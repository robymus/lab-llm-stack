# OpenTelemetry Collector

> Routing hub between trace emitters (the agent app today; LiteLLM /
> vLLM tomorrow) and the trace store (Langfuse v3). Holds the Langfuse
> credentials so emitters don't have to. Batches small bursts of spans
> into larger HTTP calls.

## What this is

The [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)
runs as a separate container that:

1. Listens for OTLP/HTTP traffic on `:4318` (and OTLP/gRPC on `:4317`,
   network-internal only).
2. Tags each span with a `source` attribute, batches them up to 200 ms,
3. Forwards them to Langfuse v3's OTLP endpoint with HTTP Basic auth.

We use the **contrib** distribution (`otel/opentelemetry-collector-contrib`)
because the `basicauth` extension and the `attributes` processor live in
contrib, not core.

## Why it's here

Phase 1.2 had the agent app talking directly to Langfuse via the SDK
callback. That made the app know about Langfuse — its hostname, its
credentials, its protocol. Phase 2.2 inserts this collector between
them so that:

- **The app doesn't know about Langfuse anymore.** It pushes plain OTLP
  to `http://otel-collector:4318` and walks away. If we ever switch
  trace stores (Tempo, Honeycomb, Jaeger), only this collector's config
  changes — the app is untouched. That's the same "decouple from
  downstream" lesson LiteLLM teaches at the gateway layer.
- **One credentials surface.** `LANGFUSE_PUBLIC_KEY` /
  `LANGFUSE_SECRET_KEY` live on the collector container (consumed by the
  `basicauth/langfuse` extension), not in every emitter.
- **Batching.** Single-span POSTs from a streaming agent would hammer
  Langfuse with chatter; the `batch` processor coalesces them.

## Files

| File | What it is |
| ---- | ---------- |
| [config.yaml](config.yaml) | The collector pipeline (receivers → processors → exporters). |
| `docker-compose.yaml` (otel-collector block) | Service definition: image pin, port map, env, healthcheck. |

## Configuration walkthrough

### Receivers

`otlp` receives on both HTTP/4318 and gRPC/4317. Only 4318 is published
to the host (so `curl localhost:4318` works for a one-off test); 4317
is reachable only inside the docker network. Apps inside compose can
target either.

### Processors

Two processors run in series:

1. **`batch`** — combine spans into `≤ 8 KiB` chunks or `200 ms`
   windows, whichever comes first. The 200 ms ceiling means the worst-case
   latency between "span produced" and "span visible in Langfuse" is
   half a second.
2. **`attributes/source`** — inserts `source = otel-collector` on every
   span. Useful once we add a second emitter (e.g. LiteLLM's own OTLP
   output) so Langfuse can filter "from the app vs. from the gateway".

### Exporters

Two exporters share the same pipeline:

| Exporter | Purpose | Plans |
| -------- | ------- | ----- |
| `otlphttp/langfuse` | Real one — POST to Langfuse v3's OTLP endpoint. | Keeps. |
| `debug` (verbosity `detailed`) | Logs every batch to stdout for debugging while Phase 2.2 stabilises. | **Remove** once OTLP path is verified. (TODO open at the top of `config.yaml`.) |

### Extensions

| Extension | Purpose |
| --------- | ------- |
| `basicauth/langfuse` | Holds the Langfuse public/secret key pair. `otlphttp/langfuse` references it via `auth.authenticator`. |
| `health_check` | Returns 200 OK on `:13133/` once the collector is initialised. Docker-compose hits this for the healthcheck. |

### Telemetry

The collector emits its own Prometheus metrics on `:8888/metrics`. A
Prometheus scrape job (`otel-collector`) collects them; key series:

| Metric | What it tells you |
| ------ | ----------------- |
| `otelcol_receiver_accepted_spans` | Spans coming IN from emitters. |
| `otelcol_exporter_sent_spans` | Spans going OUT to Langfuse. |
| `otelcol_exporter_send_failed_spans` | Drops on the way out — auth issues, network errors. |
| `otelcol_processor_batch_batch_send_size` | Histogram of batch sizes — confirms batching is doing something. |
| `otelcol_exporter_queue_size` | Backpressure indicator. |

## Adding a new emitter

Anything that speaks OTLP/HTTP can push to `http://otel-collector:4318`
from inside the network. Two practical examples Phase 2.5+ will reach
for:

- **LiteLLM** can be configured with a `langfuse` callback that emits
  OTLP — point its endpoint at the collector and a second `source`
  value flows in.
- **vLLM** has experimental OpenTelemetry support; same hook-up.

## Adding a new exporter

Suppose you want traces to *also* land in Grafana Tempo:

1. Add the new exporter under `exporters:`:
   ```yaml
   otlp/tempo:
     endpoint: http://tempo:4317
     tls:
       insecure: true
   ```
2. Append it to the pipeline:
   ```yaml
   service:
     pipelines:
       traces:
         exporters: [otlphttp/langfuse, otlp/tempo, debug]
   ```
3. Restart the collector. No app code touches.

## Smoke tests

```bash
# Healthy?
curl -s http://localhost:13133/      # 200 OK (no body)

# Push a synthetic OTLP/HTTP trace from the host
# (uses a tiny static payload — adapt to your shell of choice)
curl -s -X POST http://localhost:4318/v1/traces \
  -H 'Content-Type: application/json' \
  -d '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"smoke-test"}}]},"scopeSpans":[{"scope":{"name":"smoke"},"spans":[{"traceId":"00112233445566778899aabbccddeeff","spanId":"0011223344556677","name":"hello","kind":1,"startTimeUnixNano":"1700000000000000000","endTimeUnixNano":"1700000000100000000"}]}]}]}'
# → {} on success

# Watch it flow through (assuming the debug exporter is still on)
docker compose logs --tail=20 otel-collector | grep -E 'TracesExporter|spans'

# Metrics endpoint
curl -s http://localhost:8888/metrics | grep -E '^otelcol_(receiver|exporter)_'
```

## Where to look when it breaks

| Symptom | Likely cause | Fix |
| ------- | ------------ | --- |
| Collector starts, then exits 1 immediately | Env var `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` empty at start | Confirm both are populated in `.env`; the `basicauth` extension validates at boot |
| Spans accepted but `otelcol_exporter_send_failed_spans` climbs | Langfuse rejected the POST | `docker compose logs otel-collector` will show the HTTP status; common cause: wrong key pair (re-copy from the Langfuse UI), or v3 not healthy yet |
| 404 on `POST /v1/traces` | App pointed at port `4317` (gRPC) but sent HTTP/JSON | Set `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318` (HTTP); 4317 is gRPC only |
| No `httpx.GET` spans appear under tool spans | Auto-instrumentation didn't pick up httpx | Confirm `traceloop-sdk` is installed (or `opentelemetry-instrumentation-httpx`); restart `app` |
| Collector logs `Permanent error: x509: certificate ...` | Endpoint mistakenly using HTTPS | Plain `http://` is what we want inside the network |

## What's next

- **Phase 2.2 cleanup**: remove the `debug` exporter once the OTLP path
  is verified stable (one-line edit in `config.yaml`, restart the
  collector).
- **Phase 2.5+** is when LiteLLM's OTLP callback would plug in here, so
  per-request gateway spans land in the same trace as the agent's chain.
