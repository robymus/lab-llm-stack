# DCGM exporter — *Phase 1.1*

> Not yet implemented. Placeholder for link integrity.

Will cover:
- Why the NVIDIA DCGM exporter (vs. parsing `nvidia-smi` output)
- The `dcp-metrics-included.csv` we'll bind-mount to trim fields to what we use
- One-line explanation per `DCGM_FI_*` field we include (power, SM_ACTIVE,
  FB memory, mem clock, temp)
- Why `SM_ACTIVE` is more honest than `GPU-Util` from nvidia-smi

See [.plans/llm-sandbox-PLAN.md §5.6](../.plans/llm-sandbox-PLAN.md).
