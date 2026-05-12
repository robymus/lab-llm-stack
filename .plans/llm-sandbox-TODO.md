# LLM SRE Sandbox — Phase 1 TODO

> Source of truth: [.plans/llm-sandbox-PLAN.md](./llm-sandbox-PLAN.md). Section numbers in parens point back at the plan.
> Convention: every task ends in something runnable or readable. No "scaffolding" tasks that leave the repo in a half-built state — each task is small enough to commit on its own.

---

## Phase 1.0 — Infra skeleton

> Exit: `curl litellm:4000/v1/chat/completions` from inside the network returns a Qwen completion, and every line in `docker-compose.yaml` is explained by a comment or a README.

### Prerequisites & host readiness *(added during 1.0)*
- [x] Verify host: Docker, Compose, NVIDIA driver, GPU, disk free
- [x] Write `scripts/preflight.sh` covering all plan §9 checks with PASS/FAIL output and fix hints
- [x] **BLOCKER for first `docker compose up`**: install `nvidia-container-toolkit` and register the nvidia runtime with Docker (commands listed in preflight output)
> Done.

### Repo bootstrap
- [x] Create root README.md with quickstart, smoke-test commands, and links to ARCHITECTURE/PLAN/TODO
- [x] Create `.gitignore` covering `.env`, container-mounted state, Python noise, editor noise
- [x] Create `.env.example` with every var the stack reads, phase-tagged comments
- [x] Create service directories with placeholder READMEs for the ones not implemented yet (`app/`, `mock-services/`, `prometheus/`, `grafana/`, `dcgm/`, `docs/`)
- [x] `git init` done; first commit left for the user to make (per global "never auto-commit" rule)

### docker-compose foundation
- [x] `docker-compose.yaml` skeleton: `name: llm-stack`, single `llm-stack` bridge network, named volumes `hf-cache`/`langfuse-pg-data`/`prometheus-data`/`grafana-data`
- [x] Top-of-file comment block explaining reading order, conventions, and the deliberate omission of `version:`
- [x] `docker compose config -q` passes

### vLLM service (plan §5.1)
- [x] `vllm-engine` service added: pinned `vllm/vllm-openai:v0.6.6`, full flag set, `hf-cache` volume, GPU reservation, `/health` healthcheck with 120s start_period, `shm_size: 2gb`
- [x] Every flag inline-commented explaining *why* it's set
- [x] `vllm/README.md`: what vLLM is, flag-by-flag walkthrough, key `/metrics` series, smoke tests, troubleshooting matrix
- [x] Smoke test: `docker compose up vllm-engine` + `curl :8000/v1/models` — _runnable after the toolkit install_

### LiteLLM gateway (plan §5.2)
- [x] `litellm/config.yaml`: `model_list` with the Phase 2 seam clearly commented, `callbacks: ["prometheus"]`, `forward_client_headers_to_llm_api: true`, `master_key: os.environ/LITELLM_MASTER_KEY`
- [x] `litellm` service added: pinned `ghcr.io/berriai/litellm:main-stable`, port 4000:4000, bind-mounted config (read-only), `depends_on: vllm-engine healthy`, env via `${LITELLM_MASTER_KEY}`, healthcheck on `/health/liveliness`
- [x] `litellm/README.md`: what LiteLLM is, the Phase 2 seam (with diff example), config walkthrough, smoke tests, `/metrics` discovery, troubleshooting matrix
- [x] Smoke test: gateway returns a completion through `:4000` — _runnable after the toolkit install_
- [x] Smoke test: `curl :4000/metrics/` returns Prometheus format — _runnable after the toolkit install_

### Langfuse v2 + Postgres (plan §5.7)
- [x] `langfuse-db` service: `postgres:16-alpine`, named volume, password via `${LANGFUSE_DB_PASSWORD}`, `pg_isready` healthcheck, no host port
- [x] `langfuse` service: pinned `langfuse/langfuse:2`, port 3001:3000, `depends_on: langfuse-db healthy`, env (DATABASE_URL, NEXTAUTH_URL/SECRET, SALT, TELEMETRY_ENABLED=false), `/api/public/health` healthcheck
- [x] `langfuse/.env.langfuse.example` with per-var comments
- [x] `langfuse/README.md`: what v2 is, why-not-v3 table, config walkthrough, first-run UI setup steps, OTLP endpoint, smoke tests, troubleshooting matrix
- [x] Smoke test: open `http://localhost:3001`, create org/project, write keys into `.env` — _user action; preflight auto-computes LANGFUSE_AUTH_B64 from the pair_

