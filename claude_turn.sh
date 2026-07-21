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

# Snapshot AI thread.
THREAD_FILE="$ID/thread.ndjson"
fetch_ai_thread > "$THREAD_FILE" || true

# Extract this iter's codex output split by surface:
#   - LATEST_REVIEW_FILE  → summary issue-comment body (cross-cutting + verdict)
#   - LATEST_INLINE_FILE  → NDJSON of inline findings, one per line:
#                            { id, discussion_id, path, line, body }
#     GitHub: id is what Claude's in_reply_to replies target (discussion_id
#     is null). GitLab: replies POST to discussions/<discussion_id>/notes.
LATEST_REVIEW_FILE="$ID/codex-review.md"
LATEST_INLINE_FILE="$ID/codex-inline.ndjson"

jq -r --arg t "$CODEX_MARKER_TAG" --argjson it "$ITER" '
    select(.tag==$t and .iter==$it and .surface=="issue") | .body' \
    "$THREAD_FILE" > "$LATEST_REVIEW_FILE"

jq -c --arg t "$CODEX_MARKER_TAG" --argjson it "$ITER" '
    select(.tag==$t and .iter==$it and .surface=="inline")
    | {id, discussion_id, path, line, body}' \
    "$THREAD_FILE" > "$LATEST_INLINE_FILE"

# No fallback to an older summary here. Reaching this turn means codex's
# iter-$ITER summary exists (codex_turn verifies it after posting, and the
# resume high-water counts only summaries), so failing to extract it means
# the fetch is broken or the thread is inconsistent — and answering a stale
# review would advance the loop past an incomplete one. Die instead; the
# next invocation resumes at this same iteration.
# (Missing inline is different: no inline findings is a valid outcome.)
if [[ ! -s "$LATEST_REVIEW_FILE" ]]; then
  die "codex summary for iter $ITER not found on the PR — cannot run claude turn"
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
PROMPT_TEMPLATE="$HERE/prompts/claude.md"
[[ "${FORGE:-github}" == "gitlab" ]] && PROMPT_TEMPLATE="$HERE/prompts/claude.gitlab.md"
PROMPT_FILE="$ID/claude.prompt.md"
sed \
  -e "s|{{REPO_OWNER}}|${REPO_OWNER}|g" \
  -e "s|{{REPO_NAME}}|${REPO_NAME}|g" \
  -e "s|{{REPO_SLUG}}|${REPO_SLUG:-${REPO_OWNER}/${REPO_NAME}}|g" \
  -e "s|{{FORGE_HOST}}|${FORGE_HOST:-github.com}|g" \
  -e "s|{{FORGE_SCHEME}}|${FORGE_SCHEME:-https}|g" \
  -e "s|{{PROJECT_ENC}}|${PROJECT_ENC:-}|g" \
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
  "$PROMPT_TEMPLATE" > "$PROMPT_FILE"

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

# Permission handling for the implementer, set by the orchestrator's
# --claude-perms (default: auto).
#   auto   — --permission-mode auto: every action is gated by the Claude Code
#            auto-mode classifier, which approves task-aligned actions
#            headlessly and works on hosts where bypass is policy-disabled.
#            Auto mode is not available on every account/provider (Pro and
#            Bedrock/Vertex/Foundry are excluded; Team/Enterprise needs admin
#            enablement). Ineligible hosts SILENTLY DOWNGRADE to default mode
#            (rc 0, empty stderr, every headless action denied), so a
#            deterministic preflight probe reads the CLI-reported effective
#            mode first and switches to the settings safety net when auto
#            does not stick (cached per PR). A CLI that instead hard-rejects
#            the flag at startup is handled by a one-shot retry (see below).
#   bypass — --dangerously-skip-permissions, plus a settings safety net for
#            hosts that silently downgrade bypass (managed no-bypass policies,
#            nested launches from inside another Claude Code session — the
#            skill path): auto-accepted edits + allowed Bash/WebFetch/
#            WebSearch. Where bypass is honored the net is a no-op.
#   off    — leave the host's CLI/settings default untouched.
# In every mode $STATE_DIR is mounted as a second working dir below so the
# turn can always read the codex review files.
CLAUDE_PERMISSIONS_NET='"permissions": {"defaultMode": "acceptEdits", "allow": ["Bash", "WebFetch", "WebSearch"]}'
CLAUDE_PERMS_RESOLVED="${CLAUDE_PERMS:-auto}"
CLAUDE_PERMS_ARG=()
CLAUDE_PERMISSIONS=''

