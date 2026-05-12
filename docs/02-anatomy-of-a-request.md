# 02 · Anatomy of a request

> Follow one prompt — *"Should I bring an umbrella to London, and what's
> the NVDA stock price?"* — all the way through the stack. Every layer
> gets a paragraph and a pointer at where to verify the hop yourself.
>
> Read after [01 Getting started](01-getting-started.md).

---

## The single prompt we'll trace

In Streamlit, with `user_id = robert` set:

```
Should I bring an umbrella to London, and what's the NVDA stock price?
```

What you'll see: Qwen2.5-3B picks *both* `get_current_weather` and
`get_stock_price` in its first turn, calls them, and synthesises one
combined reply in a second LLM turn. That makes it the simplest prompt
that produces a meaningfully *branchy* trace — multiple tool spans, two
generations, sequenced correctly.

---

## The hops, in order

### 0. Streamlit UI (in your browser)

When you submit, Streamlit's WebSocket-driven runtime fires a script
rerun. Inside that rerun, [app/app.py](../app/app.py) appends the new
message to `st.session_state.messages`, then calls `executor.chat(...)`.

**Verify:** `docker compose logs --tail 20 app` shows Streamlit's access
log entries for the WebSocket message.

### 1. LangChain agent (inside the app container)

`executor.chat(prompt, history)` lives on the `Agent` class in
[app/agent.py](../app/agent.py). It:

1. Converts the message history to LangChain `HumanMessage` / `AIMessage` objects.
2. Calls `AgentExecutor.invoke(...)` with the Langfuse callback attached
   via `config={"callbacks": [...]}` — this is what gets the full chain →
   llm → tool tree into Langfuse.
3. Forces a `handler.flush()` in `finally` so the trace appears in the
   UI before this function returns.

**Verify:** the trace is visible in Langfuse with name `AgentExecutor`
and `userId=robert` — see step 7 below.

### 2. First LLM call — system + user prompt → tool selection

`AgentExecutor` runs its first `RunnableSequence`:

1. `ChatPromptTemplate` renders the messages, prepending the system prompt
   that enumerates the tools (see `SYSTEM_PROMPT` in `agent.py`).
2. `ChatOpenAI` (with `model="qwen-chat"`) POSTs to the gateway.
3. The response comes back containing `tool_calls` for both
   `get_current_weather(city="London")` and `get_stock_price(ticker="NVDA")`.
4. `ToolsAgentOutputParser` extracts those into structured tool-call objects.

This whole hop runs the openai-python client under the hood. The HTTP
request leaves the app container with:

```
POST http://litellm:4000/v1/chat/completions
Authorization: Bearer sk-llm-stack-dev
X-User-Id: robert
Content-Type: application/json

{ "model": "qwen-chat",
  "messages": [...],
  "tools": [
    {"type":"function","function":{"name":"get_current_weather", ...}},
    {"type":"function","function":{"name":"get_news",            ...}},
    {"type":"function","function":{"name":"get_stock_price",     ...}},
    {"type":"function","function":{"name":"search_documents",    ...}},
    {"type":"function","function":{"name":"flaky_call",          ...}}
  ],
  "tool_choice": "auto",
  "user": "robert"
}
```

**Verify:** in Langfuse, the trace's first `GENERATION` span has both the
input messages and the output `tool_calls` array in its payload.

### 3. LiteLLM gateway

[litellm/config.yaml](../litellm/config.yaml) routes `model: qwen-chat`
through the OpenAI-compatible adapter to `api_base: http://vllm-engine:8000/v1`.
On the way:

- `forward_client_headers_to_llm_api: true` carries `X-User-Id` forward.
- `callbacks: ["prometheus"]` increments `litellm_proxy_total_requests_metric_total{requested_model="qwen-chat", status_code="200", ...}`.
- The OpenAI `user` field bound to `model_kwargs` lives in the body for
  any future virtual-key-aware label.

**Verify:** `docker compose logs --tail 30 litellm` shows the POST landing
with HTTP 200. `curl -s http://localhost:4000/metrics/ | grep '_total{.*qwen-chat'`
shows the counter incremented.

### 4. vLLM engine (the GPU work)

LiteLLM forwards to `http://vllm-engine:8000/v1/chat/completions`. vLLM:

1. **Tokenises** the messages using Qwen's chat template (which translates
   the OpenAI `tools` array into `<|tool_call|>` markers, courtesy of
   `--tool-call-parser hermes`).
2. **Prefills** — runs the prompt through the model in one (or a few)
   GPU batches, building the KV cache. This is where you'd see GPU power
   spike; for a short combined-tools prompt it's a 100-200 ms hump.
3. **Decodes** — generates output tokens one at a time, attending over
   the KV cache. For a tool-call response (a few dozen tokens) this is
   <1 s.
4. **Detokenises** and returns. Because tool-calling is on, the parser
   formats the output as a proper OpenAI `tool_calls` array.

Metrics emitted during this hop:
- `vllm:num_requests_running` → 1 for the duration.
- `vllm:prompt_tokens_total` → += prompt token count.
- `vllm:generation_tokens_total` → += output token count.
- `vllm:iteration_tokens_total_bucket` → updated.
- `vllm:gpu_cache_usage_perc` → briefly non-zero.
- DCGM's `DCGM_FI_DEV_POWER_USAGE` → spike captured by the next 5 s scrape.

