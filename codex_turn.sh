#!/usr/bin/env bash
# One Codex review iteration. Reads env: REPO_OWNER, REPO_NAME, PR_NUMBER,
# REPO_DIR, BASE_REF, HEAD_REF, ITER, MAX_ITER, LOOP_HOME, STATE_DIR,
# REVIEW_ONLY, HAS_CONTEXT, CONTEXT_FILE, CODEX_BIN, CODEX_MODEL,
# CODEX_EFFORT, CODEX_TIER, CODEX_CONTEXT_WINDOW.
# Exits 0 if APPROVED, 2 if CHANGES_REQUESTED, 1 on error / no verdict found.
set -euo pipefail

HERE="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
trap _runtime_rpc_stop_if_active EXIT
trap '_runtime_rpc_exit_on_signal 129' HUP
trap '_runtime_rpc_exit_on_signal 130' INT
trap '_runtime_rpc_exit_on_signal 143' TERM

ID=$(iter_dir "$ITER")
mkdir -p "$ID"

# Where the review goes.
#   forge mode — comments on the PR/MR; the prior AI thread is snapshotted
#                here for the model to read.
#   local mode — a file. It is this turn's completion contract, so a
#                leftover from a crashed earlier attempt is removed first:
#                only a review written by THIS run may count as done.
THREAD_FILE="$ID/thread.ndjson"
REVIEW_FILE=$(local_artifact_path codex "$ITER")
if [[ "$LOCAL_MODE" == "1" ]]; then
  rm -f "$REVIEW_FILE"
  : > "$THREAD_FILE"
else
  # A failed fetch fails the turn: reviewing against an empty or partial
  # thread would re-raise settled findings and invent pushback responses.
  # (A thread with no comments yet is rc 0 with empty output — fine.)
  fetch_ai_thread > "$THREAD_FILE" \
    || die "could not fetch the AI thread — not reviewing against a partial or empty one"
fi

PREV_ITER=$(( ITER - 1 ))
[[ $PREV_ITER -lt 0 ]] && PREV_ITER=0

# Mode-specific note injected near the top of the prompt. Review-only loops
# have no Claude implementer, so any "fixes since last review" come from
# humans pushing commits, and the prompt section about Claude's pushback is
# inapplicable.
if [[ "${REVIEW_ONLY:-0}" == "1" ]]; then
  if [[ "$LOCAL_MODE" == "1" ]]; then
    PUSHBACK_SECTION='Carried over'
  else
    PUSHBACK_SECTION="Response to Claude's pushback"
  fi
  MODE_NOTE="**Mode: review-only.** There is no Claude implementer in this loop -- humans address findings by pushing commits directly. The \"${PUSHBACK_SECTION}\" section in step 7 is therefore inapplicable; rename it to \"Response to changes since iter ${PREV_ITER}\" and use it to note which prior findings the new commits resolved, accepted, or left open. If there is no prior iteration on this PR (ITER=1), omit that section entirely."
else
  MODE_NOTE=''
fi

# Optional human-supplied reference material (web links / notes / files),
# rendered by run.sh to $CONTEXT_FILE. Inject a one-line pointer when present;
# the agent reads the file (and fetches any URLs) itself.
if [[ "${HAS_CONTEXT:-0}" == "1" ]]; then
  CONTEXT_NOTE="**Additional context for this review.** The operator attached trusted reference material at \`${CONTEXT_FILE}\`. Read it now and fetch any URLs it lists (via \`curl\`). Factor it into your review on every iteration — it supplements the PR description and the repo's conventions; weigh it alongside them as authoritative background."
else
  CONTEXT_NOTE=''
fi

# Local mode can show the author/loop split exactly because base.sha pins the
# PR head from before the first review round. Give the reviewer that evidence
# every iteration, especially before it approves a large fixup diff.
SCOPE_NOTE=''
if [[ "$LOCAL_MODE" == "1" ]]; then
  SCOPE_FILE="$ID/review-scope.md"
  local_write_scope_report "$SCOPE_FILE"
  SCOPE_NOTE="**Review-created diff.** Read \`${SCOPE_FILE}\` before filing findings. It separates the original change from paths changed by this review and flags paths newly brought into scope. Require a change-specific reason for every review-created path."
