#!/usr/bin/env bash
# Closing turn of a LOCAL review (run.sh --local), run once the reviewer and
# the implementer agree. It:
#   1. asks the implementer to compose one commit message for the whole
#      review — what the change does, plus the findings, fixes, and decisions
#      that shaped the final diff;
#   2. squashes every local round into a single commit with that message;
#   3. pushes that one commit (unless --no-push);
#   4. refreshes the PR/MR title and description if the change made them
#      stale (PR/MR scope only — the one and only forge write of the run).
#
# Same env contract as claude_turn.sh, plus LOCAL_SCOPE / NO_PUSH.
#
# Exits: 0 finalized (pushed, or held locally by --no-push)
#        3 nothing to finalize (no local rounds, or they cancel out)
#        1 on error — the local rounds are left untouched for a re-run.
set -euo pipefail

HERE="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

[[ "$LOCAL_MODE" == "1" ]] || die "finalize_turn.sh runs only in local review mode"

LOCAL_DIR=$(local_state_dir)
mkdir -p "$LOCAL_DIR"
BASE_FILE=$(local_base_file)
MSG_FILE="$LOCAL_DIR/commit-message.txt"
TITLE_FILE="$LOCAL_DIR/pr-title.txt"
DESC_FILE="$LOCAL_DIR/pr-description.md"
FINALIZED_FILE="$LOCAL_DIR/finalized.sha"
PUSHED_FILE="$LOCAL_DIR/pushed.sha"

if [[ ! -s "$BASE_FILE" ]]; then
  log "finalize: no squash base recorded — nothing to finalize"
  exit 3
fi
BASE_SHA=$(<"$BASE_FILE")

# The review turn that approved may have left build output in the worktree;
# drop it, keeping every local round.
sync_repo_to_local_head

HEAD_SHA=$(git -C "$REPO_DIR" rev-parse HEAD)
git -C "$REPO_DIR" merge-base --is-ancestor "$BASE_SHA" "$HEAD_SHA" \
  || die "HEAD ($HEAD_SHA) in $REPO_DIR no longer descends from the squash base ($BASE_SHA) — refusing to rewrite history the loop did not create"

ROUNDS=$(git -C "$REPO_DIR" rev-list --count "${BASE_SHA}..${HEAD_SHA}")
if [[ "$ROUNDS" == "0" ]]; then
  log "finalize: the review produced no commits — nothing to push"
  exit 3
fi

# --- 1. compose the message ---------------------------------------------------
#
# Skipped when the squash already exists (a re-run after a rejected push, or
# after --no-push): the message is composed once, and re-composing it would
# spend a full agent turn to say the same thing.
if [[ -s "$FINALIZED_FILE" && "$(<"$FINALIZED_FILE")" == "$HEAD_SHA" && -s "$MSG_FILE" ]]; then
  log "finalize: $HEAD_SHA is already the squashed commit — reusing its message"
  SQUASHED=1
