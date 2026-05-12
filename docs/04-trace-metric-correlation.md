# 04 · Trace ↔ metric correlation

> The headline lesson of the sandbox: pick one trace, find its
> wall-clock window, line that window up with the dashboards. Two pillars,
> one event, three views — and you'll *see* prefill burstiness with your
> own eyes.
>
> Read after [03 saturation analysis](03-saturation-analysis.md). Best
> with the `mixed` or `prefill-heavy` profile still running, or fresh
> in your TSDB.

---

## The setup

Run a moderate load so there's something interesting to look at:

```bash
./scripts/load.sh prefill-heavy
```

While it runs (~30 s), open three browser tabs:

1. **Langfuse** — <http://localhost:3001> → filter `userId = (whatever
   user-id you used in Streamlit before)` or just take the most recent
   trace. *(If you only ran load via the gateway and not via Streamlit,
   no Langfuse traces exist — the gateway path bypasses the LangChain
   callback. You can still do this walkthrough using one of the older
   Streamlit traces you produced in section 01.)*
2. **LLM Overview** — <http://localhost:3000/d/llm-overview/llm-overview>,
   refresh **5 s**, range **Last 15 minutes**.
3. **GPU Saturation** — <http://localhost:3000/d/gpu-saturation/gpu-saturation>,
   same range / refresh.

---

## Pick a trace and read its clock

In Langfuse, click any `AgentExecutor` trace. The top of the trace detail
view shows:

- **Timestamp** — e.g. `2026-05-12T13:42:18.234Z`. This is the trace
  *start*.
- **Latency** — e.g. `4.12 s`. End time = start + latency.

Note both. You'll line up the dashboards to this window in a moment.

Below the timestamp is the **span timeline view** — a flame-graph-ish
breakdown of the spans by wall-clock. Specifically look at:

- The two `ChatOpenAI` (`GENERATION`) spans — these are the actual LLM
  calls. Their durations are what dominate the latency.
- The tool spans between them — short, sub-100 ms.

If the trace was for a multi-tool prompt, you'll see something like:

```
00.00 s ─┬─ AgentExecutor                              (4.12 s)
00.00 s ─┼─── RunnableSequence (LLM call 1)            (1.43 s)
00.02 s ─┼─────── ChatOpenAI                           (1.40 s)  ◀ first LLM call
01.45 s ─┼─── get_current_weather                      (0.02 s)
01.47 s ─┼─── get_stock_price                          (0.02 s)
01.49 s ─┴─── RunnableSequence (LLM call 2)            (2.61 s)
                ChatOpenAI                              (2.58 s)  ◀ second LLM call
```

Now we'll match that against power.

---

## Line it up with the GPU power panel

On the GPU Saturation dashboard, **zoom to the relevant window** — click
and drag horizontally across the time of the trace. You should now see:

- A **brief power spike** that lines up with the *first* `ChatOpenAI` span.
- A **second**, often bigger spike right where the *second* `ChatOpenAI`
  span is.
- In between, power **drops back near idle** — those are the tool spans
  (mock-services responds in ~20 ms, no GPU work happening).

If you took the prompt from `prefill-heavy` (long input, brief output),
each spike has a sharp rise (prefill) and a fast fall (short decode). That
sharp-rise-fast-fall *is* the prefill signature.

If you took the prompt from `decode-heavy` (short input, long output),
each spike has a smaller initial rise (prefill) followed by a long, lower
plateau (decode). Different shape, same correlation.

---

## What you've just observed

This is the **prefill vs decode burstiness** pattern:

- **Prefill** is compute-bound and lasts only as long as it takes to push
  the prompt through the model once. For a 1000-token prompt on Qwen-3B,
  that's around 150-250 ms — and during that time the GPU is at near-peak
  power.
- **Decode** is mostly memory-bandwidth-bound (loading KV cache for each
  step). Per-token, it's cheaper compute and lower power, but it lasts
  for as many tokens as you generate.

Power graph reveals this *without* anyone instrumenting prefill vs decode
explicitly. The trace timeline reveals it as latency math. Together they
make the abstract phases concrete.

---

## The same lesson without traces

If you ever lose access to traces (different stack, no Langfuse), the
*queue depth* + *GPU power* pair alone tells the same story:

- Queue depth `running` going from 1 → 3 → 5 → 3 → 1 = a burst of prefills.
- Sustained `running` ≥ 5 with steady high power = batch in steady-state decode.

Watch <http://localhost:3000/d/llm-overview/llm-overview> during `saturation`
profile's `sat-10rps` stage — that pattern is impossible to miss.

---

## Multi-user attribution: same trick across users

If your load came from the Streamlit app with multiple user-ids
(`robert`, `maliwan`, etc.), do the same exercise twice:

1. Filter Langfuse by `userId=robert` → pick a trace at time T.
2. On the GPU panel, find the spike at T → identify which Grafana
   timestamp it is.
3. Now filter Langfuse by `userId=maliwan` → if Maliwan had a trace at
   the same T (or overlapping), they share the GPU. That's the
   multi-tenancy observability lesson — *one user's traffic is another
   user's tail-latency contributor*.

---

## What's next

Phase 1.3 ends here. Phase 1.4 (CI + polish) and beyond:

- **Phase 2 (deferred):** Triton + TensorRT-LLM as a second backend in
  LiteLLM. The swap is one config line. Re-run all of `03 saturation`
  against the new backend and compare numbers — this is the "switch-over
  test" the original plan called out.

- **Logs pillar (deferred):** add Loki + Promtail so log lines from each
  service are searchable, and a Grafana log panel sits alongside the
  metrics panels for end-to-end debugging.

- **Langfuse v3:** unlocks OTLP/HTTP, which brings back OpenLLMetry's
  per-tool httpx sub-spans and other auto-instrumentation. Hefty
  infrastructure cost (ClickHouse, Redis, Minio); see plan §5.7 trade-off
  table.

In any of those directions, the methodology stays the same: change one
layer, re-run the load profiles in [03](03-saturation-analysis.md),
re-do the correlation in this doc, see what changed.

That's the whole point of the lab.
