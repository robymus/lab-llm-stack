"""LangChain agent + OpenLLMetry/OTLP tracing, encapsulated as `Agent`.

Tracing path (Phase 2.2): traceloop-sdk auto-instruments LangChain, the
OpenAI client, and httpx. Spans are pushed via OTLP/HTTP to the
otel-collector container, which batches and forwards them to Langfuse v3
with HTTP Basic auth. The app no longer knows anything about Langfuse —
the collector is the only thing in this codebase that does.

Compared to Phase 1.2's `langfuse.callback.CallbackHandler` path, this
restores the httpx sub-spans under each tool span (one extra level of
detail visible in the Langfuse UI) and decouples the app from the trace
backend's wire protocol.

Per-user identity propagates via `Traceloop.set_association_properties`,
which attaches `user_id` (and any other key/value pairs) to every span
emitted within that thread's context. The Langfuse UI surfaces those
properties under `metadata.traceloop.association.properties.user_id`.

NB: `Traceloop.init(...)` is called at *module import time*, before any
`from langchain...` / `from openai...` imports — that ordering matters
because the auto-instrumentors wrap classes when they're imported.
"""

# ---------------------------------------------------------------------------
#  Traceloop init MUST come before the framework imports below.
# ---------------------------------------------------------------------------
import os

from traceloop.sdk import Traceloop

Traceloop.init(
    app_name=os.environ.get("OTEL_SERVICE_NAME", "llm-sandbox-app"),
    # api_endpoint is read directly from OTEL_EXPORTER_OTLP_ENDPOINT if
    # not passed. We pass it explicitly so the failure mode is "missing
    # env var → KeyError at startup" instead of "silently exports to the
    # Traceloop SaaS default endpoint".
    api_endpoint=os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"],
    # The otel-collector's `batch` processor already batches; doing it
    # twice would just add latency without further coalescing.
    disable_batch=True,
)

# traceloop-sdk doesn't auto-instrument generic HTTP clients. Add httpx
# explicitly so the GET-to-mock-services sub-span appears under each tool
# span — that's the Phase 2.2 exit criterion ("httpx sub-spans restored").
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor  # noqa: E402

HTTPXClientInstrumentor().instrument()

# ---------------------------------------------------------------------------
#  Framework imports (auto-instrumented by traceloop above).
# ---------------------------------------------------------------------------
from langchain.agents import AgentExecutor, create_tool_calling_agent  # noqa: E402
from langchain_core.messages import AIMessage, HumanMessage  # noqa: E402
from langchain_core.prompts import ChatPromptTemplate  # noqa: E402
from langchain_openai import ChatOpenAI  # noqa: E402

from tools import ALL_TOOLS  # noqa: E402

# Known limitation (Phase 2.2):
#   The `Tokens` field on `ChatOpenAI.chat` Generations in the Langfuse v3 UI
#   reads 0/0/0. vLLM and LiteLLM both return `usage.prompt_tokens` /
#   `completion_tokens` on the chat-completions response, but OpenLLMetry's
#   instrumentors (0.60.x) don't propagate them into the
#   `gen_ai.usage.input_tokens` / `output_tokens` OTel attributes Langfuse v3
#   reads. We tried bridging via a LangChain callback (`on_llm_end` reading
#   `llm_output.token_usage`); it fires AFTER the OpenLLMetry-managed
#   Generation span has been ended, so `span.set_attribute` no-ops.
#   Token counts ARE still observable through:
#     - LiteLLM's /metrics — series `litellm_total_tokens`, `litellm_*_tokens_metric`
#     - vLLM's /metrics — `vllm:prompt_tokens_total`, `vllm:generation_tokens_total`
#     - The "Tokens / second" panel on the LLM Overview Grafana dashboard
#   Revisit when OpenLLMetry's openai instrumentor ships proper usage extraction
#   for chat-completions-via-langchain-openai, or when Langfuse publishes an
#   alternative OTel attribute Langfuse v3 already reads.


