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
# A PR/MR review whose rounds land no net change skips the squash and push,
# but still runs the closing turn for step 4: the review may have agreed
# title/description corrections, and that update is the one remaining write.
#
# Same env contract as claude_turn.sh, plus LOCAL_SCOPE / NO_PUSH.
#
# Exits: 0 finalized — pushed, landed locally when there is no origin
#          (terminal), or held back by --no-push (resumable)
#        3 nothing to land — no squash base, no commits, or net-zero
#          rounds (terminal when a base was recorded: the review is over)
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
FINALIZED_FILE=$(local_finalized_file)
INPROGRESS_FILE=$(local_finalize_inprogress_file)
BASELINE_FILE="$LOCAL_DIR/metadata-baseline.json"   # pr scope only
# --audit only: the branch its PR/MR targets, recorded when the review
# branch was created. Its presence is what makes this an audit.
AUDIT_PR_BASE_FILE="$LOCAL_DIR/audit-pr-base"
PR_URL_FILE="$LOCAL_DIR/pr-url"
AUDIT_PR_BASE=''
[[ -s "$AUDIT_PR_BASE_FILE" ]] && AUDIT_PR_BASE=$(<"$AUDIT_PR_BASE_FILE")
IS_AUDIT=0; [[ -n "$AUDIT_PR_BASE" ]] && IS_AUDIT=1

# Record a finalize outcome that has not landed terminally yet — the tip it
# covers and what it is — as one atomic journal write.
hold_outcome() {  # <sha> <squash|nocommit>
  local_write_finalized "$1" "$2"
}

# The review's outcome is in its final resting place: record that
# terminally and clear the in-progress markers, so the next invocation
# starts a NEW review (via --restart) instead of resuming this one.
# completed.sha is published FIRST, and atomically (a torn write must not
# read as absent): startup treats it as authoritative and purges stale
# markers found beside it, whereas the reverse order could leave review
# artifacts with neither marker — and a stale APPROVED verdict would then
# complete a tip the review never saw.
mark_completed() {
  write_state_atomic "$(local_completed_file)" "$1"
  rm -f "$BASE_FILE" "$FINALIZED_FILE" "$INPROGRESS_FILE" \
        "$(local_tip_file)" "$(local_origin_file)"
}

# The PR/MR's current title and body, as one canonical string per forge —
# recorded when a title/description proposal is composed, and compared
# right before delivery: the proposal replaces the WHOLE field, so a human
# edit made in between must never be overwritten.
fetch_pr_text() {
  case "$FORGE" in
    gitlab)
      gl_api_get "projects/${PROJECT_ENC}/merge_requests/${PR_NUMBER}" \
      | jq -c '{title: .title, body: .description}'
      ;;
    *)
      gh pr view "$PR_NUMBER" --repo "${REPO_OWNER}/${REPO_NAME}" --json title,body
      ;;
  esac
}

