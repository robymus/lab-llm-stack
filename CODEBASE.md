# Codebase reference

> Snapshot of what exists in the repo and how the pieces fit. Updated as
> phases land. For the *design*, read [.plans/llm-sandbox-PLAN.md](.plans/llm-sandbox-PLAN.md).
> For the *map*, read [ARCHITECTURE.md](ARCHITECTURE.md). This file answers
> "what concrete files do I look at?"

## Current state

**Phases 1.0 + 1.1 + 1.2 + 1.3 + 1.4 + 2.0 + 2.1 + 2.2 + 2.3 implemented.**
Eighteen services healthy under `docker compose up -d` (after running
`scripts/pull-phase2-images.sh` once). Phase 2.2 routed the trace path
through an `otel-collector`. Phase 2.3 added the **third observability
pillar**: `loki` (single-binary, filesystem-backed, schema v13 + TSDB)
and `promtail` (docker-SD scraper) ship every compose container's
stdout into Loki, labelled by `service` / `project` / `container`. A
Loki datasource is provisioned alongside Prometheus, and a new
"LiteLLM access log (filtered)" logs panel lives at the bottom of the
LLM Overview dashboard. The `docs/05-trace-log-correlation.md`
walkthrough completes the cross-pillar story: open a trace in
Langfuse, copy its wall-clock window into Grafana, see the matching
`POST /chat/completions` log line for that exact request.

Deviations from the plan along the way (documented inline + in PLAN/TODO):
- Langfuse v2 doesn't speak OTLP → Langfuse-native LangChain callback
  instead of OpenLLMetry/Traceloop.
- vLLM needs `--enable-auto-tool-choice` and `--tool-call-parser hermes`
  for tool calling.
- Load tester uses **trunks** (Rust) not vegeta — `cargo install trunks`.
  Saturation profile is a single 90 s linear ramp instead of three
  discrete stages.
- LiteLLM `main-stable` is pinned by **manifest digest** (no clean
  semver tags published for that channel) — see VERSIONS.md for the
  bump procedure.

## Files by purpose

### Top-level
| File | What it is |
| ---- | ---------- |
| [README.md](README.md) | Quickstart, smoke tests, dev workflow (CI mirror), repo layout, troubleshooting |
| [ARCHITECTURE.md](ARCHITECTURE.md) | The map: layers, request flow, Phase 2 swap point, reading order |
| [VERSIONS.md](VERSIONS.md) | **Phase 1.4** — pinned image / action / dep audit trail with bump procedures |
| [INITIAL-PLAN.md](INITIAL-PLAN.md) | The original brief from the user (kept for context) |
| [docker-compose.yaml](docker-compose.yaml) | The wiring: networks, volumes, all services. Heavily commented. |
| [.env.example](.env.example) | Template for `.env`. Every var phase-tagged and commented. Reconciled in 1.4. |
| [.gitignore](.gitignore) | Keeps `.env`, container-mounted state, and Python noise out of git |
| [pyproject.toml](pyproject.toml) | **Phase 1.4** — ruff (lint + format) + pytest config |
| [.yamllint.yml](.yamllint.yml) | **Phase 1.4** — YAML lint rules |
| [.hadolint.yaml](.hadolint.yaml) | **Phase 1.4** — Dockerfile lint rules |
| [.pre-commit-config.yaml](.pre-commit-config.yaml) | **Phase 1.4** — local mirror of CI lint stage |

### Planning artefacts
| File | What it is |
| ---- | ---------- |
| [.plans/llm-sandbox-PLAN.md](.plans/llm-sandbox-PLAN.md) | Full design doc with trade-offs and resolved decisions |
| [.plans/llm-sandbox-TODO.md](.plans/llm-sandbox-TODO.md) | Phased task list; updated as work completes |

### Scripts
| File | What it does |
| ---- | ------------ |
| [scripts/preflight.sh](scripts/preflight.sh) | Verifies host has Docker, Compose, NVIDIA driver, container toolkit + registered runtime, ≥30 GB disk, and a `.env`. Reports whether the Langfuse public/secret keys are populated (Phase 1.2 readiness). |
| [scripts/cleanup.sh](scripts/cleanup.sh) | Wipes the sandbox: stops containers, drops the network and all named volumes, removes pulled images. Destructive — confirms before acting. Flags: `-y`, `--keep-images`, `--keep-cache`, `--help`. |
| [scripts/load.sh](scripts/load.sh) | Load tester driven by `trunks` (Rust port of vegeta — `cargo install trunks`). Seven profiles: smoke / short / decode-heavy / prefill-heavy / prefix-cache / mixed / saturation. Curated prompt sets (~40 prompts across categories) baked into the script; targets file + JSON payloads generated on the fly. Per-run binary + CSV under `/tmp/load-<profile>-<ts>/`. |
| [scripts/pull-phase2-images.sh](scripts/pull-phase2-images.sh) | **Phase 2.0** — one-shot prefetch of every Phase 2 container image. Pulls Triton (~25 GB, longest pole), Langfuse v3 web + worker, ClickHouse alpine, Redis alpine, Minio, OTel Collector, Loki, Promtail. Checks ≥45 GB free on the docker root first; idempotent so re-runs only fetch what's missing. |

