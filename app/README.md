# Agent app

> Streamlit chat UI + LangChain `create_tool_calling_agent` + five tools +
> Langfuse trace export. The reason all the rest of the stack exists.

## What this is

A small chat application that demonstrates a real agentic flow:

1. User asks a question in the Streamlit UI.
2. Qwen2.5-3B (via the LiteLLM gateway → vLLM) decides whether to call a tool.
3. If yes, the tool hits `mock-services` over HTTP.
4. Result feeds back to the LLM for a final answer.
5. The whole tree — chain, LLM call, tool, second LLM call — lands in
   Langfuse as a single trace, tagged with the user-id.

## Why it's here

The plan calls this out as the second pillar (traces). Everything before
Phase 1.2 was metrics. This is where the user picks `user-id = robert`,
asks "umbrella in London?", and sees:

- A Streamlit chat reply in seconds.
- A trace in Langfuse with `chain → llm → tool → llm → final` structure.
- A spike on Grafana's `02-gpu-saturation` dashboard at the same wall-clock time.

All three at once — that's the correlation lesson.

## Files

| File | Purpose |
| ---- | ------- |
| [app.py](app.py) | Streamlit UI: user-id capture, chat history, agent invocation |
| [agent.py](agent.py) | LangChain agent + OpenLLMetry/OTLP tracing init |
| [tools.py](tools.py) | The five `@tool`-decorated functions hitting mock-services |
| [Dockerfile](Dockerfile) | python:3.11-slim + the dep stack |
| [requirements.txt](requirements.txt) | Pinned dependency set |

## The tracing path (Phase 2.2 — OTLP restored)

```
   app                              otel-collector                 langfuse v3
   ─────                            ─────────────                  ───────────
   traceloop-sdk                       :4318  ──HTTP──▶              :3000
   auto-instruments                  (batch +                     (OTLP receiver
   langchain +                        attribute                    on /api/public/
   openai +                           processors)                   otel/v1/traces)
   httpx
            ──OTLP/HTTP──▶                       ──OTLP/HTTP──▶
            (no Langfuse                         (Basic auth via
             knowledge here)                      basicauth/langfuse
                                                  extension)
```

The agent app emits plain OTLP/HTTP. The
[`otel-collector`](../otel/) container holds the Langfuse credentials and
forwards. Three things this buys us:

- **httpx sub-spans are back.** Each tool span has its `httpx.GET` child
  underneath. Phase 1.2's Langfuse v2 callback path collapsed those.
- **No Langfuse knowledge in the app.** Swap the trace backend (Tempo,
  Jaeger, Honeycomb…) by editing only `otel/config.yaml` — `app/agent.py`
  doesn't change.
- **Batching out of the app's hot path.** The collector coalesces sub-200 ms
  bursts of single-span POSTs into one network call.

Phase 1.2 used Langfuse's native LangChain `CallbackHandler` (v2 didn't
speak OTLP/HTTP). Phase 2.1 brought v3 online; 2.2 flipped the wire
protocol. The trace tree in the UI is the same shape, plus one extra
layer of `httpx.*` spans.

## Configuration walkthrough

### [agent.py](agent.py)

The agent + tracing machinery is encapsulated as an `Agent` class bound
to one `user_id`. App code only sees `executor.chat(input, history)`.

Three rules that *are* worth understanding:

1. **`Traceloop.init(...)` runs at module-import time, BEFORE any
   `from langchain... import ...` lines.** OpenLLMetry's
   auto-instrumentors wrap classes as they're imported; flipping that
   order silently disables them. The `# noqa: E402` comments on the
   framework imports document the deliberate ordering.
2. **Per-turn identity via `Traceloop.set_association_properties`.**
   Stamping `user_id` and `session_id` at the top of each `chat()` call
   propagates them onto every span emitted within that thread's context.
   Surfaces in Langfuse v3 as
   `metadata.traceloop.association.properties.user_id` and is filterable
   from the UI sidebar.
