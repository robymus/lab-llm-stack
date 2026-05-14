# LLM SRE Sandbox — Phase 2 TODO

> Source of truth: [.plans/phase2-PLAN.md](./phase2-PLAN.md). Section/sub-phase numbers in parens point back at the plan.
> Convention (carried over from Phase 1): every task ends in something runnable or readable. No "scaffolding" tasks that leave the repo in a half-built state — each task is small enough to commit on its own.
> Order: follows the plan's §5 "Implementation order" recommendation — 2.1+2.2 first (better trace UX for everything that follows), then 2.3 (logs unlock cross-pillar debugging), then 2.0 (Triton chore), then 2.4 (virtual keys), then 2.5 (streaming).

---

## Phase 2.0 — Image pre-pull (preamble, runs in background)

> Exit: every container image referenced by Phase 2 is present in the local Docker image cache, so subsequent sub-phases never block on a slow `docker pull` mid-bring-up. The Triton image (~25 GB unpacked) is the long pole — kick it off first.

- [x] Confirm host has ≥45 GB free disk before pulling (per plan §7); abort with a friendly message if not
- [x] Pull `nvcr.io/nvidia/tritonserver:25.04-trtllm-python-py3` (~25 GB, longest — start first) *(scripted; user runs)*
- [x] Pull `clickhouse/clickhouse-server:24.10-alpine` *(scripted; user runs)*
- [x] Pull `redis:7-alpine` *(scripted; user runs)*
- [x] Pull `minio/minio:RELEASE.2024-11-07T00-52-20Z` *(scripted; user runs)*
- [x] Pull `langfuse/langfuse-worker:3.174.1` *(pinned; scripted; user runs)*
- [x] Pull `langfuse/langfuse:3.174.1` *(pinned; replaces v2.95.11; scripted; user runs)*
- [x] Pull `otel/opentelemetry-collector-contrib:0.114.0` *(scripted; user runs)*
- [x] Pull `grafana/loki:3.3.0` *(scripted; user runs)*
- [x] Pull `grafana/promtail:3.3.0` *(scripted; user runs)*
- [x] Write `scripts/pull-phase2-images.sh` (idempotent loop, ≥45 GB disk check, serial pulls so progress is readable, retry-friendly summary). Per user preference, **not run in the background** — user runs it manually to watch progress.
- [x] Record final sizes in a comment at the top of the script (Triton ~25 GB is the surprise; total ~29 GB extra)

---

## Phase 2.1 — Langfuse v3 (ClickHouse + Redis + Minio + worker)

> Exit: all five new Langfuse-side services healthy; Langfuse v3 UI at `:3001` loads; org/project/keys recreated; existing `app/agent.py` (still on v2 callback) still writes traces that appear in the v3 UI; `curl :3001/api/public/otel/v1/traces` returns 401 (proves OTLP path exists, just needs auth).

### Backing services
- [x] Add `langfuse-clickhouse` service (`clickhouse/clickhouse-server:24.10-alpine`): named volume `langfuse-clickhouse-data`, env (`CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`, `CLICKHOUSE_DB`), `wget /ping` healthcheck, no host port. `user: 101:101` per upstream compose so volume ownership matches the image's `clickhouse` uid.
- [x] Add `langfuse-redis` service (`redis:7-alpine`): `--requirepass` from env via `REDIS_PASSWORD` container env, `--maxmemory-policy noeviction`, `--appendonly yes`, `redis-cli -a "$$REDIS_PASSWORD" --no-auth-warning ping` healthcheck. Named volume `langfuse-redis-data` for AOF durability across restarts.
- [x] Add `langfuse-minio` service (`minio/minio:RELEASE.2024-11-07T00-52-20Z`): `entrypoint: sh; command: -c 'mkdir -p /data/langfuse && exec minio server --address :9000 --console-address :9001 /data'` (pre-creates the bucket, matching upstream Langfuse compose pattern). Named volume `langfuse-minio-data`, `mc ready local` healthcheck, internal-only.
- [x] Add a YAML anchor `x-langfuse-env: &langfuse-env` at the top of `docker-compose.yaml`. Includes DATABASE_URL, CLICKHOUSE_URL + **CLICKHOUSE_MIGRATION_URL** (v3 needs both; the latter uses the native protocol on :9000), CLICKHOUSE_USER/PASSWORD, REDIS_HOST/PORT/AUTH, all `LANGFUSE_S3_EVENT_UPLOAD_*` (region `us-east-1` — "auto" is rejected by the AWS SDK), NEXTAUTH_URL/SECRET, SALT, **ENCRYPTION_KEY** (new in v3 — 64 hex chars), TELEMETRY_ENABLED=false. Merged into both `langfuse` and `langfuse-worker` via `<<: *langfuse-env`.

