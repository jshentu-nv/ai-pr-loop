#!/usr/bin/env bash
# One Claude implementer iteration. Same env contract as codex_turn.sh, with
# CLAUDE_MODEL / CLAUDE_EFFORT / CLAUDE_PERMS in place of the CODEX_* knobs.
# Exits 0 on success (turn marker found), 1 on error.
set -euo pipefail

HERE="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

ID=$(iter_dir "$ITER")
mkdir -p "$ID"

# This iter's codex output, split by surface:
#   - LATEST_REVIEW_FILE  → the review body (cross-cutting + verdict). In
#                           forge mode it is extracted from the summary
#                           comment; in local mode the reviewer wrote it
#                           there directly.
#   - LATEST_INLINE_FILE  → NDJSON of inline findings, one per line:
#                            { id, discussion_id, path, line, body }
#     GitHub: id is what Claude's in_reply_to replies target (discussion_id
#     is null). GitLab: replies POST to discussions/<discussion_id>/notes.
#     Local mode has no inline surface — findings cite path:line in the
#     review file — so it stays empty.
THREAD_FILE="$ID/thread.ndjson"
LATEST_REVIEW_FILE=$(local_artifact_path codex "$ITER")
LATEST_INLINE_FILE="$ID/codex-inline.ndjson"
# Where this turn's response goes in local mode. It is the turn's completion
# contract, so a leftover from a crashed earlier attempt is removed first:
# only a response written by THIS run may count as done.
RESPONSE_FILE=$(local_artifact_path claude "$ITER")

if [[ "$LOCAL_MODE" == "1" ]]; then
  rm -f "$RESPONSE_FILE"
  : > "$THREAD_FILE"
  : > "$LATEST_INLINE_FILE"
else
  # A failed fetch fails the turn here, not at the review-missing guard
  # below: dying there would misread a forge outage as a broken review.
  fetch_ai_thread > "$THREAD_FILE" \
    || die "could not fetch the AI thread — not answering a partial or empty one"

  # Same structural summary predicate as latest_ai_comment_iter /
  # ai_summary_posted: a tagged general note without the summary wrapper —
  # even one quoting the banner in its prose, e.g. an inline finding that
  # lost its position — must not be mistaken for the review to answer.
  extract_ai_summary_body codex "$ITER" "$THREAD_FILE" > "$LATEST_REVIEW_FILE"

  jq -c --arg t "$CODEX_MARKER_TAG" --argjson it "$ITER" '
      select(.tag==$t and .iter==$it and .surface=="inline")
      | {id, discussion_id, path, line, body}' \
      "$THREAD_FILE" > "$LATEST_INLINE_FILE"
fi

# No fallback to an older review here. Reaching this turn means codex's
# iter-$ITER review exists (codex_turn verifies it after posting/writing, and
# the resume high-water counts the same artifact), so failing to find it means
# the fetch is broken or the thread is inconsistent — and answering a stale
# review would advance the loop past an incomplete one. Die instead; the
# next invocation resumes at this same iteration.
# (Missing inline is different: no inline findings is a valid outcome.)
if [[ ! -s "$LATEST_REVIEW_FILE" ]]; then
  die "codex review for iter $ITER not found at $LATEST_REVIEW_FILE — cannot run claude turn"
fi

# Optional human-supplied reference material (web links / notes / files),
# rendered by run.sh to $CONTEXT_FILE. Inject a one-line pointer when present;
# the agent reads the file (and fetches any URLs) itself.
if [[ "${HAS_CONTEXT:-0}" == "1" ]]; then
  CONTEXT_NOTE="**Additional context for this PR.** The operator attached trusted reference material at \`${CONTEXT_FILE}\`. Read it now and fetch any URLs it lists (via WebFetch). Factor it into your fixes and replies on every iteration — it supplements the PR description and the repo's conventions; weigh it alongside them as authoritative background."
else
  CONTEXT_NOTE=''
fi


