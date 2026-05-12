"""Mock services — fake backends the agent's tools call.

Existence rationale: the agent's five LangChain tools call into these
endpoints over HTTP (not in-process Python functions). The HTTP round-trip
produces real network spans in Langfuse, which is the whole point of
having a tool-call observability story.

Conventions:
- Every endpoint returns JSON.
- Unknown-input endpoints return 404 (not an empty result) so tools can
  surface "I don't know" cleanly.
- `/flaky` is deterministic given the same `seed` — important so we can
  reproduce a failure on demand for trace demos.
- Datasets are tiny on-purpose; the agent's job is to pick the right
  tool, not to do real retrieval.
"""

import hashlib

from fastapi import FastAPI, HTTPException
from prometheus_fastapi_instrumentator import Instrumentator

app = FastAPI(
    title="LLM Sandbox Mock Services",
    description="Tiny backends the agent's tools call so trace trees include real HTTP spans.",
    version="1.0.0",
)


# ---------------------------------------------------------------------------
#  Canned datasets
# ---------------------------------------------------------------------------
# Kept as module-level constants so the LLM's docstrings (which list known
# values) stay in sync with the data — anyone editing this file sees both
# at once.

WEATHER = {
    "london":   {"summary": "Overcast, 15 °C, 80% chance of rain. Bring an umbrella."},
    "paris":    {"summary": "Sunny, 22 °C. Light wind from the west."},
    "tokyo":    {"summary": "Hot and humid, 31 °C. Thunderstorms expected this evening."},
    "new york": {"summary": "Clear, 18 °C. Light breeze."},
    "berlin":   {"summary": "Cool and cloudy, 14 °C. Drizzle on and off."},
    "sydney":   {"summary": "Mild, 19 °C. Partly cloudy."},
}

NEWS = {
    "ai":      ["GPT-5 launches with multimodal abilities", "EU finalizes AI Act enforcement rules", "Open-source Llama 4 sees one million downloads"],
    "tech":    ["Major AWS region outage resolved after 4 hours", "Quantum-chip announcement from IBM", "Apple unveils M5-class accelerators"],
    "stocks":  ["Markets rally on Fed pivot signal", "Tech earnings beat estimates broadly", "Bond-yield curve normalizes"],
    "weather": ["Hurricane season forecast updated", "Record warmth across Antarctic peninsula", "Polar vortex disrupts midwest grid"],
}

STOCKS = {
    "AAPL":  {"price": 234.56, "change_pct": 1.23},
    "NVDA":  {"price": 1023.45, "change_pct": -2.34},
    "TSLA":  {"price": 189.12, "change_pct": 5.67},
    "MSFT":  {"price": 412.89, "change_pct": 0.45},
    "GOOGL": {"price": 178.34, "change_pct": -0.89},
}

# Mini "knowledge base" — searched by very dumb keyword match. Enough for
# the LLM to demonstrate a search-then-summarise pattern in traces.
DOCS = [
    {"id": "d1", "snippet": "vLLM uses PagedAttention to manage the KV cache like virtual memory."},
    {"id": "d2", "snippet": "AWQ-INT4 quantization reduces model weight size by roughly four times."},
    {"id": "d3", "snippet": "DCGM exporter exposes GPU power, temperature, and SM activity metrics for Prometheus."},
    {"id": "d4", "snippet": "Langfuse v2 ingests OpenTelemetry traces over OTLP/HTTP at /api/public/otel."},
    {"id": "d5", "snippet": "LiteLLM gateway provides a unified OpenAI-compatible API across many backends."},
    {"id": "d6", "snippet": "Triton with TensorRT-LLM compiles model engines specific to GPU compute capability."},
    {"id": "d7", "snippet": "Prefix caching reuses prompt prefixes across requests; visible as a hit-rate metric."},
    {"id": "d8", "snippet": "OpenLLMetry auto-instruments LangChain, OpenAI client, and httpx for tracing."},
]


# ---------------------------------------------------------------------------
#  Endpoints
# ---------------------------------------------------------------------------

@app.get("/health", tags=["meta"])
def health():
    """Liveness probe. Compose healthcheck hits this."""
    return {"status": "ok"}


@app.get("/weather/{city}", tags=["weather"])
def weather(city: str):
    """Canned weather summary by city. 404 for unknowns — lets the tool surface 'no data'."""
    key = city.lower().strip()
    if key not in WEATHER:
        raise HTTPException(status_code=404, detail=f"No weather data for {city}.")
    return {"city": city, **WEATHER[key]}


@app.get("/news", tags=["news"])
def news(topic: str, limit: int = 3):
    """Headlines for a topic. Empty list (not 404) for unknown topics — the tool returns 'no headlines'."""
    key = topic.lower().strip()
    headlines = NEWS.get(key, [])
    return {"topic": topic, "headlines": headlines[: max(1, limit)]}


@app.get("/stocks/{ticker}", tags=["stocks"])
def stocks(ticker: str):
    """Latest price + 24h change for a ticker. 404 for unknown tickers."""
    key = ticker.upper().strip()
    if key not in STOCKS:
        raise HTTPException(status_code=404, detail=f"Unknown ticker {ticker}.")
    return {"ticker": key, **STOCKS[key]}


@app.get("/docs/search", tags=["docs"])
def docs_search(q: str, limit: int = 3):
    """Very dumb keyword search over a small doc set. Returns up to `limit` hits."""
    words = q.lower().split()
    hits = [d for d in DOCS if any(w in d["snippet"].lower() for w in words)]
    return {"query": q, "hits": hits[: max(1, limit)]}


@app.get("/flaky", tags=["flaky"])
def flaky(seed: str = "default"):
    """
    Intentionally flaky: ~30% chance of 500. Deterministic given `seed`
    so we can reproduce a failure for trace demos.

    Implementation note: we use md5(seed)[0] < 76 (76/256 ≈ 29.7%). The
    8 single-byte buckets behaviour means trying seeds 0..9 you'll hit
    both branches.
    """
    h = hashlib.md5(seed.encode()).digest()[0]
    if h < 76:
        raise HTTPException(status_code=500, detail=f"synthetic failure for seed={seed} (hash byte {h})")
    return {"message": f"ok, seed={seed}", "hash_byte": h}


# ---------------------------------------------------------------------------
#  Prometheus instrumentation
# ---------------------------------------------------------------------------
# Adds a /metrics endpoint exposing the standard FastAPI request count
# and latency histogram, labelled by method + handler + status code.
# Prometheus scrapes this as a sixth target.
Instrumentator().instrument(app).expose(app, endpoint="/metrics")
