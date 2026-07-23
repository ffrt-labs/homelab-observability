# homelab-observability

The observability stack for this home server. Four containers, one compose file, and two
alerts that arrive without anyone having to go looking.

`SPEC.md` is the design of record, including its **Amendments** section. This README covers
running the thing.

## Scope

This repo owns exactly one thing: the observability stack. It does **not** own application
containers, the edge proxy, or backups — those live in their own repos and deploy
independently.

The governing constraint, shared with `homelab-edge`: **it must be possible to onboard an
application without touching that application's repository.** An app is onboarded by
existing. It emits structured JSON to stdout and knows nothing else exists — no push, no
agent, no SDK. That constraint is the design's best property, because it means this entire
collector can be replaced later without any application changing.

## What ships today

Task 1 of the [roadmap](SPEC.md#roadmap). Collection, search, and the two out-of-band alerts.

| Service | Role |
|---|---|
| **Alloy** | Reads container logs via Docker service discovery, ships them to Loki |
| **Loki** | Log store. Filesystem backend, 90-day retention, per-stream rate limits |
| **Grafana** | Query UI, at `grafana.<EDGE_BASE_DOMAIN>` behind Caddy |
| **canary** | The dead-man's switch, the disk check, and the host-memory check |

Not yet: Prometheus, container metrics, Docker events, Telegram, and every Grafana alert
rule. Those are tasks 2 and 3.

## How it works

- **Collection is automatic and repo-free.** Alloy uses `discovery.docker`, so every
  container on the box is collected the moment it exists — no compose edits anywhere, and
  `docker logs` keeps working as the debugging tool of last resort. Pi-hole is excluded
  because it logs every DNS query on the network and would dwarf everything else combined;
  deleting one rule in `alloy/config.alloy` reverses that.
- **Three labels, and only three:** `container`, `compose_service`, `compose_project`.
  Labels are baked into chunks at write time, so the schema cannot be revised retroactively
  — the risk is deliberately taken toward under-labelling. Everything else is a line field,
  queried with `| json` at query time.
- **Retention is on.** Loki deletes nothing by default, so an unconfigured stack grows until
  the root filesystem is full — on a disk shared with Postgres, RabbitMQ and every app here.
  The compactor runs with `retention_enabled: true` at 90 days, and per-stream rate limits
  keep one crash-looping container from being absorbed.
- **Only Grafana is reachable.** Loki, Alloy and the canary sit on a private `observability`
  network. Single-binary Loki runs `auth_enabled: false`, so putting it on the shared `edge`
  network would give every application container an unauthenticated read API over every log
  line on the server.
- **Three inverted heartbeats.** The canary pings Healthchecks.io only while it can prove
  things are healthy; the *absence* of a ping is the alarm. All notify by **email**, not
  Telegram — if the failure is "the box lost internet", a Telegram alert that never arrives
  is worthless.

| Check | Pings only if | Proves |
|---|---|---|
| Pipeline | Loki reports > 0 lines in the last 5 minutes | containers → Docker socket → Alloy → Loki → query API |
| Disk | host disk usage is below 80% | the box is not about to take every app down at once |
| Memory | host `MemAvailable` is ≥ 10% of total | the box is not about to OOM-kill and thrash |

The disk and memory checks are both out-of-band for the same reason: a full disk or an
exhausted box degrades Loki, Prometheus and Grafana themselves, so neither condition can be
alerted on *through* the stack — the reporter is what breaks.

The pipeline check is deliberately not a naive heartbeat. A sidecar that curls a URL every
five minutes proves only that the box has power and the internet works — Alloy could be
silently crash-looping and it would ping happily forever.

The disk check applies the same suspicion to itself. It refuses to report on a filesystem
implausibly smaller than the host root it is supposed to be watching (`DISK_MIN_TOTAL_KB`,
default 10 GB) — because a lost or misdirected host mount otherwise yields a perfectly
valid, permanently healthy number. It fails closed and emails you instead.

The memory check reads `MemAvailable` from `/proc/meminfo` (not "used" — Linux fills free
RAM with reclaimable disk cache, so "used" reads ~90% on a healthy box). It is a *sustained
exhaustion* signal: a momentary spike during a deploy won't page you, because the 5-minute
interval against a 15-minute grace means memory must sit below the floor for roughly three
consecutive checks before Healthchecks.io alarms. The exact instant of an OOM kill is
caught instead by the container-down alert in task 3 — the two are complementary. Tune the
floor with `MEM_MIN_AVAIL_PCT` (default 10).

## One-time setup

1. **Healthchecks.io** (free tier) — create **three** checks:
   - All: **Period 5 minutes, Grace 15 minutes**, notify by **email**.
   - Name them something like `homelab-log-pipeline`, `homelab-disk` and `homelab-memory`.
   - Copy each ping URL.
2. **A DNS record for Grafana.** Unlike the TLS cert (a wildcard), the DNS records on this
   box are per-app. Add an `A` record `grafana` → your server's LAN IP, **DNS only (grey
   cloud)** — the same record every other app already has.
