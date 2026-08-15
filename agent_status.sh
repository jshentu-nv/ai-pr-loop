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
  [[ -f "$1" ]] && n=$(wc -l < "$1")
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s\n' "$n"
}

LAST_LINE=0
CURSOR_SEEDED=0
if [[ -s "$CURSOR_FILE" ]]; then
  read -r LAST_LINE < "$CURSOR_FILE" || LAST_LINE=0
  [[ "$LAST_LINE" =~ ^[0-9]+$ ]] || LAST_LINE=0
  CURSOR_SEEDED=1
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
  printf '%s\n' "$LAST_LINE" > "$tmp"
  mv -f "$tmp" "$CURSOR_FILE"
}

HIGH_SIGNAL='(=====.*Iteration|codex:|claude:|VERDICT|issue[[:space:]]counts|convergence|APPROVED|AI[[:space:]]PR[[:space:]]loop[[:space:]]finished|ERROR|failed|exit[[:space:]]|auto-resume:)'
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

deadline=$(( $(date +%s) + WAIT_SECONDS ))

while :; do
  renew_lease

  TOTAL_LINES=$(line_count "$LOG_FILE")
  # A truncated or replaced log restarts the cursor rather than skipping to
  # the end of a file that is now shorter than the recorded position.
  (( TOTAL_LINES < LAST_LINE )) && LAST_LINE=0

  EMITTED=0
  if (( TOTAL_LINES > LAST_LINE )); then
    while IFS= read -r line; do
      if [[ "$line" =~ $HIGH_SIGNAL ]]; then
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

  (( EMITTED == 1 )) && exit 0
  (( $(date +%s) >= deadline )) && exit 3
  sleep 1
done
