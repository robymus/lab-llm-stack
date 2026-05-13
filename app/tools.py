"""LangChain tools — the agent's external "verbs".

Each tool is a thin wrapper around an httpx GET into the mock-services
container. The docstrings matter: LangChain feeds them to the LLM as
the tool's description, which is what the model uses to decide which
tool to pick. Keep them accurate and concise.

Why httpx (not requests): OpenLLMetry's auto-instrumentor patches httpx's
client to emit an OTel span for every HTTP call. Each tool span in
Langfuse therefore has an `httpx GET ...` child span — the network round
trip is visible, not hidden.
"""

import os

import httpx
from langchain_core.tools import tool

# Single shared client — connection pooling makes the first call ~50 ms
# faster than a fresh client per tool invocation. timeout is short enough
# that a hung backend fails the tool span rather than blocking the agent
# indefinitely.
_BASE_URL = os.environ["MOCK_SERVICES_URL"]
_client = httpx.Client(base_url=_BASE_URL, timeout=5.0)


# ---------------------------------------------------------------------------
#  Tools
# ---------------------------------------------------------------------------
# The @tool decorator turns a plain function into a LangChain Tool, using
# the docstring as `description`. Argument types come from type hints.


@tool
def get_current_weather(city: str) -> str:
    """Get the current weather summary for a city. Useful for travel and
    activity questions. Returns a short text summary or a not-found message
    if the city isn't in our dataset."""
    r = _client.get(f"/weather/{city}")
    if r.status_code == 404:
        return f"No weather data for {city}."
    return r.json()["summary"]


@tool
def get_news(topic: str, limit: int = 3) -> str:
    """Get recent news headlines for a topic. Good topics include 'ai',
    'tech', 'stocks', 'weather'. Returns up to `limit` headlines."""
    r = _client.get("/news", params={"topic": topic, "limit": limit})
    headlines = r.json().get("headlines", [])
    if not headlines:
        return f"No headlines found for {topic}."
    return "\n".join(f"- {h}" for h in headlines)


@tool
def get_stock_price(ticker: str) -> str:
    """Get the latest price and 24-hour percent change for a stock ticker
    (e.g. AAPL, NVDA, TSLA, MSFT, GOOGL)."""
    r = _client.get(f"/stocks/{ticker.upper()}")
    if r.status_code == 404:
        return f"Unknown ticker {ticker}."
    d = r.json()
    return f"{d['ticker']}: ${d['price']:.2f} ({d['change_pct']:+.2f}%)"


@tool
def search_documents(query: str) -> str:
    """Search the sandbox knowledge base for relevant snippets. Best for
    questions about the LLM stack itself (vLLM, LiteLLM, DCGM, Langfuse,
    etc.). Returns up to 3 short matches."""
    r = _client.get("/docs/search", params={"q": query})
    hits = r.json().get("hits", [])
    if not hits:
        return f"No documents match '{query}'."
    return "\n".join(f"[{h['id']}] {h['snippet']}" for h in hits)


@tool
def flaky_call(seed: str = "default") -> str:
    """An intentionally flaky endpoint — about 30% chance of HTTP 500.
    Deterministic by seed: same seed → same outcome. Only call this when
    the user explicitly asks to demonstrate or test error handling."""
    r = _client.get("/flaky", params={"seed": seed})
    # Let an HTTP error surface as an exception so OpenLLMetry marks the
    # span as failed; AgentExecutor catches it and feeds the error back
    # to the LLM as part of the scratchpad.
    r.raise_for_status()
    return r.json()["message"]


ALL_TOOLS = [
    get_current_weather,
    get_news,
    get_stock_price,
    search_documents,
    flaky_call,
]
