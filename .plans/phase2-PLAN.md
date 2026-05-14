# LLM SRE Sandbox — Phase 2 Plan

> Status: **DRAFT — ready for review**
> Scope: every item listed under "Phase 2 (out of scope)" in
> [llm-sandbox-TODO.md](./llm-sandbox-TODO.md). Items listed under
> "Out of scope for this lab" (Grafana alerts/Alertmanager, authenticated
> Grafana) remain out of scope.
> Primary goal: **prove that the orchestration boundaries we set up in Phase 1
> hold under real change.** Every Phase 2 sub-phase changes one layer and
> leaves the others untouched — that's the lesson.

---

## 1. Goals (what this phase teaches)

Phase 1 built a stack with explicit seams. Phase 2 walks across each seam in
turn, replacing one component without touching the rest:

1. **Backend swap.** The agent app keeps asking for `qwen-chat`. LiteLLM
   routes it to a new Triton + TensorRT-LLM backend. The app doesn't change.
   This is the headline lesson the gateway exists for.
2. **Trace store swap.** Langfuse v2 → v3. The app's *trace API* stays the
   same, but the transport flips from the v2 SDK callback to true OTLP/HTTP
   via OpenLLMetry → OpenTelemetry Collector. The trace tree in the UI is
   identical.
3. **Add a third observability pillar.** Logs (Loki + Promtail) join metrics
   (Prometheus) and traces (Langfuse). The trace ↔ log correlation panel in
   Grafana ties them together.
4. **Multi-tenancy hardening.** Virtual API keys in LiteLLM make
   `X-User-Id` more than a header — every tenant gets a real key, real
   spend tracking, real rate limits. The `end_user` Prometheus label
   that Phase 1 deferred starts populating.
5. **Streaming end-to-end.** vLLM SSE → LiteLLM stream → LangChain async
   events → Streamlit token rendering. Latency *characteristics* change
   (TTFT visible to the human eye), trace span shape changes, and we
   adjust dashboards accordingly.

Each sub-phase ends in something runnable and a doc that explains *what
moved and what didn't*.

---

