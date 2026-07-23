#!/bin/sh
# The dead-man's switch, the disk check, and the host-memory check.
#
# All three are INVERTED heartbeats: this script pings only while it can
# prove things are healthy, and it is the ABSENCE of a ping that raises the
# alarm via Healthchecks.io. Every failure path below therefore ends in "do
# not ping" — a check that pings on error is worse than no check at all,
# because it converts an outage into a reassurance.
#
# Why this rather than the naive heartbeat: a sidecar that curls a ping URL
# every 5 minutes proves only that the box has power, Docker runs, and the
# internet works. It does not prove Alloy is collecting or Loki is
# ingesting — Alloy could be silently crash-looping and it would ping
# happily forever. That is the version most people build, and it produces a
# comfortable green checkmark certifying almost nothing (SPEC decision 14).
#
# POSIX sh; runs under BusyBox ash in the alpine image.

set -u

LOKI_URL="${LOKI_URL:-http://loki:3100}"
LOKI_WINDOW="${LOKI_WINDOW:-5m}"
DISK_PATH="${DISK_PATH:-/host}"
DISK_THRESHOLD_PCT="${DISK_THRESHOLD_PCT:-80}"
# Sanity floor for the filesystem behind DISK_PATH, in 1K blocks (default
# 10 GB). The host root this watches is ~200 GB; anything drastically
# smaller means the mount is missing or DISK_PATH points somewhere else,
# and a check quietly measuring the wrong filesystem reports a healthy
# number forever. Set to 0 to disable.
DISK_MIN_TOTAL_KB="${DISK_MIN_TOTAL_KB:-10485760}"
# Host memory. Ping only while MemAvailable stays at or above this percentage
# of MemTotal. MemAvailable is the kernel's own estimate of memory reclaimable
# for new work — it already discounts droppable disk cache, so a healthy but
# busy box does not trip it. This is a "sustained exhaustion" signal, not an
# "exact instant of an OOM" one: the fast kill is caught by the container-down
# alert (task 3). MemAvailable only, no swap rate — sampling a rate over time
# is metrics-with-history work, which is what Prometheus is for.
MEM_MIN_AVAIL_PCT="${MEM_MIN_AVAIL_PCT:-10}"
# In a container, /proc/meminfo is NOT namespaced: it reflects the host's
# physical memory, which is exactly what we want. Overridable so the test
# suite can point it at a fixture or a missing file.
MEMINFO_PATH="${MEMINFO_PATH:-/proc/meminfo}"
CHECK_INTERVAL_SECONDS="${CHECK_INTERVAL_SECONDS:-300}"
CURL_TIMEOUT="${CURL_TIMEOUT:-10}"
HC_PING_URL_PIPELINE="${HC_PING_URL_PIPELINE:-}"
HC_PING_URL_DISK="${HC_PING_URL_DISK:-}"
HC_PING_URL_MEMORY="${HC_PING_URL_MEMORY:-}"

# Run a single iteration and exit. Used by the test suite; unset in production.
CANARY_ONCE="${CANARY_ONCE:-0}"

log() {
	echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
}

# Delivery only. Deciding whether to ping is the caller's job.
send_ping() {
	_url="$1"
	_name="$2"

	if [ -z "$_url" ]; then
		log "$_name: healthy, but no ping URL configured — nothing sent"
		return 1
	fi

	if curl -fsS --max-time "$CURL_TIMEOUT" -o /dev/null "$_url"; then
		log "$_name: healthy — pinged"
		return 0
	fi

	# The check passed but delivery failed. Nothing to do: Healthchecks.io
	# will alarm on the missing ping, which is the correct outcome.
	log "$_name: healthy, but ping delivery FAILED"
	return 1
}

# Proves the entire chain in a single signal:
#   containers -> Docker socket -> Alloy -> Loki -> query API.
check_pipeline() {
	_query='sum(count_over_time({container=~".+"}['"$LOKI_WINDOW"']))'

	if ! _body=$(curl -fsS --max-time "$CURL_TIMEOUT" -G \
		--data-urlencode "query=$_query" \
		"$LOKI_URL/loki/api/v1/query" 2>/dev/null); then
		log "pipeline: Loki query failed or unreachable — NOT pinging"
		return 1
	fi

	_status=$(printf '%s' "$_body" | jq -r '.status // "error"' 2>/dev/null)
	if [ "$_status" != "success" ]; then
		log "pipeline: Loki returned status=${_status:-unparseable} — NOT pinging"
		return 1
	fi

	# An empty result set is 0 lines, not an error — `add` on an empty array
	# yields null, hence the fallback.
	_count=$(printf '%s' "$_body" |
		jq -r '[.data.result[]?.value[1] | tonumber] | add // 0' 2>/dev/null)

	case "$_count" in
	'' | *[!0-9.]*)
		log "pipeline: unparseable line count from Loki — NOT pinging"
		return 1
		;;
	esac

	_count_int=${_count%%.*}
	if [ "$_count_int" -gt 0 ]; then
		log "pipeline: $_count_int lines in the last $LOKI_WINDOW"
		send_ping "$HC_PING_URL_PIPELINE" pipeline
		return 0
	fi

	# The signal this whole component exists to produce. Zero lines across
	# every container means the pipeline has stopped, whatever the reason.
	log "pipeline: 0 lines in the last $LOKI_WINDOW — NOT pinging"
	return 1
}

