# Loki (logs store)

> Third observability pillar — logs alongside metrics (Prometheus) and
> traces (Langfuse). Single-binary deployment backed by the filesystem.
> Promtail tails every container's stdout and ships line by line.

## What this is

[Loki](https://grafana.com/oss/loki/) is a log aggregation system from
Grafana Labs. Unlike Elasticsearch / OpenSearch, it indexes only the
*labels* on each log stream (service, container, project), not the log
content — meaning it's cheap to store and fast to filter by label, at
the price of slower full-text search.

For our sandbox that's the right trade. The dashboards filter by
`{service="litellm"}` and the like; full-text search happens on the
rare occasion we actually `grep` in Grafana Explore.

## Why it's here

Phase 2.3 introduces logs as the third observability pillar. The
headline lesson: **pick a span in Langfuse, copy its wall-clock window,
drop it into Grafana — see the matching LiteLLM access-log line for that
exact request, filterable by `user`**. Two pillars become three; the
cross-pillar workflow gets one more useful surface.

A second lesson: this is the only "single-binary mode for everything"
service in the stack. Production deployments split Loki into
distributor / ingester / querier / compactor on separate processes (so
the read path can scale independently from the write path). For the
sandbox the single binary mode is plenty; the per-component config
shape is identical, just consolidated.

## Configuration walkthrough

[`loki.yaml`](loki.yaml) — the only config file. Highlights:

| Setting | Why |
| ------- | --- |
| `auth_enabled: false` | Single-tenant. Loki normally expects `X-Scope-OrgID` on every request; here we let the default tenant absorb everything. |
| `schema: v13`, `store: tsdb`, `object_store: filesystem` | Modern schema + TSDB index + on-disk chunks. Same shape as a production deployment, just without S3/GCS. |
| `compactor.retention_enabled: true` | Compactor enforces retention. Without it, logs accumulate forever even if `retention_period` is set. |
| `limits_config.retention_period: 168h` | 7 days — mirrors Prometheus's retention so traces, metrics, and logs all age out together. |
| `replication_factor: 1` | Single binary, no peers, no replication. |
| `ring.kvstore.store: inmemory` | No consul/etcd — single binary, ring is local. |

State lives in the `loki-data` named volume (`/loki` inside the
container). On disk: `chunks/` (the log lines, gzipped), `index/`
(daily TSDB shards), `compactor/` (retention worker state).

## Why single-binary (not microservices)

The plan calls this out in §2.3's trade-offs. Loki's microservice mode
buys you horizontal scale; our log volume measured in MB/hour doesn't
need it. The trade-off is that a single-binary Loki won't survive a
write burst that fills one node's memory queue — fine for sandbox
traffic, not for production.

## Smoke tests

```bash
# Ready?
curl -s http://localhost:3100/ready
# → ready

# Has Promtail pushed anything?
curl -s 'http://localhost:3100/loki/api/v1/label/service/values' | jq
# → {"status":"success","data":["litellm","vllm-engine","app",...]}

# Tail the last 10 LiteLLM lines via the API
curl -sG 'http://localhost:3100/loki/api/v1/query_range' \
  --data-urlencode 'query={service="litellm"}' \
  --data-urlencode 'limit=10' \
  | jq '.data.result[0].values[][1]' | head -10
```

In Grafana, the same query is one keystroke:

```
{service="litellm"}
```

in **Explore → Loki**.

## Where to look when it breaks

| Symptom | Likely cause | Fix |
| ------- | ------------ | --- |
| `curl :3100/ready` returns `Ingester not ready: waiting for 15s after being ready` for ages | Cold start; ingester defers ready to give chunks a chance to flush from a previous shutdown | Wait 15-30 s. If it never goes ready, check `docker compose logs loki` for ring errors. |
| Logs visible in `docker compose logs <svc>` but not in Loki | Promtail not scraping that container | Check that the container has a `com.docker.compose.service` label (compose adds it automatically; bare `docker run` containers don't get scraped). |
| `too many outstanding requests` in Loki logs | Query/ingest concurrency cap hit | Raise `limits_config.max_*` knobs. Sandbox defaults should suffice for normal use. |
| Logs older than 7 days missing | Compactor did its job | Bump `limits_config.retention_period`. Note: compactor runs every 10 min; the actual delete lags by `retention_delete_delay` (2 h). |
| `schema_config` validation error after a config edit | Don't change the `from` date or `schema` version once data exists | Either roll forward by appending a new schema config entry, or `docker volume rm llm-stack_loki-data` if you don't mind losing logs. |

## What's next

- Phase 2.3's [docs/05-trace-log-correlation.md](../docs/05-trace-log-correlation.md)
  walks through using the trace ↔ log correlation in practice.
- Promtail's config — what gets scraped and how labels are derived —
  lives in [../promtail/](../promtail/README.md).
