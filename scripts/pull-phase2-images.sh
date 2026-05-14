#!/usr/bin/env bash
# =============================================================================
#  pull-phase2-images.sh — one-shot prefetch of every Phase 2 container image
# -----------------------------------------------------------------------------
#  Phase 2 introduces a lot of new images. The Triton + TensorRT-LLM image is
#  the long pole (~25 GB unpacked, slow over typical home connections), so
#  it's worth starting the pulls before you start working on a sub-phase
#  rather than discovering mid-`docker compose up` that you're waiting on a
#  download. This script does that.
#
#  Re-runnable: docker pull is idempotent — if you already have an image at
#  the pinned digest, the pull returns instantly. Safe to invoke any time.
#
#  Approx. on-disk sizes (post-extraction, will differ on your host):
#     tritonserver:25.04-trtllm-python-py3   ~25 GB   ← the long pole
#     clickhouse-server:24.10-alpine          ~700 MB
#     langfuse:3.174.1                        ~1.5 GB
#     langfuse-worker:3.174.1                 ~1.2 GB
#     otel-collector-contrib:0.114.0          ~250 MB
#     loki:3.3.0                              ~80 MB
#     promtail:3.3.0                          ~250 MB
#     minio (RELEASE.2024-11-07T00-52-20Z)    ~250 MB
#     redis:7-alpine                          ~50 MB
#     ─────────────────────────────────────  ────────
#     Total                                  ~29 GB extra
#
#  Run as you (not as root) — Docker handles its own privilege escalation.
# =============================================================================

set -u

# ---------------------------------------------------------------------------
#  Pinned images (must match what docker-compose.yaml references in Phase 2)
# ---------------------------------------------------------------------------
# Two arrays so we can print a per-image header. Keep the order roughly
# longest-first so the slow Triton pull starts as early as possible.
IMAGES=(
    "nvcr.io/nvidia/tritonserver:25.04-trtllm-python-py3"   # Phase 2.0
    "langfuse/langfuse:3.174.1"                              # Phase 2.1 (replaces v2.95.11)
    "langfuse/langfuse-worker:3.174.1"                       # Phase 2.1
    "clickhouse/clickhouse-server:24.10-alpine"              # Phase 2.1
    "otel/opentelemetry-collector-contrib:0.114.0"           # Phase 2.2
    "grafana/promtail:3.3.0"                                 # Phase 2.3
    "minio/minio:RELEASE.2024-11-07T00-52-20Z"               # Phase 2.1
    "grafana/loki:3.3.0"                                     # Phase 2.3
    "redis:7-alpine"                                         # Phase 2.1
)

# ---------------------------------------------------------------------------
#  Colours (only on a TTY so log redirection stays clean)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; YELLOW=""; BOLD=""; RESET=""
fi

# ---------------------------------------------------------------------------
#  Preconditions
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    echo "${RED}docker not found on PATH${RESET}"
    exit 1
fi

# Disk-free check — Phase 2 plan §7 calls out ≥45 GB free (the Triton image
# alone is ~25 GB; the rest plus headroom add up). We measure on the docker
# root dir so we're checking the volume images actually land on.
docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
free_gb="$(df -BG "$docker_root" 2>/dev/null | awk 'NR==2 {gsub("G","",$4); print $4}')"
if [ -n "${free_gb:-}" ] && [ "$free_gb" -lt 45 ]; then
    echo "${RED}Only ${free_gb} GB free on ${docker_root} — Phase 2 needs ≥ 45 GB.${RESET}"
    echo "Free up disk (or move the docker data dir), then re-run."
    exit 1
fi
echo "${GREEN}Disk check OK${RESET} — ${free_gb:-unknown} GB free on ${docker_root}"
echo

# ---------------------------------------------------------------------------
#  Pulls
# ---------------------------------------------------------------------------
# We pull serially, not in parallel, because:
#   - The Triton image is so much bigger than everything else that running
#     it side-by-side with the small pulls doesn't save real time, and the
#     interleaved progress output becomes unreadable.
#   - A single failed pull is easier to retry when you can see exactly which
#     image errored.
total=${#IMAGES[@]}
i=0
failed=()
for image in "${IMAGES[@]}"; do
    i=$((i+1))
    echo "${BOLD}[${i}/${total}] docker pull ${image}${RESET}"
    if docker pull "$image"; then
        echo "${GREEN}  ✓ ${image}${RESET}"
    else
        echo "${RED}  ✗ ${image} failed${RESET}"
        failed+=("$image")
    fi
    echo
done

# ---------------------------------------------------------------------------
#  Summary
# ---------------------------------------------------------------------------
if [ "${#failed[@]}" -eq 0 ]; then
    echo "${GREEN}${BOLD}All ${total} images pulled.${RESET}"
    echo
    echo "Quick check:"
    echo "  docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}' \\"
    echo "    | grep -E 'tritonserver|langfuse|clickhouse|otel|loki|promtail|minio|redis'"
    exit 0
else
    echo "${RED}${BOLD}${#failed[@]} image(s) failed${RESET}:"
    for f in "${failed[@]}"; do
        echo "  - $f"
    done
    echo
    echo "${YELLOW}Re-run this script to retry — successful pulls are cached.${RESET}"
    exit 1
fi
