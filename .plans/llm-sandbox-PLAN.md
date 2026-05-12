# LLM SRE Sandbox — Phase 1 Plan

> Status: **REVIEWED — open questions resolved, ready to break into a TODO**
> Scope: Phase 1 only. vLLM as the sole inference backend. Triton + TensorRT-LLM is deferred to Phase 2.
> Primary goal: **learn how the layers of an LLM serving stack fit together and how to observe each one.** Documentation and inline commentary are first-class deliverables, on par with the running code.

---

## 1. Learning objectives

These are the lenses everything else hangs off. Every component is chosen because it teaches one of these:

1. **Layer separation.** Understand each layer (UI → orchestrator → gateway → engine → hardware) as a black box with a clear API, so the inference backend can be swapped in Phase 2 without touching the app.
2. **The two pillars (Phase 1):**
   - *Metrics* — Prometheus scrape model, exporters, PromQL, Grafana panels.
   - *Traces* — OpenTelemetry SDK + auto-instrumentation, span hierarchies, propagation across services.
3. **Correlation.** Overlay LLM latency (gateway) with GPU power and SM activity (DCGM) on the same time axis. See the prefill/decode burstiness with your own eyes.
4. **Saturation.** Drive enough load that vLLM batching kicks in. Read the right metrics to recognise it (`vllm:num_requests_running`, `vllm:gpu_cache_usage_perc`, KV cache hit rate, DCGM SM occupancy).
5. **Multi-tenancy hooks.** Pass an `X-User-Id` header end-to-end. See it in Langfuse traces and in LiteLLM logs. Foundation for cost-per-user and per-user rate limiting later.

Anything that doesn't serve one of these is out of scope for Phase 1.

---

## 2. Hardware constraints & model choice

**GPU:** RTX 4060, 8 GB VRAM (laptop or desktop class), compute capability 8.9 (Ada).

8 GB is the dominant constraint. The original plan's `Llama-3-8B-Instruct-AWQ` would technically load (~4.5 GB for AWQ weights) but leave so little headroom for KV cache that batching tests would just OOM. We swap to a smaller AWQ-quantised model:

**Primary model:** `Qwen/Qwen2.5-3B-Instruct-AWQ`
- ~2.2 GB weights in AWQ-INT4.
- Strong tool-calling support (matters for the agent step).
- Leaves ~5 GB for KV cache → meaningful batching headroom.
- vLLM flags (in `docker-compose.yaml`):
  ```
  --model Qwen/Qwen2.5-3B-Instruct-AWQ
  --quantization awq_marlin       # fast AWQ kernel for Ada
  --max-model-len 4096            # keep KV cache bounded
  --gpu-memory-utilization 0.85
  --enable-prefix-caching         # so we can see prefix cache hits in metrics
  --served-model-name qwen-chat   # stable alias used in LiteLLM config
  ```