### Compose-wide validation
- [x] `docker compose config -q` parses clean after every edit
- [x] All services healthy under `docker compose up -d` — _blocked by toolkit install_
- [x] Quickstart + smoke-test commands documented in root `README.md`

### Architecture doc (kick-off)
- [x] `ARCHITECTURE.md`: ASCII diagram, layer table with deep-dive links, request flow (1.0 + future 1.2), Phase 2 swap point section, reading order, conventions

---

## Phase 1.1 — Hardware observability

> Exit: Grafana's `02-gpu-saturation` dashboard shows live power, SM activity, memory, and temperature curves while vLLM serves traffic.
>
> **Status: COMPLETE.** SM_ACTIVE (`DCGM_FI_PROF_SM_ACTIVE`) is gated to data-centre GPUs and unavailable on the 4060 (consumer Ada lacks the DCP profiling module — exporter log: *"Not collecting DCP metrics: This request is serviced by a module of DCGM that is not currently loaded"*). The dashboard substitutes `DEV_GPU_UTIL` + `SM_CLOCK` and documents the workaround in `dcgm/README.md`. Live power / temp / memory / clock curves all flow.

### DCGM exporter (plan §5.6)
- [x] `dcgm-exporter` added: pinned `nvcr.io/nvidia/k8s/dcgm-exporter:3.3.9-3.6.1-ubuntu22.04`, port 9400:9400, GPU reservation `capabilities: [gpu, utility]`, `cap_add: [SYS_ADMIN]`, bash-`/dev/tcp` healthcheck (image has no wget/curl, only bash)
- [x] `dcgm/dcp-metrics-included.csv`: 8 active DEV_* fields, 4 PROF_* fields commented out with rationale (uncomment on data-centre GPU)
- [x] `dcgm/README.md`: per-field physical meaning, SM_ACTIVE-vs-GPU_UTIL explanation, why PROF_* is gated, smoke tests, troubleshooting matrix
- [x] Smoke tests: `curl :9400/metrics` returns plausible DCGM_FI_DEV_POWER_USAGE; verified against `nvidia-smi --query-gpu=power.draw`

### Host + container metrics
- [x] `node-exporter` added: pinned `prom/node-exporter:v1.8.2`, port 9100:9100, `/proc`, `/sys`, `/` read-only with `rslave` propagation, filesystem mount-points-exclude list, `wget` healthcheck
- [x] `cadvisor` added: pinned `gcr.io/cadvisor/cadvisor:v0.49.2`, port 8080:8080, host mounts read-only, `/dev/kmsg`, `privileged: true`, `--disable_metrics` tuned (note: `accelerator` was removed in v0.49 — see comment), `wget` healthcheck on `/healthz`
- [x] Smoke tests: `/metrics` reachable on both (1333 series from node-exporter, 1010 from cAdvisor)

### Prometheus (plan §5.4)
- [x] `prometheus/prometheus.yml`: 5s scrape, 15s eval, `external_labels` (cluster + env), six scrape jobs each with `layer:` label, `metrics_path: /metrics/` on the `litellm` job (trailing slash matters — LiteLLM 307-redirects)
- [x] `prometheus/rules/llm.rules.yml`: three groups (`llm-gateway`, `vllm-engine`, `gpu-hardware`) — request rate/by-user/success-rate, p50/p95/api-only latency, tokens/s (gen + prompt), queue depth, active batch size, power 30s moving average, FB-used fraction. All names verified against live `/metrics` output before writing.
- [x] `prometheus` service: pinned `prom/prometheus:v3.1.0`, port 9090:9090, `--web.enable-lifecycle`, `--storage.tsdb.retention.time=7d`, bind-mounted config + named volume for TSDB, `wget /-/healthy` healthcheck
- [x] `prometheus/README.md`: scrape walkthrough, per-job notes (esp. the LiteLLM trailing-slash quirk), metric-name discovery recipe, 8 PromQL recipes including per-tenant rate and the prefill/decode pair, troubleshooting matrix
- [x] Smoke test: `:9090/targets` shows all six jobs UP (vllm, litellm, dcgm, node, cadvisor, prometheus)

