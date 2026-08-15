#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: agent_guard.sh HEARTBEAT_FILE TIMEOUT_SECONDS -- RUN_COMMAND [ARGS...]

Run ai-pr-loop under a monitoring lease. The controller must refresh
HEARTBEAT_FILE (normally through agent_status.sh) before TIMEOUT_SECONDS
elapse. If monitoring stops, the guarded front-end is terminated; run.sh's
signal handler writes the stop sentinel and shuts down its supervisor.
EOF
  exit 2
}

[[ $# -ge 4 ]] || usage
HEARTBEAT_FILE="$1"
TIMEOUT_SECONDS="$2"
shift 2
[[ "$1" == "--" ]] || usage
shift
[[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || usage
MIN_TIMEOUT_SECONDS="${AI_PR_LOOP_AGENT_GUARD_MIN_TIMEOUT_SECONDS:-60}"
POLL_SECONDS="${AI_PR_LOOP_AGENT_GUARD_POLL_SECONDS:-5}"
[[ "$MIN_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || usage
[[ "$POLL_SECONDS" =~ ^[1-9][0-9]*$ ]] || usage
(( TIMEOUT_SECONDS >= MIN_TIMEOUT_SECONDS )) \
  || TIMEOUT_SECONDS="$MIN_TIMEOUT_SECONDS"

mkdir -p "$(dirname "$HEARTBEAT_FILE")"
: > "$HEARTBEAT_FILE"

"$@" &
RUNNER_PID=$!

forward_signal() {
  kill -TERM "$RUNNER_PID" 2>/dev/null || true
}
trap forward_signal INT TERM HUP

while kill -0 "$RUNNER_PID" 2>/dev/null; do
  now=$(date +%s)
  heartbeat_mtime=$(stat -c %Y "$HEARTBEAT_FILE" 2>/dev/null || printf '0')
  [[ "$heartbeat_mtime" =~ ^[0-9]+$ ]] || heartbeat_mtime=0
  if (( now - heartbeat_mtime > TIMEOUT_SECONDS )); then
    printf 'agent-guard: monitoring heartbeat expired after %ss; stopping ai-pr-loop\n' \
      "$TIMEOUT_SECONDS" >&2
    kill -TERM "$RUNNER_PID" 2>/dev/null || true
    wait "$RUNNER_PID" 2>/dev/null || true
    exit 124
  fi
  sleep "$POLL_SECONDS"
done

set +e
wait "$RUNNER_PID"
rc=$?
set -e
exit "$rc"
