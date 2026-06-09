#!/usr/bin/env bash
#
# Deploy / teardown the AMD MI325X granite-4.1-8b prefix-cache stack.
#
# Usage:
#   ./deploy.sh deploy       Install from empty namespace (idempotent)
#   ./deploy.sh destroy      Remove everything except the namespace + HF token
#   ./deploy.sh redeploy     destroy + deploy
#   ./deploy.sh status       Print current pod/service state
#   ./deploy.sh test         Run a basic end-to-end request through the EPP
#
# Env vars:
#   NAMESPACE                (default: llm-d-granite-amd-kv)
#   HF_TOKEN                 Required on first deploy only; otherwise copied
#                            from an existing secret in SOURCE_NAMESPACE
#   SOURCE_NAMESPACE         Namespace to copy HF token secret from if
#                            HF_TOKEN env is unset (default: llm-d-sarvam-kv)
#   EXPECTED_DECODE_REPLICAS (default: 8)
#   KUBECTL                  kubectl command (default: kubectl)
#   HELM                     helm command (default: helm)
#   HELMFILE                 helmfile command (default: helmfile)

set -euo pipefail

NAMESPACE="${NAMESPACE:-llm-d-granite-amd-kv}"
SOURCE_NAMESPACE="${SOURCE_NAMESPACE:-llm-d-sarvam-kv}"
EXPECTED_DECODE_REPLICAS="${EXPECTED_DECODE_REPLICAS:-8}"
KUBECTL="${KUBECTL:-kubectl}"
HELM="${HELM:-helm}"
HELMFILE="${HELMFILE:-helmfile}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export HELMFILE_DIR="$SCRIPT_DIR"
MS_RELEASE="ms-kv-events"
EPP_RELEASE="precise-granite-amd"
EPP_SVC="${EPP_RELEASE}-epp"
ZMQ_ALIAS_SVC="gaie-kv-events-epp"
MODEL_NAME="ibm-granite/granite-4.1-8b"

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
err() { printf '\033[1;31m[ERR]\033[0m %s\n' "$*" >&2; exit 1; }

check_prereqs() {
    for cmd in "$KUBECTL" "$HELM" "$HELMFILE" jq curl; do
        command -v "$cmd" >/dev/null || err "missing required command: $cmd"
    done
    "$HELM" plugin list 2>/dev/null | grep -q '^diff' || {
        log "Installing helm-diff plugin..."
        "$HELM" plugin install https://github.com/databus23/helm-diff --verify=false
    }
}

ensure_namespace_and_token() {
    "$KUBECTL" get ns "$NAMESPACE" >/dev/null 2>&1 || {
        log "Creating namespace $NAMESPACE"
        "$KUBECTL" create namespace "$NAMESPACE"
    }
    "$KUBECTL" get secret llm-d-hf-token -n "$NAMESPACE" >/dev/null 2>&1 && return 0

    if [[ -n "${HF_TOKEN:-}" ]]; then
        log "Creating llm-d-hf-token secret from HF_TOKEN env"
        "$KUBECTL" create secret generic llm-d-hf-token -n "$NAMESPACE" \
            --from-literal=HF_TOKEN="$HF_TOKEN"
        return 0
    fi

    if "$KUBECTL" get secret llm-d-hf-token -n "$SOURCE_NAMESPACE" >/dev/null 2>&1; then
        log "Copying llm-d-hf-token secret from $SOURCE_NAMESPACE"
        "$KUBECTL" get secret llm-d-hf-token -n "$SOURCE_NAMESPACE" -o yaml \
            | sed "s/namespace: $SOURCE_NAMESPACE/namespace: $NAMESPACE/" \
            | "$KUBECTL" apply -n "$NAMESPACE" -f -
        return 0
    fi

    err "HF_TOKEN env not set and no llm-d-hf-token secret found in $SOURCE_NAMESPACE"
}

deploy_vllm() {
    log "Installing $MS_RELEASE (granite AMD vLLM decode pods)"
    cd "$HELMFILE_DIR"
    "$HELMFILE" apply -n "$NAMESPACE" --suppress-secrets >/dev/null
}

