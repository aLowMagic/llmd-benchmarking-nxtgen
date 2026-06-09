#!/usr/bin/env bash
#
# Deploy / teardown the precise-prefix-cache-aware stack for
# ibm-granite/granite-4.1-8b on OpenShift with AMD GPUs.
#
# Usage:
#   ./deploy.sh deploy       Install from empty namespace (idempotent)
#   ./deploy.sh destroy      Remove everything except the namespace + HF token
#   ./deploy.sh redeploy     destroy + deploy
#   ./deploy.sh status       Print current pod/service state
#   ./deploy.sh test         Run end-to-end prefix-cache verification
#
# Env vars:
#   NAMESPACE                (default: llm-d-granite-kv)
#   HF_TOKEN                 Required on first deploy only; otherwise copied
#                            from an existing secret in SOURCE_NAMESPACE
#   SOURCE_NAMESPACE         Namespace to copy HF token secret from if
#                            HF_TOKEN env is unset (default: llm-d-precise-prefix-granite)
#   DECODE_REPLICAS          Expected decode pod count (default: 8)

set -euo pipefail

NAMESPACE="${NAMESPACE:-llm-d-granite-kv}"
SOURCE_NAMESPACE="${SOURCE_NAMESPACE:-llm-d-precise-prefix-granite}"
DECODE_REPLICAS="${DECODE_REPLICAS:-8}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Inherit llm-d guide prereq directory two levels up — matches existing layout
export HELMFILE_DIR="$SCRIPT_DIR"
MS_RELEASE="ms-kv-events"
EPP_RELEASE="precise-granite"
EPP_SVC="${EPP_RELEASE}-epp"
ZMQ_ALIAS_SVC="gaie-kv-events-epp"

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
err() { printf '\033[1;31m[ERR]\033[0m %s\n' "$*" >&2; exit 1; }

check_prereqs() {
    for cmd in kubectl helm helmfile jq curl; do
        command -v "$cmd" >/dev/null || err "missing required command: $cmd"
    done
    helm plugin list 2>/dev/null | grep -q '^diff' || {
        log "Installing helm-diff plugin..."
        helm plugin install https://github.com/databus23/helm-diff --verify=false
    }
}

ensure_namespace_and_token() {
    kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || {
        log "Creating namespace $NAMESPACE"
        kubectl create namespace "$NAMESPACE"
    }
    kubectl get secret llm-d-hf-token -n "$NAMESPACE" >/dev/null 2>&1 && return 0

    if [[ -n "${HF_TOKEN:-}" ]]; then
        log "Creating llm-d-hf-token secret from HF_TOKEN env"
        kubectl create secret generic llm-d-hf-token -n "$NAMESPACE" \
            --from-literal=HF_TOKEN="$HF_TOKEN"
        return 0
    fi

    if kubectl get secret llm-d-hf-token -n "$SOURCE_NAMESPACE" >/dev/null 2>&1; then
        log "Copying llm-d-hf-token secret from $SOURCE_NAMESPACE"
        kubectl get secret llm-d-hf-token -n "$SOURCE_NAMESPACE" -o yaml \
            | sed "s/namespace: $SOURCE_NAMESPACE/namespace: $NAMESPACE/" \
            | kubectl apply -n "$NAMESPACE" -f -
        return 0
    fi

    err "HF_TOKEN env not set and no llm-d-hf-token secret found in $SOURCE_NAMESPACE"
}

deploy_vllm() {
    log "Installing $MS_RELEASE (vllm decode pods)"
    cd "$HELMFILE_DIR"
    helmfile -e istio -l "name=$MS_RELEASE" apply -n "$NAMESPACE" --suppress-secrets >/dev/null
}

deploy_epp() {
    log "Installing $EPP_RELEASE (standalone EPP chart)"
    helm upgrade --install "$EPP_RELEASE" \
        oci://registry.k8s.io/gateway-api-inference-extension/charts/standalone \
        --version v1.5.0 \
        -n "$NAMESPACE" \
        -f "$SCRIPT_DIR/standalone-values/values.yaml" >/dev/null

    log "Applying tokenizer-uds sidecar patch"
    kubectl apply -f "$SCRIPT_DIR/standalone-values/tokenizer-sidecar-patch.yaml" -n "$NAMESPACE" >/dev/null
}

