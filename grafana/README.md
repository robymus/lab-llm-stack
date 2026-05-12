# Grafana

> Dashboards over the Prometheus data. Datasource + dashboards are
> *provisioned from this directory* on every start — no manual UI setup,
> and the source of truth stays in git.

## What this is

[Grafana](https://grafana.com/) is the visualisation layer. We provision:

- **One datasource:** Prometheus (auto-configured with `uid: prometheus`
  so dashboards can reference it by stable name).
- **Two dashboards**, both landing in the **"LLM Stack"** folder:
  - `01-llm-overview` — gateway/engine view: request rate, p50/p95
    latency, tokens/s, queue depth, KV cache, prefix-cache hit rate.
  - `02-gpu-saturation` — DCGM telemetry + p95 latency overlay. This
    is the dashboard for the prefill/decode burstiness lesson.

Open at <http://localhost:3000> — anonymous read is enabled, so no login
needed to view. To edit, log in with `admin / admin` (rotate before any
non-local use).

## Why it's here

Phase 1 covers two observability pillars; this is the UI for one of them.
The structure deliberately separates *what callers see* (overview) from
*what the GPU is doing* (saturation), so when something looks wrong you
know which dashboard to start on.

## Configuration walkthrough

### Provisioning

| File | What it does |
| ---- | ------------ |
| [`provisioning/datasources/datasources.yml`](provisioning/datasources/datasources.yml) | Adds Prometheus as the default datasource. `editable: false` so it can't be silently changed in the UI. `timeInterval: 5s` matches Prometheus's `scrape_interval` so `$__rate_interval` is right. |
| [`provisioning/dashboards/dashboards.yml`](provisioning/dashboards/dashboards.yml) | Tells Grafana to load every `*.json` under `/var/lib/grafana/dashboards` (which we bind-mount from `dashboards/`) into the "LLM Stack" folder. `updateIntervalSeconds: 30` picks up edits without restarting Grafana. |

### Anonymous read

The compose env sets:

```yaml
GF_AUTH_ANONYMOUS_ENABLED: "true"
GF_AUTH_ANONYMOUS_ORG_ROLE: Viewer
```

You can read every dashboard without authenticating. Edits still require
admin login. For any deployment beyond a local sandbox, replace this with
proper auth.

### Dashboards as JSON

Both dashboards are plain JSON in [`dashboards/`](dashboards/). Each panel
has a `description` field set, which Grafana renders as a tooltip on the
panel — so the *why* of every panel is one click away.

## Dashboard 01 — LLM Overview

| Panel | Reads | Healthy looks like |
| ----- | ----- | ------------------ |
| Request rate (rps) | `llm:request_rate`, `llm:request_rate_by_user` | matches your sender rate; per-user lines split out evenly when the agent app sends `X-User-Id` |
| Latency p50 / p95 | `llm:request_latency_p{50,95}_seconds`, `llm:api_latency_p95_seconds` | p95-p50 gap small under steady load; large gap = bursty / queueing |
| Tokens / second | `llm:tokens_per_second`, `llm:prompt_tokens_per_second` | output ~tens of tokens/s steady-state on Qwen-3B; prompt spikes during prefill |
| Queue depth / batch | `llm:queue_depth`, `llm:active_batch_size` | queue 0 = not saturating; batch climbs into the tens when load is heavy |
| KV cache usage | `vllm:gpu_cache_usage_perc` | climbs with concurrent requests; 0 when idle (even though the slab is allocated) |
| Prefix cache hit rate | `vllm:gpu_prefix_cache_hit_rate` | rises when prompts share prefixes (system prompts) |

## Dashboard 02 — GPU Saturation

| Panel | Reads | What to watch |
| ----- | ----- | ------------- |
| Power (W) | `DCGM_FI_DEV_POWER_USAGE` + `gpu:power_watts_avg30s` | raw line whips around; the avg lags — that gap *is* the burstiness |
| Temperature (°C) | `DCGM_FI_DEV_GPU_TEMP` | sustained 80°C+ → check the Clocks panel for throttling |
| Frame-buffer | `DCGM_FI_DEV_FB_USED`, `DCGM_FI_DEV_FB_FREE` (stacked) | vLLM grabs `--gpu-memory-utilization` fraction at start; then roughly flat |
| Clocks | `DCGM_FI_DEV_SM_CLOCK`, `DCGM_FI_DEV_MEM_CLOCK` | SM clock dropping under load + high temp = thermal throttling |
| Power ↔ p95 latency | `DCGM_FI_DEV_POWER_USAGE` (left) + `llm:request_latency_p95_seconds` (right) | the correlation lesson: power and latency tick together; tells you GPU saturation drives the user-facing latency tail |

## Editing dashboards

The `allowUiUpdates: true` provider option means you *can* edit in the
UI — but Grafana stores the edit in its SQLite, NOT in the bind-mounted
JSON. To persist:

1. Edit in the UI.
2. Dashboard top-right → Share → Export → Save to file (or "View JSON" → copy).
3. Replace `grafana/dashboards/<file>.json` with the export.
4. Commit.

Grafana picks up the file change within 30 s (`updateIntervalSeconds`).

## Smoke tests

```bash
# Service responding
curl -s http://localhost:3000/api/health

# Datasource provisioned
curl -s -u admin:admin http://localhost:3000/api/datasources | jq '.[].name'

# Dashboards provisioned (note: don't pass folderUIDs= empty — that means
# "no folder", but our dashboards are in the "LLM Stack" folder)
curl -s -u admin:admin "http://localhost:3000/api/search?type=dash-db" | jq '.[].title'

# Direct dashboard URL
echo "Open: http://localhost:3000/d/llm-overview/llm-overview"
echo "Open: http://localhost:3000/d/gpu-saturation/gpu-saturation"
```

## Where to look when it breaks

| Symptom | Likely cause | Fix |
| ------- | ------------ | --- |
| "No data" on every panel | Prometheus target DOWN for the source metric | Open `:9090/targets`; fix the offending exporter |
| One panel blank, others fine | Metric name changed (image bump) | `curl /metrics`, search for the new name, update the dashboard JSON or recording rule |
| Dashboard not appearing in UI | JSON has syntax error | `python3 -m json.tool <dashboard.json> >/dev/null`; also check `docker compose logs grafana | grep provision` |
| Datasource shows "test failed" | DNS — Prometheus container not on same network | Both should be on `llm-stack` network; check `docker network inspect llm-stack_llm-stack` |
| Edits in UI disappear after restart | Grafana DB cleared (e.g. `docker compose down -v`) | Use the export → commit flow above to persist |

## What's next

- Phase 1.2 adds the `mock-services` Prometheus target → a small extension
  to the LLM Overview dashboard (per-tool latency).
- Phase 1.3 walkthroughs cite specific panels — keep panel `id`s stable
  across edits to avoid broken inbound links.
