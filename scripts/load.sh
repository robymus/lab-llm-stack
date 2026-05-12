#!/usr/bin/env bash
# =============================================================================
#  load.sh — trunks-driven load tester for the LLM sandbox
# -----------------------------------------------------------------------------
#  Drives traffic through the LiteLLM gateway with curated prompt sets so
#  each profile lights up a *different* set of dashboard panels:
#
#    smoke         sanity check — 10s @ 1/s
#    short         high-rate short prompts        → request rate, gateway p95
#    decode-heavy  ~400-token generations         → sustained tokens/s, GPU power
#    prefill-heavy long input, short output       → TTFT, prompt tokens/s spikes
#    prefix-cache  shared system prompt           → gpu_prefix_cache_hit_rate
#    mixed         varied prompts at steady rate  → realistic
#    saturation    linear ramp 2/s → ~12/s        → queue depth, KV cache spikes
#
#  Each profile prints a text report (text + histogram) at the end, and
#  every run dumps the per-request binary + CSV so you can post-process
#  with `trunks plot`.
#
#  Tool: https://github.com/tsenart/trunks  (Rust port of vegeta).
#  Install:  cargo install trunks
#
#  Use `load.sh <profile> --help` for full options.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
#  Console colours (TTY only)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'
    BOLD=$'\033[1m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; YELLOW=""; BOLD=""; CYAN=""; RESET=""
fi

# ---------------------------------------------------------------------------
#  Help text + usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
${BOLD}load.sh${RESET} — trunks load tester for the LLM sandbox

${BOLD}Usage:${RESET}
  load.sh ${CYAN}<profile>${RESET} [options]
  load.sh ${CYAN}--list${RESET}

${BOLD}Profiles:${RESET}
  ${CYAN}smoke${RESET}         10s @ 1/s, short prompts            (sanity check)
  ${CYAN}short${RESET}         30s @ 5/s, short prompts            (gateway throughput)
  ${CYAN}decode-heavy${RESET}  30s @ 2/s, ~400-token generations   (sustained decode)
  ${CYAN}prefill-heavy${RESET} 30s @ 2/s, long input prompts       (TTFT, prefill cost)
  ${CYAN}prefix-cache${RESET}  60s @ 3/s, shared system prompt     (watch hit_rate climb)
  ${CYAN}mixed${RESET}         60s @ 3/s, varied prompts           (realistic)
  ${CYAN}saturation${RESET}    120s linear ramp 2/s → ~20/s        (find the latency knee)
  ${CYAN}stress${RESET}        180s @ 12/s, decode-heavy           (sustained KV-cache pressure)
  ${CYAN}crush${RESET}         60s @ 25/s, mixed                   (deliberately over capacity)
  ${CYAN}marathon${RESET}      180s @ 5/s, max_tokens=2500         (long generations → fill KV cache)

${BOLD}Options:${RESET}
  --rate=N         Override the profile's starting rate (e.g. --rate=4, --rate=4/s)
  --duration=Ts    Override the profile's duration (e.g. 30s, 1m)
  --variations=N   Generate N salted variations per base prompt (default: 1).
                   Defeats vLLM's prefix cache for realistic hit rates.
                   Rule of thumb: set to (rate × duration) / number_of_prompts
                   to keep total targets ≥ total requests.
  --workers=N      Initial trunks worker count (default: 128). Bigger = more
                   concurrent in-flight HTTP connections.
  --max-workers=N  Cap on workers trunks may spawn (default: 4096). The
                   default 0 in trunks means "don't grow beyond initial" —
                   we override to actually deliver the requested rate.
  --out=DIR        Write detailed results to DIR (default: /tmp/load-<profile>-<ts>)
  --quiet          Suppress the per-second progress dots
  -h, --help       This help

${BOLD}Environment:${RESET}
  LITELLM_URL          default: http://localhost:4000
  LITELLM_MASTER_KEY   loaded from .env if present

${BOLD}Example:${RESET}
  $ load.sh decode-heavy
  $ load.sh saturation --duration=2m
  $ load.sh mixed --rate=8/s --out=./run-1
EOF
}

# ---------------------------------------------------------------------------
#  Pre-flight: parse args, check trunks, load env
# ---------------------------------------------------------------------------

PROFILE=""
RATE_OVERRIDE=""
DURATION_OVERRIDE=""
OUT_DIR=""
QUIET=0
VARIATIONS=1
WORKERS=128
MAX_WORKERS=4096

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "--list" ]; then
    usage; exit 0
