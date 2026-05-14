# Promtail (log scraper)

> Tails every Docker container's stdout/stderr on the host and ships the
> lines to [Loki](../loki/README.md). Labels each stream by compose
> service name so the dashboards can query `{service="litellm"}`,
> `{service="vllm-engine"}`, etc.

## What this is

[Promtail](https://grafana.com/docs/loki/latest/clients/promtail/) is
Grafana Labs' log-shipping agent — the canonical Loki sidecar. We run
it as a separate container with read-only access to the host's Docker
socket; it uses Docker's service-discovery API to enumerate live
containers and tails their log files.

No app changes anywhere — anything emitting to stdout shows up in Loki.

## Why Promtail (and why we'll revisit)

Grafana Labs is in the process of replacing Promtail with
[Alloy](https://grafana.com/oss/alloy/) — a unified agent that does
logs + metrics + traces. Alloy is the future; Promtail enters
maintenance mode in 2026.

We're using Promtail anyway because:

1. **Docker SD is rock solid in Promtail.** Alloy supports it via
   `discovery.docker` but the recipes are still ad-hoc.
2. **The Phase 2.3 lesson is "logs join the party"**, not "migrate
   between agents". Adding Alloy on top would dilute the lesson.
3. **Switching to Alloy later is one PR** (it's a strict superset of
   Promtail's capabilities). We'd lose nothing.

Revisit this post-2026 if Alloy's Docker-SD experience matures and
Promtail's maintenance status starts to bite.

## Configuration walkthrough

[`promtail.yaml`](promtail.yaml) — the only config file.

### Service discovery

```yaml
scrape_configs:
  - job_name: docker
    docker_sd_configs:
      - host: unix:///var/run/docker.sock
        refresh_interval: 5s
```

Promtail polls the Docker socket every 5 s and picks up new containers
within that window. For our slow-changing sandbox that's plenty; bump
to 1 s if you want immediate pickup on `docker compose up <new-service>`.

### Label scheme

Three labels come from Docker SD's metadata, via `relabel_configs`:

| Loki label | Source | Example |
| ---------- | ------ | ------- |
| `service` | `__meta_docker_container_label_com_docker_compose_service` | `litellm`, `vllm-engine`, `langfuse` |
| `project` | `__meta_docker_container_label_com_docker_compose_project` | `llm-stack` |
| `container` | `__meta_docker_container_name` (with leading `/` stripped) | `litellm`, `langfuse-worker` |

We drop containers that don't have a `com.docker.compose.service` label
(one-off `docker run` containers, the Docker proxy, etc.). They'd show
up as `{service=""}` and add noise.

### Pipeline stages

```yaml
pipeline_stages:
  - docker: {}
```

`docker: {}` unwraps Docker's `json-file` log driver format. Without
it, every Loki line looks like
`{"log":"INFO: actually useful content\n","stream":"stdout","time":"..."}`
— readable but ugly. With it, the line content is just the inner `log`
value and the entry timestamp is the docker-recorded `time` (more
accurate than "when Promtail noticed").

## Adding a per-service parser

If you want structured fields on a particular service's logs, add a
service-specific scrape with extra pipeline stages. Example: extract
the HTTP status from LiteLLM's access log lines:

```yaml
  - job_name: litellm-access
    docker_sd_configs:
      - host: unix:///var/run/docker.sock
    relabel_configs:
      - source_labels: ['__meta_docker_container_label_com_docker_compose_service']
        action: keep
        regex: 'litellm'
      - source_labels: ['__meta_docker_container_label_com_docker_compose_service']
        target_label: 'service'
    pipeline_stages:
      - docker: {}
      - regex:
          expression: '"(?P<method>GET|POST) (?P<path>[^ ]+) HTTP/[\d.]+" (?P<status>\d+)'
      - labels:
          method:
          status:
```

That gives you `{service="litellm",method="GET",status="200"}` as
queryable labels. Resist the urge to add high-cardinality fields (paths
with IDs, user IDs) as labels — they explode Loki's index. Use the
log line content for those; query with `|=` (contains) instead.

## Smoke tests

```bash
# Promtail healthy?
docker compose exec promtail wget -qO- http://localhost:9080/ready
# → Ready

# How many targets has it discovered?
docker compose exec promtail wget -qO- http://localhost:9080/targets \
  | grep -c 'docker'

# Promtail's own metrics (lines shipped per service)
docker compose exec promtail wget -qO- http://localhost:9080/metrics \
  | grep '^promtail_sent_entries_total'
```

In Grafana:

```
{service="litellm"}   # LiteLLM access log
{service="vllm-engine"} | json   # vLLM (older versions use plain text; recent ones JSON)
{service="app"}       # Streamlit / LangChain
```

## Where to look when it breaks

| Symptom | Likely cause | Fix |
| ------- | ------------ | --- |
| `{service="X"}` returns nothing | Either container has no `com.docker.compose.service` label, or Promtail can't read `/var/run/docker.sock` | Check that the container was started via compose (not bare `docker run`); confirm Promtail's bind mounts in `docker-compose.yaml` |
| Logs lag by minutes | Promtail's `refresh_interval` too long, or position file out of sync | Lower the SD interval; if a container restarted with a new id Promtail will pick it up within 5 s |
| Lines duplicated after restart | Position file got wiped | Promtail keeps progress in `/tmp/positions.yaml`. Make it survive restarts by moving to a named volume if duplicates become a real problem. We don't bother in the sandbox. |
| `failed to fetch docker container info: permission denied` | Promtail can't read the docker socket | The mount in compose is `:ro`; the socket's group should match Promtail's uid. On rootless docker setups, change the socket path. |
| High Loki ingestion rate after a restart | Promtail re-tailing whole logs because position file lost | Same fix as duplicates above. |

## Direct links

- Loki targets/datasource: <http://localhost:3000/connections/datasources/loki>
- Loki Explore: <http://localhost:3000/explore?left=%7B%22datasource%22%3A%22loki%22%7D>

## What's next

- Phase 2.3's [docs/05-trace-log-correlation.md](../docs/05-trace-log-correlation.md)
  walks through trace ↔ log correlation in practice.
- See [../loki/README.md](../loki/README.md) for the storage side
  (retention, schema, smoke tests against the Loki API).