# --audit's closing step: one claude turn that opens the PR/MR for the
# pushed review branch by following the loop's own skill. Returns 0 with the
# URL in $PR_URL_FILE. The turn runs inside the repo under review, so the
# skill directory — which lives with the loop, not with that repo — is
# handed to it explicitly.
open_pr_turn() {
  local d="$LOCAL_DIR/open-pr" skill="$HERE/.claude/skills/open-pr" rc
  mkdir -p "$d"
  [[ -s "$skill/SKILL.md" ]] || { log "finalize: the open-pr skill is missing at $skill/SKILL.md"; return 1; }
  rm -f "$PR_URL_FILE"
  # Branch names go through the environment, never through sed: a branch
  # name can carry sed metacharacters, and --pr-branch is operator input.
  sed \
    -e "s|{{SKILL_FILE}}|${skill}/SKILL.md|g" \
    -e "s|{{TITLE_FILE}}|${TITLE_FILE}|g" \
    -e "s|{{DESC_FILE}}|${DESC_FILE}|g" \
    -e "s|{{PR_URL_FILE}}|${PR_URL_FILE}|g" \
    -e "s|{{REPO_DIR}}|${REPO_DIR}|g" \
    "$HERE/prompts/open-pr.md" > "$d/open-pr.prompt.md"
  export OPEN_PR_HEAD="$HEAD_REF" OPEN_PR_BASE="$AUDIT_PR_BASE" \
         OPEN_PR_TITLE_FILE="$TITLE_FILE" OPEN_PR_DESC_FILE="$DESC_FILE" \
         OPEN_PR_URL_FILE="$PR_URL_FILE"
  CLAUDE_EXTRA_DIR_ARGS=(--add-dir "$skill")
  claude_prepare_cli
  set +e
  claude_run_prompt "$d/open-pr.prompt.md" "$d/open-pr.stdout" "$d/open-pr.stderr"
  rc=$?
  set -e
  CLAUDE_EXTRA_DIR_ARGS=()
  if (( rc != 0 )); then
    log "finalize: the open-pr turn exited $rc"
    tail -20 "$d/open-pr.stderr" >&2 || true
    return 1
  fi
  # The written URL is the contract, exactly as the review file is for a
  # round: a marker printed without it is not a finished step.
  [[ -s "$PR_URL_FILE" ]] \
    || { log "finalize: the open-pr turn wrote no URL to $PR_URL_FILE"; return 1; }
  [[ "$(<"$PR_URL_FILE")" =~ ^https?:// ]] \
    || { log "finalize: the open-pr turn wrote something that is not a URL to $PR_URL_FILE"; rm -f "$PR_URL_FILE"; return 1; }
  return 0
}

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

# The review may land nothing: no commits at all (every finding answered by
# pushback), or rounds whose edits cancel out.
NET_KIND=''
if [[ "$ROUNDS" == "0" ]]; then
  NET_KIND='no commits'
elif [[ "$(git -C "$REPO_DIR" rev-parse "${BASE_SHA}^{tree}")" == "$(git -C "$REPO_DIR" rev-parse "${HEAD_SHA}^{tree}")" ]]; then
  NET_KIND='cancel out'
fi

# Move HEAD back to the base when cancelled-out rounds left it ahead, then
# record the review as terminally complete with nothing landed.
finish_net_zero() {
  log "finalize: the local rounds land nothing ($NET_KIND) — nothing to push; the review record stays at $STATE_DIR"
  if [[ "$HEAD_SHA" != "$BASE_SHA" ]]; then
    git_safe -C "$REPO_DIR" reset --quiet --soft "$BASE_SHA" \
      || die "could not move HEAD back to the squash base $BASE_SHA in $REPO_DIR"
    local_record_tip
  fi
  mark_completed "$BASE_SHA"
}

# Branch scope has no title or description to keep true, and a review-only
# run must never spend an implementer turn or write to the forge — for
# both, nothing-to-land is terminal right here. PR/MR scope otherwise
# continues: the closing turn below runs in metadata-only mode.
if [[ -n "$NET_KIND" ]] && [[ "$LOCAL_SCOPE" == "branch" || "${REVIEW_ONLY:-0}" == "1" ]]; then
  finish_net_zero
  exit 3
fi

# What Codex approved, and the ONLY tree the squash may push.
APPROVED_TREE=$(git -C "$REPO_DIR" rev-parse "${HEAD_SHA}^{tree}") \
  || die "could not read the tree of $HEAD_SHA"

# squash: compose the one commit's message, squash, push, refresh metadata.
# nocommit: nothing lands — the turn only assesses the PR/MR text.
MODE=squash
[[ -n "$NET_KIND" ]] && MODE=nocommit

# --- 1. the closing turn --------------------------------------------------
#
# Skipped when the turn's output already exists for this exact tip (a
# re-run after a rejected push or --no-push): the message — or, in
# nocommit mode, the title/description proposal — is composed once, and
# re-composing it would spend a full agent turn to say the same thing.
if [[ "$(local_finalized_sha)" == "$HEAD_SHA" && "$(local_finalized_kind)" == "$MODE" ]] \
   && { [[ "$MODE" == "nocommit" ]] || [[ -s "$MSG_FILE" ]]; } \
   && { (( IS_AUDIT == 0 )) || [[ -s "$TITLE_FILE" && -s "$DESC_FILE" ]]; }; then
  if [[ "$MODE" == "squash" ]]; then
    log "finalize: $HEAD_SHA is already the squashed commit — reusing its message"
  else
    log "finalize: the closing turn already assessed $HEAD_SHA — reusing its held title/description proposal"
  fi
  SQUASHED=1
else
  SQUASHED=0
  FID="$LOCAL_DIR/finalize"
  mkdir -p "$FID"
  rm -f "$MSG_FILE" "$TITLE_FILE" "$DESC_FILE" "$BASELINE_FILE"

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
  render_forge_blocks "$HERE/prompts/finalize.md" "$(prompt_tags) $MODE" \
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

  if [[ "$MODE" == "squash" ]]; then
    log "finalize: composing one commit message for $ROUNDS local round(s)"
  else
    log "finalize: the rounds land nothing ($NET_KIND) — asking the implementer whether the title/description need refreshing"
  fi
  # The only destination this review may push to is the one recorded when
  # the review started (local_setup_repo). Anything that redirected it
  # since — whichever turn or invocation — fails here, BEFORE an agent
  # turn is spent. A missing record fails closed too: a turn could delete
  # the file to get a poisoned re-pin later.
  ORIGIN_DEST=$(origin_dest)
  [[ -s "$(local_origin_file)" ]] \
    || die "no pinned origin destination is recorded for this review ($(local_origin_file) is missing — it is written when the review starts, and a turn may have removed it). Write the intended destination there (the output of 'git remote get-url --all origin' then 'git remote get-url --push --all origin', or '(none)') and re-run"
  [[ "$ORIGIN_DEST" == "$(<"$(local_origin_file)")" ]] \
    || die "the effective destination of origin in $REPO_DIR does not match the one recorded for this review ($(printf '%s' "$(<"$(local_origin_file)")" | tr '\n' ' ')) — refusing to push anywhere the review never validated. Fix the remote configuration, or write the intended destination into $(local_origin_file)"
  # The title/description baseline is captured BEFORE the turn, so the
  # delivery-time comparison brackets everything from here on: a human
  # edit made while the turn runs, or while a proposal is held, always
  # wins over the proposal. In nocommit mode the metadata update is the
  # run's only outcome, so an unreadable baseline stops it before the
  # agent turn; in squash mode the push must not depend on a forge read —
  # the proposal is then held undelivered instead.
  if [[ "$LOCAL_SCOPE" != "branch" ]] && ! fetch_pr_text > "$BASELINE_FILE"; then
    rm -f "$BASELINE_FILE"
    if [[ "$MODE" == "nocommit" ]]; then
      die "could not read the current PR/MR title/description to baseline this turn's proposal"
    fi
    log "finalize: WARNING — could not read the current PR/MR text; any title/description proposal from this turn will be held, not delivered"
  fi
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
  if [[ "$MODE" == "squash" ]]; then
    # The message file is the turn's contract, exactly as the review file
    # is for a round: a marker printed without it is not a finished turn.
    [[ -s "$MSG_FILE" ]] \
      || { log "finalize: no commit message written to $MSG_FILE"; exit 1; }
    # A message whose first line is empty produces a subject-less commit.
    [[ -n "$(head -1 "$MSG_FILE" | tr -d '[:space:]')" ]] \
      || { log "finalize: the composed message starts with a blank subject line ($MSG_FILE)"; exit 1; }
  fi
  # An audit's PR/MR is created from these two files, so both are part of
  # this turn's contract rather than an optional refresh. Checked here,
  # where exiting 1 leaves the rounds intact and re-runnable.
  if (( IS_AUDIT == 1 )); then
    [[ -s "$TITLE_FILE" ]] \
      || { log "finalize: no PR/MR title written to $TITLE_FILE"; exit 1; }
    [[ "$(wc -l < "$TITLE_FILE")" -le 1 && -n "$(head -1 "$TITLE_FILE" | tr -d '[:space:]')" ]] \
      || { log "finalize: the PR/MR title at $TITLE_FILE must be one non-blank line"; exit 1; }
    grep -q '[^[:space:]]' "$DESC_FILE" 2>/dev/null \
      || { log "finalize: no PR/MR description written to $DESC_FILE"; exit 1; }
  fi

  # The compose turn writes text into the state dir; the approved tree must
  # come out of it untouched. A HEAD that moved means the turn committed or
  # rewrote history after Codex approved — put the checkout back on the
  # approved tip (the rogue commit stays in the reflog; leaving it checked
  # out would wedge every later resume against the recorded tip) and refuse.
  ROGUE_HEAD=$(git -C "$REPO_DIR" rev-parse HEAD)
  if [[ "$ROGUE_HEAD" != "$HEAD_SHA" ]]; then
    if [[ "$LOCAL_SCOPE" == "branch" ]]; then
      # Only the branch under review may be moved back; a foreign branch
      # the turn checked out must stay exactly where its owner left it.
      if [[ "$(git -C "$REPO_DIR" symbolic-ref --quiet HEAD 2>/dev/null)" == "refs/heads/$HEAD_REF" ]]; then
        git_safe -C "$REPO_DIR" reset --quiet --hard "$HEAD_SHA" \
          || log "finalize: WARNING — could not restore the approved tip $HEAD_SHA"
      fi
    else
      # Detached restore: never a reset, which would rewrite whatever
      # branch the turn left checked out.
      git_safe -C "$REPO_DIR" checkout --quiet --force --detach "$HEAD_SHA" \
        || log "finalize: WARNING — could not restore the approved tip $HEAD_SHA"
    fi
    die "HEAD in $REPO_DIR moved to $ROGUE_HEAD during the finalize turn (approved tip: $HEAD_SHA) — refusing to squash a tree the review never saw"
  fi
  CLEAN_MODE=detach
  if [[ "$LOCAL_SCOPE" == "branch" ]]; then
    CLEAN_MODE=attach
    [[ "$(git -C "$REPO_DIR" symbolic-ref --quiet HEAD 2>/dev/null)" == "refs/heads/$HEAD_REF" ]] \
      || die "HEAD in $REPO_DIR is no longer on the branch under review — the finalize turn switched or detached it; put it back before re-running"
  fi
  # Anything else the turn left — an edit, a staged file, build output —
  # would be committed by the squash below (reset --soft keeps the index).
  # Drop all of it: the squash must carry the approved tree exactly.
  force_clean_to_commit "$REPO_DIR" "$HEAD_SHA" "$CLEAN_MODE"
  # The worktree is clean, but .git/config is not covered by it: a turn
  # that pointed origin somewhere else (remote.origin.url or pushurl, or a
  # url.*.insteadOf / pushInsteadOf rewrite — origin_dest resolves them
  # all) would make the loop push the approved commit to a destination the
  # review never validated.
  [[ "$(origin_dest)" == "$ORIGIN_DEST" ]] \
    || die "the effective destination of origin changed during the finalize turn (was: $(printf '%s' "$ORIGIN_DEST" | tr '\n' ' ')) — refusing to push anywhere the review never validated; fix the remote configuration in $REPO_DIR and re-run"
fi

# --- 2. keep the PR/MR title and description true ------------------------------
#
# The one forge write of a local run, and only when the review left them
# stale. Both files are written by the closing turn from the CURRENT values,
# so they replace the whole field. Called after the push (squash mode), or
# as the only external write (nocommit mode).
#
# Returns 0 delivered, or nothing to deliver
#         1 delivery failed — the proposal is intact, a re-run retries it
#         2 the PR/MR text changed since the proposal was composed —
#           delivering would overwrite a human edit; the caller decides
#           whether to drop it or fail for reassessment
refresh_pr_metadata() {
  [[ "$LOCAL_SCOPE" != "branch" ]] || return 0
  [[ -s "$TITLE_FILE" || -s "$DESC_FILE" ]] || return 0
  # GitLab runs any line-leading /command in a saved description as a quick
  # action — /draft flips the MR to draft, /close closes it, /run_pipeline
  # starts CI. The command list grows with GitLab releases, so reject the
  # SYNTAX (a line whose first non-blank character opens a /word), not an
  # enumeration. Drop the description update rather than fire one — the
  # review's outcome does not depend on it, so this is the operator's to
  # finish, not a reason to fail the run.
  if [[ "$FORGE" == "gitlab" && -s "$DESC_FILE" ]] \
     && grep -qE '^[[:space:]]*/[[:alpha:]]' "$DESC_FILE"; then
    log "finalize: WARNING — the composed description at $DESC_FILE has a line starting with '/<word>', which GitLab would run as a quick action; not sending it. Update the MR description by hand"
    rm -f "$DESC_FILE"
  fi
  # A file holding only whitespace proposes nothing.
  local NEW_TITLE='' NEW_DESC=0
  if [[ -s "$TITLE_FILE" ]]; then NEW_TITLE=$(cat "$TITLE_FILE"); fi
  if [[ -s "$DESC_FILE" ]] && grep -q '[^[:space:]]' "$DESC_FILE"; then NEW_DESC=1; fi
  if [[ -z "${NEW_TITLE//[[:space:]]/}" ]] && (( NEW_DESC == 0 )); then
    log "finalize: no title/description change proposed"
    return 0
  fi
  # A proposal replaces the whole field it targets, so it is only valid
  # against the text it was composed from. No baseline at all means the
  # record was lost — reassess rather than guess.
  if [[ ! -s "$BASELINE_FILE" ]]; then
    log "finalize: the proposed title/description has no recorded baseline — not delivering it"
    return 2
  fi
  local current cur_t cur_b base_t base_b want_t want_b
  current=$(fetch_pr_text) \
    || { log "finalize: WARNING — could not re-read the PR/MR text before delivery"; return 1; }
  cur_t=$(jq -r '.title // ""' <<<"$current");   base_t=$(jq -r '.title // ""' "$BASELINE_FILE")
  cur_b=$(jq -r '.body  // ""' <<<"$current");   base_b=$(jq -r '.body  // ""' "$BASELINE_FILE")
  # A delivery that applied but reported failure (dropped response, crash
  # before the terminal step): the text already IS the end state — done.
  want_t="$base_t"; want_b="$base_b"
  [[ -n "${NEW_TITLE//[[:space:]]/}" ]] && want_t="$NEW_TITLE"
  (( NEW_DESC == 1 )) && want_b=$(cat "$DESC_FILE")
  if [[ "$cur_t" == "$want_t" && "$cur_b" == "$want_b" ]]; then
    log "finalize: the PR/MR title/description already carries the proposed text"
    return 0
  fi
  # Compare only the fields the proposal replaces: an edit to the OTHER
  # field must not block delivery, and an edit to a proposed field wins.
  if { [[ -n "${NEW_TITLE//[[:space:]]/}" ]] && [[ "$cur_t" != "$base_t" ]]; } \
     || { (( NEW_DESC == 1 )) && [[ "$cur_b" != "$base_b" ]]; }; then
    log "finalize: the PR/MR title/description changed after the proposal was composed — not overwriting the newer text"
    return 2
  fi
  case "$FORGE" in
    gitlab)
      local JQ_ARGS=(-n) JQ_FILTER='{}'
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
        log "finalize: WARNING — the MR title/description update failed (proposed text: $TITLE_FILE / $DESC_FILE)"
        return 1
      fi
      ;;
    *)
      local GH_EDIT_ARGS=()
      if [[ -n "${NEW_TITLE//[[:space:]]/}" ]]; then GH_EDIT_ARGS+=(--title "$NEW_TITLE"); fi
      if (( NEW_DESC == 1 )); then GH_EDIT_ARGS+=(--body-file "$DESC_FILE"); fi
      if gh pr edit "$PR_NUMBER" --repo "${REPO_OWNER}/${REPO_NAME}" \
           "${GH_EDIT_ARGS[@]}" >/dev/null; then
        log "finalize: refreshed the PR title/description"
      else
        log "finalize: WARNING — the PR title/description update failed (proposed text: $TITLE_FILE / $DESC_FILE)"
        return 1
      fi
      ;;
  esac
}