fi
if [ -z "${1:-}" ]; then
    echo "${RED}missing profile${RESET}"; usage; exit 2
fi

PROFILE="$1"; shift
while [ $# -gt 0 ]; do
    case "$1" in
        --rate=*)         RATE_OVERRIDE="${1#*=}" ;;
        --duration=*)     DURATION_OVERRIDE="${1#*=}" ;;
        --variations=*)   VARIATIONS="${1#*=}" ;;
        --workers=*)      WORKERS="${1#*=}" ;;
        --max-workers=*)  MAX_WORKERS="${1#*=}" ;;
        --out=*)          OUT_DIR="${1#*=}" ;;
        --quiet)          QUIET=1 ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "${RED}unknown flag: $1${RESET}"; usage; exit 2 ;;
    esac
    shift
done

if ! [[ "$VARIATIONS" =~ ^[0-9]+$ ]] || [ "$VARIATIONS" -lt 1 ]; then
    echo "${RED}--variations must be a positive integer, got: $VARIATIONS${RESET}"; exit 2
fi

if ! command -v trunks >/dev/null 2>&1; then
    echo "${RED}trunks not found on PATH${RESET}"
    echo
    echo "Install:  cargo install trunks"
    echo "See:      https://github.com/tsenart/trunks"
    exit 1
fi

# Load .env (only KEY=VAL lines; ignore comments and blank lines).
if [ -f "$REPO_DIR/.env" ]; then
    while IFS= read -r line; do
        if [[ "$line" =~ ^[A-Z_][A-Z0-9_]*= ]]; then
            export "${line?}"
        fi
    done < "$REPO_DIR/.env"
fi

LITELLM_URL="${LITELLM_URL:-http://localhost:4000}"
if [ -z "${LITELLM_MASTER_KEY:-}" ]; then
    echo "${RED}LITELLM_MASTER_KEY is not set${RESET} (check .env or env var)"; exit 1
fi

# Output directory for raw results + CSV.
if [ -z "$OUT_DIR" ]; then
    OUT_DIR="/tmp/load-${PROFILE}-$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------------------
#  Prompt sets
# -----------------------------------------------------------------------------
#  Each entry: "MAX_TOKENS|PROMPT_TEXT"  (MAX first so | inside prompts is OK)
#
#  IMPORTANT: prompts must not contain double-quotes or backslashes — we
#  embed them into JSON with printf. If you need richer text, switch to
#  pre-baked payload files (one .json per prompt).
# ---------------------------------------------------------------------------

# Short, simple prompts — Qwen-3B answers in well under a second each.
SHORT_PROMPTS=(
  "60|What is 17 times 23?"
  "60|Translate the phrase hello world to French."
  "60|What is the capital of Australia?"
  "60|Name three primary colours."
  "60|Convert 100 Fahrenheit to Celsius. Show the formula."
  "60|Spell observability backwards."
  "60|What is the chemical symbol for gold and silver?"
  "60|Round 3.14159 to two decimals."
  "60|How many sides does a hexagon have?"
  "60|What year did the first iPhone launch?"
)

# Longer generations — wide variety of styles so the dashboards aren't
# dominated by a single prompt's quirks.
DECODE_HEAVY_PROMPTS=(
  "400|Write a fictional incident report about a Kubernetes pod that crash-looped because of an OOM. Include timeline, suspected cause, mitigation, and a one-sentence lesson."
  "400|Describe the architecture of a typical microservice application: load balancer, API gateway, services, message bus, database. One short paragraph per layer."
  "400|Explain how OAuth 2.0 works to a junior developer. Cover the authorization-code flow, access tokens, and refresh tokens with a concrete example."
  "400|Walk through the lifecycle of a single HTTP request landing on a web server, from TCP handshake through TLS, routing, handler invocation, and response."
  "400|Compare four cache eviction policies (LRU, LFU, FIFO, random) with one realistic use case per policy and a trade-off summary."
  "400|Write a short story about a sysadmin in the year 2099 doing on-call rotation for a fusion reactor. Two paragraphs maximum."
  "400|Outline a beginner-friendly Saturday-morning plan for learning Rust, covering setup, first project ideas, and pitfalls."
  "400|Compare relational vs document databases. Cover write performance, schema flexibility, query expressiveness, and operational cost."
)