3. **`ChatOpenAI` gets both** `default_headers={"X-User-Id": user_id}` (HTTP
   header, forwarded by LiteLLM to vLLM) and `model_kwargs={"user": user_id}`
   (OpenAI's standard `user` body field). Different downstream tools
   surface different ones; the body field is what LiteLLM's per-`end_user`
   Prometheus label will use once virtual API keys are wired up (Phase 2.4).

No callbacks pass through `invoke()` anymore — traceloop's
auto-instrumentation hooks `Chain.invoke` / `BaseChatModel.invoke`
directly, so the chain → llm → tool tree appears in the UI without any
LangChain-callback plumbing on our side.

### [tools.py](tools.py)

Five `@tool`-decorated functions:

| Tool | Calls | When the LLM picks it |
| ---- | ----- | --------------------- |
| `get_current_weather(city)` | `GET /weather/{city}` | weather questions |
| `get_news(topic, limit)` | `GET /news` | headlines / news questions |
| `get_stock_price(ticker)` | `GET /stocks/{ticker}` | stock-price questions |
| `search_documents(query)` | `GET /docs/search` | questions about this stack itself |
| `flaky_call(seed)` | `GET /flaky` | only when user explicitly asks |

Docstrings matter: LangChain feeds them to the LLM as the tool's
description, which drives selection. Keep them tight.

### [app.py](app.py)

- **First load** — gate the chat behind a user-id input. Default is
  `user-<6 hex chars>`; user can override. Once set, kept in
  `st.session_state.user_id` for the session.
- **Chat history** — list of `{role, content}` in `st.session_state.messages`.
  Converted to LangChain `HumanMessage`/`AIMessage` objects per turn via
  `agent.to_lc_history`.
- **Caching** — `@st.cache_resource` on the executor builder. Streamlit
  reruns the entire script on each keystroke; the cache avoids
  rebuilding the chain on every input. The tracing pipeline is
  initialised once at module import and reused.
- **No explicit flushing** — the OTel SDK's BatchSpanProcessor exports on
  its own (200 ms in the collector + ~5 s SDK-side max). For local
  debugging where you want the trace visible *immediately*, set
  `OTEL_BSP_SCHEDULE_DELAY=100` (ms) on the `app` service or pass
  `disable_batch=True` to `Traceloop.init` (we already do — the
  collector's `batch` processor handles the coalescing instead).

## Trace tree (what to expect in Langfuse v3)

A multi-tool prompt like *"umbrella in London and NVDA price?"* produces
this structure (the `httpx.GET` rows are new in Phase 2.2 — they were
missing in the Phase 1.2 v2-callback tree):

```
AgentExecutor                      [span]   trace root
├── RunnableSequence               [span]   first LLM call setup
│   ├── ChatPromptTemplate         [span]   prompt rendering
│   ├── ChatOpenAI                 [GEN]    LLM call → returns tool calls
│   │   └── HTTP POST              [span]   httpx hits litellm:4000
│   └── ToolsAgentOutputParser     [span]   parses tool calls from response
├── get_current_weather            [span]   tool 1
│   └── HTTP GET                   [span]   httpx hits mock-services:9000  ◀── NEW
├── get_stock_price                [span]   tool 2
│   └── HTTP GET                   [span]   httpx hits mock-services:9000  ◀── NEW
└── RunnableSequence               [span]   second LLM call (with tool results)
    ├── ...                                  same shape as above
    └── ChatOpenAI                 [GEN]    final synthesis
        └── HTTP POST              [span]   httpx hits litellm:4000        ◀── NEW
```

`GEN` (Generation) is Langfuse's first-class type for LLM calls — it
carries token counts, model name, and the chat messages.

## Smoke tests

```bash
# Service up
curl -s http://localhost:8501/_stcore/health

# Open the UI
echo "Open http://localhost:8501 — pick a user-id, then type a question."

# Drive the agent from outside the UI (useful for scripting load tests)
docker compose exec -T app python - <<'PY'
import agent
ex = agent.build_executor("script-user")
print(ex.chat("What is the weather in Tokyo?", []))
PY

# Watch traces flow through the collector while you drive load
docker compose logs --tail=20 -f otel-collector | grep -E 'TracesExporter|spans'

# Verify the trace landed in Langfuse
LF_PK=$(grep ^LANGFUSE_PUBLIC_KEY .env | cut -d= -f2)
LF_SK=$(grep ^LANGFUSE_SECRET_KEY .env | cut -d= -f2)
curl -s -u "$LF_PK:$LF_SK" "http://localhost:3001/api/public/traces?limit=3&userId=script-user" | jq '.data[].name'
```

## Known limitation: Tokens field on Generations reads 0/0/0

vLLM returns `usage.prompt_tokens` / `completion_tokens` on every
chat-completion; LiteLLM passes them through unchanged. But OpenLLMetry's
instrumentors (0.60.x) don't translate them into the
`gen_ai.usage.input_tokens` / `output_tokens` OTel attributes that
Langfuse v3 reads to populate its native `usage` field. Result: the
Tokens column on every Generation span in the Langfuse UI shows 0/0/0.

We tried a LangChain-callback bridge that reads `llm_output.token_usage`
and re-stamps it via the OTel API. It doesn't work — by the time
LangChain's `on_llm_end` fires, OpenLLMetry has already ended the
Generation span, and `set_attribute` no-ops on a finished span.

Token counts ARE observable through other surfaces today:

| Surface | Series / panel |
| ------- | -------------- |
| LiteLLM `/metrics/` | `litellm_total_tokens`, `litellm_input_tokens_metric`, `litellm_output_tokens_metric` |
| vLLM `/metrics` | `vllm:prompt_tokens_total`, `vllm:generation_tokens_total` |
| Grafana | "Tokens / second" panel on the LLM Overview dashboard |

Revisit this when OpenLLMetry's openai instrumentor ships proper usage
extraction for chat-completions-via-langchain-openai (tracking upstream).

## Where to look when it breaks

| Symptom | Likely cause | Fix |
| ------- | ------------ | --- |
| Streamlit shows error: "auto tool choice requires --enable-auto-tool-choice" | vLLM is missing the tool-calling flags | Confirm `vllm-engine.command` has `--enable-auto-tool-choice` + `--tool-call-parser hermes` |
| Trace contains only the agent root span, no children | `Traceloop.init` ran AFTER the langchain import (auto-instrumentor missed it) | Confirm `Traceloop.init(...)` is the very first runtime statement in agent.py, before any framework imports |
| No `httpx.*` spans under tool spans | Either traceloop-sdk not installed, or httpx import beat the init | Same fix as above — agent.py's import ordering is load-bearing |
| "Connection refused" to litellm:4000 | App started before gateway healthy | `depends_on: litellm: service_healthy` handles this; if you bypassed compose, wait for healthcheck |
| Per-user filter in Langfuse shows nothing | `user_id` association property not stamped | Check `Agent.chat` calls `Traceloop.set_association_properties({"user_id": ...})` before invoking |
| `otel-collector` logs `401 Unauthorized` on every batch | `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` in `.env` don't match Langfuse's UI | Re-copy from Project Settings → API Keys, `docker compose restart otel-collector` |
| `flaky_call` always succeeds | Wrong seed | seed `a`/`c`/`f` fail; `b`/`d`/`e` succeed (md5 first-byte < 76 fails) |

## Direct links

- Streamlit UI — <http://localhost:8501>
- Langfuse traces — <http://localhost:3001> (filter by user-id in the left sidebar)
- LLM Overview dashboard — <http://localhost:3000/d/llm-overview/llm-overview>
- GPU Saturation dashboard — <http://localhost:3000/d/gpu-saturation/gpu-saturation>

## What's next

- Phase 1.3 walkthrough docs cite specific traces produced here.
- Phase 1.4 added `tests/test_tools.py` mocking `httpx` (via `respx`) so
  changes to the tools don't silently break the agent.
- Phase 2.2 (this phase) restored OTLP, completing the vendor-neutral
  tracing path the original PLAN called for. Next on the path: Phase 2.4
  adds per-tenant virtual API keys so the `end_user` Prometheus label
  populates alongside the trace's `user_id` association property.
