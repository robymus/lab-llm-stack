# mock-services

> Tiny FastAPI app the agent's tools call over HTTP. Exists so trace trees
> in Langfuse contain real network round-trips, not just in-process function
> calls.

## What this is

Six endpoints over a thin layer of canned data. The agent picks one based
on the user's question, makes a `GET`, and threads the response back into
its next LLM turn. The whole reason it's a separate container is so the
HTTP traffic is observable — both in Langfuse (the tool span owns the
call) and in Prometheus (per-handler latency).

## Why it's here

Three reasons:

1. **Real network spans in traces.** In-process Python tools would skip
   the network layer entirely. Even if Langfuse v2's callback-based
   transport doesn't split out the httpx call as its own child span, the
   call is observable here via the service's own `/metrics`.
2. **A seventh Prometheus target** — the app-layer of the stack.
3. **A controlled failure surface.** `/flaky` deterministically fails 30%
   of the time, by seed, so we can reliably reproduce "what does an
   error span look like" for the Langfuse demo without any actual breakage.

## Endpoints

| Path | Status codes | Purpose |
| ---- | ------------ | ------- |
| `GET /health` | 200 | Compose healthcheck target |
| `GET /weather/{city}` | 200 / 404 | Canned weather for ~6 cities |
| `GET /news?topic=&limit=` | 200 | Headlines per topic; empty list for unknown |
| `GET /stocks/{ticker}` | 200 / 404 | Price + 24h change for ~5 tickers |
| `GET /docs/search?q=` | 200 | Dumb keyword match over a small doc set |
| `GET /flaky?seed=` | 200 / 500 | ~30% failure rate, deterministic by seed |
| `GET /metrics` | 200 | Prometheus-format request count + latency |

## Datasets

All data lives at the top of [`main.py`](main.py) as module-level constants.
Tiny on-purpose — the agent's job is to pick the right tool, not to do real
retrieval. Edit anything there; restart picks it up via the bind-mount
(actually it's COPYed into the image, so restart needs a rebuild — see
[Dockerfile](Dockerfile)).

## Why the flaky endpoint is deterministic

`/flaky?seed=X` computes `md5(X)[0]` and fails if the first byte is < 76
(76/256 ≈ 29.7%). Same seed → same outcome, every time. Try `seed=a`
(fails), `seed=b` (succeeds), `seed=c` (fails) to see both branches.

This matters because trace demos need reproducibility — you don't want
to ask the user "run this command several times until you see an error"
when you can just say "use seed `a`."

## Smoke tests

```bash
# Health
curl -s http://localhost:9000/health

# Known cities
curl -s http://localhost:9000/weather/london | jq
curl -s http://localhost:9000/weather/paris  | jq

# 404 on unknowns (tools surface this as "no data")
curl -s http://localhost:9000/weather/atlantis -w "\nhttp=%{http_code}\n"

# Multiple topics
curl -s "http://localhost:9000/news?topic=ai&limit=2" | jq

# Stock prices (case-insensitive ticker)
curl -s http://localhost:9000/stocks/NVDA | jq

# Doc search (keyword match)
curl -s "http://localhost:9000/docs/search?q=KV+cache" | jq

# Flaky — try several seeds, see both 200 and 500
for s in a b c d e f; do
  echo -n "seed=$s "
  curl -s -o /dev/null -w "http=%{http_code}\n" "http://localhost:9000/flaky?seed=$s"
done

# Prometheus metrics
curl -s http://localhost:9000/metrics | grep ^http_request | head -10
```

## How Prometheus picks it up

Scrape job in [`../prometheus/prometheus.yml`](../prometheus/prometheus.yml):

```yaml
- job_name: mock-services
  static_configs:
    - targets: ["mock-services:9000"]
      labels: { layer: app }
```

Key series exposed:

- `http_requests_total{handler, method, status}` — counter
- `http_request_duration_seconds_bucket{handler, method, status, le}` — histogram
- `http_request_duration_highr_seconds_*` — high-resolution version for low-latency endpoints

PromQL for per-tool latency p95:

```promql
histogram_quantile(0.95,
  sum by (handler, le) (
    rate(http_request_duration_seconds_bucket{job="mock-services"}[1m])
  )
)
```

## Where to look when it breaks

| Symptom | Likely cause | Fix |
| ------- | ------------ | --- |
| 500 from /weather/{known-city} | KeyError from dataset mismatch | Check `WEATHER` dict in main.py |
| `/flaky` always succeeds | seed didn't reach the endpoint | Confirm via `&seed=a` works; check tool propagation |
| `/metrics` returns 0 lines | `Instrumentator().instrument(app).expose(app)` removed | Restore the line at the bottom of main.py |
| Prometheus target DOWN | service not on `llm-stack` network | `docker network inspect llm-stack_llm-stack` |
| Healthcheck always failing | Python missing in container | Image is `python:3.11-slim` — Python is built in |

## What's next

- Phase 1.4 adds endpoint-shape tests to `tests/test_endpoints.py` so a
  silent change here doesn't break the agent.
- If you want to simulate slow dependencies for saturation demos, give
  `/flaky` a `?delay=` param that does `time.sleep(...)` before returning.
