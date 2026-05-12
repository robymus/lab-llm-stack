# vLLM engine

> The inference layer. Loads model weights, runs forward passes, exposes an
> OpenAI-compatible HTTP API and a `/metrics` endpoint that Prometheus scrapes
> directly (no exporter needed).

## What this is

[vLLM](https://docs.vllm.ai/) is an LLM-serving runtime built around two ideas:

1. **PagedAttention** — manages the KV cache like a virtual-memory system, so
   you don't have to over-allocate per request. This is what makes batching
   on a small GPU practical.
2. **Continuous batching** — incoming requests are added to a running batch
   rather than waiting for the batch to finish. The metrics show this in
   action (`num_requests_running` vs `num_requests_waiting`).

It's the canonical "fast and friendly" inference engine. The harder, faster
alternative — Triton + TensorRT-LLM — is what Phase 2 swaps in.

## Why it's here

For Phase 1 we want one inference engine that's straightforward to bring up,
so all the observability wiring can be the focus. vLLM:

- Speaks the OpenAI API spec → LiteLLM routes to it as `openai/...`.
- Exposes Prometheus metrics natively at `/metrics`. No DCGM-like sidecar.
- Has stable AWQ kernels for Ada GPUs, so a 4060 (compute capability 8.9)
  can serve Qwen2.5-3B-AWQ comfortably.

## Configuration walkthrough

All flags live in [`docker-compose.yaml`](../docker-compose.yaml) under
`services.vllm-engine.command`. The reasoning:

| Flag | Value | Why |
| ---- | ----- | --- |
| `--model` | `Qwen/Qwen2.5-3B-Instruct-AWQ` | Smallest capable tool-calling model that comfortably fits 8 GB with batching headroom. ~2.2 GB weights. |
| `--quantization` | `awq_marlin` | AWQ-INT4 with the Marlin GEMM kernel — fastest on Ada. Falls back to `awq` if Marlin breaks; flag it in this README if you have to. |
| `--max-model-len` | `4096` | KV cache scales linearly with context length. 4096 is a sweet spot for our prompts and leaves room for batching. Raise only after measuring. |
| `--gpu-memory-utilization` | `0.85` | vLLM grabs this fraction of the GPU at startup and manages it as a slab. 0.85 leaves ~15% slack for the runtime allocator's quirks. |
| `--enable-prefix-caching` | (flag) | When two requests share a prompt prefix (e.g. the same system prompt), the prefill compute is reused. Visible in metrics as `vllm:gpu_prefix_cache_hit_rate`. |
| `--served-model-name` | `qwen-chat` | Stable alias decoupled from the HF model name. LiteLLM routes by this alias; weights can be swapped without changing the gateway config. |

Two non-flag pieces also matter:

- **HF cache volume** — mounted at `/root/.cache/huggingface`. First start
  downloads ~2 GB of weights; subsequent starts skip that.
- **`shm_size: 2gb`** — vLLM workers IPC over `/dev/shm`. Docker's default
  64 MB is not enough; the engine will crash with cryptic errors otherwise.

## The `/metrics` endpoint

vLLM exposes Prometheus-format metrics at `http://vllm-engine:8000/metrics`
(or `http://localhost:8000/metrics` from the host). The series we care about
in this sandbox:

| Metric | What it tells you |
| ------ | ----------------- |
| `vllm:num_requests_running` | Requests currently in the running batch. Tracks throughput. |
| `vllm:num_requests_waiting` | Queued requests. Non-zero = you're saturating. |
| `vllm:gpu_cache_usage_perc` | KV cache occupancy. Approaching 1.0 means you're memory-bound. |
| `vllm:gpu_prefix_cache_hit_rate` | Free wins. High during repeated similar prompts. |
| `vllm:time_to_first_token_seconds_bucket` | Prefill latency histogram. The "TTFT" SLO. |
| `vllm:time_per_output_token_seconds_bucket` | Decode latency histogram. The "ITL" / streaming smoothness SLO. |
| `vllm:prompt_tokens_total` | Cumulative input tokens. `rate()` gives input throughput. |
| `vllm:generation_tokens_total` | Cumulative output tokens. `rate()` gives the headline "tokens/sec" number. |

Discover the full list with:

```bash
curl -s http://localhost:8000/metrics | grep ^# HELP
```

## Smoke tests

After `docker compose up vllm-engine` (give it ~60-90s to load the model):

```bash
# Service is up and the model is loaded.
curl -s http://localhost:8000/v1/models | jq

# A completion. Use the served-model-name, not the HF path.
curl -s http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
        "model": "qwen-chat",
        "messages": [{"role": "user", "content": "Reply with one word: hello."}]
      }' | jq

# Metrics are there.
curl -s http://localhost:8000/metrics | head -30
```

## Where to look when it breaks

| Symptom | Likely cause | Where to look |
| ------- | ------------ | ------------- |
| Container exits immediately, "RuntimeError: No CUDA GPUs are available" | Missing `nvidia-container-toolkit` or runtime not registered | Run `scripts/preflight.sh` |
| OOM during model load | `--gpu-memory-utilization` too high or another process holds VRAM | `nvidia-smi` to see what's using the GPU |
| OOM during long requests | `--max-model-len` too high for current batch | Reduce `--max-model-len`, restart |
| "401 Unauthorized" downloading model | Gated model + missing HF token | Check `HF_TOKEN` in `.env` |
| Prefix cache hit rate stays 0 | Each request has a unique system prompt | Try the same prompt twice — should jump |
| `awq_marlin` errors at startup | Kernel incompat with chosen weights | Switch to `--quantization awq` (slower but compatible) |

## What's next

- Phase 1.1 wires DCGM exporter so vLLM's queue-depth metrics can be
  correlated with actual GPU SM occupancy and power.
- Phase 2 adds a second backend (Triton + TensorRT-LLM). The `litellm/`
  config gets a second entry; this file does not change.