# System prompt enumerates tools by name and gives selection hints.
# Small models (Qwen-3B) need the explicit list to pick tools well.
SYSTEM_PROMPT = """You are a helpful assistant in an LLM observability sandbox.

You have these tools available:
- get_current_weather(city) — for weather questions
- get_news(topic, limit) — for headlines; good topics: ai, tech, stocks, weather
- get_stock_price(ticker) — for stock prices (AAPL, NVDA, TSLA, MSFT, GOOGL)
- search_documents(query) — for questions about THIS stack (vLLM, DCGM, Langfuse, etc.)
- flaky_call(seed) — ONLY call this if the user explicitly asks for an error demo

If a question mentions multiple distinct facts, call the relevant tools in sequence,
then combine the results into a brief answer. Keep replies short — the user values
brevity and is looking at the trace tree, not the prose.
"""

_PROMPT = ChatPromptTemplate.from_messages(
    [
        ("system", SYSTEM_PROMPT),
        ("placeholder", "{chat_history}"),
        ("user", "{input}"),
        ("placeholder", "{agent_scratchpad}"),
    ]
)


def _to_lc_history(messages: list[dict]) -> list:
    """Convert app-side {role, content} dicts to LangChain message objects."""
    out = []
    for m in messages:
        if m["role"] == "user":
            out.append(HumanMessage(content=m["content"]))
        elif m["role"] == "assistant":
            out.append(AIMessage(content=m["content"]))
    return out


class Agent:
    """An LLM agent bound to one user_id, with OTLP tracing built in.

    Auto-instrumentation runs at module import; this class just builds the
    LangChain executor and stamps `user_id` onto each chat call's spans.
    """

    def __init__(self, user_id: str):
        self._user_id = user_id

        # ---- LLM --------------------------------------------------------
        llm = ChatOpenAI(
            # Logical model name — LiteLLM routes "qwen-chat" to vllm-engine.
            # This is the Phase-2 swap point in action: swap to Triton later
            # and the only change here is the string.
            model="qwen-chat",
            base_url=os.environ["OPENAI_API_BASE"],
            api_key=os.environ["LITELLM_MASTER_KEY"],
            # X-User-Id header: forwarded by LiteLLM (forward_client_headers_to_llm_api)
            # all the way to vLLM. Visible in LiteLLM access logs.
            default_headers={"X-User-Id": user_id},
            # OpenAI's standard `user` body field. LiteLLM will surface this
            # on its per-`end_user` Prometheus label once virtual API keys
            # are configured (Phase 2.4 exercise); harmless until then.
            model_kwargs={"user": user_id},
            temperature=0.3,
            max_tokens=512,
        )

        # ---- Agent + executor ------------------------------------------
        # No callbacks here — traceloop's auto-instrumentation wraps
        # LangChain's `Chain.invoke` / `BaseChatModel.invoke` directly and
        # produces the trace tree without us hooking anything up.
        agent_runnable = create_tool_calling_agent(llm, ALL_TOOLS, _PROMPT)
        self._executor = AgentExecutor(
            agent=agent_runnable,
            tools=ALL_TOOLS,
            max_iterations=6,
            verbose=False,
        )

    def chat(self, user_input: str, history: list[dict]) -> str:
        """Run one conversation turn.

        `history` is the chat history *before* this turn, as a list of
        `{"role": "user"|"assistant", "content": str}` dicts. The current
        user input is passed separately so the agent can put it through
        its scratchpad / tool-use loop.

        Returns the assistant's reply. Raises whatever the agent or its
        tools raise — the caller decides how to surface that to the user.
        """
        # Stamp user_id (and session_id, same value) onto every span
        # emitted within this thread's context. Surfaces in Langfuse v3
        # as `metadata.traceloop.association.properties.user_id` and is
        # filterable from the UI.
        Traceloop.set_association_properties({"user_id": self._user_id, "session_id": self._user_id})
        result = self._executor.invoke(
            {"input": user_input, "chat_history": _to_lc_history(history)},
        )
        return result.get("output") or "(no response)"


def build_executor(user_id: str) -> Agent:
    """Construct an Agent bound to `user_id`. Thin factory used by `app.py` so
    Streamlit's `@st.cache_resource` has a single function to cache."""
    return Agent(user_id)