### Langfuse v3 (web + worker)
- [x] Bump `langfuse` image from `langfuse:2.95.11` → pinned `langfuse/langfuse:3.174.1` (latest stable v3 at pin time); switch to `<<: *langfuse-env`; keep `:3001:3000`; keep `$(hostname)`-based health workaround for v3's Next.js standalone binding. `start_period` raised to 120s because v3 runs both Prisma (PG) AND ClickHouse schema migrations on first start.
- [x] Add `langfuse-worker` service (`langfuse/langfuse-worker:3.174.1`): same `<<: *langfuse-env`, no published port (in-network health probe on `:3030/api/health`), `depends_on: { langfuse-db, langfuse-clickhouse, langfuse-redis, langfuse-minio: { condition: service_healthy } }`
- [x] Update existing `langfuse` `depends_on` to also wait on `langfuse-clickhouse`, `langfuse-redis`, `langfuse-minio` healthy
- [x] `langfuse-db`'s service spec unchanged — Postgres still hosts metadata; v3 just adds ClickHouse alongside, doesn't replace it

### Clean cut — drop v2 trace data (option A in the plan)
- [x] Document the destructive step (`docker compose down langfuse langfuse-db && docker volume rm llm-stack_langfuse-pg-data`) in `langfuse/README.md` — user runs it, not us. New "Upgrading from v2" section.
- [ ] *(user-side)* Re-run the first-time UI setup (org/project/keys), put the new key pair in `.env` — happens when user does the cut

### Env, secrets, docs
- [x] Add to `.env.example`: `CLICKHOUSE_PASSWORD`, `REDIS_PASSWORD`, `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`, `LANGFUSE_ENCRYPTION_KEY` (with phase-2.1 comments + `openssl rand -hex 32` hint for ENCRYPTION_KEY)
- [x] Update `langfuse/.env.langfuse.example` with the full v3 env block — sectioned by store (PG / CH / Redis / Minio / NextAuth / encryption / telemetry / API keys)
- [x] Rewrite `langfuse/README.md` — replaced "Why not v3?" with "v3 architecture" (containers table, ingest-path ASCII diagram, per-service walkthrough), refreshed the troubleshooting matrix for v3's failure modes (CH migration URL, missing ENCRYPTION_KEY, worker queue backlog, etc.), kept the v2-compat note for Phase 2.1's transitional state
- [x] Add v3-aware checks to `scripts/preflight.sh`: required `.env` vars (`CLICKHOUSE_PASSWORD`, `REDIS_PASSWORD`, `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`, `LANGFUSE_ENCRYPTION_KEY`); ENCRYPTION_KEY shape regex `^[0-9a-fA-F]{64}$`; disk-free bumped to ≥45 GB hint

