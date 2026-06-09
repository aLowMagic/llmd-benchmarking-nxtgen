#!/usr/bin/env python3
"""Plot TTFT and output tok/s for llm-d vs plain k8s, granite-4.1-8b, rates 3-50.

Same plot style as 2.1/precise-prefix-granite. EPP uses approximate prefix-cache-scorer
(hash-based, no tokenizer — works for trust_remote_code models like granite-4.1-8b) +
kv-cache-utilization-scorer + queue-scorer (weights 3/2/2).
"""
import json
import pathlib
import matplotlib.pyplot as plt

BASE = pathlib.Path(__file__).parent
LLMD = next(BASE.glob("results-llmd-scaled/*/inference-perf_*_llmd-precise-granite-approx-scaled"))
K8S = next(BASE.glob("results-k8s-scaled/*/inference-perf_*_k8s-roundrobin-granite-approx-scaled"))

# Stage index -> target rate (from config-*-scaled.yaml)
STAGE_RATE = {0: 15, 1: 3, 2: 10, 3: 15, 4: 20, 5: 25, 6: 30, 7: 40, 8: 50}
INCLUDE_STAGES = [1, 2, 3, 4, 5, 6]  # skip warmup + rates 40/50 (well past saturation)


def load_stage(root: pathlib.Path, stage: int) -> dict:
    p = root / f"stage_{stage}_lifecycle_metrics.json"
    with open(p) as f:
        return json.load(f)


rows = []
for s in INCLUDE_STAGES:
    l = load_stage(LLMD, s)
    k = load_stage(K8S, s)
    rows.append({
        "rate": STAGE_RATE[s],
        "llmd_ttft": l["successes"]["latency"]["time_to_first_token"]["mean"],
        "k8s_ttft": k["successes"]["latency"]["time_to_first_token"]["mean"],
        "llmd_tok": l["successes"]["throughput"]["output_tokens_per_sec"],
        "k8s_tok": k["successes"]["throughput"]["output_tokens_per_sec"],
    })

rates = [r["rate"] for r in rows]

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13, 5))

ax1.plot(rates, [r["llmd_ttft"] for r in rows], "o-", label="llm-d (approximate prefix-cache)", linewidth=2, markersize=8)
ax1.plot(rates, [r["k8s_ttft"] for r in rows], "s-", label="plain k8s (round-robin)", linewidth=2, markersize=8)
ax1.set_xlabel("Target QPS (requests/sec)")
ax1.set_ylabel("Mean TTFT (seconds)")
ax1.set_title("Time To First Token vs QPS\ngranite-4.1-8b on DGX H100 (8 H100 SXM)")
ax1.legend()
ax1.grid(True, alpha=0.3)
ax1.set_yscale("log")

ax2.plot(rates, [r["llmd_tok"] for r in rows], "o-", label="llm-d (approximate prefix-cache)", linewidth=2, markersize=8)
ax2.plot(rates, [r["k8s_tok"] for r in rows], "s-", label="plain k8s (round-robin)", linewidth=2, markersize=8)
ax2.set_xlabel("Target QPS (requests/sec)")
ax2.set_ylabel("Output tokens/sec")
ax2.set_title("Output Throughput vs QPS\ngranite-4.1-8b on DGX H100 (8 H100 SXM)")
ax2.legend()
ax2.grid(True, alpha=0.3)

plt.tight_layout()
out = BASE / "comparison_rates_3_to_30.png"
plt.savefig(out, dpi=120, bbox_inches="tight")
print(f"saved: {out}")

# Also print numbers for reference
print()
print(f"{'rate':<6} {'llmd_TTFT':<12} {'k8s_TTFT':<12} {'TTFT_x':<8} {'llmd_tok':<10} {'k8s_tok':<10} {'tok_%':<8}")
print("-" * 70)
for r in rows:
    ttft_x = r["k8s_ttft"] / r["llmd_ttft"] if r["llmd_ttft"] else 0
    tok_pct = (r["llmd_tok"] - r["k8s_tok"]) / r["k8s_tok"] * 100 if r["k8s_tok"] else 0
    print(f"{r['rate']:<6} {r['llmd_ttft']:<12.3f} {r['k8s_ttft']:<12.3f} {ttft_x:<8.2f} {r['llmd_tok']:<10.0f} {r['k8s_tok']:<10.0f} {tok_pct:+.1f}%")
