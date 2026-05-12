# Mock services — *Phase 1.2*

> Not yet implemented. Placeholder for link integrity.

Will cover:
- Five FastAPI endpoints the agent's tools call:
  `/weather/{city}`, `/news`, `/stocks/{ticker}`, `/docs/search`, `/flaky`
- Why this is a separate container (so the HTTP span is real, not in-process)
- Prometheus instrumentation exposing this service's own `/metrics`

See [.plans/llm-sandbox-PLAN.md §5.8](../.plans/llm-sandbox-PLAN.md).
