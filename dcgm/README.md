# DCGM exporter

> GPU telemetry over Prometheus. Reads the NVIDIA driver via the DCGM
> (Data Center GPU Manager) library and exposes a `/metrics` endpoint
> on `:9400`.

## What this is

The honest answer to "how busy is the GPU?". Replaces the misleading
`nvidia-smi --query-gpu=utilization.gpu` percentage (which only tells you
*whether* a kernel was running, not how saturated the SMs are).

The exporter ships an `nvidia-smi`-equivalent set of fields plus, on
data-centre cards, an honest profiling set (`PROF_*`) that measures real
SM activity, tensor-core pipe activity, and memory bandwidth utilisation.

## Why it's here

For Phase 1.1's correlation lesson: overlay GPU power and the LLM gateway's
p95 latency on the same time axis (see `grafana/dashboards/02-gpu-saturation.json`
panel 5). Power spikes during prefill, idles during decode — and you can
see the relationship without instrumenting vLLM itself.

## Configuration

[`../docker-compose.yaml`](../docker-compose.yaml) → `services.dcgm-exporter`.

| Setting | Purpose |
| ------- | ------- |
| `image: nvcr.io/nvidia/k8s/dcgm-exporter:3.3.9-3.6.1-ubuntu22.04` | Pinned. Bump on newer drivers (4.x line for 580+) if you see "driver version mismatch" in the logs. |
| `command: -f /etc/dcgm-exporter/dcp-metrics-included.csv` | Loads our trimmed field list instead of the default ~80 fields. |
| `cap_add: [SYS_ADMIN]` | Required by DCGM to read profiling counters on cards that have them (no-op on consumer GPUs, harmless to leave). |
| `deploy.resources.reservations.devices` | Same GPU as `vllm-engine`. Both containers share the device concurrently — no issue. The `capabilities: [gpu, utility]` part is what lets DCGM read driver-management counters in addition to compute. |
| Bind-mount `dcp-metrics-included.csv` | Read-only; edit + restart to change fields. |

### The custom metrics CSV

[`dcp-metrics-included.csv`](dcp-metrics-included.csv) — 8 active fields on a 4060.
On a data-centre GPU, four more `DCGM_FI_PROF_*` lines become live (they're
currently commented out because the DCP profiling module isn't loaded on
consumer Ada cards; the exporter logs `Not collecting DCP metrics:
This request is serviced by a module of DCGM that is not currently loaded`
and silently skips them).

## Fields we collect — and what they mean

| Field | Reads on this 4060? | What it physically measures |
| ----- | :------------------: | --------------------------- |
| `DCGM_FI_DEV_POWER_USAGE` | ✓ | Live power draw in watts. Idle ~10 W, full-tilt prefill ~45-55 W on this 4060. |
| `DCGM_FI_DEV_GPU_TEMP` | ✓ | Die temperature, °C. Throttling threshold is GPU-specific; check `nvidia-smi -q -d TEMPERATURE` for "GPU Slowdown Temp". |
| `DCGM_FI_DEV_MEMORY_TEMP` | reports 0 | Memory temp. GDDR6 in the 4060 doesn't expose this sensor; reads 0 always. Left in for parity with data-centre GPUs. |
| `DCGM_FI_DEV_SM_CLOCK` | ✓ | Streaming-multiprocessor clock, MHz. Drops sharply if thermal/power throttled. |
| `DCGM_FI_DEV_MEM_CLOCK` | ✓ | Memory clock, MHz. |
| `DCGM_FI_DEV_FB_USED` | ✓ | Frame-buffer (VRAM) used, MiB. vLLM's `--gpu-memory-utilization 0.85` grabs ~6800 MiB of the 8188 MiB available immediately. |
| `DCGM_FI_DEV_FB_FREE` | ✓ | VRAM free, MiB. USED + FREE ≈ 8188 (some overhead at the driver level). |
| `DCGM_FI_DEV_GPU_UTIL` | ✓ | The nvidia-smi-style "GPU-Util". Coarse. *Misleading for LLMs* — flips between 0% and 99% depending on whether any kernel is in flight, ignores how many SMs are actually doing useful work. Plot it alongside `vllm:num_requests_running` to see the disconnect. |

### What you don't see on the 4060

The `DCGM_FI_PROF_*` family is the honest saturation story:

| Field | Why it'd be useful | Why we don't see it |
| ----- | ----------------- | ------------------- |
| `PROF_SM_ACTIVE` | Fraction of cycles *any* warp resident on an SM. Always-on means real load. | DCP profiling module unsupported on Ada consumer cards. |
| `PROF_SM_OCCUPANCY` | Fraction of resident warps over max per SM. Tells you whether kernels are launching enough threads to saturate. | Same. |
| `PROF_PIPE_TENSOR_ACTIVE` | Tensor-core pipe utilisation. Direct measure of TFLOPS-style saturation. | Same. |
| `PROF_DRAM_ACTIVE` | HBM/GDDR bandwidth utilisation. The KV-cache bottleneck reads here. | Same. |

On a data-centre card (A100/H100/L40) you uncomment those four lines in
[`dcp-metrics-included.csv`](dcp-metrics-included.csv) and they appear in
`/metrics` automatically.

## Smoke tests

```bash
# Endpoint up
curl -s http://localhost:9400/metrics | head -3

# Sanity-check power tracks nvidia-smi
echo "From DCGM:    $(curl -s http://localhost:9400/metrics | grep ^DCGM_FI_DEV_POWER_USAGE | awk -F'} ' '{print $2}') W"
echo "From smi:     $(nvidia-smi --query-gpu=power.draw --format=csv,noheader)"

# Should sum to ~8188 MiB
curl -s http://localhost:9400/metrics | grep -E "^DCGM_FI_DEV_FB_(USED|FREE)" | awk -F'} ' '{ s += $2 } END { print s " MiB total (~8188 expected)" }'
```

## Where to look when it breaks

| Symptom | Likely cause | Fix |
| ------- | ------------ | --- |
| Container restart-looping, log says "DCGM init failed" | Driver version too new for this DCGM build | Bump the image tag (4.x line supports newer drivers) |
| `/metrics` returns 0 lines | Healthcheck happened before initialisation | Wait ~30 s; check `docker compose logs dcgm-exporter` for "Pipeline starting" |
| Warning "Skipping line N: metric not enabled" | DCP profiling unavailable (consumer GPU) | Expected — these are the `PROF_*` lines, see table above |
| `DCGM_FI_DEV_FB_USED` is always 0 | Container can't see the GPU | Run `scripts/preflight.sh`; check `docker info | grep -i nvidia` shows runtime registered |
| Numbers look wildly different from `nvidia-smi` | They shouldn't — open an issue if so; `nvidia-smi` and DCGM read the same NVML | — |

## What's next

- Phase 1.1 dashboards consume the fields here (`grafana/dashboards/02-gpu-saturation.json`).
- Phase 1.3 walkthrough `docs/04-trace-metric-correlation.md` builds on
  the prefill/decode burstiness pattern visible in `POWER_USAGE`.
- If you ever run this stack on a data-centre GPU, uncommenting the
  `PROF_*` lines is the single change that unlocks the better dashboard.