else
  SQUASHED=0
  FID="$LOCAL_DIR/finalize"
  mkdir -p "$FID"
  rm -f "$MSG_FILE" "$TITLE_FILE" "$DESC_FILE"

  if [[ "${HAS_CONTEXT:-0}" == "1" ]]; then
    CONTEXT_NOTE="**Additional context.** The operator attached trusted reference material at \`${CONTEXT_FILE}\`. Read it and weigh it alongside the repository's own conventions."
  else
    CONTEXT_NOTE=''
  fi

  # BASE_REF/HEAD_REF are NOT sed-substituted (see codex_turn.sh): a
  # forge-supplied branch name can carry sed/shell metacharacters, so the
  # template references the exported shell variables instead.
  PROMPT_FILE="$FID/finalize.prompt.md"
  forge_vocab
  render_forge_blocks "$HERE/prompts/finalize.md" "$(prompt_tags)" \
  | sed \
    -e "s|{{FORGE_NAME}}|${FORGE_NAME}|g" \
    -e "s|{{PR_NOUN_LONG}}|${PR_NOUN_LONG}|g" \
    -e "s|{{PR_NOUN}}|${PR_NOUN}|g" \
    -e "s|{{PR_REF}}|${PR_REF}|g" \
    -e "s|{{REPO_OWNER}}|${REPO_OWNER}|g" \
    -e "s|{{REPO_NAME}}|${REPO_NAME}|g" \
    -e "s|{{REPO_SLUG}}|${REPO_SLUG:-${REPO_OWNER}/${REPO_NAME}}|g" \
    -e "s|{{FORGE_HOST}}|${FORGE_HOST:-github.com}|g" \
    -e "s|{{FORGE_SCHEME}}|${FORGE_SCHEME:-https}|g" \
    -e "s|{{PROJECT_ENC}}|${PROJECT_ENC:-}|g" \
    -e "s|{{PR_NUMBER}}|${PR_NUMBER}|g" \
    -e "s|{{REPO_DIR}}|${REPO_DIR}|g" \
    -e "s|{{BASE_SHA}}|${BASE_SHA}|g" \
    -e "s|{{ROUNDS}}|${ROUNDS}|g" \
    -e "s|{{HISTORY_DIR}}|${STATE_DIR}|g" \
    -e "s|{{MESSAGE_FILE}}|${MSG_FILE}|g" \
    -e "s|{{TITLE_FILE}}|${TITLE_FILE}|g" \
    -e "s|{{DESC_FILE}}|${DESC_FILE}|g" \
    -e "s|{{GH_USER}}|${GH_USER}|g" \
    -e "s|{{CONTEXT_NOTE}}|${CONTEXT_NOTE}|g" \
    > "$PROMPT_FILE"

  log "finalize: composing one commit message for $ROUNDS local round(s)"
  claude_prepare_cli
  set +e
  claude_run_prompt "$PROMPT_FILE" "$FID/finalize.stdout" "$FID/finalize.stderr"
  RC=$?
  set -e
  if [[ $RC -ne 0 ]]; then
    log "finalize: claude exited $RC"
    tail -20 "$FID/finalize.stderr" >&2 || true
    exit 1
  fi
  grep -q '\[CLAUDE_FINALIZE: COMPLETE\]' "$FID/finalize.stdout" \
    || { log "finalize: missing [CLAUDE_FINALIZE: COMPLETE] marker — assuming partial"; exit 1; }
  # The message file is the turn's contract, exactly as the review file is
  # for a round: a marker printed without it is not a finished turn.
  [[ -s "$MSG_FILE" ]] \
    || { log "finalize: no commit message written to $MSG_FILE"; exit 1; }
  # A message whose first line is empty produces a subject-less commit.
  [[ -n "$(head -1 "$MSG_FILE" | tr -d '[:space:]')" ]] \
    || { log "finalize: the composed message starts with a blank subject line ($MSG_FILE)"; exit 1; }
fi

# --- 2. squash ----------------------------------------------------------------
if (( SQUASHED == 0 )); then
  # reset --soft keeps the tree and index exactly as they are and moves HEAD
  # back to the base, so the single commit below carries the review's net
  # change. On any failure HEAD goes back where it was — the rounds survive.
  git -C "$REPO_DIR" reset --quiet --soft "$BASE_SHA" \
    || die "could not move HEAD back to the squash base $BASE_SHA in $REPO_DIR"
  if git -C "$REPO_DIR" diff --cached --quiet; then
    log "finalize: the local rounds cancel out (identical tree to $BASE_SHA) — nothing to push"
    local_record_tip
    rm -f "$FINALIZED_FILE"
    exit 3
  fi
  if ! git -C "$REPO_DIR" \
        -c "user.name=$CLAUDE_GIT_NAME" -c "user.email=$CLAUDE_GIT_EMAIL" \
        commit --quiet -F "$MSG_FILE"; then
    git -C "$REPO_DIR" reset --quiet --soft "$HEAD_SHA" \
      || log "finalize: WARNING — could not restore HEAD to $HEAD_SHA after the failed commit"
    die "the squash commit failed (a commit hook may have rejected it); the message is at $MSG_FILE"
  fi
  HEAD_SHA=$(git -C "$REPO_DIR" rev-parse HEAD)
  printf '%s\n' "$HEAD_SHA" > "$FINALIZED_FILE"
  local_record_tip
  log "finalize: squashed $ROUNDS local round(s) into $HEAD_SHA"
  log "finalize: $(git -C "$REPO_DIR" log -1 --format=%s "$HEAD_SHA")"
fi

# --- 3. push ------------------------------------------------------------------
if (( ${NO_PUSH:-0} == 1 )); then
  log "finalize: --no-push — $HEAD_SHA stays in $REPO_DIR; re-run without --no-push to push it"
  exit 0
fi
if ! git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1; then
  log "finalize: $REPO_DIR has no origin remote — $HEAD_SHA stays local"
  exit 0
fi

