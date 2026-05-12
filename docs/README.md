# Walkthrough docs

Read in order. Each one builds on the previous.

| # | Doc | What it covers |
| - | --- | -------------- |
| 01 | [Getting started](01-getting-started.md) | First-run smoke test: preflight, per-layer curls, a single Streamlit chat, multi-tenancy, an optional saturation glimpse, and a URL reference card. |
| 02 | [Anatomy of a request](02-anatomy-of-a-request.md) | Follow one multi-tool prompt through every layer — UI, agent, gateway, vLLM, tool, mock-services, back — with the corresponding trace tree and metric signature. |
| 03 | [Saturation analysis](03-saturation-analysis.md) | Drive real load with [`scripts/load.sh`](../scripts/load.sh) and its seven profiles (smoke, short, decode-heavy, prefill-heavy, prefix-cache, mixed, saturation). What each profile is for and which dashboard panel it lights up. |
| 04 | [Trace ↔ metric correlation](04-trace-metric-correlation.md) | Pick one Langfuse trace, find its wall-clock window on the GPU power panel, see the prefill/decode burstiness pattern with your own eyes. The lesson the sandbox was built for. |

## Quick links

- Streamlit chat — <http://localhost:8501>
- Langfuse traces — <http://localhost:3001>
- Grafana LLM Overview — <http://localhost:3000/d/llm-overview/llm-overview>
- Grafana GPU Saturation — <http://localhost:3000/d/gpu-saturation/gpu-saturation>
- Prometheus — <http://localhost:9090>

## When something doesn't match

Each layer's `README.md` has a "Where to look when it breaks" section:
- [vllm/](../vllm/README.md) · [litellm/](../litellm/README.md) · [langfuse/](../langfuse/README.md)
- [prometheus/](../prometheus/README.md) · [grafana/](../grafana/README.md) · [dcgm/](../dcgm/README.md)
- [app/](../app/README.md) · [mock-services/](../mock-services/README.md)

For host-level prereqs: [`scripts/preflight.sh`](../scripts/preflight.sh).
For a clean reset: [`scripts/cleanup.sh`](../scripts/cleanup.sh).