### Pins + validation
- [x] Update `VERSIONS.md`: langfuse bumped to v3.174.1, langfuse-worker / clickhouse / redis / minio rows added with last-verified 2026-05-14
- [x] `docker compose config -q` passes cleanly (only env-var warnings, which `.env` populates)
- [x] yamllint -s . passes
- [x] *(user-side)* `docker compose up -d` brings all five new services to healthy — gated on pull-phase2-images.sh completing
- [x] *(user-side)* Smoke test: load existing `app/agent.py` once, confirm a trace shows up in v3 UI (v3 SDK is back-compat with v2 callback per plan)
- [x] *(user-side)* Smoke test: `curl -i http://localhost:3001/api/public/otel/v1/traces` returns 401 — OTLP path reachable
> Actually returned 405 Method not allowed

---

## Phase 2.2 — OpenLLMetry + OTel Collector

> Exit: a multi-tool prompt in Streamlit produces a Langfuse v3 trace with `httpx.GET` spans as children of each tool span (the thing we lost in Phase 1.2); `docker compose logs otel-collector` shows trace batches every ~200 ms during traffic; the `otelcol_exporter_sent_spans` counter is visible in Prometheus and on the LLM Overview dashboard.

### Collector service + config
- [x] Add `otel-collector` service (`otel/opentelemetry-collector-contrib:0.114.0`): mount `./otel/config.yaml:/etc/otel/config.yaml:ro`, expose `4318` (OTLP HTTP), `13133` (health), `8888` (metrics), `depends_on: langfuse healthy`. **No healthcheck** — the contrib image is distroless (only `/otelcol-contrib`, no shell/wget/curl); consumers use `condition: service_started` instead. Documented inline in compose.
- [x] Write `otel/config.yaml`: OTLP receiver (HTTP on 4318 + gRPC on 4317 internal), `batch` processor (`200ms` / `8192`), `attributes/source` processor (insert `source: otel-collector`), **`attributes/langfuse_mapping` processor** (upserts `langfuse.user.id` from `traceloop.association.properties.user_id`, same for session_id — without this the native userId field stays null), `otlphttp/langfuse` exporter pointing at `http://langfuse:3000/api/public/otel`, `debug` exporter (`verbosity: detailed` — TODO to remove after stabilisation), `basicauth/langfuse` extension, `health_check` extension on 13133, telemetry `metrics.address: 0.0.0.0:8888` (deprecation warn but works on v0.114)
- [x] Write `otel/README.md`: what the collector is, why it sits between app and Langfuse, the future-proofing argument, how to add a new exporter/receiver, basicauth wiring, the `debug` exporter caveat with a "remove this once stable" TODO

### App-side rewrite (replace v2 callback with OpenLLMetry)
- [x] Update `app/requirements.txt`: add `traceloop-sdk==0.60.0` (latest stable; 0.30.x didn't exist), add `opentelemetry-instrumentation-httpx==0.62b1` (traceloop doesn't auto-instrument generic HTTP clients), pin `wrapt==1.17.2` (workaround for the wrapt-2 incompat in langchain instrumentor 0.60.x), drop the v2 Langfuse SDK
- [x] Rewrite `app/agent.py` tracing init: `Traceloop.init(...)` at module top, then `HTTPXClientInstrumentor().instrument()`, all BEFORE any `from langchain... / from openai...` imports
- [x] Remove `CallbackHandler` import + `self._handler` field + `config={"callbacks": [self._handler]}` from `Agent.invoke()`
- [x] Replace user_id propagation: `Traceloop.set_association_properties({"user_id": ..., "session_id": ...})` at the start of each `chat()` call (note: API is `Traceloop.set_association_properties`, not `from traceloop.sdk.tracing import set_association_properties` as the plan said)
- [x] Update `app/README.md` tracing section: "OTLP path restored", new trace-tree ASCII showing the httpx sub-spans, ordering caveat (Traceloop.init before framework imports), updated troubleshooting matrix

