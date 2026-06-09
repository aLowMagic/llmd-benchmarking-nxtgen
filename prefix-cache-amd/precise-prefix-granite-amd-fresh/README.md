# Granite 4.1 8B on AMD MI325X

This directory runs the AMD-only granite benchmark using:

- Model: `ibm-granite/granite-4.1-8b`
- Namespace: `llm-d-granite-amd-kv`
- Decode pods: 8 AMD replicas
- llm-d path: `http://precise-granite-amd-epp.llm-d-granite-amd-kv.svc.cluster.local:8081`
- Baseline path: `http://decode-clusterip.llm-d-granite-amd-kv.svc.cluster.local:8000`

## Prerequisites

```bash
microk8s kubectl get node -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.amd\.com/gpu
microk8s config > /tmp/microk8s-kubeconfig
export KUBECONFIG=/tmp/microk8s-kubeconfig
```

The node should show `amd.com/gpu` capacity, normally `8` on a MI325X node.

## Deploy

```bash
cd /Users/faney/Documents/workspace/llmd-benchmarking-nxtgen/prefix-cache-amd/precise-prefix-granite-amd-fresh

export NAMESPACE=llm-d-granite-amd-kv
export HF_TOKEN='<your Hugging Face token>'

./deploy.sh deploy
./deploy.sh status
./deploy.sh test
```

If your host uses `helm3` instead of `helm`, run:

```bash
HELM=helm3 ./deploy.sh deploy
```

If you only have MicroK8s subcommands, expose them as normal command names first:

```bash
snap alias microk8s.kubectl kubectl
snap alias microk8s.helm3 helm3
```

If `llm-d-hf-token` already exists in another namespace, omit `HF_TOKEN` and set:

```bash
export SOURCE_NAMESPACE=<namespace-with-llm-d-hf-token>
```

## Benchmark

```bash
cd /Users/faney/Documents/workspace/llmd-benchmarking-nxtgen/prefix-cache-amd/precise-prefix-granite-amd-fresh/benchmark

bash run_only.sh -c config-llmd-scaled.yaml -o "$(pwd)/results-llmd-scaled"
bash run_only.sh -c config-k8s-scaled.yaml -o "$(pwd)/results-k8s-scaled"
python3 plot_comparison.py
```

`config-llmd-scaled.yaml` targets the EPP service, while `config-k8s-scaled.yaml` targets the plain `decode-clusterip` baseline.