# Nothing lands: the turn only assessed the PR/MR text. Apply it (unless
# --no-push holds every external write) and finish terminally.
if [[ "$MODE" == "nocommit" ]]; then
  # Record the assessed tip: a --no-push hold, or a crash below, must not
  # spend another closing turn — the reuse guard above skips it, and the
  # held title/description files survive for the finishing run.
  hold_outcome "$HEAD_SHA" nocommit
  if (( ${NO_PUSH:-0} == 1 )); then
    log "finalize: --no-push — nothing to push, and the proposed title/description (if any) stays local; re-run without --no-push to finish"
    exit 0
  fi
  # The metadata update is this review's only external outcome, so its
  # delivery decides the run: a failure keeps the held proposal for a
  # retry, and a stale proposal is dropped so the next run reassesses the
  # current text instead of overwriting a human edit.
  set +e
  refresh_pr_metadata
  META_RC=$?
  set -e
  case "$META_RC" in
    0) finish_net_zero
       exit 3 ;;
    2) # FINALIZED_FILE first: an interruption mid-cleanup must read as
       # "reassess" (no reuse), never as "nothing left to deliver".
       rm -f "$FINALIZED_FILE" "$TITLE_FILE" "$DESC_FILE" "$BASELINE_FILE"
       die "the PR/MR text changed after the title/description proposal was composed — re-run to reassess it against the current text" ;;
    *) die "the PR/MR title/description update was not delivered — the held proposal is kept; re-run to retry" ;;
  esac