**Verify:** in Grafana → LLM Overview → *Tokens / second*, you should see
a bump for "generation (out)" right at this time. → GPU Saturation →
*Power* line shows a corresponding pulse.

### 5. Tool calls land back at LangChain

LangChain's `AgentExecutor` sees the `tool_calls` from step 4 and dispatches
to the corresponding `@tool` functions in [app/tools.py](../app/tools.py).

Both run in parallel as separate Langfuse spans:

- `get_current_weather("London")` → `_client.get("/weather/London")`
- `get_stock_price("NVDA")` → `_client.get("/stocks/NVDA")`

httpx (auto-pooled by the shared `_client`) makes those calls into the
mock-services container.

### 6. mock-services replies

[mock-services/main.py](../mock-services/main.py) handles both:

- `GET /weather/London` → 200, `{"city":"London","summary":"Overcast..."}`
- `GET /stocks/NVDA` → 200, `{"ticker":"NVDA","price":1023.45,"change_pct":-2.34}`

Each handler is also wrapped by `prometheus-fastapi-instrumentator`, so:

- `http_requests_total{handler="/weather/{city}", method="GET", status="2xx"}` += 1
- `http_request_duration_seconds_bucket{handler="/weather/{city}", ...}` updated

**Verify:** `curl -s http://localhost:9000/metrics | grep weather`
shows the counter incrementing.

### 7. Second LLM call — synthesis

LangChain feeds the two tool results back into a fresh `RunnableSequence`,
which sends another `POST /v1/chat/completions` through the gateway with
the conversation now containing:

- system prompt
- user prompt
- assistant prompt with the previous tool calls
- tool result message for `get_current_weather`
- tool result message for `get_stock_price`

vLLM does another prefill (longer this time — the conversation has more
tokens), decodes the final answer (~50 tokens), and the response flows
back up the stack.

LangChain's `AgentExecutor` checks: no further tool calls → done →
returns `result["output"]` to `Agent.chat()`, which returns to Streamlit.

### 8. Streamlit renders

`st.session_state.messages` gets the assistant reply appended. The
chat history re-renders, the spinner disappears, the user sees:

> *"Overcast with 80% chance of rain in London — bring an umbrella. NVDA
> is at $1023.45, down 2.34%."*

---

## The trace tree (what Langfuse shows)

Open <http://localhost:3001> → filter by `userId = robert` → click the
most recent `AgentExecutor` trace:

```
AgentExecutor                              SPAN     ─── trace root
├── RunnableSequence                       SPAN     ─── first LLM call setup
│   ├── RunnableAssign<agent_scratchpad>   SPAN
│   │   └── RunnableParallel<...>          SPAN
│   │       └── RunnableLambda             SPAN
│   ├── ChatPromptTemplate                 SPAN
│   ├── ChatOpenAI                         GEN  ⬅── step 2: tool selection
│   └── ToolsAgentOutputParser             SPAN
├── get_current_weather                    SPAN ⬅── step 5: tool 1
├── get_stock_price                        SPAN ⬅── step 5: tool 2
└── RunnableSequence                       SPAN ─── second LLM call
    ├── ... (same shape)
    └── ChatOpenAI                         GEN  ⬅── step 7: synthesis
```

`GEN` (Generation) is Langfuse's specialised type for LLM calls — it
carries token counts and the chat messages as structured fields.

---

## The metric trace (what Prometheus + Grafana see)

For the same wall-clock window, you should see:

| Series | What happens |
| ------ | ------------ |
| `litellm_proxy_total_requests_metric_total{requested_model="qwen-chat"}` | +2 (two gateway calls — steps 2 and 7) |
| `vllm:generation_tokens_total` | +N where N is the combined output tokens |
| `vllm:gpu_cache_usage_perc` | briefly non-zero during each LLM call |
| `vllm:gpu_prefix_cache_hit_rate` | tickled if the system prompt has been seen before |
| `DCGM_FI_DEV_POWER_USAGE` | two small humps |
| `http_requests_total{handler="/weather/{city}",status="2xx"}` (mock-services) | +1 |
| `http_requests_total{handler="/stocks/{ticker}",status="2xx"}` | +1 |

Open <http://localhost:3000/d/llm-overview/llm-overview> with the time
range set to "Last 5 minutes" while running the prompt — *Request rate*
and *Tokens / second* will both bump.

---

## A single prompt → two LLM calls + two tool calls + lots of metrics

That's the take-away. A user types one sentence; the system makes
**5 HTTP requests internally** (2 × gateway, 2 × mock-services, 1 ×
trace export to Langfuse), generates spans across 17 observations, and
emits scrape-time-resolved updates across half a dozen Prometheus series.

Next:
- [03 saturation analysis](03-saturation-analysis.md) — what changes when
  the rate is *not* one prompt every 30 seconds.
- [04 trace ↔ metric correlation](04-trace-metric-correlation.md) — line up
  a specific trace's wall-clock with the GPU power panel.
