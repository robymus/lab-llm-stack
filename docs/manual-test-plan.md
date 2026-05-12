# Manual test plan — Phases 1.0 → 1.2

> A scripted walk through the running stack. Each section has *what to do*,
> *where to look*, and *what good looks like*. Run them in order on a fresh
> `docker compose up -d`.

## 0. Preflight

| Check | Command | Expected |
| ----- | ------- | -------- |
| 11 services healthy | `docker compose ps` | every row `(healthy)` |
| All Prometheus targets up | <http://localhost:9090/targets> | 7 jobs UP: vllm, litellm, dcgm, node, cadvisor, mock-services, prometheus |
| Dashboards present | <http://localhost:3000/dashboards> | folder "LLM Stack" with 2 dashboards |
| Langfuse logged in | <http://localhost:3001> | UI loads; sign in if needed; project from Phase 1.0 setup is selectable |
| Streamlit reachable | <http://localhost:8501> | Page shows "Pick a user-id" prompt |

If anything is off: `docker compose logs -f <service>` and check the
service's `Where to look when it breaks` section in its README.

---

## 1. Smoke each service in isolation

A 60-second sweep that confirms each layer is talking.

```bash
# --- inference + gateway
curl -s http://localhost:8000/v1/models | jq '.data[].id'                           # → "qwen-chat"
curl -s -H "Authorization: Bearer $(grep ^LITELLM_MASTER_KEY .env | cut -d= -f2)" \
  -d '{"model":"qwen-chat","messages":[{"role":"user","content":"hi"}],"max_tokens":5}' \
  -H 'Content-Type: application/json' \
  http://localhost:4000/v1/chat/completions | jq '.choices[0].message.content'

# --- mock-services (the agent's tool backend)
curl -s http://localhost:9000/weather/london | jq
curl -s http://localhost:9000/stocks/NVDA   | jq
curl -s "http://localhost:9000/flaky?seed=a" -w "\nhttp=%{http_code}\n"             # → 500
curl -s "http://localhost:9000/flaky?seed=b" -w "\nhttp=%{http_code}\n"             # → 200

# --- exporters (Prometheus scrapes these)
curl -s http://localhost:9400/metrics | grep ^DCGM_FI_DEV_POWER_USAGE | head -1
curl -s http://localhost:9100/metrics | grep ^node_load1
curl -s http://localhost:8080/metrics | grep ^container_cpu_usage_seconds_total | head -3
```

All should return non-empty plausible output.

---

## 2. End-to-end via the Streamlit UI

This is the headline test. Run *each prompt in its own session* so trace
trees are clean.

### 2a. Single-tool prompt

1. Open <http://localhost:8501>.
2. Pick user-id **`robert`**, click Start.
3. Type: **`What's the weather in London?`**
4. Wait for the reply (~3-5 s).

**Where to look:**
- **Streamlit** — reply mentions overcast, 15 °C, 80% rain, umbrella.
- **Langfuse** — open <http://localhost:3001>, filter by `userId = robert`.
  Click the trace named `AgentExecutor`. Tree should contain:
  - `AgentExecutor` (root span)
  - `RunnableSequence` → `ChatOpenAI` (`GENERATION`) → `ToolsAgentOutputParser`
  - `get_current_weather` (tool span)
  - Second `RunnableSequence` with the final `ChatOpenAI` synthesis

- **Grafana — LLM Overview** — <http://localhost:3000/d/llm-overview/llm-overview>
  - "Request rate" — single spike at the time you sent the prompt.
  - "p95 latency" — small bump.
  - "Tokens / second" — burst.

### 2b. Multi-tool prompt (the interesting one)

1. In the same session, type: **`Should I bring an umbrella to London, and what's the NVDA stock price?`**

**Expected trace tree (Langfuse):**
- `AgentExecutor`
  - First LLM call → returns *two* tool calls
  - `get_current_weather` ─┐  both as siblings under the root
  - `get_stock_price`     ─┘
  - Second LLM call → synthesises both results into one reply

This is the moment that proves the agent is actually agent-ing — not just
one tool call, but the model planning a multi-step request.

### 2c. Multi-turn (history works)

1. Type: **`What's the weather in Berlin?`** (note the reply).
2. Then: **`And in Tokyo?`**

**Expected:** the model treats "in Tokyo?" as a follow-up — calls
`get_current_weather("Tokyo")` instead of asking "weather where?".

### 2d. Knowledge-base tool

1. Type: **`How does prefix caching work in vLLM?`**

**Expected:** `search_documents` tool span; reply quotes one or two
snippets from the canned doc set.

### 2e. Deliberate error (the trace tree for failures)

1. Type: **`Demonstrate an error by calling flaky_call with seed='a'`**

**Expected:**
- Streamlit shows `⚠️ HTTPStatusError: Server error '500...'`.
- Langfuse trace contains a `flaky_call` span marked as error
  (look for the red badge / "level=ERROR" in the span details).

---

## 3. Multi-tenancy