fi

# --- 3. squash ----------------------------------------------------------------
if (( SQUASHED == 0 )); then
  # Journal the squash's identity — its base and approved tree — BEFORE the
  # commit moves HEAD. A kill anywhere in publication then leaves a checkout
  # whose tip is a commit collapsing this base onto this tree: unmistakably
  # the loop's own squash, which the recovery below re-adopts idempotently
  # rather than reading as foreign movement.
  write_state_atomic "$INPROGRESS_FILE" "$BASE_SHA $APPROVED_TREE"
  # reset --soft keeps the tree and index exactly as they are and moves HEAD
  # back to the base, so the single commit below carries the review's net
  # change. On any failure HEAD goes back where it was — the rounds survive.
  git_safe -C "$REPO_DIR" reset --quiet --soft "$BASE_SHA" \
    || die "could not move HEAD back to the squash base $BASE_SHA in $REPO_DIR"
  # core.hooksPath=/dev/null: this commit is mechanical — the tree was
  # already approved, and no repository/user hook may edit or reject it.
  # core.fsmonitor=false: no config-planted program may run between the
  # destination check above and the push below.
  if ! git_safe -C "$REPO_DIR" \
        -c "user.name=$CLAUDE_GIT_NAME" -c "user.email=$CLAUDE_GIT_EMAIL" \
        commit --quiet -F "$MSG_FILE"; then
    git_safe -C "$REPO_DIR" reset --quiet --soft "$HEAD_SHA" \
      || log "finalize: WARNING — could not restore HEAD to $HEAD_SHA after the failed commit"
    die "the squash commit failed; the message is at $MSG_FILE"
  fi
  NEW_HEAD=$(git -C "$REPO_DIR" rev-parse HEAD)
  # Belt and braces behind the cleanup and the hook bypass: what is about
  # to be pushed must be tree-identical to what Codex approved.
  if [[ "$(git -C "$REPO_DIR" rev-parse "${NEW_HEAD}^{tree}")" != "$APPROVED_TREE" ]]; then
    git_safe -C "$REPO_DIR" reset --quiet --soft "$HEAD_SHA" \
      || log "finalize: WARNING — could not restore HEAD to $HEAD_SHA after the mismatched squash"
    die "the squash commit's tree does not match the approved tree $APPROVED_TREE — refusing to push it"
  fi
  HEAD_SHA=$NEW_HEAD
  hold_outcome "$HEAD_SHA" squash
  local_record_tip
  rm -f "$INPROGRESS_FILE"    # fully published — the outcome journal is authoritative now
  log "finalize: squashed $ROUNDS local round(s) into $HEAD_SHA"
  log "finalize: $(git -C "$REPO_DIR" log -1 --format=%s "$HEAD_SHA")"