# Marathon prompts — explicitly ask for very long outputs to force the
# engine to spend tens of seconds per request and fill the KV cache.
# max_tokens 2500 is well under --max-model-len 4096 even with a couple
# hundred input tokens; Qwen will likely EOS earlier on some, hit the
# cap on others. Both are interesting.
LONG_GEN_PROMPTS=(
  "2500|Write a complete novella in 12 short scenes about a fusion-power technician on Mars who discovers a sentient anomaly inside the reactor. Each scene should have setting, dialogue, and a small reveal. Aim for narrative momentum."
  "2500|Produce a thorough tutorial on Rust's ownership and borrowing system. Start with motivation, then introduce move semantics, then references and lifetimes, then trait objects, then async — each section with multiple code examples and a 'common pitfall' callout. Target an intermediate programmer."
  "2500|Outline the entire history of distributed-systems research from 1965 to today, with section headings per decade. For each decade, name the key papers, the systems that came out of them, the prevailing failure modes, and the dominant academic debates. Cite specific names and years."
  "2500|Write a thorough postmortem of a fictional multi-region outage: cause analysis, timeline minute-by-minute, customer-facing impact, internal response, fixes shipped, lessons learned, action items. Take the format seriously — this is what a senior SRE would write."
  "2500|Describe in detail how a modern multicore CPU executes a single C function from source to retirement of the last instruction. Cover the compiler frontend, optimizer passes, ISA selection, branch prediction, out-of-order execution, cache hierarchy, store buffer, memory ordering, retirement. One paragraph per stage, with concrete examples."
  "2500|Write a 4000-word essay on the philosophical implications of large language models for the concept of authorship. Engage with classical theories (Barthes, Foucault), modern legal frameworks (copyright, fair use), and at least two concrete recent cases. Pick a side and defend it."
)

# Long-input prompts — they fill TTFT histograms cleanly. We pad the
# prompt with a big chunk of fixed text so prefill dominates.
# Each prompt asks for a *short* answer to keep decode time small.
_LONG_TEXT_A='The Roman Empire was the post-Republican period of ancient Rome. As a polity, it included large territorial holdings around the Mediterranean Sea in Europe, North Africa, and Western Asia, ruled by emperors. From the accession of Caesar Augustus in 27 BC to the military anarchy of the third century, it was a Principate with Italia as the metropole of its provinces and the city of Rome as its sole capital. The Empire was later ruled by multiple emperors who shared control over the Western Roman Empire and the Eastern Roman Empire. The city of Rome remained the nominal capital of both parts until AD 476, when the imperial insignia were sent to Constantinople following the capture of the Western capital of Ravenna by the Germanic barbarians. The adoption of Christianity as the state church of the Roman Empire in AD 380 and the fall of the Western Roman Empire to Germanic kings conventionally marks the end of classical antiquity and the beginning of the Middle Ages.'
_LONG_TEXT_B='In computer science, an algorithm is a finite sequence of mathematically rigorous instructions, typically used to solve a class of specific problems or to perform a computation. Algorithms are used as specifications for performing calculations and data processing. More advanced algorithms can use conditionals to divert the code execution through various routes (referred to as automated decision-making) and deduce valid inferences (referred to as automated reasoning), achieving automation eventually. Using human characteristics as descriptors of machines in metaphorical ways was already practiced by Alan Turing with terms such as memory, search and stimulus.'

PREFILL_HEAVY_PROMPTS=(
  "60|Summarize this in one sentence: ${_LONG_TEXT_A}"
  "60|Summarize this in one sentence: ${_LONG_TEXT_B}"
  "60|Pick three key dates from this text and list them: ${_LONG_TEXT_A}"
  "60|Identify the main topic of this text in one phrase: ${_LONG_TEXT_B}"
  "60|Translate the first sentence of this text to French: ${_LONG_TEXT_A}"
  "60|Quote the longest sentence in this text verbatim: ${_LONG_TEXT_B}"
)

# Prefix-cache exerciser. All prompts share the SAME system prompt, which
# is the part that gets cached. We vary the user message so generation
# differs but the long prefix is re-used.
PREFIX_SYSTEM='You are a strict grammar bot in an English language tutoring service. You will receive a single sentence from a learner and must reply with the corrected version only — no explanation, no preamble, no quotation marks. Preserve the meaning. If the sentence is already correct, repeat it verbatim. Examples of corrections you should make: subject-verb agreement, missing articles, tense consistency, common preposition mistakes. Respond on a single line.'
PREFIX_USERS=(
  "I has a apple."
  "He go to school every day."
  "She are very nice."
  "We was at the park yesterday."
  "Yesterday I have eat pizza."
  "The dog barks at man."
  "I am going to the supermarket on next Monday."
  "Can you helps me with the homework?"
  "She dont like coffee."
  "They has been working since 10."
  "I prefer apples than oranges."
  "He explained me the rules."
)

