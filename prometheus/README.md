# Prometheus

> Pulls `/metrics` from every other service every 5 seconds, stores them
> in its local TSDB, evaluates a small set of recording rules so dashboards
> don't compute the same histogram_quantile on every panel load.

## What this is

[Prometheus](https://prometheus.io/) is a pull-based time-series database
+ query engine. Services expose `/metrics` in a simple text format;
Prometheus scrapes them on a schedule and stores the result. Queries use
PromQL. Grafana sits on top.

## Why it's here

Single pane of glass for *metrics* — the first of the two observability
pillars we're covering in Phase 1. Six things are scraped:

| Job | Target | What we get |
| --- | ------ | ----------- |
| `vllm` | `vllm-engine:8000` | KV cache, queue depth, batch size, tokens/s, prefix-cache hit rate |
| `litellm` | `litellm:4000/metrics/` *(trailing slash!)* | Gateway request rate, latency histograms, per-user labels |
| `dcgm` | `dcgm-exporter:9400` | GPU power, temp, memory, clocks |
| `node` | `node-exporter:9100` | Host CPU, memory, disk, network |
| `cadvisor` | `cadvisor:8080` | Per-container CPU, memory, IO |
| `prometheus` | `localhost:9090` | Self — scrape duration, target health |

## Configuration walkthrough

### [`prometheus.yml`](prometheus.yml)

- **`scrape_interval: 5s`** — short, because LLM bursts can be very brief.
  Real prod is 15-60 s. Don't push lower than 1 s without thinking about
  cardinality + storage.
- **`evaluation_interval: 15s`** — recording rules re-compute at this
  cadence. Cheaper than re-querying on every dashboard tick.
- **`external_labels: { cluster, env }`** — every series Prometheus ingests
  gets these labels. Useful for federation and disambiguation.
- **`metrics_path: /metrics/`** on the `litellm` job — LiteLLM's exporter
  only answers on the trailing-slash path. Without this set, every scrape
  pays a 307 redirect round-trip.
- Each job has a **`labels: { layer: ... }`** so dashboards / alerts can
  filter by "is this an inference, gateway, hardware, or meta target?"

### [`rules/llm.rules.yml`](rules/llm.rules.yml)

Three groups of recording rules:

| Group | Rules |
| ----- | ----- |
| `llm-gateway` | request rate (total + by user), success rate, p50/p95 latency, API-only latency |
| `vllm-engine` | tokens/s, prompt-tokens/s, queue depth, active batch size |
| `gpu-hardware` | 30 s power moving average, FB used as fraction |

Naming convention is the standard Prometheus one: `<level>:<metric>:<agg>`,
e.g. `llm:request_latency_p95_seconds`. Lets dashboards reference a stable
name regardless of which underlying histogram or counter actually backs it.

## How to discover metric names yourself

This is the single most useful debugging trick:

```bash
# Help text for every series an exporter exposes (line per metric family)
curl -s http://localhost:8000/metrics | grep ^# HELP   # vllm
curl -sL http://localhost:4000/metrics/ | grep ^# HELP  # litellm (note trailing /)
curl -s http://localhost:9400/metrics | grep ^# HELP   # dcgm
curl -s http://localhost:9100/metrics | grep ^# HELP   # node
curl -s http://localhost:8080/metrics | grep ^# HELP   # cadvisor

# Family name only (strip labels):
curl -s http://localhost:8000/metrics | grep -E "^vllm:" | awk -F'{' '{print $1}' | sort -u
```

Recording rules use the exact names found this way — verify after any
image bump.

## Useful PromQL recipes

```promql
# Request rate (per second), per requested model
sum by (requested_model) (rate(litellm_proxy_total_requests_metric_total[1m]))

# Tokens per second (output, across all in-flight requests)
sum(rate(vllm:generation_tokens_total[30s]))

# KV-cache pressure: is the slab filling up?
vllm:gpu_cache_usage_perc

# Prefix-cache hit rate — repeated system prompts produce visible jumps
vllm:gpu_prefix_cache_hit_rate

# GPU power - 30 s moving average vs raw (the prefill/decode burstiness lesson)
avg_over_time(DCGM_FI_DEV_POWER_USAGE[30s])
DCGM_FI_DEV_POWER_USAGE

# Per-container memory usage in MiB
container_memory_working_set_bytes{name=~".+"} / 1024 / 1024

# Per-tenant request rate (set X-User-Id from the agent app in Phase 1.2)
sum by (user) (rate(litellm_proxy_total_requests_metric_total[1m]))

# Queue saturation alert candidate:
# average waiting requests over the last 2 minutes
avg_over_time(vllm:num_requests_waiting[2m])
```

## Smoke tests

```bash
# All targets healthy
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health: .health, lastError: .lastError}'

# Recording rules evaluating
curl -s --data-urlencode 'query=llm:request_rate' http://localhost:9090/api/v1/query | jq

# Hot-reload after editing prometheus.yml (no container restart needed)
curl -X POST http://localhost:9090/-/reload
```

## Where to look when it breaks

| Symptom | Likely cause | Fix |
| ------- | ------------ | --- |
| A target shows "DOWN" with "context deadline exceeded" | Service slow or unhealthy | `docker compose ps`, then `docker compose logs <service>` |
| Target DOWN with "redirect not permitted" | Missing `metrics_path` for an exporter that requires trailing slash | Add `metrics_path` to that job (see the `litellm` block) |
| Recording rule has no data | Underlying histogram never populated | Fire a couple of requests; rule needs at least one bucket sample |
| `/-/reload` returns 403 | Container started without `--web.enable-lifecycle` | Already enabled in this compose; check `command:` block |
| TSDB growing unexpectedly | Cardinality from per-request labels (user_id, route, etc.) | LiteLLM emits *many* labels per request — consider dropping some via `metric_relabel_configs` if it becomes a problem |

## What's next

- Phase 1.2 adds a 7th scrape target: `mock-services:9000/metrics`.
  Add it to the scrape config with `layer: app`; nothing else changes.
- Phase 2 adds `triton:8000` as another `inference`-layer target; the
  existing `vllm` recording rules apply unchanged if Triton's metric
  family names also start with `vllm:` (they don't — bridge with
  relabel rules or add a parallel set of recording rules).
