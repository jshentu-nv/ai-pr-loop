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
#   run.sh <pr-number-or-url> [--repo OWNER/NAME] [--dir REPO_DIR]
#                      [--forge github|gitlab] [--host HOST]
#                      [--max N] [--converge N] [--review-only]
#                      [--context-url URL]... [--context TEXT]...
#                      [--context-file FILE]... [--clear-context]
#                      [--claude-model MODEL] [--claude-effort LEVEL]
#                      [--claude-perms MODE]
#                      [--codex-model MODEL] [--codex-effort LEVEL]
#                      [--codex-tier TIER] [--print-config]
#
# The positional argument is either a PR/MR number (with --repo) or a full
# PR/MR URL, from which the forge, host, repo, and number are all derived:
#   https://github.com/OWNER/NAME/pull/42                     → GitHub
#   https://<gitlab-host>/<group>/<project>/-/merge_requests/7 → GitLab
#                                            (gitlab.com or self-hosted)
#
# Arguments:
#   --repo        Repo slug (required unless a URL is given). GitHub:
#                 OWNER/NAME. GitLab: full project path — subgroups allowed
#                 (e.g. group/subgroup/project).
#   --forge       github (default) | gitlab. Inferred from a URL positional
#                 or from a non-github --host, so usually not needed.
#   --host        Forge hostname, for self-hosted GitLab (e.g.
#                 gitlab-master.nvidia.com). Defaults: github.com /
#                 gitlab.com. Implies --forge gitlab when not github.com.
#   --dir         Local checkout to use. If omitted, the loop manages its own
#                 clone at $LOOP_HOME/checkouts/<slug with / -> __>, cloning
#                 on first use via the forge CLI (`gh repo clone` /
#                 `glab repo clone`) and reusing it thereafter.
#   --max         6 iterations this invocation; pass 0 for uncapped (ceiling 50).
#   --converge    3 consecutive BLOCKER=0 MAJOR=0 codex iters; pass 0 to disable.
#   --restart     Force a new review round even if codex previously APPROVED.
#                 Use after new commits land past a prior approval. Starts at
#                 max(last_codex,last_claude)+1, codex first.
#   --review-only Run a single codex review turn and exit; do not run the
#                 claude implementer. Useful when you want feedback without
#                 auto-fixups. Implies --max 1, disables --converge. Both
#                 APPROVED and CHANGES_REQUESTED exit 0 (review posted).
#   --context-url URL
#                 Web link to attach as reference material for BOTH agents
#                 (design doc, RFC, related issue, API reference, ...). The
#                 agents fetch it themselves (Claude via WebFetch, Codex via
#                 curl). Repeatable.
#   --context TEXT
#                 Free-text note to attach for both agents. Repeatable.
#   --context-file FILE
#                 Local file whose contents are injected verbatim as context
#                 for both agents. Read at launch (not referenced later), so
#                 the path need not survive to later re-runs. Repeatable.
#   --clear-context
#                 Drop any context persisted from a prior invocation on this
#                 PR. Ignored when new --context* flags are also given (those
#                 replace the prior context instead).
#   --claude-model MODEL
#                 Model for the Claude implementer's `claude -p` turns, passed
#                 as `--model MODEL`. Default: fable (Claude Fable 5; alias
#                 resolved by the claude CLI). Use `off` to leave the CLI/
#                 settings default untouched.
#   --claude-effort LEVEL
#                 Reasoning effort for the Claude implementer's `claude -p`
#                 turns. Default: ultracode (xhigh reasoning + dynamic-workflow
#                 orchestration, via --settings). Other values map to
#                 `claude --effort LEVEL`: low | medium | high | xhigh | max.
#                 Use `off` to leave the CLI/settings default untouched.
#   --claude-perms MODE
#                 Permission handling for the Claude implementer's `claude -p`
#                 turns. auto (default): --permission-mode auto — every action
#                 is gated by the Claude Code auto-mode classifier, which
#                 approves task-aligned actions headlessly and works on hosts
#                 where bypass is policy-disabled. Auto mode is not available
#                 on every account/provider, and ineligible hosts silently
#                 downgrade it; a deterministic preflight probe reads the
#                 CLI-reported effective mode (cached per PR) and uses the
#                 settings safety net when auto does not stick. A CLI that
#                 hard-rejects the flag at startup instead triggers a single
#                 retry with the same net. bypass: --dangerously-skip-permissions plus a
#                 settings safety net (auto-accepted edits + allowed
#                 Bash/WebFetch/WebSearch) for hosts that silently downgrade
#                 bypass. off: leave the host's CLI/settings default
#                 untouched.
#   --codex-model MODEL
#                 Model for the Codex reviewer's `codex exec` turns, passed as
#                 `-m MODEL` on every turn. Default: gpt-5.6-sol. Use `off` to
#                 leave the host's codex config untouched.
#   --codex-effort LEVEL
#                 Reasoning effort for the Codex reviewer's `codex exec` turns,
#                 applied as `-c model_reasoning_effort=LEVEL` on every turn:
#                 low | medium | high | xhigh | max | ultra. Default: ultra
#                 when the codex model is gpt-5.6-sol/-terra (the only models
#                 that support it); for any other --codex-model no level is
#                 forced (same as `off`) — the host codex config / the model's
#                 own default applies, since effort ceilings vary per model.
#                 An explicit level is passed verbatim. Use `off` to leave
#                 the host's codex config untouched.
#   --codex-tier TIER
#                 Service (speed) tier for the Codex reviewer, applied as
#                 `-c service_tier=TIER` on every turn. Default: fast (the
#                 "Fast" tier: 1.5x speed, increased usage). Use `off` to
#                 leave the host's codex config untouched.
#   --print-config
#                 Print the resolved model/effort/tier knobs (after adaptive
#                 defaults) and exit without contacting GitHub; the PR number
#                 is optional in this mode. Used by tests/run_tests.sh to
#                 observe the resolution.
#
# Context flags persist per-PR: re-running without them reuses the prior
# context.md, so you only pass them once. Pass any --context* flag to replace
# the stored context, or --clear-context to drop it.
#
# Credentials — one per forge:
#   GitHub: GH_TOKEN/GITHUB_TOKEN (the gh CLI must be logged in). Works on
#           any GitHub repo the authenticated user can push + comment on.
#   GitLab: GITLAB_TOKEN, or a `glab auth login --hostname <host>` session
#           (the token is read from the glab config). The token is exported
#           to both agents — all GitLab REST calls go through curl, because
#           `glab api` silently drops position payloads on inline comments.

