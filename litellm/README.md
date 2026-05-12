# LiteLLM gateway

> The middle of the stack. The agent talks to *this*, not to vLLM. Whichever
> backend serves a request, the API the app sees is identical.

## What this is

[LiteLLM](https://docs.litellm.ai/) is a Python-based gateway that exposes one
OpenAI-compatible endpoint and routes requests to 100+ different LLM backends
(OpenAI, Anthropic, vLLM, Triton, Bedrock, local Ollama, …). In this sandbox
we use it for one job: **decoupling the app from the inference engine.**

It also happens to give us:
- A per-request `/metrics` endpoint Prometheus scrapes (request rate,
  latency, token counts — labelled by model and user).
- Header pass-through, which is how we propagate `X-User-Id` end-to-end.
- A natural place to add per-tenant rate limits, retries, or fallback
  routing later (deferred to Phase 2/3).

## Why it's here — the Phase 2 seam

This file is the *most important file in the repo for the learning goal*:

```yaml
# litellm/config.yaml
model_list:
  - model_name: qwen-chat
    litellm_params:
      model: openai/qwen-chat
      api_base: http://vllm-engine:8000/v1   # ← the entire Phase 2 swap point
```

When Phase 2 plugs in Triton + TensorRT-LLM, the diff to this file looks like:

```diff
   - model_name: qwen-chat
     litellm_params:
       model: openai/qwen-chat
       api_base: http://vllm-engine:8000/v1
+  - model_name: qwen-chat-trt
+    litellm_params:
+      model: openai/ensemble                 # Triton's model name
+      api_base: http://triton:8000/v2
```

And the app's `model="qwen-chat"` becomes `model="qwen-chat-trt"`. No app
code changes. No Prometheus changes. No Langfuse changes. **That** is what
a gateway is for, and that's the lesson worth internalising.

## Configuration walkthrough

[`config.yaml`](./config.yaml) has three sections:

1. **`model_list`** — what logical model names exist and where each one
   resolves. The `openai/` prefix on `model:` is LiteLLM's way of saying
   "talk to it using the OpenAI Chat Completions wire format" — which vLLM
   speaks natively.

2. **`litellm_settings`** —
   - `callbacks: ["prometheus"]` turns on the `/metrics` endpoint we scrape
     in Phase 1.1.
   - `forward_client_headers_to_llm_api: true` is required for `X-User-Id`
     to reach vLLM (and Triton later); without it the gateway silently
     strips client headers.

3. **`general_settings`** —
   - `master_key: os.environ/LITELLM_MASTER_KEY` is LiteLLM's syntax for
     "read this value from the environment at startup." Real secret stays
     in `.env`, never in this file.
   - `telemetry: false` disables LiteLLM's anonymous-usage pings.

## Smoke tests

After `docker compose up vllm-engine litellm`:

```bash
# Health
curl -s http://localhost:4000/health/liveliness

# Make a request through the gateway (same shape as hitting vLLM directly,
# but through :4000 and with the master key).
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $(grep ^LITELLM_MASTER_KEY .env | cut -d= -f2)" \
  -H 'Content-Type: application/json' \
  -d '{
        "model": "qwen-chat",
        "messages": [{"role": "user", "content": "Say hi in one word."}]
      }' | jq

# Metrics endpoint (Prometheus scrapes this in Phase 1.1)
curl -s http://localhost:4000/metrics | head -30

# User-id propagation. Watch the LiteLLM logs (`docker compose logs -f litellm`)
# while running this; you should see X-User-Id arrive.
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $(grep ^LITELLM_MASTER_KEY .env | cut -d= -f2)" \
  -H "X-User-Id: robert" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen-chat","messages":[{"role":"user","content":"hi"}]}' | jq
```

## Useful Prometheus series

LiteLLM's exporter exposes per-model + per-user labelled series. The
authoritative names depend on the version, but the families you'll use:

- `litellm_request_total_latency_metric_*` — request-end-to-end latency
  histogram (gateway side, includes network to backend).
- `litellm_total_tokens` / `litellm_input_tokens` / `litellm_output_tokens`
  — counter by model and user.
- `litellm_proxy_total_requests_metric` — request count, useful for
  throughput PromQL.

Discover the actual names live:

```bash
curl -s http://localhost:4000/metrics | grep ^# HELP
```

This is *the* spot Phase 1.1's recording rules read from — confirm the
exact names there before editing `prometheus/rules/llm.rules.yml`.

## Where to look when it breaks

| Symptom | Likely cause | Where to look |
| ------- | ------------ | ------------- |
| 401 from gateway | Wrong/missing `Authorization: Bearer ${LITELLM_MASTER_KEY}` | Check `.env` and the header in your curl |
| 504/timeout from gateway | vLLM still loading the model | `docker compose logs vllm-engine` |
| Backend reachable but model unknown | Mismatch between `served-model-name` (vLLM) and `model_name` (LiteLLM) | They must match. Both are `qwen-chat` here. |
| `X-User-Id` not arriving at vLLM | `forward_client_headers_to_llm_api` not enabled | Already on; check you didn't edit it out |
| `/metrics` returns 404 | `callbacks: ["prometheus"]` missing | Check `litellm_settings` block |

## What's next

- Phase 1.1: Prometheus starts scraping `:4000/metrics`, recording rules
  derive p95 latency series from the histograms here.
- Phase 1.2: the agent app actually consumes this gateway. Until then,
  curl is your friend.
