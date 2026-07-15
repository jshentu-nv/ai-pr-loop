#!/usr/bin/env bash
# One Claude implementer iteration. Same env contract as codex_turn.sh, with
# CLAUDE_MODEL / CLAUDE_EFFORT in place of the CODEX_* knobs.
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

# Optional human-supplied reference material (web links / notes / files),
# rendered by run.sh to $CONTEXT_FILE. Inject a one-line pointer when present;
# the agent reads the file (and fetches any URLs) itself.
if [[ "${HAS_CONTEXT:-0}" == "1" ]]; then
  CONTEXT_NOTE="**Additional context for this PR.** The operator attached trusted reference material at \`${CONTEXT_FILE}\`. Read it now and fetch any URLs it lists (via WebFetch). Factor it into your fixes and replies on every iteration — it supplements the PR description and the repo's conventions; weigh it alongside them as authoritative background."
else
  CONTEXT_NOTE=''
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
  -e "s|{{CONTEXT_NOTE}}|${CONTEXT_NOTE}|g" \
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

# Model for the implementer, set by the orchestrator's --claude-model
# (default: fable — Claude Fable 5; the alias resolves to the latest model in
# the claude CLI). "off" leaves the CLI/settings default untouched.
CLAUDE_MODEL_ARG=()
CLAUDE_MODEL_RESOLVED="${CLAUDE_MODEL:-fable}"
case "$CLAUDE_MODEL_RESOLVED" in
  off|'') CLAUDE_MODEL_ARG=() ;;
  *)      CLAUDE_MODEL_ARG=(--model "$CLAUDE_MODEL_RESOLVED") ;;
esac
(( ${#CLAUDE_MODEL_ARG[@]} > 0 )) && log "claude: model = ${CLAUDE_MODEL_RESOLVED}"

# Permission safety net. --dangerously-skip-permissions is silently downgraded
# to the default permission mode on some hosts (managed no-bypass policies, and
# nested launches from inside another Claude Code session — the skill path). In
# default mode a -p session auto-denies every out-of-dir read and Bash call, so
# the turn dies unable to even read the review. Grant what the turn needs via
# the sanctioned settings mechanism instead: auto-accept edits in the working
# dirs, allow Bash/WebFetch/WebSearch, and mount $STATE_DIR (review files) as a
# second working dir below. Where bypass is honored these are no-ops.
CLAUDE_PERMISSIONS='"permissions": {"defaultMode": "acceptEdits", "allow": ["Bash", "WebFetch", "WebSearch"]}'

# Reasoning effort for the implementer, set by the orchestrator's --claude-effort
# (default: ultracode). "ultracode" sends xhigh reasoning + dynamic-workflow
# orchestration via --settings (the documented headless mechanism; degrades to
# plain xhigh if orchestration doesn't apply in -p mode). A bare level uses
# --effort. "off" leaves the CLI/settings effort default untouched. The single
# --settings payload always carries the permission safety net above.
CLAUDE_EFFORT_ARG=()
CLAUDE_SETTINGS="{${CLAUDE_PERMISSIONS}}"
case "${CLAUDE_EFFORT:-ultracode}" in
  ultracode)                 CLAUDE_SETTINGS="{\"ultracode\": true, ${CLAUDE_PERMISSIONS}}" ;;
  low|medium|high|xhigh|max) CLAUDE_EFFORT_ARG=(--effort "${CLAUDE_EFFORT}") ;;
  off|'')                    ;;
  *)                         log "claude: unknown CLAUDE_EFFORT='${CLAUDE_EFFORT}' — using CLI default" ;;
esac
log "claude: effort = ${CLAUDE_EFFORT:-ultracode}"

# claude -p runs non-interactively; --dangerously-skip-permissions is required
# for unattended operation (user authorized this).
set +e
( cd "$REPO_DIR" && \
  claude -p \
    "${CLAUDE_SESSION_ARG[@]}" \
    "${CLAUDE_MODEL_ARG[@]}" \
    "${CLAUDE_EFFORT_ARG[@]}" \
    --settings "$CLAUDE_SETTINGS" \
    --dangerously-skip-permissions \
    --add-dir "$REPO_DIR" \
    --add-dir "$STATE_DIR" \
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
