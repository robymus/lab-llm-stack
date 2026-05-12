"""LangChain agent + Langfuse instrumentation, encapsulated as `Agent`.

Tracing path: LangChain's `CallbackHandler` mechanism. The Langfuse SDK's
handler hooks into the standard LangChain callbacks for chain/llm/tool
events, batches them, and POSTs to Langfuse's ingestion API.

Why not OTLP via OpenLLMetry / Traceloop? Langfuse v2 doesn't expose an
OTLP/HTTP endpoint — that's a v3 feature (which would need a separate
ClickHouse + Redis + Minio backend the plan deliberately avoids). The
trace tree visible in the Langfuse UI is identical either way; only the
transport differs.

Loss from this trade-off: httpx calls inside our tools don't appear as
separate child spans (OTLP + Traceloop + Langfuse-v3 would show them, but
the v2-native callback won't). Each tool span shows the function call and
its return value; the in-flight HTTP round trip is collapsed inside. To
inspect those, the mock-services container exposes its own /metrics with
per-handler latency histograms — same information, different surface.

Escape hatch: if we ever upgrade Langfuse to v3, this whole module flips
back to traceloop-sdk + OTLP. The app-facing API (`Agent` / `chat`) stays
the same; only the inside of `Agent` changes.
"""

import os

from langchain_core.messages import AIMessage, HumanMessage
from langchain_core.prompts import ChatPromptTemplate
from langchain.agents import AgentExecutor, create_tool_calling_agent
from langchain_openai import ChatOpenAI
from langfuse.callback import CallbackHandler

from tools import ALL_TOOLS


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

_PROMPT = ChatPromptTemplate.from_messages([
    ("system", SYSTEM_PROMPT),
    ("placeholder", "{chat_history}"),
    ("user", "{input}"),
    ("placeholder", "{agent_scratchpad}"),
])


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
    """An LLM agent bound to one user_id, with Langfuse tracing built in.

    The Langfuse `CallbackHandler` and the LangChain `AgentExecutor` are
    constructed together and kept private — callers just call `chat(...)`.
    Traces flush at the end of every turn.
    """

    def __init__(self, user_id: str):
        # ---- Langfuse handler ------------------------------------------
        # user_id and session_id both set to the same string so the Langfuse
        # UI's per-user and per-session filters both group cleanly. tags
        # let you filter for "everything from this phase" in the UI.
        self._handler = CallbackHandler(
            public_key=os.environ["LANGFUSE_PUBLIC_KEY"],
            secret_key=os.environ["LANGFUSE_SECRET_KEY"],
            host="http://langfuse:3000",
            user_id=user_id,
            session_id=user_id,
            tags=["llm-sandbox", "phase-1.2"],
        )

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
            # are configured (Phase 2+ exercise); harmless until then.
            model_kwargs={"user": user_id},
            temperature=0.3,
            max_tokens=512,
        )

        # ---- Agent + executor ------------------------------------------
        # Note: callbacks are NOT attached here. They flow in per-call via
        # `invoke(config={"callbacks": [...]})` so they propagate through
        # every child runnable. Attaching to AgentExecutor would only fire
        # at the outermost span — see chat() below.
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
        Whatever happens, the Langfuse trace is flushed before returning
        so the UI sees it within ~1 s.
        """
        try:
            result = self._executor.invoke(
                {"input": user_input, "chat_history": _to_lc_history(history)},
                # Passing the handler via the invoke config (rather than the
                # AgentExecutor constructor) is what gets us the full
                # chain → llm → tool tree in Langfuse on LangChain 0.3+.
                config={"callbacks": [self._handler]},
            )
            return result.get("output") or "(no response)"
        finally:
            # Force-flush so the trace appears in the UI immediately,
            # instead of waiting for the SDK's background batch window.
            self._handler.flush()


def build_executor(user_id: str) -> Agent:
    """Construct an Agent bound to `user_id`. Thin factory used by `app.py` so
    Streamlit's `@st.cache_resource` has a single function to cache."""
    return Agent(user_id)
