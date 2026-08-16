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

# proc_start_token, shared with run.sh and agent_status.sh. The poller
# compares the tokens written below, so both ends must derive them the same
# way; a second spelling would drift.
GUARD_HOME="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
[[ -r "$GUARD_HOME/lib/common.sh" ]] || {
  printf 'agent-guard: run this from its checkout: %s/lib/common.sh is missing\n' \
    "$GUARD_HOME" >&2
  exit 2
}
# shellcheck source=lib/common.sh
. "$GUARD_HOME/lib/common.sh"

# Records kept next to the lease, all removed on a clean exit:
#
#   .guard-pid   this guard's pid and start-time token
#   .runner-pid  the guarded run's pid and token, written after the fork
#   .stop-cmd    the argv to re-run with --stop, NUL separated
#   .exit        the guard's exit status
#
# A guarded run can end without writing anything a log filter would notice — a
# silent nonzero exit, an empty run log — so .exit is what tells the poller
# "this is over". The other three exist for the guard dying without running
# its exit trap: the poller can then tell whether the review outlived the
# guard, and end it through the same authoritative stop the guard would have
# used. The start-time tokens matter because a bare pid is reused, and an
# unrelated process holding this guard's old pid would otherwise look alive
# for as long as it ran.
#
# Written as soon as the heartbeat path is known, before any argument check
# that can exit: a guard that dies on one of them must still leave a record,
# or the poller waits for a run that never started.
GUARD_PID_FILE="${HEARTBEAT_FILE}.guard-pid"
GUARD_EXIT_FILE="${HEARTBEAT_FILE}.exit"
RUNNER_PID_FILE="${HEARTBEAT_FILE}.runner-pid"
STOP_CMD_FILE="${HEARTBEAT_FILE}.stop-cmd"
publish_atomic() {  # <path> <content>
  local tmp="$1.tmp.$$"
  printf '%s\n' "$2" > "$tmp"
  mv -f "$tmp" "$1"
}
publish_pid_record() {  # <path> <pid>
  publish_atomic "$1" "$2
$(proc_start_token "$2")"
}
publish_exit() {
  local rc=$?
  publish_atomic "$GUARD_EXIT_FILE" "$rc"
  rm -f "$GUARD_PID_FILE" "$RUNNER_PID_FILE" "$STOP_CMD_FILE" \
        "$GUARD_PID_FILE.tmp.$$" "$RUNNER_PID_FILE.tmp.$$" "$STOP_CMD_FILE.tmp.$$"
}
mkdir -p "$(dirname "$HEARTBEAT_FILE")"
rm -f "$GUARD_EXIT_FILE" "$RUNNER_PID_FILE" "$STOP_CMD_FILE"
trap publish_exit EXIT
publish_pid_record "$GUARD_PID_FILE" "$$"

[[ "$1" == "--" ]] || usage
shift
RUN_CMD=("$@")
printf '%s\0' "${RUN_CMD[@]}" > "$STOP_CMD_FILE.tmp.$$"
mv -f "$STOP_CMD_FILE.tmp.$$" "$STOP_CMD_FILE"

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

RUNNER_PID=''
signal_run() {  # <signal>
  [[ -n "$RUNNER_PID" ]] || return 0
  kill -"$1" -- "-$RUNNER_PID" 2>/dev/null \
    || kill -"$1" "$RUNNER_PID" 2>/dev/null || true
}

# Wait up to STOP_GRACE_SECONDS for a pid to exit. Returns 0 if it did.
await_exit() {  # <pid>
  local pid="${1:-}" waited=0
  [[ -n "$pid" ]] || return 0
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
  "${RUN_CMD[@]}" --stop >&2 &
  stop_pid=$!
  if ! await_exit "$stop_pid"; then
    printf 'agent-guard: WARNING - --stop did not finish within %ss\n' \
      "$STOP_GRACE_SECONDS" >&2
    kill -TERM "$stop_pid" 2>/dev/null || true
  fi
  wait "$stop_pid" 2>/dev/null || true

  [[ -n "$RUNNER_PID" ]] || return 0
  signal_run TERM
  await_exit "$RUNNER_PID" || signal_run KILL
  wait "$RUNNER_PID" 2>/dev/null || true
}

# Every signal ends the review, none of them merely forwards. Passing SIGTERM
# through would detach run.sh's front-end and leave the supervisor reviewing
# with the guard gone — the loop still running, nothing watching its lease,
# and a completion record saying the run is over. A caller that wants to
# detach must not put the run under a guard.
guard_signalled() {  # <name> <exit code>
  trap '' INT TERM HUP
  printf 'agent-guard: signalled (%s); ending the review\n' "$1" >&2
  stop_guarded_run
  exit "$2"
}
# Armed only here. Every function a handler reaches is defined above and the
# fork is below, so no signal can land on a name that does not exist yet: that
# would run an undefined command, exit 127 under set -e, and orphan the run.
trap 'guard_signalled SIGINT 130' INT
trap 'guard_signalled SIGTERM 143' TERM
trap 'guard_signalled SIGHUP 129' HUP

"${RUN_CMD[@]}" &
RUNNER_PID=$!
# What lets the poller tell "the guard finished" from "the guard was killed
# and its review is still running".
publish_pid_record "$RUNNER_PID_FILE" "$RUNNER_PID"

while kill -0 "$RUNNER_PID" 2>/dev/null; do
  now=$(date +%s)
  heartbeat_epoch=$(lease_epoch) || heartbeat_epoch=0
  if (( now - heartbeat_epoch > TIMEOUT_SECONDS )); then
    printf 'agent-guard: monitoring heartbeat expired after %ss; stopping ai-pr-loop\n' \
      "$TIMEOUT_SECONDS" >&2
    trap '' INT TERM HUP
    stop_guarded_run
    exit 124
  fi
  sleep "$POLL_SECONDS"
done

set +e
wait "$RUNNER_PID"
rc=$?
set -e
exit "$rc"
