#!/usr/bin/env bash
# =============================================================================
#  cleanup.sh — wipe the sandbox state
# -----------------------------------------------------------------------------
#  Removes, in order:
#    1. all running containers from this compose project
#    2. the user-defined network
#    3. named volumes (HF cache, Langfuse Postgres data, Prometheus/Grafana state)
#    4. images this compose project pulled
#    5. (optional) any dangling images left behind
#
#  Flags:
#    -y, --yes          skip the interactive confirmation
#        --keep-images  remove containers + volumes, but keep pulled images
#                       (faster turnaround — model weights re-cache from disk,
#                        but you skip a multi-GB image re-pull)
#        --keep-cache   keep the HuggingFace model cache volume (`hf-cache`)
#                       so you don't re-download Qwen2.5-3B every iteration
#    -h, --help         show this help and exit
#
#  Exit status: 0 on success, non-zero on any docker command failure.
#
#  This script is DESTRUCTIVE. By default it asks before doing anything.
# =============================================================================

set -u
set -o pipefail

# Resolve project root regardless of where the script is called from.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

# Compose project name. Must match the `name:` key in docker-compose.yaml.
PROJECT="llm-stack"

# Volumes the project creates, in the namespaced form `<project>_<vol>`.
# Kept explicit so we can selectively preserve `hf-cache` (the big one).
VOLUMES=(
  "${PROJECT}_hf-cache"
  "${PROJECT}_langfuse-pg-data"
  "${PROJECT}_prometheus-data"
  "${PROJECT}_grafana-data"
)
HF_CACHE_VOL="${PROJECT}_hf-cache"

# ANSI colour helpers — same shape as preflight.sh for consistency.
if [ -t 1 ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; YELLOW=""; BOLD=""; RESET=""
fi
ok()   { echo "  ${GREEN}✓${RESET} $1"; }
fail() { echo "  ${RED}✗${RESET} $1"; }
warn() { echo "  ${YELLOW}!${RESET} $1"; }
section() { echo; echo "${BOLD}[$1]${RESET}"; }

# ---------------------------------------------------------------------------
#  Argument parsing
# ---------------------------------------------------------------------------
ASSUME_YES=0
KEEP_IMAGES=0
KEEP_CACHE=0

usage() {
    sed -n '2,/^# ====/p' "$0" | sed -e 's/^# \{0,1\}//' -e '$d'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)        ASSUME_YES=1 ;;
        --keep-images)   KEEP_IMAGES=1 ;;
        --keep-cache)    KEEP_CACHE=1 ;;
        -h|--help)       usage ;;
        *) fail "unknown flag: $1"; echo "Run \`$0 --help\` for usage."; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
#  Preview what's about to happen
# ---------------------------------------------------------------------------
section "About to remove"

# Containers from this compose project, if any.
running="$(docker compose ps -q 2>/dev/null | wc -l | tr -d ' ')"
echo "  - $running container(s) from compose project '${PROJECT}'"

echo "  - the '${PROJECT}_default' / '${PROJECT}_llm-stack' network (if present)"

if [ "$KEEP_CACHE" -eq 1 ]; then
    echo "  - named volumes:"
    for v in "${VOLUMES[@]}"; do
        if [ "$v" = "$HF_CACHE_VOL" ]; then
            echo "      ${YELLOW}(keeping)${RESET}  $v"
        else
            echo "      $v"
        fi
    done
else
    echo "  - all named volumes:"
    for v in "${VOLUMES[@]}"; do echo "      $v"; done
fi

if [ "$KEEP_IMAGES" -eq 1 ]; then
    warn "images will be KEPT (--keep-images)"
else
    echo "  - all images this compose project uses (vllm, litellm, langfuse, postgres,"
    echo "    plus any pulled in later phases via the same compose file)"
fi

# Show disk reclaim estimate so the user knows what's at stake.
section "Disk reclaim estimate"
if [ "$running" -gt 0 ] || docker volume ls --format '{{.Name}}' 2>/dev/null | grep -q "^${PROJECT}_"; then
    docker system df 2>/dev/null | grep -E "(Images|Volumes)" || true
else
    echo "  (nothing to remove)"
fi

# ---------------------------------------------------------------------------
#  Confirm
# ---------------------------------------------------------------------------
if [ "$ASSUME_YES" -ne 1 ]; then
    echo
    printf "%sProceed?%s [y/N] " "$BOLD" "$RESET"
    read -r ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) echo "Aborted. No changes made."; exit 0 ;;
    esac
fi

# ---------------------------------------------------------------------------
#  Tear down
# ---------------------------------------------------------------------------
section "Stopping & removing containers + network"
# `down` removes containers + the user-defined network. We do NOT pass `-v`
# here so we can be selective about which volumes to drop below.
# `--remove-orphans` cleans up any container we forgot to declare.
if docker compose down --remove-orphans; then
    ok "compose down complete"
else
    fail "compose down had errors (continuing — usually safe if services were already gone)"
fi

# ---------------------------------------------------------------------------
section "Removing named volumes"
for v in "${VOLUMES[@]}"; do
    if [ "$KEEP_CACHE" -eq 1 ] && [ "$v" = "$HF_CACHE_VOL" ]; then
        warn "skipped $v (--keep-cache)"
        continue
    fi
    if docker volume inspect "$v" >/dev/null 2>&1; then
        if docker volume rm "$v" >/dev/null 2>&1; then
            ok "removed $v"
        else
            fail "could not remove $v (something still using it?)"
        fi
    else
        warn "$v not present"
    fi
done

# ---------------------------------------------------------------------------
section "Removing images"
if [ "$KEEP_IMAGES" -eq 1 ]; then
    warn "skipped (--keep-images)"
else
    # Reach the image list via compose so we automatically pick up images
    # added by future phases (DCGM, Prometheus, Grafana, app, mock-services).
    # `--rmi all` on `docker compose down` would do this in one step, but we
    # already ran `down` above without it so we could be selective on volumes.
    # Do it explicitly here.
    images="$(docker compose config --images 2>/dev/null | sort -u)"
    if [ -z "$images" ]; then
        warn "no images resolved from compose config"
    else
        # shellcheck disable=SC2086  # we want word-splitting
        while IFS= read -r img; do
            [ -z "$img" ] && continue
            if docker image inspect "$img" >/dev/null 2>&1; then
                if docker rmi "$img" >/dev/null 2>&1; then
                    ok "removed image $img"
                else
                    fail "could not remove $img (still in use?)"
                fi
            else
                warn "image $img not present locally"
            fi
        done <<< "$images"
    fi

    # Dangling images can pile up after pulls / rebuilds. Free those too.
    dangling="$(docker image ls -qf dangling=true 2>/dev/null)"
    if [ -n "$dangling" ]; then
        # shellcheck disable=SC2086
        if docker rmi $dangling >/dev/null 2>&1; then
            ok "removed dangling images"
        else
            warn "some dangling images could not be removed"
        fi
    fi
fi

# ---------------------------------------------------------------------------
section "Final state"
echo "  Containers from project ${PROJECT}:"
docker compose ps 2>/dev/null | sed 's/^/    /' || true
echo "  Remaining ${PROJECT}_* volumes:"
docker volume ls --format '{{.Name}}' 2>/dev/null | grep "^${PROJECT}_" | sed 's/^/    /' || echo "    (none)"

echo
echo "${GREEN}Cleanup complete.${RESET}"
echo "Next: \`./scripts/preflight.sh\` then \`docker compose up -d\` to start fresh."
