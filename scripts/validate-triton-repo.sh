#!/usr/bin/env bash
# =============================================================================
#  validate-triton-repo.sh — fast offline sanity check of triton/model_repository/
# -----------------------------------------------------------------------------
#  Runs in <1 second on the host (no docker, no GPU). Catches the
#  ~5 things that make Triton refuse to load before you wait 60 s for it
#  to boot and dig through thousands of log lines.
#
#  Checks:
#    1. All 5 expected models present (preprocessing, postprocessing,
#       ensemble, tensorrt_llm, tensorrt_llm_bls)
#    2. Each config.pbtxt has zero unresolved `${...}` placeholders
#    3. tensorrt_llm/1/ contains a *.engine file (non-zero size)
#    4. preprocessing/tokenizer/ contains tokenizer.json + tokenizer_config.json
#    5. tokenizer_dir values in pre/postprocessing configs point at an
#       actual directory inside the runtime mount (/models/...)
#    6. No stray top-level directories that aren't valid Triton models
#       (these confuse the model loader)
#
#  Exit 0 = repo looks loadable. Exit 1 = at least one check failed,
#  with a pinpointed error per failure.
# =============================================================================

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${REPO_ROOT}/triton/model_repository"
EXPECTED_MODELS=(preprocessing postprocessing ensemble tensorrt_llm tensorrt_llm_bls)

if [ -t 1 ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; YELLOW=""; BOLD=""; RESET=""
fi

PASS=0
FAIL=0

ok()   { echo "  ${GREEN}✓${RESET} $1"; PASS=$((PASS+1)); }
err()  { echo "  ${RED}✗${RESET} $1"; FAIL=$((FAIL+1)); }
note() { echo "  ${YELLOW}!${RESET} $1"; }
sect() { echo; echo "${BOLD}[$1]${RESET}"; }

# ---------------------------------------------------------------------------
sect "Directory exists"
if [ -d "$REPO" ]; then
    ok "$REPO"
else
    err "$REPO is missing — run scripts/build-trt-engine.sh"
    echo; echo "${RED}${FAIL} checks failed.${RESET}"; exit 1
fi

# ---------------------------------------------------------------------------
sect "Top-level layout — only valid Triton models allowed"
# Triton scans direct children of model_repository and loads each as a
# model. Any directory here that isn't in EXPECTED_MODELS will confuse
# the loader with "Could not determine backend for model 'X'".
for d in "$REPO"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    expected=0
    for e in "${EXPECTED_MODELS[@]}"; do
        if [ "$e" = "$name" ]; then expected=1; break; fi
    done
    if [ "$expected" = "1" ]; then
        ok "$name (expected)"
    else
        err "$name is a top-level directory but not a Triton model — Triton will fail to start. Move under a model subdir (e.g. preprocessing/$name/)"
    fi
done

# ---------------------------------------------------------------------------
sect "Every expected model present"
for m in "${EXPECTED_MODELS[@]}"; do
    if [ -d "$REPO/$m" ]; then
        ok "$m/"
    else
        err "$m/ missing"
    fi
done

# ---------------------------------------------------------------------------
sect "config.pbtxt present + no unresolved \${...} placeholders"
for m in "${EXPECTED_MODELS[@]}"; do
    cfg="$REPO/$m/config.pbtxt"
    if [ ! -f "$cfg" ]; then
        err "$m/config.pbtxt missing"
        continue
    fi
    # Find any remaining `${...}` placeholders that fill_template.py didn't
    # substitute. These cause Triton to start the model but reject requests
    # with "invalid parameter value".
    unfilled=$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$cfg" | sort -u)
    if [ -n "$unfilled" ]; then
        err "$m/config.pbtxt has unresolved placeholders:"
        echo "$unfilled" | sed 's/^/      /'
    else
        ok "$m/config.pbtxt clean"
    fi
done

# ---------------------------------------------------------------------------
sect "Engine binary"
engine_dir="$REPO/tensorrt_llm/1"
if [ -d "$engine_dir" ]; then
    engines=$(find "$engine_dir" -name '*.engine' -size +0c 2>/dev/null)
    if [ -n "$engines" ]; then
        # Show first engine with size for sanity.
        sz=$(stat -c '%s' "$(echo "$engines" | head -1)")
        sz_mb=$((sz / 1024 / 1024))
        ok "tensorrt_llm/1/ has engine ($sz_mb MB)"
    else
        err "tensorrt_llm/1/ has no .engine file — run scripts/build-trt-engine.sh"
    fi
else
    err "tensorrt_llm/1/ directory missing"
fi

# ---------------------------------------------------------------------------
sect "Tokenizer files"
tok="$REPO/preprocessing/tokenizer"
if [ -d "$tok" ]; then
    missing=()
    for f in tokenizer.json tokenizer_config.json; do
        [ -f "$tok/$f" ] || missing+=("$f")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        ok "preprocessing/tokenizer/ has tokenizer.json + tokenizer_config.json"
    else
        err "preprocessing/tokenizer/ missing: ${missing[*]}"
    fi
else
    err "preprocessing/tokenizer/ missing — the build script should populate this from HF cache"
fi

# ---------------------------------------------------------------------------
sect "tokenizer_dir values in configs"
for m in preprocessing postprocessing; do
    cfg="$REPO/$m/config.pbtxt"
    [ -f "$cfg" ] || continue
    # Pull the string_value inside the tokenizer_dir parameter block.
    val=$(awk '
        /key:[[:space:]]*"tokenizer_dir"/ { found=1 }
        found && /string_value:/ {
            match($0, /"[^"]*"/);
            print substr($0, RSTART+1, RLENGTH-2);
            exit
        }
    ' "$cfg")
    if [ -z "$val" ]; then
        err "$m/config.pbtxt missing tokenizer_dir"
        continue
    fi
    # Map /models/X → REPO/X on the host
    host_path="${val/#\/models/$REPO}"
    if [ -d "$host_path" ]; then
        ok "$m: tokenizer_dir → $val (resolves to $host_path)"
    else
        err "$m: tokenizer_dir → $val (host-side $host_path doesn't exist)"
    fi
done

# ---------------------------------------------------------------------------
sect "Triton model-loader-trap directories"
# Triton tries to load anything matching /models/<name>/config.pbtxt. If
# config.pbtxt is missing OR `backend:` is unset, loading fails.
for m in "${EXPECTED_MODELS[@]}"; do
    cfg="$REPO/$m/config.pbtxt"
    [ -f "$cfg" ] || continue
    if ! grep -qE '^(backend|platform):' "$cfg"; then
        err "$m/config.pbtxt has no backend: line — Triton will reject it"
    fi
done
ok "every model declares a backend"

# ---------------------------------------------------------------------------
echo
if [ "$FAIL" -eq 0 ]; then
    echo "${GREEN}${BOLD}All ${PASS} validation checks passed${RESET} — repo looks loadable"
    exit 0
else
    echo "${RED}${BOLD}${FAIL} validation check(s) failed${RESET} (${PASS} passed)"
    echo
    echo "Fix the items above, re-run this script, then bring Triton up."
    exit 1
fi