# 64 short, common English words used to build per-variation salt tags
# (e.g. "(tag alpha-bravo)" prepended to the user message). Natural-looking
# tags defeat vLLM's 16-token-block prefix cache without confusing the
# model the way "[r0042]"-style alphanumeric noise sometimes does
# (small models occasionally interpret it as a malformed reference code
# and short-circuit with a clarifying response). 64² = 4096 unique pairs,
# enough for typical --variations values.
SALT_WORDS=(
  alpha bravo charlie delta echo foxtrot golf hotel india juliet
  kilo lima mike november oscar papa quebec romeo sierra tango
  uniform victor whiskey xray yankee zulu
  apple banana cherry grape lemon mango peach plum berry melon
  river forest desert mountain island canyon valley meadow ocean cloud
  cat dog wolf bear fox eagle owl hawk shark whale tiger lion
)

# Mixed = short + decode + a couple of prefill. Realistic-ish workload.
build_mixed() {
    MIXED_PROMPTS=()
    MIXED_PROMPTS+=( "${SHORT_PROMPTS[@]}" )
    MIXED_PROMPTS+=( "${DECODE_HEAVY_PROMPTS[@]}" )
    MIXED_PROMPTS+=( "${PREFILL_HEAVY_PROMPTS[@]:0:2}" )
}

# ---------------------------------------------------------------------------
#  JSON payload helpers
# ---------------------------------------------------------------------------

# Write a JSON payload for a chat completion request.
#   $1 = file path, $2 = max_tokens, $3 = user message, $4 = optional system
write_payload() {
    local file="$1" max="$2" user="$3" sys="${4:-}"
    if [ -n "$sys" ]; then
        printf '{"model":"qwen-chat","messages":[{"role":"system","content":"%s"},{"role":"user","content":"%s"}],"max_tokens":%s,"temperature":0.3}\n' \
            "$sys" "$user" "$max" > "$file"
    else
        printf '{"model":"qwen-chat","messages":[{"role":"user","content":"%s"}],"max_tokens":%s,"temperature":0.3}\n' \
            "$user" "$max" > "$file"
    fi
}

