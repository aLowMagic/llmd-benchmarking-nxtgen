# DGX H100 Prefix Cache NVIDIA Variant

This directory is copied from `prefix-cache-nvidia` and retargeted for a single DGX H100.

Default DGX H100 settings:

- `decode.replicas: 8` in the primary `ms-kv-events/values.yaml` files, assuming one vLLM decode pod per H100 GPU.
- `decode.parallelism.tensor: 1` and `decode.parallelism.data: 1`, so each decode pod consumes one GPU.
- `decode.nodeSelector.nvidia.com/gpu.product: NVIDIA-H100-80GB-HBM3`, the common NVIDIA GPU Operator product label for H100 SXM 80GB GPUs in DGX H100 systems.

Before deploying, confirm your actual node label:

```bash
kubectl get nodes -L nvidia.com/gpu.product
```

If your cluster reports a different value, replace `NVIDIA-H100-80GB-HBM3` in:

- `precise-prefix-granite/ms-kv-events/values.yaml`
- `precise-prefix-granite-approx/ms-kv-events/values.yaml`
- `precise-prefix-sarvam-30b/ms-kv-events/values.yaml`

If the DGX H100 is the only NVIDIA GPU pool in the cluster, `nvidia.com/gpu.present: "true"` is also a workable selector, but the product label is safer when the cluster has mixed NVIDIA GPUs.

If the cluster has multiple DGX H100 nodes and you want to use exactly one physical DGX, add another selector such as `kubernetes.io/hostname: <dgx-node-name>` or a custom node label alongside the GPU product selector.

---

# Multi-GPU-Vendor Deployment Example

Deploy the same model across NVIDIA and AMD GPUs using two LLMInferenceService instances that share a single
scheduler/EPP via a custom InferencePool selector.

## Problem

A cluster has both NVIDIA and AMD GPU nodes. A single LLMInferenceService can only target one GPU type because all
replicas share the same pod template. Without this pattern, one GPU vendor's capacity sits idle.

## Solution

1. **NVIDIA instance** (`qwen2-7b-instruct-nvidia`) — creates the scheduler/EPP, InferencePool, HTTPRoute, and Gateway.
   The InferencePool uses a custom selector (`llm-pool: qwen2-7b`) instead of the default name-based selector. There is no separate object named `llm-pool`; it is a **label** on workload pods. The InferencePool resource is named `qwen2-7b-instruct-nvidia-inference-pool` (`oc get inferencepool`).
2. **AMD instance** (`qwen2-7b-instruct-amd`) — has **no router** (no scheduler, no route, no gateway). Its pods carry
   the same `llm-pool: qwen2-7b` label, so the EPP from the NVIDIA instance discovers and routes traffic to them.

## Architecture

```
                         ┌──────────────┐
                         │   Gateway    │
                         └──────┬───────┘
                                │
                         ┌──────┴───────┐
                         │  HTTPRoute   │
                         └──────┬───────┘
                                │
                    ┌───────────┴───────────┐
                    │   Scheduler / EPP     │
                    │  (from NVIDIA isvc)   │
                    └───────────┬───────────┘
                                │
                    InferencePool selector:
                      llm-pool: qwen2-7b
                      kserve.io/component: workload
                                │
              ┌─────────────────┼─────────────────┐
              │                                   │
   ┌──────────┴──────────┐             ┌──────────┴──────────┐
   │  NVIDIA vLLM Pods   │             │   AMD vLLM Pods     │
   │  (3 replicas)       │             │   (2 replicas)      │
   │  nvidia.com/gpu: 1  │             │  amd.com/gpu: 1     │
   └─────────────────────┘             └─────────────────────┘
```

## How It Works

By default, the controller sets the InferencePool selector to match on `app.kubernetes.io/name: <service-name>`,
which only selects pods from that single LLMInferenceService. To pool pods from multiple instances together, the
NVIDIA instance overrides the selector with a shared custom label:

```yaml
# NVIDIA instance — custom pool selector (InferencePool v1 embedded in pool.spec)
spec:
  labels:
    llm-pool: qwen2-7b          # added to all workload pods
  router:
    scheduler:
      pool:
        spec:
          selector:
            matchLabels:
              llm-pool: qwen2-7b            # shared across instances
              kserve.io/component: workload # only select workload pods
          targetPorts:
            - number: 8000
          endpointPickerRef:
            name: qwen2-7b-instruct-nvidia-epp-service
            kind: Service
            port:
              number: 9002
```

