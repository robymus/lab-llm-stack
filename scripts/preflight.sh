#!/usr/bin/env bash
# =============================================================================
#  preflight.sh — verify host can run the LLM SRE Sandbox
# -----------------------------------------------------------------------------
#  Run this BEFORE `docker compose up`. It checks every prereq from the plan's
#  §9 list and prints clear PASS/FAIL output. Exit status:
#    0  — all checks passed
#    1  — at least one required check failed (output explains what + how to fix)
#
#  Designed to be re-run after fixing issues. No state, no side effects.
# =============================================================================

set -u   # treat unset vars as errors; we deliberately don't `set -e` because
         # each check decides its own pass/fail and we want all reports, not
         # the first failure.

PASS=0   # count of passed checks
FAIL=0   # count of failed checks

# ANSI colours, but only if stdout is a TTY so log files stay readable.
if [ -t 1 ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; YELLOW=""; RESET=""
fi

ok()   { echo "  ${GREEN}✓${RESET} $1"; PASS=$((PASS+1)); }
fail() { echo "  ${RED}✗${RESET} $1"; FAIL=$((FAIL+1)); }
warn() { echo "  ${YELLOW}!${RESET} $1"; }
hint() { echo "      ${YELLOW}→${RESET} $1"; }

section() { echo; echo "[$1]"; }

# ---------------------------------------------------------------------------
section "Docker"
if command -v docker >/dev/null 2>&1; then
    ok "docker installed ($(docker --version | head -1))"
else
    fail "docker not found on PATH"
    hint "install Docker Engine: https://docs.docker.com/engine/install/"
fi

# `docker compose version` works for both the plugin (v2+) and any rebrand.
if docker compose version >/dev/null 2>&1; then
    ok "docker compose plugin works ($(docker compose version | head -1))"
else
    fail "docker compose plugin missing"
    hint "install the compose plugin: https://docs.docker.com/compose/install/linux/"
fi

# ---------------------------------------------------------------------------
section "NVIDIA driver & GPU"
if command -v nvidia-smi >/dev/null 2>&1; then
    gpu_line="$(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null | head -1)"
    if [ -n "$gpu_line" ]; then
        ok "GPU detected: $gpu_line"
    else
        fail "nvidia-smi present but reports no GPU"
    fi
else
    fail "nvidia-smi not found — NVIDIA driver likely not installed"
    hint "install the proprietary NVIDIA driver for your distro"
fi

# ---------------------------------------------------------------------------
section "NVIDIA Container Toolkit"
# Two independent checks: the toolkit package, and Docker daemon registration.
# Both must pass for `--gpus all` / `deploy.resources.reservations.devices` to
# actually expose the GPU inside containers.

if command -v nvidia-ctk >/dev/null 2>&1 || dpkg -l 2>/dev/null | grep -q nvidia-container-toolkit; then
    ok "nvidia-container-toolkit installed"
else
    fail "nvidia-container-toolkit NOT installed"
    hint "follow https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html"
    hint "Debian/Ubuntu quick-install:"
    hint "  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \\"
    hint "    sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
    hint "  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \\"
    hint "    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \\"
    hint "    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list"
    hint "  sudo apt update && sudo apt install -y nvidia-container-toolkit"
fi

# Docker daemon needs the runtime registered. `docker info` lists it.
if docker info 2>/dev/null | grep -qi 'Runtimes:.*nvidia'; then
    ok "docker daemon has nvidia runtime registered"
else
    fail "docker daemon does NOT have nvidia runtime"
    hint "register it and restart docker:"
    hint "  sudo nvidia-ctk runtime configure --runtime=docker"
    hint "  sudo systemctl restart docker"
fi

# Real test: try to launch a tiny CUDA container.
# We do this only if the previous two checks passed, otherwise it's noise.
if docker info 2>/dev/null | grep -qi 'Runtimes:.*nvidia'; then
    if docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi -L >/dev/null 2>&1; then
        ok "container GPU access works (ran nvidia-smi inside a container)"
    else
        fail "container GPU access failed despite runtime being registered"
        hint "try: docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi -L"
    fi
fi

# ---------------------------------------------------------------------------
section "Disk space"
# Plan §9 calls for ~30 GB free. We measure on the docker root (where images
# land), not the project dir — they're usually the same volume but not always.
docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
free_gb="$(df -BG "$docker_root" 2>/dev/null | awk 'NR==2 {gsub("G","",$4); print $4}')"
if [ -n "$free_gb" ] && [ "$free_gb" -ge 30 ]; then
    ok "${free_gb} GB free on $docker_root (≥ 30 GB)"
elif [ -n "$free_gb" ]; then
    fail "only ${free_gb} GB free on $docker_root — plan needs ≥ 30 GB"
    hint "free up disk or move docker data dir"
else
    warn "could not determine free space on $docker_root"
fi

# ---------------------------------------------------------------------------
section ".env file"
ENV_FILE="$(dirname "$0")/../.env"
if [ -f "$ENV_FILE" ]; then
    ok ".env present"
    # If both Langfuse keys are set, compute the base64 helper so the agent
    # app can authenticate to OTLP without further intervention.
    pk="$(grep -E '^LANGFUSE_PUBLIC_KEY=' "$ENV_FILE" | cut -d= -f2-)"
    sk="$(grep -E '^LANGFUSE_SECRET_KEY=' "$ENV_FILE" | cut -d= -f2-)"
    if [ -n "$pk" ] && [ -n "$sk" ]; then
        b64="$(printf '%s:%s' "$pk" "$sk" | base64 -w0)"
        if grep -qE '^LANGFUSE_AUTH_B64=' "$ENV_FILE"; then
            # In-place update (BSD/GNU sed compatible).
            sed -i.bak -E "s|^LANGFUSE_AUTH_B64=.*|LANGFUSE_AUTH_B64=${b64}|" "$ENV_FILE"
            rm -f "${ENV_FILE}.bak"
        fi
        ok "LANGFUSE_AUTH_B64 computed from public/secret key pair"
    else
        warn "LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY empty"
        hint "needed for Phase 1.2 — create them in the Langfuse UI after first start"
    fi
else
    fail ".env missing"
    hint "cp .env.example .env  and fill in HF_TOKEN at minimum"
fi

# ---------------------------------------------------------------------------
echo
if [ "$FAIL" -eq 0 ]; then
    echo "${GREEN}All ${PASS} required checks passed.${RESET}"
    exit 0
else
    echo "${RED}${FAIL} check(s) failed${RESET} (${PASS} passed). Fix the items above, then re-run."
    exit 1
fi