set -euo pipefail

LOOP_HOME="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
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
URL_ARG=""
FORGE=""
FORGE_HOST=""
RESTART=0
REVIEW_ONLY=0
PRINT_CONFIG=0
CONTEXT_URLS=()
CONTEXT_NOTES=()
CONTEXT_FILES=()
CLEAR_CONTEXT=0
CLAUDE_MODEL="fable"
CLAUDE_EFFORT="ultracode"
CLAUDE_PERMS="auto"
CODEX_MODEL="gpt-5.6-sol"
CODEX_EFFORT=""           # resolved after parsing: ultra for gpt-5.6-sol/-terra, off (host/model default) otherwise
CODEX_TIER="fast"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)          REPO_SLUG="$2"; shift 2 ;;
    --dir)           REPO_DIR="$2";  shift 2 ;;
    --forge)         [[ $# -ge 2 && "$2" != -* ]] || die "--forge needs github or gitlab"; FORGE="$2"; shift 2 ;;
    --host)          [[ $# -ge 2 && "$2" != -* ]] || die "--host needs a hostname"; FORGE_HOST="$2"; shift 2 ;;
    --max)           MAX_ITER="$2";  shift 2 ;;
    --converge)      CONVERGE_N="$2"; shift 2 ;;
    --restart)       RESTART=1; shift ;;
    --review-only)   REVIEW_ONLY=1; shift ;;
    --context-url)   [[ $# -ge 2 ]] || die "--context-url needs a URL";  CONTEXT_URLS+=("$2");  shift 2 ;;
    --context)       [[ $# -ge 2 ]] || die "--context needs text";       CONTEXT_NOTES+=("$2"); shift 2 ;;
    --context-file)  [[ $# -ge 2 ]] || die "--context-file needs a path"; CONTEXT_FILES+=("$2"); shift 2 ;;
    --clear-context) CLEAR_CONTEXT=1; shift ;;
    --claude-model)  [[ $# -ge 2 && "$2" != -* ]] || die "--claude-model needs a model";  CLAUDE_MODEL="$2";  shift 2 ;;
    --claude-effort) [[ $# -ge 2 ]] || die "--claude-effort needs a level"; CLAUDE_EFFORT="$2"; shift 2 ;;
    --claude-perms)  [[ $# -ge 2 && "$2" != -* ]] || die "--claude-perms needs a mode";   CLAUDE_PERMS="$2";  shift 2 ;;
    --codex-model)   [[ $# -ge 2 && "$2" != -* ]] || die "--codex-model needs a model";   CODEX_MODEL="$2";   shift 2 ;;
    --codex-effort)  [[ $# -ge 2 && -n "$2" ]] || die "--codex-effort needs a level";  CODEX_EFFORT="$2";  shift 2 ;;
    --codex-tier)    [[ $# -ge 2 && "$2" != -* ]] || die "--codex-tier needs a tier";     CODEX_TIER="$2";    shift 2 ;;
    --print-config)  PRINT_CONFIG=1; shift ;;
    -h|--help)
      awk 'NR < 2 { next } /^set -euo pipefail/ { exit } { print }' "$0"; exit 0 ;;
    *)
      [[ -z "$PR_NUMBER" && -z "$URL_ARG" ]] || die "unexpected arg: $1"
      if [[ "$1" == http://* || "$1" == https://* ]]; then
        URL_ARG="$1"
      else
        PR_NUMBER="$1"
      fi
      shift ;;
  esac
done

# --- forge resolution -----------------------------------------------------------
#
# A URL positional pins forge, host, repo, and number all at once; explicit
# --forge/--host/--repo may accompany it but must agree. Without a URL, the
# forge defaults to github unless --forge says otherwise or --host names a
# non-github host (self-hosted GitHub is not supported, so any other host
# must be GitLab).
if [[ -n "$URL_ARG" ]]; then
  if [[ "$URL_ARG" =~ ^https?://github\.com/([^/]+/[^/]+)/pull/([0-9]+) ]]; then
    URL_FORGE=github; URL_HOST=github.com
    URL_SLUG="${BASH_REMATCH[1]}"; URL_PR="${BASH_REMATCH[2]}"
  elif [[ "$URL_ARG" =~ ^https?://([^/]+)/(.+)/-/merge_requests/([0-9]+) ]]; then
    URL_FORGE=gitlab; URL_HOST="${BASH_REMATCH[1]}"
    URL_SLUG="${BASH_REMATCH[2]}"; URL_PR="${BASH_REMATCH[3]}"
  elif [[ "$URL_ARG" =~ ^https?://([^/]+)/(.+)/merge_requests/([0-9]+) ]]; then
    # Legacy GitLab URL form (pre-13.0, no /-/ separator).
    URL_FORGE=gitlab; URL_HOST="${BASH_REMATCH[1]}"
    URL_SLUG="${BASH_REMATCH[2]}"; URL_PR="${BASH_REMATCH[3]}"
  else
    die "unrecognized PR/MR URL: $URL_ARG (expected .../pull/N or .../-/merge_requests/N)"
  fi
  [[ -z "$FORGE" || "$FORGE" == "$URL_FORGE" ]] \
    || die "--forge $FORGE conflicts with the URL (a $URL_FORGE link)"
  [[ -z "$FORGE_HOST" || "$FORGE_HOST" == "$URL_HOST" ]] \
    || die "--host $FORGE_HOST conflicts with the URL host ($URL_HOST)"
  [[ -z "$REPO_SLUG" || "$REPO_SLUG" == "$URL_SLUG" ]] \
    || die "--repo $REPO_SLUG conflicts with the URL repo ($URL_SLUG)"
  FORGE="$URL_FORGE"; FORGE_HOST="$URL_HOST"
  REPO_SLUG="$URL_SLUG"; PR_NUMBER="$URL_PR"
fi
if [[ -z "$FORGE" ]]; then
  if [[ -n "$FORGE_HOST" && "$FORGE_HOST" != "github.com" ]]; then
    FORGE=gitlab
  else
    FORGE=github
  fi
fi
case "$FORGE" in
  github)
    FORGE_HOST="${FORGE_HOST:-github.com}"
    [[ "$FORGE_HOST" == "github.com" ]] \
      || die "self-hosted GitHub is not supported (--host $FORGE_HOST)"
    ;;
  gitlab)
    FORGE_HOST="${FORGE_HOST:-gitlab.com}"
    ;;
  *) die "--forge must be github or gitlab (got: $FORGE)" ;;
esac

[[ -n "$REPO_SLUG" ]] || die "--repo OWNER/NAME is required (see --help)"
[[ "$REPO_SLUG" == */* ]] || die "--repo must be in OWNER/NAME form, got: $REPO_SLUG"

# --max 0 → uncapped (still honor the hard ceiling).
if [[ "$MAX_ITER" -eq 0 ]] 2>/dev/null; then
  log "uncapped (--max 0): hard ceiling = $HARD_CEILING iterations this invocation"
  MAX_ITER="$HARD_CEILING"
fi

# --review-only: single codex turn, no claude turn, no convergence check.
if (( REVIEW_ONLY == 1 )); then
  MAX_ITER=1
  CONVERGE_N=0
  log "review-only: running a single codex review turn (no claude implementer)"
fi

# Validate the implementer effort level up front (the claude CLI accepts an
# unknown --effort at parse time and only falls back later, so catch typos here).
case "$CLAUDE_EFFORT" in
  ultracode|low|medium|high|xhigh|max|off) ;;
  *) die "--claude-effort must be one of: ultracode low medium high xhigh max off (got: $CLAUDE_EFFORT)" ;;
esac
# Implementer permission handling: classifier-gated auto mode by default.
case "$CLAUDE_PERMS" in
  auto|bypass|off) ;;
  *) die "--claude-perms must be one of: auto bypass off (got: $CLAUDE_PERMS)" ;;
esac
# Codex reasoning effort: ceilings vary per model (ultra only exists for
# gpt-5.6-sol/-terra; older gpt-5.x reject ultra/max, some catalog models top
# out below xhigh), so when --codex-effort is not given the default adapts:
# ultra for sol/terra, otherwise 'off' — no level is forced and the host
# codex config / the model's own default applies. An explicit --codex-effort
# always wins verbatim.
CODEX_EFFORT=$(resolve_codex_effort "$CODEX_MODEL" "$CODEX_EFFORT")
case "$CODEX_EFFORT" in
  low|medium|high|xhigh|max|ultra|off) ;;
  *) die "--codex-effort must be one of: low medium high xhigh max ultra off (got: $CODEX_EFFORT)" ;;
esac
# Models and the codex service tier are free-form (validated by the CLIs /
# the codex model catalog); only guard against empty values. `off` = leave
# the host's CLI/config default untouched.
[[ -n "$CLAUDE_MODEL" ]] || die "--claude-model needs a model (or 'off')"
[[ -n "$CODEX_MODEL"  ]] || die "--codex-model needs a model (or 'off')"
[[ -n "$CODEX_TIER"   ]] || die "--codex-tier needs a tier (or 'off')"

# --print-config: report the resolved knobs and exit before any forge access.
# Lets tests (and humans) observe adaptive-default and URL/forge resolution
# directly.
if (( PRINT_CONFIG == 1 )); then
  printf 'forge: %s host=%s repo=%s pr=%s\n' "$FORGE" "$FORGE_HOST" "$REPO_SLUG" "${PR_NUMBER:--}"
  printf 'claude: model=%s effort=%s perms=%s\n' "$CLAUDE_MODEL" "$CLAUDE_EFFORT" "$CLAUDE_PERMS"
  printf 'codex: model=%s effort=%s tier=%s\n' "$CODEX_MODEL" "$CODEX_EFFORT" "$CODEX_TIER"
  exit 0
fi

[[ -n "$PR_NUMBER" ]] || die "PR number is required (first positional arg)"
[[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || die "PR number must be numeric: $PR_NUMBER"

# Validate any --context-file paths up front so we fail fast (contents are read
# at render time below, not stored by reference).
for _cf in "${CONTEXT_FILES[@]}"; do
  [[ -f "$_cf" ]] || die "--context-file not found or not a regular file: $_cf"
  [[ -r "$_cf" ]] || die "--context-file not readable: $_cf"
done

# First/last path component. Exact owner/name on GitHub; on GitLab (where
# the slug may contain subgroups) these are informational only — API paths
# and naming use the full $REPO_SLUG.
REPO_OWNER="${REPO_SLUG%%/*}"
REPO_NAME="${REPO_SLUG##*/}"

# Default checkout location when --dir not given: one managed clone per repo,
# shared across PRs of that repo. (Concurrent loops on the same repo should
# pass --dir to point at separate clones.) Slug-derived name: identical to
# the old <owner>__<name> layout for GitHub. A GitLab path with a literal
# "__" component can alias another path's flat name; ensure_repo_clone and
# ensure_state_dir both detect that and die rather than share.
if [[ -z "$REPO_DIR" ]]; then
  REPO_DIR="$LOOP_HOME/checkouts/${REPO_SLUG//\//__}"
fi

export FORGE FORGE_HOST REPO_SLUG \
       REPO_OWNER REPO_NAME PR_NUMBER REPO_DIR MAX_ITER LOOP_HOME REVIEW_ONLY \
       CLAUDE_MODEL CLAUDE_EFFORT CLAUDE_PERMS CODEX_MODEL CODEX_EFFORT CODEX_TIER

preflight
ensure_repo_clone

# --- discover branches --------------------------------------------------------

case "$FORGE" in
  gitlab)
    PR_JSON=$(gl_api_get "projects/${PROJECT_ENC}/merge_requests/${PR_NUMBER}") \
      || die "failed to fetch MR !${PR_NUMBER} of ${REPO_SLUG} from ${FORGE_HOST}"
    PR_STATE=$(jq -r '.state'          <<<"$PR_JSON")
    HEAD_REF=$(jq -r '.source_branch'  <<<"$PR_JSON")
    BASE_REF=$(jq -r '.target_branch'  <<<"$PR_JSON")
    PR_URL=$(jq -r '.web_url'          <<<"$PR_JSON")
    [[ "$PR_STATE" == "opened" ]] || die "MR is not open (state=$PR_STATE)"
    # The loop fetches/pushes origin/$HEAD_REF; a cross-fork MR's source
    # branch lives in another project, which this flow can't reach.
    [[ "$(jq -r '.source_project_id == .target_project_id' <<<"$PR_JSON")" == "true" ]] \
      || die "cross-fork MRs are not supported (source project differs from target)"
    ;;
  *)
    PR_JSON=$(gh pr view "$PR_NUMBER" --repo "$REPO_SLUG" \
                --json headRefName,baseRefName,state,url)
    PR_STATE=$(jq -r '.state'        <<<"$PR_JSON")
    HEAD_REF=$(jq -r '.headRefName'  <<<"$PR_JSON")
    BASE_REF=$(jq -r '.baseRefName'  <<<"$PR_JSON")
    PR_URL=$(jq -r '.url'            <<<"$PR_JSON")
    [[ "$PR_STATE" == "OPEN" ]] || die "PR is not OPEN (state=$PR_STATE)"
    ;;
esac
export HEAD_REF BASE_REF

ensure_state_dir
export STATE_DIR
RUN_LOG="$STATE_DIR/run.log"
: > "$RUN_LOG"

# --- additional context (web links / notes / files) ---------------------------
#
# Optional reference material the human attaches for BOTH agents. Rendered once
# to $STATE_DIR/context.md; each turn injects that path into the prompt and the
# agent reads it (and fetches any URLs) itself. Persisted across invocations:
#   - any --context* flag this run  → (re)render context.md from the flags
#   - no --context* flag, --clear-context → drop a prior context.md
#   - no --context* flag, file present     → reuse the prior context.md
CONTEXT_FILE="$STATE_DIR/context.md"
HAS_CONTEXT=0

# Drop empty / whitespace-only inputs so a stray `--context ""` or an empty
# --context-file doesn't activate (and then stickily persist via the reuse
# branch below) a content-free context. Only genuine material counts.
_urls=();  for _u  in "${CONTEXT_URLS[@]}";  do [[ -n "${_u//[[:space:]]/}" ]] && _urls+=("$_u");   done
_notes=(); for _n  in "${CONTEXT_NOTES[@]}"; do [[ -n "${_n//[[:space:]]/}" ]] && _notes+=("$_n");  done
_files=(); for _cf in "${CONTEXT_FILES[@]}"; do
  if grep -q '[^[:space:]]' "$_cf"; then _files+=("$_cf"); fi
done
CONTEXT_URLS=("${_urls[@]}"); CONTEXT_NOTES=("${_notes[@]}"); CONTEXT_FILES=("${_files[@]}")

if (( ${#CONTEXT_URLS[@]} + ${#CONTEXT_NOTES[@]} + ${#CONTEXT_FILES[@]} > 0 )); then
  {
    cat <<'CTX_HDR'
# Additional review context

The operator running this loop attached the trusted reference material below
for this PR. Read it, fetch any URLs it lists (Claude via WebFetch, Codex via
`curl`), and factor all of it into your work — this iteration and every
following one. It supplements the PR's own description and the repository's
conventions; weigh it alongside them as authoritative background.
CTX_HDR
    if (( ${#CONTEXT_URLS[@]} > 0 )); then
      printf '\n## Web links\n\n'
      for _u in "${CONTEXT_URLS[@]}"; do printf -- '- %s\n' "$_u"; done
    fi
    if (( ${#CONTEXT_NOTES[@]} > 0 )); then
      printf '\n## Notes\n\n'
      for _n in "${CONTEXT_NOTES[@]}"; do printf -- '%s\n\n' "$_n"; done
    fi
    for _cf in "${CONTEXT_FILES[@]}"; do
      printf '\n## Attached file: %s\n\n' "$_cf"
      cat -- "$_cf"
      printf '\n\n---\n'
    done
  } > "$CONTEXT_FILE"
  HAS_CONTEXT=1
  log "context: wrote ${#CONTEXT_URLS[@]} link(s), ${#CONTEXT_NOTES[@]} note(s), ${#CONTEXT_FILES[@]} file(s) -> $CONTEXT_FILE"
elif (( CLEAR_CONTEXT == 1 )); then
  rm -f "$CONTEXT_FILE"
  log "context: --clear-context — dropped any context stored for this PR"
elif [[ -s "$CONTEXT_FILE" ]]; then
  HAS_CONTEXT=1
  log "context: reusing stored context at $CONTEXT_FILE (no --context* flags this run; --clear-context to drop)"
fi
export CONTEXT_FILE HAS_CONTEXT

log "------------------------------------------------------------"
log "AI PR loop starting"
log "  PR:    $PR_URL"
log "  forge: $FORGE ($FORGE_HOST)"
log "  base:  $BASE_REF"
log "  head:  $HEAD_REF"
log "  dir:   $REPO_DIR"
log "  max:   $MAX_ITER iterations (this invocation)"
log "  mode:  $( (( REVIEW_ONLY == 1 )) && echo 'review-only (codex only, no claude)' || echo 'review + implement' )"
log "  ctx:   $( (( HAS_CONTEXT == 1 )) && echo "$CONTEXT_FILE" || echo 'none' )"
log "  claude: model=$CLAUDE_MODEL effort=$CLAUDE_EFFORT perms=$CLAUDE_PERMS"
log "  codex:  model=$CODEX_MODEL effort=$CODEX_EFFORT tier=$CODEX_TIER"
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
if (( RESTART == 1 )) && (( LAST_CODEX > 0 || LAST_CLAUDE > 0 )); then
  HIGH=$(( LAST_CODEX > LAST_CLAUDE ? LAST_CODEX : LAST_CLAUDE ))
  ITER=$(( HIGH + 1 ))
  log "--restart: bypassing prior APPROVED state — starting fresh at iter $ITER (codex first)"
elif (( LAST_CODEX == 0 && LAST_CLAUDE == 0 )); then
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
  if (( REVIEW_ONLY == 1 )); then
    # Review-only: claude won't ever respond to the half-step. Treat it as
    # closed and re-review on top of current HEAD at iter LAST_CODEX+1.
    ITER=$(( LAST_CODEX + 1 ))
    log "review-only: prior codex iter=$LAST_CODEX has no claude reply — skipping it, codex re-reviews at iter $ITER"
  else
    ITER="$LAST_CODEX"
    RESUME_CLAUDE_FIRST=1
    log "resuming: codex iter=$LAST_CODEX exists, claude iter=$LAST_CLAUDE — claude will run next at iter $ITER"
  fi
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
      2)  log "codex requested changes on iter $ITER"
          if (( REVIEW_ONLY == 1 )); then
            FINAL_STATUS="review_posted"
            break
          fi ;;
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
  approved|converged_no_major|review_posted) exit 0 ;;
  *)                                          exit 1 ;;
esac