### Grafana (plan §5.5)
- [x] `grafana/provisioning/datasources/datasources.yml`: Prometheus default with stable `uid: prometheus`, `editable: false`, `timeInterval: 5s` matching scrape interval
- [x] `grafana/provisioning/dashboards/dashboards.yml`: file provider into `LLM Stack` folder, `updateIntervalSeconds: 30`, `allowUiUpdates: true`
- [x] `grafana/dashboards/01-llm-overview.json`: 6 panels — request rate (with per-user overlay), p50/p95 latency (+ API-only), tokens/s (gen + prompt), queue+batch, KV cache gauge, prefix cache hit rate. Every panel has a `description`.
- [x] `grafana/dashboards/02-gpu-saturation.json`: 5 panels — power (raw + 30s avg), temp, FB stacked, clocks, plus the headline correlation panel: GPU power (left axis) ↔ p95 latency (right axis) on a shared time axis
- [x] `grafana` service: pinned `grafana/grafana:11.4.0`, port 3000:3000, anonymous read enabled, provisioning + dashboards bind-mounted read-only, `depends_on: prometheus healthy`, telemetry off
- [x] `grafana/README.md`: provisioning explained, per-panel "what to watch" tables for both dashboards, edit-then-export workflow for persisting UI changes, smoke tests, troubleshooting matrix
- [x] Smoke test: datasource provisioned (queryable), both dashboards visible in `LLM Stack` folder at `:3000`, panels populate against live traffic. Direct links: `/d/llm-overview/llm-overview`, `/d/gpu-saturation/gpu-saturation`.

### Compose-wide validation (Phase 1.1)
- [x] `docker compose config -q` parses clean
- [x] All 9 services reach healthy: cadvisor, dcgm-exporter, grafana, langfuse, langfuse-db, litellm, node-exporter, prometheus, vllm-engine

---

## Phase 1.2 — App + traces

> Exit: a Streamlit chat exchange with a multi-part prompt produces a Langfuse trace tree containing the chain root, multiple tool spans, an httpx GET span under each tool, the `X-User-Id` on the root span, and at least one error span when `flaky_call` rolls a 500.
>
> **Status: COMPLETE.** Two material deviations from the plan, both documented in PLAN §5.1 and §5.7 and in the per-service READMEs:
> 1. **Langfuse v2 does not accept OTLP/HTTP** (v3-only feature) — dropped `traceloop-sdk` and switched to the Langfuse-native LangChain `CallbackHandler`. The chain → llm → tool tree appears identically in the UI; the per-tool httpx sub-spans don't (workaround: `mock-services` exposes its own `/metrics` for that visibility).
> 2. **vLLM tool-calling needs explicit flags** — added `--enable-auto-tool-choice` and `--tool-call-parser hermes` to the vLLM command. Without them every agent turn 400s.

### Mock services (plan §5.8)
- [x] `mock-services/requirements.txt`: pinned fastapi==0.115.4, uvicorn[standard]==0.32.0, prometheus-fastapi-instrumentator==7.0.0
- [x] `mock-services/main.py`: six endpoints (`/health`, `/weather/{city}`, `/news`, `/stocks/{ticker}`, `/docs/search`, `/flaky`), all canned datasets as module-level constants, `/flaky` deterministic via md5(seed)[0]<76
- [x] `mock-services/Dockerfile`: python:3.11-slim, ENV PYTHONUNBUFFERED, deps before app code
- [x] `mock-services` service in compose: build context, port 9000:9000, python-based healthcheck on `/health`
- [x] Smoke tests: known/unknown city lookups (200/404), ticker lookups, news, doc search, flaky seed sweep showing both 200 + 500
- [x] Prometheus scrape job `mock-services` added with `layer: app`; appeared in `/targets` after `curl -X POST :9090/-/reload`

