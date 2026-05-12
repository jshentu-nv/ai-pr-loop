#!/usr/bin/env bash
# Orchestrator: alternates Codex review and Claude implementer turns on a PR
# until one of:
#   - Codex returns APPROVED                                      → exit 0
#   - Codex reports BLOCKER=0 MAJOR=0 for `--converge` consecutive
#     iterations (NIT-only, "converged_no_major")                 → exit 0
#   - This invocation's iteration cap is hit                      → exit 1
#   - A turn errors                                               → exit 1
#
# Resume: on each launch the orchestrator inspects the PR's existing AI
# comments and continues from the high-water mark. If codex posted but claude
# didn't respond (prior run died or hit max between turns), claude runs first
# at that iteration.
#
# Usage:
#   run.sh <pr-number> --repo OWNER/NAME [--dir REPO_DIR]
#                      [--max N] [--converge N]
#
# Arguments:
#   --repo     OWNER/NAME of the GitHub repo (required).
#   --dir      Local checkout to use. If omitted, the loop manages its own
#              clone at $LOOP_HOME/checkouts/<owner>__<name>, cloning on
#              first use via `gh repo clone` and reusing it thereafter.
#   --max      6 iterations this invocation; pass 0 for uncapped (ceiling 50).
#   --converge 3 consecutive BLOCKER=0 MAJOR=0 codex iters; pass 0 to disable.
#
# The only credential needed is GH_TOKEN/GITHUB_TOKEN (the gh CLI must be
# logged in to the repo's host). Works on any GitHub repo the authenticated
# user has push + comment access to.

set -euo pipefail

LOOP_HOME="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$LOOP_HOME/lib/common.sh"

# --- args ---------------------------------------------------------------------

MAX_ITER_DEFAULT=6
CONVERGE_DEFAULT=3
HARD_CEILING=50           # safety bound when --max 0 (uncapped)

REPO_SLUG=""
REPO_DIR=""
MAX_ITER="$MAX_ITER_DEFAULT"
CONVERGE_N="$CONVERGE_DEFAULT"
PR_NUMBER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)     REPO_SLUG="$2"; shift 2 ;;
    --dir)      REPO_DIR="$2";  shift 2 ;;
    --max)      MAX_ITER="$2";  shift 2 ;;
    --converge) CONVERGE_N="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0"; exit 0 ;;
    *)
      [[ -z "$PR_NUMBER" ]] || die "unexpected arg: $1"
      PR_NUMBER="$1"; shift ;;
  esac
done