fi

# --- 4. push ------------------------------------------------------------------
if (( ${NO_PUSH:-0} == 1 )); then
  log "finalize: --no-push — $HEAD_SHA stays in $REPO_DIR; re-run without --no-push to push it"
  exit 0
fi
# The squash may only reach the destination pinned when the review
# started — checked again HERE because the reuse path (a held or rejected
# squash pushed by a later invocation) runs no closing turn, so the
# checks around it never fire on the one invocation that actually pushes.
# A missing record fails closed for the same reason as above.
[[ -s "$(local_origin_file)" ]] \
  || die "no pinned origin destination is recorded for this review ($(local_origin_file) is missing — it is written when the review starts, and a turn may have removed it). Write the intended destination there (the output of 'git remote get-url --all origin' then 'git remote get-url --push --all origin', or '(none)') and re-run"
[[ "$(origin_dest)" == "$(<"$(local_origin_file)")" ]] \
  || die "the effective destination of origin in $REPO_DIR does not match the one recorded for this review ($(printf '%s' "$(<"$(local_origin_file)")" | tr '\n' ' ')) — refusing to push anywhere the review never validated. Fix the remote configuration, or write the intended destination into $(local_origin_file)"

if ! git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1; then
  # A supported terminal state, not a held one: with nowhere to push, the
  # squashed commit on the branch IS the review's outcome.
  log "finalize: $REPO_DIR has no origin remote — $HEAD_SHA stays local as the review's result"
  mark_completed "$HEAD_SHA"
  log "finalize: done — one commit ($HEAD_SHA) landed for this review"
  exit 0