# Never force: the single commit must fast-forward the branch it lands on. A
# rejection means the branch moved while the review ran, and reconciling that
# is the operator's call, not the loop's.
log "finalize: pushing $HEAD_SHA to origin"
if ! git -C "$REPO_DIR" push origin "HEAD:refs/heads/$HEAD_REF" >&2; then
  die "push of $HEAD_SHA was rejected (the branch moved while the review ran?). The squashed commit is in $REPO_DIR at $HEAD_SHA — reconcile it there and push manually; the loop never force-pushes"
fi
printf '%s\n' "$HEAD_SHA" > "$PUSHED_FILE"

# --- 4. keep the PR/MR title and description true -----------------------------
#
# The one forge write of a local run, and only when the change made them
# stale. Both files are written by the finalize turn from the CURRENT values,
# so they replace the whole field.
if [[ "$LOCAL_SCOPE" != "branch" ]] && [[ -s "$TITLE_FILE" || -s "$DESC_FILE" ]]; then
  # GitLab runs a leading-slash line as a quick action; /draft would flip the
  # MR to draft, /close would close it. Drop the description update rather
  # than fire one — the commit is already pushed, so this is the operator's
  # to finish, not a reason to fail the run.
  if [[ "$FORGE" == "gitlab" && -s "$DESC_FILE" ]] \
     && grep -qE '^/(draft|todo|close|reopen|merge|approve|unapprove|assign|unassign|label|unlabel|milestone|target_branch|wip|award|spend|estimate|lock|unlock|confidential|move|duplicate|remove_source_branch|submit_review|request_review)\b' "$DESC_FILE"; then
    log "finalize: WARNING — the composed description at $DESC_FILE starts a line with a GitLab quick action; not sending it. Update the MR description by hand"
    rm -f "$DESC_FILE"
  fi
  # A file holding only whitespace proposes nothing.
  NEW_TITLE=''
  if [[ -s "$TITLE_FILE" ]]; then NEW_TITLE=$(cat "$TITLE_FILE"); fi
  NEW_DESC=0
  if [[ -s "$DESC_FILE" ]] && grep -q '[^[:space:]]' "$DESC_FILE"; then NEW_DESC=1; fi
  if [[ -z "${NEW_TITLE//[[:space:]]/}" ]] && (( NEW_DESC == 0 )); then
    log "finalize: no title/description change proposed"
  else
    case "$FORGE" in
      gitlab)
        JQ_ARGS=(-n)
        JQ_FILTER='{}'
        if [[ -n "${NEW_TITLE//[[:space:]]/}" ]]; then
          JQ_ARGS+=(--arg t "$NEW_TITLE"); JQ_FILTER="$JQ_FILTER + {title: \$t}"
        fi
        if (( NEW_DESC == 1 )); then
          JQ_ARGS+=(--rawfile d "$DESC_FILE"); JQ_FILTER="$JQ_FILTER + {description: \$d}"
        fi
        if jq "${JQ_ARGS[@]}" "$JQ_FILTER" \
           | curl -sSf -X PUT -H "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" \
               -H 'Content-Type: application/json' --data @- \
               "${FORGE_SCHEME:-https}://${FORGE_HOST}/api/v4/projects/${PROJECT_ENC}/merge_requests/${PR_NUMBER}" \
               >/dev/null; then
          log "finalize: refreshed the MR title/description"
        else
          log "finalize: WARNING — the MR title/description update failed; the pushed commit is unaffected (proposed text: $TITLE_FILE / $DESC_FILE)"
        fi
        ;;
      *)
        GH_EDIT_ARGS=()
        if [[ -n "${NEW_TITLE//[[:space:]]/}" ]]; then GH_EDIT_ARGS+=(--title "$NEW_TITLE"); fi
        if (( NEW_DESC == 1 )); then GH_EDIT_ARGS+=(--body-file "$DESC_FILE"); fi
        if gh pr edit "$PR_NUMBER" --repo "${REPO_OWNER}/${REPO_NAME}" \
             "${GH_EDIT_ARGS[@]}" >/dev/null; then
          log "finalize: refreshed the PR title/description"
        else
          log "finalize: WARNING — the PR title/description update failed; the pushed commit is unaffected (proposed text: $TITLE_FILE / $DESC_FILE)"
        fi
        ;;
    esac
  fi
fi

# The rounds are on the remote now: the next invocation starts a new local run
# from the new head instead of stacking on a base that no longer exists there.
rm -f "$BASE_FILE" "$FINALIZED_FILE"
log "finalize: done — one commit ($HEAD_SHA) pushed for this review"
exit 0