## 2. End-state architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Browser                                                                  │
│    │ streams tokens (Phase 2.5)                                           │
│    ▼                                                                      │
│  ┌──────────────┐                                                         │
│  │  Streamlit   │  st.write_stream() + agent_executor.astream_events()    │
│  └──────┬───────┘                                                         │
│         │                                                                  │
│         ▼                                                                  │
│  ┌──────────────┐         ┌──────────────────────────────┐                │
│  │  LangChain   │ ──HTTP─▶│  mock-services (FastAPI)     │                │
│  │  agent       │         └──────────────────────────────┘                │
│  │              │ OpenLLMetry (traceloop-sdk) — auto-spans on             │
│  │              │ langchain, openai client, httpx                         │
│  └──────┬───────┘ ───OTLP/HTTP──▶ otel-collector                          │
│         │                                                                  │
│         │ Bearer <virtual_key>  ── Phase 2.4                              │
│         ▼                                                                  │
│  ┌──────────────┐                                                         │
│  │   LiteLLM    │  + litellm-db (Postgres) for virtual keys + budgets     │
│  │   gateway    │  - models: `qwen-chat` (vLLM), `qwen-chat-trt` (Triton) │
│  │              │  - streaming on; per-end-user metrics                    │
│  └─┬──────────┬─┘                                                          │
│    │          │                                                            │
│    │          └──────────────────┐                                         │
│    ▼                             ▼                                         │
│  ┌──────────────┐         ┌────────────────────────┐                       │
│  │     vLLM     │         │  Triton Inference Srv   │  Phase 2.0          │
│  │  (Phase 1)   │         │  + TensorRT-LLM engine  │  Qwen2.5-3B-AWQ     │
│  │  Qwen-3B-AWQ │         │  for SM 8.9 (Ada)        │  compiled .engine  │
│  └──────────────┘         └────────────────────────┘                       │
│                                                                            │
│  ═══════════ OBSERVABILITY (3 pillars) ═══════════════════════════════    │
│                                                                            │
│  Metrics (Phase 1.1 + new dashboards):                                    │
│    Prometheus ── scrapes ── { existing 7 +                                │
│                               triton:8002, otel-collector:8888,           │
│                               litellm-db:9187 (postgres-exporter) }       │
│                                                                            │
│  Traces (Phase 2.1 + 2.2):                                                │
│    app ── OTLP/HTTP ──▶ otel-collector ── OTLP/HTTP ──▶ langfuse-web      │
│    langfuse-web ── enqueue ──▶ redis ── dequeue ──▶ langfuse-worker      │
│    langfuse-worker ── inserts ── clickhouse + postgres + minio            │
│                                                                            │
│  Logs (Phase 2.3 — NEW):                                                  │
│    docker logs ── scraped by ── promtail ── pushes ──▶ loki              │
│    grafana ── queries ── loki  (logs alongside metrics in one panel)     │
└──────────────────────────────────────────────────────────────────────────┘
```

Service count after Phase 2: **11 → ~20**. Layered breakdown:

| Layer | New services | Replaces / extends |
| ----- | ------------ | ------------------ |
| Inference | `triton-server` | second backend behind LiteLLM |
| Gateway | `litellm-db` (Postgres) | enables virtual keys |
| Traces | `clickhouse`, `redis`, `minio`, `langfuse-worker` | required by Langfuse v3 |
| Routing | `otel-collector` | OTLP hub |
| Logs | `loki`, `promtail` | third observability pillar |

---

## 3. Sub-phases (work breakdown)

Each sub-phase is self-contained, ends in a runnable + readable state, and
can be merged independently. The order below is dependency-aware: 2.0 is
isolated, 2.1 enables 2.2, 2.3 stands alone, 2.4 enables a richer 2.5.

| Sub-phase | Theme | Depends on | Headline demo |
| --------- | ----- | ---------- | ------------- |
| 2.0 | Triton + TRT-LLM backend | none | Same Streamlit prompt routes to a different engine via one config line |
| 2.1 | Langfuse v3 + ClickHouse | none (parallel with 2.0) | Existing traces migrate; v3 UI shows same chain tree |
| 2.2 | OpenLLMetry + OTel Collector | 2.1 | httpx sub-spans reappear under tool spans |
| 2.3 | Logs pillar (Loki + Promtail) | none | "Click a span, see the LiteLLM access log lines that match" |
| 2.4 | Virtual keys + per-tenant cost / rate limits | none (but 2.3 helps debug) | Hitting LiteLLM with two different keys produces distinct `end_user` series in Prometheus |
| 2.5 | Streaming end-to-end | 2.4 nice but not required | Tokens render in Streamlit as they arrive; TTFT visible on the dashboard |

---

### Phase 2.0 — Triton + TensorRT-LLM as a second backend

**Goal:** demonstrate the gateway's swap point by introducing a *different*
inference engine for the same logical model name. Compile a TRT-LLM engine
for compute capability 8.9 (Ada / RTX 4060), serve it through Triton, and
add it to LiteLLM's `model_list`.

**Why TRT-LLM:** the original PLAN named it as the canonical Phase 2 backend.
It also exposes a genuinely different metric surface (`nv_inference_*`)
than vLLM's `vllm:*`, so the dashboards have to learn a second vocabulary —
realistic and educational.

#### Approach

1. **Build the engine** (host-side, one-off step).
   We run the NVIDIA-provided builder image to compile the Qwen2.5-3B-AWQ
   weights into a Triton-ready engine for SM 8.9:

   ```bash
   # scripts/build-trt-engine.sh — new
   docker run --rm --gpus all \
     -v "$PWD/triton/engines:/engines" \
     -v "$HOME/.cache/huggingface:/hf" \
     nvcr.io/nvidia/tritonserver:25.04-trtllm-python-py3 \
     bash -c "
       trtllm-build \
         --checkpoint_dir /hf/hub/models--Qwen--Qwen2.5-3B-Instruct-AWQ/snapshots/<HASH> \
         --output_dir /engines/qwen-chat-trt \
         --gemm_plugin float16 \
         --gpt_attention_plugin float16 \
         --max_batch_size 8 \
         --max_input_len 3072 \
         --max_output_len 1024 \
         --use_paged_context_fmha enable
     "
   ```

   The output is a `*.engine` file plus a `config.pbtxt` in `triton/engines/qwen-chat-trt/`.
   Build time on Ada: ~10–15 minutes. Output size: ~3 GB. **The compiled
   engine is GPU-specific** — it won't run on anything other than SM 8.9.

2. **Triton service in compose**:

   ```yaml
   # docker-compose.yaml — addition
   triton-server:
     image: nvcr.io/nvidia/tritonserver:25.04-trtllm-python-py3  # pin in 2.0
     container_name: triton-server
     restart: unless-stopped
     command:
       - tritonserver
       - --model-repository=/models
       - --log-verbose=1
       - --http-port=8002       # avoid colliding with vLLM:8000
       - --grpc-port=8003
       - --metrics-port=8004    # Prometheus scrape target
     volumes:
       - ./triton/model_repository:/models:ro
     ports:
       - "8002:8002"
       - "8004:8004"
     networks: [llm-stack]
     deploy:
       resources:
         reservations:
           devices:
             - driver: nvidia
               count: 1
               capabilities: [gpu]
     # No depends_on: vllm — they can run in parallel; LiteLLM routes between them
     healthcheck:
       test: ["CMD", "curl", "-fsS", "http://localhost:8002/v2/health/ready"]
       interval: 10s
       start_period: 90s
   ```

3. **LiteLLM second `model_list` entry**:

   ```yaml
   # litellm/config.yaml — diff vs. Phase 1
   model_list:
     - model_name: qwen-chat                         # existing — vLLM
       litellm_params:
         model: openai/qwen-chat
         api_base: http://vllm-engine:8000/v1
         api_key: dummy

     # NEW — Triton + TRT-LLM
     - model_name: qwen-chat-trt
       litellm_params:
         # LiteLLM's `triton/` provider speaks Triton's /v2 inference API
         # natively. No custom adapter needed.
         model: triton/qwen-chat-trt
         api_base: http://triton-server:8002

     # Optional router rule for the "swap" lesson — same logical name, two
     # backends, weighted shedding. Uncomment to switch the app to TRT
     # without touching app code.
     # router_settings:
     #   model_group_alias:
     #     qwen-chat: ["qwen-chat", "qwen-chat-trt"]
   ```

4. **Prometheus scrape job** (`prometheus/prometheus.yml`):

   ```yaml
   - job_name: triton
     metrics_path: /metrics      # Triton exposes on :8002 (default) or :8004 with the override above
     static_configs:
       - targets: ["triton-server:8004"]
         labels: { layer: inference }
   ```

5. **New dashboard panels** (additive — don't touch the vLLM panels):
   - `nv_inference_request_duration_us` histogram → TRT request latency
   - `nv_inference_compute_infer_duration_us` → compute-only (no queue)
   - Same `Gateway p95` panel auto-includes both backends because LiteLLM's
     metrics aggregate by `model` label.

#### Files touched

```
docker-compose.yaml                  # +triton-server service
litellm/config.yaml                  # second model_list entry
prometheus/prometheus.yml            # +scrape job
grafana/dashboards/03-trt-llm.json   # NEW — TRT-specific metrics
scripts/build-trt-engine.sh          # NEW — one-shot engine compile
triton/README.md                     # NEW — what this is, how to rebuild, troubleshooting
triton/model_repository/qwen-chat-trt/  # NEW — generated artefact (gitignored except config.pbtxt template)
VERSIONS.md                          # +triton image pin
.gitignore                           # +triton/engines/, triton/model_repository/qwen-chat-trt/1/
```

#### Trade-offs

| Decision | Why | Cost |
| -------- | --- | ---- |
| TRT-LLM via Triton (not vLLM's experimental TRT-LLM backend) | The original PLAN promised this exact lesson; Triton is the production-realistic path | Two engines now live on the same 8 GB GPU → can't run both at full batch sizes simultaneously. Demo each separately. |
| LiteLLM `triton/` provider over custom adapter | LiteLLM 1.40+ ships native Triton support, including streaming | If LiteLLM's triton wire format ever drifts, we'd need to pin the version |
| Engine compile runs **outside** compose | The builder image is huge (~25 GB) and only needed once per GPU model | Adds a `scripts/build-trt-engine.sh` step before `docker compose up` |
| Engine artefacts live in `triton/model_repository/` under git | `config.pbtxt` is a template (committed); the binary `.engine` is gitignored | Anyone cloning needs to run the build script before `triton-server` is healthy |

> Note: due to hardware constraints, we don't have to ru both engines simultaneously, it's okay to just comment out vLLM in docker compose and don't bring it up when running Triton.

#### Exit criteria

- `curl :4000/v1/chat/completions -d '{"model":"qwen-chat-trt", ...}'`
  returns a Qwen completion from Triton.
- Streamlit chat still works with `model="qwen-chat"` (vLLM unchanged).
- New Grafana dashboard `03-trt-llm` shows TRT-LLM request latency curves
  against load (drive with `scripts/load.sh --model qwen-chat-trt`).
- `triton/README.md` documents engine rebuild, GPU-specific binary,
  troubleshooting matrix.

---

### Phase 2.1 — Langfuse v3 (ClickHouse + Redis + Minio)

**Goal:** upgrade to Langfuse v3 so OTLP becomes available. v3 splits
ingestion across web + worker + ClickHouse + Redis + Minio (object store
for batched event files).

**Why now:** Phase 2.2 (OpenLLMetry / OTel) is only useful with v3.
The split is also genuinely educational — it's the same shape every
production trace store ends up with (hot OLTP for metadata, columnar
store for events, queue between API and ingest workers).

#### Approach

1. **Five new services** in `docker-compose.yaml`. Postgres stays; ClickHouse
   is *additional*, not a replacement. Rough sizes on disk: ClickHouse ~5 GB
   for a few weeks of traces; Minio ~1 GB; Redis ~50 MB.

   ```yaml
   langfuse-clickhouse:
     image: clickhouse/clickhouse-server:24.10-alpine
     container_name: langfuse-clickhouse
     volumes:
       - langfuse-clickhouse-data:/var/lib/clickhouse
     environment:
       CLICKHOUSE_USER: langfuse
       CLICKHOUSE_PASSWORD: ${CLICKHOUSE_PASSWORD}
       CLICKHOUSE_DB: langfuse
     networks: [llm-stack]
     healthcheck:
       test: ["CMD", "wget", "-qO-", "http://localhost:8123/ping"]

   langfuse-redis:
     image: redis:7-alpine
     container_name: langfuse-redis
     command: ["redis-server", "--requirepass", "${REDIS_PASSWORD}"]
     networks: [llm-stack]
     healthcheck:
       test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]

   langfuse-minio:
     image: minio/minio:RELEASE.2024-11-07T00-52-20Z
     container_name: langfuse-minio
     command: server /data --console-address ":9001"
     environment:
       MINIO_ROOT_USER: ${MINIO_ROOT_USER}
       MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
     volumes:
       - langfuse-minio-data:/data
     # Internal-only; no host port unless we want the web console
     networks: [llm-stack]
     healthcheck:
       test: ["CMD", "mc", "ready", "local"]

   langfuse-worker:
     image: langfuse/langfuse-worker:3   # pin to specific minor in 2.1 commit
     container_name: langfuse-worker
     environment: *langfuse-env          # YAML anchor — same env as web
     depends_on:
       langfuse-db: { condition: service_healthy }
       langfuse-clickhouse: { condition: service_healthy }
       langfuse-redis: { condition: service_healthy }
       langfuse-minio: { condition: service_healthy }
     networks: [llm-stack]
     # No port; reads from Redis, writes to ClickHouse + Postgres + Minio
   ```

2. **Replace `langfuse:2.95.11` with `langfuse:3.X.Y`** in the web service,
   wire the same env block via a YAML anchor:

   ```yaml
   x-langfuse-env: &langfuse-env
     DATABASE_URL: postgresql://langfuse:${LANGFUSE_DB_PASSWORD}@langfuse-db:5432/langfuse
     CLICKHOUSE_URL: http://langfuse-clickhouse:8123
     CLICKHOUSE_USER: langfuse
     CLICKHOUSE_PASSWORD: ${CLICKHOUSE_PASSWORD}
     REDIS_HOST: langfuse-redis
     REDIS_AUTH: ${REDIS_PASSWORD}
     LANGFUSE_S3_EVENT_UPLOAD_BUCKET: langfuse
     LANGFUSE_S3_EVENT_UPLOAD_REGION: auto
     LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID: ${MINIO_ROOT_USER}
     LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY: ${MINIO_ROOT_PASSWORD}
     LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT: http://langfuse-minio:9000
     LANGFUSE_S3_EVENT_UPLOAD_FORCE_PATH_STYLE: "true"
     NEXTAUTH_URL: http://localhost:3001
     NEXTAUTH_SECRET: ${NEXTAUTH_SECRET}
     SALT: ${LANGFUSE_SALT}
     TELEMETRY_ENABLED: "false"
   ```

3. **Migration** from v2 → v3 traces. Two options:

   - **A (clean cut):** `docker compose down langfuse langfuse-db`, drop the
     volume, restart on v3 with a fresh DB. Lose Phase 1 traces.
     Acceptable since they're synthetic.
   - **B (in-place):** v3's worker has a one-shot `migrate-from-v2`
     command that reads Postgres traces and writes them to ClickHouse.
     ~5–10 minutes for a sandbox-sized history. Adds complexity but
     preserves the demo traces (handy if anyone wants to compare).

   **Choosing A** unless explicit reason to keep history — it's simpler and
   the traces are reproducible by re-running `scripts/load.sh`.

4. **OTLP endpoint**: v3 exposes
   `POST /api/public/otel/v1/traces` (note the suffix) — that's what Phase
   2.2 will point at.

#### Files touched

```
docker-compose.yaml                  # +4 services, edit langfuse service, YAML anchor
.env.example                         # +CLICKHOUSE_PASSWORD, REDIS_PASSWORD, MINIO_ROOT_USER, MINIO_ROOT_PASSWORD
langfuse/README.md                   # rewrite "Why not v3?" section into "v3 architecture"
langfuse/.env.langfuse.example       # update with the new env block
scripts/preflight.sh                 # add checks for the new env vars + a "have you bumped HF cache RAM?" hint
VERSIONS.md                          # +clickhouse, redis, minio, langfuse-worker pins
```

#### Trade-offs

| Decision | Why | Cost |
| -------- | --- | ---- |
| Self-host every backing service (CH/Redis/Minio), not managed | Sandbox value comes from running the ingest path end-to-end | +4 containers, ~6 GB extra RAM at idle, more healthchecks to fail when things drift |
| Drop v2 traces (option A) | Cleaner; sandbox traces are synthetic anyway | Phase 2 starts with an empty trace store; takes ~3 minutes of `load.sh` to repopulate |
| Bump to `clickhouse:24.10` | What Langfuse v3 has tested against in late 2025 / early 2026 | 25.x might work but isn't on Langfuse's compatibility list yet |
| `minio` for S3 emulation, not localstack | minio is single-purpose and lean; localstack is heavier and aimed at full-AWS emulation | minio's UI is less polished than localstack's debug surface, but we don't need the UI |

#### Exit criteria

- All five new services healthy under `docker compose up -d`.
- The Langfuse UI at `:3001` loads, the org/project/keys from Phase 1 are
  recreated, and the existing `app/agent.py` (still using the v2 native
  callback) writes traces that appear in v3's UI — the v3 SDK is
  backwards-compatible with the v2 callback.
- `curl :3001/api/public/otel/v1/traces` returns a 401 (auth needed) —
  proves OTLP is reachable on the path Phase 2.2 will use.

---

### Phase 2.2 — OpenLLMetry (traceloop-sdk) + OTel Collector

**Goal:** swap the app's tracing transport from the Langfuse v2 native
callback to true OTLP via OpenLLMetry, with an OpenTelemetry Collector in
the middle as a routing hub. This restores the httpx sub-spans under each
tool span — the thing we lost when v2 forced us off OTLP in Phase 1.2.

#### Approach

1. **Add the collector service** to compose:

   ```yaml
   otel-collector:
     image: otel/opentelemetry-collector-contrib:0.114.0   # pin in 2.2
     container_name: otel-collector
     command: ["--config=/etc/otel/config.yaml"]
     volumes:
       - ./otel/config.yaml:/etc/otel/config.yaml:ro
     ports:
       - "4318:4318"                # OTLP HTTP receiver (host shell can also push)
       - "13133:13133"              # health check
       - "8888:8888"                # collector's own /metrics
     networks: [llm-stack]
     depends_on:
       langfuse: { condition: service_healthy }
     healthcheck:
       test: ["CMD", "wget", "-qO-", "http://localhost:13133/"]
   ```

2. **Collector config** (`otel/config.yaml`, new):

   ```yaml
   receivers:
     otlp:
       protocols:
         http:
           endpoint: 0.0.0.0:4318
         grpc:
           endpoint: 0.0.0.0:4317   # not exposed externally but available inside the network

   processors:
     batch:                          # batch up to 8 KB or 200 ms — the sweet spot for HTTP
       timeout: 200ms
       send_batch_size: 8192

     # Tag everything coming through this collector so Langfuse can filter
     # by source if we ever fan out to multiple emitters (e.g. add LiteLLM's
     # own OTLP emission in a future phase).
     attributes/source:
       actions:
         - key: source
           value: otel-collector
           action: insert

   exporters:
     otlphttp/langfuse:
       endpoint: http://langfuse:3000/api/public/otel
       auth:
         authenticator: basicauth/langfuse

     # Sidecar export — also write to the collector's own logs at info-level
     # so we can `docker compose logs otel-collector` and *see* traces flow.
     # Useful while debugging the new pipeline. Remove after 2.2 stabilises.
     debug:
       verbosity: detailed

   extensions:
     basicauth/langfuse:
       client_auth:
         username: ${LANGFUSE_PUBLIC_KEY}
         password: ${LANGFUSE_SECRET_KEY}
     health_check:
       endpoint: 0.0.0.0:13133

   service:
     extensions: [basicauth/langfuse, health_check]
     pipelines:
       traces:
         receivers: [otlp]
         processors: [batch, attributes/source]
         exporters: [otlphttp/langfuse, debug]

     telemetry:
       metrics:
         address: 0.0.0.0:8888
   ```

3. **App-side**: drop the Langfuse v2 callback path in `app/agent.py`, add
   `traceloop-sdk` to `app/requirements.txt`, and initialise it at import
   time so OpenLLMetry's auto-instrumentation hooks fire when LangChain /
   openai / httpx are imported:

   ```python
   # app/agent.py — top of file replaces the Langfuse import + handler
   import os
   from traceloop.sdk import Traceloop

   Traceloop.init(
       app_name="llm-sandbox",
       api_endpoint=os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"],   # http://otel-collector:4318
       disable_batch=False,                                       # collector handles batching
   )

   # Rest of agent.py stays nearly identical, EXCEPT:
   # - remove CallbackHandler import
   # - remove `self._handler` from Agent.__init__
   # - remove `config={"callbacks": [self._handler]}` from invoke()
   # - replace user_id propagation with Traceloop's `set_association_properties`:

   from traceloop.sdk.tracing import set_association_properties

   class Agent:
       def __init__(self, user_id: str):
           self._user_id = user_id
           # ... ChatOpenAI + AgentExecutor as before ...

       def chat(self, user_input, history):
           set_association_properties({"user_id": self._user_id})
           result = self._executor.invoke(...)
           return result.get("output")
   ```

4. **Compose env update** for the `app` service:

   ```yaml
   environment:
     # was: LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY (now consumed by otel-collector)
     OTEL_EXPORTER_OTLP_ENDPOINT: http://otel-collector:4318
     OTEL_SERVICE_NAME: llm-sandbox-app
   depends_on:
     otel-collector: { condition: service_healthy }
   ```

5. **Prometheus**: add the collector itself as a scrape target so we can
   watch trace ingest rate / batch size in Grafana:

   ```yaml
   - job_name: otel-collector
     static_configs:
       - targets: ["otel-collector:8888"]
         labels: { layer: traces }
   ```

#### Files touched

```
docker-compose.yaml                  # +otel-collector, edit app env
otel/config.yaml                     # NEW
otel/README.md                       # NEW — what the collector does, how to add new exporters/receivers
app/requirements.txt                 # +traceloop-sdk==0.30.x, remove langfuse v2 SDK
app/agent.py                         # rewrite tracing init
app/README.md                        # rewrite tracing section (OTLP path restored)
prometheus/prometheus.yml            # +otel-collector scrape
.env.example                         # OTEL_EXPORTER_OTLP_ENDPOINT (re-introduced, this time actually used)
VERSIONS.md                          # +otel-collector image pin, traceloop-sdk pin
```

#### Trade-offs

| Decision | Why | Cost |
| -------- | --- | ---- |
| OTel Collector in the path | Future-proof: any other emitter (LiteLLM OTLP, vLLM OTLP) plugs in without app changes; collector handles batching and retries | One extra hop = one extra failure mode; on first deploy we'll spend time on collector logs |
| `traceloop-sdk` over hand-rolled OTel SDK | Auto-instruments LangChain + OpenAI client + httpx; the alternative is wiring three opentelemetry-instrumentation packages by hand | Couples us to Traceloop's auto-instrumentor's pace of language-model coverage |
| Keep `debug` exporter on initially | While 2.2 is being shaken out, seeing traces in collector logs is invaluable | Will need a follow-up commit to remove it (TODO captured) |
| Auth via collector's `basicauth/langfuse`, not in the app | Centralises the Langfuse credentials at the collector — the app doesn't know about Langfuse at all | If we add a second backend for traces (e.g. Tempo), they each need their own collector exporter |

#### Exit criteria

- A multi-tool prompt in Streamlit produces a trace in Langfuse v3 with
  `httpx.GET` spans as children of each tool span — the thing we lost in
  Phase 1.2.
- `docker compose logs otel-collector` shows trace export batches every
  ~200 ms during traffic.
- The `Traces` row in the LLM Overview dashboard tracks the collector's
  `otelcol_exporter_sent_spans` counter.

---

### Phase 2.3 — Logs pillar (Loki + Promtail)

**Goal:** introduce the third observability pillar without ceremony — Loki
+ Promtail scraping every container's stdout, with Grafana querying both
Prometheus and Loki on a single dashboard. The headline moment: pick a
trace in Langfuse, copy its wall-clock window, drop it into a Grafana panel,
see the `litellm` access-log lines for that exact span.

#### Approach

1. **Loki** (single-binary deployment is enough for a sandbox):

   ```yaml
   loki:
     image: grafana/loki:3.3.0
     container_name: loki
     command: ["-config.file=/etc/loki/loki.yaml"]
     volumes:
       - ./loki/loki.yaml:/etc/loki/loki.yaml:ro
       - loki-data:/loki
     ports: ["3100:3100"]
     networks: [llm-stack]
     healthcheck:
       test: ["CMD", "wget", "-qO-", "http://localhost:3100/ready"]
   ```

2. **Promtail** scrapes the Docker daemon's container logs:

   ```yaml
   promtail:
     image: grafana/promtail:3.3.0
     container_name: promtail
     command: ["-config.file=/etc/promtail/promtail.yaml"]
     volumes:
       - /var/run/docker.sock:/var/run/docker.sock:ro
       - /var/lib/docker/containers:/var/lib/docker/containers:ro
       - ./promtail/promtail.yaml:/etc/promtail/promtail.yaml:ro
     networks: [llm-stack]
     depends_on:
       loki: { condition: service_healthy }
   ```

3. **Promtail config** uses the Docker service discovery so labels match
   our compose service names (`{service="litellm"}`, `{service="vllm-engine"}`, etc.):

   ```yaml
   # promtail/promtail.yaml
   server:
     http_listen_port: 9080
   clients:
     - url: http://loki:3100/loki/api/v1/push
   scrape_configs:
     - job_name: docker
       docker_sd_configs:
         - host: unix:///var/run/docker.sock
           refresh_interval: 5s
       relabel_configs:
         - source_labels: ['__meta_docker_container_label_com_docker_compose_service']
           target_label: 'service'
         - source_labels: ['__meta_docker_container_label_com_docker_compose_project']
           target_label: 'project'
         - source_labels: ['__meta_docker_container_name']
           target_label: 'container'
       pipeline_stages:
         - cri: {}      # parse the CRI line format docker writes
   ```

4. **Grafana datasource** (`grafana/provisioning/datasources/datasources.yml`):

   ```yaml
   - name: Loki
     type: loki
     uid: loki
     url: http://loki:3100
     editable: false
     jsonData:
       maxLines: 5000
   ```

5. **New dashboard panel** on `01-llm-overview.json` ("Recent logs (gateway)"):

   ```jsonc
   {
     "type": "logs",
     "title": "LiteLLM access log (last 10 min)",
     "datasource": { "uid": "loki" },
     "targets": [
       { "expr": "{service=\"litellm\"} | json | line_format \"{{.method}} {{.url}} {{.status_code}} {{.user}}\"" }
     ]
   }
   ```

#### Files touched

```
docker-compose.yaml                  # +loki, +promtail
loki/loki.yaml                       # NEW
loki/README.md                       # NEW
promtail/promtail.yaml               # NEW
promtail/README.md                   # NEW (or merge into loki/)
grafana/provisioning/datasources/datasources.yml  # +Loki datasource
grafana/dashboards/01-llm-overview.json           # +log panel
VERSIONS.md                          # +loki, +promtail pins
```

#### Trade-offs

| Decision | Why | Cost |
| -------- | --- | ---- |
| Promtail (legacy) over Grafana Alloy (newer) | Promtail's Docker service discovery is well-trodden; Alloy adds a learning step | Promtail enters maintenance mode in 2026; revisit in a future phase |
| Loki single-binary, no separate ingester/distributor/querier | Sandbox doesn't need horizontal scale | Won't survive a heavy log burst — fine for our load levels |
| Scrape Docker container logs directly | Catches anything emitted on stdout, no app changes needed | Doesn't pick up custom-shaped log files; not an issue here since every service is stdout-only |

#### Exit criteria

- All eleven Phase 1 services' logs queryable in Grafana via
  `{service="<name>"}` selectors.
- The "LiteLLM access log" panel on the overview dashboard populates with
  parsed JSON fields.
- A trace ↔ log walkthrough lands in `docs/05-trace-log-correlation.md`
  (new) showing how to pick a span and find the matching log lines.

---

### Phase 2.4 — Virtual API keys + per-tenant cost + rate limits in LiteLLM

**Goal:** make `X-User-Id` a real tenant identity — back it with a virtual
API key in LiteLLM, attach a budget per key, set per-key rate limits, and
surface the `end_user` Prometheus label that Phase 1 explicitly deferred.

#### Approach

1. **LiteLLM needs Postgres** to persist virtual keys. We *could* reuse
   `langfuse-db` but mixing two apps' schemas in one DB is operationally
   ugly — add `litellm-db` instead:

   ```yaml
   litellm-db:
     image: postgres:16-alpine
     container_name: litellm-db
     environment:
       POSTGRES_USER: litellm
       POSTGRES_PASSWORD: ${LITELLM_DB_PASSWORD}
       POSTGRES_DB: litellm
     volumes:
       - litellm-pg-data:/var/lib/postgresql/data
     networks: [llm-stack]
     healthcheck:
       test: ["CMD-SHELL", "pg_isready -U litellm -d litellm"]
   ```

2. **Wire LiteLLM to it** via `general_settings.database_url`:

   ```yaml
   # litellm/config.yaml — add
   general_settings:
     master_key: os.environ/LITELLM_MASTER_KEY
     database_url: os.environ/LITELLM_DATABASE_URL
     # When set, LiteLLM splits Prometheus metrics by `end_user`.
     allowed_fails: 3
     budget_tracker: enabled

   litellm_settings:
     callbacks: ["prometheus"]
     forward_client_headers_to_llm_api: true
     # NEW: split metrics by end_user label
     enable_end_user_cost_tracking: true
     # NEW: per-virtual-key rate limit (override per key below)
     rpm_limit: 60
   ```

3. **Provisioning script** (`scripts/seed-virtual-keys.sh`, new). On first
   bring-up, this hits LiteLLM's `/key/generate` with a couple of demo
   tenants and writes the resulting keys to `.env.virtual-keys` (gitignored):

   ```bash
   set -euo pipefail
   MASTER="$(grep ^LITELLM_MASTER_KEY .env | cut -d= -f2)"
   for user in alice bob carol; do
     resp=$(curl -s -X POST http://localhost:4000/key/generate \
       -H "Authorization: Bearer $MASTER" \
       -H "Content-Type: application/json" \
       -d "{\"models\": [\"qwen-chat\"], \"user_id\": \"$user\", \"max_budget\": 0.10, \"rpm_limit\": 30}")
     key=$(echo "$resp" | jq -r .key)
     echo "LITELLM_KEY_${user^^}=$key" >> .env.virtual-keys
   done
   ```

4. **App-side**: Streamlit now needs to *send* the virtual key as the
   bearer, not the master key. The `user_id` becomes a per-key property
   (Phase 1's `default_headers={"X-User-Id": user_id}` becomes redundant
   but harmless — the key already carries the identity).

   ```python
   # app/app.py — sidebar gains a "tenant" picker that maps to a virtual key
   tenant = st.sidebar.selectbox("Tenant", ["alice", "bob", "carol"])
   api_key = os.environ[f"LITELLM_KEY_{tenant.upper()}"]   # injected via compose env
   # passed through to ChatOpenAI as before
   ```

5. **New dashboard panels** on a NEW `04-tenants.json`:
   - Request rate per `end_user` (from `litellm_requests_total{end_user=...}`)
   - Spend per `end_user` (from `litellm_spend_metric{end_user=...}`)
   - Rate-limit hits (`litellm_total_requests` filtered by 429 status)

#### Files touched

```
docker-compose.yaml                  # +litellm-db, edit litellm + app env
litellm/config.yaml                  # general_settings + new keys
litellm/README.md                    # add virtual-keys section
scripts/seed-virtual-keys.sh         # NEW
.env.example                         # +LITELLM_DB_PASSWORD
.gitignore                           # +.env.virtual-keys
grafana/dashboards/04-tenants.json   # NEW
prometheus/rules/llm.rules.yml       # +per-tenant recording rules
VERSIONS.md                          # already pinned postgres
```

#### Trade-offs

| Decision | Why | Cost |
| -------- | --- | ---- |
| Separate `litellm-db` from `langfuse-db` | Operational hygiene; either can be wiped/restored independently | One more container, one more env var |
| Bootstrap keys via shell script, not LiteLLM's UI | UI requires `LITELLM_PROXY_UI_ENABLED=true` and a login flow; for a sandbox the curl script is enough and reproducible | The UI is nice-to-have for any non-toy use; can be added in a follow-up |
| Synthetic costs (no real pricing source) | vLLM/Triton are free; we just want the *plumbing* to work | Numbers are arbitrary; the lesson is the labels and panels, not the dollars |

#### Exit criteria

- Two parallel `curl` requests to `:4000/v1/chat/completions` with
  different virtual keys produce two distinct `end_user` series in
  Prometheus that the new tenant dashboard plots side-by-side.
- Exceeding a key's rate limit returns HTTP 429 with the `rate_limit` reason.
- Spend counters increment on each call (synthetic pricing aside).

---

### Phase 2.5 — Streaming end-to-end

**Goal:** stream tokens from vLLM through LiteLLM, through LangChain's
async event API, into Streamlit's `st.write_stream`. TTFT becomes the
metric that matters to the human experience; the dashboard panel layout
adjusts accordingly.

#### Approach

1. **vLLM**: already supports SSE — nothing to change.
2. **LiteLLM**: streaming flag is passed through transparently for
   `openai/`-prefixed models. The `triton/` provider also supports
   streaming as of LiteLLM 1.50+ (verify at impl time).
3. **LangChain agent loop**: switch from `AgentExecutor.invoke()` to
   `astream_events(version="v2")`, which emits one event per token plus
   tool-start/tool-end events:

   ```python
   # app/agent.py — new async chat() method
   async def chat_stream(self, user_input, history):
       set_association_properties({"user_id": self._user_id})
       async for event in self._executor.astream_events(
           {"input": user_input, "chat_history": _to_lc_history(history)},
           version="v2",
       ):
           kind = event["event"]
           if kind == "on_chat_model_stream":
               chunk = event["data"]["chunk"].content
               if chunk:
                   yield chunk
           elif kind == "on_tool_start":
               yield f"\n_calling {event['name']}..._\n"
           elif kind == "on_tool_end":
               yield ""   # tool result not surfaced in the visible text
   ```

4. **Streamlit**:

   ```python
   with st.chat_message("assistant"):
       full = st.write_stream(executor.chat_stream(prompt, prior))   # streams tokens
   ```

5. **New metrics & dashboard tweaks**:
   - vLLM already emits `vllm:time_to_first_token_seconds` — promote it
     to a top-line panel.
   - The "p95 latency" panel still makes sense but is now best paired
     with a "p95 TTFT" panel alongside it — that's the *user-perceived*
     latency.

#### Files touched

```
app/agent.py                         # async chat_stream method
app/app.py                           # st.write_stream
app/requirements.txt                 # may need `anyio` bump
app/README.md                        # explain why streaming changes the trace shape
grafana/dashboards/01-llm-overview.json  # +TTFT panel
docs/06-streaming.md                 # NEW — what TTFT means, how to read the panel
```

#### Trade-offs

| Decision | Why | Cost |
| -------- | --- | ---- |
| Stream via LangChain `astream_events` | Cleanest fit with the existing AgentExecutor; auto-instrumentor sees streams | Async-only path; the sync `chat()` stays around for the test harness |
| Keep AgentExecutor (not raw `astream` on the chain) | Tools still need to run; AgentExecutor's loop handles tool invocation properly | Streaming events for tool calls arrive *after* the LLM stops streaming the tool-call message — a UX wrinkle worth documenting |
| New TTFT panel, keep the existing latency panel | TTFT and end-to-end are different stories | One more panel to maintain; the docs explain when each matters |

#### Exit criteria

- Tokens appear in Streamlit incrementally (visible streaming) instead of
  in one block.
- The TTFT panel on the overview dashboard correlates with vLLM's
  `time_to_first_token_seconds` histogram during a `scripts/load.sh
  decode-heavy` run.
- A streaming Langfuse trace shows the LLM span as a long-lived span with
  token timestamps as events (or as multiple short spans, depending on
  what OpenLLMetry chooses to emit).

---

## 4. Networking & ports (post-Phase-2)

| Service | Host port | Internal | Purpose | New / existing |
| ------- | --------- | -------- | ------- | -------------- |
| streamlit | 8501 | app:8501 | UI | existing |
| litellm | 4000 | litellm:4000 | gateway + `/metrics/` | existing |
| litellm-db | — | litellm-db:5432 | virtual keys + budgets | **2.4** |
| vllm | 8000 | vllm-engine:8000 | OpenAI API + /metrics | existing |
| triton | 8002 | triton-server:8002 | Triton /v2 inference | **2.0** |
| triton-metrics | 8004 | triton-server:8004 | TRT-LLM Prometheus metrics | **2.0** |
| prometheus | 9090 | prometheus:9090 | metrics UI | existing |
| grafana | 3000 | grafana:3000 | dashboards | existing |
| langfuse | 3001 | langfuse:3000 | UI + OTLP | existing (v3) |
| langfuse-db | — | langfuse-db:5432 | metadata | existing |
| langfuse-clickhouse | — | langfuse-clickhouse:8123 | event store | **2.1** |
| langfuse-redis | — | langfuse-redis:6379 | queue | **2.1** |
| langfuse-minio | — | langfuse-minio:9000 | object store | **2.1** |
| langfuse-worker | — | (no port) | ingest worker | **2.1** |
| otel-collector | 4318 | otel-collector:4318 | OTLP receiver | **2.2** |
| otel-collector-metrics | 8888 | otel-collector:8888 | collector's own metrics | **2.2** |
| loki | 3100 | loki:3100 | log store + query | **2.3** |
| promtail | — | (no port) | log scraper | **2.3** |
| dcgm/node/cadvisor/mock-services | — | as Phase 1 | — | existing |

Host ports kept low and stable; nothing gets re-shuffled.

---

## 5. Implementation order

The sub-phases are **mostly independent**, so we can do them in the
"highest learning per hour" order, not strictly sequentially:

```
   2.0 (Triton/TRT)           ◀── parallelisable with anything; isolated to inference
                              \\
                               \\── 2.1 (Langfuse v3) ──▶ 2.2 (OTel / OpenLLMetry)
                              //
   2.3 (Loki/Promtail)        ◀── parallelisable; touches grafana/datasources only
   2.4 (virtual keys)         ◀── parallelisable; touches litellm + app sidebar
   2.5 (streaming)            ◀── can land any time; nicer once 2.4 is in (per-tenant TTFT)
