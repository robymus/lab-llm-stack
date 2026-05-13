"""Unit tests for the agent's tools.

These tests don't touch the network. They mock the mock-services HTTP API at
the httpx transport layer using respx, so each test asserts both:
  (a) the tool calls the right URL with the right params, and
  (b) the tool parses the response shape correctly into the string the LLM sees.

If either drifts — endpoint renamed, response shape changed — the test fails
loudly. That's the whole reason the tests exist: silently-broken tools would
otherwise only show up as garbled agent answers.
"""

import httpx
import pytest
import respx

# Import after conftest.py sets MOCK_SERVICES_URL so the module-level
# httpx.Client picks up the test host.
from tools import (
    flaky_call,
    get_current_weather,
    get_news,
    get_stock_price,
    search_documents,
)

BASE = "http://mock-services.test"


# ---------------------------------------------------------------------------
#  Helpers
# ---------------------------------------------------------------------------


def _invoke(tool, **kwargs) -> str:
    """Call a LangChain `@tool`-decorated function programmatically.

    The decorator wraps the function in a StructuredTool; calling the
    object directly isn't how LangChain expects it to be invoked. Tests
    use `.invoke({...})` for the same reason the agent does.
    """
    return tool.invoke(kwargs)


# ---------------------------------------------------------------------------
#  get_current_weather
# ---------------------------------------------------------------------------


@respx.mock
def test_weather_known_city_returns_summary():
    respx.get(f"{BASE}/weather/london").mock(
        return_value=httpx.Response(200, json={"city": "london", "summary": "Cloudy, 15C."})
    )
    assert _invoke(get_current_weather, city="london") == "Cloudy, 15C."


@respx.mock
def test_weather_unknown_city_returns_friendly_string():
    respx.get(f"{BASE}/weather/atlantis").mock(return_value=httpx.Response(404, json={"detail": "no data"}))
    assert _invoke(get_current_weather, city="atlantis") == "No weather data for atlantis."


# ---------------------------------------------------------------------------
#  get_news
# ---------------------------------------------------------------------------


@respx.mock
def test_news_renders_bullet_list():
    respx.get(f"{BASE}/news").mock(
        return_value=httpx.Response(
            200,
            json={"topic": "ai", "headlines": ["A", "B", "C"]},
        )
    )
    out = _invoke(get_news, topic="ai", limit=3)
    assert out == "- A\n- B\n- C"


@respx.mock
def test_news_empty_returns_friendly_string():
    respx.get(f"{BASE}/news").mock(return_value=httpx.Response(200, json={"topic": "obscure", "headlines": []}))
    assert _invoke(get_news, topic="obscure") == "No headlines found for obscure."


@respx.mock
def test_news_passes_topic_and_limit_as_params():
    route = respx.get(f"{BASE}/news").mock(return_value=httpx.Response(200, json={"topic": "tech", "headlines": ["x"]}))
    _invoke(get_news, topic="tech", limit=5)
    # respx exposes the captured request so we can verify the wire call.
    call = route.calls.last
    assert call.request.url.params["topic"] == "tech"
    assert call.request.url.params["limit"] == "5"


# ---------------------------------------------------------------------------
#  get_stock_price
# ---------------------------------------------------------------------------


@respx.mock
def test_stock_known_ticker_formats_price_and_change():
    respx.get(f"{BASE}/stocks/NVDA").mock(
        return_value=httpx.Response(200, json={"ticker": "NVDA", "price": 1023.45, "change_pct": -2.34})
    )
    assert _invoke(get_stock_price, ticker="nvda") == "NVDA: $1023.45 (-2.34%)"


@respx.mock
def test_stock_unknown_ticker_returns_friendly_string():
    respx.get(f"{BASE}/stocks/ZZZZ").mock(return_value=httpx.Response(404, json={"detail": "unknown"}))
    assert _invoke(get_stock_price, ticker="zzzz") == "Unknown ticker zzzz."


# ---------------------------------------------------------------------------
#  search_documents
# ---------------------------------------------------------------------------


@respx.mock
def test_docs_search_formats_hits_with_ids():
    respx.get(f"{BASE}/docs/search").mock(
        return_value=httpx.Response(
            200,
            json={
                "query": "vllm",
                "hits": [
                    {"id": "d1", "snippet": "vLLM uses PagedAttention."},
                    {"id": "d2", "snippet": "AWQ-INT4 quantization."},
                ],
            },
        )
    )
    out = _invoke(search_documents, query="vllm")
    assert out == "[d1] vLLM uses PagedAttention.\n[d2] AWQ-INT4 quantization."


@respx.mock
def test_docs_search_no_hits_returns_friendly_string():
    respx.get(f"{BASE}/docs/search").mock(return_value=httpx.Response(200, json={"query": "xyz", "hits": []}))
    assert _invoke(search_documents, query="xyz") == "No documents match 'xyz'."


# ---------------------------------------------------------------------------
#  flaky_call
# ---------------------------------------------------------------------------


@respx.mock
def test_flaky_success_returns_message():
    respx.get(f"{BASE}/flaky").mock(return_value=httpx.Response(200, json={"message": "ok, seed=ok", "hash_byte": 200}))
    assert _invoke(flaky_call, seed="ok") == "ok, seed=ok"


@respx.mock
def test_flaky_500_raises_httpstatus_error():
    """The tool calls `r.raise_for_status()` so a 500 propagates out, which
    is what makes Langfuse mark the span as failed instead of silently
    swallowing the error."""
    respx.get(f"{BASE}/flaky").mock(return_value=httpx.Response(500, json={"detail": "synthetic failure"}))
    with pytest.raises(httpx.HTTPStatusError):
        _invoke(flaky_call, seed="boom")
