# 05 · Trace ↔ log correlation

> Phase 2.3 closed the loop: now you can pick a trace in Langfuse, copy
> its wall-clock window, and *see the matching gateway log lines* on the
> same Grafana dashboard you use for metrics. Three pillars, one event,
> one tab-switching dance.
>
> Read after [04 trace ↔ metric correlation](04-trace-metric-correlation.md).
> Best while a Streamlit conversation is still fresh.

---

## The setup

You need a trace to chase. Either:

1. Pick a recent multi-tool turn in Streamlit
   (e.g. *"weather in Tokyo and NVDA price?"*). The bigger the trace,
   the easier this is.
2. Or drive a synthetic one from the host shell:

   ```bash
   docker compose exec -T app python - <<'PY'
   import agent
   ex = agent.build_executor("walkthrough-user")
   print(ex.chat("Weather in Tokyo and NVDA price?", []))
   PY
   ```

Then open three browser tabs:

1. **Langfuse** — <http://localhost:3001> → traces → filter by
   `userId = walkthrough-user` (or whatever you used in Streamlit).
2. **LLM Overview dashboard** — <http://localhost:3000/d/llm-overview/llm-overview>.
3. **Grafana Explore (Loki)** — <http://localhost:3000/explore?left=%7B%22datasource%22%3A%22loki%22%7D>.

---

## Step 1 — Find the trace

In Langfuse, open your most recent trace. The header shows the
**start timestamp** (e.g. `2026-05-14 02:14:21.847`) and the **total
duration** (e.g. `1.2s`). Expand the tree and note:

- The **AgentExecutor.workflow** span at the root — that's the
  per-conversation-turn wall-clock window.
- The `userId` filter on the left sidebar — `walkthrough-user`.
- The `phase-2.2` tag (set by the otel-collector). Filterable.

What you're going to do with the timestamp: **take the start-time
minus ~5 seconds and the end-time plus ~5 seconds** as your Grafana
time range. The 5 s of padding handles clock skew between the agent
and Promtail's docker timestamps (usually < 1 s, but better safe).

---

## Step 2 — Switch to Grafana with the trace's time range

In Grafana's time-range picker (top right), click **Custom time range**
and paste the start/end from step 1.

Click into the **LLM Overview** dashboard. Scroll to the bottom panel:
**"LiteLLM access log (filtered)"**. You should see lines like:

```
INFO:     172.20.0.7:42120 - "POST /chat/completions HTTP/1.1" 200 OK
```

One `POST /chat/completions` per LLM call in your trace (so a
two-tool turn produces two — first call gets the tool decision, second
synthesises the final answer from the tool results). If you see zero
lines for the window: the time range is wrong (clock skew or wrong tab)
or the trace was from before Phase 2.3 was deployed.

---

## Step 3 — Cross-reference

Three things to notice on this side:

| What | Where | Tells you |
| ---- | ----- | --------- |
| **Number of `/chat/completions` POSTs** | log panel | How many LLM round-trips this trace involved — should match the count of `ChatOpenAI.chat` Generations in the Langfuse trace |
| **Status codes** | log panel | `200` for success, `429` for rate-limit (Phase 2.4), `5xx` for backend errors |
| **Request rate spike** | "Request rate (rps)" panel | The single-turn load registered as a brief uptick |
| **GPU power spike** | the GPU Saturation dashboard, same time window | Same event, hardware view |

Three pillars, one event. That's the lesson.

---

## Step 4 — Drill into a specific service

The overview panel is filtered to LiteLLM. To pivot to another service,
switch to **Grafana Explore → Loki** and run:

```
{service="vllm-engine"}     # vLLM's startup + inference logs
{service="mock-services"}   # FastAPI access log for tool calls
{service="app"}             # Streamlit + agent.py stdout
{service="langfuse"}        # Langfuse v3 web container
{service="otel-collector"}  # The OTLP collector's debug output
```

Each label is a separate stream that Promtail's docker-SD attached
when the container started.

---

## Useful queries to keep in your pocket

```
# Every tool call in mock-services (most recent first)
{service="mock-services"} |= "GET /"

# Anything that returned 5xx anywhere
{service=~".+"} |= "500" or |= "502" or |= "503"

# OTel collector's batch sends (matches the trace path)
{service="otel-collector"} |= "TracesExporter"

# Langfuse worker's ingest activity
{service="langfuse-worker"} |= "ingestion"

# Filter to just one user-id from the agent
{service="app"} |= "user_id"
```

LogQL uses `|=` for "contains", `!=` for "doesn't contain",
`|~` for regex match. Combine them: `{service="litellm"} |= "POST" != "200"`.

---

## When the log panel is empty

| Symptom | Likely cause | Fix |
| ------- | ------------ | --- |
| Panel says "No logs found" for a clearly populated window | Time range covers a period before Phase 2.3 was deployed | Pick a more recent trace |
| `{service="litellm"}` works in Explore but the panel is empty | Healthcheck filter `!= "/health/liveliness" != "/metrics/"` excluded everything (no actual traffic) | Drive a real chat turn — the filter is intentional, not a bug |
| All services show logs except one | That container started before Promtail discovered it AND hasn't logged since | `docker compose restart <service>` |
| Logs lag by more than a few seconds | Promtail's `refresh_interval: 5s` is the floor; the docker SD picks up new containers within that window | Wait 5 s, retry; if persistent see [promtail/README.md](../promtail/README.md) |

---

## What you've now seen

- Phase 1's metrics show *how much* and *how fast*.
- Phase 2.1–2.2's traces show *what the agent did*.
- Phase 2.3's logs show *the raw HTTP* underneath.

All three pillars in one Grafana time-range; one trace, three views.
That's the cross-pillar workflow this sandbox was built to teach.