**Trade-off:** A 3B model hallucinates more than 8B. Acceptable — the lab is about *observing the system*, not the quality of answers. If a heavier model is wanted later, `meta-llama/Llama-3.1-8B-Instruct-AWQ-INT4` with `--max-model-len 2048` and `--gpu-memory-utilization 0.92` is the fallback (almost no batching headroom, but it'll run for single-stream demos).

---

## 3. Architecture

```
┌────────────────────────────────────────────────────────────────────────┐
│  Browser                                                                │
│    │                                                                    │
│    ▼                                                                    │
│  ┌──────────────┐                                                       │
│  │  Streamlit   │  app/app.py                                           │
│  │  chat UI     │  ─ asks for X-User-Id at session start                │
│  └──────┬───────┘                                                       │
│         │ OpenAI-compatible HTTP, X-User-Id passed as extra_headers     │
│         ▼                                                               │
│  ┌──────────────┐         ┌──────────────────────────────┐              │
│  │  LangChain   │ ──HTTP─▶│  mock-services (FastAPI)     │              │
│  │  agent       │         │  /weather  /news  /stocks    │              │
│  │              │         │  /docs/search  /flaky        │              │
│  │  app/agent.py│         └──────────────────────────────┘              │
│  │  ─ multi-tool, OpenLLMetry-instrumented (LLM + httpx spans) → OTLP   │
│  └──────┬───────┘                                                       │
│         │ POST /v1/chat/completions                                     │
│         ▼                                                               │
│  ┌──────────────┐                                                       │
│  │   LiteLLM    │  litellm/config.yaml                                  │
│  │   gateway    │  ─ exposes :4000 OpenAI-compatible API                │
│  │              │  ─ /metrics for Prometheus                            │
│  │              │  ─ routes "qwen-chat" → vllm-engine:8000              │
│  └──────┬───────┘                                                       │
│         │ POST /v1/chat/completions                                     │
│         ▼                                                               │
│  ┌──────────────┐                                                       │
│  │     vLLM     │  :8000  ─  /metrics in Prometheus format              │
│  │   engine     │  ─ Qwen2.5-3B-Instruct-AWQ                            │
│  └──────────────┘                                                       │
│                                                                         │
│  ════════════════════ OBSERVABILITY PLANE ═══════════════════════════   │
│                                                                         │
│  Metrics (pull):                                                        │
│    Prometheus ── scrapes ── { vllm:8000, litellm:4000,                  │
│                               dcgm-exporter:9400,                       │
│                               node-exporter:9100,                       │
│                               cadvisor:8080 }                           │
│    Grafana   ── queries ── Prometheus                                   │
│                                                                         │
│  Traces (push):                                                         │
│    app  ── OTLP/HTTP ── Langfuse (/api/public/otel)                     │
│    Langfuse ── stores → Postgres                                        │
└────────────────────────────────────────────────────────────────────────┘
```

**Why this shape:**
- **LiteLLM in the middle** is non-negotiable. Without it, the app talks to vLLM directly and Phase 2 (Triton) becomes an app rewrite. With it, swap is one YAML line. This *is* the orchestration-layer lesson.
- **DCGM + node-exporter + cAdvisor** together give the three layers of host telemetry: GPU, host OS, individual container. Real production stacks all have these three.
- **Langfuse as OTLP sink** means we use the OpenTelemetry standard end-to-end and Langfuse just happens to be the backend. Same OTel SDK code would work against Jaeger, Tempo, etc. — vendor-neutral by construction.

---

## 4. File / directory layout

```
llm-stack/
├── ARCHITECTURE.md              # Top-level: how the pieces talk, what to read first
├── README.md                    # Quickstart: prereqs, "docker compose up", smoke test
├── INITIAL-PLAN.md              # (kept as-is, original brief)
├── docker-compose.yaml          # Heavily commented — the single source of wiring truth
├── .env.example                 # All tunables; copy to .env
├── .plans/
│   └── llm-sandbox-PLAN.md      # This document
│
├── app/                         # Agent app (Streamlit + LangChain)
│   ├── README.md                # What the app does, how traces are produced
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── app.py                   # Streamlit entrypoint
│   ├── agent.py                 # LangChain agent + OpenLLMetry init
│   └── tools.py                 # Multi-tool surface (HTTP calls into mock-services)
│
├── mock-services/               # Tiny FastAPI app the tools call — produces network spans
│   ├── README.md
│   ├── Dockerfile
│   ├── requirements.txt
│   └── main.py                  # /weather, /news, /stocks, /docs/search, /flaky
│
├── litellm/
│   ├── README.md                # What LiteLLM does, why it's the seam for Phase 2
│   └── config.yaml              # model_list, router settings, /metrics
│
├── vllm/
│   └── README.md                # Flag-by-flag explanation, key /metrics endpoints
│
├── prometheus/
│   ├── README.md                # Scrape config explained, useful PromQL recipes
│   ├── prometheus.yml
│   └── rules/
│       └── llm.rules.yml        # Recording rules: p95 latency, tokens/sec
│
├── grafana/
│   ├── README.md                # How dashboards are provisioned, panel-by-panel notes
│   ├── provisioning/
│   │   ├── datasources/datasources.yml
│   │   └── dashboards/dashboards.yml
│   └── dashboards/
│       ├── 01-llm-overview.json       # request rate, latency, tokens/s, queue depth
│       └── 02-gpu-saturation.json     # SM%, mem%, power, temp, KV cache
│
├── dcgm/
│   └── README.md                # Which DCGM_FI_* fields matter and why
│
├── langfuse/
│   ├── README.md                # OTLP ingestion, how traces map to LLM spans
│   └── .env.langfuse.example
│
├── docs/                        # Walkthroughs (read in order)
│   ├── 01-getting-started.md
│   ├── 02-anatomy-of-a-request.md   # follow one prompt end-to-end through every layer
│   ├── 03-saturation-analysis.md    # vegeta load test + what to watch
│   └── 04-trace-metric-correlation.md  # the prefill/decode lesson
│
└── .github/
    └── workflows/
        └── ci.yml               # YAML/JSON lint, hadolint, compose validate, app pytest
```

**Documentation rules** (because docs are the deliverable):
- Every service folder has a `README.md`. Minimum sections: *What this is*, *Why it's here*, *Configuration walkthrough*, *Where to look when it breaks*.
- `docker-compose.yaml` is commented service-by-service explaining *why* each flag / volume / port exists. No "magic numbers."
- Inline comments in `app/agent.py` and `litellm/config.yaml` explain the seams that make Phase 2 possible.
- `docs/` walkthroughs are read in order; each ends with "what to try next".

---

## 5. Component-by-component plan

### 5.1 vLLM engine

> **Implementation note (Phase 1.2):** Tool-calling via OpenAI's
> `tool_choice="auto"` requires two extra flags vLLM doesn't enable by
> default: `--enable-auto-tool-choice` and `--tool-call-parser hermes`
> (the `hermes` parser matches Qwen2.5's chat template). Without them
> the agent's first turn 400s.

Image: `vllm/vllm-openai:latest` (pin a specific tag in the actual compose — TBD at impl time).

Key points to call out in `vllm/README.md`:
- vLLM ships **native Prometheus metrics** at `/metrics`. No exporter needed. Important series:
  - `vllm:num_requests_running`, `vllm:num_requests_waiting` — queue depth (saturation).
  - `vllm:gpu_cache_usage_perc` — KV cache occupancy.
  - `vllm:time_to_first_token_seconds_*` — prefill latency histogram.
  - `vllm:time_per_output_token_seconds_*` — decode latency histogram.
  - `vllm:prompt_tokens_total`, `vllm:generation_tokens_total` — throughput.
- Volume-mount the HF cache (`/root/.cache/huggingface`) so model weights survive container restarts.
- GPU access via Docker Compose `deploy.resources.reservations.devices` with `nvidia` driver. Prerequisite: host has `nvidia-container-toolkit` installed and `docker info | grep -i runtime` shows `nvidia` available.

### 5.2 LiteLLM gateway

Image: `ghcr.io/berriai/litellm:main-latest` (pin in impl).

`litellm/config.yaml`:
```yaml
model_list:
  - model_name: qwen-chat                      # what the app asks for
    litellm_params:
      model: openai/qwen-chat                  # "openai/" tells LiteLLM to use the OpenAI-compat path
      api_base: http://vllm-engine:8000/v1     # *** the Phase 2 seam ***
      api_key: dummy                           # vLLM doesn't require auth

litellm_settings:
  # Surface /metrics for Prometheus scraping
  callbacks: ["prometheus"]
  # Pass selected headers downstream — needed for X-User-Id propagation
  forward_client_headers_to_llm_api: true

general_settings:
  master_key: sk-llm-stack-dev                 # dev-only; .env in real life
```
**Teaching note** (goes into `litellm/README.md`): the `api_base` line is the *entire* Phase 2 swap point. Adding Triton later means another `model_list` entry pointing at `triton:8000` and a model-name change in the app. Nothing else.

LiteLLM also emits OpenAI-compatible token usage on every response, which Langfuse picks up automatically via the OTLP semantic conventions.

### 5.3 Agent app (Streamlit + LangChain + OpenLLMetry)

`app/requirements.txt` (key pins documented in code comments):
```
streamlit
langchain
langchain-openai
openai
httpx                # tool calls into mock-services; auto-instrumented for HTTP spans
traceloop-sdk        # OpenLLMetry: auto-instruments LangChain + openai + httpx
```

`app/agent.py` (sketch, ~40 lines, fully commented in impl):
```python
# OpenLLMetry must be initialised before LangChain/openai/httpx are imported by the agent code,
# so instrumentation hooks are in place when those modules build their classes.
from traceloop.sdk import Traceloop
Traceloop.init(
    app_name="llm-sandbox",
    api_endpoint=os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"],   # Langfuse OTLP URL
    headers={"Authorization": f"Basic {os.environ['LANGFUSE_AUTH_B64']}"},
    disable_batch=True,   # flush eagerly in a dev sandbox so traces appear immediately
)

from langchain_openai import ChatOpenAI
from langchain.agents import AgentExecutor, create_tool_calling_agent
from .tools import ALL_TOOLS

llm = ChatOpenAI(
    model="qwen-chat",                         # logical name, resolved by LiteLLM
    base_url=os.environ["OPENAI_API_BASE"],    # http://litellm:4000
    api_key=os.environ["LITELLM_MASTER_KEY"],
    # default_headers lets us thread the simulated user id end-to-end
    default_headers={"X-User-Id": st.session_state["user_id"]},
)

# System prompt nudges the LLM toward multi-tool plans:
# "If a question involves several facts, call the tools needed in sequence."
agent = create_tool_calling_agent(llm, ALL_TOOLS, SYSTEM_PROMPT)
executor = AgentExecutor(agent=agent, tools=ALL_TOOLS, max_iterations=6)
```

`app/tools.py` — **multi-tool surface, designed for branchy traces.** Each tool hits the `mock-services` container over HTTP so OpenLLMetry's httpx instrumentation produces a real network span underneath each tool span:

```python
import os, httpx
from langchain.tools import tool

MOCK = os.environ["MOCK_SERVICES_URL"]   # http://mock-services:9000
_client = httpx.Client(base_url=MOCK, timeout=5.0)

@tool
def get_current_weather(city: str) -> str:
    """Current weather for a city. Returns 'unknown' if the city isn't in the mock dataset."""
    r = _client.get(f"/weather/{city}")
    return r.json()["summary"] if r.status_code == 200 else f"No weather data for {city}."

@tool
def get_news(topic: str, limit: int = 3) -> str:
    """Recent headlines for a topic. Returns up to `limit` items."""
    r = _client.get("/news", params={"topic": topic, "limit": limit})
    return "\n".join(f"- {h}" for h in r.json()["headlines"])

@tool
def get_stock_price(ticker: str) -> str:
    """Latest price + 24h change for a stock ticker."""
    r = _client.get(f"/stocks/{ticker.upper()}")
    if r.status_code == 404: return f"Unknown ticker {ticker}."
    d = r.json(); return f"{d['ticker']}: ${d['price']:.2f} ({d['change_pct']:+.2f}%)"

@tool
def search_documents(query: str) -> str:
    """Search the sandbox knowledge base. Returns up to 3 short snippets."""
    r = _client.get("/docs/search", params={"q": query})
    return "\n".join(f"[{h['id']}] {h['snippet']}" for h in r.json()["hits"])

@tool
def flaky_call(seed: str = "default") -> str:
    """Intentionally flaky endpoint — 30% chance of HTTP 500. Useful for seeing error spans."""
    r = _client.get("/flaky", params={"seed": seed})
    r.raise_for_status()    # let the exception surface; Langfuse shows it as a failed span
    return r.json()["message"]

ALL_TOOLS = [get_current_weather, get_news, get_stock_price, search_documents, flaky_call]
```

**Why five tools and not one:** the LLM has to pick. A prompt like *"Should I bring an umbrella to London and what's NVIDIA's stock doing?"* produces a Langfuse trace with two parallel-ish tool branches under one chain — exactly the kind of tree the observability practice is about reading. `flaky_call` exists so error spans appear without anything actually being broken.

`app/app.py` (Streamlit):
- Asks for a `user_id` on first load; stores in `st.session_state`.
- Renders a chat with `st.chat_input` / `st.chat_message`.
- Each turn invokes the agent; the resulting OTel trace tree (chain → llm → tool(s) → httpx GET → llm → final) shows up in Langfuse.

### 5.4 Prometheus

`prometheus/prometheus.yml` (excerpt; comments stripped here, present in file):
```yaml
global:
  scrape_interval: 5s        # short interval — sandbox, not prod cost
  evaluation_interval: 15s

rule_files:
  - /etc/prometheus/rules/llm.rules.yml

scrape_configs:
  - job_name: vllm
    static_configs: [{ targets: ["vllm-engine:8000"] }]
  - job_name: litellm
    static_configs: [{ targets: ["litellm:4000"] }]
  - job_name: dcgm
    static_configs: [{ targets: ["dcgm-exporter:9400"] }]
  - job_name: node
    static_configs: [{ targets: ["node-exporter:9100"] }]
  - job_name: cadvisor
    static_configs: [{ targets: ["cadvisor:8080"] }]
```

`prometheus/rules/llm.rules.yml` — recording rules to make dashboards readable:
```yaml
groups:
  - name: llm-recording-rules
    interval: 15s
    rules:
      - record: llm:request_latency_p95_seconds
        expr: histogram_quantile(0.95, sum by (le) (rate(litellm_request_total_latency_metric_bucket[1m])))
      - record: llm:tokens_per_second
        expr: sum(rate(vllm:generation_tokens_total[30s]))
      - record: gpu:power_watts
        expr: avg(DCGM_FI_DEV_POWER_USAGE)
```
(Exact metric names will be verified against the vLLM/LiteLLM versions chosen at impl time. README to list how to discover names via `curl :8000/metrics | head`.)

### 5.5 Grafana

- Provisioned via `grafana/provisioning/` — no clicking through UI; everything in git.
- Two starter dashboards, both pre-shipped as JSON:
  - **01-llm-overview**: request rate, p50/p95 latency, tokens/s, queue depth, KV cache % — annotated panels explain what each one means.
  - **02-gpu-saturation**: GPU SM activity, memory used, power draw, temperature, all on a shared time axis with LLM p95 latency overlaid. This is the dashboard that delivers the prefill/decode lesson.
- `grafana/README.md` walks panel by panel: "what this measures, what 'good' looks like, what changes when you increase load."

### 5.6 DCGM exporter

Image: `nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.0-ubuntu22.04` (pin at impl).
- Needs GPU access via the same `nvidia` device reservation as vLLM.
- A custom `dcp-metrics-included.csv` lets us trim to fields we care about (power, SM activity, mem used, mem clock, temp). Documented in `dcgm/README.md` with one line per field explaining what it represents physically.

### 5.7 Langfuse

> **Implementation note (Phase 1.2):** Langfuse v2 does *not* expose an
> OTLP/HTTP ingestion endpoint — that's a v3-only feature requiring the
> ClickHouse worker. We had to drop the planned `traceloop-sdk` (OpenLLMetry)
> + OTLP path and use Langfuse's **native LangChain `CallbackHandler`**
> instead. The trace tree visible in the UI is identical (chain → llm → tool);
> only the transport differs. Side-effect loss: httpx auto-instrumentation
> doesn't produce separate child spans under each tool — the per-tool HTTP
> round trip is observable instead via `mock-services` `/metrics`. If we
> ever upgrade to v3, the OTLP path becomes available again.

**Recommendation:** Self-host **Langfuse v2** (single web container + Postgres) for Phase 1.
- Reasoning: Langfuse v3 splits into web + worker + Postgres + ClickHouse + Redis + Minio. Production-realistic but six containers is a lot of moving parts for a sandbox whose focus is the LLM stack, not the trace store. The v2 path is two containers and gives you full OTLP ingestion, the UI, and Langfuse SDK access. v3 upgrade is a follow-up exercise.
- Compose: `langfuse/langfuse:2` + `postgres:16` with a named volume.
- OTLP endpoint: `http://langfuse:3000/api/public/otel/v1/traces`.
- Auth: a public/secret key pair (env-injected) → Basic auth header from the app.

### 5.8 Mock services

A tiny FastAPI app the agent's tools call. Exists so the trace tree has real HTTP spans under each tool span — without it, tools are pure Python and the "network" layer is invisible to observability.

**Endpoints:**
| Path                      | Returns                                                                  |
| ------------------------- | ------------------------------------------------------------------------ |
| `GET /weather/{city}`     | Canned weather for a small city list; 404 for unknowns                   |
| `GET /news?topic=&limit=` | Topic-keyed headline list                                                |
| `GET /stocks/{ticker}`    | Price + change for AAPL/NVDA/TSLA/…; 404 for unknowns                    |
| `GET /docs/search?q=`     | Trivial keyword match over a hard-coded doc set; returns ranked snippets |
| `GET /flaky?seed=`        | 30% 500, 70% 200 — produces interesting error spans                      |
| `GET /metrics`            | Prometheus metrics (request count, latency histogram) via prometheus-fastapi-instrumentator |

**Why it's a separate container** (not in-process in `app/`):
- The HTTP span between `app` and `mock-services` is the point. In-process means no network span.
- Lets us also scrape `/metrics` from this service in Prometheus — gives a second app-layer metrics source for cross-correlation practice.
- Easier to crank up its latency artificially later (`/flaky` could grow a `?delay=` knob) to simulate a slow dependency.

Image: built locally via `mock-services/Dockerfile`. ~10 lines of FastAPI; the file is intentionally short so a learner can read it cover-to-cover.

### 5.9 CI / linting

A single workflow at `.github/workflows/ci.yml` runs on PR and push:

| Step             | Tool                                  | What it checks                                                    |
| ---------------- | ------------------------------------- | ----------------------------------------------------------------- |
| YAML lint        | `yamllint`                            | All `*.yml` / `*.yaml` (compose, Prometheus, Grafana provisioning) |
| JSON validate    | `jq -e . < file`                      | Every Grafana dashboard JSON parses                                |
| Dockerfile lint  | `hadolint`                            | `app/Dockerfile`, `mock-services/Dockerfile`                       |
| Compose validate | `docker compose config -q`            | Compose file is parseable and references resolve                   |
| Python lint      | `ruff check` + `ruff format --check`  | `app/` and `mock-services/`                                        |
| Python tests     | `pytest -q`                           | Unit tests for `app/tools.py` (mocked httpx) and `mock-services/main.py` |

Tests stay minimal but real: the tool layer is the most likely thing to break silently. `mock-services` gets a few endpoint-shape tests so changes there don't quietly break the agent.

`pre-commit` hooks for the same checks are documented in the root README so failures surface before CI.

---

## 6. Networking & ports

| Service        | Host port | Internal              | Purpose                          |
| -------------- | --------- | --------------------- | -------------------------------- |
| Streamlit      | 8501      | app:8501              | UI                               |
| LiteLLM        | 4000      | litellm:4000          | gateway API + /metrics           |
| vLLM           | 8000      | vllm-engine:8000      | OpenAI API + /metrics            |
| Prometheus     | 9090      | prometheus:9090       | metrics UI / PromQL              |
| Grafana        | 3000      | grafana:3000          | dashboards                       |
| Langfuse       | 3001      | langfuse:3000         | UI + OTLP ingestion              |
| DCGM exporter  | 9400      | dcgm-exporter:9400    | GPU metrics                      |
| node-exporter  | 9100      | node-exporter:9100    | host metrics                     |
| cAdvisor       | 8080      | cadvisor:8080         | per-container metrics            |
| mock-services  | 9000      | mock-services:9000    | tool backend + /metrics          |
| Postgres (lf)  | —         | langfuse-db:5432      | langfuse storage (internal only) |

All services join a single `llm-stack` user-defined bridge network — service names become DNS, no `localhost` plumbing required.

---

## 7. Implementation phases (work breakdown)

Each phase ends in something you can demo and read.

**Phase 1.0 — Infra skeleton**
- `docker-compose.yaml` with vLLM + LiteLLM + Postgres + Langfuse + Prometheus + Grafana.
- vLLM serves Qwen2.5-3B; `curl litellm:4000/v1/chat/completions` works.
- ARCHITECTURE.md + READMEs for each service committed alongside the YAML.
- Exit criteria: a curl gets a sane completion and you can point to the line in compose that explains every choice.

**Phase 1.1 — Hardware observability**
- DCGM exporter, node-exporter, cAdvisor added.
- Prometheus scrapes all five sources.
- Grafana dashboards provisioned and visible at `:3000`.
- Exit criteria: `02-gpu-saturation` dashboard shows live power/temp curves.

**Phase 1.2 — App + traces**
- `mock-services` FastAPI container with the five endpoints, `/metrics` exposed and scraped.
- Streamlit chat + LangChain agent + five tools + OpenLLMetry → Langfuse OTLP.
- `X-User-Id` set in the UI, visible in Langfuse trace attributes.
- Exit criteria: a multi-part prompt produces a Langfuse trace tree with the chain at the root, multiple tool spans under it, an httpx GET span under each tool, and the user id on the root span.

**Phase 1.3 — Walkthrough docs**
- `docs/02-anatomy-of-a-request.md` — trace one prompt through every layer with screenshots / curl snippets.
- `docs/03-saturation-analysis.md` — drive load with `vegeta`; record what each metric does.
- `docs/04-trace-metric-correlation.md` — pair Langfuse trace timings with the GPU power curve at the same wall-clock time.

**Phase 1.4 — CI + polish**
- `.github/workflows/ci.yml` running the lint/validate/test matrix from §5.9.
- `pre-commit` config mirroring CI so failures surface locally.
- Pin all image tags. `.env.example` complete. README quickstart verified on a clean clone.

Phase 2 (deferred): Triton + TensorRT-LLM as a second `model_list` entry in LiteLLM. Compile a TRT-LLM engine for compute capability 8.9; mount the model repository; switch the app over by changing one model name.

---

## 8. Trade-offs & resolved decisions

| Decision | Choice | Trade-off |
| -------- | ------ | --------- |
| Model size | Qwen2.5-3B-AWQ over Llama-3-8B-AWQ | Lower answer quality, but enables real batching demos on 8 GB |
| Langfuse version | **v2** (single container) — confirmed | Skips the ClickHouse / Redis / Minio learning; faster to stand up. v3 stays as a future exercise. |
| Logs pillar | Deferred | Three pillars at once is too much surface for one phase; revisit when Loki is the focus of its own exercise |
| OTel routing | App pushes OTLP directly to Langfuse | Skips OTel Collector lesson; collector pattern can be introduced in Phase 2 as a routing point for both vLLM-and-Triton-era apps |
| LangChain vs LangGraph | LangChain `create_tool_calling_agent` | Simpler, OpenLLMetry instrumentation is mature; LangGraph adds graph-state concepts not relevant here |
| Agent tool surface | **Five tools** hitting a `mock-services` FastAPI app — confirmed | Adds one small container, but produces multi-branch traces with real HTTP spans, which is the whole point of the trace pillar |
| Load test tool | **vegeta** — confirmed | Histograms align with Prometheus bucketing; better correlation in dashboards |
| CI / lint pipeline | **In scope for Phase 1.4** — confirmed | Modest extra work, but enforces your "all code lints" rule and demonstrates how infra repos are kept honest |
| LiteLLM master key | Hard-coded dev key in repo | Acceptable for local sandbox; documented as such; rotate before any non-local use |

---

## 9. Prerequisites checklist (host side)

These need to exist before `docker compose up` will work:

- [ ] Docker Engine + Compose v2
- [ ] NVIDIA driver supporting CUDA 12.x (check with `nvidia-smi`)
- [ ] `nvidia-container-toolkit` installed and `docker info | grep -i runtime` shows `nvidia`
- [ ] At least ~30 GB free disk for images + HF model cache
- [x] HuggingFace token — **done** (already in `.env`). Not strictly needed for Qwen2.5-3B-AWQ (ungated), but useful for the Llama fallback.

The README will include a single `make preflight` (or `./scripts/preflight.sh`) target that checks every box and prints clear errors.

---

## 10. What "done" looks like for Phase 1

You can open the repo cold, run `docker compose up`, wait ~60 seconds, and:

1. Visit `http://localhost:8501`, type a question, get an answer.
2. Open `http://localhost:3001` (Langfuse) and see the trace tree for that exact request, with `user_id` tagged.
3. Open `http://localhost:3000` (Grafana), `02-gpu-saturation` dashboard, and see the GPU power spike at the moment of that request.
4. Open any service's README and have the configuration explained to you well enough to modify it confidently.

That's the learning loop — UI action → trace → metric correlation → docs that close the loop.