# Print the effective permission mode the CLI grants for --permission-mode
# auto, or nothing when the probe is inconclusive. The stream-json init event
# is emitted by the CLI itself at startup — before any model or tool activity
# — and reports the mode actually in effect, so this detects the silent
# downgrade deterministically (verified on claude 2.1.211: an ineligible host
# reports "default" here while exiting 0 with empty stderr). Probing with the
# turn's own model args matters: eligibility can be per-model. The watchdog is
# run_with_timeout (lib/common.sh) — portable across hosts without GNU
# timeout, where a bare `timeout` would silently make every probe
# inconclusive.
probe_claude_effective_auto_mode() {
  ( cd "$REPO_DIR" && run_with_timeout 60 claude -p \
      "${CLAUDE_MODEL_ARG[@]}" \
      --permission-mode auto \
      --output-format stream-json --verbose \
      'Reply with exactly: OK' 2>/dev/null \
    | head -1 | jq -r '.permissionMode // empty' 2>/dev/null )
}

case "$CLAUDE_PERMS_RESOLVED" in
  auto)
    # Definitive probe results are cached per PR AND per resolved model —
    # eligibility is account/host/model state, and --claude-model can change
    # between invocations sharing this state dir ('off' = host default model
    # is a key of its own). A cache line is "<mode> <model>", mode first
    # because modes are single tokens while a model string could contain
    # whitespace — `read` hands the remainder to the model field verbatim,
    # so the match is exact for any model. A stored line for a different
    # model (or the older formats) is treated as absent and re-probed.
    # Delete the cache file after changing auto-mode enablement to re-probe.
    AUTOMODE_CACHE="$STATE_DIR/claude.automode.effective"
    EFFECTIVE_AUTO=''
    if [[ -s "$AUTOMODE_CACHE" ]]; then
      read -r CACHED_MODE CACHED_MODEL < "$AUTOMODE_CACHE" || true
      if [[ "${CACHED_MODEL:-}" == "$CLAUDE_MODEL_RESOLVED" && -n "${CACHED_MODE:-}" ]]; then
        EFFECTIVE_AUTO="$CACHED_MODE"
        log "claude: auto-mode probe (cached for model '$CACHED_MODEL') = '$EFFECTIVE_AUTO'"
      fi
    fi
    if [[ -z "$EFFECTIVE_AUTO" ]]; then
      EFFECTIVE_AUTO=$(probe_claude_effective_auto_mode || true)
      if [[ -n "$EFFECTIVE_AUTO" ]]; then
        printf '%s %s\n' "$EFFECTIVE_AUTO" "$CLAUDE_MODEL_RESOLVED" > "$AUTOMODE_CACHE"
        log "claude: auto-mode probe (model '$CLAUDE_MODEL_RESOLVED') = '$EFFECTIVE_AUTO'"
      else
        log "claude: auto-mode probe inconclusive — proceeding with auto (startup-rejection retry still applies)"
      fi
    fi
    if [[ -z "$EFFECTIVE_AUTO" || "$EFFECTIVE_AUTO" == "auto" ]]; then
      CLAUDE_PERMS_ARG=(--permission-mode auto)
    else
      log "claude: auto mode silently downgraded to '$EFFECTIVE_AUTO' on this host — using the settings safety net"
      CLAUDE_PERMISSIONS="$CLAUDE_PERMISSIONS_NET"
    fi
    ;;
  bypass) CLAUDE_PERMS_ARG=(--dangerously-skip-permissions)
          CLAUDE_PERMISSIONS="$CLAUDE_PERMISSIONS_NET" ;;
  off|'') ;;
  *)      log "claude: unknown CLAUDE_PERMS='${CLAUDE_PERMS_RESOLVED}' — using CLI default" ;;