fi

# Resolve the reviewer's runtime knobs before rendering the prompt: the prompt
# contains the exact signature that every public Codex comment/reply must carry.
# These same resolved values build the CLI argv below, so the signed model and
# effort can never drift from what the turn requested.
CODEX_MODEL_ARG=()
CODEX_MODEL_RESOLVED="${CODEX_MODEL:-gpt-5.6-sol}"
case "$CODEX_MODEL_RESOLVED" in
  off|'') CODEX_MODEL_ARG=() ;;
  *)      CODEX_MODEL_ARG=(-m "$CODEX_MODEL_RESOLVED") ;;
esac
(( ${#CODEX_MODEL_ARG[@]} > 0 )) && log "codex: model = ${CODEX_MODEL_RESOLVED}"

CODEX_EFFORT_ARG=()
CODEX_EFFORT_RESOLVED=$(resolve_codex_effort "$CODEX_MODEL_RESOLVED" "${CODEX_EFFORT:-}")
case "$CODEX_EFFORT_RESOLVED" in
  low|medium|high|xhigh|max|ultra) CODEX_EFFORT_ARG=(-c "model_reasoning_effort=\"${CODEX_EFFORT_RESOLVED}\"") ;;
  off)                             CODEX_EFFORT_ARG=() ;;
  *)                               log "codex: unknown CODEX_EFFORT='${CODEX_EFFORT_RESOLVED}' — using CLI/config default"; CODEX_EFFORT_ARG=() ;;