### Agent app — plumbing (plan §5.3)
- [x] `app/requirements.txt`: pinned streamlit==1.40.1, langchain==0.3.7, langchain-core==0.3.18, langchain-openai==0.2.8, openai==1.54.3, httpx==0.27.2, langfuse==2.60.0. **Deliberate omission: no `traceloop-sdk`** — Langfuse v2 lacks OTLP, so the OpenLLMetry path doesn't work
- [x] `app/tools.py`: five `@tool` functions sharing one `httpx.Client`, docstrings written so the LLM picks the right one
- [x] `app/agent.py`: Langfuse `CallbackHandler` per user, ChatOpenAI with both `default_headers={"X-User-Id": …}` AND `model_kwargs={"user": …}`, `create_tool_calling_agent` + `AgentExecutor(max_iterations=6)`. **Critical: callbacks passed via `invoke(config=…)` not `AgentExecutor(callbacks=…)`** — the latter only fires at the outermost span in LangChain 0.3+
- [x] `app/app.py`: Streamlit chat UI, user-id gate on first load, chat history via session state, `handler.flush()` after every turn so traces appear within a second
- [x] `app/Dockerfile`: python:3.11-slim, build-essential install+purge around pip (some traceloop deps would need C — kept for safety), CMD streamlit with headless + telemetry off
- [x] `app` service in compose: env (OPENAI_API_BASE, LITELLM_MASTER_KEY, LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY, MOCK_SERVICES_URL), `depends_on` litellm/mock-services/langfuse all healthy, python-based healthcheck on `/_stcore/health`
- [x] vLLM command updated: added `--enable-auto-tool-choice --tool-call-parser hermes` (Qwen parser)

### End-to-end trace verification
- [x] Single-tool prompt produces a 17-observation trace: AgentExecutor → RunnableSequence → ChatPromptTemplate → ChatOpenAI [GENERATION] → ToolsAgentOutputParser → tool span → second RunnableSequence → final ChatOpenAI
- [x] Multi-tool prompt ("umbrella + NVDA") produces two tool spans (`get_current_weather`, `get_stock_price`) as siblings under the root, then a second LLM call for synthesis
- [x] `flaky_call(seed='a')` lands an HTTPStatusError 500; AgentExecutor surfaces the exception cleanly
- [x] Per-user attribution: 4 distinct user_ids on 8 traces in Langfuse (robert/maliwan/smoke-test-user/smoke-test-v2)
- [x] `X-User-Id` forwarded to vLLM via LiteLLM's `forward_client_headers_to_llm_api`; visible via the Langfuse SDK's user_id field. **Note:** LiteLLM's per-`end_user` Prometheus label requires virtual API keys; for Phase 1 the per-user view lives in Langfuse

---

## Phase 1.3 — Walkthrough docs

> Exit: a new reader can sit down, follow `docs/01..04` in order, and understand each layer + how to read what it's telling them.
>
> **Status: COMPLETE.** One material deviation: load-tester swapped from vegeta (Go) to **trunks** (Rust port, same author) at the user's request — install path is `cargo install trunks`, no other change to the methodology. The saturation profile became a single 90 s linear ramp (`--pace linear --slope 0.11`) instead of three discrete stages — more elegant and shows the latency knee continuously rather than as a step.

### Load tester (`scripts/load.sh`)
- [x] `scripts/load.sh` — trunks-based runner with 7 profiles (smoke, short, decode-heavy, prefill-heavy, prefix-cache, mixed, saturation), curated prompt sets per profile (~40 distinct prompts across short/long-gen/long-input/prefix-cache), inline-generated JSON payloads + HTTP-format targets, per-attack binary + CSV output, text + histogram reports
- [x] Smoke-tested against the live stack: smoke profile returns 100% 200s, p95 ~195 ms; 30 s saturation ramp climbs from 2/s to ~5.3/s with p95 widening from 80 ms → 808 ms — knee visible exactly as intended
- [x] Prompt set is *intentionally varied* (incident reports, microservices walkthrough, OAuth tutorial, fictional sysadmin story, etc.) so trace samples don't all look the same

