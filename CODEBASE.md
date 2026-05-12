# Codebase reference

> Snapshot of what exists in the repo and how the pieces fit. Updated as
> phases land. For the *design*, read [.plans/llm-sandbox-PLAN.md](.plans/llm-sandbox-PLAN.md).
> For the *map*, read [ARCHITECTURE.md](ARCHITECTURE.md). This file answers
> "what concrete files do I look at?"

## Current state

**Phases 1.0 + 1.1 + 1.2 implemented.** Eleven services healthy under
`docker compose up -d`: vLLM, LiteLLM, Langfuse (web + Postgres), DCGM
exporter, node-exporter, cAdvisor, Prometheus, Grafana, mock-services,
agent app. Streamlit chat → LangChain agent (5 tools) → mock-services
produces trace trees in Langfuse with chain/llm/tool spans, grouped by
user_id.

Two material deviations from the plan landed in Phase 1.2 (both
documented in PLAN §5.1, §5.7 and in `app/README.md`):
- Langfuse v2 doesn't speak OTLP → use the Langfuse-native LangChain
  callback handler instead of OpenLLMetry/Traceloop.
- vLLM needs `--enable-auto-tool-choice` and `--tool-call-parser hermes`
  for tool calling to work.

Phases 1.3 (walkthrough docs) and 1.4 (CI + polish) are pending.

## Files by purpose

### Top-level
| File | What it is |
| ---- | ---------- |
| [README.md](README.md) | Quickstart, smoke tests, repo layout, troubleshooting entry point |
| [ARCHITECTURE.md](ARCHITECTURE.md) | The map: layers, request flow, Phase 2 swap point, reading order |
| [INITIAL-PLAN.md](INITIAL-PLAN.md) | The original brief from the user (kept for context) |
| [docker-compose.yaml](docker-compose.yaml) | The wiring: networks, volumes, all services. Heavily commented. |
| [.env.example](.env.example) | Template for `.env`. Every var phase-tagged and commented. |
| [.gitignore](.gitignore) | Keeps `.env`, container-mounted state, and Python noise out of git |

### Planning artefacts
| File | What it is |
| ---- | ---------- |
| [.plans/llm-sandbox-PLAN.md](.plans/llm-sandbox-PLAN.md) | Full design doc with trade-offs and resolved decisions |
| [.plans/llm-sandbox-TODO.md](.plans/llm-sandbox-TODO.md) | Phased task list; updated as work completes |

### Scripts
| File | What it does |
| ---- | ------------ |
| [scripts/preflight.sh](scripts/preflight.sh) | Verifies host has Docker, Compose, NVIDIA driver, container toolkit + registered runtime, ≥30 GB disk, and a `.env`. Computes `LANGFUSE_AUTH_B64` automatically when both Langfuse keys are populated. |
| [scripts/cleanup.sh](scripts/cleanup.sh) | Wipes the sandbox: stops containers, drops the network and all named volumes, removes pulled images. Destructive — confirms before acting. Flags: `-y`, `--keep-images`, `--keep-cache`, `--help`. |

### Services (live in 1.0)
| Folder | Implementation status | Key files |
| ------ | --------------------- | --------- |
| [vllm/](vllm/) | Service in compose, README done | [vllm/README.md](vllm/README.md) |
| [litellm/](litellm/) | Service + config + README done | [litellm/config.yaml](litellm/config.yaml), [litellm/README.md](litellm/README.md) |
| [langfuse/](langfuse/) | Two services in compose, README + env crib done | [langfuse/README.md](langfuse/README.md), [langfuse/.env.langfuse.example](langfuse/.env.langfuse.example) |

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
| [mock-services/](mock-services/) | FastAPI app with 5 endpoints + `/metrics` + Prometheus scrape job + README | [mock-services/main.py](mock-services/main.py), [mock-services/Dockerfile](mock-services/Dockerfile), [mock-services/README.md](mock-services/README.md) |
| [app/](app/) | Streamlit + LangChain agent + 5 tools + Langfuse `CallbackHandler` + README | [app/app.py](app/app.py), [app/agent.py](app/agent.py), [app/tools.py](app/tools.py), [app/Dockerfile](app/Dockerfile), [app/README.md](app/README.md) |

### Services (stubs for later phases)
| Folder | Will arrive in | What's there now |
| ------ | -------------- | ---------------- |
| [docs/](docs/) | Phase 1.3 | Placeholder README |
| [.github/workflows/](.github/workflows/) | Phase 1.4 | Empty |

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

  --- Trace store -------------------------------------------------------
            ┌──────────────┐
            │ langfuse-db  │  postgres:16-alpine (no host port)
            └──────┬───────┘
                   ▼
            ┌──────────────┐
host:3001 ──│   langfuse   │  v2: trace UI + OTLP ingestion
            └──────────────┘

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

`LANGFUSE_AUTH_B64` was added during Phase 1.0 for the originally-planned OTLP path; **no longer used** since Phase 1.2 switched to the native Langfuse SDK. Leave it in `.env` — preflight still computes it from the pair, and it'd come back if we ever upgrade to Langfuse v3.

## Conventions worth knowing

1. **Service-name DNS over `localhost`.** Inside the network, everything
   talks via `http://<service>:<port>`. Host `localhost:<port>` only for
   you-on-the-host access.
2. **Healthchecks gate dependents.** Every service that has consumers
   defines a healthcheck; consumers use `depends_on: { ...: { condition:
   service_healthy } }`. Removes startup races.
3. **Named volumes for state.** Bind mounts only for *config* (read-only),
   not state. Keeps `git status` clean and dodges permission issues.
4. **Pinned image tags.** Phase 1.4 does the final pin pass; until then
   any tag change should come with a comment about what was retested.
5. **Secrets only via `.env`.** Compose loads it automatically; configs
   reference them via `${VAR}` or LiteLLM's `os.environ/VAR` syntax.

## Known blockers / open items

- **Langfuse API keys** must be created via the UI on first run, then
  pasted into `.env`. Preflight's `.env` step auto-computes
  `LANGFUSE_AUTH_B64` from the pair. *(Done on this host.)*
- **DCP profiling (`DCGM_FI_PROF_*`)** is gated to data-centre GPUs and
  unavailable on the 4060. Dashboards use `DEV_GPU_UTIL` + `SM_CLOCK` as
  substitutes. To unlock the better saturation metrics on an A100/H100/L40,
  uncomment the four PROF_* lines in `dcgm/dcp-metrics-included.csv`.
- **Image tags** are best-current-guess; Phase 1.4 re-verifies them.
- **LiteLLM `/metrics` requires trailing slash** — handled in Prometheus
  scrape config; worth knowing if you ever poke it by hand.
- **Langfuse v2 doesn't support OTLP/HTTP** — we use the native LangChain
  callback handler instead. Side-effect: httpx sub-spans under tool spans
  aren't visible in Langfuse (workaround: per-handler latency from
  `mock-services/metrics` covers the same ground from a different angle).
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