### Services (live in 2.2)
| Folder | Implementation status | Key files |
| ------ | --------------------- | --------- |
| [otel/](otel/) | **Phase 2.2** — collector service in compose, config + README. Routes OTLP/HTTP from the agent to Langfuse v3 with basicauth + batching + attribute remapping. | [otel/config.yaml](otel/config.yaml), [otel/README.md](otel/README.md) |

### Services (live in 2.3)
| Folder | Implementation status | Key files |
| ------ | --------------------- | --------- |
| [loki/](loki/) | **Phase 2.3** — single-binary log aggregator. Schema v13 + TSDB index, filesystem chunks on the `loki-data` volume, 7-day retention enforced by the compactor. | [loki/loki.yaml](loki/loki.yaml), [loki/README.md](loki/README.md) |
| [promtail/](promtail/) | **Phase 2.3** — docker-SD log scraper. Tails every compose container's stdout/stderr, labels by `service` / `project` / `container`, unwraps Docker's `json-file` log driver via the `docker:` pipeline stage. | [promtail/promtail.yaml](promtail/promtail.yaml), [promtail/README.md](promtail/README.md) |

### Services (live in 1.0)
| Folder | Implementation status | Key files |
| ------ | --------------------- | --------- |
| [vllm/](vllm/) | Service in compose, README done | [vllm/README.md](vllm/README.md) |
| [litellm/](litellm/) | Service + config + README done | [litellm/config.yaml](litellm/config.yaml), [litellm/README.md](litellm/README.md) |
| [langfuse/](langfuse/) | **Phase 2.1** — six services in compose (v3 ingest cluster: web + worker + db + clickhouse + redis + minio). README rewritten for v3 architecture, env crib updated. | [langfuse/README.md](langfuse/README.md), [langfuse/.env.langfuse.example](langfuse/.env.langfuse.example) |

### Services (live in 1.1)
| Folder | Implementation status | Key files |
| ------ | --------------------- | --------- |
| [dcgm/](dcgm/) | Service in compose, custom metric CSV, README done | [dcgm/dcp-metrics-included.csv](dcgm/dcp-metrics-included.csv), [dcgm/README.md](dcgm/README.md) |
| [prometheus/](prometheus/) | Service + scrape config + recording rules + README | [prometheus/prometheus.yml](prometheus/prometheus.yml), [prometheus/rules/llm.rules.yml](prometheus/rules/llm.rules.yml), [prometheus/README.md](prometheus/README.md) |
| [grafana/](grafana/) | Service + provisioning + 2 dashboards + README | [grafana/provisioning/](grafana/provisioning/), [grafana/dashboards/01-llm-overview.json](grafana/dashboards/01-llm-overview.json), [grafana/dashboards/02-gpu-saturation.json](grafana/dashboards/02-gpu-saturation.json), [grafana/README.md](grafana/README.md) |
| `node-exporter`, `cadvisor` | Services in compose only — no per-service config beyond mounts. Notes live inline in [docker-compose.yaml](docker-compose.yaml). | — |

### Services (live in 1.2)
| Folder | Implementation status | Key files |
| ------ | --------------------- | --------- |
| [mock-services/](mock-services/) | FastAPI app with 5 endpoints + `/metrics` + Prometheus scrape job + README + tests (1.4) | [mock-services/main.py](mock-services/main.py), [mock-services/Dockerfile](mock-services/Dockerfile), [mock-services/README.md](mock-services/README.md), [mock-services/tests/test_endpoints.py](mock-services/tests/test_endpoints.py), [mock-services/requirements-dev.txt](mock-services/requirements-dev.txt) |
| [app/](app/) | Streamlit + LangChain agent + 5 tools + tracing via **traceloop-sdk → OTLP** (Phase 2.2) + README + tests (1.4). Phase 1.2 used `langfuse.CallbackHandler`; Phase 2.2 swapped it for `Traceloop.init(...)` + `HTTPXClientInstrumentor` + `Traceloop.set_association_properties({"user_id": ...})`. | [app/app.py](app/app.py), [app/agent.py](app/agent.py), [app/tools.py](app/tools.py), [app/Dockerfile](app/Dockerfile), [app/README.md](app/README.md), [app/tests/test_tools.py](app/tests/test_tools.py), [app/requirements-dev.txt](app/requirements-dev.txt) |

