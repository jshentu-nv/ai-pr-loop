#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: agent_status.sh STATE_DIR CURSOR_FILE [WAIT_SECONDS] [HEARTBEAT_FILE] [RUN_LOG_FILE]

Print the next high-signal ai-pr-loop events after CURSOR_FILE. When a turn
report lands, print its complete saved report too. WAIT_SECONDS defaults to
0 and is capped at 60. If HEARTBEAT_FILE is supplied, refresh it before and
during the wait so agent_guard.sh knows the controlling conversation is
still monitoring.

RUN_LOG_FILE is the file the guarded run.sh command writes to. Pass it: it
is the one log that covers every mode. A run with no supervisor
(--no-auto-resume, or a host with no session primitive) writes no
supervisor.log at all, and a supervised run's front-end tails this
invocation's supervisor lines into it. Without it this reads
STATE_DIR/supervisor.log, which a previous review appended to as well.

Exit 0: one or more events were emitted
Exit 3: no event arrived before the wait expired
Exit 4: the guard is gone but its review outlived it, and this could not end
        it — stop the review by hand and report it
EOF
  exit 2
}

[[ $# -ge 2 && $# -le 5 ]] || usage

STATE_DIR="$1"
CURSOR_FILE="$2"
WAIT_SECONDS="${3:-0}"
HEARTBEAT_FILE="${4:-}"
RUN_LOG_FILE="${5:-}"

[[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || usage
(( WAIT_SECONDS <= 60 )) || WAIT_SECONDS=60

# proc_start_token, shared with run.sh and agent_guard.sh. The guard writes
# the tokens compared below, so both ends must derive them the same way.
STATUS_HOME="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
[[ -r "$STATUS_HOME/lib/common.sh" ]] || {
  printf 'agent-status: run this from its checkout: %s/lib/common.sh is missing\n' \
    "$STATUS_HOME" >&2
  exit 2
}
# shellcheck source=lib/common.sh
. "$STATUS_HOME/lib/common.sh"

# One log, chosen once. Reading both would double-report every event, because
# a supervised front-end tails supervisor.log into the run log.
if [[ -n "$RUN_LOG_FILE" ]]; then
  LOG_FILE="$RUN_LOG_FILE"
  LOG_IS_PER_RUN=1
else
  LOG_FILE="$STATE_DIR/supervisor.log"
  LOG_IS_PER_RUN=0
fi

# agent_guard.sh takes the lease timestamp from the file body or its mtime,
# whichever is newer, so writing the epoch satisfies both.
renew_lease() {
  [[ -n "$HEARTBEAT_FILE" ]] || return 0
  local tmp="${HEARTBEAT_FILE}.tmp.$$"
  date +%s > "$tmp"
  mv -f "$tmp" "$HEARTBEAT_FILE"
}

mkdir -p "$(dirname "$CURSOR_FILE")"
if [[ -n "$HEARTBEAT_FILE" ]]; then
  mkdir -p "$(dirname "$HEARTBEAT_FILE")"
  renew_lease
fi

line_count() {  # <file>
  local n=0
  # BSD wc pads its count with leading spaces, which the digit check below
  # would reject — leaving every poll on macOS reading an empty log.
  [[ -f "$1" ]] && n=$(wc -l < "$1" | tr -d '[:space:]')
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s\n' "$n"
}

# Line 1 is the position, line 2 the log it indexes. A line number means
# nothing against a different file: a poll that dropped the optional run-log
# argument would otherwise apply the run log's position to supervisor.log and
# drain a previous review's tail, terminal verdict included.
LAST_LINE=0
CURSOR_SEEDED=0
if [[ -s "$CURSOR_FILE" ]]; then
  CURSOR_LOG=''
  { read -r LAST_LINE || LAST_LINE=0
    read -r CURSOR_LOG || CURSOR_LOG=''
  } < "$CURSOR_FILE"
  [[ "$LAST_LINE" =~ ^[0-9]+$ ]] || LAST_LINE=0
  # An older cursor carries no log line; it was written for whichever log the
  # caller passed then, so treat it as this one rather than replaying.
  if [[ -z "$CURSOR_LOG" || "${CURSOR_LOG%$'\r'}" == "$LOG_FILE" ]]; then
    CURSOR_SEEDED=1
  else
    LAST_LINE=0
  fi
fi
# supervisor.log is appended to across reviews and never truncated, so a first
# poll from position 0 would replay the previous review — including its
# terminal verdict, which would tell the controller that the run it just
# started had already finished. Start such a monitor at the end of the log
# instead. The run log needs no seeding: the launch creates it.
if (( CURSOR_SEEDED == 0 && LOG_IS_PER_RUN == 0 )); then
  LAST_LINE=$(line_count "$LOG_FILE")
fi

save_cursor() {
  local tmp="${CURSOR_FILE}.tmp.$$"
  printf '%s\n%s\n' "$LAST_LINE" "$LOG_FILE" > "$tmp"
  mv -f "$tmp" "$CURSOR_FILE"
}

# Only the orchestrator's own log lines can raise an event. Saved report
# bodies are written into this same log indented by two spaces, and the
# agents' stdout lands there unfiltered, so a report line reading `AI PR loop
# finished: approved` must not read as the controller saying it. Terminal
# status is not taken from log text at all — see the guard exit record below.
CONTROLLER_LINE='^\[ai-loop [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\] [^[:space:]]'
# The guard writes to the same captured log and its lines are always events.
GUARD_LINE='^agent-guard: '
HIGH_SIGNAL='(=====.*Iteration|codex:|claude:|finalize:|VERDICT|issue[[:space:]]counts|convergence|APPROVED|AI[[:space:]]PR[[:space:]]loop[[:space:]]finished|ERROR|failed|exit[[:space:]]|auto-resume:)'
# The two sentences the skill makes actionable: one ends the poll, the other
# tells the controller the lease is unenforced. The agents can write anything
# into this log — a failing turn's stderr is tailed into it verbatim — so no
# log line is allowed to carry either. They reach the controller only from the
# guard's own records below.
TERMINAL_TEXT='the guarded run has ended'
ALARM_TEXT='ALARM - the guard is gone'
# The one line the orchestrator prints when a round report is saved, anchored
# to its whole shape: `[ai-loop HH:MM:SS] codex: iter 1 report (27 lines) -> …`.
# Report bodies are logged into the same file (indented by two spaces) and the
# agents' own stdout lands there too, so an unanchored match would fire on
# text an agent wrote.
REPORT_ANNOUNCE='^\[ai-loop [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\] (codex|claude): iter ([0-9]{1,6}) report \([0-9]+ lines\) ->'

# Print the saved report for an announcement. The path printed in the log is
# never opened: an agent can write that whole line into its own report body,
# which would turn this helper into a read primitive for any local file the
# controller can see. The real report is always at the orchestrator's own
# STATE_DIR/iter-NN/<agent>-report.md, so derive it and read only that.
emit_saved_report() {  # <codex|claude> <iter>
  local who="$1" iter="$2" report_path
  report_path=$(printf '%s/iter-%02d/%s-report.md' \
    "$STATE_DIR" "$((10#$iter))" "$who")
  if [[ -f "$report_path" ]]; then
    printf '%s\n' "----- BEGIN SAVED TURN REPORT -----"
    cat "$report_path"
    printf '%s\n' "----- END SAVED TURN REPORT -----"
  else
    printf 'WARNING: announced report is not readable: %s\n' "$report_path" >&2
  fi
}

# The guard's completion record, published next to the lease. Checked BEFORE
# the log is drained: once the guard is gone the log is final, so a flag read
# first and acted on last cannot cut off the run's closing lines.
GUARD_EXIT_FILE=''
GUARD_PID_FILE=''
RUNNER_PID_FILE=''
STOP_CMD_FILE=''
if [[ -n "$HEARTBEAT_FILE" ]]; then
  GUARD_EXIT_FILE="${HEARTBEAT_FILE}.exit"
  GUARD_PID_FILE="${HEARTBEAT_FILE}.guard-pid"
  RUNNER_PID_FILE="${HEARTBEAT_FILE}.runner-pid"
  STOP_CMD_FILE="${HEARTBEAT_FILE}.stop-cmd"
fi

# True when the pid record at $1 still names the process that wrote it. The
# recorded start-time token is what makes that "still": a bare pid is reused,
# and an unrelated process holding the guard's old pid would otherwise
# suppress completion for as long as it ran.
record_is_live() {  # <pid-record-file>
  local pid='' token=''
  [[ -s "$1" ]] || return 1
  { read -r pid || pid=''
    read -r token || token=''
  } < "$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # Empty on both sides means no probe on this host answered. Accept it:
  # reading the process as live only keeps the poller watching.
  [[ "$(proc_start_token "$pid")" == "${token%$'\r'}" ]]
}

record_pid() {  # <pid-record-file>
  local pid=''
  [[ -s "$1" ]] || return 1
  read -r pid < "$1" || pid=''
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$pid"
}

STOP_GRACE_SECONDS="${AI_PR_LOOP_AGENT_STATUS_STOP_GRACE_SECONDS:-20}"
[[ "$STOP_GRACE_SECONDS" =~ ^[0-9]+$ ]] || STOP_GRACE_SECONDS=20

# Signal the recorded runner's whole process group. The guard starts it under
# job control, so the group reaches the agent CLI below it.
signal_recorded_runner() {  # <signal>
  local pid
  pid=$(record_pid "$RUNNER_PID_FILE") || return 1
  record_is_live "$RUNNER_PID_FILE" || return 1
  kill -"$1" -- "-$pid" 2>/dev/null || kill -"$1" "$pid" 2>/dev/null || true
}

# End a review whose guard died without stopping it. This mirrors the guard's
# own stop, and needs both halves for the same reasons: --stop alone cannot
# end an unsupervised run, which writes no pid record and reads no sentinel,
# and a signal alone only detaches a supervised front-end.
run_recorded_stop() {
  local cmd=() a stop_pid waited=0 tried=1
  if [[ -s "$STOP_CMD_FILE" ]]; then
    while IFS= read -r -d '' a; do cmd+=("$a"); done < "$STOP_CMD_FILE"
  fi
  if (( ${#cmd[@]} > 0 )); then
    tried=0
    printf 'agent-guard: the guard is gone; ending its review through --stop\n' >&2
    "${cmd[@]}" --stop >&2 &
    stop_pid=$!
    while kill -0 "$stop_pid" 2>/dev/null && (( waited < STOP_GRACE_SECONDS )); do
      sleep 1
      waited=$(( waited + 1 ))
    done
    kill -TERM "$stop_pid" 2>/dev/null || true
    wait "$stop_pid" 2>/dev/null || true
  fi

  # `--stop` returns as soon as it has signalled; the front-end still has to
  # notice, and an unsupervised run never will. Escalate on the recorded
  # runner exactly as the guard does, with the same grace before each step —
  # re-checking the instant --stop returns would read a perfectly normal stop
  # as an unstoppable review.
  signal_recorded_runner TERM || return "$tried"
  tried=0
  waited=0
  while record_is_live "$RUNNER_PID_FILE" && (( waited < STOP_GRACE_SECONDS )); do
    sleep 1
    waited=$(( waited + 1 ))
  done
  record_is_live "$RUNNER_PID_FILE" && signal_recorded_runner KILL
  waited=0
  while record_is_live "$RUNNER_PID_FILE" && (( waited < 5 )); do
    sleep 1
    waited=$(( waited + 1 ))
  done
  return 0
}

# Print the terminal event when the guarded run is over. Returns 1 when it is
# not over, and 4 when the guard is gone but its review outlived it.
guard_terminal_event() {
  local rc='' runner='' stopped_nothing=0
  [[ -n "$GUARD_EXIT_FILE" ]] || return 1
  # A live guard settles it first. These records sit at a path the controller
  # reuses per PR, so a previous review's exit status can still be on disk
  # when this one starts: the guard removes it, but the first poll can run
  # before the guard gets that far.
  record_is_live "$GUARD_PID_FILE" && return 1
  if [[ -s "$GUARD_EXIT_FILE" ]]; then
    read -r rc < "$GUARD_EXIT_FILE" || rc=''
    [[ "$rc" =~ ^[0-9]+$ ]] || rc=unknown
    printf 'agent-guard: %s (exit %s)\n' "$TERMINAL_TEXT" "$rc"
    return 0
  fi
  [[ -s "$GUARD_PID_FILE" ]] || return 1
  # The guard died without running its exit trap — a SIGKILL, or the host
  # taking it down. Killing a guard does not end the review under it, and a
  # missing runner record does not mean there is nothing to end: that record
  # is published just after the fork, so a guard killed inside that window
  # leaves none. Stop unconditionally, then decide. The stop is idempotent,
  # so doing it for a review that had already finished costs a sentinel file.
  runner=$(record_pid "$RUNNER_PID_FILE") || runner=''
  run_recorded_stop || stopped_nothing=1
  if record_is_live "$RUNNER_PID_FILE"; then
    printf 'agent-guard: %s (pid %s) is still running; nothing is enforcing the monitoring lease. End it by hand: run.sh <pr> --repo <slug> --stop\n' \
      "$ALARM_TEXT" "$runner" >&2
    return 4
  fi
  if [[ -n "$runner" ]]; then
    printf 'agent-guard: %s without an exit status (the guard was killed; its review has been stopped)\n' \
      "$TERMINAL_TEXT"
    return 0
  fi
  # No usable runner record: the guard died inside the window between forking
  # the run and publishing it. Claiming the review was stopped would be the
  # same false statement this path exists to remove.
  printf 'agent-guard: %s without an exit status (the guard is gone; its review could not be identified%s)\n' \
    "$TERMINAL_TEXT" \
    "$( (( ${stopped_nothing:-0} == 1 )) && printf ' or stopped' )"
  return 0
}

deadline=$(( $(date +%s) + WAIT_SECONDS ))

while :; do
  renew_lease

  TERMINAL_EVENT=''
  TERMINAL_RC=0
  TERMINAL_EVENT=$(guard_terminal_event) || TERMINAL_RC=$?

  TOTAL_LINES=$(line_count "$LOG_FILE")
  # A truncated or replaced log restarts the cursor rather than skipping to
  # the end of a file that is now shorter than the recorded position.
  (( TOTAL_LINES < LAST_LINE )) && LAST_LINE=0

  EMITTED=0
  if (( TOTAL_LINES > LAST_LINE )); then
    while IFS= read -r line; do
      if [[ "$line" == *"$TERMINAL_TEXT"* || "$line" == *"$ALARM_TEXT"* ]]; then
        continue
      fi
      if [[ "$line" =~ $GUARD_LINE ]] \
         || { [[ "$line" =~ $CONTROLLER_LINE ]] && [[ "$line" =~ $HIGH_SIGNAL ]]; }
      then
        printf '%s\n' "$line"
        EMITTED=1
      fi
      if [[ "$line" =~ $REPORT_ANNOUNCE ]]; then
        emit_saved_report "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
      fi
    done < <(sed -n "$((LAST_LINE + 1)),${TOTAL_LINES}p" "$LOG_FILE")
    LAST_LINE="$TOTAL_LINES"
    save_cursor
  elif (( CURSOR_SEEDED == 0 )); then
    save_cursor          # publish the seeded position for the next poll
    CURSOR_SEEDED=1
  fi

  # The log is drained above either way, so a run that ended keeps its closing
  # lines even when the guard's own state is what ends this poll.
  (( TERMINAL_RC == 4 )) && exit 4
  if [[ -n "$TERMINAL_EVENT" ]]; then
    printf '%s\n' "$TERMINAL_EVENT"
    exit 0
  fi
  (( EMITTED == 1 )) && exit 0
  (( $(date +%s) >= deadline )) && exit 3
  sleep 1
done