```

Recommended sequence:

1. **2.1 + 2.2 together** (one PR each, but planned as a pair) — the v3
   upgrade is the prerequisite for OTLP; finishing the trace story first
   means every later sub-phase debugs with the better trace UX.
2. **2.3** — logs unlock cross-pillar debugging for the remaining phases.
3. **2.0** — Triton compile is a one-off chore worth getting out of the
   way; the headline lesson is in the dashboards.
4. **2.4** — virtual keys are a small-ish PR that unlocks per-tenant
   panels.
5. **2.5** — streaming is the *most user-visible* change; saved for last
   so the dashboard / trace assumptions it changes don't churn the prior
   work.

---

## 6. Trade-offs & deferred decisions

| Decision | Choice | Trade-off |
| -------- | ------ | --------- |
| TRT-LLM via Triton, not via vLLM's experimental TRT-LLM backend | Triton is the production-realistic story; vLLM's TRT backend is single-process and skips the "different inference server" lesson | More moving parts; engine compile is GPU-specific |
| Langfuse v3 with self-hosted CH/Redis/Minio | Production-shaped — what you'd run if Langfuse Cloud weren't an option | +4 containers, ~6 GB extra RAM, more failure modes |
| OTel Collector in the path | Future-proof routing point; matches what a real org would deploy | One extra hop and config file to maintain |
| Loki single-binary | Sandbox-appropriate | Won't scale; not a goal |
| Promtail (not Grafana Alloy) | Today's stable Docker-SD path | Promtail goes into maintenance mode in 2026; revisit |
| Per-tenant via virtual keys (not just X-User-Id) | Surfaces the `end_user` Prometheus label LiteLLM only emits with virtual keys | One more Postgres + a seed script |
| Streaming via `astream_events("v2")` | LangChain's recommended path; auto-instrumented | Async-only; sync code paths kept for tests |
| Drop v2 traces during v3 upgrade | Simpler; traces are reproducible | Loses Phase 1's recorded examples — fine since `scripts/load.sh` repopulates in minutes |

**Explicitly NOT in scope** (carried forward from Phase 1's "Out of scope"):
- Grafana alerts / Alertmanager
- Authenticated Grafana
- Cost tracking against *real* pricing data (vLLM/Triton are free; synthetic OK)
- Llama-class models (still 8 GB GPU constraint)
- Multi-GPU / model parallelism

---

## 7. Prerequisites (host-side, on top of Phase 1)

- Disk: budget another ~15 GB for ClickHouse + Loki + Minio + the TRT-LLM
  engine + extra Docker images.
- RAM: ~6 GB extra at idle, ~10 GB during the TRT-LLM compile.
- The `nvcr.io/nvidia/tritonserver:25.04-trtllm-python-py3` image is large
  (~25 GB unpacked). First pull is slow; once cached, container starts in
  ~5 seconds.
- `scripts/preflight.sh` gets new checks for: Triton image present (warn-only),
  disk free ≥45 GB, env vars (`CLICKHOUSE_PASSWORD` etc.) set.

---

## 8. What "done" looks like for Phase 2

You can open the repo cold, run `docker compose up`, wait ~2 minutes for
everything to settle, and:

1. Visit `http://localhost:8501`, pick a tenant (alice/bob/carol), ask a
   multi-part question, see tokens streaming in.
2. Pick the same trace in Langfuse v3 — see `httpx.GET` sub-spans under
   each tool span. Filter by `user_id="alice"`.
3. Open the trace's timestamp window in Grafana, switch to the
   `01-llm-overview` dashboard — TTFT panel, GPU saturation, AND a
   "LiteLLM access log" panel show the same window with `user="alice"`
   matching.
4. Open the `04-tenants` dashboard, see alice/bob/carol's request rate
   and spend split by virtual key.
5. In `litellm/config.yaml`, swap `qwen-chat` for `qwen-chat-trt` in
   `model_group_alias`, redeploy, watch the GPU power signature change
   on the saturation dashboard — same app, same prompt, different
   engine.
6. Open every per-service README and have the new configuration explained
   well enough to modify it confidently.

That's the test: Phase 1's seams held under five orthogonal changes, the
observability got *better* (logs joined the party, traces got richer),
and the app didn't change except where the experience changed.