deploy_epp() {
    log "Installing $EPP_RELEASE (standalone EPP chart)"
    "$HELM" upgrade --install "$EPP_RELEASE" \
        oci://registry.k8s.io/gateway-api-inference-extension/charts/standalone \
        --version v1.5.0 \
        -n "$NAMESPACE" \
        -f "$SCRIPT_DIR/standalone-values/values.yaml" >/dev/null
}

deploy_zmq_alias() {
    log "Creating ExternalName service alias $ZMQ_ALIAS_SVC -> $EPP_SVC"
    cat <<YAML | "$KUBECTL" apply -n "$NAMESPACE" -f - >/dev/null
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
    "$KUBECTL" rollout status -n "$NAMESPACE" deploy/"$EPP_SVC" --timeout=300s || true

    log "Waiting for $EXPECTED_DECODE_REPLICAS/$EXPECTED_DECODE_REPLICAS decode pods ready (up to 35m for first pull)"
    local deadline=$(( $(date +%s) + 2100 ))
    while true; do
        local ready
        ready=$("$KUBECTL" get pods -n "$NAMESPACE" -l llm-d.ai/role=decode --no-headers 2>/dev/null \
                | awk '$2=="1/1"' | wc -l | tr -d ' ')
        echo "  decode ready=$ready/$EXPECTED_DECODE_REPLICAS"
        [[ "$ready" == "$EXPECTED_DECODE_REPLICAS" ]] && break
        [[ $(date +%s) -gt $deadline ]] && err "timeout waiting for decode pods"
        sleep 30
    done
}

run_test() {
    log "Port-forwarding and sending 3 identical completion requests"
    pkill -f "port-forward.*$NAMESPACE" 2>/dev/null || true
    sleep 1
    "$KUBECTL" port-forward -n "$NAMESPACE" "service/$EPP_SVC" 8000:8081 >/tmp/pf-$$.log 2>&1 &
    local pf=$!
    trap "kill $pf 2>/dev/null || true" EXIT
    sleep 3

    local prompt='Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Unique marker: granite-amd-verification-run.'
    local body
    body=$(jq -n --arg model "$MODEL_NAME" --arg p "$prompt" '{model:$model,prompt:$p,max_tokens:10}')

    for i in 1 2 3; do
        printf '  call %d: ' "$i"
        curl -s -m 60 http://localhost:8000/v1/completions \
            -H "Content-Type: application/json" -d "$body" \
            -o /dev/null -w "HTTP=%{http_code} time=%{time_total}s\n"
        sleep 3
    done

    { kill $pf; wait $pf; } 2>/dev/null || true
    trap - EXIT

    log "Scoreboard from EPP logs"
    local epp
    epp=$("$KUBECTL" get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
          | awk '/^'"$EPP_SVC"'/ {print $1; exit}')
    [[ -n "$epp" ]] || { log "EPP pod not found"; return 1; }
    "$KUBECTL" logs -n "$NAMESPACE" "$epp" -c epp --tail=2000 2>&1 \
        | grep -E '"Calculated score"|prefix-cache' \
        | tail -50 || true
}

cmd_deploy() {
    check_prereqs
    ensure_namespace_and_token
    deploy_vllm
    deploy_epp
    deploy_zmq_alias
    wait_for_pods
    log "Deployment complete. Run '$0 test' to verify routing."
}

cmd_destroy() {
    log "Deleting helm releases in $NAMESPACE"
    "$HELM" uninstall "$EPP_RELEASE" -n "$NAMESPACE" 2>/dev/null || true
    (cd "$HELMFILE_DIR" && "$HELMFILE" destroy -n "$NAMESPACE" 2>/dev/null) || true

    log "Deleting ExternalName alias"
    "$KUBECTL" delete svc "$ZMQ_ALIAS_SVC" -n "$NAMESPACE" --ignore-not-found

    log "Force-deleting any lingering decode pods"
    "$KUBECTL" delete pods -n "$NAMESPACE" -l llm-d.ai/role=decode --force --grace-period=0 2>/dev/null || true

    log "Namespace + HF token secret retained. Delete namespace manually if desired:"
    echo "    $KUBECTL delete namespace $NAMESPACE"
}

cmd_status() {
    log "Namespace: $NAMESPACE"
    "$KUBECTL" get pods,svc,inferencepool -n "$NAMESPACE" 2>&1 || true
    echo
    "$HELM" list -n "$NAMESPACE" 2>&1 || true
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