### Compose + Prometheus wiring
- [x] Update `app` service env: dropped `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY`; added `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318`, `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`, `OTEL_SERVICE_NAME=llm-sandbox-app`, `TRACELOOP_METRICS_ENABLED=false` (kills the metrics-export 404 chatter)
- [x] Update `app` `depends_on` to `otel-collector: { condition: service_started }` (distroless = no healthcheck — see above)
- [x] Move `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` env passthrough onto the `otel-collector` service (basicauth extension reads them at startup)
- [x] Add Prometheus scrape job for the collector: `targets: [otel-collector:8888]`, `labels: { layer: traces }`
- [x] Add two panels (id 9 + 10) on `grafana/dashboards/01-llm-overview.json` at y=32: span throughput (received vs exported) and export failures + queue depth

### Env, pins, validation
- [x] Re-introduce `OTEL_EXPORTER_OTLP_ENDPOINT` in `.env.example` (host-side runs only; in-compose env block overrides)
- [x] Update `VERSIONS.md`: add `otel-collector:0.114.0` image pin, update Python-deps blurb to mention `traceloop-sdk==0.60.0`
- [x] Multi-tool prompt via `docker compose exec app python ...` produced a Langfuse trace with `GET` + `POST` httpx sub-spans alongside `ChatOpenAI.chat`, `get_current_weather`, etc.
- [x] `otelcol_receiver_accepted_spans` and `otelcol_exporter_sent_spans` increment 1:1, `send_failed_spans=0` (verified via `:8888/metrics` and the new Grafana panels)
- [x] Prometheus reload picks up the new `otel-collector` scrape target — `up{job="otel-collector"}=1`

---

## Phase 2.3 — Logs pillar (Loki + Promtail)

> Exit: every Phase-1/Phase-2 container's logs queryable in Grafana via `{service="<name>"}`; the "LiteLLM access log" panel on the overview dashboard populates with parsed JSON fields; a trace ↔ log walkthrough lives in `docs/05-trace-log-correlation.md`.

### Loki service
- [ ] Add `loki` service (`grafana/loki:3.3.0`): mount `./loki/loki.yaml:/etc/loki/loki.yaml:ro`, named volume `loki-data:/loki`, expose `3100:3100`, `wget /ready` healthcheck
- [ ] Write `loki/loki.yaml`: single-binary config (no separate ingester/distributor/querier — sandbox-appropriate per plan), filesystem storage, reasonable retention (e.g. 7d to mirror Prometheus)
- [ ] Write `loki/README.md`: what Loki is, why single-binary is enough for the sandbox, retention knob, smoke test (`curl :3100/ready`), troubleshooting matrix (ring failures, schema migration, etc.)

### Promtail service + config
- [ ] Add `promtail` service (`grafana/promtail:3.3.0`): mount `/var/run/docker.sock:/var/run/docker.sock:ro`, `/var/lib/docker/containers:/var/lib/docker/containers:ro`, `./promtail/promtail.yaml:/etc/promtail/promtail.yaml:ro`, `depends_on: loki healthy`, no host port
- [ ] Write `promtail/promtail.yaml`: docker_sd_configs against the host socket; relabel `__meta_docker_container_label_com_docker_compose_service` → `service`, `..._project` → `project`, `__meta_docker_container_name` → `container`; `cri: {}` pipeline stage to parse Docker's CRI format
- [ ] Write `promtail/README.md` (or merge into `loki/README.md`): label scheme, why we use Promtail not Alloy (plan trade-off — Promtail enters maintenance mode in 2026, revisit later), how to add a custom pipeline stage for a particular service

### Grafana wiring
- [ ] Add Loki datasource block to `grafana/provisioning/datasources/datasources.yml`: `uid: loki`, `url: http://loki:3100`, `editable: false`, `maxLines: 5000`
- [ ] Add a "LiteLLM access log (last 10 min)" logs panel to `grafana/dashboards/01-llm-overview.json` using `{service="litellm"} | json | line_format "..."` — keep formatting minimal, no over-design

### Cross-pillar walkthrough doc
- [ ] Write `docs/05-trace-log-correlation.md`: open a trace in Langfuse v3 → copy wall-clock window → switch to the LLM Overview dashboard with that time range → spot the matching access-log line by user_id. This is the headline demo of the phase — make sure the screenshots / commands are unambiguous