### Walkthrough docs (live in 1.3, extended in 2.3)
| File | What it covers |
| ---- | -------------- |
| [docs/README.md](docs/README.md) | Index — read these in order |
| [docs/01-getting-started.md](docs/01-getting-started.md) | First-run smoke tests, per-layer curls, multi-tenancy demo, URL reference card |
| [docs/02-anatomy-of-a-request.md](docs/02-anatomy-of-a-request.md) | One multi-tool prompt traced through every layer with the resulting spans + metrics |
| [docs/03-saturation-analysis.md](docs/03-saturation-analysis.md) | All 7 `scripts/load.sh` profiles explained, what to watch on which dashboard, how to read a trunks report |
| [docs/04-trace-metric-correlation.md](docs/04-trace-metric-correlation.md) | The headline lesson — pick one trace, find its GPU power signature, see prefill vs decode burstiness |
| [docs/05-trace-log-correlation.md](docs/05-trace-log-correlation.md) | **Phase 2.3** — same trace, same wall-clock window, now overlaid on the LiteLLM access log panel + a tour of `{service="…"}` queries for every container |

### CI (live in 1.4)
| File | What it is |
| ---- | ---------- |
| [.github/workflows/ci.yml](.github/workflows/ci.yml) | Three parallel jobs — `lint` (yamllint + jq + ruff), `dockerfiles` (hadolint + `docker compose config -q`), `tests` (matrixed pytest for both services). Every third-party action pinned to a commit SHA. |

## Compose service map (Phases 1.0 + 1.1 + 1.2)

```
  --- App layer (Phase 1.2) ---------------------------------------------
            ┌──────────────┐
host:8501 ──│  app         │  Streamlit + LangChain (5 tools)
            │  (python)    │  Langfuse CallbackHandler attached via invoke config
            └──┬────────┬──┘
               │        │ HTTP /v1/chat/completions     ┌──────────────┐
               │        └──────────────────────────────▶│   litellm    │
               │ HTTP tool calls                        └──────────────┘
               ▼
            ┌──────────────┐
host:9000 ──│ mock-services│  FastAPI: /weather /news /stocks /docs /flaky + /metrics
            │  (python)    │
            └──────────────┘

  --- LLM serving plane -------------------------------------------------
            ┌──────────────┐
host:8000 ──│ vllm-engine  │  Qwen2.5-3B-Instruct-AWQ on GPU
            │ v0.6.6       │  /metrics native; tool-calling enabled (hermes)
            └──────┬───────┘
                   │ http://vllm-engine:8000/v1
                   ▼
            ┌──────────────┐
host:4000 ──│   litellm    │  routes "qwen-chat" → vllm
            │ main-stable  │  /metrics/ (trailing slash!)
            └──────────────┘                Phase 2 swap point: litellm/config.yaml

  --- Trace store (Phase 2.1 — Langfuse v3 cluster) ---------------------
            ┌──────────────┐    ┌────────────────────┐    ┌──────────────┐
            │ langfuse-db  │    │ langfuse-clickhouse│    │ langfuse-redis│
            │ postgres-16  │    │ 24.10-alpine       │    │ 7-alpine      │
            │ (metadata)   │    │ (spans, columnar)  │    │ (ingest queue)│
            └──────┬───────┘    └─────────┬──────────┘    └──────┬───────┘
                   │                      │                      │
                   │            ┌─────────┴──────────┐           │
                   │            │   langfuse-minio   │           │
                   │            │   (S3 staging)     │           │
                   │            └─────────┬──────────┘           │
                   │                      │                      │
                   └──┬─────────┬─────────┴─────────┬────────────┘
                      ▼         ▼                   ▼
              ┌──────────────┐                ┌──────────────────┐
host:3001 ── │   langfuse   │                │ langfuse-worker  │
             │ v3 (web/UI)  │ ─OTLP/HTTP─────│ drain Redis,     │
             │ enqueue+S3   │  to /api/      │ insert into CH+PG │
             └──────────────┘   public/otel  └──────────────────┘

  --- Observability plane (Phase 1.1) -----------------------------------
            ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
host:9400 ──│ dcgm-exporter│  │ node-exporter│  │   cadvisor   │
            │ 3.3.9-3.6.1  │  │   v1.8.2     │  │   v0.49.2    │
            │ GPU metrics  │  │ host OS      │  │ per-container│
            └──────┬───────┘  └──────┬───────┘  └──────┬───────┘
                   │                 │                 │
                   ▼                 ▼                 ▼
            ┌─────────────────────────────────────────────────┐
host:9090 ──│              prometheus  v3.1.0                  │
            │  7 scrape jobs, recording rules every 15s        │
            │  (vllm, litellm, dcgm, node, cadvisor,           │
            │   mock-services, prometheus)                     │
            └────────────────────────┬────────────────────────┘
                                     │ proxy queries
                                     ▼
                              ┌──────────────┐
host:3000 ──────────────────  │   grafana    │  anonymous read
                              │   11.4.0     │  2 provisioned dashboards
                              └──────────────┘
```