### Walkthrough docs (`docs/01..04`)
- [x] `docs/01-getting-started.md`: preflight, per-layer curl smoke tests, single Streamlit chat, multi-tenancy demo, optional saturation glimpse (with the fixed concurrent-curl snippet), URL reference card (migrated from `manual-test-plan.md` via `git mv`)
- [x] `docs/02-anatomy-of-a-request.md`: a multi-tool prompt (umbrella + NVDA) traced through every layer with the corresponding spans / metrics at each hop, plus the resulting 17-observation trace tree visualised in ASCII
- [x] `docs/03-saturation-analysis.md`: trunks install, all 7 profiles explained with "what to expect on which dashboard", how to read a trunks text + histogram report, plot/CSV usage, and a small glossary (rps, tokens/s, TTFT, ITL)
- [x] `docs/04-trace-metric-correlation.md`: the headline lesson — pick one Langfuse trace, zoom Grafana's GPU saturation panel to its wall-clock window, see the prefill vs decode burstiness pattern visually
- [x] `docs/README.md` index updated; root `README.md` has a "Hands-on walkthroughs" section pointing at all four in order

---

## Phase 1.4 — CI + polish (plan §5.9)

> Exit: a fresh clone passes `pre-commit run --all-files`, CI is green on the first push, all image tags are pinned, and a teammate can stand the stack up by following only `README.md`.

### CI workflow
- [ ] Write `.github/workflows/ci.yml`: jobs for yamllint, jq-validate-json, hadolint, `docker compose config -q`, ruff (check + format-check), pytest — all running on push and PR
- [ ] Pin GitHub Actions to commit SHAs (security best practice; mention this choice in CI README)
- [ ] Decide and document Python version (3.11 likely) in CI matrix and Dockerfiles consistently

### Linters and configs
- [ ] `.yamllint.yml` config — relax line-length rule for compose, enable everything else
- [ ] `pyproject.toml` (root or per-service): ruff config with reasonable line length and ignored rules listed with rationale
- [ ] `.hadolint.yaml`: any project-wide ignores (e.g. `DL3008` if we don't pin apt versions in dev Dockerfiles)
- [ ] `.pre-commit-config.yaml` mirroring the CI checks; document `pre-commit install` step in the root README

### Tests (minimal but real)
- [ ] `app/tests/test_tools.py`: each tool, mocking httpx with `respx` or similar — verify it parses the mock-services response shape correctly and surfaces errors
- [ ] `mock-services/tests/test_endpoints.py`: every endpoint returns the documented shape; `/flaky` is deterministic under a fixed seed
- [ ] Wire tests into CI

### Polish
- [ ] Replace every `:latest` / `:main-latest` image tag with a concrete version; document chosen versions in a `VERSIONS.md` (or top of compose)
- [ ] Walk `.env.example` against the actual codebase — every referenced var present, no dead vars
- [ ] On a clean clone, run end-to-end: `cp .env.example .env`, fill HF token + Langfuse keys, `docker compose up`, then the Phase 1.0/1.1/1.2 smoke tests; fix any gap surfaced
- [ ] Final pass on root `README.md`: prereqs, quickstart, "read the docs in order", troubleshooting section linked to per-service READMEs

---

## Phase 2 (out of scope)

Captured here so we don't keep re-evaluating them mid-stream:

- Triton + TensorRT-LLM as a second `model_list` entry
- Compiling a TRT-LLM engine for compute capability 8.9
- Langfuse v3 (ClickHouse + Redis + Minio) - this enables OpenLLMetry
- OpenLLMetry instead of direct callback
- OpenTelemetry Collector as a routing hub
- Logs pillar (Loki + Promtail)
- Per-tenant cost tracking and rate limiting in LiteLLM
- Streaming responses end-to-end (Streamlit token streaming + LiteLLM streaming + vLLM SSE)

## Out of scope of this lab
- Grafana alerts / Alertmanager
- Authenticated Grafana (today: anonymous read)

---

## Cross-cutting reminders

- Every new file in a service folder is accompanied by an update to that service's README — no "I'll write the docs later" tasks.
- After any compose edit, re-run `docker compose config -q` before committing.
- Image tags get pinned the moment we know what version works — don't accumulate `:latest` debt.
- When something doesn't work, the lesson goes into the relevant README's "Where to look when it breaks" section. The repo's failure-mode catalogue *is* part of the deliverable.