### Pins + validation
- [ ] Update `VERSIONS.md`: add `loki` and `promtail` pins
- [ ] `docker compose up -d`; in Grafana's Explore, run `{service="litellm"}` and confirm log lines stream during traffic
- [ ] Repeat for `{service="vllm-engine"}`, `{service="app"}` — confirm labels are populated by docker-SD as expected

---

## Phase 2.0 (deferred to here per plan §5) — Triton + TensorRT-LLM second backend

> Exit: `curl :4000/v1/chat/completions -d '{"model":"qwen-chat-trt", ...}'` returns a Qwen completion from Triton; Streamlit chat still works with `model="qwen-chat"` (vLLM unchanged); new Grafana dashboard `03-trt-llm` shows TRT-LLM request latency curves under load; `triton/README.md` documents rebuild + GPU-specific binary + troubleshooting.

### Engine build (host-side, one-off)
- [ ] Write `scripts/build-trt-engine.sh` calling `nvcr.io/nvidia/tritonserver:25.04-trtllm-python-py3` with `trtllm-build` flags: `--gemm_plugin float16`, `--gpt_attention_plugin float16`, `--max_batch_size 8`, `--max_input_len 3072`, `--max_output_len 1024`, `--use_paged_context_fmha enable` — output to `triton/engines/qwen-chat-trt/`
- [ ] Add header to the script documenting: ~10–15 min build on Ada, ~3 GB output, engine is GPU-specific (SM 8.9 only, won't run anywhere else)
- [ ] Add `triton/engines/` and `triton/model_repository/qwen-chat-trt/1/` to `.gitignore` (binary artefacts not committed)
- [ ] Commit the `config.pbtxt` template under `triton/model_repository/qwen-chat-trt/` (template only — generated `.engine` stays untracked)

### Triton service
- [ ] Add `triton-server` service (`nvcr.io/nvidia/tritonserver:25.04-trtllm-python-py3`): `command: [tritonserver, --model-repository=/models, --log-verbose=1, --http-port=8002, --grpc-port=8003, --metrics-port=8004]`, mount `./triton/model_repository:/models:ro`, expose `8002:8002` + `8004:8004`, GPU reservation, `/v2/health/ready` healthcheck with `start_period: 90s`
- [ ] Add the plan's "due to 8 GB GPU constraint, commenting vLLM out is fine" note inline in compose (so the reader sees it next to both services)

### LiteLLM second backend entry
- [ ] Edit `litellm/config.yaml`: add a second `model_list` entry — `model_name: qwen-chat-trt`, `litellm_params: { model: triton/qwen-chat-trt, api_base: http://triton-server:8002 }` (native `triton/` provider — no custom adapter)
- [ ] Add (commented-out) `router_settings.model_group_alias: { qwen-chat: [qwen-chat, qwen-chat-trt] }` block — the optional "swap to TRT without app changes" lesson
- [ ] Update `litellm/README.md` with the second-backend example + the alias lesson

### Prometheus + Grafana
- [ ] Add Prometheus scrape job `triton` against `triton-server:8004` with `labels: { layer: inference }`
- [ ] Write new `grafana/dashboards/03-trt-llm.json` with `nv_inference_request_duration_us` and `nv_inference_compute_infer_duration_us` panels (request latency vs. compute-only) — additive only, do not touch the vLLM panels
- [ ] Note in the dashboard description: the gateway p95 panel auto-includes both backends (aggregates by `model` label)

### Docs + load testing
- [ ] Write `triton/README.md`: what it is, how to rebuild engines, GPU-specific binary caveat, smoke tests, troubleshooting matrix
- [ ] Extend `scripts/load.sh` (or its trunks equivalent) with a `--model qwen-chat-trt` mode so the headline TRT dashboard can be driven

### Pins + validation
- [ ] Update `VERSIONS.md`: add `triton-server` image pin
- [ ] Smoke test: `curl :4000/v1/chat/completions -d '{"model":"qwen-chat-trt", ...}'` returns a completion
- [ ] Smoke test: while only Triton is up, the original `qwen-chat` model also still works *if* both backends are mapped through the alias (and stops working if only TRT is alive without alias — document this as expected)

---

## Phase 2.4 — Virtual API keys + per-tenant cost + rate limits

> Exit: two parallel `curl` requests to `:4000/v1/chat/completions` with different virtual keys produce two distinct `end_user` series in Prometheus; the new `04-tenants` dashboard plots them side-by-side; exceeding a key's RPM returns HTTP 429 with the `rate_limit` reason; spend counters increment on each call (synthetic pricing).

### LiteLLM persistence
- [ ] Add `litellm-db` service (`postgres:16-alpine`): env (`POSTGRES_USER=litellm`, `POSTGRES_PASSWORD=${LITELLM_DB_PASSWORD}`, `POSTGRES_DB=litellm`), named volume `litellm-pg-data:/var/lib/postgresql/data`, `pg_isready` healthcheck, no host port
- [ ] Wire LiteLLM to it: add `general_settings: { master_key: os.environ/LITELLM_MASTER_KEY, database_url: os.environ/LITELLM_DATABASE_URL, allowed_fails: 3, budget_tracker: enabled }` to `litellm/config.yaml`
- [ ] Add LiteLLM-side feature flags: `litellm_settings: { callbacks: [prometheus], forward_client_headers_to_llm_api: true, enable_end_user_cost_tracking: true, rpm_limit: 60 }`
- [ ] Update `litellm` compose service env: add `LITELLM_DATABASE_URL=postgresql://litellm:${LITELLM_DB_PASSWORD}@litellm-db:5432/litellm`, `depends_on: litellm-db healthy`

### Virtual-key bootstrap
- [ ] Write `scripts/seed-virtual-keys.sh`: hits `/key/generate` with master key, loops over `alice`/`bob`/`carol`, parses `.key` field, writes `LITELLM_KEY_ALICE=...` etc. to `.env.virtual-keys` (gitignored). Idempotent — skip if `.env.virtual-keys` already populated
- [ ] Add `.env.virtual-keys` to `.gitignore`
- [ ] Document in `litellm/README.md`: when to run the seed script (once per fresh `litellm-pg-data` volume), how to rotate, how to delete a key via curl

### App-side tenant picker
- [ ] Add tenant selector to `app/app.py` sidebar: `tenant = st.sidebar.selectbox("Tenant", ["alice", "bob", "carol"])`
- [ ] Pass `api_key = os.environ[f"LITELLM_KEY_{tenant.upper()}"]` through to `ChatOpenAI` (replaces the master-key bearer)
- [ ] Compose: inject `LITELLM_KEY_ALICE`, `LITELLM_KEY_BOB`, `LITELLM_KEY_CAROL` into the `app` service env (sourced from `.env.virtual-keys` via `env_file:` or explicit passthrough)
- [ ] Keep the existing `default_headers={"X-User-Id": user_id}` — redundant once virtual keys carry identity, but harmless and useful as a fallback

### Dashboards + recording rules
- [ ] Write `grafana/dashboards/04-tenants.json`: request-rate-per-end_user (from `litellm_requests_total{end_user=...}`), spend-per-end_user (from `litellm_spend_metric{end_user=...}`), 429 rate-limit hits panel
- [ ] Add per-tenant recording rules to `prometheus/rules/llm.rules.yml`: pre-aggregate per-`end_user` request rate / token usage / spend at 30s/5m windows

### Env, pins, validation
- [ ] Add to `.env.example`: `LITELLM_DB_PASSWORD` (with phase-2.4-tag comment)
- [ ] Update `VERSIONS.md`: no new pin (postgres already pinned in Phase 1)
- [ ] Smoke test: two parallel curls with different virtual keys → two `end_user` series in Prometheus
- [ ] Smoke test: hammer one key past its 30 RPM → HTTP 429 + the `04-tenants` rate-limit panel ticks up
- [ ] Smoke test: spend counter increments per call (synthetic pricing is fine — the lesson is the plumbing)

---

## Phase 2.5 — Streaming end-to-end

> Exit: tokens render in Streamlit incrementally instead of in one block; the TTFT panel on the overview dashboard correlates with vLLM's `time_to_first_token_seconds` histogram during a `scripts/load.sh decode-heavy` run; a streaming Langfuse trace shows the LLM span as long-lived with token timestamps (or as multiple short spans — depends on OpenLLMetry's emission shape, document whichever we see).