# Build a trunks targets file from a prompt array.
#   $1 = path to targets file
#   $2 = system prompt (empty string = no system message)
#   $3... = array of "MAX|PROMPT" strings
#
# If $VARIATIONS > 1, each base prompt is expanded into N variations with
# a unique short prefix like "(tag alpha-bravo) ..." prepended to the
# user message. The prefix lands in the first ~5 tokens of the user
# content, which is enough to defeat vLLM's 16-token-block prefix cache
# while still leaving the chat-template wrapper (`<|im_start|>user\n`)
# cacheable. Net effect: prefix cache hit rate drops from ~99% (looped
# targets) toward the "real-world floor" you'd see with diverse user
# traffic.
build_targets_file() {
    local targets_file="$1"; shift
    local system_msg="$1"; shift
    local payload_dir
    payload_dir="$OUT_DIR/payloads"
    mkdir -p "$payload_dir"
    : > "$targets_file"

    local nwords=${#SALT_WORDS[@]}
    local i=0
    local salt=0
    for entry in "$@"; do
        local max="${entry%%|*}"
        local prompt="${entry#*|}"
        local v
        for ((v=0; v<VARIATIONS; v++)); do
            local final_prompt="$prompt"
            if [ "$VARIATIONS" -gt 1 ]; then
                # Two natural English words from SALT_WORDS, picked
                # deterministically from $salt so the same --variations run
                # produces the same tags. Different per variation → defeats
                # the 16-token-block prefix cache. Natural English → the
                # model treats it as a meta-tag and proceeds normally rather
                # than getting confused by random hex.
                local w1=${SALT_WORDS[$((salt % nwords))]}
                local w2=${SALT_WORDS[$(((salt / nwords) % nwords))]}
                final_prompt="(tag $w1-$w2) $prompt"
            fi
            local pf="$payload_dir/p$(printf '%05d' $i).json"
            write_payload "$pf" "$max" "$final_prompt" "$system_msg"
            cat >> "$targets_file" <<TARGET
POST $LITELLM_URL/v1/chat/completions
Content-Type: application/json
Authorization: Bearer $LITELLM_MASTER_KEY
@$pf

TARGET
            i=$((i+1))
            salt=$((salt+1))
        done
    done
    echo "${CYAN}built $i targets ($VARIATIONS variation(s) × $# base prompts) → $targets_file${RESET}"
}

# ---------------------------------------------------------------------------
#  trunks attack wrapper
# ---------------------------------------------------------------------------

# Run one attack stage.
#   $1 = rate (e.g. "5/1s" or "2")
#   $2 = duration (e.g. "30s")
#   $3 = targets file
#   $4 = tag/name
#   $5 = pace ("constant" or "linear")
#   $6 = slope (only if pace=linear; hits/s² increase per second)
#   $7 = per-request timeout (default: 30s — trunks's default)
run_attack() {
    local rate="$1" duration="$2" targets_file="$3" tag="${4:-attack}" pace="${5:-constant}" slope="${6:-0}" timeout="${7:-30s}"
    rate="${RATE_OVERRIDE:-$rate}"
    duration="${DURATION_OVERRIDE:-$duration}"

    local bin="$OUT_DIR/${tag}.bin"
    echo
    if [ "$pace" = "linear" ]; then
        echo "${BOLD}▶ attacking${RESET}  pace=${YELLOW}linear${RESET}  start=${GREEN}${rate}${RESET}  slope=${GREEN}${slope}/s²${RESET}  duration=${GREEN}${duration}${RESET}  timeout=${GREEN}${timeout}${RESET}  tag=${tag}"
    else
        echo "${BOLD}▶ attacking${RESET}  rate=${GREEN}${rate}${RESET}  duration=${GREEN}${duration}${RESET}  timeout=${GREEN}${timeout}${RESET}  tag=${tag}"
    fi

    # trunks emits JSON-encoded result records by default. Save the binary
    # form for downstream report / plot / encode passes.
    #
    # --workers / --max-workers default to 16 / 0 in trunks, where 0 means
    # "don't grow beyond initial". At marathon-style long latencies, 16
    # workers caps achievable rate around ~16-17 rps regardless of what
    # --rate says — we observed 3147 / 180s ≈ 17.5 rps with marathon@50/s.
    # Crank initial workers and uncap the max so the requested rate is
    # actually delivered. 4096 covers 60-second requests at 60+ rps.
    local trunks_args=(
        attack
        --name "$tag"
        --targets "$targets_file"
        --format http
        --rate "$rate"
        --duration "$duration"
        --timeout "$timeout"
        --pace "$pace"
        --workers "${WORKERS:-128}"
        --max-workers "${MAX_WORKERS:-4096}"
        --output "$bin"
    )
    if [ "$pace" = "linear" ]; then
        trunks_args+=(--slope "$slope")
    fi

    if [ "$QUIET" -eq 1 ]; then
        trunks "${trunks_args[@]}"
    else
        trunks "${trunks_args[@]}" &
        local pid=$!
        while kill -0 "$pid" 2>/dev/null; do printf '.'; sleep 1; done
        wait "$pid"; echo
    fi

    echo
    echo "${BOLD}── trunks report ($tag) ───────────────────────────────${RESET}"
    trunks report --report-type=text "$bin"
    echo
    echo "${BOLD}── histogram ───────────────────────────────${RESET}"
    trunks report --report-type=hist --buckets='[0,250ms,500ms,1s,2s,5s,10s,30s]' "$bin"
    trunks encode --to=csv --output="$OUT_DIR/${tag}.csv" "$bin"
}

# ---------------------------------------------------------------------------
#  Profiles
# ---------------------------------------------------------------------------

profile_smoke() {
    local t="$OUT_DIR/targets.txt"
    build_targets_file "$t" "" "${SHORT_PROMPTS[@]}"
    run_attack "1/1s" 10s "$t" smoke
}

profile_short() {
    local t="$OUT_DIR/targets.txt"
    build_targets_file "$t" "" "${SHORT_PROMPTS[@]}"
    run_attack "5/1s" 30s "$t" short
}

profile_decode_heavy() {
    local t="$OUT_DIR/targets.txt"
    build_targets_file "$t" "" "${DECODE_HEAVY_PROMPTS[@]}"
    run_attack "2/1s" 30s "$t" decode
}

profile_prefill_heavy() {
    local t="$OUT_DIR/targets.txt"
    build_targets_file "$t" "" "${PREFILL_HEAVY_PROMPTS[@]}"
    run_attack "2/1s" 30s "$t" prefill
}

profile_prefix_cache() {
    local prompts=()
    for u in "${PREFIX_USERS[@]}"; do prompts+=("60|$u"); done
    local t="$OUT_DIR/targets.txt"
    build_targets_file "$t" "$PREFIX_SYSTEM" "${prompts[@]}"
    run_attack "3/1s" 60s "$t" prefix
}

profile_mixed() {
    build_mixed
    local t="$OUT_DIR/targets.txt"
    build_targets_file "$t" "" "${MIXED_PROMPTS[@]}"
    run_attack "3/1s" 60s "$t" mixed
}

profile_saturation() {
    # Linear pacer: start at 2/s, slope 0.15 hits/s² for 120s.
    # Final rate at t=120s: 2 + 120 * 0.15 ≈ 20 rps.
    # This is where trunks shines vs vegeta's three-stage hack — the
    # rate is continuously increasing, so the saturation point appears
    # as a smooth knee on the latency curve, not a step. By the time we
    # reach the top of the ramp we're solidly past the engine's capacity
    # on a 4060, so the back half exercises queueing and latency tail.
    build_mixed
    local t="$OUT_DIR/targets.txt"
    build_targets_file "$t" "" "${MIXED_PROMPTS[@]}"
    run_attack "2/1s" 120s "$t" saturation linear 0.15
}

profile_stress() {
    # Sustained pressure — flat 12 rps × 3 min with decode-heavy prompts
    # (each ~6-10s in the engine). At steady state the engine has
    # ~70-100 concurrent requests holding KV blocks; KV-cache usage rises
    # into the hundreds of MiB and GPU power pegs for the duration.
    # Power is power-capped on this GPU — the visible change is in the
    # KV cache (bytes) panel and the queue-depth panel, not on power.
    local t="$OUT_DIR/targets.txt"
    build_targets_file "$t" "" "${DECODE_HEAVY_PROMPTS[@]}"
    run_attack "12/1s" 180s "$t" stress
}

profile_crush() {
    # Deliberately above capacity — 25 rps flat for a minute. Designed to
    # show what failure looks like: latency p99 in the timeout zone,
    # success ratio below 100%, queue-depth pegged. If you want a clean
    # demo of "we cannot serve this rate," this is it.
    build_mixed
    local t="$OUT_DIR/targets.txt"
    build_targets_file "$t" "" "${MIXED_PROMPTS[@]}"
    run_attack "25/1s" 60s "$t" crush
}

profile_marathon() {
    # Long generations (~2500 tokens output cap each). At 5 rps with each
    # request taking 30-60 s of decode time, ~150-300 concurrent requests
    # sit in the engine at steady state. With ~2500-token contexts each
    # holding ~90 MB of KV slab, total demand is far more than our 3.19 GB
    # slab — vLLM will preempt aggressively and `num_preemptions_total`
    # starts climbing. Use this profile to push the cache subsystem.
    #
    # We bump the per-request timeout to 120 s because long generations
    # genuinely take that long; the 30 s default would mark many as failed
    # even though the work was on track.
    local t="$OUT_DIR/targets.txt"
    build_targets_file "$t" "" "${LONG_GEN_PROMPTS[@]}"
    run_attack "5/1s" 180s "$t" marathon constant 0 120s
}

# ---------------------------------------------------------------------------
#  Dispatch
# ---------------------------------------------------------------------------

echo "${BOLD}LLM-sandbox load test${RESET}  profile=${CYAN}$PROFILE${RESET}  out=${OUT_DIR}"

case "$PROFILE" in
    smoke)         profile_smoke ;;
    short)         profile_short ;;
    decode-heavy)  profile_decode_heavy ;;
    prefill-heavy) profile_prefill_heavy ;;
    prefix-cache)  profile_prefix_cache ;;
    mixed)         profile_mixed ;;
    saturation)    profile_saturation ;;
    stress)        profile_stress ;;
    crush)         profile_crush ;;
    marathon)      profile_marathon ;;
    *) echo "${RED}unknown profile: $PROFILE${RESET}"; usage; exit 2 ;;
esac

echo
echo "${GREEN}done.${RESET} Detailed bins + CSV: $OUT_DIR"
echo "Tip: ${CYAN}trunks plot $OUT_DIR/*.bin --output=/tmp/plot.html && xdg-open /tmp/plot.html${RESET}"