All services share the `llm-stack` bridge network defined at the top
of [docker-compose.yaml](docker-compose.yaml). State (HF cache, Postgres
data, Prometheus TSDB, Grafana SQLite) lives in named volumes.

### URLs
- Streamlit chat: <http://localhost:8501>
- Langfuse traces: <http://localhost:3001>
- LLM Overview dashboard: <http://localhost:3000/d/llm-overview/llm-overview>
- GPU Saturation dashboard: <http://localhost:3000/d/gpu-saturation/gpu-saturation>
- Prometheus targets: <http://localhost:9090/targets>
- Loki API + readiness: <http://localhost:3100/ready>
- Grafana Explore (Loki): <http://localhost:3000/explore?left=%7B%22datasource%22%3A%22loki%22%7D>

## Env vars in use

Loaded automatically from `.env`. The full list with comments is in
[.env.example](.env.example). For Phase 1.0, only these are required:

- `HF_TOKEN` — populated; used by vLLM for model download
- `LITELLM_MASTER_KEY` — auth on the gateway
- `LANGFUSE_DB_PASSWORD` — Postgres password
- `NEXTAUTH_SECRET`, `LANGFUSE_SALT` — Langfuse session signing + at-rest encryption

Phase 1.2 adds:
- `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` — read by the app at startup to construct the Langfuse `CallbackHandler`
- `OPENAI_API_BASE`, `MOCK_SERVICES_URL` — set in the app compose env, override the `.env` defaults (`.env` values are for running the app outside compose)

