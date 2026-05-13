"""Endpoint contract tests for mock-services.

The agent's tools depend on specific JSON shapes. These tests pin them: if
someone renames a field or changes a status code, the test fails before the
agent's "garbled answers" become the first signal something's wrong.

We use FastAPI's TestClient (an httpx wrapper) — no network, no container —
so the tests are fast and run identically locally and in CI.
"""

import hashlib

import pytest
from fastapi.testclient import TestClient

from main import app

client = TestClient(app)


# ---------------------------------------------------------------------------
#  /health
# ---------------------------------------------------------------------------


def test_health_returns_ok():
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


# ---------------------------------------------------------------------------
#  /weather/{city}
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("city", ["london", "paris", "tokyo", "new york", "berlin", "sydney"])
def test_weather_known_city_shape(city):
    r = client.get(f"/weather/{city}")
    assert r.status_code == 200
    body = r.json()
    assert body["city"] == city
    assert isinstance(body["summary"], str) and body["summary"]


def test_weather_unknown_city_returns_404():
    r = client.get("/weather/atlantis")
    assert r.status_code == 404
    assert "atlantis" in r.json()["detail"]


def test_weather_case_insensitive():
    r = client.get("/weather/LONDON")
    assert r.status_code == 200


# ---------------------------------------------------------------------------
#  /news
# ---------------------------------------------------------------------------


def test_news_known_topic_returns_headlines():
    r = client.get("/news", params={"topic": "ai"})
    assert r.status_code == 200
    body = r.json()
    assert body["topic"] == "ai"
    assert isinstance(body["headlines"], list)
    assert all(isinstance(h, str) for h in body["headlines"])


def test_news_unknown_topic_returns_empty_list():
    r = client.get("/news", params={"topic": "asdf-not-a-topic"})
    assert r.status_code == 200
    assert r.json()["headlines"] == []


def test_news_limit_caps_results():
    r = client.get("/news", params={"topic": "ai", "limit": 1})
    assert r.status_code == 200
    assert len(r.json()["headlines"]) == 1


# ---------------------------------------------------------------------------
#  /stocks/{ticker}
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("ticker", ["AAPL", "NVDA", "TSLA", "MSFT", "GOOGL"])
def test_stocks_known_ticker_shape(ticker):
    r = client.get(f"/stocks/{ticker}")
    assert r.status_code == 200
    body = r.json()
    assert body["ticker"] == ticker
    assert isinstance(body["price"], (int, float))
    assert isinstance(body["change_pct"], (int, float))


def test_stocks_unknown_ticker_returns_404():
    r = client.get("/stocks/ZZZZ")
    assert r.status_code == 404


def test_stocks_lowercase_input_normalises():
    r = client.get("/stocks/aapl")
    assert r.status_code == 200
    assert r.json()["ticker"] == "AAPL"


# ---------------------------------------------------------------------------
#  /docs/search
# ---------------------------------------------------------------------------


def test_docs_search_returns_hits_for_known_term():
    r = client.get("/docs/search", params={"q": "vllm"})
    assert r.status_code == 200
    body = r.json()
    assert body["query"] == "vllm"
    assert len(body["hits"]) >= 1
    assert all(set(h.keys()) == {"id", "snippet"} for h in body["hits"])


def test_docs_search_no_match_returns_empty_hits():
    r = client.get("/docs/search", params={"q": "asdfqwertyzxcv"})
    assert r.status_code == 200
    assert r.json()["hits"] == []


# ---------------------------------------------------------------------------
#  /flaky — determinism is the contract here
# ---------------------------------------------------------------------------


def _expected_status(seed: str) -> int:
    """Mirror the production logic: md5(seed)[0] < 76 → 500."""
    h = hashlib.md5(seed.encode()).digest()[0]
    return 500 if h < 76 else 200


@pytest.mark.parametrize("seed", ["a", "b", "c", "test", "boom", "default"])
def test_flaky_is_deterministic_for_seed(seed):
    r = client.get("/flaky", params={"seed": seed})
    assert r.status_code == _expected_status(seed)


def test_flaky_500_payload_mentions_seed():
    # Find a seed that produces a 500 and assert the error body includes it.
    for seed in ("a", "z", "0", "1", "2", "3"):
        if _expected_status(seed) == 500:
            r = client.get("/flaky", params={"seed": seed})
            assert r.status_code == 500
            assert seed in r.json()["detail"]
            return
    pytest.skip("no 500-yielding seed in the small sample — unexpected")


def test_flaky_success_payload_shape():
    for seed in ("a", "z", "0", "1", "2", "3"):
        if _expected_status(seed) == 200:
            r = client.get("/flaky", params={"seed": seed})
            assert r.status_code == 200
            body = r.json()
            assert seed in body["message"]
            assert isinstance(body["hash_byte"], int)
            return
    pytest.skip("no 200-yielding seed in the small sample — unexpected")


# ---------------------------------------------------------------------------
#  /metrics — exposed by the Prometheus instrumentator
# ---------------------------------------------------------------------------


def test_metrics_endpoint_returns_prometheus_format():
    # Hit at least one endpoint first so a request_total sample exists.
    client.get("/health")
    r = client.get("/metrics")
    assert r.status_code == 200
    body = r.text
    # Prometheus exposition format: HELP / TYPE lines and a counter we know about.
    assert "# HELP" in body
    assert "# TYPE" in body
    assert "http_requests_total" in body
