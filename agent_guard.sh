#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: agent_guard.sh HEARTBEAT_FILE TIMEOUT_SECONDS -- RUN_COMMAND [ARGS...]

Run ai-pr-loop under a monitoring lease. The controller must refresh
HEARTBEAT_FILE (normally through agent_status.sh) before TIMEOUT_SECONDS
elapse. If monitoring stops, the guard ends the review: it re-runs
RUN_COMMAND with --stop appended, then signals the run's whole process
group.

RUN_COMMAND must therefore be a run.sh invocation that accepts --stop.
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
STOP_GRACE_SECONDS="${AI_PR_LOOP_AGENT_GUARD_STOP_GRACE_SECONDS:-30}"
[[ "$MIN_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || usage
[[ "$POLL_SECONDS" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$STOP_GRACE_SECONDS" =~ ^[0-9]+$ ]] || usage
(( TIMEOUT_SECONDS >= MIN_TIMEOUT_SECONDS )) \
  || TIMEOUT_SECONDS="$MIN_TIMEOUT_SECONDS"

# The lease timestamp is written into the heartbeat file's body AND carried by
# its mtime, and the newer of the two wins. Neither alone is enough: `stat -c`
# is GNU-only and `stat -f` is BSD-only, so an mtime-only lease expires a fresh
# heartbeat on the first poll of a host with the other stat; and a body-only
# lease ignores a controller that renews by touching the file.
renew_lease() {
  local tmp="${HEARTBEAT_FILE}.tmp.$$"
  date +%s > "$tmp"
  mv -f "$tmp" "$HEARTBEAT_FILE"
}

file_mtime() {  # <path>; prints epoch seconds, or fails
  local p="$1" v
  if v=$(stat -c %Y -- "$p" 2>/dev/null) && [[ "$v" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$v"; return 0
  fi
  if v=$(stat -f %m -- "$p" 2>/dev/null) && [[ "$v" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$v"; return 0
  fi
  if v=$(perl -e 'print +(stat $ARGV[0])[9]' -- "$p" 2>/dev/null) \
     && [[ "$v" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$v"; return 0
  fi
  return 1
}

lease_epoch() {
  local body='' mtime='' best=''
  if [[ -s "$HEARTBEAT_FILE" ]]; then
    read -r body < "$HEARTBEAT_FILE" || body=''
    body="${body%$'\r'}"
    [[ "$body" =~ ^[0-9]+$ ]] && best="$body"
  fi
  mtime=$(file_mtime "$HEARTBEAT_FILE") || mtime=''
  if [[ -n "$mtime" ]] && { [[ -z "$best" ]] || (( mtime > best )); }; then
    best="$mtime"
  fi
  [[ -n "$best" ]] || return 1
  printf '%s\n' "$best"
}

mkdir -p "$(dirname "$HEARTBEAT_FILE")"
renew_lease
# Fail loudly now rather than silently expiring (or never expiring) later.
lease_epoch >/dev/null \
  || { printf 'agent-guard: cannot read the monitoring lease at %s\n' \
         "$HEARTBEAT_FILE" >&2; exit 2; }

# Job control puts the guarded run in its own process group, so a signal can
# reach the agent CLI it started. That matters when run.sh has no supervisor
# (--no-auto-resume, or a host with no session primitive): there the front-end
# runs the loop itself, and signalling only its pid leaves the agent running.
set -m

# Armed before the fork: a signal arriving in the window between starting the
# run and installing the traps would otherwise kill the guard by default
# action and leave the run going with nothing watching its lease.
RUNNER_PID=''
signal_run() {  # <signal>
  [[ -n "$RUNNER_PID" ]] || return 0
  kill -"$1" -- "-$RUNNER_PID" 2>/dev/null \
    || kill -"$1" "$RUNNER_PID" 2>/dev/null || true
}
# Forward the signal that actually arrived. run.sh reads them differently:
# SIGINT is its stop (it writes the sentinel and takes the session down),
# while SIGTERM/SIGHUP only detach the front-end and leave the supervisor
# reviewing. Rewriting one as the other would change the caller's intent.
trap 'signal_run INT' INT
trap 'signal_run TERM' TERM
trap 'signal_run HUP' HUP

"$@" &
RUNNER_PID=$!

# Wait up to STOP_GRACE_SECONDS for a pid to exit. Returns 0 if it did.
await_exit() {  # <pid>
  local pid="$1" waited=0
  while kill -0 "$pid" 2>/dev/null; do
    (( waited < STOP_GRACE_SECONDS )) || return 1
    sleep 1
    waited=$(( waited + 1 ))
  done
  return 0
}

# An expired lease must end the whole review, so it goes through the
# authoritative stop path first. Signalling alone is not enough: SIGTERM is
# run.sh's detach signal, and a detached supervisor would keep launching
# agents until someone ran --stop by hand. Signalling alone is also not
# skippable, because an unsupervised run reads no stop sentinel.
stop_guarded_run() {
  local stop_pid
  printf 'agent-guard: ending the review through run.sh --stop\n' >&2
  "$@" --stop >&2 &
  stop_pid=$!
  if ! await_exit "$stop_pid"; then
    printf 'agent-guard: WARNING - --stop did not finish within %ss\n' \
      "$STOP_GRACE_SECONDS" >&2
    kill -TERM "$stop_pid" 2>/dev/null || true
  fi
  wait "$stop_pid" 2>/dev/null || true

  signal_run TERM
  await_exit "$RUNNER_PID" || signal_run KILL
  wait "$RUNNER_PID" 2>/dev/null || true
}

while kill -0 "$RUNNER_PID" 2>/dev/null; do
  now=$(date +%s)
  heartbeat_epoch=$(lease_epoch) || heartbeat_epoch=0
  if (( now - heartbeat_epoch > TIMEOUT_SECONDS )); then
    printf 'agent-guard: monitoring heartbeat expired after %ss; stopping ai-pr-loop\n' \
      "$TIMEOUT_SECONDS" >&2
    stop_guarded_run "$@"
    exit 124
  fi
  sleep "$POLL_SECONDS"
done

set +e
wait "$RUNNER_PID"
rc=$?
set -e
exit "$rc"
