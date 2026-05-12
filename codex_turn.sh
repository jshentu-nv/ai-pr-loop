#!/usr/bin/env bash
# One Codex review iteration. Reads env: REPO_OWNER, REPO_NAME, PR_NUMBER,
# REPO_DIR, BASE_REF, HEAD_REF, ITER, MAX_ITER, LOOP_HOME, STATE_DIR.
# Exits 0 if APPROVED, 2 if CHANGES_REQUESTED, 1 on error / no verdict found.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

ID=$(iter_dir "$ITER")
mkdir -p "$ID"

# Snapshot prior AI thread for the model.
THREAD_FILE="$ID/thread.ndjson"
fetch_ai_thread > "$THREAD_FILE" || true

PREV_ITER=$(( ITER - 1 ))
[[ $PREV_ITER -lt 0 ]] && PREV_ITER=0

# Render the prompt template.
PROMPT_FILE="$ID/codex.prompt.md"
sed \
  -e "s|{{REPO_OWNER}}|${REPO_OWNER}|g" \
  -e "s|{{REPO_NAME}}|${REPO_NAME}|g" \
  -e "s|{{PR_NUMBER}}|${PR_NUMBER}|g" \
  -e "s|{{REPO_DIR}}|${REPO_DIR}|g" \
  -e "s|{{BASE_REF}}|${BASE_REF}|g" \
  -e "s|{{HEAD_REF}}|${HEAD_REF}|g" \
  -e "s|{{ITER}}|${ITER}|g" \
  -e "s|{{PREV_ITER}}|${PREV_ITER}|g" \
  -e "s|{{MAX_ITER}}|${MAX_ITER}|g" \
  -e "s|{{THREAD_FILE}}|${THREAD_FILE}|g" \
  -e "s|{{GH_USER}}|${GH_USER}|g" \
  "$HERE/prompts/codex.md" > "$PROMPT_FILE"

log "codex: iter $ITER — running"

# Persistent session: codex has no pre-pin flag like claude --session-id, so we
# capture the session id from the filesystem after the first run, then resume
# by id on subsequent iters. This gives Codex its own internal memory of the
# whole review, on top of the public PR thread it re-reads from disk each turn.
CODEX_SESSION_FILE="$STATE_DIR/codex.session.id"
CAPTURE_NEW_SESSION=0
CODEX_SUBCMD=()
if [[ -s "$CODEX_SESSION_FILE" ]]; then
  CODEX_SESSION_ID=$(<"$CODEX_SESSION_FILE")
  log "codex: resuming session $CODEX_SESSION_ID"
  CODEX_SUBCMD=(resume "$CODEX_SESSION_ID")
else
  log "codex: starting new session"
  CAPTURE_NEW_SESSION=1
  SNAPSHOT_BEFORE="$ID/codex.sessions.before"
  snapshot_codex_sessions "$SNAPSHOT_BEFORE"
fi

# Codex must be able to run gh + git, hence bypass-approvals-and-sandbox.
# (User explicitly requested unattended operation; mutations to GitHub are
# expected.) `codex exec resume` doesn't accept --cd or --color, so cd via
# subshell and use NO_COLOR=1 for both fresh and resume paths.
set +e
( cd "$REPO_DIR" && NO_COLOR=1 codex exec \
    "${CODEX_SUBCMD[@]}" \
    --skip-git-repo-check \
    --dangerously-bypass-approvals-and-sandbox \
    - \
    < "$PROMPT_FILE" \
    > "$ID/codex.stdout" 2> "$ID/codex.stderr" )
RC=$?
set -e

# Capture the new session id so the next iter can resume. Only on success —
# a failed first run probably didn't write a usable rollout file.
if (( CAPTURE_NEW_SESSION == 1 )) && [[ $RC -eq 0 ]]; then
  if NEW_SESSION_ID=$(discover_new_codex_session_id "$SNAPSHOT_BEFORE"); then
    printf '%s\n' "$NEW_SESSION_ID" > "$CODEX_SESSION_FILE"
    log "codex: captured session id $NEW_SESSION_ID"
  else
    log "codex: WARNING — could not discover session id; next iter will start fresh"
  fi
fi

log "codex: iter $ITER — exit $RC"

if [[ $RC -ne 0 ]]; then
  log "codex stderr (tail):"
  tail -20 "$ID/codex.stderr" >&2 || true
  return 2>/dev/null || exit 1
fi

# Parse issue counts (last occurrence wins). Missing line → counts unknown,
# orchestrator treats convergence as not-met.
ISSUES_LINE=$(grep -Eo '\[CODEX_ISSUES: BLOCKER=[0-9]+ MAJOR=[0-9]+ NIT=[0-9]+\]' \
                "$ID/codex.stdout" | tail -1 || true)
if [[ -n "$ISSUES_LINE" ]]; then
  BLOCKER_N=$(grep -Eo 'BLOCKER=[0-9]+' <<<"$ISSUES_LINE" | grep -Eo '[0-9]+')
  MAJOR_N=$(grep -Eo 'MAJOR=[0-9]+' <<<"$ISSUES_LINE" | grep -Eo '[0-9]+')
  NIT_N=$(grep -Eo 'NIT=[0-9]+' <<<"$ISSUES_LINE" | grep -Eo '[0-9]+')
  printf 'BLOCKER=%s\nMAJOR=%s\nNIT=%s\n' "$BLOCKER_N" "$MAJOR_N" "$NIT_N" \
    > "$ID/issue_counts"
  log "codex: issue counts BLOCKER=$BLOCKER_N MAJOR=$MAJOR_N NIT=$NIT_N"
else
  log "codex: no [CODEX_ISSUES: ...] marker found — convergence check disabled for this iter"
fi

# Parse verdict from stdout. Take the LAST occurrence to be safe.
VERDICT=$(grep -Eo '\[CODEX_VERDICT: (APPROVED|CHANGES_REQUESTED)\]' \
            "$ID/codex.stdout" | tail -1 || true)

if [[ -z "$VERDICT" ]]; then
  log "codex: no verdict marker found in stdout — treating as CHANGES_REQUESTED"
  echo "CHANGES_REQUESTED" > "$ID/verdict"
  exit 2
fi

if [[ "$VERDICT" == *APPROVED* ]]; then
  echo "APPROVED" > "$ID/verdict"
  log "codex: VERDICT = APPROVED"
  exit 0
else
  echo "CHANGES_REQUESTED" > "$ID/verdict"
  log "codex: VERDICT = CHANGES_REQUESTED"
  exit 2
fi