1. Open a new browser tab/window on <http://localhost:8501>.
2. Pick user-id **`maliwan`**, click Start.
3. Send any two prompts.
4. Back in Langfuse, **Users** menu (left sidebar) → you should see two
   distinct rows: `robert` and `maliwan`, each with their own trace counts.
5. Filtering traces by `userId = maliwan` shows only that user's runs.

Same info via the API (sanity check):

```bash
PK=$(grep ^LANGFUSE_PUBLIC_KEY .env | cut -d= -f2)
SK=$(grep ^LANGFUSE_SECRET_KEY .env | cut -d= -f2)
for u in robert maliwan; do
  count=$(curl -s -u "$PK:$SK" "http://localhost:3001/api/public/traces?limit=50&userId=$u" \
           | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('data',[])))")
  echo "$u: $count traces"
done
```

---

## 4. Grafana — find the GPU correlation

This is the Phase 1.1 learning payoff.

1. Open <http://localhost:3000/d/gpu-saturation/gpu-saturation>.
2. Set time range to **Last 15 minutes** (top-right).
3. Send a fresh prompt from Streamlit (any tool prompt works).
4. Watch the bottom panel: **"GPU power ↔ LLM p95 latency"**.

**Expected:**
- GPU power spikes (often 30–50 W) during the prompt's prefill phase.
- p95 latency on the right axis ticks up.
- Both line up on the same x-coordinate — that's the correlation.

Also worth checking:
- **VRAM panel** — used ≈ 6.8 GB (vLLM's 85% slab) + a bit; free ≈ 1.2 GB.
- **Clocks** — SM clock jumps to its boost frequency during the prompt.

---

## 5. Prometheus — raw PromQL

For when you want to verify recording rules or build a new panel.

Open <http://localhost:9090/graph>, paste each into the query box, run:

```promql
# Requests per second
llm:request_rate

# Tokens per second
llm:tokens_per_second

# p95 latency
llm:request_latency_p95_seconds

# vLLM queue depth (non-zero means saturating)
vllm:num_requests_waiting

# GPU power moving average
gpu:power_watts_avg30s

# Per-handler latency p95 in mock-services
histogram_quantile(0.95,
  sum by (handler, le) (rate(http_request_duration_seconds_bucket{job="mock-services"}[1m])))
```

Each should return at least one series with values that look sane.

---

## 6. Saturation glimpse (optional)

If you want to *see* the dashboards under load (not just idle), fire a
quick burst of concurrent requests:

```bash
MK=$(grep ^LITELLM_MASTER_KEY .env | cut -d= -f2)
for i in $(seq 1 30); do
  curl -s -o /dev/null --max-time 60 \
    -H "Authorization: Bearer $MK" -H 'Content-Type: application/json' \
    -d '{"model":"qwen-chat","messages":[{"role":"user","content":"count to 20"}],"max_tokens":100}' \
    http://localhost:4000/v1/chat/completions &
done
wait
```

While it runs:
- **LLM Overview** — `Queue depth / active batch` panel: `running` climbs
  into the 5–15 range, `waiting` shows transient spikes.
- **KV cache usage** gauge — goes amber/red while the batch holds.
- **GPU Saturation** — power panel pegs near its peak for tens of seconds.

This is the metric that tells you the gateway is fine but the engine is
the bottleneck — exactly the "saturation analysis" lesson the plan calls
out (and that Phase 1.3 will formalise with `vegeta`).

---

## 7. URL reference card

Keep this open in a tab while testing.

| URL | Purpose |
| --- | ------- |
| <http://localhost:8501> | Streamlit chat UI |
| <http://localhost:3001> | Langfuse — traces, users, sessions |
| <http://localhost:3000/d/llm-overview/llm-overview> | Grafana — gateway/engine view |
| <http://localhost:3000/d/gpu-saturation/gpu-saturation> | Grafana — GPU + correlation |
| <http://localhost:9090/targets> | Prometheus — scrape target health |
| <http://localhost:9090/graph> | Prometheus — PromQL playground |
| <http://localhost:8000/v1/models> | vLLM — what models are served |
| <http://localhost:4000/metrics/> | LiteLLM /metrics (trailing slash matters!) |
| <http://localhost:9000/health> | mock-services liveness |
| <http://localhost:9000/metrics> | mock-services Prometheus metrics |
| <http://localhost:9400/metrics> | DCGM exporter metrics |

---

## 8. What "pass" means for Phase 1.0–1.2

You should be able to point to:

1. A live Streamlit chat with a multi-tool prompt and a sensible answer. ✓
2. The exact trace for that chat in Langfuse, with tool spans visible. ✓
3. The GPU-power spike for that chat on the saturation dashboard, at the
   same wall-clock time as the trace timestamps. ✓
4. The request appearing in Prometheus's `llm:request_rate` and contributing
   to the `tokens_per_second` curve. ✓
5. A second user-id producing a distinct, filterable trace in Langfuse. ✓
6. A failed `flaky_call` producing an error span. ✓

If all six work end-to-end on one fresh `docker compose up`, Phases 1.0
through 1.2 are functionally complete and you can move on to Phase 1.3
(walkthrough docs) or Phase 1.4 (CI + polish).
