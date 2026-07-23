# homelab-observability — v1 Spec

Status: **agreed, not yet implemented**
Date: 2026-07-19 (amended 2026-07-20 — see [Amendments](#amendments))
Related: [`ffrt-labs/agregado#4`](https://github.com/ffrt-labs/agregado/issues/4) (the producer-side counterpart)

---

## Problem Statement

Four features across the homelab shipped and then silently never worked — each one
discovered by accident, weeks later, by a stray click or a manual `SELECT count(*)`.
There is currently no way to learn that something broke except to go looking for it.

The naive fix is "put all the logs in one searchable place." That is the wrong goal.
**Search only helps someone who is already looking**, and the defining property of these
failures was that nobody was looking. A log search UI would not have caught a single one
of them; it would only have made the eventual archaeology faster.

So the goal of this repo is:

> **Tell me when something broke, without my having to ask.**

Search is the supporting capability that makes an alert actionable. It is not the
deliverable.

---

## Scope

This repo owns exactly one thing: **the observability stack for this home server**. It
does not own application containers, the edge proxy, or backups — those live in their own
repos and deploy independently.

The same principle that governs `homelab-edge` governs this repo: **it must be possible to
onboard an application without touching that application's repository.** Any design that
requires editing every app's `docker-compose.yml` is rejected on those grounds alone.

### The producer contract

Applications emit **structured JSON to stdout** and know nothing else exists. No push, no
in-app agent, no SDK, no in-app storage or UI. The app is oblivious to where its logs go.

This is the single most valuable constraint in the design, because it means the entire
collector can be replaced later without any application changing.

---

## Architecture

Five containers, one repo, one compose file, publishing **no host ports** — Caddy remains
the only way in.

| Service | Role |
|---|---|
| **Alloy** | Collects everything. Three sources (below) |
| **Loki** | Log store. Filesystem backend, 90-day retention |
| **Prometheus** | Container-health metrics only — never application internals |
| **Grafana** | Query UI + alerting engine → Telegram |
| **Canary sidecar** | The out-of-band checks. See [decision 15](#15-network-topology) and [decision 14](#14-dead-mans-switch) |

**Network topology** (amended — see [decision 15](#15-network-topology)): all five join a
private `observability` network. **Only Grafana** also joins the external `edge` network,
where Caddy reaches it. Loki, Prometheus and Alloy are unreachable from any application
container.

Alloy runs three collection paths:

1. **Docker service discovery** (`discovery.docker` + `loki.source.docker`) → container
   logs into Loki.
2. **Built-in cAdvisor exporter** (`prometheus.exporter.cadvisor`) → container metrics
   into Prometheus. No separate cAdvisor container is needed; Alloy ships this natively.
   Linux-only, which is fine for this box.
3. **Docker event stream** → container lifecycle and healthcheck transitions into Loki as
   log lines.

Plus one external dependency, deliberately off-box:

- **Healthchecks.io** — the dead-man's switch. See [Dead-man's switch](#dead-mans-switch).

---

## Decisions

### 1. Alerting is in v1, not deferred to "phase 2"

Everything else in this repo exists to serve alerting. A version of this stack that ships
search-only would reproduce the exact failure mode it was built to eliminate.

### 2. Logs carry the heartbeat, not a metrics endpoint

Absence-detection needs a signal whose *disappearance* is meaningful. Two ways to get one:
logs (a periodic summary line, queried with LogQL range functions) or metrics (a counter,
scraped from a `/metrics` endpoint).

**Chosen: logs.** It preserves the stdout-only producer contract, which is the design's
best property. Metrics are the better tool for "has this number moved," but they are
correct at a scale this homelab does not have, and they are additive later.

> **Known weakness:** absence-alerting on logs is fragile in one specific way — if the
> *collector* breaks, every absence alert fires at once and looks like every app died.
> Prometheus's `up` metric makes "the monitoring broke" self-evident; log-based absence
> detection does not. This is why the [dead-man's switch](#dead-mans-switch) is a
> non-negotiable component rather than a nice-to-have.

### 3. Telegram is the alert channel

**WhatsApp was evaluated first and rejected on structural grounds, not effort:**

- Grafana has no native WhatsApp contact point — it would require a bridge service, i.e.
  custom code sitting directly in the alerting path, the one path that must be more
  reliable than everything it monitors.
- WhatsApp's **24-hour customer service window** only permits free-form messages within 24h
  of the *user* messaging the business. An alert is by definition business-initiated and
  arrives when nobody is looking. So every real alert must be a **pre-approved utility
  template**, charged per delivered message.
- Templates are fixed, pre-approved structures with variable slots — not "send this
  arbitrary string." Alerts want free-form error text, component names, and query links.
- Requires Meta Business verification and a **dedicated phone number** (not the one on
  personal WhatsApp).

Unofficial libraries (`whatsapp-web.js`, Baileys) would work and are free, but violate
WhatsApp's ToS and put the personal number at risk of a ban. Rejected.

**Discord was the runner-up** — setup is a single webhook URL (vs. Telegram's fiddlier
bot-token + chat-ID discovery), and its colour-coded embeds make severity readable at a
glance from a lock screen. It was rejected on **noise**: Discord is a busy app, and an
alert that lands in a stream one has already learned to swipe away is worse than no alert.

Telegram wins because the thing being optimised for is **being noticed**. Setup
inconvenience is a one-time cost; notification noise is permanent.

### 4. Broad collection, narrow alerting

These were conflated in the original framing and are properly independent:

- **Collection** is cheap, mechanical, and best done once. Alloy's Docker discovery is the
  same config whether it covers one container or twenty.
- **Alerting** is where all the judgement lives.

Loki does **not** require JSON. It stores raw lines indexed by labels; JSON parsing is a
*query-time* operation (`| json`). Structure buys better queries and reliable alerts — it
is not the price of admission for collection. So an unstructured Postgres line and a
structured application line sit side by side, both searchable, both labelled.

Therefore: **collect from every container from day one**, alert on almost none of them.
The first time an app breaks *because RabbitMQ did*, the correlation is already recorded.

**Pi-hole is excluded** — it logs every DNS query on the network and would dwarf everything
else combined. Reversible with one config line if DNS forensics is ever wanted.

### 5. Alloy + Docker service discovery, not the Docker log driver

| Option | Verdict |
|---|---|
| **Docker Loki log driver** | **Rejected.** Requires editing every app's compose file in every separate repo — the exact cross-repo coupling this design forbids. Also breaks `docker logs`, removing the debugging tool of last resort when Loki itself is broken. And if Loki is down or slow, the driver can block the container or drop logs — the monitoring becomes a liability for the apps it monitors. |
| **Alloy reads JSON files off disk** | **Rejected.** Yields container IDs, not names; the mapping breaks every time a container is recreated. Metadata is the whole point of labels. |
| **Alloy + Docker service discovery** | **Chosen.** Container names, image names, compose service and labels for free. Zero changes to any other repo, ever. `docker logs` keeps working. If Loki dies, Alloy buffers and retries; apps never notice. |

> **Accepted risk:** Alloy needs the Docker socket. Even mounted `:ro`, **socket access is
> root-equivalent on the host** — anything that can talk to the Docker API can start a
> privileged container. Mitigations for v1: mount `:ro`, pin the Alloy image to a digest
> (never `latest`), never expose Alloy's HTTP port outside the Docker network. A
> `docker-socket-proxy` sidecar whitelisting only the read endpoints is the stricter
> option and is a drop-in upgrade — deferred, because this is a LAN-only box with no
> untrusted workloads.

### 6. Configuration lives in Git; the Grafana volume is disposable

By default Grafana stores dashboards, alert rules, contact points and notification
policies in an internal SQLite DB inside a Docker volume. That is unacceptable here: the
thing whose entire job is catching silent failures would itself be invisible to `git log`,
unreviewable, undiffable, and one `docker compose down -v` from total loss.

**Chosen split:**

- **Provisioned from Git immediately:** Loki datasource, Prometheus datasource, Telegram
  contact point, notification policy. These are write-once and never tuned.
- **Built in the Grafana UI, then exported to YAML and committed:** alert rules and
  dashboards. Thresholds genuinely need iteration against real log volume, and forcing
  that round-trip through Git commits would mean tuning them less than one should.

Grafana has a built-in **Export → YAML** for both alert rules and dashboards; the workflow
is "build it by clicking, export, commit."

> **This is the weakest joint in the design.** "Export it later" is exactly the kind of
> task that never happens, at which point one is storing config in a volume while
> believing it is in Git — and [decision 13](#13-no-backups) becomes actively dangerous.
> **The export must happen before the v1 branch merges.** Not "someday."

### 7. Retention, and not becoming the outage

**Loki does not delete anything by default.** Retention is off unless the compactor is
explicitly configured with `retention_enabled: true`. The default configuration of this
stack is therefore "grow until the disk is full" — on a disk shared with Postgres,
RabbitMQ, and every app on the box.

The realistic worst case for this project is not a bad dashboard. It is filling the root
filesystem at 2am and taking down every application simultaneously. **The observability
stack becomes the outage.**

- **Storage:** filesystem (TSDB index + filesystem chunks), single-binary Loki. MinIO/S3
  would be a second stateful service to run and back up, for a workload measured in tens
  of MB/day.
- **Retention: 90 days.** Retention must exceed detection latency; alerting collapses that
  to minutes, but the first question after any alert is *"when did this start?"* — and
  that question is worthless if history stops at a week. At ~50 MB/day compressed this is
  ~4.5 GB against 200 GB of disk: under 3%. The binding constraint is query performance,
  not space.
- **Per-stream rate limits** (`ingestion_rate_mb`, `per_stream_rate_limit`) set generously
  above normal peak, so one crash-looping container gets throttled rather than absorbed.
  Retention is time-based; a log-spam bug is volume-based and will outrun any time window.
- **Named volumes**, not bind mounts into the application filesystem.

> **Accepted trade-off:** aggressive rate limits mean that during a genuine incident —
> exactly when logs matter most — some lines may be dropped. This is a real cost, not a
> theoretical one. It is accepted because an unthrottled ingest path during that same
> incident is precisely how the disk fills.

**The host disk alert (>80%) ships before any application alert.** It is the alert that
protects everything else.

### 8. Grafana behind Caddy, LAN-only

- Route: `grafana.<EDGE_BASE_DOMAIN>` → `reverse_proxy grafana:3000`.
- Real TLS via the existing wildcard cert. No new DNS record, no new cert, no host port.
- **Admin password injected as `GF_SECURITY_ADMIN_PASSWORD` from a GitHub Actions secret.**
  Anonymous access explicitly disabled. Sign-up disabled.

Why not leave `admin/admin` on a LAN-only box: this server runs a **self-hosted GitHub
Actions runner**. Any workflow on it — including one from a compromised dependency or
action — executes *inside* the LAN, behind Caddy. "LAN-only" is not the isolation boundary
it feels like. And Grafana with admin rights can query Loki, which now holds logs from
every application; given that `agregado#4` exists partly *because* the app was printing its
database password and Cloudflare token to stdout, old log lines may already contain
secrets.

Localhost-binding + SSH tunnel was rejected: it breaks the phone-to-investigation path,
and a Telegram alert at 11pm is useless if acting on it requires opening a laptop. Public
exposure via Cloudflare tunnel was rejected outright.

> **This requires the one legitimate cross-repo change:** a PR to `homelab-edge` adding a
> `@grafana` host matcher and handle block, plus joining the `edge` network. This is by
> design — that Caddyfile is deliberately the single file answering "what does this server
> serve."

### 9. No application-specific alerts in v1

An earlier draft of this spec included alerts like "zero articles ingested in 24h." Those
are **one application's business logic wearing a platform costume**, and baking them into
the platform's v1 would couple this repo to a single app — the same mistake as the Docker
log driver.

The correct distinction:

- **Generic alerts** — work on *any* container, require zero domain knowledge. These are
  platform features and belong here.
- **Business-logic alerts** — require per-app knowledge. These belong to a **per-app
  onboarding step**, not to this repo's v1.

### 10. The v1 alert set

All app-agnostic. Ordered by priority — **not** by ship sequence; for that see
[Roadmap](#roadmap).

| # | Alert | Catches | Channel |
|---|---|---|---|
| 1 | Host disk > 80% | The stack becoming the outage | Healthchecks.io → email |
| 2 | Dead-man's switch stops pinging | Box dead, Loki dead, Alloy dead, pipeline broken | Healthchecks.io → email |
| 3 | Any container gone / not running | Crash loops, OOM kills, failed deploys | Grafana → Telegram |
| 4 | Any container reports unhealthy | Running but broken | Grafana → Telegram |
| 5 | Any container emitting `ERROR` | Presence of failure | Grafana → Telegram |

**Alerts 1 and 2 are deliberately out-of-band** (amended). Both are inverted heartbeats
run by the canary sidecar and delivered by Healthchecks.io over email, with no dependency
on Prometheus, Grafana, or Telegram.

The reasoning is the same for both. The disk-full scenario is precisely the one where Loki
cannot write chunks, Prometheus cannot write blocks, and Grafana cannot write its SQLite —
so routing alert 1 *through* that stack asks it to report the condition that breaks it.
Alert 2 has the same shape by definition. A monitoring stack must not be the delivery path
for the alerts about its own death. This extends decision 14's "notifies by email, not
Telegram" reasoning from one alert to both.

**Two design stances, adopted deliberately:**

**(a) Alert on *any* `ERROR`, not on a rate threshold.** This is aggressive and will be
noisy if an app logs recoverable problems at `ERROR`. That is treated as a *feature*: it
forces the discipline that **`ERROR` means "a human should look,"** with retries and
transient blips at `WARN`. Starting with a rate threshold lets `ERROR` decay into
background noise, which is how one ends up back at the original problem. The cost is
re-levelling some log statements in the apps — that is the work, not a distraction from it.

**(b) Notification throttling is mandatory.** A crash loop emitting 10k errors must produce
*one* Telegram message. Grafana notification policy: group by alert rule, `group_interval`
~5m, `repeat_interval` ~4h so an unresolved problem re-nags without spamming. **Without
this, (a) is dangerous.**

> **Best-effort caveat:** only well-behaved producers emit a parseable `level`. Postgres,
> RabbitMQ and others emit their own formats, so alert #5 falls back to substring matching
> on them. The generic error alert is therefore *reliable* on structured producers and
> *best-effort* elsewhere — which is exactly the incentive the onboarding contract exists
> to create.

### 11. Both Prometheus and Docker-events-to-Loki

Container health needs a signal Loki does not have. Two mechanisms, with genuinely
different failure characteristics:

- **Prometheus + Alloy's cAdvisor exporter** — **level-triggered**. A dead container is
  simply absent from every subsequent scrape, so the failure is discovered *late* rather
  than *never*. Does **not** expose Docker's healthcheck verdict; `container_last_seen`
  gives presence, not health.

  > **Correction (amended).** An earlier draft implied cAdvisor would also serve the host
  > disk alert. It does not: cAdvisor exposes *per-container* filesystem stats
  > (`container_fs_*`), never host filesystem usage. `node_filesystem_avail_bytes` comes
  > from node exporter — in Alloy, `prometheus.exporter.unix`. As originally written, the
  > highest-priority alert in v1 had no data source. That alert has moved out-of-band
  > (decision 10); `prometheus.exporter.unix` is still adopted, but for **dashboards and
  > trends**, not for alert 1.
- **Docker events → Loki** — **edge-triggered**. Captures `container die` and
  `health_status: unhealthy` transitions, closing the healthcheck gap cAdvisor leaves. But
  if Alloy is down when a container dies, that event is gone forever and nothing ever
  reports it.

**Both are adopted**, sequenced: Prometheus first (it is the load-bearing half, and
level-triggered detection cannot be retrofitted cheaply), then Docker events in the same
v1 — cheap, since it is an extra Alloy source block into a store already running. The
dead-man's switch covers the events path's blind spot, which makes the combination sound
rather than merely redundant.

Events-to-Loki *alone* was rejected: a monitoring system that can permanently miss the
event it exists to catch has the same silent-failure shape as the original problem.

> This adds metrics to a design that started logs-only. It does **not** violate the
> producer contract: these are facts observed *about* containers by the platform, never
> emitted *by* an application.

### 12. Label schema

Loki labels are the one thing genuinely painful to change later — every unique label-value
combination is a separate stream, and labels are baked into chunks at write time, so
revising the schema does not fix existing data.

**Labels** (things streams are selected by, with small bounded value sets):

- `container` — container name.
- `compose_service`, `compose_project` — free from Docker discovery. `compose_project`
  gives "everything in this app's stack, including its Postgres and RabbitMQ," which is
  precisely the correlation decision 4 exists to enable.

**Not labels:**

- `article_id`, `source_id`, request IDs, user IDs — unbounded, the classic way to blow up
  a Loki index. Line fields, queried with `| json | article_id="123"`.
- `component` — low-cardinality per app, but it is *app-specific vocabulary*; promoting it
  would make the platform's schema depend on one application's internals. Query-time
  filter.
- `level` — bounded, and labelling it would make the `ERROR` alert a cheap stream selector.
  Rejected anyway: **Loki 3.x structured metadata** attaches `level` efficiently without a
  5× stream multiplication.

> **Accepted trade-off:** the risk here is asymmetric toward *under*-labelling. If a
> particular query filter turns out to be constantly repeated, promoting it to a label
> later will not backfill old data. Minimal is still right at this scale, but it is a real
> trade rather than a free win.

### 13. No backups

Three volumes, all deliberately unprotected:

- **Grafana** — disposable cache. Git is the source of truth (decision 6). *Conditional on
  the export step actually happening.*
- **Loki** — 90 days of logs, ~5 GB.
- **Prometheus** — container metrics.

Telemetry is inherently regenerable and time-decaying. Losing 90 days of logs costs the
ability to answer "when did this start" for incidents almost certainly already resolved.
The data's value halves every week; backing it up is effort better spent elsewhere. **The
thing that must survive a rebuild is the configuration, and that is in Git.**

**Corollary, and a genuinely useful property:** `docker compose down -v` on this repo is a
supported, non-destructive operation. The whole stack can be rebuilt fearlessly — which
cannot be said of any application's Postgres.

> **When this flips:** losing Prometheus data hurts more than losing logs, because
> baselines are cumulative — "is this CPU usage normal for a Tuesday" needs months of
> history that cannot be regenerated. If this stack is ever used for capacity or trend work
> rather than pure alerting, revisit.

### 14. Dead-man's switch

The only defence against "the monitoring is dead and therefore silent" — the failure mode
that makes every other alert here unreliable. **What triggers the ping determines what it
actually proves.**

**Rejected — the naive heartbeat.** A sidecar that `curl`s the ping URL every 5 minutes
proves only that the box has power, Docker runs, and the internet works. It does **not**
prove Alloy is collecting or Loki is ingesting. Alloy could be silently crash-looping and
this would ping happily forever. This is the version most people build, and it produces a
comfortable green checkmark certifying almost nothing.

**Chosen — the end-to-end canary.** Every 5 minutes, a small script queries Loki's API for
the count of lines received in the last 5 minutes. **It pings only if the count is > 0.**
Zero, or a failed query, means no ping, and the external service raises the alarm.

This proves the entire chain in a single signal: containers → Docker socket → Alloy →
Loki → query API. It is the only bespoke code in the stack (a `curl` + `jq` loop), and
that cost is accepted because this component's entire purpose is to be the one thing
trustworthy when everything else is lying.

**Two riders:**

- **Hosted, never self-hosted.** Healthchecks.io free tier or equivalent. A watcher on the
  same box dies with the box and proves nothing. This is the design's only third-party
  dependency, and the dependency is the point.
- **Notifies by email, not Telegram.** Deliberately a *different* channel from the primary
  path — if the failure is "the box lost internet," a Telegram alert that never arrives is
  worthless. Healthchecks.io sends from its own infrastructure.

**Where it runs (amended):** a sidecar container in this repo's compose file, not a host
crontab. Host cron would put load-bearing monitoring logic in host state that no repo owns
and no `git log` records — Open Risk 1 wearing a different hat. The sidecar reaches
`loki:3100` over Docker DNS with no host port, and, decisively, **its own death is covered
by the thing it feeds**: if it stops, pings stop, and Healthchecks.io raises the alarm. A
dead cron job is silent.

The same sidecar runs the disk check, with the host root filesystem bind-mounted
read-only. That is a second privileged-ish mount alongside the Docker socket; accepted on
the same grounds as decision 5, and strictly less dangerous than the socket.

A `sleep 300` loop drifts and has no jitter. Grace periods (~15m against a 5m schedule)
are set deliberately rather than left at their defaults.

### 15. Network topology

*Added 2026-07-20.*

The original text said the stack joins the external `edge` network. Read literally, all
containers do. That is rejected.

`edge` is **shared**: `mycoach` and `agregado` are on it today and every future app will
be, and Docker's internal DNS resolves service names across it. Single-binary Loki runs
with `auth_enabled: false`, so any container on `edge` could
`curl http://loki:3100/loki/api/v1/query` and read everything. Decision 8 already
establishes that these logs may contain database passwords and Cloudflare tokens from
`agregado`'s stdout. Putting an unauthenticated read API for every secret on the box onto
the same network as every application would negate the argument for a strong Grafana
admin password that decision 8 spends three paragraphs making. The same applies to
Prometheus and to Alloy's HTTP port — which the spec already says must never be exposed
outside the Docker network, a statement inconsistent with joining the shared one.

**Chosen:** a private `observability` network for all five services; Grafana dual-homed
onto `edge` as well. Caddy reaches Grafana; nothing else reaches anything. Cost: one extra
`networks:` entry. It reduces the blast radius of a compromised app container from "can
read every log line this server has ever produced" to "can talk to Caddy."

Loki `auth_enabled` / multi-tenancy is **deferred**, filed next to `docker-socket-proxy`
as a drop-in hardening upgrade once nothing can route to it.

> **Not solved by this.** Alloy still holds the Docker socket and the canary sidecar now
> holds the host root filesystem. Network isolation touches neither.

### 16. Host-memory check

*Added 2026-07-23, after task 1 shipped.*

A third out-of-band canary check, alongside the disk check, watching total host memory.

It earns the out-of-band slot on the **same** grounds as disk (decision 10): a box
exhausting memory OOM-kills processes and thrashes swap, and what the kernel kills may be
Loki, Alloy or Grafana. The condition degrades the very stack that would report it, so it
cannot be alerted on *through* that stack — it has to be watched from outside. This is the
one property that distinguishes it from per-container memory, which is ordinary metrics
work for Prometheus in task 3.

**Signal: `MemAvailable`, nothing else.** Not "used" — Linux fills free RAM with
reclaimable disk cache, so "used" reads ~90% on a healthy box and any naive threshold
screams constantly. `MemAvailable` is the kernel's own estimate of what is reclaimable for
new work, so a low value is the leading edge of the thrashing being guarded against. Swap
rate was considered and rejected: sampling a rate over time is metrics-with-history work,
which is precisely what Prometheus is for, and the canary must stay the one dumb,
trustworthy thing — a single `/proc/meminfo` read keeps it that way.

**Threshold: ping while `MemAvailable` ≥ 10% of `MemTotal`**, configurable via
`MEM_MIN_AVAIL_PCT`. Percentage, not an absolute floor, to match the disk check's idiom and
survive a RAM change without re-tuning.

**Sustained, not instantaneous.** Memory dips and recovers constantly, so this is a
"sustained exhaustion" alarm: the 5-minute interval against a 15-minute grace means memory
must sit below the floor for ~3 consecutive checks before Healthchecks.io fires. A deploy
spike will not page anyone. The exact instant of an OOM kill is caught instead by task 3's
container-down alert — the two are complementary, which is the point.

> **Accepted trade-off:** on a box with lots of swap, `MemAvailable` can dip below the
> floor while swap is still absorbing the load — so this can fire somewhat early. Erring
> early is the right direction given the risk it guards is the box falling over entirely.

Reads `/proc/meminfo`, which is not namespaced in a container and therefore reports the
host's physical memory directly — no extra mount needed.

---

## Roadmap

Ship sequence, distinct from the alert priority ordering in decision 10. Each task ends in
a state that is verifiable rather than merely deployed.

### Task 1 — logs land, and the pipeline can say when it stops

Alloy + Loki + Grafana + canary sidecar. Broad collection from every container except
Pi-hole. Grafana behind Caddy. Both out-of-band alerts live. CI deploy with a secrets
guard.

Deliberately **not** the four containers standing up doing nothing observable: that is the
maximally deferrable state — nothing proves the design works and nothing hurts if it
stops. This slice front-loads the two riskiest unknowns (the Docker socket path and the
cross-repo Caddy change) instead of saving them.

Retention and rate limits are **in task 1**, not deferred. Broad collection is where
volume surprises live, and decision 7's failure mode is filling the root filesystem.

Out of scope for task 1: Prometheus, cAdvisor, `prometheus.exporter.unix`, Docker events,
Telegram, every Grafana alert rule, the README onboarding contract.

### Task 2 — the Telegram path, proven on the alert that needs nothing new

Telegram bot, contact point, notification policy (`group_interval` ~5m, `repeat_interval`
~4h), and alert 5 — which requires only Loki, already delivered. Exported to YAML and
committed.

**Before Prometheus, contradicting decision 11's sequencing**, for three reasons. The
notification policy is the highest-risk piece of the alerting design and has nothing to do
with Prometheus; decision 10(b) makes throttling mandatory precisely because 10(a) is
otherwise dangerous, and alert 5 across every container is the alert most likely to
produce a flood. Discover that on the alert you can disable in one commit, not while
simultaneously debugging a new Prometheus deployment. Second, it forces the Git-export
workflow to happen once, early, on a single small rule — Open Risk 1, addressed by habit
rather than by a merge blocker across five rules. Third, alert 5's noise is what tells you
which apps need their log levels re-levelling, and that generates work in other repos.

Accepted gap: container-down detection waits one more task. The canary already covers "the
pipeline stopped" and the disk check covers "the box is filling."

### Task 3 — the metrics layer

Prometheus, `prometheus.exporter.cadvisor`, `prometheus.exporter.unix`, Docker events →
Loki. Alerts 3 and 4, slotting into machinery already proven in task 2.

### Task 4 — the onboarding contract

The README deliverable: what an application must emit to earn alerts. This is where Open
Risk 2 is either addressed or quietly abandoned.

---

## Out of Scope

- **Application-specific alerts.** Per-app onboarding, not platform v1.
- **Alerting on mycoach, Postgres, RabbitMQ, Caddy.** Collected and searchable; not
  alerted. Their normal baselines are unknown, and alert fatigue in week one would kill the
  project.
- **Distributed tracing.** No demonstrated need.
- **Backups.** See decision 13.
- **Public exposure.** LAN-only via Caddy.
- **`docker-socket-proxy` hardening.** Drop-in upgrade, deferred.
- **Pi-hole DNS query logs.** Volume, not principle. Reversible.

---

## Deliverables

1. This repo: `docker-compose.yml`, Alloy config, Loki config, Prometheus config,
   provisioned Grafana config (datasources, contact point, notification policy), the canary
   script, and `.github/workflows/deploy.yml` mirroring `homelab-edge` (self-hosted runner,
   push to `main`, `.env` written from Actions secrets, `docker compose up -d
   --force-recreate --remove-orphans`).

   **Two additions to the workflow (amended):**

   - **A PR-triggered validation job** — `docker compose config -q` plus Alloy config
     validation. Push-to-`main`-deploys is kept; no review gate is added. This catches the
     likeliest failure, a malformed Alloy config that crash-loops on the box while nobody
     is watching, without pretending to simulate a Linux host that cannot be simulated
     (cAdvisor is Linux-only, and `df` on a bind-mounted macOS root is meaningless). The
     spec's `docker compose down -v` property, not a local rig, is the real safety net.
   - **A guard step that fails loudly on any missing or blank secret or var**, before
     `docker compose up`. The motivating case: `GF_SECURITY_ADMIN_PASSWORD` is honoured
     **only when Grafana initialises its database**. Deploy once without it and Grafana
     writes `admin/admin` into the volume; setting the variable afterwards changes
     nothing. The result is a compose file that plainly sets a strong password, on a
     Grafana that still accepts `admin/admin`, with nothing anywhere to say so — this
     repo's own failure mode, inside this repo's own security control. A stack that
     catches silent failures everywhere except its own deploy pipeline is the joke
     telling itself.
2. Exported alert-rule YAML committed to this repo **before v1 merges**.
3. A PR to `homelab-edge` adding the `@grafana` handle block.
4. A README containing the **onboarding contract**: what an application must emit to earn
   alerts.

---

## Open Risks

These are recorded as *unsolved*, not as things the design handles.

### 1. The Git-export step is the weakest joint

Decision 6's compromise — iterate in the UI, export to Git — degrades silently into
"alerting config lives only in a Docker volume" if the export does not happen. At that
point decision 13 (no backups) turns from correct into dangerous, and nothing will signal
that it has. **Mitigation: treat the export as a merge blocker for v1.**

### 2. The per-app work is where the value actually lands

Descoping application alerts (decision 9) was correct for the platform's design, but it
means **this repo alone does not solve the original problem.** A generic `ERROR` alert
would not have caught any of the four original failures: an RSS fetch returning zero
articles emits no error at all. It emits *silence*, which is indistinguishable from "idle
and fine."

Until at least one application is onboarded with a business-level absence rule, this stack
is a precondition for the fix, not the fix. **If "connect specific apps later" quietly
never happens, this repo is search-only — the outcome explicitly rejected in decision 1.**

### 3. A pending landmine in `agregado#4`

Absence alerting consumes a periodic success signal. `agregado#4`'s user story 15 —
*"successful-message chatter removed (or demoted below the default level)"* — **deletes
exactly that signal**, leaving an app that can only be observed when it errors.

The amendment (keep low-volume per-cycle summary lines such as
`poll_complete source_id=X articles_new=3` at `info`, as distinct from one line per
message) is now part of per-app onboarding rather than this repo's v1. Not a v1 blocker.
It is a landmine for whoever onboards that app.

---

## Amendments

### 2026-07-20 — roadmap planning

Five changes, agreed before any implementation began. Recorded here so the spec and the
build do not disagree from day one.

| # | Change | Where |
|---|---|---|
| 1 | cAdvisor cannot serve the host disk alert; `prometheus.exporter.unix` added, for dashboards rather than for alert 1 | [Decision 11](#11-both-prometheus-and-docker-events-to-loki) |
| 2 | Alerts 1 and 2 move out-of-band to Healthchecks.io email, off the Grafana/Telegram path | [Decision 10](#10-the-v1-alert-set), [14](#14-dead-mans-switch) |
| 3 | Private `observability` network; only Grafana joins shared `edge` | [Decision 15](#15-network-topology) |
| 4 | Ship order is Telegram before Prometheus, contradicting decision 11's sequencing | [Roadmap](#roadmap) |
| 5 | Canary runs as a compose sidecar, not host cron; PR validation job and secrets guard added to CI | [Decision 14](#14-dead-mans-switch), [Deliverables](#deliverables) |

Changes 1 and 3 are corrections — the spec as written was wrong. Changes 2, 4 and 5 are
decisions the spec had not reached.

### 2026-07-23 — during task 1 deployment

| # | Change | Where |
|---|---|---|
| 6 | A new DNS `A` record **is** required per app — the DNS records on this box are per-app, not wildcard, even though the TLS cert is wildcard. Decision 8's "no new DNS record" was wrong for this box. | [Decision 8](#8-grafana-behind-caddy-lan-only), [Deliverables](#deliverables) |
| 7 | A third out-of-band canary check for host memory (`MemAvailable` ≥ 10% of total) | [Decision 16](#16-host-memory-check) |

Change 6 is a correction found when `grafana.<domain>` returned no DNS at all; the wildcard
that decision 8 assumed does not exist. Change 7 is a new decision, added after task 1 had
shipped and was running.
