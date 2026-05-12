#!/usr/bin/env bash
# One Claude implementer iteration. Same env contract as codex_turn.sh.
# Exits 0 on success (turn marker found), 1 on error.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

ID=$(iter_dir "$ITER")
mkdir -p "$ID"

# Snapshot AI thread.
THREAD_FILE="$ID/thread.ndjson"
fetch_ai_thread > "$THREAD_FILE" || true

# Extract this iter's codex output split by surface:
#   - LATEST_REVIEW_FILE  → summary issue-comment body (cross-cutting + verdict)
#   - LATEST_INLINE_FILE  → NDJSON of inline findings, one per line:
#                            { id, path, line, body }
#     id is needed when Claude posts in_reply_to replies.
LATEST_REVIEW_FILE="$ID/codex-review.md"
LATEST_INLINE_FILE="$ID/codex-inline.ndjson"

jq -r --arg t "$CODEX_MARKER_TAG" --argjson it "$ITER" '
    select(.tag==$t and .iter==$it and .surface=="issue") | .body' \
    "$THREAD_FILE" > "$LATEST_REVIEW_FILE"

jq -c --arg t "$CODEX_MARKER_TAG" --argjson it "$ITER" '
    select(.tag==$t and .iter==$it and .surface=="inline")
    | {id, path, line, body}' \
    "$THREAD_FILE" > "$LATEST_INLINE_FILE"

if [[ ! -s "$LATEST_REVIEW_FILE" ]]; then
  # Summary missing for this iter — fall back to the latest codex summary so
  # Claude has *something*. (Doesn't affect inline; missing inline = no inline
  # findings this iter, which is a valid outcome.)
  jq -r --arg t "$CODEX_MARKER_TAG" '
      select(.tag==$t and .surface=="issue") | .body' "$THREAD_FILE" \
    | tail -n 200 > "$LATEST_REVIEW_FILE"
fi

if [[ ! -s "$LATEST_REVIEW_FILE" ]]; then
  die "no codex review found on PR — cannot run claude turn"
fi

# Render the prompt.
PROMPT_FILE="$ID/claude.prompt.md"
sed \
  -e "s|{{REPO_OWNER}}|${REPO_OWNER}|g" \
  -e "s|{{REPO_NAME}}|${REPO_NAME}|g" \
  -e "s|{{PR_NUMBER}}|${PR_NUMBER}|g" \
  -e "s|{{REPO_DIR}}|${REPO_DIR}|g" \
  -e "s|{{BASE_REF}}|${BASE_REF}|g" \
  -e "s|{{HEAD_REF}}|${HEAD_REF}|g" \
  -e "s|{{ITER}}|${ITER}|g" \
  -e "s|{{MAX_ITER}}|${MAX_ITER}|g" \
  -e "s|{{LATEST_REVIEW_FILE}}|${LATEST_REVIEW_FILE}|g" \
  -e "s|{{LATEST_INLINE_FILE}}|${LATEST_INLINE_FILE}|g" \
  -e "s|{{THREAD_FILE}}|${THREAD_FILE}|g" \
  -e "s|{{GH_USER}}|${GH_USER}|g" \
  "$HERE/prompts/claude.md" > "$PROMPT_FILE"

log "claude: iter $ITER — running"

# Persistent session: pin a UUID on iter 1 via --session-id, then --resume it.
# This gives Claude its own internal memory of the whole review, on top of the
# public PR thread it re-reads from disk each turn.
CLAUDE_SESSION_FILE="$STATE_DIR/claude.session.uuid"
if [[ -s "$CLAUDE_SESSION_FILE" ]]; then
  CLAUDE_SESSION_UUID=$(<"$CLAUDE_SESSION_FILE")
  CLAUDE_SESSION_ARG=(--resume "$CLAUDE_SESSION_UUID")
  log "claude: resuming session $CLAUDE_SESSION_UUID"
else
  CLAUDE_SESSION_UUID=$(gen_uuid)
  printf '%s\n' "$CLAUDE_SESSION_UUID" > "$CLAUDE_SESSION_FILE"
  CLAUDE_SESSION_ARG=(--session-id "$CLAUDE_SESSION_UUID")
  log "claude: starting new session $CLAUDE_SESSION_UUID"
fi

# claude -p runs non-interactively; --dangerously-skip-permissions is required
# for unattended operation (user authorized this).
set +e
( cd "$REPO_DIR" && \
  claude -p \
    "${CLAUDE_SESSION_ARG[@]}" \
    --dangerously-skip-permissions \
    --add-dir "$REPO_DIR" \
    --append-system-prompt "You are operating as an autonomous PR implementer bot. Distinct identity for any git commits: name='${CLAUDE_GIT_NAME}', email='${CLAUDE_GIT_EMAIL}'. Never amend or force-push." \
    "$(cat "$PROMPT_FILE")" \
    > "$ID/claude.stdout" 2> "$ID/claude.stderr" )
RC=$?
set -e

log "claude: iter $ITER — exit $RC"

if [[ $RC -ne 0 ]]; then
  log "claude stderr (tail):"
  tail -20 "$ID/claude.stderr" >&2 || true
  exit 1
fi

if grep -q '\[CLAUDE_TURN: COMPLETE\]' "$ID/claude.stdout"; then
  log "claude: turn complete"
  exit 0
else
  log "claude: missing [CLAUDE_TURN: COMPLETE] marker — assuming partial"
  exit 1
fi