### Agent loop
- [ ] Verify LiteLLM's `triton/` provider supports streaming on the pinned version (per plan: 1.50+; confirm at impl time)
- [ ] Add async `chat_stream(user_input, history)` method to `app/agent.py` using `self._executor.astream_events(..., version="v2")`
- [ ] In the event loop, yield text from `on_chat_model_stream` chunks; emit a `\n_calling {tool}..._\n` marker on `on_tool_start`; suppress `on_tool_end` payloads (tool results not surfaced)
- [ ] Keep the existing sync `chat()` method for the test harness — async-only is the new default for the UI, sync stays for tests (per plan trade-off)
- [ ] Call `set_association_properties({"user_id": ...})` at the top of `chat_stream` too (so streamed traces still carry tenant identity)

### Streamlit surface
- [ ] Replace the assistant-message render with `full = st.write_stream(executor.chat_stream(prompt, prior))` inside the `st.chat_message("assistant"):` block
- [ ] Smoke test: in the browser, the first token appears visibly before the response is complete

### Dependencies
- [ ] Bump `anyio` in `app/requirements.txt` if needed (verify at impl time — `astream_events("v2")` requires a recent enough anyio)

### Metrics + dashboards
- [ ] Promote `vllm:time_to_first_token_seconds` to a top-line "p95 TTFT" panel on `01-llm-overview.json` — sit it next to the existing p95 end-to-end latency panel (two distinct stories, plan calls this out)
- [ ] Add a brief note to the dashboard description explaining when TTFT matters vs. end-to-end latency