esac
(( ${#CLAUDE_PERMS_ARG[@]} > 0 )) && log "claude: permission mode = ${CLAUDE_PERMS_RESOLVED}"

# Reasoning effort for the implementer, set by the orchestrator's --claude-effort
# (default: ultracode). "ultracode" sends xhigh reasoning + dynamic-workflow
# orchestration via a --settings payload (the documented headless mechanism;
# degrades to plain xhigh if orchestration doesn't apply in -p mode). A bare
# level uses --effort. "off" leaves the CLI/settings effort default untouched.
# The bypass-mode permission safety net rides in the same --settings payload.
CLAUDE_EFFORT_ARG=()
SETTINGS_PARTS=()
case "${CLAUDE_EFFORT:-ultracode}" in
  ultracode)                 SETTINGS_PARTS+=('"ultracode": true') ;;
  low|medium|high|xhigh|max) CLAUDE_EFFORT_ARG=(--effort "${CLAUDE_EFFORT}") ;;
  off|'')                    ;;
  *)                         log "claude: unknown CLAUDE_EFFORT='${CLAUDE_EFFORT}' — using CLI default" ;;
esac
log "claude: effort = ${CLAUDE_EFFORT:-ultracode}"
[[ -n "$CLAUDE_PERMISSIONS" ]] && SETTINGS_PARTS+=("$CLAUDE_PERMISSIONS")
CLAUDE_SETTINGS_ARG=()
if (( ${#SETTINGS_PARTS[@]} > 0 )); then
  _joined=$(IFS=,; printf '%s' "${SETTINGS_PARTS[*]}")
  CLAUDE_SETTINGS_ARG=(--settings "{${_joined}}")
fi

# The implementer sometimes launches a long build/test as a background task
# and ends its message expecting to be re-invoked when the task completes.
# Headless claude holds the final message while background tasks are pending,
# but only up to CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS (default 600s) — past
# that it terminates the turn WITHOUT emitting the final message, so the
# orchestrator sees a marker-less exit 0 and fails the iteration even though
# work happened (observed on ovstage-internal PR 58 iter 1). Give such tasks
# a bounded but realistic window; 0 (= wait forever) is unsafe here because
# no outer watchdog wraps the turn. Override via env if a repo needs more.
: "${CLAUDE_BG_WAIT_CEILING_MS:=3600000}"

# A -p turn is a one-shot process: when the model ends its turn the CLI
# exits (it waits only for pending background tasks, bounded above). Tools
# that yield the turn expecting a later re-invocation — scheduled wakeups,
# monitors, cron jobs — therefore end the run with NO final message and no
# completion marker: observed on ovstage-internal PR 58 iter 9, where the
# implementer backgrounded a stress run and called ScheduleWakeup as a
# "fallback heartbeat", killing the turn 6s later with empty stdout. Ban
# them outright; the prompt also says to drain work in-turn.
CLAUDE_DISALLOWED_TOOLS="ScheduleWakeup,Monitor,CronCreate"

# claude -p runs non-interactively; permission handling for unattended
# operation (user authorized this) is selected above via --claude-perms.
run_claude_turn() {
  ( cd "$REPO_DIR" && \
    CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="$CLAUDE_BG_WAIT_CEILING_MS" \
    claude -p \
      --disallowedTools "$CLAUDE_DISALLOWED_TOOLS" \
      "${CLAUDE_SESSION_ARG[@]}" \
      "${CLAUDE_MODEL_ARG[@]}" \
      "${CLAUDE_EFFORT_ARG[@]}" \
      "${CLAUDE_PERMS_ARG[@]}" \
      "${CLAUDE_SETTINGS_ARG[@]}" \
      --add-dir "$REPO_DIR" \
      --add-dir "$STATE_DIR" \
      --append-system-prompt "You are operating as an autonomous PR implementer bot. Distinct identity for any git commits: name='${CLAUDE_GIT_NAME}', email='${CLAUDE_GIT_EMAIL}'. Never amend or force-push." \
      "$(cat "$PROMPT_FILE")" \
      > "$ID/claude.stdout" 2> "$ID/claude.stderr" )
}

set +e
TURN_START=$SECONDS
run_claude_turn
RC=$?
TURN_ELAPSED=$(( SECONDS - TURN_START ))
set -e

# Auto mode is not available on every account/provider; the CLI refuses the
# flag at startup there — before any turn work runs — so a retry cannot
# duplicate side effects. Fall back once to the broadly available settings
# safety net rather than failing every iteration on such hosts. Retry ONLY
# on proven startup ineligibility, never on a turn that may have done work:
#   - stderr must carry one of the CLI's startup-eligibility diagnostics
#     ("auto mode disabled by settings" / "is unavailable for your plan" /
#     "requires CLAUDE_CODE_ENABLE_AUTO_MODE" / "unavailable for this model",
#     extracted from the claude 2.1.211 bundle), and must NOT be the
#     documented runtime classifier abort ("auto mode cannot determine the
#     safety ..."), which can fire after tool side effects;
#   - stdout must be empty (text mode prints only the final response, so
#     this alone cannot prove no work — hence the checks above);
#   - the attempt must have died almost immediately: a turn that reached
#     the model and executed tools cannot finish this fast.
if [[ $RC -ne 0 && "$CLAUDE_PERMS_RESOLVED" == "auto" ]] \
   && (( ${#CLAUDE_PERMS_ARG[@]} > 0 )) \
   && (( TURN_ELAPSED < 15 )) \
   && [[ ! -s "$ID/claude.stdout" ]] \
   && ! grep -qi 'cannot determine the safety' "$ID/claude.stderr" \
   && grep -qiE 'auto[ -]mode (is )?(disabled by settings|unavailable for (your plan|this model)|requires CLAUDE_CODE_ENABLE_AUTO_MODE)' "$ID/claude.stderr"; then
  log "claude: permission mode 'auto' unavailable on this host — retrying with the settings safety net"
  mv "$ID/claude.stderr" "$ID/claude.stderr.auto-rejected"
  CLAUDE_PERMS_ARG=()
  SETTINGS_PARTS+=("$CLAUDE_PERMISSIONS_NET")
  _joined=$(IFS=,; printf '%s' "${SETTINGS_PARTS[*]}")
  CLAUDE_SETTINGS_ARG=(--settings "{${_joined}}")
  set +e
  run_claude_turn
  RC=$?
  set -e
fi

log "claude: iter $ITER — exit $RC"

if [[ $RC -ne 0 ]]; then
  log "claude stderr (tail):"
  tail -20 "$ID/claude.stderr" >&2 || true
  exit 1
fi

if ! grep -q '\[CLAUDE_TURN: COMPLETE\]' "$ID/claude.stdout"; then
  log "claude: missing [CLAUDE_TURN: COMPLETE] marker — assuming partial"
  exit 1
fi

# The stdout marker alone isn't proof of completion: the summary comment is
# the turn's contract (posted last, after every inline reply), and a failed
# POST or a crash after inline-only replies would otherwise advance the loop
# past a half-posted response. Refetch and require this iteration's summary.
if ! verify_ai_summary claude "$ITER"; then
  log "claude: iter $ITER summary comment not found on the PR — failing the turn (stdout marker ignored)"
  exit 1
fi

log "claude: turn complete"
exit 0