# Render the prompt. GitLab loops use the gitlab prompt variant — same
# implementer contract, MR/discussions API commands (curl + PRIVATE-TOKEN)
# instead of gh.
#
# BASE_REF/HEAD_REF are NOT sed-substituted (see codex_turn.sh): a
# forge-supplied branch name can carry sed/shell metacharacters, so the
# templates reference the exported $BASE_REF / $HEAD_REF shell variables
# and the agent's shell expands them safely.
PROMPT_TEMPLATE="$HERE/prompts/claude.md"
PROMPT_FILE="$ID/claude.prompt.md"
forge_vocab
render_forge_blocks "$PROMPT_TEMPLATE" "$(prompt_tags)" \
| sed \
  -e "s|{{FORGE_NAME}}|${FORGE_NAME}|g" \
  -e "s|{{PR_NOUN_LONG}}|${PR_NOUN_LONG}|g" \
  -e "s|{{PR_NOUN}}|${PR_NOUN}|g" \
  -e "s|{{PR_REF}}|${PR_REF}|g" \
  -e "s|{{SUMMARY_NOUN}}|${SUMMARY_NOUN}|g" \
  -e "s|{{INLINE_NOUN_TITLE}}|${INLINE_NOUN_TITLE}|g" \
  -e "s|{{INLINE_NOUN}}|${INLINE_NOUN}|g" \
  -e "s|{{TOKEN_NOUN}}|${TOKEN_NOUN}|g" \
  -e "s|{{AUTOLINK_SIGILS}}|${AUTOLINK_SIGILS}|g" \
  -e "s|{{REPO_OWNER}}|${REPO_OWNER}|g" \
  -e "s|{{REPO_NAME}}|${REPO_NAME}|g" \
  -e "s|{{REPO_SLUG}}|${REPO_SLUG:-${REPO_OWNER}/${REPO_NAME}}|g" \
  -e "s|{{FORGE_HOST}}|${FORGE_HOST:-github.com}|g" \
  -e "s|{{FORGE_SCHEME}}|${FORGE_SCHEME:-https}|g" \
  -e "s|{{PROJECT_ENC}}|${PROJECT_ENC:-}|g" \
  -e "s|{{PR_NUMBER}}|${PR_NUMBER}|g" \
  -e "s|{{REPO_DIR}}|${REPO_DIR}|g" \
  -e "s|{{ITER}}|${ITER}|g" \
  -e "s|{{MAX_ITER}}|${MAX_ITER}|g" \
  -e "s|{{LATEST_REVIEW_FILE}}|${LATEST_REVIEW_FILE}|g" \
  -e "s|{{LATEST_INLINE_FILE}}|${LATEST_INLINE_FILE}|g" \
  -e "s|{{RESPONSE_FILE}}|${RESPONSE_FILE}|g" \
  -e "s|{{HISTORY_DIR}}|${STATE_DIR}|g" \
  -e "s|{{THREAD_FILE}}|${THREAD_FILE}|g" \
  -e "s|{{GH_USER}}|${GH_USER}|g" \
  -e "s|{{CONTEXT_NOTE}}|${CONTEXT_NOTE}|g" \
  > "$PROMPT_FILE"

log "claude: iter $ITER — running"

# Resolve the CLI knobs (session, model, effort, permissions) and run this
# iteration's prompt. Both live in lib/common.sh so the finalize turn of a
# local review runs with exactly the same setup.
claude_prepare_cli
set +e
claude_run_prompt "$PROMPT_FILE" "$ID/claude.stdout" "$ID/claude.stderr"
RC=$?
set -e

log "claude: iter $ITER — exit $RC"

# The turn's completion contract — the summary comment in forge mode, the
# written response file in local mode. The prompt produces it LAST, after
# every fix and reply, so the stdout marker alone isn't proof of completion:
# a failed POST or a crash mid-reply would otherwise advance the loop past a
# half-done response. Probed BEFORE the failure exits below, as in
# codex_turn.sh: a response that LANDED is a real, public reply even when
# the CLI then died or lost its stdout marker, and resume advances past this
# iteration on that artifact — so its round report is emitted here or never.
RESPONSE_LANDED=0
turn_artifact_landed claude "$ITER" && RESPONSE_LANDED=1

if (( RESPONSE_LANDED == 1 )); then
  emit_round_report claude "$ITER"
fi

if [[ $RC -ne 0 ]]; then
  log "claude stderr (tail):"
  tail -20 "$ID/claude.stderr" >&2 || true
  if (( RESPONSE_LANDED == 1 )); then
    log "claude: the iter $ITER response landed before the CLI failure — round report captured"
  fi
  exit 1
fi

if ! grep -q '\[CLAUDE_TURN: COMPLETE\]' "$ID/claude.stdout"; then
  log "claude: missing [CLAUDE_TURN: COMPLETE] marker — assuming partial"
  if (( RESPONSE_LANDED == 1 )); then
    log "claude: the iter $ITER response landed despite the missing marker — round report captured"
  fi
  exit 1
fi

if (( RESPONSE_LANDED == 0 )); then
  if [[ "$LOCAL_MODE" == "1" ]]; then
    log "claude: iter $ITER response file $RESPONSE_FILE is missing or empty — failing the turn (stdout marker ignored)"
  else
    log "claude: iter $ITER summary comment not found on the PR — failing the turn (stdout marker ignored)"
  fi
  exit 1
fi

log "claude: turn complete"
exit 0
