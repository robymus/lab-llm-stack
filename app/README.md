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
| [agent.py](agent.py) | LangChain agent + Langfuse `CallbackHandler` wiring |
| [tools.py](tools.py) | The five `@tool`-decorated functions hitting mock-services |
| [Dockerfile](Dockerfile) | python:3.11-slim + the dep stack |
| [requirements.txt](requirements.txt) | Pinned dependency set |

## The tracing path — and why it's not OTLP

The plan originally specified OpenTelemetry/OTLP via `traceloop-sdk` →
Langfuse. **It turned out Langfuse v2 doesn't accept OTLP/HTTP** — that's
a v3-only feature. So instead we use Langfuse's native LangChain
`CallbackHandler`, which:

- Hooks into LangChain's `on_*_start`/`on_*_end` events.
- Batches and ships them to Langfuse's standard ingestion API.
- Captures the same chain/llm/tool tree visible in the UI.

What we lose: the httpx sub-spans that OpenLLMetry would have produced
under each tool span (one extra layer of detail). Workaround:
[mock-services](../mock-services/) exposes its own Prometheus `/metrics`
with per-handler latency histograms, so the network round-trip is
observable, just through a different surface.

What would unlock the original plan: upgrading to Langfuse v3 (deferred
— see [PLAN §5.7](../.plans/llm-sandbox-PLAN.md)).

## Configuration walkthrough

### [agent.py](agent.py)

The whole agent + Langfuse machinery is encapsulated as an `Agent` class
bound to one `user_id`. App code only sees `executor.chat(input, history)` —
the Langfuse `CallbackHandler` is private to `Agent` and never crosses the
module boundary.

Three rules that *are* worth understanding (all inside `Agent.__init__` /
`Agent.chat`):

1. **One handler per user, with `user_id == session_id`.** Both fields
   appear as first-class filters in the Langfuse UI; using the same value
   for both makes "everything Robert did" one filter, not two.
2. **`ChatOpenAI` gets both** `default_headers={"X-User-Id": user_id}` (HTTP
   header, forwarded by LiteLLM to vLLM) and `model_kwargs={"user": user_id}`
   (OpenAI's standard `user` body field). Different downstream tools
   surface different ones; the body field is what LiteLLM's per-`end_user`
   Prometheus label will use once virtual API keys are wired up.
3. **Callbacks are passed via `invoke(config={"callbacks": [...]})`**, not
   via `AgentExecutor(callbacks=[...])`. In LangChain 0.3+ the former
   propagates through every child runnable; the latter only fires at the
   outermost span (so you'd see *only* the `AgentExecutor` span in
   Langfuse and miss the chain → llm → tool tree underneath).

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
  rebuilding the chain on every input.
- **Flushing** — `handler.flush()` after each invoke. Langfuse batches
  spans by default; flushing immediately gets the trace into the UI
  within ~1 s, which makes iterating worthwhile.

## Trace tree (what to expect in Langfuse)

A multi-tool prompt like *"umbrella in London and NVDA price?"* produces
this structure:

```
AgentExecutor                      [span]   trace root
├── RunnableSequence               [span]   first LLM call setup
│   ├── RunnableAssign<...>        [span]   variable assignment
│   │   └── RunnableParallel<...>  [span]   parallel runnables
│   │       └── RunnableLambda     [span]   user-supplied function
│   ├── ChatPromptTemplate         [span]   prompt rendering
│   ├── ChatOpenAI                 [GEN]    LLM call → returns tool calls
│   └── ToolsAgentOutputParser     [span]   parses tool calls from response
├── get_current_weather            [span]   tool 1
├── get_stock_price                [span]   tool 2
└── RunnableSequence               [span]   second LLM call (with tool results)
    ├── ...                                  same shape as above
    └── ChatOpenAI                 [GEN]    final synthesis
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

# Verify the trace landed
LF_PK=$(grep ^LANGFUSE_PUBLIC_KEY .env | cut -d= -f2)
LF_SK=$(grep ^LANGFUSE_SECRET_KEY .env | cut -d= -f2)
curl -s -u "$LF_PK:$LF_SK" "http://localhost:3001/api/public/traces?limit=3&userId=script-user" | jq '.data[].name'
```

## Where to look when it breaks

| Symptom | Likely cause | Fix |
| ------- | ------------ | --- |
| Streamlit shows error: "auto tool choice requires --enable-auto-tool-choice" | vLLM is missing the tool-calling flags | Confirm `vllm-engine.command` has `--enable-auto-tool-choice` + `--tool-call-parser hermes` |
| Trace contains only the AgentExecutor span | Callback passed via constructor, not invoke config | Move to `invoke(config={"callbacks": [handler]})` |
| "Connection refused" to litellm:4000 | App started before gateway healthy | `depends_on: litellm: service_healthy` handles this; if you bypassed compose, wait for healthcheck |
| Per-user filter in Langfuse shows nothing | `user_id` not set on CallbackHandler | Check `_build_handler()` — both `user_id` and `session_id` are set |
| Tokeniser warning about `qwen-chat` in logs | OpenLLMetry tries to count tokens with tiktoken | Harmless — we don't use OpenLLMetry anymore; if you see this, agent.py was somehow loaded with old code |
| `flaky_call` always succeeds | Wrong seed | seed `a`/`c`/`f` fail; `b`/`d`/`e` succeed (md5 first-byte < 76 fails) |

## Direct links

- Streamlit UI — <http://localhost:8501>
- Langfuse traces — <http://localhost:3001> (filter by user-id in the left sidebar)
- LLM Overview dashboard — <http://localhost:3000/d/llm-overview/llm-overview>
- GPU Saturation dashboard — <http://localhost:3000/d/gpu-saturation/gpu-saturation>

## What's next

- Phase 1.3 walkthrough docs cite specific traces produced here.
- Phase 1.4 adds `tests/test_tools.py` mocking `httpx` (via `respx`) so
  changes to the tools don't silently break the agent.
- If we ever upgrade to Langfuse v3, swap `langfuse.callback.CallbackHandler`
  back to `traceloop-sdk` and post traces via OTLP/HTTP for vendor-neutrality.
