# Granite 4.1 8B AMD Precise Prefix Cache

This directory deploys `ibm-granite/granite-4.1-8b` on AMD GPUs with precise prefix-cache-aware routing.

## Hardware

The default modelservice values use 8 AMD decode replicas:

- Model: `ibm-granite/granite-4.1-8b`
- Runtime image: `ghcr.io/llm-d/llm-d-rocm:v0.6.0`
- Accelerator type: `amd`
- Node selector: `feature.node.kubernetes.io/amd-gpu: "true"`

To use fewer GPUs, update `decode.replicas` in `ms-kv-events-amd/values.yaml` and set `DECODE_REPLICAS` when using `deploy.sh`.

## Prerequisites

- Have the client tools from `../prereq/client-setup/README.md`.
- Configure the gateway control plane from `../prereq/gateway-provider/README.md`.
- Create `llm-d-hf-token` in the target namespace with key `HF_TOKEN`.

## Deploy

```bash
cd /Users/faney/Documents/workspace/llmd-benchmarking-nxtgen/prefix-cache-amd/precise-prefix-granite-amd

export NAMESPACE=llm-d-granite-kv
export HF_TOKEN='<your Hugging Face token>'

./deploy.sh deploy
./deploy.sh status
./deploy.sh test
```

For a direct helmfile install:

```bash
helmfile apply -e istio -n ${NAMESPACE}
```

Pod discovery mode is also available:

```bash
POD_DISCOVERY=true helmfile apply -e istio -n ${NAMESPACE}
```

## Routes

Apply the provider-specific route after deployment:

```bash
kubectl apply -f httproute.yaml -n ${NAMESPACE}
```

For GKE, use `httproute.gke.yaml`. For OpenShift-specific route handling, use `httproute-openshift.yaml`.

## Benchmark

Existing benchmark configs are in `benchmark/`:

```bash
cd benchmark
bash run_only.sh -c config-llmd-scaled.yaml
bash run_only.sh -c config-k8s-scaled.yaml
python3 plot_comparison.py
```

Reusable benchmark templates are in `benchmark-templates/` and now target `ibm-granite/granite-4.1-8b`.