Phase 1.4 cleanup: `LANGFUSE_AUTH_B64` and `OTEL_EXPORTER_OTLP_ENDPOINT` were
removed from `.env.example` and `preflight.sh` (originally-planned OpenLLMetry/OTLP
path that v2 didn't support). `OTEL_EXPORTER_OTLP_ENDPOINT` returns in Phase 2.2.

Phase 2.2 adds:
- `OTEL_EXPORTER_OTLP_ENDPOINT` — re-introduced (deleted in 1.4 cleanup).
  Inside compose, `app` is hardcoded to `http://otel-collector:4318` in
  the service env. The `.env` value is for host-side runs only.
- `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`, `OTEL_SERVICE_NAME=llm-sandbox-app`,
  `TRACELOOP_METRICS_ENABLED=false` — set on the `app` service env block
  in `docker-compose.yaml` (not in `.env`).
- `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` — still in `.env`, but
  now consumed by the `otel-collector` service (its `basicauth/langfuse`
  extension), not by `app`.

Phase 2.1 adds (all read via the `x-langfuse-env` YAML anchor in compose):
- `CLICKHOUSE_PASSWORD` — Langfuse ClickHouse user `langfuse` password
- `REDIS_PASSWORD` — Langfuse Redis `requirepass` + worker/web `REDIS_AUTH`
- `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD` — Minio root creds, surfaced
  to Langfuse as `LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID/_SECRET_ACCESS_KEY`
- `LANGFUSE_ENCRYPTION_KEY` — 64 hex chars, required by v3 for column-
  level encryption of integration creds. **Do not rotate after first write.**
  Preflight validates shape (regex `^[0-9a-fA-F]{64}$`).

## Conventions worth knowing

1. **Service-name DNS over `localhost`.** Inside the network, everything
   talks via `http://<service>:<port>`. Host `localhost:<port>` only for
   you-on-the-host access.
2. **Healthchecks gate dependents.** Every service that has consumers
   defines a healthcheck; consumers use `depends_on: { ...: { condition:
   service_healthy } }`. Removes startup races.
3. **Named volumes for state.** Bind mounts only for *config* (read-only),
   not state. Keeps `git status` clean and dodges permission issues.
4. **Pinned image tags + actions + Python deps.** See [VERSIONS.md](VERSIONS.md).
   Every bump is a deliberate commit with a one-line note in that file.
5. **Secrets only via `.env`.** Compose loads it automatically; configs
   reference them via `${VAR}` or LiteLLM's `os.environ/VAR` syntax.
6. **CI mirrors local checks.** `.pre-commit-config.yaml` runs the same
   linters as the `lint` job in CI (ruff, yamllint, hadolint). Tests run
   in CI only — both services have their own `requirements-dev.txt`.

## Known blockers / open items

- **Langfuse API keys** must be created via the UI on first run, then
  pasted into `.env`. Preflight reports whether they're set. *(Done on this host.)*
- **DCP profiling (`DCGM_FI_PROF_*`)** is gated to data-centre GPUs and
  unavailable on the 4060. Dashboards use `DEV_GPU_UTIL` + `SM_CLOCK` as
  substitutes. To unlock the better saturation metrics on an A100/H100/L40,
  uncomment the four PROF_* lines in `dcgm/dcp-metrics-included.csv`.
- **LiteLLM `/metrics` requires trailing slash** — handled in Prometheus
  scrape config; worth knowing if you ever poke it by hand.
- **OTLP/HTTP** is reachable on Langfuse v3 at
  `http://localhost:3001/api/public/otel/v1/traces` (401 without auth —
  the otel-collector adds the basic-auth headers). The agent app now
  pushes traces to `http://otel-collector:4318` via traceloop-sdk; the
  collector forwards to Langfuse. Httpx sub-spans under each tool span
  are visible in the Langfuse UI. The native `userId` field is
  populated via the collector's `langfuse.user.id` attribute mapping.
- **Tokens field on Generations reads 0/0/0** in Langfuse v3 — OpenLLMetry's
  instrumentors (0.60.x) don't translate vLLM's returned `usage.*_tokens`
  into the OTel `gen_ai.usage.*` attributes Langfuse reads. A LangChain-callback
  bridge attempt didn't work (the OpenLLMetry span has already ended by
  the time `on_llm_end` fires). Token counts are visible elsewhere: LiteLLM's
  Prometheus `/metrics/` (`litellm_*_tokens_metric`), vLLM's `vllm:*_tokens_total`,
  and the existing Grafana "Tokens / second" panel. Documented in
  `app/agent.py`'s top-of-module comment and `app/README.md`.
- **LiteLLM per-`end_user` Prometheus label** needs virtual API keys to
  actually split; for Phase 1 the per-user view lives in Langfuse, where
  `user_id`/`session_id` are first-class filters.

## Observability quick-reference

| Question | Where to look |
| -------- | ------------- |
| Is the gateway healthy? | <http://localhost:3000/d/llm-overview/llm-overview> panel "Request rate" + "p50/p95 latency" |
| Is the GPU saturated? | <http://localhost:3000/d/gpu-saturation/gpu-saturation> panel "Power ↔ p95 latency" |
| KV cache filling up? | LLM Overview, "KV cache usage" gauge |
| Are all Prometheus targets up? | <http://localhost:9090/targets> |
| Why is a target down? | `docker compose logs <service>` |
| Discover a metric's exact name | `curl <service>/metrics | grep ^# HELP` (LiteLLM needs trailing slash on `/metrics/`) |
| **What did user X do?** | Langfuse → filter by `user_id` |
| **What did the agent actually decide?** | Langfuse → trace tree shows chain → llm → tool spans |
| **How long did the weather tool take?** | <http://localhost:9090/graph?g0.expr=histogram_quantile(0.95%2C%20sum%20by%20(handler%2C%20le)%20(rate(http_request_duration_seconds_bucket%7Bjob%3D%22mock-services%22%7D%5B1m%5D)))> |

## How to extend (Phase 1.3+)

1. Pick the next pending task in [.plans/llm-sandbox-TODO.md](.plans/llm-sandbox-TODO.md).
2. New service → add a block to `docker-compose.yaml` following the conventions
   in the file's header.
3. Every new service gets a `README.md` with the same five sections (*What*,
   *Why*, *Configuration*, *Smoke tests*, *Troubleshooting*).
4. After any compose edit, run `docker compose config -q` before committing.
5. Update this file (CODEBASE.md) when a placeholder folder becomes a real
   one.
