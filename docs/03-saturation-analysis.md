# 03 · Saturation analysis

> Push real traffic at the stack and watch each dashboard panel earn its
> keep. Driven by [`scripts/load.sh`](../scripts/load.sh), which uses
> [`trunks`](https://github.com/tsenart/trunks) (Rust port of vegeta)
> with curated prompt sets so different profiles light up different
> panels.
>
> Read after [02 anatomy of a request](02-anatomy-of-a-request.md). The
> next doc, [04 trace ↔ metric correlation](04-trace-metric-correlation.md),
> zooms in on a single trace from the load you produce here.

---

## Install trunks

`scripts/load.sh` needs the `trunks` binary on PATH:

```bash
cargo install trunks
```

See <https://github.com/tsenart/trunks> for non-cargo install options.
The script confirms it's on PATH and exits with install hints if not.

---

## The ten profiles

| Profile | Rate × duration | Prompt set | Lights up |
| ------- | --------------- | ---------- | --------- |
| `smoke`         | 1/s × 10 s                            | short                       | sanity — every panel ticks once |
| `short`         | 5/s × 30 s                            | short                       | request rate, gateway p95 latency |
| `decode-heavy`  | 2/s × 30 s                            | ~400-token generations      | tokens/s, sustained GPU power |
| `prefill-heavy` | 2/s × 30 s                            | long input, brief output    | prompt tokens/s spike, KV cache used |
| `prefix-cache`  | 3/s × 60 s                            | shared system prompt        | `prefix_cache_hit_rate` climbs above 0 |
| `mixed`         | 3/s × 60 s                            | varied                      | realistic baseline |
| `saturation`    | **linear ramp** 2/s → ~20/s × 120 s   | varied                      | queue depth, KV cache, latency knee |
| `stress`        | flat 12/s × 180 s                     | decode-heavy                | sustained KV-cache pressure (hundreds of MiB) |
| `crush`         | flat 25/s × 60 s                      | varied                      | deliberately over capacity — what failure looks like |
| `marathon`      | flat 5/s × 180 s (timeout 120 s)      | max_tokens=2500             | fills the KV cache, triggers preemption |

## Defeating the prefix cache: `--variations`

A surprise on first runs: the dashboard's "prefix cache hit rate" panel
sits near 100% even on `mixed` traffic. That's because trunks loops over
the targets file — with ~20 base prompts and ~2400 requests at high rate,
each prompt is repeated ~120 times. Once vLLM has prefilled a prompt
once, every subsequent identical request is a cache hit. Not realistic.

The `--variations=N` flag fixes this by generating N salted versions of
each base prompt (e.g. `[r0042] What is 17 times 23?`). The salt sits in
the first ~5 tokens of the user content — enough to defeat vLLM's
16-token-block prefix cache, while still leaving the chat-template
wrapper (`<|im_start|>user\n`) cacheable.

Rule of thumb: pick `variations` so total targets ≥ total requests:

```bash
# 40 rps × 60 s = 2400 requests. mixed has ~24 base prompts.
# 2400 / 24 = need ~100 variations to never loop.
./scripts/load.sh mixed --rate=40/s --variations=100

# stress at 12/s × 180s = 2160 requests. decode-heavy has 8 prompts.
# 2160 / 8 = need ~270.
./scripts/load.sh stress --variations=300
```

Hit rate should drop from ~99% to the "real" floor (single-digit
percent — just the chat-template wrapper). That's what production traffic
with diverse user messages looks like.

Run any profile:

```bash
./scripts/load.sh smoke
./scripts/load.sh decode-heavy
./scripts/load.sh saturation --duration=2m       # override profile defaults
```

Each profile writes timestamped artefacts to `/tmp/load-<profile>-<ts>/`:
the raw vegeta binary log, the per-request CSV, and the JSON payload files.

---

## Where to watch while it runs

Two browser tabs:

1. **LLM Overview** — <http://localhost:3000/d/llm-overview/llm-overview>
   Set the time range to **Last 15 minutes** and the refresh interval to **5 s**.
2. **GPU Saturation** — <http://localhost:3000/d/gpu-saturation/gpu-saturation>
   Same time range / refresh.

You can also have a terminal with:

```bash
watch -n2 'docker compose ps --format "{{.Service}}\t{{.Status}}"'
```

…just to confirm nothing OOM'd while you weren't looking.

---

## Profile walkthroughs

### 1 · `smoke` — does anything work?

```bash
./scripts/load.sh smoke
```

Ten requests over ten seconds with short prompts. vegeta should report
**100% 200s**, p95 well under 2 s. If anything fails here, stop and
debug — none of the other profiles will be useful.

What to look for on dashboards: a small "blip" on every panel, big enough
to confirm the metrics path. The KV cache panel barely registers.

### 2 · `short` — gateway throughput

```bash
./scripts/load.sh short
```

150 requests in 30 s, short prompts, output capped at 60 tokens. The
gateway is the question here: can it keep up at 5 rps?

**Expect on LLM Overview:**
- *Request rate* — flat at ~5 rps for the duration.
- *p50/p95 latency* — p50 around a second, p95 maybe two; gap is small.
- *Tokens / second* — generation hovers around 300 tok/s.
- *KV cache used* — barely moves (each request finishes too quickly).

**Expect on GPU Saturation:**
- *Power* — sustained ~25-35 W (idle is ~10 W).
- *Temperature* — ticks up a couple of °C.

### 3 · `decode-heavy` — sustained generation

```bash
./scripts/load.sh decode-heavy
```

2 rps × 30 s, ~400-token outputs each. Each request takes 4-6 s, so 8-12
are simultaneously in flight.

**Expect:**
- *Tokens / second* — high (the bottleneck shifts to decode).
- *p95 latency* — much higher than `short` (more tokens × per-token time).
- *Queue depth* — `running` climbs into the 5-10 range; `waiting`
  spikes briefly at start, then settles.
- *GPU power* — high and steady. This is the "decode" signature: it
  doesn't whip up and down like prefill does.

### 4 · `prefill-heavy` — input-bound

```bash
./scripts/load.sh prefill-heavy
```

2 rps × 30 s, long input (~250-1000 tokens of pre-baked text), short output.

**Expect:**
- *Tokens / second* — the "prompt" line jumps (input tokens/s); "generation"
  stays low.
- *KV cache used (bytes)* — visible bumps as the cache fills with input
  tokens. Bigger and more frequent than `decode-heavy`'s.
- *p95 latency* — dominated by TTFT. Higher than `short` even though
  output is similar length.
- *GPU power* — bursty: spikes during prefill, drops during the tiny
  decode, repeat.

### 5 · `prefix-cache` — free wins

```bash
./scripts/load.sh prefix-cache
```

3 rps × 60 s. All requests share a long system prompt; the user message
varies. The same prefix → same KV-cache blocks. With `--enable-prefix-caching`
on, vLLM short-circuits the prefill for that prefix on every request after
the first.

**Expect:**
- *Prefix cache hit rate* — climbs from 0 toward a high steady state (the
  exact number depends on how many requests have run, since hit-rate is
  cumulative-ish).
- *Tokens / second* — the prompt-tokens line drops despite the prompts
  *being* long, because most of those tokens don't actually need prefilling.
- *Power* — lower than `prefill-heavy` for the same nominal input size.

This is the dashboard panel that proves the cache is doing work.

### 6 · `mixed` — realistic

```bash
./scripts/load.sh mixed
```

A combination of all the above prompt sets at 3 rps. Closest to "what real
traffic looks like." No single panel pegs; many of them are simultaneously
non-zero.

Useful when you want a realistic-ish background while testing something
else (alert configs, new dashboards, etc.).

### 7 · `saturation` — find the knee

```bash
./scripts/load.sh saturation
```

A **continuous linear ramp** from 2/s up to ~20/s over 120 s (`trunks`
`--pace linear --slope 0.15`). One run, one report; the rate increases
smoothly rather than stepping. This makes the *saturation point* visible
as a knee on the latency / queue-depth curves rather than as a step.

**Expect over the 120 s:**
- *Request rate* — a clean straight line climbing from 2 to ~20.
- *p95 latency* — flat at first, then bends sharply upward at the
  saturation point (typically 5-8 rps on Qwen-3B on a 4060).
- *Queue depth* — `waiting` is at 0 in the low-rate region, then climbs
  steadily once the engine can't keep up.
- *KV cache used (bytes)* — `max 1m` line climbs into the hundreds of MiB
  by the end of the ramp.
- *GPU power* — pegs early (4060 is power-capped at TGP) and stays there.

The *knee* on the latency curve is what to identify — that's your
"capacity number" for this model on this GPU at these prompt mixes.

### 8 · `stress` — sustained KV-cache pressure

```bash
./scripts/load.sh stress
```

Flat **12/s × 3 minutes**, decode-heavy prompts only (~400-token
generations). Each request stays in the engine 6-10 s; at steady state
the engine holds 70-100 concurrent requests in its batch.

This is the profile that actually fills the KV cache. The dashboards in
all the other profiles only nibble at it because requests finish too fast.

**Expect:**
- *KV cache used (bytes)* — climbs steadily, settles in the **hundreds
  of MiB** range. The `max 1m` dashed line tracks the live value with a
  lag, then plateaus.
- *Queue depth* — `running` plateaus high (often 30-50+); `waiting` rides
  in the single digits to double digits.
- *Tokens / second* — the headline number is *generation* tokens/s, much
  higher than other profiles because there are many decoders running in
  parallel.
- *GPU power* — pegged at TGP for the entire duration.
- *Latency* — much higher than baseline, but *steady* — that's the
  signature of a saturated-but-not-overloaded system.

### 9 · `crush` — deliberately over capacity

```bash
./scripts/load.sh crush
```

Flat **25/s × 1 minute**, varied prompts. This is well above the
engine's sustained capacity on a 4060. The point isn't to find a knee;
it's to *see what failure looks like* before something real fails on you.

**Expect:**
- *Success ratio* in the trunks report **below 100%** — some requests
  hit the 30 s timeout or get 5xx'd by the gateway.
- *Queue depth `waiting`* pegged high (40+ stuck behind the running batch).
- *Latency p99* — in the seconds-to-tens-of-seconds range.
- *Latency histogram* — long tail; bucket `[10s, 30s]` non-empty.

If you've never seen what a saturated stack looks like on the dashboards,
run this once. It's the negative example that makes the other profiles'
"healthy" shapes legible.

> ⚠ **Note:** vLLM with continuous batching is *really* good at absorbing
> bursts. On a 4060 with mixed prompts, even 40+ rps often produces 100%
> success — the latency tail widens but nothing fails. To actually break
> things, use `marathon` (next) or `stress --rate=40/s --variations=300`.

### 10 · `marathon` — fill the cache, force preemption

```bash
./scripts/load.sh marathon
```

Flat **5/s × 3 minutes**, with **max_tokens=2500** per request. Each
request takes 30-60+ seconds of pure decode; per-request timeout is
bumped to 120 s for this profile.

The math: ~150 concurrent requests at steady state × ~90 MB KV-cache
per request ≈ **13 GB of cache demand on a 3.19 GB slab.** vLLM responds
by preempting in-flight requests (saving + restoring their state),
which is exactly the metric you'll see climb.

**Expect:**
- *KV cache used (bytes)* — pegs near the slab capacity (~3 GB).
- `vllm:num_preemptions_total` (PromQL) — climbs steadily during the run.
  Plot this directly in Grafana Explore: it's the rate at which vLLM is
  swapping requests out and back in to fit the working set.
- *Tokens/sec* — high, but with visible *plateaus* during preemption
  cycles.
- *Latency* — wide distribution; some requests finish in 30 s, some in
  100 s+.

This is the profile that actually pushes the engine's capacity-planning
subsystem, not just its compute. Run it once to see what preemption
looks like on the dashboards.

---

## Reading a trunks report

After each attack, the script prints two reports:

### Text summary

```
Requests      [total, rate, throughput]         150, 5.01, 4.93
Duration      [total, attack, wait]             30.42s, 29.93s, 487ms
Latencies     [min, mean, 50, 90, 95, 99, max]  236ms, 982ms, 854ms, 1.62s, 2.04s, 3.14s, 3.61s
Bytes In      [total, mean]                     ...
Bytes Out     [total, mean]                     ...
Success       [ratio]                           100.00%
Status Codes  [code:count]                      200:150
Error Set:
```

Three things to check first:
- `Success` ratio — should be 100%. Anything else means look at the
  *Error Set* and at `docker compose logs litellm`.
- `Latencies / 95` — the p95 number is the same one Prometheus is showing
  on the dashboard. They should agree within a tenth of a second.
- `Status Codes` — splits by HTTP code. 5xx counts pair with red points
  in trunks' plot.

### Histogram bucket view

```
Bucket           #    %       Histogram
[0s,     250ms]  3    2.00%   ##
[250ms,  500ms]  18   12.00%  #########
[500ms,  1s]     58   38.66%  ##############################
[1s,     2s]     54   36.00%  ############################
[2s,     5s]     17   11.33%
[5s,     10s]    0    0.00%
[10s,    30s]    0    0.00%
```

Tells you the *shape* of the distribution at a glance. Bimodal? Long tail?
Compare two runs without squinting at means.

### Plot and CSV

Each run dumps `<profile>.bin` (trunks's binary record format) and
`<profile>.csv`. Plot the bin with the built-in plotter:

```bash
trunks plot /tmp/load-saturation-*/saturation.bin --output=/tmp/plot.html
xdg-open /tmp/plot.html
```

…or open the CSV in your spreadsheet tool of choice. Columns include
timestamp, latency, code, body bytes — enough to slice however you want.

---

## "How fast is the LLM?" — what the numbers actually mean

Some quick definitions, anchored to what your dashboards show:

- **rps**: requests per second arriving at LiteLLM. Reported by vegeta and
  by `llm:request_rate`.
- **tokens/s (output)**: total output tokens generated per second across
  *all in-flight requests*. Reported by `llm:tokens_per_second`. A single
  request will hit ~30-50 tok/s on Qwen-3B on a 4060; the total can be
  much higher because vLLM batches.
- **TTFT (time-to-first-token)**: the latency until the first output token
  arrives. Heavily input-length-dependent. Not exposed by vLLM in v0.6.6's
  `/metrics`; closest analogue is the gap between *prompt tokens/s spiking*
  and *generation tokens/s starting to climb* on the timeseries panels.
- **ITL (inter-token latency)**: the average gap between successive output
  tokens during decode. ~20-30 ms steady state at low load on Qwen-3B.
  Increases as the running batch grows.

If the batch keeps growing past a healthy size, the engine is
**throughput-saturated** — more rps in = same or fewer tokens/s out, with
latency rising for everyone.

---

## What's next

[04 trace ↔ metric correlation](04-trace-metric-correlation.md) takes
one specific trace produced by the `mixed` or `saturation` profile and
walks through how to find the corresponding spikes on the dashboards.
That's the lesson the dashboards were designed for.