fi

# Never force: the single commit must fast-forward the branch it lands on. A
# rejection means the branch moved while the review ran, and reconciling that
# is the operator's call, not the loop's.
# core.hooksPath=/dev/null: a repository pre-push hook is code the turn
# controls, running with the orchestrator's authority AFTER the destination
# was validated — this push is mechanical, so no hook may run under it.
log "finalize: pushing $HEAD_SHA to origin"
if ! git_safe -C "$REPO_DIR" push origin "HEAD:refs/heads/$HEAD_REF" >&2; then
  die "push of $HEAD_SHA was rejected (the branch moved while the review ran?). The squashed commit is in $REPO_DIR at $HEAD_SHA — reconcile it there and push manually; the loop never force-pushes"
fi
# An audit is not finished by the push: its deliverable is the PR/MR that
# the pushed branch gets. Opening it is an agent turn following the loop's
# own skill — the forge, its API, and what counts as "one already exists"
# are the agent's to work out. It runs here, after the push, because a
# PR/MR cannot target a branch the forge has not seen.
if (( IS_AUDIT == 1 )); then
  if [[ -s "$PR_URL_FILE" ]]; then
    log "finalize: the PR/MR for '$HEAD_REF' is already recorded: $(<"$PR_URL_FILE")"
  else
    open_pr_turn \
      || die "could not open the PR/MR for '$HEAD_REF' -> '$AUDIT_PR_BASE'. The branch is pushed at $HEAD_SHA and the composed text is at $TITLE_FILE / $DESC_FILE — re-run to retry"
    log "finalize: opened $(<"$PR_URL_FILE")"
  fi
  mark_completed "$HEAD_SHA"
  log "finalize: done — one commit ($HEAD_SHA) on '$HEAD_REF', $(<"$PR_URL_FILE")"
  exit 0
fi

# Terminal the moment the push lands — the metadata refresh below is
# best-effort here (the pushed commit is the review's outcome), and a
# crash before it must not leave a pushed review looking resumable.
mark_completed "$HEAD_SHA"

# A failed or stale update only warns: refresh_pr_metadata has already
# logged which, and the proposal files stay in the state dir for the
# operator. A stale one is never delivered over the newer human text.
set +e
refresh_pr_metadata
set -e

log "finalize: done — one commit ($HEAD_SHA) pushed for this review"
exit 0