# Out-of-band on purpose. The disk-full scenario is exactly the one where
# Loki cannot write chunks, Prometheus cannot write blocks and Grafana
# cannot write its SQLite — so routing this alert through that stack would
# ask it to report the condition that breaks it (SPEC decision 10).
check_disk() {
	_df=$(df -P "$DISK_PATH" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $2, $5}')
	_total=${_df% *}
	_used=${_df#* }

	case "${_used:-}" in
	'' | *[!0-9]*)
		log "disk: could not read usage for $DISK_PATH — NOT pinging"
		return 1
		;;
	esac

	case "${_total:-}" in
	'' | *[!0-9]*)
		log "disk: could not read total size for $DISK_PATH — NOT pinging"
		return 1
		;;
	esac

	# Fail closed rather than report a healthy number for the wrong disk.
	if [ "$DISK_MIN_TOTAL_KB" -gt 0 ] && [ "$_total" -lt "$DISK_MIN_TOTAL_KB" ]; then
		log "disk: $DISK_PATH is only ${_total}K total, below the ${DISK_MIN_TOTAL_KB}K sanity floor — the host mount is probably missing. NOT pinging"
		return 1
	fi

	if [ "$_used" -lt "$DISK_THRESHOLD_PCT" ]; then
		log "disk: ${_used}% used of $DISK_PATH, below ${DISK_THRESHOLD_PCT}%"
		send_ping "$HC_PING_URL_DISK" disk
		return 0
	fi

	log "disk: ${_used}% used of $DISK_PATH, at or above ${DISK_THRESHOLD_PCT}% — NOT pinging"
	return 1
}

# Out-of-band for the same reason as disk: a box exhausting memory starts
# OOM-killing processes and thrashing swap, which degrades the very stack
# that would otherwise report it — Loki, Alloy or Grafana could be what the
# kernel kills. The condition breaks the reporter, so it must be watched
# from outside (SPEC decision 16).
check_memory() {
	if [ ! -r "$MEMINFO_PATH" ]; then
		log "memory: cannot read $MEMINFO_PATH — NOT pinging"
		return 1
	fi

	_total=$(awk '/^MemTotal:/ {print $2; exit}' "$MEMINFO_PATH" 2>/dev/null)
	_avail=$(awk '/^MemAvailable:/ {print $2; exit}' "$MEMINFO_PATH" 2>/dev/null)

	# MemAvailable is absent on kernels older than 3.14. Fail closed rather
	# than guess it from free+cached; the server is modern.
	case "${_total:-}" in
	'' | *[!0-9]*)
		log "memory: could not read MemTotal from $MEMINFO_PATH — NOT pinging"
		return 1
		;;
	esac
	case "${_avail:-}" in
	'' | *[!0-9]*)
		log "memory: could not read MemAvailable from $MEMINFO_PATH — NOT pinging"
		return 1
		;;
	esac

	if [ "$_total" -le 0 ]; then
		log "memory: MemTotal is ${_total}K — NOT pinging"
		return 1
	fi

	_avail_pct=$((_avail * 100 / _total))

	if [ "$_avail_pct" -ge "$MEM_MIN_AVAIL_PCT" ]; then
		log "memory: ${_avail_pct}% available (${_avail}K of ${_total}K), at or above ${MEM_MIN_AVAIL_PCT}%"
		send_ping "$HC_PING_URL_MEMORY" memory
		return 0
	fi

	log "memory: ${_avail_pct}% available (${_avail}K of ${_total}K), below ${MEM_MIN_AVAIL_PCT}% — NOT pinging"
	return 1
}

log "canary starting: loki=$LOKI_URL window=$LOKI_WINDOW disk=$DISK_PATH threshold=${DISK_THRESHOLD_PCT}% mem_min_avail=${MEM_MIN_AVAIL_PCT}% interval=${CHECK_INTERVAL_SECONDS}s"

while :; do
	check_pipeline || true
	check_disk || true
	check_memory || true

	if [ "$CANARY_ONCE" = "1" ]; then
		break
	fi

	# Drifts, and has no jitter. That is fine: the Healthchecks.io grace
	# period (15m against a 5m period) absorbs it, which is why the grace
	# period is set deliberately rather than left at its default.
	sleep "$CHECK_INTERVAL_SECONDS"
done