[[ -n "$REPO_SLUG" ]] || die "--repo OWNER/NAME is required (see --help)"
[[ "$REPO_SLUG" == */* ]] || die "--repo must be in OWNER/NAME form, got: $REPO_SLUG"

# --max 0 → uncapped (still honor the hard ceiling).
if [[ "$MAX_ITER" -eq 0 ]] 2>/dev/null; then
  log "uncapped (--max 0): hard ceiling = $HARD_CEILING iterations this invocation"
  MAX_ITER="$HARD_CEILING"
fi

[[ -n "$PR_NUMBER" ]] || die "PR number is required (first positional arg)"
[[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || die "PR number must be numeric: $PR_NUMBER"

REPO_OWNER="${REPO_SLUG%%/*}"
REPO_NAME="${REPO_SLUG##*/}"

# Default checkout location when --dir not given: one managed clone per repo,
# shared across PRs of that repo. (Concurrent loops on the same repo should
# pass --dir to point at separate clones.)
if [[ -z "$REPO_DIR" ]]; then
  REPO_DIR="$LOOP_HOME/checkouts/${REPO_OWNER}__${REPO_NAME}"
fi

export REPO_OWNER REPO_NAME PR_NUMBER REPO_DIR MAX_ITER LOOP_HOME

preflight
ensure_repo_clone

# --- discover branches --------------------------------------------------------

PR_JSON=$(gh pr view "$PR_NUMBER" --repo "$REPO_SLUG" \
            --json headRefName,baseRefName,state,url)
PR_STATE=$(jq -r '.state'        <<<"$PR_JSON")
HEAD_REF=$(jq -r '.headRefName'  <<<"$PR_JSON")
BASE_REF=$(jq -r '.baseRefName'  <<<"$PR_JSON")
PR_URL=$(jq -r '.url'            <<<"$PR_JSON")

[[ "$PR_STATE" == "OPEN" ]] || die "PR is not OPEN (state=$PR_STATE)"
export HEAD_REF BASE_REF

ensure_state_dir
export STATE_DIR
RUN_LOG="$STATE_DIR/run.log"
: > "$RUN_LOG"

log "------------------------------------------------------------"
log "AI PR loop starting"
log "  PR:    $PR_URL"
log "  base:  $BASE_REF"
log "  head:  $HEAD_REF"
log "  dir:   $REPO_DIR"
log "  max:   $MAX_ITER iterations (this invocation)"
log "  state: $STATE_DIR"
log "------------------------------------------------------------"

# Make sure local checkout matches the remote PR branch.
( cd "$REPO_DIR"
  git fetch --quiet origin "$BASE_REF" "$HEAD_REF"
  current=$(git rev-parse --abbrev-ref HEAD)
  if [[ "$current" != "$HEAD_REF" ]]; then
    log "switching local branch from $current to $HEAD_REF"
    git checkout "$HEAD_REF"
  fi
  git pull --ff-only --quiet origin "$HEAD_REF" || true
)

# --- resume detection ---------------------------------------------------------
#
# Look at the PR's existing AI comments and figure out where to resume:
#
#   last_codex == 0 && last_claude == 0  → fresh start, ITER=1, codex first.
#   last_codex == last_claude (= K)      → both did iter K, next round is K+1.
#   last_codex >  last_claude            → codex posted iter K but claude didn't
#                                           respond (prior run died or hit max
#                                           between turns) → run claude at K
#                                           first, then continue from K+1.
#
# `--max` counts iterations *this invocation*, not total. Re-run to grant more.

LAST_CODEX=$(latest_ai_comment_iter codex)
LAST_CLAUDE=$(latest_ai_comment_iter claude)
LAST_CODEX="${LAST_CODEX:-0}"
LAST_CLAUDE="${LAST_CLAUDE:-0}"

RESUME_CLAUDE_FIRST=0
if (( LAST_CODEX == 0 && LAST_CLAUDE == 0 )); then
  ITER=1
  log "no prior AI thread on this PR — starting fresh at iter 1"
elif (( LAST_CODEX > LAST_CLAUDE )); then
  # Half-step: codex reviewed but claude hasn't replied. Check on-disk verdict
  # to avoid running claude on top of an APPROVED review.
  PRIOR_VERDICT_FILE="$STATE_DIR/$(printf 'iter-%02d' "$LAST_CODEX")/verdict"
  if [[ -f "$PRIOR_VERDICT_FILE" && "$(cat "$PRIOR_VERDICT_FILE")" == "APPROVED" ]]; then
    log "codex already APPROVED at iter $LAST_CODEX — nothing to do"
    log "PR: $PR_URL"
    exit 0
  fi
  ITER="$LAST_CODEX"
  RESUME_CLAUDE_FIRST=1
  log "resuming: codex iter=$LAST_CODEX exists, claude iter=$LAST_CLAUDE — claude will run next at iter $ITER"
else
  ITER=$(( LAST_CODEX + 1 ))
  log "resuming: completed through iter $LAST_CODEX — next round is iter $ITER"
fi

# --- main loop ----------------------------------------------------------------

FINAL_STATUS="unknown"
RUNS=0
CONVERGE_STREAK=0   # consecutive codex iters with BLOCKER=0 MAJOR=0

while (( RUNS < MAX_ITER )); do
  export ITER
  log ""
  log "===== Iteration $ITER (run $((RUNS + 1)) / $MAX_ITER this invocation) ====="

  if (( RESUME_CLAUDE_FIRST == 1 )); then
    log "skipping codex turn — codex already posted at iter $ITER in a prior run"
    RESUME_CLAUDE_FIRST=0
  else
    # Codex review.
    set +e
    bash "$LOOP_HOME/codex_turn.sh"
    CODEX_RC=$?
    set -e

    case "$CODEX_RC" in
      0)  log "codex APPROVED on iter $ITER"
          FINAL_STATUS="approved"
          break ;;
      2)  log "codex requested changes on iter $ITER" ;;
      *)  log "codex turn failed on iter $ITER (rc=$CODEX_RC)"
          FINAL_STATUS="codex_error"
          break ;;
    esac

    # Convergence check (NITs only for N consecutive iterations).
    if (( CONVERGE_N > 0 )); then
      COUNTS_FILE="$STATE_DIR/$(printf 'iter-%02d' "$ITER")/issue_counts"
      if [[ -f "$COUNTS_FILE" ]]; then
        IB=$(awk -F= '/^BLOCKER=/{print $2}' "$COUNTS_FILE")
        IM=$(awk -F= '/^MAJOR=/{print $2}'   "$COUNTS_FILE")
        if [[ "$IB" == "0" && "$IM" == "0" ]]; then
          CONVERGE_STREAK=$((CONVERGE_STREAK + 1))
          log "convergence: iter $ITER BLOCKER=0 MAJOR=0 (streak $CONVERGE_STREAK / $CONVERGE_N)"
          if (( CONVERGE_STREAK >= CONVERGE_N )); then
            log "convergence: $CONVERGE_N consecutive NIT-only iterations — exiting"
            FINAL_STATUS="converged_no_major"
            break
          fi
        else
          if (( CONVERGE_STREAK > 0 )); then
            log "convergence: streak reset (BLOCKER=$IB MAJOR=$IM at iter $ITER)"
          fi
          CONVERGE_STREAK=0
        fi
      else
        log "convergence: no issue_counts file for iter $ITER — streak unchanged"
      fi
    fi

    # Pull in case anything landed remotely between turns.
    ( cd "$REPO_DIR" && git pull --ff-only --quiet origin "$HEAD_REF" || true )
  fi

  # Claude response.
  set +e
  bash "$LOOP_HOME/claude_turn.sh"
  CLAUDE_RC=$?
  set -e

  if [[ $CLAUDE_RC -ne 0 ]]; then
    log "claude turn failed on iter $ITER (rc=$CLAUDE_RC)"
    FINAL_STATUS="claude_error"
    break
  fi

  # Pull — Claude pushed.
  ( cd "$REPO_DIR" && git pull --ff-only --quiet origin "$HEAD_REF" || true )

  ITER=$((ITER + 1))
  RUNS=$((RUNS + 1))
done

if [[ "$FINAL_STATUS" == "unknown" ]]; then
  FINAL_STATUS="max_iterations_reached"
fi

log ""
log "============================================================"
log "AI PR loop finished: $FINAL_STATUS"
log "  ran $RUNS iteration(s) this invocation; last iter attempted = $ITER"
if [[ "$FINAL_STATUS" == "max_iterations_reached" ]]; then
  log "  re-run the same command to grant another $MAX_ITER iterations"
fi
log "  PR:    $PR_URL"
log "  Logs:  $STATE_DIR"
log "============================================================"

case "$FINAL_STATUS" in
  approved|converged_no_major) exit 0 ;;
  *)                            exit 1 ;;
esac