The AMD instance carries the same label but has no router:

```yaml
# AMD instance — no router, shared label
spec:
  labels:
    llm-pool: qwen2-7b          # matches the InferencePool selector
  # no router section
```

## Prerequisites

- Kubernetes cluster with both NVIDIA and AMD GPU nodes
- Nodes labeled appropriately (e.g., `nvidia.com/gpu.present: "true"`, `amd.com/gpu.present: "true"`)
- Model weights accessible via HuggingFace

### Pool spec and CRD version

`spec.router.scheduler.pool.spec` is validated against the **InferencePool** shape your cluster’s `LLMInferenceService` CRD was built for. Two variants exist:

| Variant | Selector | Ports | EPP reference |
|---------|----------|-------|----------------|
| **v1** (`inference.networking.k8s.io/v1`) | `selector.matchLabels` (nested map) | `targetPorts: [{ number: … }]` | `endpointPickerRef` with `port.number` |
| **v1alpha2** (`inference.networking.x-k8s.io`) | **Flat** map under `selector` (each value is a **string**) | `targetPortNumber` | `extensionRef` with `portNumber` |

Inspect what your cluster expects:

```bash
oc explain llminferenceservice.spec.router.scheduler.pool.spec --recursive
```

If `oc apply` fails with **`matchLabels` must be of type string**, **`extensionRef: Required value`**, or **`targetPortNumber: Required value`**, you used the **v1** shape but the apiserver still embeds **v1alpha2**. Do **not** nest `matchLabels`; put label keys directly under `selector`. Use [`llm-inference-service-qwen2-7b-nvidia-with-scheduler-inferencepool-v1alpha2.yaml`](llm-inference-service-qwen2-7b-nvidia-with-scheduler-inferencepool-v1alpha2.yaml) instead of the default NVIDIA manifest.

## Deployment

```bash
# 1. Deploy the NVIDIA instance (creates InferencePool, EPP, HTTPRoute, Gateway).
#    Use the -inferencepool-v1alpha2.yaml variant if your CRD validates pool.spec as v1alpha2.
oc apply -f llm-inference-service-qwen2-7b-nvidia-with-scheduler.yaml

# 2. Deploy the AMD instance (pods join the existing InferencePool via shared label)
oc apply -f llm-inference-service-qwen2-7b-amd-no-scheduler.yaml


# 3. Add labels manually to the pods as the current KServe does not automatically do this
oc label pod qwen2-7b-instruct-nvidia-kserve-<...> llm-pool=qwen2-7b
oc label pod qwen2-7b-instruct-amd-kserve-<...> llm-pool=qwen2-7b


```

## Configuration Summary

| Feature         | NVIDIA Instance                   | AMD Instance         |
|-----------------|-----------------------------------|----------------------|
| Replicas        | 3                                 | 2                    |
| GPU             | 1x NVIDIA per replica             | 1x AMD per replica   |
| Scheduler / EPP | Yes (creates InferencePool + EPP) | No                   |
| Route / Gateway | Yes                               | No                   |
| Shared label    | `llm-pool: qwen2-7b`              | `llm-pool: qwen2-7b` |

## Verification

```bash
# Check both services
oc get llminferenceservice

# Verify pods are on the correct GPU nodes
oc get pods -o wide -l llm-pool=qwen2-7b

# Confirm the InferencePool selects pods from both instances
oc get inferencepool -o yaml

# Check scheduler logs for routing across all replicas
oc logs -l app.kubernetes.io/component=llminferenceservice-scheduler -f

# Send a test request
curl -k https://<route-url>/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "prompt": "What is Kubernetes?",
    "max_tokens": 100
  }'
```

## Scaling

Each instance can be scaled independently:

```bash
# Scale NVIDIA replicas
oc patch llmisvc qwen2-7b-instruct-nvidia --type merge -p '{"spec":{"replicas":5}}'

# Scale AMD replicas
oc patch llmisvc qwen2-7b-instruct-amd --type merge -p '{"spec":{"replicas":4}}'
```

The EPP automatically discovers new pods as they match the shared `llm-pool: qwen2-7b` label.