### Docs
- [ ] Write `docs/06-streaming.md`: what TTFT is, what the user perceives, how the trace shape changes (long-lived LLM span vs. multiple short spans — document whatever OpenLLMetry actually emits), what to watch on the dashboard during a decode-heavy load run
- [ ] Update `app/README.md`: explain why streaming changes the trace shape, when to flip back to the sync code path (tests, regression suite)

### Validation
- [ ] Run `scripts/load.sh` in decode-heavy mode (or trunks equivalent); confirm p95 TTFT panel moves independently of end-to-end p95
- [ ] Open a streamed trace in Langfuse v3; record the actual shape (single long span vs. many small ones) in `docs/06-streaming.md`

---

## Cross-phase polish (final pass)

> Exit: the "what done looks like" walkthrough in plan §8 runs cold from a fresh clone — no surprises.

- [ ] Remove the temporary `debug` exporter from `otel/config.yaml` (TODO opened in Phase 2.2)
- [ ] Refresh `ARCHITECTURE.md`: redraw the diagram, refresh layer table, refresh request flow, add a "what changed in Phase 2" section
- [ ] Refresh root `README.md` quickstart: new env vars, new ports table (per plan §4), pointer to `scripts/pull-phase2-images.sh` for first-time setup
- [ ] Refresh `CODEBASE.md` with the post-Phase-2 layout (new service dirs: `otel/`, `loki/`, `promtail/`, `triton/`)
- [ ] Final pass on every per-service README to make sure the headline "what moved and what didn't" lesson is visible in each one (plan §1 promise)
- [ ] Walk the §8 "what done looks like" steps end-to-end as a final smoke test — fix anything that surprises us
