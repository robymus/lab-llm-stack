# Codebase reference

> Snapshot of what exists in the repo and how the pieces fit. Updated as
> phases land. For the *design*, read [.plans/llm-sandbox-PLAN.md](.plans/llm-sandbox-PLAN.md).
> For the *map*, read [ARCHITECTURE.md](ARCHITECTURE.md). This file answers
> "what concrete files do I look at?"

## Current state

**Phase 1.0 — Infra skeleton: implemented (compose validates; runtime
verification blocked on host toolkit install).**

Phases 1.1 (hardware obs), 1.2 (agent + traces), 1.3 (walkthrough docs),
1.4 (CI + polish) are pending.

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

### Services (stubs for later phases)
| Folder | Will arrive in | What's there now |
| ------ | -------------- | ---------------- |
| [prometheus/](prometheus/) | Phase 1.1 | Placeholder README + empty `rules/` |
| [grafana/](grafana/) | Phase 1.1 | Placeholder README + empty `provisioning/`, `dashboards/` |
| [dcgm/](dcgm/) | Phase 1.1 | Placeholder README |
| [app/](app/) | Phase 1.2 | Placeholder README |
| [mock-services/](mock-services/) | Phase 1.2 | Placeholder README |
| [docs/](docs/) | Phase 1.3 | Placeholder README |
| [.github/workflows/](.github/workflows/) | Phase 1.4 | Empty |

## Compose service map (Phase 1.0)

```
            ┌──────────────┐
host:8000 ──│ vllm-engine  │  Qwen2.5-3B-Instruct-AWQ on GPU
            │ (vllm v0.6.6)│
            └──────┬───────┘
                   │ http://vllm-engine:8000/v1
                   ▼
            ┌──────────────┐
host:4000 ──│   litellm    │  routes "qwen-chat" → vllm
            │ (main-stable)│  Phase 2 swap point lives in litellm/config.yaml
            └──────────────┘

            ┌──────────────┐
            │ langfuse-db  │  postgres:16-alpine (internal-only, no host port)
            └──────┬───────┘
                   │ postgresql://...@langfuse-db:5432
                   ▼
            ┌──────────────┐
host:3001 ──│   langfuse   │  Trace UI + OTLP endpoint (used in Phase 1.2)
            │  (v2 image)  │
            └──────────────┘
```

All four services share the `llm-stack` bridge network defined at the top
of [docker-compose.yaml](docker-compose.yaml). State (HF cache, Postgres
data, future Prometheus/Grafana state) lives in named volumes.

## Env vars in use

Loaded automatically from `.env`. The full list with comments is in
[.env.example](.env.example). For Phase 1.0, only these are required:

- `HF_TOKEN` — populated; used by vLLM for model download
- `LITELLM_MASTER_KEY` — auth on the gateway
- `LANGFUSE_DB_PASSWORD` — Postgres password
- `NEXTAUTH_SECRET`, `LANGFUSE_SALT` — Langfuse session signing + at-rest encryption

These come into play later but are already templated:
- `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`, `LANGFUSE_AUTH_B64` — set after first-run UI walkthrough; needed for Phase 1.2
- `OPENAI_API_BASE`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `MOCK_SERVICES_URL` — used by the agent app in Phase 1.2

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

- **Host needs `nvidia-container-toolkit`** before `docker compose up` can
  give vLLM GPU access. Preflight surfaces this; install commands in the
  preflight output. Surfaced to user for decision.
- **Langfuse API keys** must be created via the UI on first run, then
  pasted into `.env`. Preflight's `.env` step auto-computes
  `LANGFUSE_AUTH_B64` from the pair.
- **Image tags** for `vllm/vllm-openai:v0.6.6`, `ghcr.io/berriai/litellm:main-stable`,
  and `langfuse/langfuse:2` are best-current-guess. Phase 1.4 re-verifies
  against actual `docker pull` output.

## How to extend (Phase 1.1+)

1. Pick the next pending task in [.plans/llm-sandbox-TODO.md](.plans/llm-sandbox-TODO.md).
2. New service → add a block to `docker-compose.yaml` following the conventions
   in the file's header.
3. Every new service gets a `README.md` with the same five sections (*What*,
   *Why*, *Configuration*, *Smoke tests*, *Troubleshooting*).
4. After any compose edit, run `docker compose config -q` before committing.
5. Update this file (CODEBASE.md) when a placeholder folder becomes a real
   one.
