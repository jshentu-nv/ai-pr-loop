#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: agent_status.sh STATE_DIR CURSOR_FILE [WAIT_SECONDS] [HEARTBEAT_FILE]

Print the next high-signal ai-pr-loop events after CURSOR_FILE. When a turn
report lands, print its complete saved report too. WAIT_SECONDS defaults to
0 and is capped at 60. If HEARTBEAT_FILE is supplied, refresh it before and
during the wait so agent_guard.sh knows the controlling conversation is
still monitoring.

Exit 0: one or more events were emitted
Exit 3: no event arrived before the wait expired
EOF
  exit 2
}

[[ $# -ge 2 && $# -le 4 ]] || usage

STATE_DIR="$1"
CURSOR_FILE="$2"
WAIT_SECONDS="${3:-0}"
HEARTBEAT_FILE="${4:-}"
LOG_FILE="$STATE_DIR/supervisor.log"

[[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || usage
(( WAIT_SECONDS <= 60 )) || WAIT_SECONDS=60

mkdir -p "$(dirname "$CURSOR_FILE")"
if [[ -n "$HEARTBEAT_FILE" ]]; then
  mkdir -p "$(dirname "$HEARTBEAT_FILE")"
  : > "$HEARTBEAT_FILE"
fi

LAST_LINE=0
if [[ -s "$CURSOR_FILE" ]]; then
  read -r LAST_LINE < "$CURSOR_FILE" || LAST_LINE=0
  [[ "$LAST_LINE" =~ ^[0-9]+$ ]] || LAST_LINE=0
fi

deadline=$(( $(date +%s) + WAIT_SECONDS ))

while :; do
  [[ -n "$HEARTBEAT_FILE" ]] && : > "$HEARTBEAT_FILE"

  TOTAL_LINES=0
  [[ -f "$LOG_FILE" ]] && TOTAL_LINES=$(wc -l < "$LOG_FILE")
  [[ "$TOTAL_LINES" =~ ^[0-9]+$ ]] || TOTAL_LINES=0

  if (( TOTAL_LINES < LAST_LINE )); then
    LAST_LINE=0
  fi

  EMITTED=0
  if (( TOTAL_LINES > LAST_LINE )); then
    while IFS= read -r line; do
      if [[ "$line" =~ (=====.*Iteration|codex:|claude:|VERDICT|issue[[:space:]]counts|convergence|APPROVED|AI[[:space:]]PR[[:space:]]loop[[:space:]]finished|ERROR|failed|exit[[:space:]]|auto-resume:) ]]; then
        printf '%s\n' "$line"
        EMITTED=1
      fi

      if [[ "$line" =~ report[[:space:]]\([0-9]+[[:space:]]lines\)[[:space:]]-\>[[:space:]](.*)$ ]]; then
        report_path="${BASH_REMATCH[1]%$'\r'}"
        if [[ -f "$report_path" ]]; then
          printf '%s\n' "----- BEGIN SAVED TURN REPORT -----"
          cat "$report_path"
          printf '%s\n' "----- END SAVED TURN REPORT -----"
        else
          printf 'WARNING: announced report is not readable: %s\n' "$report_path" >&2
        fi
      fi
    done < <(sed -n "$((LAST_LINE + 1)),${TOTAL_LINES}p" "$LOG_FILE")

    cursor_tmp="${CURSOR_FILE}.tmp.$$"
    printf '%s\n' "$TOTAL_LINES" > "$cursor_tmp"
    mv -f "$cursor_tmp" "$CURSOR_FILE"
    LAST_LINE="$TOTAL_LINES"
  fi

  (( EMITTED == 1 )) && exit 0
  (( $(date +%s) >= deadline )) && exit 3
  sleep 1
done
