# Langfuse v3 (trace store)

> Where the agent's traces land. v3 receives OpenTelemetry data over the
> standard OTLP/HTTP protocol, batches it through Redis + Minio + a worker
> process, and stores high-cardinality span data in ClickHouse while
> keeping project metadata in Postgres.

## What this is

[Langfuse](https://langfuse.com/) is an LLM-observability platform. We
self-host the **v3 edition** as of Phase 2.1. Five containers, two storage
backends:

| Container | Image | What it does |
| --------- | ----- | ------------ |
| `langfuse` (web) | `langfuse/langfuse:3.x` | UI, REST + OTLP API, NextAuth login, schema migrator |
| `langfuse-worker` | `langfuse/langfuse-worker:3.x` | Drains the Redis queue, reads staged S3 batches, inserts into ClickHouse/Postgres |
| `langfuse-db` | `postgres:16-alpine` | Project metadata, users, encrypted API keys |
| `langfuse-clickhouse` | `clickhouse/clickhouse-server:24.10-alpine` | Spans + observations (columnar) |
| `langfuse-redis` | `redis:7-alpine` | Ingest queue between web and worker |
| `langfuse-minio` | `minio/minio` | S3-compatible blob store for staged event batches |

Phase 1 ran the **v2** edition — a single web container + Postgres. v3 is
six containers and ~6 GB more RAM at idle, but the upgrade unlocks two
things we wanted:

1. **OTLP/HTTP** at `/api/public/otel/v1/traces` — the standard wire
   protocol. v2 only spoke the proprietary SDK protocol. Phase 2.2 plugs
   OpenLLMetry → OTel Collector → this endpoint, restoring the httpx
   sub-spans we lost in Phase 1.2.
2. **Production-shape ingest pipeline.** Decoupling trace-receive from
   ClickHouse insertion via Redis matches what any high-volume trace
   store actually does (Tempo, Honeycomb, Datadog APM, …). Seeing the
   shape end-to-end is the educational reason to run v3 here, not just a
   managed v2.

## Why it's here

Three pillars / Phase 1+2 cover all three: metrics (Prometheus), traces
(Langfuse), and — in Phase 2.3 — logs (Loki). The questions Langfuse
answers:

- "User Robert says the answer was wrong — show me what the agent
  actually did." → click his user_id in Langfuse, see every span.
- "Why did this request take 30 seconds?" → trace tree shows whether the
  time was in an LLM call, a tool call, or HTTP overhead.
- "How is token usage trending per tenant?" → built-in Langfuse
  dashboards (separate from Grafana, different audience).

## v3 architecture (ingest path)

```
   Streamlit / agent / curl
         │  POST /api/public/otel/v1/traces (Phase 2.2)
         │  or  langfuse-sdk → /api/public/ingestion (v2-compat, Phase 2.1)
         ▼
   ┌─────────────────────┐
   │  langfuse (web)     │  Receives, validates, batches.
   │  Next.js standalone │  Writes batch as S3 object: events/<uuid>.json
   │  port 3000          │  Enqueues batch reference on Redis stream.
   └──────────┬──────────┘
              │
              ▼
   ┌─────────────────────┐
   │  langfuse-redis     │  XADD'd entries, one per pending batch.
   │  AOF on             │
   └──────────┬──────────┘
              │  XREAD
              ▼
   ┌─────────────────────┐  S3 GET            ┌──────────────────────┐
   │  langfuse-worker    │ ───────────────▶   │  langfuse-minio      │
   │  port 3030 (health) │ ◀────────────────  │  langfuse/events/    │
   └──────────┬──────────┘   batch JSON       └──────────────────────┘
              │
              ├── INSERT spans       ─▶ langfuse-clickhouse
              └── UPDATE indexes     ─▶ langfuse-db (Postgres)
```

## Configuration walkthrough

[`docker-compose.yaml`](../docker-compose.yaml) defines six services. The
common env block is hoisted into the `x-langfuse-env` YAML anchor at the
top of the file — both `langfuse` and `langfuse-worker` merge it in, so
their connection strings can't drift apart.

### `langfuse-db` (Postgres 16)

Internal-only. Stores projects, users, and encrypted API keys. Password
comes from `LANGFUSE_DB_PASSWORD` in `.env`. State persists in
`langfuse-pg-data`.

### `langfuse-clickhouse` (ClickHouse, alpine)

Internal-only. Holds the per-span rows. The user `langfuse` with
`CLICKHOUSE_PASSWORD` and database `langfuse` are created via env vars on
first start. Two listeners: `:8123` for HTTP queries at runtime, `:9000`
for the native protocol used by the web container's startup migrator
(`CLICKHOUSE_MIGRATION_URL`). State persists in `langfuse-clickhouse-data`.

Poke at it:
```bash
docker compose exec langfuse-clickhouse \
  clickhouse-client --user langfuse --password "$CLICKHOUSE_PASSWORD" --database langfuse
```

### `langfuse-redis` (Redis 7, alpine)

Internal-only. Queue between web (enqueue) and worker (dequeue). Password
via `REDIS_PASSWORD`. AOF on so a `compose restart` doesn't lose
in-flight batches. State persists in `langfuse-redis-data`.

### `langfuse-minio` (Minio)

Internal-only. S3-compatible blob store. Bucket `langfuse/` is
pre-created by the entrypoint command (`mkdir -p /data/langfuse` before
`minio server` runs) because Langfuse's S3 client doesn't auto-create
buckets. Credentials via `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD`. State
in `langfuse-minio-data`.

To inspect blobs, temporarily enable the console:
```yaml
    ports:
      - "9091:9001"
```
Then visit `http://localhost:9091` with the root user/pass.

### `langfuse` (web, v3)

| Env var | Purpose |
| ------- | ------- |
| `DATABASE_URL` | Postgres metadata connection. |
| `CLICKHOUSE_URL` / `CLICKHOUSE_MIGRATION_URL` / `CLICKHOUSE_USER` / `CLICKHOUSE_PASSWORD` | Two URLs: HTTP for runtime queries, native for migrations. |
| `REDIS_HOST` / `REDIS_PORT` / `REDIS_AUTH` | Ingest queue. |
| `LANGFUSE_S3_EVENT_UPLOAD_*` | Tells Langfuse where to stage batches. `REGION=us-east-1` is required — `auto` is rejected by the AWS SDK even against Minio. |
| `NEXTAUTH_URL` | The external URL Langfuse is reached on. We publish on host port `3001`. |
| `NEXTAUTH_SECRET` | Session-cookie signing. `openssl rand -hex 32`. |
| `SALT` | Hash salt for API key fingerprints. |
| `ENCRYPTION_KEY` | **New in v3.** 64 hex chars; column-level encryption of integration creds. CRITICAL: do not rotate after first write. |
| `TELEMETRY_ENABLED=false` | No anonymous pings. |

### `langfuse-worker`

Same env block as the web (merged from the same anchor). No published
port — the worker exposes `/api/health` on `3030` for the in-network
healthcheck only.

### Why port 3001 (not 3000)?

Grafana defaults to `3000`. Langfuse's container also listens on 3000. We
map host `3001 → container 3000` so both can run side by side.

## First-run setup (manual)

Langfuse needs an account, an org, a project, and an API key pair before
the agent app can push traces. One-time UI walkthrough:

1. `docker compose up -d langfuse-db langfuse-clickhouse langfuse-redis langfuse-minio langfuse langfuse-worker`
2. Wait for `langfuse` to go healthy (`docker compose ps langfuse`).
   First start runs Prisma migrations against Postgres AND a ClickHouse
   schema migration — easily 30-60 s.
3. Open <http://localhost:3001>.
4. Sign up (any email; this is a local install).
5. Create an organisation (e.g. "Sandbox") and a project (e.g. "phase-2").
6. Project Settings → API Keys → Create new keys.
7. Copy the **public key** and **secret key** into `.env`:
   ```bash
   LANGFUSE_PUBLIC_KEY=pk-lf-...
   LANGFUSE_SECRET_KEY=sk-lf-...
   ```
8. `docker compose restart app`.
9. Re-run `scripts/preflight.sh` — it reports whether both keys are
   populated and whether the new v3 env vars are set.

## Upgrading from v2 (one-time)

If you ran Phase 1's v2 stack, the cleanest path is a **clean cut**:

```bash
docker compose down langfuse langfuse-db
docker volume rm llm-stack_langfuse-pg-data
docker compose up -d  # rebuilds with the v3 services
```

That drops the Phase 1 traces, which is fine because they're synthetic
(`scripts/load.sh` regenerates them in minutes). Langfuse v3 *does* ship
a `migrate-from-v2` worker command if you genuinely need the old traces,
but the plan deliberately picked the clean-cut path — see
[../.plans/phase2-PLAN.md](../.plans/phase2-PLAN.md) §2.1 trade-offs.

## OTLP endpoint (Phase 2.2 hook)

v3 accepts OTLP/HTTP at:

```
http://langfuse:3000/api/public/otel        # from inside compose
http://localhost:3001/api/public/otel       # from the host shell
```

Auth is HTTP Basic with `LANGFUSE_PUBLIC_KEY` as the username and
`LANGFUSE_SECRET_KEY` as the password. Smoke test (returns 401 because
we haven't sent credentials — that's the success signal):

```bash
curl -i http://localhost:3001/api/public/otel/v1/traces
# HTTP/1.1 401 Unauthorized
```

Phase 2.2 plugs `otel-collector`'s `basicauth/langfuse` extension into
this endpoint.

## Smoke tests

```bash
# Web healthy
curl -s http://localhost:3001/api/public/health
# → {"status":"OK"}

# OTLP path reachable (requires auth, hence 401)
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3001/api/public/otel/v1/traces
# → 401

# Worker healthy (in-network only)
docker compose exec langfuse-worker \
  wget -qO- http://localhost:3030/api/health
# → {"status":"OK"}

# ClickHouse has the langfuse DB
docker compose exec langfuse-clickhouse \
  clickhouse-client --user langfuse --password "$CLICKHOUSE_PASSWORD" \
                    --query "SHOW DATABASES"
# → ... langfuse ...

# Minio bucket exists
docker compose exec langfuse-minio mc ls local/
# → langfuse/

# Redis answers (from inside the container, with auth)
docker compose exec langfuse-redis \
  redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping
# → PONG
```

## Where to look when it breaks

| Symptom | Likely cause | Where to look |
| ------- | ------------ | ------------- |
| `langfuse` keeps restarting; logs say "ClickHouse migration failed" | CH not healthy yet, or `CLICKHOUSE_MIGRATION_URL` wrong (native port = 9000, not 8123) | `docker compose logs langfuse-clickhouse`; check the URL pair in `docker-compose.yaml`'s `x-langfuse-env` |
| `langfuse` healthy but UI hangs on first request | Prisma still running migrations | wait 30-60 s; `docker compose logs -f langfuse` |
| Worker logs "Bucket does not exist" | The Minio entrypoint didn't pre-create the bucket | Confirm the `mkdir -p /data/langfuse` is intact in `langfuse-minio.command` |
| "JWT_SESSION_ERROR" | `NEXTAUTH_SECRET` changed between starts | Keep it stable, or `docker compose down -v` to clear sessions |
| SDK ingestion returns 401 | Wrong `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` pair | Re-copy from Project Settings → API Keys; restart the `app` service |
| Traces sent but never appear | Worker not draining; check Redis | `docker compose logs langfuse-worker`; `redis-cli -a "$REDIS_PASSWORD" XLEN events` (queue length > 0 means worker is behind) |
| Web container crashes "Encryption key not set or wrong length" | Missing or non-64-hex `ENCRYPTION_KEY` | `openssl rand -hex 32` and put in `.env` |
| ClickHouse logs "Cannot allocate thread" | Alpine image hits LimitNOFILE on some hosts | Add `ulimits.nofile: 262144` to the service block |

## What's next

- **Phase 2.2** wires OpenLLMetry + OTel Collector at the OTLP endpoint,
  replacing the v2-compat callback path in `app/agent.py`. The trace tree
  in this UI gets the `httpx.GET` sub-spans back.
- The walkthrough doc [docs/02-anatomy-of-a-request.md](../docs/02-anatomy-of-a-request.md)
  is updated alongside Phase 2.2 to use v3 screenshots.
