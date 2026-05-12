# Langfuse (trace store)

> Where the agent's traces land. Receives OpenTelemetry data over the
> standard OTLP/HTTP protocol, indexes it, and presents the per-request
> "thoughts → tool calls → responses" tree in a UI.

## What this is

[Langfuse](https://langfuse.com/) is an LLM-observability platform. We use
the **self-hosted v2** edition: one Node.js web container, one Postgres for
storage. The v3 edition adds a worker + ClickHouse + Redis + Minio for
high-volume analytics — production-realistic, but six containers more than
this sandbox needs. We can upgrade later; for the learning goal, v2 covers
everything we want to see (traces, sessions, users, observations, scores).

Crucially, Langfuse v2 accepts **OpenTelemetry OTLP/HTTP** at
`/api/public/otel/v1/traces`. That means our app talks plain OTel — the same
SDK code would work against Jaeger, Tempo, Honeycomb, etc. Langfuse just
happens to be the backend we point at.

## Why it's here

Three pillars / Phase 1 covers two of them: metrics and traces. Langfuse is
the trace pillar. The questions it answers:

- "User Robert says the answer was wrong — show me what the agent actually
  did." → click his user_id in Langfuse, see every span.
- "Why did this request take 30 seconds?" → trace tree shows whether the
  time was in an LLM call, a tool call, or HTTP overhead.
- "How is token usage trending per tenant?" → built-in Langfuse dashboards
  (separate from Grafana, deliberately — different audience).

## Configuration walkthrough

[`docker-compose.yaml`](../docker-compose.yaml) defines two services:

### `langfuse-db` (Postgres 16)

- Internal-only: no host port. Reached as `langfuse-db:5432` from inside
  the network.
- Password comes from `LANGFUSE_DB_PASSWORD` in `.env`.
- State persists in the `langfuse-pg-data` named volume — surviving
  `docker compose down` but not `down -v`.

### `langfuse` (web app)

| Env var | Purpose |
| ------- | ------- |
| `DATABASE_URL` | Built from the DB password; points at `langfuse-db:5432`. |
| `NEXTAUTH_URL` | NextAuth needs to know its own external URL. We publish on host port `3001` to avoid clashing with Grafana on `3000`. |
| `NEXTAUTH_SECRET` | Session-cookie signing. Generate with `openssl rand -hex 32`. |
| `SALT` | Encryption salt for stored API keys. Same generator. |
| `TELEMETRY_ENABLED=false` | Disables Langfuse's anonymous usage pings. |

### Why port 3001 (not 3000)?

Grafana defaults to `3000`. Langfuse's container also listens on 3000.
We map host `3001 → container 3000` so both services can run side by side
without anyone having to remember "is 3000 grafana or langfuse this week".

## First-run setup (manual)

Langfuse needs an account, an org, a project, and an API key pair before
the agent app can push traces. There's no clean way to do this in pure
config for v2 — it's a one-time UI walkthrough:

1. `docker compose up langfuse-db langfuse`
2. Open <http://localhost:3001>.
3. Sign up (any email; this is a local install).
4. Create an organisation (e.g. "Sandbox") and a project (e.g. "phase-1").
5. Project Settings → API Keys → Create new keys.
6. Copy the **public key** and **secret key** into `.env`:
   ```bash
   LANGFUSE_PUBLIC_KEY=pk-lf-...
   LANGFUSE_SECRET_KEY=sk-lf-...
   ```
7. Re-run `scripts/preflight.sh` — it computes `LANGFUSE_AUTH_B64` from the
   pair automatically.

The agent app (Phase 1.2) reads `LANGFUSE_AUTH_B64` and sends it as the
`Authorization: Basic …` header on OTLP requests.

## OTLP endpoint

Phase 1.2's `Traceloop.init(...)` will use:

```
http://langfuse:3000/api/public/otel
```

(when running inside compose), or:

```
http://localhost:3001/api/public/otel
```

(when running the app outside compose for local debugging).

The protocol is standard OTLP/HTTP. Langfuse maps OTel span attributes onto
its own data model — `gen_ai.*` attributes (the OpenLLMetry-emitted ones)
turn into the rich LLM-call view; everything else becomes a generic span.

## Smoke tests

```bash
# Health
curl -s http://localhost:3001/api/public/health
# → {"status":"OK"} (or similar)

# Page renders
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3001
# → 200 (after a few seconds for the first request — NextJS cold start)
```

## Where to look when it breaks

| Symptom | Likely cause | Where to look |
| ------- | ------------ | ------------- |
| Web app crashes on first start with "no database" | Postgres not healthy yet | `docker compose ps`; wait, then restart langfuse |
| "JWT_SESSION_ERROR" in logs | `NEXTAUTH_SECRET` changed between starts | Pick one, keep it stable, or `docker compose down -v` to clear sessions |
| OTLP requests return 401 | Wrong `LANGFUSE_AUTH_B64` | Check it's `base64("$PK:$SK")` (preflight computes it for you) |
| Traces sent but never appear | Wrong endpoint path | Must end with `/api/public/otel` — NOT `/api/public/otel/v1/traces` (Traceloop appends that itself) |
| UI very slow | First-load NextJS compile | Wait 30s; it caches |

## Why not v3?

| | v2 | v3 |
| - | -- | -- |
| Containers | 2 (web + Postgres) | 6 (web + worker + Postgres + ClickHouse + Redis + Minio) |
| Trace ingestion | OTLP/HTTP, synchronous to DB | OTLP/HTTP → Redis queue → worker → ClickHouse |
| Suitable for | Sandboxes, small teams, learning | Production, high-volume analytics |
| Setup complexity | `docker compose up` | non-trivial; multiple services need first-time setup |

For Phase 1 the lesson is "see traces of an agent run" — v2 delivers that
faster. v3 is on the deferred list.

## What's next

- Phase 1.2: `app/agent.py` initialises OpenLLMetry (`Traceloop.init(...)`)
  pointing at this service. First multi-tool prompt should produce a
  visible trace tree.
- Phase 1.3's walkthrough doc ([docs/02-anatomy-of-a-request.md](../docs/02-anatomy-of-a-request.md))
  uses screenshots from this UI.
