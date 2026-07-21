#!/usr/bin/env bash
# Behaviour tests for the canary. See docker-compose.test.yml for the rig.
#
# Four of the five cases assert that NO ping is sent. That inversion is the
# whole point: a canary that pings when it should not is strictly worse than
# no canary, because it converts an outage into a reassurance.
#
# Usage: test/run-tests.sh     (requires a running Docker daemon)

set -euo pipefail

cd "$(dirname "$0")"
COMPOSE=(docker compose -f docker-compose.test.yml)

if ! docker version >/dev/null 2>&1; then
	echo "FATAL: Docker daemon is not reachable. Start Docker and retry." >&2
	exit 2
fi

passed=0
failed=0

cleanup() {
	"${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

reset_stub() {
	"${COMPOSE[@]}" exec -T stub sh -c ': > /requests/log'
}

stub_log() {
	"${COMPOSE[@]}" exec -T stub cat /requests/log 2>/dev/null || true
}

# Runs one canary iteration with per-case environment overrides.
run_canary_once() {
	local env_args=()
	while [[ $# -gt 0 && "$1" == *=* ]]; do
		env_args+=(-e "$1")
		shift
	done
	# ${x[@]+"${x[@]}"} rather than "${x[@]}": under `set -u`, bash 3.2 (which
	# is what macOS ships) treats an empty array expansion as unbound.
	"${COMPOSE[@]}" run --rm --no-deps ${env_args[@]+"${env_args[@]}"} canary >/dev/null 2>&1 || true
}

push_lines() {
	local ts payload
	ts="$(($(date +%s) * 1000000000))"
	payload="{\"streams\":[{\"stream\":{\"container\":\"canary-test\"},\"values\":[[\"${ts}\",\"synthetic line from the canary test suite\"]]}]}"
	"${COMPOSE[@]}" run --rm --no-deps --entrypoint sh canary -c \
		"curl -sS -o /dev/null -X POST -H 'Content-Type: application/json' --data '${payload}' http://loki:3100/loki/api/v1/push" \
		>/dev/null 2>&1
	# Give Loki a moment to make the line queryable.
	sleep 3
}

expect_ping() {
	local path="$1" desc="$2"
	if stub_log | grep -qF "$path"; then
		echo "  PASS  $desc"
		passed=$((passed + 1))
	else
		echo "  FAIL  $desc (expected a ping to $path, none arrived)"
		failed=$((failed + 1))
	fi
}

expect_no_ping() {
	local path="$1" desc="$2"
	if stub_log | grep -qF "$path"; then
		echo "  FAIL  $desc (a ping to $path arrived and should NOT have)"
		failed=$((failed + 1))
	else
		echo "  PASS  $desc"
		passed=$((passed + 1))
	fi
}

echo "Starting test rig (fresh Loki, empty stub)..."
"${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true

# Rebuild the canary image explicitly. `docker compose run` reuses whatever
# image already exists, so without this the suite silently tests a stale
# build and passes no matter what canary.sh says.
"${COMPOSE[@]}" build canary >/dev/null

"${COMPOSE[@]}" up -d loki stub >/dev/null

# The Loki image is distroless, so it cannot carry a Docker healthcheck.
# Poll /ready from the canary image, which has curl.
echo "Waiting for Loki to become ready..."
# Single-quoted on purpose: this loop is evaluated inside the container, not here.
# shellcheck disable=SC2016
if ! "${COMPOSE[@]}" run --rm --no-deps --entrypoint sh canary -c \
	'for i in $(seq 1 90); do curl -sf http://loki:3100/ready >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1' \
	>/dev/null 2>&1; then
	echo "FATAL: Loki did not become ready in time." >&2
	"${COMPOSE[@]}" logs loki >&2
	exit 2
fi
echo

# This case must run first, against a Loki that has never received anything.
echo "1. no log lines in the window"
reset_stub
run_canary_once
expect_no_ping "/ping/pipeline" "does not ping when the pipeline is silent"

echo "2. Loki unreachable"
reset_stub
run_canary_once "LOKI_URL=http://127.0.0.1:9999"
expect_no_ping "/ping/pipeline" "fails closed when Loki cannot be reached"

echo "3. disk usage above threshold"
reset_stub
run_canary_once "DISK_THRESHOLD_PCT=0"
expect_no_ping "/ping/disk" "does not ping when the disk is over threshold"

echo "4. disk usage below threshold"
reset_stub
run_canary_once "DISK_THRESHOLD_PCT=100"
expect_ping "/ping/disk" "pings when the disk is under threshold"

echo "5. disk mount smaller than the sanity floor"
reset_stub
run_canary_once "DISK_THRESHOLD_PCT=100" "DISK_MIN_TOTAL_KB=999999999999"
expect_no_ping "/ping/disk" "fails closed when measuring an implausibly small filesystem"

echo "6. log lines present in the window"
reset_stub
push_lines
run_canary_once
expect_ping "/ping/pipeline" "pings when Loki reports recent lines"

echo
echo "passed: $passed   failed: $failed"
[ "$failed" -eq 0 ]
