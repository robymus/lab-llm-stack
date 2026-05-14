# Pinned versions

Every image and runtime in this repo is pinned to a specific version. This
file is the audit trail — what's in the compose / Dockerfiles / requirements
and when it was last verified working.

> Bump rule: changing any pin is a deliberate commit with a one-line note in
> this file explaining what was retested. Don't accumulate `:latest` debt.

## Container images

| Service | Image | Tag / digest | Last verified |
| ------- | ----- | ------------ | ------------- |
| vllm-engine | `vllm/vllm-openai` | `v0.6.6` | 2026-05-12 — AWQ-Marlin kernel for Ada (8.9) stable here |
| litellm | `ghcr.io/berriai/litellm` | `@sha256:6c82d338a60e…` (`main-stable` as of 2026-04-26) | 2026-05-13 — pinned by manifest digest, not tag |
| langfuse-db | `postgres` | `16-alpine` | 2026-05-12 — Langfuse v3 migrations tested against PG 14-17 |
| langfuse | `langfuse/langfuse` | `3.174.1` | 2026-05-14 — Phase 2.1 bump; latest v3 at pin time, replaces v2.95.11 |
| langfuse-worker | `langfuse/langfuse-worker` | `3.174.1` | 2026-05-14 — Phase 2.1; must match the web image's minor |
| langfuse-clickhouse | `clickhouse/clickhouse-server` | `24.10-alpine` | 2026-05-14 — Phase 2.1; on Langfuse v3's tested compatibility list |
| langfuse-redis | `redis` | `7-alpine` | 2026-05-14 — Phase 2.1; queue between web + worker |
| langfuse-minio | `minio/minio` | `RELEASE.2024-11-07T00-52-20Z` | 2026-05-14 — Phase 2.1; S3-compatible event-batch staging |
| otel-collector | `otel/opentelemetry-collector-contrib` | `0.114.0` | 2026-05-14 — Phase 2.2; contrib distro for basicauth + attributes processors. Distroless image — no shell/wget, hence no compose healthcheck |
| loki | `grafana/loki` | `3.3.0` | 2026-05-14 — Phase 2.3; single-binary, filesystem-backed, schema v13 + TSDB |
| promtail | `grafana/promtail` | `3.3.0` | 2026-05-14 — Phase 2.3; docker-SD scrapes every compose container's stdout |
| dcgm-exporter | `nvcr.io/nvidia/k8s/dcgm-exporter` | `3.3.9-3.6.1-ubuntu22.04` | 2026-05-12 — works with driver 580.x on Ada |
| node-exporter | `prom/node-exporter` | `v1.8.2` | 2026-05-12 |
| cadvisor | `gcr.io/cadvisor/cadvisor` | `v0.49.2` | 2026-05-12 — `accelerator` metric class already removed in this release |
| prometheus | `prom/prometheus` | `v3.1.0` | 2026-05-12 |
| grafana | `grafana/grafana` | `11.4.0` | 2026-05-12 |
| app | `python` | `3.11-slim` | 2026-05-12 — base for the agent container |
| mock-services | `python` | `3.11-slim` | 2026-05-12 — base for the FastAPI container |

## Runtime versions

| Where | Version | Notes |
| ----- | ------- | ----- |
| Python (Dockerfiles + CI) | 3.11 | Matches `[tool.ruff] target-version = "py311"` in `pyproject.toml`. CI uses `actions/setup-python` with `python-version: "3.11"`. |
| Model | `Qwen/Qwen2.5-3B-Instruct-AWQ` | ~2.2 GB AWQ-INT4; fits 8 GB with KV-cache headroom. |

## Python dependencies

Pinned in:
- `app/requirements.txt` (runtime) + `app/requirements-dev.txt` (test + lint)
- `mock-services/requirements.txt` (runtime) + `mock-services/requirements-dev.txt` (test + lint)

The langchain ⇆ openai ⇆ traceloop-sdk compatibility matrix is the brittlest
part of the stack; bumping any of those three is a separate verification pass
against a live Langfuse trace (see `app/README.md`). Phase 2.2 swapped the
v2 `langfuse` SDK for `traceloop-sdk==0.60.0`, which auto-instruments
langchain + openai + httpx and pushes OTLP/HTTP via the otel-collector.

## GitHub Actions

CI pins every third-party action by commit SHA, not by tag — tags can be
force-moved by the action owner, SHAs cannot. The `# v4.3.1` comments next
to each SHA in `.github/workflows/ci.yml` tell humans which release the SHA
refers to. Current pins:

| Action | Version | SHA |
| ------ | ------- | --- |
| `actions/checkout` | v4.3.1 | `34e114876b0b11c390a56381ad16ebd13914f8d5` |
| `actions/setup-python` | v5.6.0 | `a26af69be951a213d495a4c3e4e4022e16d87065` |
| `hadolint/hadolint-action` | v3.3.0 | `2332a7b74a6de0dda2e2221d575162eba76ba5e5` |

Bump procedure:

```bash
gh api repos/<owner>/<repo>/git/refs/tags \
  | jq -r '.[] | "\(.ref) -> \(.object.sha)"' \
  | grep <new_tag>
```

## Linter / formatter versions

| Tool | Version | Pinned in |
| ---- | ------- | --------- |
| ruff | 0.15.9 | `app/requirements-dev.txt`, `mock-services/requirements-dev.txt`, `.github/workflows/ci.yml`, `.pre-commit-config.yaml` |
| yamllint | 1.35.1 | `.github/workflows/ci.yml`, `.pre-commit-config.yaml` |
| hadolint (action) | v3.3.0 | `.github/workflows/ci.yml` |
| hadolint (pre-commit) | v2.12.0 | `.pre-commit-config.yaml` (newer Docker image of the same tool) |
| pre-commit-hooks | v5.0.0 | `.pre-commit-config.yaml` |
| pytest | 8.3.3 | Both `requirements-dev.txt` files |
| respx | 0.21.1 | `app/requirements-dev.txt` |