esac
(( ${#CODEX_EFFORT_ARG[@]} > 0 )) && log "codex: reasoning effort = ${CODEX_EFFORT_RESOLVED}"

CODEX_TIER_ARG=()
CODEX_TIER_RESOLVED="${CODEX_TIER:-fast}"
case "$CODEX_TIER_RESOLVED" in
  off|'') CODEX_TIER_ARG=() ;;
  *)      CODEX_TIER_ARG=(-c "service_tier=\"${CODEX_TIER_RESOLVED}\"") ;;
esac
(( ${#CODEX_TIER_ARG[@]} > 0 )) && log "codex: service tier = ${CODEX_TIER_RESOLVED}"

# Resolve the persisted session before runtime metadata so the control probe
# can issue the same exec-shaped thread/resume request as the selected CLI and
# read its authoritative current model/effort response.
REPO_DIR_CANON=$(CDPATH= cd -- "$REPO_DIR" && pwd -P)
CODEX_SESSION_FILE="$STATE_DIR/codex.session.id"
CAPTURE_NEW_SESSION=0
CODEX_SUBCMD=()
CODEX_SESSION_ID=''
if [[ -s "$CODEX_SESSION_FILE" ]]; then
  STORED_SESSION_ID=$(<"$CODEX_SESSION_FILE")
  if CODEX_SESSION_ID=$(resolve_codex_root_session_id "$STORED_SESSION_ID" "$REPO_DIR_CANON"); then
    if [[ "$CODEX_SESSION_ID" != "$STORED_SESSION_ID" ]]; then
      log "codex: stored session $STORED_SESSION_ID is a sub-agent — migrated to root $CODEX_SESSION_ID"
      printf '%s\n' "$CODEX_SESSION_ID" > "$CODEX_SESSION_FILE"
    fi
    log "codex: resuming session $CODEX_SESSION_ID"
    CODEX_SUBCMD=(resume "$CODEX_SESSION_ID")
  else
    log "codex: stored session $STORED_SESSION_ID is not resumable for this checkout — starting fresh"
    rm -f "$CODEX_SESSION_FILE"
  fi
fi
if (( ${#CODEX_SUBCMD[@]} == 0 )); then
  log "codex: starting new session"
  CAPTURE_NEW_SESSION=1
  SNAPSHOT_BEFORE="$ID/codex.sessions.before"
  snapshot_codex_sessions "$SNAPSHOT_BEFORE"
fi

if [[ "$LOCAL_MODE" == "1" ]]; then
  CODEX_CONTEXT_WINDOW_RESOLVED=unknown
  CODEX_CONTEXT_WINDOW_SOURCE=unknown
  CODEX_MODEL_ACTUAL=$(ai_model_display "$CODEX_MODEL_RESOLVED")
  CODEX_EFFORT_ACTUAL=$(codex_effort_display "$CODEX_EFFORT_RESOLVED")
else
  # app-server config/read + model/list resolve layered host defaults without
  # starting a turn or inference; a resumed path only loads its existing
  # thread. The active (non-bundled) catalog supplies the effective context.
  resolve_codex_runtime_metadata
  [[ "$CODEX_MODEL_ACTUAL" != "unknown" ]] \
    || die "Codex did not report its effective model; refusing to render forge comments with guessed metadata"
  [[ "$CODEX_EFFORT_ACTUAL" != "unknown" ]] \
    || die "Codex did not report its effective effort; refusing to render forge comments with guessed metadata"
  [[ "$CODEX_CONTEXT_WINDOW_RESOLVED" =~ ^[1-9][0-9]*$ ]] \
    || die "Codex did not expose an effective context window; set --codex-context-window for this CLI/provider"
fi
AI_COMMENT_SIGNATURE=$(ai_comment_signature \
  "$CODEX_MODEL_ACTUAL" \
  "$CODEX_EFFORT_ACTUAL" \
  "$CODEX_CONTEXT_WINDOW_RESOLVED" "$CODEX_CONTEXT_WINDOW_SOURCE")
export AI_COMMENT_SIGNATURE
AI_COMMENT_BOT=codex
export AI_COMMENT_BOT
AI_COMMENT_SIGNATURE_SED=$(prompt_sed_replacement "$AI_COMMENT_SIGNATURE")
log "codex: context window = ${CODEX_CONTEXT_WINDOW_RESOLVED}"


# Render the prompt template. GitLab loops use the gitlab prompt variant —
# same review contract, MR/discussions API commands (curl + PRIVATE-TOKEN)
# instead of gh.
#
# BASE_REF/HEAD_REF are NOT sed-substituted: they come from forge metadata
# (a Git-valid branch name can contain sed/shell metacharacters — e.g. a
# name that closes the replacement and enables GNU sed's `e` flag executes
# during rendering). The templates reference the exported $BASE_REF /
# $HEAD_REF shell variables instead, which the agent's shell expands
# safely; both are exported to this process's environment by run.sh.
PROMPT_TEMPLATE="$HERE/prompts/codex.md"
PROMPT_FILE="$ID/codex.prompt.md"
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
  -e "s|{{PREV_ITER}}|${PREV_ITER}|g" \
  -e "s|{{MAX_ITER}}|${MAX_ITER}|g" \
  -e "s|{{THREAD_FILE}}|${THREAD_FILE}|g" \
  -e "s|{{REVIEW_FILE}}|${REVIEW_FILE}|g" \
  -e "s|{{HISTORY_DIR}}|${STATE_DIR}|g" \
  -e "s|{{GH_USER}}|${GH_USER}|g" \
  -e "s|{{MODE_NOTE}}|${MODE_NOTE}|g" \
  -e "s|{{CONTEXT_NOTE}}|${CONTEXT_NOTE}|g" \
  -e "s|{{SCOPE_NOTE}}|${SCOPE_NOTE}|g" \
  -e "s|{{AI_COMMENT_SIGNATURE}}|${AI_COMMENT_SIGNATURE_SED}|g" \
  > "$PROMPT_FILE"

if [[ "$LOCAL_MODE" != "1" ]]; then
  record_ai_signature_attempt codex "$ITER" "$AI_COMMENT_SIGNATURE" "$THREAD_FILE" \
    || die "could not record the Codex signature attempt manifest"
fi

log "codex: iter $ITER — running"

# Codex must be able to run gh + git, hence --yolo (autorun: the alias for
# --dangerously-bypass-approvals-and-sandbox). (User explicitly requested
# unattended operation; mutations to GitHub are expected.) `codex exec resume`
# doesn't accept --cd or --color, so cd via subshell and use NO_COLOR=1 for
# both fresh and resume paths.
# A previous attempt at this iteration may have left provisional stdout
# records. Clear them before the CLI runs: if this attempt is killed
# after its summary POSTs but before its own parse lands, resume must
# find nothing to adopt (and degrade conservatively) rather than adopt
# the PREVIOUS attempt's stdout as this landed review's record — a stale
# APPROVED would silently end the review.
rm -f "$ID/issue_counts.stdout" "$ID/verdict.stdout"

set +e
( cd "$REPO_DIR" && NO_COLOR=1 "$CODEX_BIN" exec \
    ${CODEX_SUBCMD[@]+"${CODEX_SUBCMD[@]}"} \
    ${CODEX_MODEL_ARG[@]+"${CODEX_MODEL_ARG[@]}"} \
    ${CODEX_EFFORT_ARG[@]+"${CODEX_EFFORT_ARG[@]}"} \
    ${CODEX_TIER_ARG[@]+"${CODEX_TIER_ARG[@]}"} \
    --skip-git-repo-check \
    --yolo \
    - \
    < "$PROMPT_FILE" \
    > "$ID/codex.stdout" 2> "$ID/codex.stderr" )
RC=$?
set -e

# Capture the new session id so the next iter can resume. Only on success —
# a failed first run probably didn't write a usable rollout file.
if (( CAPTURE_NEW_SESSION == 1 )) && [[ $RC -eq 0 ]]; then
  if NEW_SESSION_ID=$(discover_new_codex_session_id "$SNAPSHOT_BEFORE" "$REPO_DIR_CANON"); then
    printf '%s\n' "$NEW_SESSION_ID" > "$CODEX_SESSION_FILE"
    log "codex: captured session id $NEW_SESSION_ID"
  else
    log "codex: WARNING — could not discover session id; next iter will start fresh"
  fi
fi

log "codex: iter $ITER — exit $RC"

# The turn's completion contract — the summary comment in forge mode, the
# written review file in local mode. The prompt produces it LAST, after every
# inline note / finding, so its absence means the turn did not finish.
# Trusting stdout alone is not enough: a run can print its verdict even though
# the summary POST failed or the review was never written. Require the
# artifact before recording any CANONICAL counts or verdict — failing without
# one means the next invocation re-reviews at this same iteration, since the
# resume high-water counts the same artifact. A summary that LANDED is a
# real, public review even when the CLI then exited nonzero: persist its
# counts and verdict before failing the turn, so a relaunch's resume
# accounts for what the PR already shows (convergence included).
#
# The stdout parse is ALWAYS persisted provisionally (*.stdout files) first:
# in forge mode this verification read can itself fail transiently right after
# a POST that landed, and the durable stdout record must survive that. Resume
# adopts the provisional files only once the public high-water confirms the
# summary (adopt_landed_codex_artifacts in run.sh) — a run whose POST truly
# never landed leaves provisional files that nothing ever adopts. Local mode
# has no public surface to confirm against: the file on disk IS the record, so
# the probe below is the only check and adoption never applies.
SUMMARY_LANDED=0
turn_artifact_landed codex "$ITER" && SUMMARY_LANDED=1

# Parse issue counts (last occurrence wins). Missing line → counts unknown,
# orchestrator treats convergence as not-met.
ISSUES_LINE=$(grep -Eo '\[CODEX_ISSUES: BLOCKER=[0-9]+ MAJOR=[0-9]+ NIT=[0-9]+\]' \
                "$ID/codex.stdout" | tail -1 || true)
if [[ -n "$ISSUES_LINE" ]]; then
  BLOCKER_N=$(grep -Eo 'BLOCKER=[0-9]+' <<<"$ISSUES_LINE" | grep -Eo '[0-9]+')
  MAJOR_N=$(grep -Eo 'MAJOR=[0-9]+' <<<"$ISSUES_LINE" | grep -Eo '[0-9]+')
  NIT_N=$(grep -Eo 'NIT=[0-9]+' <<<"$ISSUES_LINE" | grep -Eo '[0-9]+')
  printf 'BLOCKER=%s\nMAJOR=%s\nNIT=%s\n' "$BLOCKER_N" "$MAJOR_N" "$NIT_N" \
    > "$ID/issue_counts.stdout"
  log "codex: issue counts BLOCKER=$BLOCKER_N MAJOR=$MAJOR_N NIT=$NIT_N"
else
  rm -f "$ID/issue_counts.stdout"
  log "codex: no [CODEX_ISSUES: ...] marker found — convergence check disabled for this iter"
fi

# Parse the verdict from stdout (last occurrence wins). No marker — e.g.
# stdout truncated by the failure that also produced a nonzero exit —
# records the conservative CHANGES_REQUESTED, so resume treats the landed
# review as a pending half-step rather than guessing an approval.
VERDICT=$(grep -Eo '\[CODEX_VERDICT: (APPROVED|CHANGES_REQUESTED)\]' \
            "$ID/codex.stdout" | tail -1 || true)
if [[ "$VERDICT" == *APPROVED* ]]; then
  echo "APPROVED" > "$ID/verdict.stdout"
  log "codex: VERDICT = APPROVED"
elif [[ -n "$VERDICT" ]]; then
  echo "CHANGES_REQUESTED" > "$ID/verdict.stdout"
  log "codex: VERDICT = CHANGES_REQUESTED"
else
  log "codex: no verdict marker found in stdout — treating as CHANGES_REQUESTED"
  echo "CHANGES_REQUESTED" > "$ID/verdict.stdout"
fi

if (( SUMMARY_LANDED == 1 )); then
  # The summary is confirmed public: promote the provisional records.
  # Copy-then-rename — a kill mid-copy must not leave a truncated
  # canonical file that would block later adoption of the intact record.
  if [[ -f "$ID/issue_counts.stdout" ]]; then
    cp "$ID/issue_counts.stdout" "$ID/issue_counts.tmp.$$"
    mv -f "$ID/issue_counts.tmp.$$" "$ID/issue_counts"
  fi
  cp "$ID/verdict.stdout" "$ID/verdict.tmp.$$"
  mv -f "$ID/verdict.tmp.$$" "$ID/verdict"
fi

# Surface the round to whoever is driving the loop. Runs before the failure
# exits below: a review that landed is worth reporting even when the CLI then
# died.
if (( SUMMARY_LANDED == 1 )); then
  emit_round_report codex "$ITER"
fi

if [[ $RC -ne 0 ]]; then
  log "codex stderr (tail):"
  tail -20 "$ID/codex.stderr" >&2 || true
  if (( SUMMARY_LANDED == 1 )); then
    if [[ "$LOCAL_MODE" == "1" ]]; then
      log "codex: the iter $ITER review landed before the CLI failure — counts and verdict persisted for resume"
    else
      log "codex: the iter $ITER summary landed before the CLI failure — counts and verdict persisted for resume"
    fi
  fi
  exit 1
fi

if (( SUMMARY_LANDED == 0 )); then
  if [[ "$LOCAL_MODE" == "1" ]]; then
    log "codex: iter $ITER review file $REVIEW_FILE is missing or empty — failing the turn (stdout verdict ignored)"
  else
    log "codex: iter $ITER summary comment not found on the PR — failing the turn (stdout verdict ignored)"
  fi
  exit 1
fi

if [[ "$VERDICT" == *APPROVED* ]]; then
  exit 0
fi
exit 2
