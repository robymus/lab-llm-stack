# Architecture

> What's running, why, and where to look first. Per-layer detail lives in
> each service's `README.md`; this doc is the map.

## High-level shape

```
┌────────────────────────────────────────────────────────────────────────┐
│  Browser                                                                │
│    │                                                                    │
│    ▼                                                                    │
│  ┌──────────────┐                                                       │
│  │  Streamlit   │  Phase 1.2                                            │
│  │  chat UI     │  ─ asks for X-User-Id at session start                │
│  └──────┬───────┘                                                       │
│         │ OpenAI-compatible HTTP, X-User-Id in extra_headers            │
│         ▼                                                               │
│  ┌──────────────┐         ┌──────────────────────────────┐              │
│  │  LangChain   │ ──HTTP─▶│  mock-services (FastAPI)     │  Phase 1.2   │
│  │  agent       │         │  /weather /news /stocks      │              │
│  │              │         │  /docs/search  /flaky        │              │
│  │  multi-tool, OpenLLMetry-instrumented (LLM + httpx)   │              │
│  └──────┬───────┘         └──────────────────────────────┘              │
│         │ POST /v1/chat/completions                                     │
│         ▼                                                               │
│  ┌──────────────┐  ─ exposes :4000 OpenAI-compatible API                │
│  │   LiteLLM    │  ─ /metrics for Prometheus                            │
│  │   gateway    │  ─ routes "qwen-chat" → vllm-engine:8000              │
│  │              │  ★ the Phase 2 swap point                             │
│  └──────┬───────┘                                                       │
│         │ POST /v1/chat/completions                                     │
│         ▼                                                               │
│  ┌──────────────┐  :8000  ─  /metrics (Prometheus, native)              │
│  │     vLLM     │  Qwen2.5-3B-Instruct-AWQ on RTX 4060 (8 GB)           │
│  │   engine     │                                                       │
│  └──────────────┘                                                       │
│                                                                         │
│  ════════════════════ OBSERVABILITY PLANE ═══════════════════════════   │
│                                                                         │
│  Metrics (pull):     Phase 1.0 + 1.1                                    │
│    Prometheus ── scrapes ── { vllm:8000, litellm:4000,                  │
│                               dcgm-exporter:9400,                       │
│                               node-exporter:9100,                       │
│                               cadvisor:8080,                            │
│                               mock-services:9000 }                      │
│    Grafana   ── queries ── Prometheus                                   │
│                                                                         │
│  Traces (push):      Phase 1.2                                          │
│    app  ── OTLP/HTTP ── Langfuse (/api/public/otel)                     │
│    Langfuse ── stores → Postgres                                        │
└────────────────────────────────────────────────────────────────────────┘
```

## Layers, in dependency order

| # | Layer | Service(s) | Job | Deep dive |
| - | ----- | ---------- | --- | --------- |
| 1 | Inference | `vllm-engine` | Loads weights, runs forward passes, exposes `/v1/chat/completions` and `/metrics`. | [vllm/README.md](vllm/README.md) |
| 2 | Gateway | `litellm` | One OpenAI-compatible API, routes logical model names to backends. Phase 2 swap point. | [litellm/README.md](litellm/README.md) |
| 3 | Tool backend | `mock-services` (Phase 1.2) | FastAPI app the agent's tools call. Makes HTTP spans visible in traces. | [mock-services/README.md](mock-services/README.md) *(stubbed until 1.2)* |
| 4 | App | `app` (Phase 1.2) | Streamlit + LangChain agent + OpenLLMetry. Generates the traces. | [app/README.md](app/README.md) *(stubbed until 1.2)* |
| 5 | Trace store | `langfuse`, `langfuse-db` | Receives OTLP, presents trace trees, stores in Postgres. | [langfuse/README.md](langfuse/README.md) |
| 6 | Metrics | `prometheus` (Phase 1.1) | Scrapes everything emitting `/metrics`, evaluates recording rules. | [prometheus/README.md](prometheus/README.md) *(stubbed until 1.1)* |
| 7 | Dashboards | `grafana` (Phase 1.1) | Visualises the metrics, datasource provisioned from git. | [grafana/README.md](grafana/README.md) *(stubbed until 1.1)* |
| 8 | Hardware telemetry | `dcgm-exporter`, `node-exporter`, `cadvisor` (Phase 1.1) | GPU / host / container Prometheus exporters. | [dcgm/README.md](dcgm/README.md) *(stubbed until 1.1)* |

## How a request flows

Phase 1.0 (now): the app doesn't exist yet, so requests come from `curl`.

```
   curl ──HTTP──▶ litellm:4000  ──HTTP──▶ vllm-engine:8000  ──CUDA──▶ GPU
                       │                          │
                       └──/metrics (Phase 1.1)────┘
```

Phase 1.2 (later): the agent app makes it interesting.

```
  Streamlit
     │ (Streamlit native)
     ▼
  LangChain agent ──┬──HTTP──▶ litellm  ──▶ vllm-engine  ──▶ GPU
                   │           │
                   │           └──header X-User-Id forwarded all the way
                   │
                   ├──HTTP──▶ mock-services  (when the model picks a tool)
                   │
                   └──OTLP/HTTP──▶ langfuse  (trace export, every step)
```

## The Phase 2 swap point

Triton + TensorRT-LLM will be added as a second backend. The total change
needed:

1. New `services.triton` block in `docker-compose.yaml`.
2. Second entry in `litellm/config.yaml`:
   ```yaml
   - model_name: qwen-chat-trt
     litellm_params:
       model: openai/ensemble
       api_base: http://triton:8000/v2
   ```
3. App-side: change `model="qwen-chat"` to `model="qwen-chat-trt"`.

Nothing else moves. Same metrics dashboards. Same trace UI. That's the
orchestration lesson.

## Reading order for a newcomer

1. This file.
2. [vllm/README.md](vllm/README.md) — the layer doing actual GPU work.
3. [litellm/README.md](litellm/README.md) — the seam.
4. [langfuse/README.md](langfuse/README.md) — where traces go.
5. (after Phase 1.1) `prometheus/`, `grafana/`, `dcgm/`.
6. (after Phase 1.2) `app/`, `mock-services/`.
7. `docs/02-anatomy-of-a-request.md` — pulls all of the above together.

## Conventions

- **Service-name DNS, not localhost.** Inside the network, every service is
  reachable as `http://<service-name>:<container-port>`. `localhost` is only
  used from the host shell.
- **Healthchecks on every long-lived service**, with `depends_on:
  service_healthy` for the consumer. This makes `docker compose up` wait
  the right amount of time without manual sleeps.
- **State in named volumes, not bind mounts.** Avoids permission churn
  and keeps `git status` clean.
- **Pinned image tags.** Phase 1.4 re-verifies versions; until then, bumps
  are commit-with-rationale events.
- **Secrets in `.env`, never inline.** Compose loads `.env` automatically;
  every committed config that needs a secret reads it via `${VAR}` or
  LiteLLM's `os.environ/VAR` syntax.
