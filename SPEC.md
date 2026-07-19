# homelab-observability — v1 Spec

Status: **agreed, not yet implemented**
Date: 2026-07-19
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

Four containers, one repo, one compose file. Joined to the external `edge` network,
publishing **no host ports** — Caddy remains the only way in.

| Service | Role |
|---|---|
| **Alloy** | Collects everything. Three sources (below) |
| **Loki** | Log store. Filesystem backend, 90-day retention |
| **Prometheus** | Container-health metrics only — never application internals |
| **Grafana** | Query UI + alerting engine → Telegram |

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

All app-agnostic. Ordered by ship sequence:

| # | Alert | Catches |
|---|---|---|
| 1 | Host disk > 80% | The stack becoming the outage |
| 2 | Dead-man's switch stops pinging | Box dead, Loki dead, Alloy dead, pipeline broken |
| 3 | Any container gone / not running | Crash loops, OOM kills, failed deploys |
| 4 | Any container reports unhealthy | Running but broken |
| 5 | Any container emitting `ERROR` | Presence of failure |

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