deploy_zmq_alias() {
    log "Creating ExternalName service alias $ZMQ_ALIAS_SVC -> $EPP_SVC"
    cat <<YAML | kubectl apply -n "$NAMESPACE" -f - >/dev/null
apiVersion: v1
kind: Service
metadata:
  name: $ZMQ_ALIAS_SVC
spec:
  type: ExternalName
  externalName: $EPP_SVC.$NAMESPACE.svc.cluster.local
YAML
}

wait_for_pods() {
    log "Waiting for EPP deployment rollout (up to 5m)"
    kubectl rollout status -n "$NAMESPACE" deploy/"$EPP_SVC" --timeout=300s || true

    log "Waiting for $DECODE_REPLICAS/$DECODE_REPLICAS decode pods ready (up to 35m for first pull)"
    local deadline=$(( $(date +%s) + 2100 ))
    while true; do
        local ready
        ready=$(kubectl get pods -n "$NAMESPACE" -l llm-d.ai/role=decode --no-headers 2>/dev/null \
                | awk '$2=="1/1"' | wc -l | tr -d ' ')
        echo "  decode ready=$ready/$DECODE_REPLICAS"
        [[ "$ready" == "$DECODE_REPLICAS" ]] && break
        [[ $(date +%s) -gt $deadline ]] && err "timeout waiting for decode pods"
        sleep 30
    done
}

run_test() {
    log "Port-forwarding and sending 3 identical completion requests"
    pkill -f "port-forward.*$NAMESPACE" 2>/dev/null || true
    sleep 1
    kubectl port-forward -n "$NAMESPACE" "service/$EPP_SVC" 8000:8081 >/tmp/pf-$$.log 2>&1 &
    local pf=$!
    trap "kill $pf 2>/dev/null || true" EXIT
    sleep 3

    local prompt='Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum. Unique marker: verification-run.'
    local body
    body=$(jq -n --arg p "$prompt" '{model:"ibm-granite/granite-4.1-8b",prompt:$p,max_tokens:10}')

    for i in 1 2 3; do
        printf '  call %d: ' "$i"
        curl -s -m 60 http://localhost:8000/v1/completions \
            -H "Content-Type: application/json" -d "$body" \
            -o /dev/null -w "HTTP=%{http_code} time=%{time_total}s\n"
        sleep 3
    done

    { kill $pf; wait $pf; } 2>/dev/null || true
    trap - EXIT

    log "Scoreboard from EPP logs (precise-prefix-cache-scorer)"
    local epp
    epp=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
          | awk '/^'"$EPP_SVC"'/ {print $1; exit}')
    [[ -n "$epp" ]] || { log "EPP pod not found"; return 1; }
    kubectl logs -n "$NAMESPACE" "$epp" -c epp --tail=2000 2>&1 \
        | grep precise-prefix-cache-scorer \
        | grep '"Calculated score"' \
        | grep -oE '"score":[^,}]*' \
        | sort | uniq -c
}

cmd_deploy() {
    check_prereqs
    ensure_namespace_and_token
    deploy_vllm
    deploy_epp
    deploy_zmq_alias
    wait_for_pods
    log "Deployment complete. Run '$0 test' to verify prefix-cache routing."
}

cmd_destroy() {
    log "Deleting helm releases in $NAMESPACE"
    helm uninstall "$EPP_RELEASE" -n "$NAMESPACE" 2>/dev/null || true
    (cd "$HELMFILE_DIR" && helmfile -e istio destroy -n "$NAMESPACE" 2>/dev/null) || true

    log "Deleting ExternalName alias + tokenizer configmap"
    kubectl delete svc "$ZMQ_ALIAS_SVC" -n "$NAMESPACE" --ignore-not-found
    kubectl delete configmap tokenizer-uds-config -n "$NAMESPACE" --ignore-not-found

    log "Force-deleting any lingering decode pods"
    kubectl delete pods -n "$NAMESPACE" -l llm-d.ai/role=decode --force --grace-period=0 2>/dev/null || true

    log "Namespace + HF token secret retained. Delete namespace manually if desired:"
    echo "    kubectl delete namespace $NAMESPACE"
}

cmd_status() {
    log "Namespace: $NAMESPACE"
    kubectl get pods,svc,inferencepool -n "$NAMESPACE" 2>&1 || true
    echo
    helm list -n "$NAMESPACE" 2>&1 || true
}

case "${1:-}" in
    deploy)   cmd_deploy   ;;
    destroy)  cmd_destroy  ;;
    redeploy) cmd_destroy; cmd_deploy ;;
    status)   cmd_status   ;;
    test)     run_test     ;;
    *)
        sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
        exit 1
        ;;
esac