3. **GitHub repo settings** → Settings → Secrets and variables → Actions:
   - **Variables**: `EDGE_BASE_DOMAIN` = your bare domain (must match `homelab-edge`).
   - **Secrets**: `GF_SECURITY_ADMIN_PASSWORD`, `HC_PING_URL_PIPELINE`, `HC_PING_URL_DISK`,
     `HC_PING_URL_MEMORY`.

   > **Set `GF_SECURITY_ADMIN_PASSWORD` before the first deploy.** Grafana honours it only
   > when it initialises its database. Deploy once without it and the volume holds
   > `admin/admin` forever, while the compose file continues to show a strong password.
   > The deploy workflow refuses to start when it is blank, but the guard only helps if it
   > is in place before the first run. Recovery is `docker compose down -v`, which is safe
   > here — the Grafana volume is a disposable cache and Git is the source of truth.
4. **Merge the `@grafana` route in `homelab-edge`.** Grafana publishes no host port; Caddy
   is the only way to reach it. That PR restarts Caddy for every app on the box, so do it
   once, deliberately.
5. Push to `main`.

## Verification

The Loki and Grafana images are distroless — no shell, no `curl` — so these run from the
canary container, which has both and sits on the same private network.

```bash
# Everything is up, and Loki reports ready
docker compose ps
docker compose exec canary curl -sf http://loki:3100/ready

# Retention is actually running — not merely spelled correctly in the config
docker compose logs loki | grep -i compactor
docker compose exec canary curl -s http://loki:3100/config | grep -E 'retention_enabled|retention_period'

# Lines are arriving, and every label is populated
docker compose exec canary sh -c \
  "curl -sG --data-urlencode 'query=sum by (container, compose_service, compose_project) (count_over_time({container=~\".+\"}[5m]))' \
   http://loki:3100/loki/api/v1/query"

# The canary's own reasoning, including every NOT pinging path
docker compose logs canary

# Grafana is healthy and rejects the default credentials
docker compose exec canary curl -s http://grafana:3000/api/health
docker compose exec canary curl -s -o /dev/null -w '%{http_code}\n' \
  -u admin:admin http://grafana:3000/api/datasources     # expect 401

# From any LAN machine
curl -sk -o /dev/null -w '%{http_code}\n' https://grafana.<EDGE_BASE_DOMAIN>
```

### Exercising the alarm

The checks above confirm things work. Only this confirms that something *breaking* reaches
you — which is the only claim this repo actually makes. An unexercised dead-man's switch is
a comfortable green checkmark certifying nothing.

```bash
docker compose stop canary
# wait out the 15-minute grace period; both Healthchecks.io checks should
# go red and email you
docker compose start canary
```

## Tests

The canary is the only bespoke code in the stack, so it is the one thing with an automated
test. It runs against a **real Loki**, with the ping URLs pointed at a stub that records
what it receives:

```bash
test/run-tests.sh      # requires a running Docker daemon
```

Four of the five cases assert that **no** ping is sent — on a silent pipeline, on an
unreachable Loki, and on a disk over threshold. That inversion is the point: a canary that
pings when it should not is strictly worse than no canary, because it converts an outage
into a reassurance.

It also runs on every pull request, alongside `docker compose config`, Alloy config
validation and shellcheck. Those PR jobs run on GitHub's runners, never on the self-hosted
one — that runner executes inside the LAN, and pull-request code has no business there.

## Backups

None, deliberately. Telemetry is regenerable and time-decaying; the thing that must survive
a rebuild is the configuration, and that is in Git. **`docker compose down -v` on this repo
is a supported, non-destructive operation** — which cannot be said of any application's
Postgres.

## Known accepted risks

- **Alloy holds the Docker socket.** Mounted `:ro`, but socket access is root-equivalent on
  the host regardless: anything that can talk to the Docker API can start a privileged
  container. Mitigated by the read-only mount, an image pinned by digest, and never
  exposing Alloy's HTTP port. A `docker-socket-proxy` sidecar is the stricter option and a
  drop-in upgrade — deferred.
- **The canary holds a read-only host root mount**, so `df` measures the disk that matters.
  Accepted on the same grounds, and strictly less dangerous than the socket.
- **Loki runs `auth_enabled: false`**, acceptable only because of the network split above.
- **Rate limits can drop lines during a genuine incident** — exactly when logs matter most.
  A real cost, accepted because an unthrottled ingest path during that same incident is
  precisely how the disk fills.

## Why this exists

Four features across the homelab shipped and then silently never worked, each discovered by
accident weeks later. The tempting fix is "put all the logs in one searchable place", but
**search only helps someone who is already looking**, and the defining property of these
failures was that nobody was looking. So the goal is:

> Tell me when something broke, without my having to ask.

Search is the supporting capability that makes an alert actionable. It is not the
deliverable — and this repo alone is not yet the fix. A generic pipeline would not have
caught any of the four original failures: an RSS fetch returning zero articles emits no
error at all, it emits *silence*. Until at least one application is onboarded with a
business-level absence rule, this stack is a precondition for the fix. See
[Open Risk 2](SPEC.md#2-the-per-app-work-is-where-the-value-actually-lands).
