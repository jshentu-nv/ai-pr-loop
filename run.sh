#!/usr/bin/env bash
# Orchestrator: alternates Codex review and Claude implementer turns on a PR
# until one of:
#   - Codex returns APPROVED                                      → exit 0
#   - Codex reports BLOCKER=0 MAJOR=0 for `--converge` consecutive
#     iterations (NIT-only, "converged_no_major")                 → exit 0
#   - This invocation's iteration cap is hit                      → exit 1
#   - A turn errors                                               → exit 1
#   - --local only: the closing squash or its push fails          → exit 1
#
# The review is exchanged as PR/MR comments by default, or — with --local —
# through files under the state dir, in which case the implementer's rounds
# are committed locally and squashed into the ONE commit that gets pushed
# when the two agents agree. See --local below.
#
# Resume: on each launch the orchestrator inspects what each agent has
# already completed — the PR's existing AI comments, or (with --local) the
# review files on disk — and continues from the high-water mark. If codex
# posted but claude didn't respond (prior run died or hit max between
# turns), claude runs first at that iteration.
#
# Auto-resume: a supervisor in its own session restarts the loop when a run
# dies without finishing, so an external kill does not end the review. On by
# default; see --auto-resume / --no-auto-resume / --stop.
#
# Usage:
#   run.sh <pr-number-or-url> [--repo OWNER/NAME] [--dir REPO_DIR]
#                      [--forge github|gitlab] [--host HOST]
#                      [--max N] [--converge N] [--review-only]
#                      [--local] [--no-push]
#                      [--context-url URL]... [--context TEXT]...
#                      [--context-file FILE]... [--clear-context]
#                      [--claude-model MODEL] [--claude-effort LEVEL]
#                      [--claude-perms MODE]
#                      [--codex-model MODEL] [--codex-effort LEVEL]
#                      [--codex-tier TIER] [--print-config]
#                      [--auto-resume N] [--no-auto-resume] [--stop]
#
#   run.sh --local --base REF [--dir REPO_DIR] [other flags...]
#
#   run.sh --local --audit [--dir REPO_DIR] [--pr-branch NAME] [--no-push]
#                      [other flags...]
#
# The positional argument is either a PR/MR number (with --repo) or a full
# PR/MR URL, from which the forge, host, repo, and number are all derived:
#   https://github.com/OWNER/NAME/pull/42                     → GitHub
#   https://<gitlab-host>/<group>/<project>/-/merge_requests/7 → GitLab
#                                            (gitlab.com or self-hosted)
# With --local --base REF and no positional, there is no PR/MR at all: the
# loop reviews the branch checked out in --dir against REF.
# With --local --audit there is no base either: the loop reviews the whole
# worktree of --dir at HEAD, on a branch it creates for the purpose.
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
#                 May carry a scheme for HTTP-only self-hosts
#                 (--host http://gitlab.lab); default scheme is https, and
#                 an MR URL positional pins the scheme too.
#   --dir         Local checkout to use. If omitted, the loop manages its own
#                 clone at $LOOP_HOME/checkouts/<slug with / -> __> (GitLab
#                 checkouts are additionally prefixed with the host:
#                 <host>__<slug...>, so same-slug repos on different
#                 forges/hosts never share a clone), cloning on first use via
#                 the forge CLI (`gh repo clone` / `glab repo clone`) and
#                 reusing it thereafter.
#   --max         6 iterations this invocation; pass 0 for uncapped (ceiling 50).
#   --converge    3 consecutive BLOCKER=0 MAJOR=0 codex iters; pass 0 to disable.
#   --restart     Force a new review round even if codex previously APPROVED.
#                 Use after new commits land past a prior approval. Starts at
#                 max(last_codex,last_claude)+1, codex first. A pending
#                 half-step (codex posted, claude did not reply) is resumed
#                 first rather than skipped, so an auto-resume relaunch can
#                 replay the flag safely.
#   --review-only Run a single codex review turn and exit; do not run the
#                 claude implementer. Useful when you want feedback without
#                 auto-fixups. Implies --max 1, disables --converge. Both
#                 APPROVED and CHANGES_REQUESTED exit 0 (review posted).
#   --local       Local review mode: the two agents exchange the review
#                 through files under the state dir instead of PR/MR
#                 comments, and the implementer commits without pushing.
#                 When the review ends in agreement (APPROVED, or the
#                 --converge streak), every local round is squashed into ONE
#                 commit, whose message carries the findings, fixes, and
#                 decisions that shaped the final diff, and that single
#                 commit is pushed. Nothing is posted to the forge; a PR/MR
#                 target is still read for its metadata, and its title and
#                 description are refreshed once after the push if the
#                 change made them stale. Ending at the iteration cap or on
#                 an error pushes nothing — the local rounds stay in the
#                 checkout and the next invocation continues them.
#   --audit       Review the whole worktree at HEAD — every file, not a
#                 diff — in the checkout --dir names (default: the current
#                 directory). Local mode only, and takes no PR/MR argument
#                 and no --base.
#                 This is a local BRANCH review the loop sets up for itself:
#                 it creates a branch at HEAD (ai-review/<branch>-<shorthash>,
#                 or --pr-branch NAME), checks it out, and reviews against
#                 HEAD. The branch you had checked out is never written,
#                 because the loop never works on it.
#                 On agreement the rounds squash into ONE commit, that branch
#                 is pushed, and one agent turn opens a PR/MR against the
#                 branch you started on, following the loop's open-pr skill.
#                 That turn works the forge out from origin itself, so
#                 --repo/--forge/--host do not apply; it needs a credential
#                 for whichever forge origin points at.
#                 Re-run the same command to continue an audit in progress.
#   --pr-branch NAME
#                 --audit only: the branch the audit works on and opens its
#                 PR/MR from, instead of ai-review/<branch>-<shorthash>. Must
#                 not exist locally or on origin, and must not name the
#                 branch you have checked out.
#   --base REF    The base to review against when there is no PR/MR (local
#                 mode with no positional argument). Any committish git can
#                 resolve — `main`, `origin/main`, a tag, a SHA. The branch
#                 under review is whatever --dir has checked out.
#   --no-push     Local mode only: create the squashed commit but stop
#                 before pushing it, so it can be inspected first. With
#                 --audit that also means no PR/MR is opened. Re-run without
#                 the flag to finish; the closing turn is not composed again.
#   --context-url URL
#                 Web link to attach as reference material for BOTH agents
#                 (design doc, RFC, related issue, API reference, ...). The
#                 agents fetch it themselves (Claude via WebFetch, Codex via
#                 curl). Repeatable.
#   --context TEXT
#                 Free-text note to attach for both agents. Repeatable.
#   --context-file FILE
#                 Local file whose contents are injected verbatim as context
#                 for both agents. Read at launch and snapshotted to the
#                 PR's context.md; once that snapshot lands, the path is
#                 never read again (auto-resume relaunches replay the flag
#                 — and re-read the file — only until the snapshot
#                 succeeds). Repeatable.
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
#   --preflight-only
#                 Run the full authenticated preflight — authority
#                 validation, credential resolution (env-isolated,
#                 OAuth-rejecting), /user lookup, PR/MR fetch + open check —
#                 print the resolved identity, PR/MR URL, and branches, then
#                 exit 0 WITHOUT cloning, posting, or looping. Side-effect
#                 free: the skill uses it to name the exact API/comment
#                 identity before asking the operator to confirm a run.
#                 (Pushes are separate: they use the checkout's own git
#                 credential — SSH key or helper — which may belong to a
#                 different account.)
#   --auto-resume N
#                 Restart budget for the auto-resume supervisor. Default 10;
#                 0 disables it (same as --no-auto-resume). The supervisor
#                 runs in its own session and relaunches the loop when a run
#                 dies without a final status — killed by an external
#                 SIGTERM/SIGHUP — or when an agent turn errors. Each
#                 relaunch resumes from the PR's high-water mark. A run that
#                 fails before it starts (bad flags, failed preflight) is not
#                 relaunched. A relaunch keeps the invocation's remaining
#                 --max/--converge budget; once a worker lands the context
#                 snapshot it drops the context flags (--context*,
#                 --clear-context) and reuses the persisted context, and
#                 before that it replays them. The supervisor logs to
#                 state/<ident>/pr-<N>/supervisor.log; this command tails
#                 that log, so foreground output is the same as an inline
#                 run. --print-config and --preflight-only always run
#                 inline. Requires setsid with -f support (util-linux) or
#                 perl for the detached session AND flock or perl for the
#                 single-supervisor lock; missing either, the loop runs
#                 inline, with a warning.
#   --no-auto-resume
#                 Run the loop in this process. Nothing restarts it.
#   --stop        Write the stop sentinel for this PR and signal its
#                 supervisor — or, when a SIGKILL took the supervisor and
#                 left its worker tree orphaned, the worker's process
#                 group — then exit. Runs no preflight and clones nothing.
#                 Ctrl-C on the foreground command does the same.
#
# Context flags persist per-PR: re-running without them reuses the prior
# context.md, so you only pass them once. Pass any --context* flag to replace
# the stored context, or --clear-context to drop it. An auto-resume relaunch
# replays the --context* flags (re-reading their inputs) only until a worker
# lands the invocation's snapshot; after that it reuses the persisted
# context.md and never reads the paths again, so a temporary file stays
# valid for the rest of the supervised run.
#
# Credentials — one per forge:
#   GitHub: GH_TOKEN/GITHUB_TOKEN (the gh CLI must be logged in). Works on
#           any GitHub repo the authenticated user can push + comment on.
#   GitLab: GITLAB_TOKEN, or a `glab auth login --hostname <host>` session
#           backed by a personal access token (the token is read from the
#           glab config). OAuth web/device glab sessions are rejected at
#           preflight: their tokens can only be sent as a Bearer header and
#           expire mid-loop, while every call here uses PRIVATE-TOKEN. The
#           token is exported to both agents — all GitLab REST calls go
#           through curl, because `glab api` silently drops position
#           payloads on inline comments.

set -euo pipefail

LOOP_HOME="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$LOOP_HOME/lib/common.sh"

# --- args ---------------------------------------------------------------------

MAX_ITER_DEFAULT=6
CONVERGE_DEFAULT=3
HARD_CEILING=50           # safety bound when --max 0 (uncapped)
AUTO_RESUME_DEFAULT=10    # restart budget for the auto-resume supervisor

REPO_SLUG=""
REPO_DIR=""
REPO_DIR_CANON=""     # set for local branch reviews, where it is the identity
MANAGED_CLONE=1          # 0 when --dir points at a caller-supplied clone
MAX_ITER="$MAX_ITER_DEFAULT"
CONVERGE_N="$CONVERGE_DEFAULT"
PR_NUMBER=""
URL_ARG=""
FORGE=""
FORGE_HOST=""
RESTART=0
REVIEW_ONLY=0
PRINT_CONFIG=0
PREFLIGHT_ONLY=0
LOCAL_MODE=0
LOCAL_SCOPE=pr
BASE_ARG=""
NO_PUSH=0
# --audit is not a scope of its own: it sets a local BRANCH review up on a
# branch the loop creates, and adds one step at the end. AUDIT_PR_BASE is
# the branch that PR/MR targets — the one the operator had checked out.
AUDIT=0
PR_BRANCH_ARG=""
AUDIT_PR_BASE=""
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
AUTO_RESUME="$AUTO_RESUME_DEFAULT"
STOP_ONLY=0
ROLE=frontend             # frontend | supervise | worker (the last two are internal)
WORKER_ARGV=()            # this argv minus the flags parsed in the loop's own cases below

while [[ $# -gt 0 ]]; do
  # Snapshot the vector so the supervisor can hand the worker this
  # invocation's argv verbatim — array in, array out, so a --context note
  # holding newlines and quotes survives. ARGV_MINE marks the flags this
  # script consumes for itself; everything else is copied through.
  ARGV_HEAD=("$@"); ARGV_N=$#; ARGV_MINE=0
  case "$1" in
    --repo)          REPO_SLUG="$2"; shift 2 ;;
    --dir)           REPO_DIR="$2"; MANAGED_CLONE=0; shift 2 ;;
    --forge)         [[ $# -ge 2 && "$2" != -* ]] || die "--forge needs github or gitlab"; FORGE="$2"; shift 2 ;;
    --host)          [[ $# -ge 2 && "$2" != -* ]] || die "--host needs a hostname"; FORGE_HOST="$2"; shift 2 ;;
    --max)           MAX_ITER="$2";  shift 2 ;;
    --converge)      CONVERGE_N="$2"; shift 2 ;;
    --restart)       RESTART=1; shift ;;
    --review-only)   REVIEW_ONLY=1; shift ;;
    --local)         LOCAL_MODE=1; shift ;;
    --audit)         AUDIT=1; shift ;;
    --pr-branch)     [[ $# -ge 2 && "$2" != -* ]] || die "--pr-branch needs a branch name"
                     PR_BRANCH_ARG="$2"; shift 2 ;;
    --base)          [[ $# -ge 2 && -n "$2" ]] || die "--base needs a git ref"; BASE_ARG="$2"; shift 2 ;;
    --no-push)       NO_PUSH=1; shift ;;
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
    --preflight-only) PREFLIGHT_ONLY=1; shift ;;
    --auto-resume)   [[ $# -ge 2 ]] || die "--auto-resume needs a restart budget"
                     AUTO_RESUME="$2"; ARGV_MINE=1; shift 2 ;;
    --no-auto-resume) AUTO_RESUME=0; ARGV_MINE=1; shift ;;
    --stop)          STOP_ONLY=1; ARGV_MINE=1; shift ;;
    --_supervise|--_worker)
      # Internal roles, set by the front-end and the supervisor.
      [[ "$ROLE" == "frontend" ]] || die "pass at most one of --_supervise / --_worker"
      case "$1" in --_worker) ROLE=worker ;; *) ROLE=supervise ;; esac
      ARGV_MINE=1; shift ;;
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
  if (( ARGV_MINE == 0 )); then
    for (( ARGV_I = 0; ARGV_I < ARGV_N - $#; ARGV_I++ )); do
      WORKER_ARGV+=("${ARGV_HEAD[$ARGV_I]}")
    done
  fi
done

[[ "$AUTO_RESUME" =~ ^[0-9]+$ ]] || die "--auto-resume needs a non-negative count (got: $AUTO_RESUME)"

# --- review mode / scope --------------------------------------------------------
#
# --local without a PR/MR positional means there is no forge target at all:
# the loop reviews the branch checked out in --dir against --base. Everything
# below that reads or writes a forge is skipped in that scope.
if (( LOCAL_MODE == 0 )); then
  [[ -z "$BASE_ARG" ]] || die "--base only applies to --local (without a PR/MR, the base comes from --base; with one, from the PR/MR)"
  (( NO_PUSH == 0 )) || die "--no-push only applies to --local (forge mode pushes each iteration's commit as it is made)"
fi
if (( LOCAL_MODE == 1 )) && [[ -z "$PR_NUMBER" && -z "$URL_ARG" ]]; then
  LOCAL_SCOPE=branch
fi
if (( AUDIT == 1 )); then
  # Named before the generic --base rejection below, so an operator who
  # passed --audit is told about --audit, not about a flag they did not pass.
  (( LOCAL_MODE == 1 )) || die "--audit is a local review mode; pass --local --audit"
  [[ -z "$PR_NUMBER" && -z "$URL_ARG" ]] \
    || die "--audit reviews the checked-out worktree; it takes no PR/MR number or URL"
  [[ -z "$BASE_ARG" ]] \
    || die "--audit reviews the whole worktree at HEAD; there is no base to diff against (use --local --base REF for a branch review)"
fi
if [[ -n "$PR_BRANCH_ARG" ]]; then
  (( AUDIT == 1 )) \
    || die "--pr-branch applies only to --local --audit (it names the branch an audit works on)"
  [[ "$PR_BRANCH_ARG" != refs/* ]] \
    || die "--pr-branch takes a branch name, not a full ref (got: $PR_BRANCH_ARG)"
  [[ "$PR_BRANCH_ARG" != +* ]] \
    || die "--pr-branch must not start with '+' (it becomes a push refspec)"
fi
if [[ "$LOCAL_SCOPE" != "branch" && -n "$BASE_ARG" ]]; then
  die "--base is for a local review with no PR/MR; the base branch of $( ((LOCAL_MODE)) && echo 'this PR/MR' || echo 'a PR/MR' ) comes from the forge"
fi

# --- forge resolution -----------------------------------------------------------
#
# A URL positional pins forge, host, repo, number, and scheme all at once;
# explicit --forge/--host/--repo may accompany it but must agree. Without a
# URL, the forge defaults to github unless --forge says otherwise or --host
# names a non-github host (self-hosted GitHub is not supported, so any other
# host must be GitLab).
#
# The scheme (https default) is preserved end-to-end — orchestrator API
# calls and both rendered prompts — so an HTTP-only self-hosted GitLab is
# reached on the scheme it actually serves. --host may carry it explicitly
# (--host http://gitlab.lab) for slug+number invocations without a URL.
if [[ "$LOCAL_SCOPE" != "branch" ]]; then
  FORGE_SCHEME=""
  if [[ "$FORGE_HOST" =~ ^(https?)://(.+)$ ]]; then
    FORGE_SCHEME="${BASH_REMATCH[1]}"
    FORGE_HOST="${BASH_REMATCH[2]%/}"
  fi
  if [[ -n "$URL_ARG" ]]; then
    # Split scheme/authority/path FIRST, validate the authority (userinfo
    # smuggling dies here, before any classification), then classify on the
    # CANONICAL authority: https://GITHUB.COM/..., github.com./..., and
    # github.com:443/... are all links to the supported GitHub endpoint.
    # FORGE_HOST keeps the RAW spelling — the later canonicalization step
    # normalizes it while preserving ORIG_HOST for glab's exact-key probe.
    [[ "$URL_ARG" =~ ^(https?)://([^/]+)(/.+)$ ]] \
      || die "unrecognized PR/MR URL: $URL_ARG (expected .../pull/N or .../-/merge_requests/N)"
    URL_SCHEME="${BASH_REMATCH[1]}"; URL_AUTH="${BASH_REMATCH[2]}"; URL_PATH="${BASH_REMATCH[3]}"
    validate_forge_authority "$URL_AUTH"
    URL_CANON=$(canon_authority "$URL_AUTH" "$URL_SCHEME")
    if [[ "$URL_CANON" == "github.com" && "$URL_PATH" =~ ^/([^/]+/[^/]+)/pull/([0-9]+) ]]; then
      # gh always speaks https to github.com; an http:// link is just a link.
      URL_FORGE=github; URL_AUTH=github.com; URL_CANON=github.com; URL_SCHEME=https
      URL_SLUG="${BASH_REMATCH[1]}"; URL_PR="${BASH_REMATCH[2]}"
    elif [[ "$URL_PATH" =~ ^/(.+)/-/merge_requests/([0-9]+) ]]; then
      URL_FORGE=gitlab
      URL_SLUG="${BASH_REMATCH[1]}"; URL_PR="${BASH_REMATCH[2]}"
    elif [[ "$URL_PATH" =~ ^/(.+)/merge_requests/([0-9]+) ]]; then
      # Legacy GitLab URL form (pre-13.0, no /-/ separator).
      URL_FORGE=gitlab
      URL_SLUG="${BASH_REMATCH[1]}"; URL_PR="${BASH_REMATCH[2]}"
    else
      die "unrecognized PR/MR URL: $URL_ARG (expected .../pull/N or .../-/merge_requests/N)"
    fi
    [[ -z "$FORGE" || "$FORGE" == "$URL_FORGE" ]] \
      || die "--forge $FORGE conflicts with the URL (a $URL_FORGE link)"
    # Redundant flags may agree in ANY equivalent spelling (case, trailing
    # dot, default port) — compare canonically.
    [[ -z "$FORGE_HOST" || "$(canon_authority "$FORGE_HOST" "$URL_SCHEME")" == "$URL_CANON" ]] \
      || die "--host $FORGE_HOST conflicts with the URL host ($URL_CANON)"
    [[ -z "$FORGE_SCHEME" || "$FORGE_SCHEME" == "$URL_SCHEME" ]] \
      || die "--host scheme ${FORGE_SCHEME}:// conflicts with the URL scheme (${URL_SCHEME}://)"
    [[ -z "$REPO_SLUG" || "$REPO_SLUG" == "$URL_SLUG" ]] \
      || die "--repo $REPO_SLUG conflicts with the URL repo ($URL_SLUG)"
    FORGE="$URL_FORGE"; FORGE_HOST="$URL_AUTH"; FORGE_SCHEME="$URL_SCHEME"
    REPO_SLUG="$URL_SLUG"; PR_NUMBER="$URL_PR"
  fi
  # Forge inference and the GitHub host check compare CANONICAL authorities:
  # GITHUB.COM and github.com:443 are spellings of the supported GitHub
  # endpoint, and matching the literal string would route them through the
  # GitLab path (or reject them as self-hosted GitHub).
  if [[ -z "$FORGE" ]]; then
    if [[ -n "$FORGE_HOST" ]] \
       && [[ "$(canon_authority "$FORGE_HOST" "${FORGE_SCHEME:-https}")" != "github.com" ]]; then
      FORGE=gitlab
    else
      FORGE=github
    fi
  fi
  case "$FORGE" in
    github)
      FORGE_HOST="${FORGE_HOST:-github.com}"
      [[ "$(canon_authority "$FORGE_HOST" https)" == "github.com" ]] \
        || die "self-hosted GitHub is not supported (--host $FORGE_HOST)"
      FORGE_HOST="github.com"
      FORGE_SCHEME=https
      ;;
    gitlab)
      FORGE_HOST="${FORGE_HOST:-gitlab.com}"
      FORGE_SCHEME="${FORGE_SCHEME:-https}"
      ;;
    *) die "--forge must be github or gitlab (got: $FORGE)" ;;
  esac
  # The resolved authority goes verbatim into every API URL both here and in
  # the agents' prompts — reject anything that isn't host[:port] (userinfo in
  # a crafted MR link would redirect PAT-bearing calls to another server).
  validate_forge_authority "$FORGE_HOST"
  # Canonicalize an explicit default port away: https://gl.example:443 and
  # https://gl.example are the same endpoint, and every consumer of
  # FORGE_HOST — managed checkout/state naming, identity markers, API URLs,
  # prompts, the clone guard — must agree on ONE spelling, or re-invoking
  # the same MR in the equivalent form would split its state (losing
  # sessions, context, and the on-disk verdict that makes an approved
  # resume a no-op).
  # Canonicalize the authority's port NUMERICALLY (shared canon_authority:
  # curl reaches the same endpoint for :0443 and :443, so no equivalent
  # spelling may fork the identity; the scheme's default port drops, other
  # ports keep canonical digits). ORIG_HOST keeps the validated original
  # spelling for the glab config probe — glab keys host config by the exact
  # login string.
  ORIG_HOST="$FORGE_HOST"
  CANON_HOST=$(canon_authority "$FORGE_HOST" "$FORGE_SCHEME")
  FORGE_HOST="$CANON_HOST"
  # One-time upgrade guard, ALL equivalent spellings: DISCOVER managed state
  # trees whose authority spelling canonicalizes to this target ('gl.example',
  # 'gl.example:443', 'gl.example:0443', ... for an https gl.example) instead
  # of enumerating spellings — re-entry through ANY equivalent form must
  # refuse loudly rather than silently fork a fresh tree and orphan the
  # legacy one (sessions, context, and the approved-resume verdict). Only a
  # tree's markers prove it is OURS: the same directory name is legitimate
  # CANONICAL state for the opposite scheme (443 is not http's default port),
  # so match same-scheme markers and the ambiguous pre-scheme form — a tree
  # whose markers all name the other scheme is left alone. Migration is
  # per-PR (never a whole-tree rename: with an existing canonical tree, mv
  # would NEST the legacy tree inside it, hiding the very sessions/verdicts
  # this guard protects).
  if [[ "$FORGE" == "gitlab" ]]; then
    FLAT_SLUG="${REPO_SLUG//\//__}"
    NEW_IDENT="${CANON_HOST}__${FLAT_SLUG}"
    for LEGACY_DIR in "$LOOP_HOME/state"/*"__${FLAT_SLUG}"; do
      [[ -d "$LEGACY_DIR" ]] || continue
      LEGACY_AUTH="${LEGACY_DIR##*/}"; LEGACY_AUTH="${LEGACY_AUTH%__${FLAT_SLUG}}"
      [[ "$LEGACY_AUTH" == "$CANON_HOST" ]] && continue
      [[ "$(canon_authority "$LEGACY_AUTH" "$FORGE_SCHEME")" == "$CANON_HOST" ]] || continue
      if grep -qsxF \
           -e "gitlab ${FORGE_SCHEME}://${LEGACY_AUTH} ${REPO_SLUG}" \
           -e "gitlab ${LEGACY_AUTH} ${REPO_SLUG}" \
           "$LEGACY_DIR"/pr-*/.repo-slug; then
        die "state keyed by the pre-canonicalization spelling '${LEGACY_AUTH}' exists under $LEGACY_DIR; the canonical identity is '$CANON_HOST'. Migrate per PR: mkdir -p \"$LOOP_HOME/state/$NEW_IDENT\", move each pr-<N> from the legacy dir into it (skip any pr-<N> already present there), update each moved pr-*/.repo-slug to 'gitlab ${FORGE_SCHEME}://${CANON_HOST} ${REPO_SLUG}', then remove the emptied legacy state dir (and any matching legacy checkouts dir) — or simply remove the legacy dirs to start fresh"
      fi
    done
  fi
  if [[ "$FORGE_SCHEME" == "http" ]]; then
    log "WARNING: plain-HTTP API base http://$FORGE_HOST/api/v4 (from the MR URL / --host) — the token travels unencrypted"
  fi

  [[ -n "$REPO_SLUG" ]] || die "--repo OWNER/NAME is required (see --help)"
  [[ "$REPO_SLUG" == */* ]] || die "--repo must be in OWNER/NAME form, got: $REPO_SLUG"
else
  # --- local branch scope: no forge involved ------------------------------
  # Identity is the checkout plus the branch it has checked out; the base is
  # whatever --base names. Nothing here contacts a forge, so no slug, host,
  # scheme, or credential is used — and passing one is a mistake worth
  # naming rather than ignoring.
  [[ -z "$REPO_SLUG"   ]] || die "--repo is not used by a local review with no PR/MR (identity comes from the checkout)"
  [[ -z "$FORGE"       ]] || die "--forge is not used by a local review with no PR/MR"
  [[ -z "$FORGE_HOST"  ]] || die "--host is not used by a local review with no PR/MR"
  if (( AUDIT == 0 )); then
    [[ -n "$BASE_ARG" ]] || die "--base REF is required for a local review with no PR/MR (there is no forge to take the base branch from)"
  fi
  FORGE=local
  FORGE_HOST=""
  FORGE_SCHEME=""
  REPO_SLUG=""
fi

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

# Default checkout location when --dir not given: one managed clone per repo
# identity, shared across PRs of that repo. (Concurrent loops on the same
# repo should pass --dir to point at separate clones.) repo_ident_name keeps
# the legacy <owner>__<name> layout for GitHub and prefixes the host for
# GitLab, so same-slug repos on different forges/hosts never share a clone;
# residual flat-name aliases (literal "__" path components, dotless intranet
# hostnames) are caught by ensure_repo_clone's origin slug+host check and
# ensure_state_dir's identity marker, which die rather than share.
#
# A local review with no PR/MR has no clone to manage: it reviews a checkout
# that already exists, defaulting to the current directory.
if [[ -z "$REPO_DIR" ]]; then
  if [[ "$LOCAL_SCOPE" == "branch" ]]; then
    REPO_DIR="$PWD"
    MANAGED_CLONE=0
  else
    REPO_DIR="$LOOP_HOME/checkouts/$(repo_ident_name)"
  fi
fi

# --print-config: report the resolved knobs and exit before any forge access.
# Lets tests (and humans) observe adaptive-default and URL/forge/scheme/dir
# resolution directly.
if (( PRINT_CONFIG == 1 )); then
  printf 'forge: %s host=%s scheme=%s repo=%s pr=%s\n' "$FORGE" "$FORGE_HOST" "$FORGE_SCHEME" "$REPO_SLUG" "${PR_NUMBER:--}"
  printf 'dir: %s\n' "$REPO_DIR"
  printf 'mode: %s scope=%s base=%s push=%s\n' \
    "$( (( LOCAL_MODE == 1 )) && echo local || echo forge )" \
    "$LOCAL_SCOPE" "${BASE_ARG:--}" \
    "$( (( LOCAL_MODE == 1 && NO_PUSH == 1 )) && echo no || echo yes )"
  (( AUDIT == 1 )) && printf 'audit: yes pr-branch=%s\n' "${PR_BRANCH_ARG:-(derived)}"
  printf 'claude: model=%s effort=%s perms=%s\n' "$CLAUDE_MODEL" "$CLAUDE_EFFORT" "$CLAUDE_PERMS"
  printf 'codex: model=%s effort=%s tier=%s\n' "$CODEX_MODEL" "$CODEX_EFFORT" "$CODEX_TIER"
  exit 0
fi

# --- --audit: a branch review the loop sets up for itself ---------------------
#
# An audit reviews the tree as it stands, with no change in flight. Rather
# than invent a scope for that, it makes one: create a branch at HEAD, check
# it out, and run the ordinary local BRANCH review on it with HEAD as the
# base. Everything after this point — the tip ref, the state identity, the
# resume checks, the squash, the push — is that reviewed path, unchanged.
# The operator's branch is never written because the loop never works on it.
#
# The only lasting addition is the closing step: finalize opens a PR/MR from
# the review branch against the branch the operator had out, recorded here.

# The state dir a local branch review of $1 would use. Needed before
# ensure_state_dir, to tell a fresh audit from one being resumed.
audit_leaf_dir() {  # <branch>
  local h
  h=$(printf '%s' "$1" | short_hash)
  printf '%s/state/local__%s-%s/branch-%s-%s\n' \
    "$LOOP_HOME" "$(ident_slug "$(basename -- "$REPO_DIR_CANON")")" \
    "$(printf '%s' "$REPO_DIR_CANON" | short_hash)" "$(ident_slug "$1")" "$h"
}

# A name is free when no local or remote ref equals it, sits below it, or
# holds it as a path prefix — git refuses both directions of that conflict,
# and hitting it later would cost the whole review.
audit_branch_free() {  # <name>
  local n="$1" r
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    [[ "$r" == "refs/heads/$n"   ]] && return 1
    [[ "$r" == "refs/heads/$n/"* ]] && return 1
    [[ "refs/heads/$n" == "$r/"* ]] && return 1
  done < <(git -C "$REPO_DIR" for-each-ref --format='%(refname)' refs/heads/
           git -C "$REPO_DIR" ls-remote --heads origin 2>/dev/null | awk '{print $2}')
  return 0
}

# The branch the operator had checked out is the one thing an audit
# promises never to write. A turn runs with the operator's authority, so
# this cannot be prevented — but it must never pass unnoticed. Snapshot it
# around every turn and fail loudly if it moved, restoring it first: the
# excursion stays in the reflog, the branch does not.
AUDIT_TARGET_SHA=''
audit_target_snapshot() {
  (( AUDIT == 1 )) || return 0
  AUDIT_TARGET_SHA=$(git -C "$REPO_DIR" rev-parse --verify --quiet "refs/heads/$AUDIT_PR_BASE" 2>/dev/null || true)
}
audit_target_verify() {  # <what ran>
  (( AUDIT == 1 )) || return 0
  local now
  now=$(git -C "$REPO_DIR" rev-parse --verify --quiet "refs/heads/$AUDIT_PR_BASE" 2>/dev/null || true)
  [[ "$now" == "$AUDIT_TARGET_SHA" ]] && return 0
  if [[ -n "$AUDIT_TARGET_SHA" ]]; then
    git_safe -C "$REPO_DIR" update-ref "refs/heads/$AUDIT_PR_BASE" "$AUDIT_TARGET_SHA" \
      || log "audit: WARNING — could not restore '$AUDIT_PR_BASE' to $AUDIT_TARGET_SHA"
  fi
  die "$1 moved '$AUDIT_PR_BASE' (from ${AUDIT_TARGET_SHA:-absent} to ${now:-absent}) — an audit never writes the branch it targets; it has been put back, and the run stops so the turn's work can be inspected"
}

audit_setup_branch() {
  local leaf orig="$HEAD_REF" head stem cand i
  leaf=$(audit_leaf_dir "$HEAD_REF")
  if AUDIT_PR_BASE=$(read_receipted "$leaf/local/audit-pr-base"); then
    # Resuming: the checkout is already on the review branch this audit
    # created. Its base is the one recorded when it started — never
    # recomputed, or a resume would redefine the squash range.
    # base.sha is the live review's squash base. A completed audit has none
    # (it is purged terminally), so fall back to what it landed, and to HEAD
    # for a --restart that will pick its own base anyway. Nothing here
    # recomputes a LIVE review's base — that would redefine its squash range.
    if [[ -s "$leaf/local/base.sha" ]]; then
      BASE_ARG=$(<"$leaf/local/base.sha")
    elif [[ -s "$leaf/local/completed.sha" ]]; then
      BASE_ARG=$(<"$leaf/local/completed.sha")
    else
      BASE_ARG=$(git -C "$REPO_DIR" rev-parse --verify --quiet 'HEAD^{commit}') \
        || die "could not read HEAD in $REPO_DIR"
    fi
    [[ -z "$PR_BRANCH_ARG" || "$PR_BRANCH_ARG" == "$HEAD_REF" ]] \
      || die "--pr-branch '$PR_BRANCH_ARG' disagrees with the audit already running on '$HEAD_REF' — finish or --restart it before renaming"
    log "audit: resuming on '$HEAD_REF' (PR base '$AUDIT_PR_BASE')"
    return
  fi
  # Entry points that only report or signal must not create anything. With
  # no audit on record there is nothing for them to act on anyway.
  if (( STOP_ONLY == 1 || PRINT_CONFIG == 1 || PREFLIGHT_ONLY == 1 )); then
    BASE_ARG="$(git -C "$REPO_DIR" rev-parse --verify --quiet 'HEAD^{commit}' || true)"
    return
  fi
  # Fresh audit. The branch is created at HEAD and checked out; the review
  # then runs against HEAD as its base, so base..HEAD is exactly the loop's
  # own work and is empty on iteration 1.
  head=$(git -C "$REPO_DIR" rev-parse --verify --quiet 'HEAD^{commit}') \
    || die "could not read HEAD in $REPO_DIR"
  if [[ -n "$PR_BRANCH_ARG" ]]; then
    git check-ref-format "refs/heads/$PR_BRANCH_ARG" >/dev/null 2>&1 \
      || die "--pr-branch is not a valid branch name: $PR_BRANCH_ARG"
    [[ "$PR_BRANCH_ARG" != "$orig" ]] \
      || die "--pr-branch must not name the branch under review ($orig) — the audit works on a branch of its own"
    audit_branch_free "$PR_BRANCH_ARG" \
      || die "--pr-branch '$PR_BRANCH_ARG' already exists locally or on origin (or conflicts with an existing ref path)"
    cand="$PR_BRANCH_ARG"
  else
    stem="ai-review/${orig}-$(printf '%s' "$head" | cut -c1-8)"
    cand=''
    for (( i = 1; i <= 20; i++ )); do
      local try="$stem"; (( i > 1 )) && try="${stem}-${i}"
      git check-ref-format "refs/heads/$try" >/dev/null 2>&1 || continue
      if audit_branch_free "$try"; then cand="$try"; break; fi
    done
    [[ -n "$cand" ]] \
      || die "could not derive a free review-branch name from '$orig' (tried $stem and 19 suffixes) — pass --pr-branch NAME"
  fi
  # The worktree must be clean before the loop takes the checkout over; the
  # branch review's own caller-clone check runs later, but a switch here
  # would already carry uncommitted work onto the new branch.
  verify_caller_clone_clean "$REPO_DIR"
  # The marker is written BEFORE the branch is checked out, and against the
  # branch about to be created. run.sh executes three times per invocation —
  # front-end, supervisor, worker — and each one resolves the checkout. A
  # marker written any later (at ensure_state_dir, past the role handoff)
  # would be invisible to the roles that follow: each would find the
  # checkout on the previous role's review branch, read no marker, conclude
  # "fresh audit", and create another branch nested inside it.
  mkdir -p "$(audit_leaf_dir "$cand")/local"
  write_receipted "$(audit_leaf_dir "$cand")/local/audit-pr-base" "$orig" \
    || die "could not record the audit's PR base for '$cand'"
  git_safe -C "$REPO_DIR" checkout --quiet -b "$cand" \
    || { rm -f "$(audit_leaf_dir "$cand")/local/audit-pr-base"{,.receipt}
         die "could not create the review branch '$cand' in $REPO_DIR"; }
  HEAD_REF="$cand"
  BASE_ARG="$head"
  AUDIT_PR_BASE="$orig"
  log "audit: reviewing the worktree of $REPO_DIR on a new branch '$cand' (base $head)"
  log "audit: '$orig' is not written by this run; its PR/MR is opened against it at the end"
}

if [[ "$LOCAL_SCOPE" == "branch" ]]; then
  # The checkout is the target, so it must exist and be a work tree now (a
  # forge-targeted run may still be about to clone one). Its branch is part
  # of the identity every state path below is keyed by, so resolve it here —
  # before the supervisor/--stop state path is computed, which reads it
  # through repo_ident.
  [[ -d "$REPO_DIR" ]] || die "no such directory: $REPO_DIR (pass --dir, or run from inside the checkout)"
  REPO_DIR_CANON=$(CDPATH= cd -- "$REPO_DIR" && pwd -P) \
    || die "could not resolve $REPO_DIR"
  REPO_DIR="$REPO_DIR_CANON"
  git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "not a git work tree: $REPO_DIR"
  HEAD_REF=$(git -C "$REPO_DIR" symbolic-ref --quiet --short HEAD) \
    || die "HEAD in $REPO_DIR is detached — check out the branch you want reviewed"
  (( AUDIT == 1 )) && audit_setup_branch
else
  [[ -n "$PR_NUMBER" ]] || die "PR number is required (first positional arg)"
  [[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || die "PR number must be numeric: $PR_NUMBER"
fi

# --- auto-resume: front-end, supervisor, worker -------------------------------
#
# Three roles share this script.
#
#   front-end  (default)      Parses args, then either runs the loop in this
#                             process (--no-auto-resume, --print-config,
#                             --preflight-only) or starts the supervisor and
#                             tails its log in the foreground.
#   supervisor (--_supervise) Launches the worker, waits for it, and decides
#                             from the status files whether to stop or
#                             relaunch. Lives in its own session, so a
#                             process-group kill aimed at the front-end — or
#                             at the shell that launched it — does not reach
#                             it. That is what lets a killed run come back.
#   worker     (--_worker)    The loop itself. Reports through the status
#                             files below.
#
# Status protocol, all under the per-PR state dir:
#   supervisor.lock  flock'd by the supervisor for its lifetime (and by the
#                    worker tree, which inherits the fd); one supervisor per
#                    PR, enforced by the kernel rather than a check window
#   supervisor.pid   the supervisor's pid + its start-time token; removed
#                    when it exits. Signalling target only — the token pins
#                    the incarnation, so a recycled pid is never signalled
#                    and a stale file blocks nothing
#   supervisor.log   what the front-end tails; appended, never truncated
#   worker.pid       the live worker's pid + start token, written by the
#                    supervisor at each launch — lets --stop reach a worker
#                    orphaned by a SIGKILLed supervisor
#   worker.started   touched once the run is known to be well-formed
#   worker.status    the worker's FINAL_STATUS on a normal exit
#   worker.progress  iterations + convergence streak this invocation has
#                    used, across relaunches, plus the invocation's starting
#                    iteration (the budget baseline); cleared per invocation
#   context.applied  touched once a worker applies this invocation's context
#                    intent; until then relaunches replay the --context*
#                    flags instead of dropping them; cleared per invocation
#   stop             stop sentinel; the supervisor stops and does not relaunch
#
# Every entry point that touches this dir validates the .repo-slug identity
# marker first (check_state_marker): the flat path is not injective, and a
# colliding repo's --stop or start must fail loudly, not act on another
# repository's supervisor.
#
# The state path is the one ensure_state_dir computes; the front-end and the
# supervisor need it before the run is authenticated, so they derive it from
# the resolved identity alone — through the same two helpers, so a scope
# whose leaf is not pr-<N> gets the dir its worker will actually use.
PR_STATE_DIR="$LOOP_HOME/state/$(repo_ident_name)/$(state_leaf_name)"

# TERM the supervisor and everything it started. A detached supervisor leads
# its own process group, so the signal reaches its worker and the agents too;
# without setsid it shares the caller's group, where a group kill would hit
# unrelated processes, so signal the pid alone and let its own trap forward.
signal_supervisor() {
  local pid="$1" pgid
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ') || pgid=''
  if [[ "$pgid" == "$pid" ]]; then
    kill -TERM -- "-$pid" 2>/dev/null || true
  else
    kill -TERM "$pid" 2>/dev/null || true
  fi
}

# Start-time token for pid $1, whitespace-squeezed; empty when unknown.
# Written next to the pid in supervisor.pid and compared on every read: two
# processes can share a recycled pid, but not a pid AND a start time.
# TZ/LC_ALL are pinned because ps renders lstart in the caller's timezone
# and locale — a --stop run from another environment must still match the
# token the supervisor wrote.
proc_start_token() {
  local t
  t=$(TZ=UTC LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null) || t=''
  # shellcheck disable=SC2086
  set -- $t
  printf '%s\n' "$*"
}

# True when pid $1 is a live process of this loop whose argv carries $3 and
# whose start-time token matches $2. A process killed with SIGKILL leaves
# its pid record behind and the operating system hands that pid to
# something else — even to another loop's process — so the command line AND
# the start-time token must both match before the pid is signalled or
# blocks a run.
recorded_pid_is_live() {
  local pid="${1:-}" token="${2:-}" argmark="$3"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ps -o args= -p "$pid" 2>/dev/null | grep -q -- "$argmark" || return 1
  [[ "$(proc_start_token "$pid")" == "$token" ]]
}

supervisor_is_live() { recorded_pid_is_live "${1:-}" "${2:-}" '--_supervise'; }
worker_is_live()     { recorded_pid_is_live "${1:-}" "${2:-}" '--_worker'; }

# Read a pid record file ($1: pid line, token line) into REC_PID / REC_TOKEN.
read_pid_record() {
  REC_PID=''; REC_TOKEN=''
  [[ -s "$1" ]] || return 0
  REC_PID=$(head -1 "$1")
  REC_TOKEN=$(sed -n '2p' "$1")
}

# True when a session primitive exists that spawn_detached can actually
# use: setsid must support -f (fork/reparent — a plain setsid leaves the
# supervisor inside the caller's descendant tree, where a tree reaper
# finds it), or perl does the fork+setsid itself. Without one there is no
# detached session and the loop runs inline instead.
have_session_primitive() {
  { command -v setsid >/dev/null 2>&1 && setsid -f true 2>/dev/null; } \
    || command -v perl >/dev/null 2>&1
}

# True when a tool exists to hold the single-supervisor flock. Supervision
# without it would run unlocked — simultaneous starts could all win — so
# the front-end requires this alongside the session primitive (a
# setsid-without-flock host has a session but no lock).
have_lock_primitive() {
  command -v flock >/dev/null 2>&1 || command -v perl >/dev/null 2>&1
}

# Run a command in its own session, REPARENTED out of this process's
# descendant tree: a task reaper that walks and TERMs the caller's tree
# must not find the supervisor, and a new session alone does not move a
# process off its parent. setsid -f forks so the intermediate exits and
# init adopts the child; the perl arm does the same fork+setsid+exec.
# The front-end checks have_session_primitive before spawning, so the
# last arm is a backstop.
spawn_detached() {
  if command -v setsid >/dev/null 2>&1 && setsid -f true 2>/dev/null; then
    setsid -f "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'exit 0 if fork; use POSIX qw(setsid); setsid();
             exec @ARGV or exit 127' -- "$@"
  else
    die "spawn_detached: neither setsid nor perl is available"
  fi
}

# Take a non-blocking exclusive flock on fd $1. flock(1) is util-linux;
# perl covers hosts without it (macOS). The lock rides the open file
# description, so it survives the perl helper's exit and is inherited by
# every child sharing the fd. Fails closed with neither tool — an unlocked
# supervisor would let simultaneous starts all win, so the front-end gates
# supervision on have_lock_primitive and never reaches that arm.
acquire_lock_fd() {
  if command -v flock >/dev/null 2>&1; then
    flock -n "$1"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'use Fcntl qw(:flock); open(my $fh, ">&=", $ARGV[0]) or exit 2;
             exit(flock($fh, LOCK_EX|LOCK_NB) ? 0 : 1)' "$1"
  else
    return 1
  fi
}

# Record this run's outcome for the supervisor. Only a worker reports; an
# inline run has no supervisor reading it.
write_worker_status() {
  [[ "$ROLE" == "worker" ]] || return 0
  printf '%s\n' "$1" > "$STATE_DIR/worker.status"
}

# Record the loop counters a relaunch must not reset: --max and --converge
# are per-invocation, and a relaunched worker continues the same invocation.
# BASE is the iteration the invocation's FIRST worker started at — the
# budget baseline. A relaunch compares its own starting iteration against
# it: iterations whose summaries landed on the PR are spent even when the
# worker died before persisting RUNS (a posted claude summary followed by a
# nonzero exit leaves RUNS behind the public thread).
persist_worker_progress() {
  [[ "$ROLE" == "worker" ]] || return 0
  printf 'RUNS=%s\nSTREAK=%s\nSTREAK_AT=%s\nBASE=%s\n' \
    "$RUNS" "$CONVERGE_STREAK" "$STREAK_AT" "$RUNS_BASE_ITER" \
    > "$STATE_DIR/worker.progress"
}

# Convergence accounting for iter $1 from its persisted issue_counts.
# Returns 0 when the streak has reached CONVERGE_N — the caller exits the
# loop as converged. Runs after a fresh codex turn AND when a relaunch
# resumes past a codex review that landed before a crash: qualifying
# reviews count either way. STREAK_AT records the last iteration accounted,
# so a relaunch replaying the same landed review cannot count it twice.
update_converge_streak() {
  local it="$1" counts_file ib im
  (( CONVERGE_N > 0 )) || return 1
  (( it > STREAK_AT )) || return 1
  counts_file="$STATE_DIR/$(printf 'iter-%02d' "$it")/issue_counts"
  if [[ ! -f "$counts_file" ]]; then
    log "convergence: no issue_counts file for iter $it — streak unchanged"
    return 1
  fi
  ib=$(awk -F= '/^BLOCKER=/{print $2}' "$counts_file")
  im=$(awk -F= '/^MAJOR=/{print $2}'   "$counts_file")
  STREAK_AT="$it"
  if [[ "$ib" == "0" && "$im" == "0" ]]; then
    CONVERGE_STREAK=$((CONVERGE_STREAK + 1))
    persist_worker_progress
    log "convergence: iter $it BLOCKER=0 MAJOR=0 (streak $CONVERGE_STREAK / $CONVERGE_N)"
    if (( CONVERGE_STREAK >= CONVERGE_N )); then
      log "convergence: $CONVERGE_N consecutive NIT-only iterations — exiting"
      return 0
    fi
  else
    if (( CONVERGE_STREAK > 0 )); then
      log "convergence: streak reset (BLOCKER=$ib MAJOR=$im at iter $it)"
    fi
    CONVERGE_STREAK=0
    persist_worker_progress
  fi
  return 1
}

# --stop: write the sentinel and signal the supervisor — or, when a SIGKILL
# took the supervisor and left its worker tree orphaned, the worker's
# process group. No preflight, no clone — a stop must work even when the
# forge is unreachable. The identity check comes first: on a colliding flat
# path this dir may belong to another repository, and its supervisor must
# not be stopped.
if (( STOP_ONLY == 1 )); then
  mkdir -p "$PR_STATE_DIR"
  claim_state_marker "$PR_STATE_DIR"
  : > "$PR_STATE_DIR/stop"
  log "stop: wrote $PR_STATE_DIR/stop — the supervisor will not relaunch this PR"
  read_pid_record "$PR_STATE_DIR/supervisor.pid"
  if supervisor_is_live "$REC_PID" "$REC_TOKEN"; then
    signal_supervisor "$REC_PID"
    log "stop: signalled supervisor pid $REC_PID"
  else
    # No supervisor to forward the signal. A worker it left behind (the
    # supervisor was SIGKILLed) never reads the sentinel, so signal its
    # process group directly — verified by pid + start token first, and
    # never our own group.
    read_pid_record "$PR_STATE_DIR/worker.pid"
    if worker_is_live "$REC_PID" "$REC_TOKEN"; then
      W_PGID=$(ps -o pgid= -p "$REC_PID" 2>/dev/null | tr -d ' ') || W_PGID=''
      MY_PGID=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ') || MY_PGID=''
      if [[ -n "$W_PGID" && "$W_PGID" != "$MY_PGID" ]]; then
        kill -TERM -- "-$W_PGID" 2>/dev/null || true
        log "stop: no live supervisor — signalled the orphaned worker group $W_PGID (worker pid $REC_PID)"
      else
        kill -TERM "$REC_PID" 2>/dev/null || true
        log "stop: no live supervisor — signalled the orphaned worker pid $REC_PID"
      fi
    else
      log "stop: no live supervisor for this PR"
    fi
  fi
  exit 0
fi

if [[ "$ROLE" == "worker" ]]; then
  # Clear the status files this run will write: a previous run's values must
  # never be read as this one's outcome. Identity first — on a colliding
  # flat path these could be another repository's files.
  mkdir -p "$PR_STATE_DIR"
  claim_state_marker "$PR_STATE_DIR"
  rm -f "$PR_STATE_DIR/worker.status" "$PR_STATE_DIR/worker.started"
fi

if [[ "$ROLE" == "frontend" ]] && (( AUTO_RESUME > 0 && PREFLIGHT_ONLY == 0 )); then
  if ! have_session_primitive; then
    if command -v setsid >/dev/null 2>&1; then
      log "auto-resume: disabled — this setsid does not support -f (fork/reparent) and perl is missing, so no detached session is possible; running the loop in this process (an external kill ends the review and nothing resumes it)"
    else
      log "auto-resume: disabled — neither setsid nor perl found for a detached session; running the loop in this process (an external kill ends the review and nothing resumes it)"
    fi
    AUTO_RESUME=0
  elif ! have_lock_primitive; then
    log "auto-resume: disabled — no flock or perl to hold the single-supervisor lock; running the loop in this process (an external kill ends the review and nothing resumes it)"
    AUTO_RESUME=0
  fi
fi

if [[ "$ROLE" == "frontend" ]] && (( AUTO_RESUME > 0 )) && (( PREFLIGHT_ONLY == 0 )); then
  SUP_LOG="$PR_STATE_DIR/supervisor.log"
  SUP_PID_FILE="$PR_STATE_DIR/supervisor.pid"
  mkdir -p "$PR_STATE_DIR"
  claim_state_marker "$PR_STATE_DIR"
  # Two supervisors on one PR would double-post. This check is the friendly
  # fast-fail; the authority is the supervisor's own lock, which closes the
  # window between this read and the spawn below.
  read_pid_record "$SUP_PID_FILE"
  if supervisor_is_live "$REC_PID" "$REC_TOKEN"; then
    die "a supervisor for this PR is already running (pid $REC_PID); stop it with --stop, or pass --no-auto-resume to run in this process"
  fi
  # A stop from an earlier run must not block this one. The pid file stays
  # put: a stale record blocks nothing (the token unmasks it), the new
  # supervisor overwrites it, and removing it here could erase the fresh
  # record of a supervisor another invocation just started.
  rm -f "$PR_STATE_DIR/stop"
  : >> "$SUP_LOG"
  # Tail from the end of what is already there, so a fresh invocation shows
  # its own output and not the whole history.
  SUP_LOG_OFFSET=$(wc -c < "$SUP_LOG" | tr -d ' ')

  if (( AUDIT == 1 )); then
    STOP_HINT="$0 --local --audit --dir $REPO_DIR --stop"
  elif [[ "$LOCAL_SCOPE" == "branch" ]]; then
    STOP_HINT="$0 --local --base $BASE_ARG --dir $REPO_DIR --stop"
  else
    STOP_HINT="$0 $PR_NUMBER --repo $REPO_SLUG"
    [[ "$FORGE" == "github" ]] || STOP_HINT="$STOP_HINT --forge $FORGE --host ${FORGE_SCHEME}://${FORGE_HOST}"
    STOP_HINT="$STOP_HINT --stop"
  fi
  SUP_PID=''
  TAIL_PID=''

  # Ctrl-C is a deliberate stop: leave the sentinel behind so the supervisor
  # cannot relaunch, and take the whole session down.
  frontend_interrupt() {
    : > "$PR_STATE_DIR/stop"
    if [[ -z "$SUP_PID" ]]; then
      read_pid_record "$SUP_PID_FILE"
      supervisor_is_live "$REC_PID" "$REC_TOKEN" && SUP_PID="$REC_PID"
    fi
    log "auto-resume: Ctrl-C — stopping supervisor pid ${SUP_PID:-unknown}; this run will not resume"
    if [[ -n "$SUP_PID" ]]; then
      signal_supervisor "$SUP_PID"
      local i
      for (( i = 0; i < 20; i++ )); do
        kill -0 "$SUP_PID" 2>/dev/null || break
        sleep 0.5
      done
    fi
    if [[ -n "$TAIL_PID" ]]; then kill "$TAIL_PID" 2>/dev/null || true; fi
    exit 130
  }
  # An external SIGTERM/SIGHUP ends this front-end only. The supervisor is in
  # another session and keeps the loop going — the failure this feature is
  # for.
  frontend_detach() {
    if [[ -z "$SUP_PID" ]]; then
      read_pid_record "$SUP_PID_FILE"
      supervisor_is_live "$REC_PID" "$REC_TOKEN" && SUP_PID="$REC_PID"
    fi
    log "auto-resume: front-end signalled; supervisor pid ${SUP_PID:-unknown} keeps running ($STOP_HINT to end it)"
    if [[ -n "$TAIL_PID" ]]; then kill "$TAIL_PID" 2>/dev/null || true; fi
    exit 143
  }
  # Armed before the supervisor is spawned: Ctrl-C in the first moments of a
  # run must stop it too. The sentinel is the handle until the pid file
  # exists — the supervisor reads it before each worker.
  trap frontend_interrupt INT
  trap frontend_detach TERM HUP

  spawn_detached bash "$0" --_supervise --auto-resume "$AUTO_RESUME" \
      ${WORKER_ARGV[@]+"${WORKER_ARGV[@]}"} >> "$SUP_LOG" 2>&1 </dev/null &

  # The supervisor writes its pid before its first log line and removes the
  # file when it exits, so a missing pid file means either "not up yet" or
  # "already finished". The log line settles which. A record that fails the
  # incarnation check is a leftover from an earlier run — keep waiting for
  # ours to overwrite it. A spawned supervisor that loses the lock race
  # logs "another supervisor" and exits; attach to the winner if its record
  # lands within the window, refuse otherwise.
  SUP_RAN=0
  SUP_CONFLICT=0
  for (( SUP_WAIT = 0; SUP_WAIT < 100; SUP_WAIT++ )); do
    if [[ -s "$SUP_PID_FILE" ]]; then
      read_pid_record "$SUP_PID_FILE"
      if supervisor_is_live "$REC_PID" "$REC_TOKEN"; then
        SUP_PID="$REC_PID"; SUP_RAN=1; break
      fi
    fi
    SUP_LOG_TAIL=$(tail -c "+$((SUP_LOG_OFFSET + 1))" "$SUP_LOG" 2>/dev/null) || SUP_LOG_TAIL=''
    if grep -q 'auto-resume: supervisor started' <<<"$SUP_LOG_TAIL"; then
      # The pid lands before that line, so read the file again: a live
      # supervisor has written it by now, and an empty file means the
      # supervisor already exited.
      [[ -s "$SUP_PID_FILE" ]] && SUP_PID=$(head -1 "$SUP_PID_FILE")
      SUP_RAN=1; break
    fi
    if grep -q 'auto-resume: another supervisor for this PR' <<<"$SUP_LOG_TAIL"; then
      SUP_CONFLICT=1
    fi
    sleep 0.1
  done
  if (( SUP_RAN == 0 && SUP_CONFLICT == 1 )); then
    die "this PR's supervisor.lock is still held — a supervisor is running (stop it with --stop), or a just-ended run's children are still winding down (retry shortly); --no-auto-resume runs the loop in this process"
  fi
  (( SUP_RAN == 1 )) || die "the auto-resume supervisor did not start — see $SUP_LOG"

  if [[ -n "$SUP_PID" ]]; then
    log "auto-resume: supervisor pid $SUP_PID, budget $AUTO_RESUME restart(s), log $SUP_LOG"
    log "auto-resume: stop it with Ctrl-C here, or: $STOP_HINT"
  fi

  # --pid ends the tail when this front-end dies, including a SIGKILL that
  # runs no trap. BSD tail has no such flag; there the traps above stop it.
  TAIL_ARGS=(-c "+$((SUP_LOG_OFFSET + 1))" -f)
  if tail --pid=$$ -c +1 /dev/null >/dev/null 2>&1; then
    TAIL_ARGS=("--pid=$$" "${TAIL_ARGS[@]}")
  fi
  tail "${TAIL_ARGS[@]}" "$SUP_LOG" >&2 &
  TAIL_PID=$!

  if [[ -n "$SUP_PID" ]]; then
    while kill -0 "$SUP_PID" 2>/dev/null; do sleep 1; done
  fi
  # Give the tail a moment to drain the supervisor's last lines.
  sleep 1
  kill "$TAIL_PID" 2>/dev/null || true
  wait "$TAIL_PID" 2>/dev/null || true

  FRONT_STATUS=''
  [[ -f "$PR_STATE_DIR/worker.status" ]] && FRONT_STATUS=$(head -1 "$PR_STATE_DIR/worker.status")
  log "auto-resume: supervisor exited; last worker status: ${FRONT_STATUS:-none}"
  case "$FRONT_STATUS" in
    approved|converged_no_major|review_posted) exit 0 ;;
    *)                                          exit 1 ;;
  esac
fi

if [[ "$ROLE" == "supervise" ]]; then
  mkdir -p "$PR_STATE_DIR"
  claim_state_marker "$PR_STATE_DIR"
  # One supervisor per PR, enforced by the kernel: the lock is taken before
  # anything else, held for this process's lifetime, and inherited by the
  # worker tree below (the fd rides into every child), so simultaneous
  # starts race the flock — exactly one wins — and a SIGKILLed supervisor's
  # surviving worker still holds it until that whole tree is gone. The
  # front-end reads the log lines below and reports the refusal. No lock
  # tool means no exclusion guarantee: refuse to supervise rather than run
  # unlocked (the front-end gates on this too; a direct --_supervise
  # invocation gets the same answer).
  if ! have_lock_primitive; then
    log "auto-resume: no flock or perl to hold the single-supervisor lock — refusing to supervise"
    exit 75
  fi
  exec 9>>"$PR_STATE_DIR/supervisor.lock"
  if ! acquire_lock_fd 9; then
    log "auto-resume: another supervisor for this PR is already running (supervisor.lock is held) — exiting"
    exit 75
  fi
  printf '%s\n%s\n' "$$" "$(proc_start_token "$$")" > "$PR_STATE_DIR/supervisor.pid"
  WORKER_PID=''
  # TERM the worker and everything below it. The turn scripts and the agent
  # CLIs they launch run in this process group, so signal the group with this
  # process deaf to it — signalling the worker's shell alone leaves an agent
  # editing, pushing, and commenting on its own. Without a session of our own
  # the group is the caller's and must not be signalled, so the worker takes
  # the signal alone there.
  kill_worker_tree() {
    local pgid
    pgid=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ') || pgid=''
    if [[ "$pgid" == "$$" ]]; then
      trap '' TERM
      kill -TERM -- "-$$" 2>/dev/null || true
      trap supervisor_signalled TERM
    elif [[ -n "$WORKER_PID" ]]; then
      kill -TERM "$WORKER_PID" 2>/dev/null || true
    fi
  }
  # Only the stop sentinel means the review should end: --stop and Ctrl-C
  # both write it before signalling. A TERM/HUP without it is exactly the
  # external noise this feature exists to survive — stay up, let the
  # interrupted wait resume, and relaunch the worker if the signal took it
  # down too.
  supervisor_signalled() {
    if [[ -e "$PR_STATE_DIR/stop" ]]; then
      log "auto-resume: supervisor signalled — stop requested; shutting down (worker pid ${WORKER_PID:-none})"
      kill_worker_tree
      rm -f "$PR_STATE_DIR/supervisor.pid" "$PR_STATE_DIR/worker.pid"
      exit 143
    fi
    log "auto-resume: supervisor signalled without a stop request — ignoring; the review continues (--stop or Ctrl-C ends it)"
  }
  trap supervisor_signalled TERM HUP

  log "auto-resume: supervisor started (pid $$, budget $AUTO_RESUME restart(s))"
  # Once a worker has applied this invocation's context intent (the
  # context.applied stamp: snapshot rendered, cleared, or reuse confirmed),
  # relaunches drop the context flags — the --context* inputs may name
  # temporary paths, and their content is persisted in context.md. Until
  # then relaunches replay the flags: a replacement that failed mid-render
  # must be retried (and fail loudly on a dead source), never quietly
  # papered over with the previous invocation's stored context. --restart
  # stays either way: its resume branch is half-step-aware, so replaying
  # it is safe.
  strip_context_worker_flags ${WORKER_ARGV[@]+"${WORKER_ARGV[@]}"}
  RETRY_ARGV=(${STRIPPED_ARGV[@]+"${STRIPPED_ARGV[@]}"})
  if (( ${#RETRY_ARGV[@]} != ${#WORKER_ARGV[@]} )); then
    log "auto-resume: relaunches reuse the stored context once a worker lands this invocation's snapshot (context flags dropped); until then they replay the context flags"
  fi
  # The iteration budget, convergence streak, and context stamp span
  # relaunches; only a new invocation grants a fresh count.
  rm -f "$PR_STATE_DIR/worker.progress" "$PR_STATE_DIR/context.applied"
  ATTEMPT=0
  QUICK=0          # consecutive short-lived workers; drives the backoff
  while :; do
    # A stop that arrived before this worker starts counts: the front-end
    # writes the sentinel on Ctrl-C, which can land while this supervisor is
    # still coming up.
    if [[ -e "$PR_STATE_DIR/stop" ]]; then
      log "auto-resume: stopping — stopped by request"
      break
    fi
    rm -f "$PR_STATE_DIR/worker.status" "$PR_STATE_DIR/worker.started"
    WORKER_AT=$(date +%s)
    if (( ATTEMPT == 0 )) || [[ ! -e "$PR_STATE_DIR/context.applied" ]]; then
      bash "$0" --_worker ${WORKER_ARGV[@]+"${WORKER_ARGV[@]}"} &
    else
      bash "$0" --_worker ${RETRY_ARGV[@]+"${RETRY_ARGV[@]}"} &
    fi
    WORKER_PID=$!
    # Recorded with its start token so --stop can still reach the worker
    # tree after a SIGKILL takes this supervisor down (the worker never
    # reads the stop sentinel itself).
    printf '%s\n%s\n' "$WORKER_PID" "$(proc_start_token "$WORKER_PID")" \
      > "$PR_STATE_DIR/worker.pid"
    WORKER_RC=0
    # A trapped signal interrupts wait with 128+sig while the worker may
    # still be running (the ignored sentinel-less TERM above); only a
    # reaped worker ends this loop. When the worker vanished during the
    # interruption itself, the 128+sig may be trap noise rather than the
    # worker's status — ask the job table once more and keep the stored
    # status (127 = already collected: the first value was real).
    while :; do
      if wait "$WORKER_PID"; then WORKER_RC=0; else WORKER_RC=$?; fi
      if kill -0 "$WORKER_PID" 2>/dev/null; then continue; fi
      if (( WORKER_RC > 128 )); then
        if wait "$WORKER_PID" 2>/dev/null; then WORKER_RC=0
        else WORKER_RC2=$?; (( WORKER_RC2 == 127 )) || WORKER_RC="$WORKER_RC2"; fi
      fi
      break
    done
    # The worker's shell is gone; anything it started goes with it, or a
    # relaunch would put a second agent on the same checkout and PR.
    kill_worker_tree
    WORKER_PID=''
    rm -f "$PR_STATE_DIR/worker.pid"
    RAN_SECS=$(( $(date +%s) - WORKER_AT ))

    DECISION=$(auto_resume_decision "$PR_STATE_DIR")
    ACTION="${DECISION%% *}"
    REASON="${DECISION#* }"
    if [[ "$ACTION" == "stop" ]]; then
      log "auto-resume: stopping — $REASON (worker exit $WORKER_RC after ${RAN_SECS}s)"
      break
    fi
    if (( ATTEMPT >= AUTO_RESUME )); then
      log "auto-resume: stopping — budget exhausted after $ATTEMPT restart(s); last: $REASON"
      break
    fi
    ATTEMPT=$(( ATTEMPT + 1 ))
    # A worker that ran a long time before dying is not a crash loop, so its
    # restart waits the floor again.
    if (( RAN_SECS > AUTO_RESUME_LONG_RUN )); then QUICK=0; fi
    BACKOFF=$(auto_resume_backoff "$QUICK")
    QUICK=$(( QUICK + 1 ))
    log "auto-resume: restart $ATTEMPT/$AUTO_RESUME in ${BACKOFF}s — $REASON (worker exit $WORKER_RC after ${RAN_SECS}s)"
    # Guarded: a group-wide sentinel-less TERM kills this sleep with 143
    # after the trap above returns, and an unguarded nonzero here would
    # end the supervisor through set -e — the very signal being ignored.
    sleep "$BACKOFF" || true
  done

  rm -f "$PR_STATE_DIR/supervisor.pid" "$PR_STATE_DIR/worker.pid"
  SUP_STATUS=''
  [[ -f "$PR_STATE_DIR/worker.status" ]] && SUP_STATUS=$(head -1 "$PR_STATE_DIR/worker.status")
  case "$SUP_STATUS" in
    approved|converged_no_major|review_posted) exit 0 ;;
    *)                                          exit 1 ;;
  esac
fi

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

export FORGE FORGE_HOST FORGE_SCHEME REPO_SLUG \
       REPO_OWNER REPO_NAME PR_NUMBER REPO_DIR MAX_ITER LOOP_HOME REVIEW_ONLY \
       LOCAL_MODE LOCAL_SCOPE NO_PUSH MANAGED_CLONE REPO_DIR_CANON AUDIT \
       CLAUDE_MODEL CLAUDE_EFFORT CLAUDE_PERMS CODEX_MODEL CODEX_EFFORT CODEX_TIER

preflight
# --preflight-only stops before any side effect: no clone, no state dir, no
# comment. It still needs branch discovery below for the open check and the
# canonical URL, so only the clone is skipped here.
if (( PREFLIGHT_ONLY == 0 )) && [[ "$LOCAL_SCOPE" != "branch" ]]; then
  ensure_repo_clone
fi

# --- discover branches --------------------------------------------------------

case "$FORGE" in
  local)
    # No PR/MR: the branch under review is the one the checkout had out when
    # this run started (resolved with the checkout, above, because the state
    # path is keyed by it), and the base is whatever --base resolves to in
    # this checkout.
    BASE_REF="$BASE_ARG"
    LOCAL_BASE_SHA=$(git -C "$REPO_DIR" rev-parse --verify --quiet --end-of-options "${BASE_ARG}^{commit}") \
      || die "--base '$BASE_ARG' does not resolve to a commit in $REPO_DIR"
    # local_setup_repo pins refs/ai-pr-loop/base to it — the base both agents
    # diff against, fixed for the whole review.
    export LOCAL_BASE_SHA
    git -C "$REPO_DIR" merge-base "$LOCAL_BASE_SHA" HEAD >/dev/null 2>&1 \
      || die "--base '$BASE_ARG' ($LOCAL_BASE_SHA) shares no history with the branch under review"
    PR_URL="local branch review: $HEAD_REF in $REPO_DIR"
    ;;
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

# --preflight-only: report what a real run would use — the API/comment
# identity (resolved from the actual credential via /user or gh; pushes
# use the checkout's own git credential, which may differ), the canonical
# PR/MR URL, and the branches — then stop. Reaching this line already
# proves authority validation, credential resolution, and the open check
# all passed; any failure died above with its specific message.
if (( PREFLIGHT_ONLY == 1 )); then
  printf 'identity: %s\n' "${GH_USER:-(none — local branch review, no forge credential)}"
  printf 'pr: %s\n' "$PR_URL"
  printf 'branches: %s <- %s\n' "$BASE_REF" "$HEAD_REF"
  exit 0
fi

ensure_state_dir
export STATE_DIR
# audit-pr-base is written by audit_setup_branch, before the branch is even
# checked out — it has to survive the role handoff. Assert the dir it landed
# in is the one this run resolved: they are derived from the same branch
# name, so a mismatch means the two derivations disagree.
if (( AUDIT == 1 )) && [[ -n "$AUDIT_PR_BASE" ]]; then
  [[ "$(read_receipted "$STATE_DIR/local/audit-pr-base" 2>/dev/null)" == "$AUDIT_PR_BASE" ]] \
    || die "internal: the audit's PR base is not recorded at $STATE_DIR/local/audit-pr-base"
fi
RUN_LOG="$STATE_DIR/run.log"
: > "$RUN_LOG"

# The run is well-formed: flags, forge resolution, preflight, and the open
# check all passed. A worker that dies past this point was killed or crashed,
# and the supervisor relaunches it; one that dies before it is a config or
# preflight error, which relaunching cannot fix.
if [[ "$ROLE" == "worker" ]]; then
  touch "$STATE_DIR/worker.started"
fi

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
  } > "$CONTEXT_FILE.tmp"
  # Land the snapshot whole or not at all: a source read failing mid-render
  # exits this run (set -e) with only the .tmp written, so a relaunch never
  # reuses a truncated context.md as the trusted material.
  mv -f "$CONTEXT_FILE.tmp" "$CONTEXT_FILE"
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
# The invocation's context intent is applied — rendered, cleared, or reuse
# confirmed. From here the supervisor may drop the context flags from
# relaunches; a worker dying before this point is retried with them.
if [[ "$ROLE" == "worker" ]]; then
  : > "$STATE_DIR/context.applied"
fi

log "------------------------------------------------------------"
log "AI PR loop starting"
log "  PR:    $PR_URL"
if (( AUDIT == 1 )); then
  log "  forge: none during the review; the closing step opens the PR/MR"
  log "  scope: the whole worktree at HEAD"
  log "  branch: $HEAD_REF (created by this run)"
  log "  pr base: $AUDIT_PR_BASE (not written by this run)"
elif [[ "$LOCAL_SCOPE" == "branch" ]]; then
  log "  forge: none (local branch review)"
else
  log "  forge: $FORGE ($FORGE_SCHEME://$FORGE_HOST)"
fi
log "  base:  $BASE_REF"
log "  head:  $HEAD_REF"
log "  dir:   $REPO_DIR"
log "  max:   $MAX_ITER iterations (this invocation)"
log "  mode:  $( (( REVIEW_ONLY == 1 )) && echo 'review-only (codex only, no claude)' || echo 'review + implement' )"
if (( LOCAL_MODE == 1 )); then
  log "  local: review exchanged on disk; local rounds squash into one commit$( (( NO_PUSH == 1 )) && echo ' (--no-push: not pushed)' )"
fi
log "  ctx:   $( (( HAS_CONTEXT == 1 )) && echo "$CONTEXT_FILE" || echo 'none' )"
log "  claude: model=$CLAUDE_MODEL effort=$CLAUDE_EFFORT perms=$CLAUDE_PERMS"
log "  codex:  model=$CODEX_MODEL effort=$CODEX_EFFORT tier=$CODEX_TIER"
log "  state: $STATE_DIR"
log "------------------------------------------------------------"

# Position the local checkout for the first turn. Forge mode: the EXACT PR
# head (fail-closed; handles option-like/ambiguous branch names and
# force-rewound remotes) — see sync_repo_to_pr_head in lib/common.sh. Local
# mode: the same on a fresh run, but a resumed one restores its own local
# rounds instead, since those commits exist nowhere else.
# Squash the local rounds into one commit and push it. Runs only when the
# review ended in agreement; rc 3 means there was nothing to squash.
FINALIZE_RC=0
run_finalize() {
  set +e
  bash "$LOOP_HOME/finalize_turn.sh"
  FINALIZE_RC=$?
  set -e
  case "$FINALIZE_RC" in
    0) : ;;
    3) log "finalize: no local commits to squash — nothing to push" ;;
    *) log "finalize failed (rc=$FINALIZE_RC) — the local rounds are still in $REPO_DIR" ;;
  esac
}

# --restart in local mode is a durable decision, not a per-invocation flag.
# A restart consumes several markers and establishes a new base — a kill
# partway would otherwise let a plain retry resurrect the superseded review
# or exit "already completed" without the new review. So a pending-restart
# marker is written FIRST, before anything is consumed, and every startup
# treats its presence as a standing --restart until the new base is set
# (cleared below). The iteration floor is published right after it.
EFFECTIVE_RESTART=$RESTART
if (( LOCAL_MODE == 1 )) && [[ -e "$(local_restart_pending_file)" ]]; then
  EFFECTIVE_RESTART=1
  (( RESTART == 1 )) \
    || log "local: a prior --restart was interrupted — resuming it; clean $(local_state_dir) to abandon it"
fi
if (( LOCAL_MODE == 1 )) && (( EFFECTIVE_RESTART == 1 )); then
  mkdir -p "$(local_state_dir)"    # a fresh target has no local/ yet
  : > "$(local_restart_pending_file)"    # durable intent, before any consume
  _fc=$(latest_local_iter codex); _fl=$(latest_local_iter claude)
  write_state_atomic "$(local_iter_floor_file)" "$(( _fc > _fl ? _fc : _fl ))" \
    || die "could not record the --restart iteration floor at $(local_iter_floor_file)"
fi

# Iterations at or below the floor belong to a review that a --restart
# superseded; every consumer below — the held-finalize shortcut and resume
# detection — reads them as absent. A floor file that exists but does not
# hold a number is a torn write from a killed run: reading it as 0 would
# silently resurrect the superseded review, so it fails closed.
ITER_FLOOR=0
if (( LOCAL_MODE == 1 )) && [[ -e "$(local_iter_floor_file)" ]]; then
  ITER_FLOOR=$(<"$(local_iter_floor_file)")
  [[ "$ITER_FLOOR" =~ ^[0-9]+$ ]] \
    || die "the --restart iteration floor at $(local_iter_floor_file) is empty or malformed (a killed run left it torn). Re-run with --restart to record it again and review the current state from scratch, or write the last superseded iteration number into it by hand — deleting the file resurrects the superseded review"
fi

# A completed local review is terminal: its single commit was already
# pushed, or landed as the local tip when there is no origin. A plain rerun
# has nothing left to do — exiting here also keeps a human commit made
# after completion from being mistaken for review state. --restart drops
# the marker and reviews the target as it is now, from a new base.
if (( LOCAL_MODE == 1 )) && [[ -s "$(local_completed_file)" ]]; then
  COMPLETED_SHA=$(<"$(local_completed_file)")
  # completed.sha is authoritative: in-progress markers found alongside it
  # are leftovers of an interrupted terminal transition, and resuming from
  # them would re-squash from the old base — rewriting the completed
  # commit. Drop them whenever the marker is present.
  rm -f "$(local_base_file)" "$(local_tip_file)" "$(local_origin_file)" \
        "$(local_finalized_file)" "$(local_finalize_inprogress_file)" \
        "$(local_pending_turn_file)"
  if (( EFFECTIVE_RESTART == 0 )); then
    log "local: this review already completed (commit $COMPLETED_SHA) — pass --restart to start a new review of the current state"
    log "PR: $PR_URL"
    exit 0
  fi
  log "--restart: prior local review completed at $COMPLETED_SHA — starting a new review from the current head"
  rm -f "$(local_completed_file)"
fi

# A round that committed and wrote its response but was killed before its
# commit was anchored: recover it from the checkout's raw HEAD BEFORE
# local_setup_repo cleans the worktree back to the (stale) tip ref and
# resume detection counts the round as complete.
if (( LOCAL_MODE == 1 )) && [[ -e "$(local_pending_turn_file)" ]]; then
  reconcile_pending_turn
fi

if (( LOCAL_MODE == 1 )); then
  local_setup_repo
else
  sync_repo_to_pr_head
fi

# Is the held squash already the remote branch head — i.e. did the push
# land and only the terminal bookkeeping get interrupted?
#   0 landed   1 definitely not landed   2 could not tell
# Only a SQUASH outcome can land: a metadata-only hold's SHA is the base,
# which equals the remote head by construction and would otherwise read as
# "landed" for a review that pushed nothing.
finalized_landed() {  # <finalized-sha>
  local out remote_head
  [[ "$(local_finalized_kind)" == "squash" ]] || return 1
  # local_setup_repo already fetched and vouched for this exact state.
  [[ "${LOCAL_FINALIZE_LANDED:-0}" == "1" ]] && return 0
  git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1 || return 1
  # A failed ls-remote is "unknown" (rc 2); a successful one with no ref
  # is a definite answer — the branch is simply not there. The `||` keeps
  # the caller's errexit state intact either way.
  out=$(git -C "$REPO_DIR" ls-remote origin "refs/heads/$HEAD_REF" 2>/dev/null) \
    || return 2
  remote_head=$(awk '{print $1; exit}' <<<"$out")
  [[ -n "$remote_head" && "$remote_head" == "$1" ]]
}

# A finalized squash that already reached the remote is LANDED work: no
# flavor of restart or supersession may consume it. Complete it first —
# idempotent (the compose is reused, the re-push is a no-op) — and only
# then let --restart begin its new review, from the landed head.
LANDED_RC=1
HELD_SUPERSEDED=0
if (( LOCAL_MODE == 1 )) && [[ -n "$(local_finalized_sha)" ]] \
   && [[ "$(local_finalized_sha)" == "$(git -C "$REPO_DIR" rev-parse HEAD)" ]]; then
  set +e; finalized_landed "$(local_finalized_sha)"; LANDED_RC=$?; set -e
  # The held outcome is discarded either by --restart now, or by the
  # supersession drop below when a prior --restart's floor covers every
  # round it came from.
  (( $(latest_local_iter codex) <= ITER_FLOOR )) && HELD_SUPERSEDED=1
  # Never discard an outcome that MIGHT already be on the remote.
  (( LANDED_RC == 2 )) && (( EFFECTIVE_RESTART == 1 || HELD_SUPERSEDED == 1 )) \
    && die "could not read the remote head for '$HEAD_REF', so whether this review's squashed commit already landed is unknown — refusing to discard it. Re-run when the remote is reachable"
  if (( LANDED_RC == 0 )); then
    log "local: the squashed commit already reached the remote — completing the interrupted finalization"
    run_finalize
    (( FINALIZE_RC == 0 || FINALIZE_RC == 3 )) || exit 1
    if (( EFFECTIVE_RESTART == 0 && HELD_SUPERSEDED == 0 )); then
      log "PR: $PR_URL"
      exit 0
    fi
    # rc alone does not prove terminal completion (--no-push returns 0 with
    # the outcome still held). The marker does, and until it exists nothing
    # may consume the landed squash.
    [[ -s "$(local_completed_file)" ]] \
      || die "the landed finalization did not complete (its terminal marker was not written; --no-push holds it) — re-run without --no-push to finish it before starting a new review"
    log "local: the landed review is complete — starting a new review from its head"
    rm -f "$(local_completed_file)"
    local_setup_repo
  fi
fi

# A finalize outcome from an earlier invocation that never landed — a
# rejected push, a --no-push hold of the squash or of a metadata-only
# finish — is finished work. Land it (finalize reuses the composed message
# or held proposal) rather than stacking more review rounds on top of a
# review that already ended. --restart instead CONSUMES the marker: the
# fresh review stacks new rounds on the held state and later re-squashes
# everything to the same base, so it stops being finished work.
if (( LOCAL_MODE == 1 )); then
  if (( EFFECTIVE_RESTART == 1 )); then
    rm -f "$(local_finalized_file)" "$(local_finalize_inprogress_file)"
  elif [[ -n "$(local_finalized_sha)" ]] \
     && [[ "$(local_finalized_sha)" == "$(git -C "$REPO_DIR" rev-parse HEAD)" ]]; then
    if (( HELD_SUPERSEDED == 1 )); then
      # Every completed round sits at or below the floor: the held outcome
      # belongs to a review a --restart superseded, and the restart was
      # interrupted before consuming it. Consume it now — landing it would
      # silently drop the requested restart. Nothing landed: a squash on
      # the remote was completed above, and an unreadable remote died
      # there rather than reach this drop.
      log "local: dropping a held outcome superseded by --restart"
      rm -f "$(local_finalized_file)" "$(local_finalize_inprogress_file)"
    else
      log "local: this review already produced its finalize outcome — landing it instead of reviewing again"
      run_finalize
      (( FINALIZE_RC == 0 || FINALIZE_RC == 3 )) || exit 1
      log "PR: $PR_URL"
      exit 0
    fi
  fi
fi

# The restart's superseding work is done — the floor is set, the old
# terminal/held outcome is consumed, and local_setup_repo established the
# base the new review builds on. Clear the durable intent so a later plain
# rerun resumes the NEW review instead of re-driving the restart.
if (( LOCAL_MODE == 1 )) && (( EFFECTIVE_RESTART == 1 )); then
  rm -f "$(local_restart_pending_file)"
fi

# --- resume detection ---------------------------------------------------------
#
# Look at what each agent has already completed and figure out where to
# resume. Forge mode reads the PR's AI comments; local mode reads the review
# files under the state dir. Either way:
#
#   last_codex == 0 && last_claude == 0  → fresh start, ITER=1, codex first.
#   last_codex == last_claude (= K)      → both did iter K, next round is K+1.
#   last_codex >  last_claude            → codex posted iter K but claude didn't
#                                           respond (prior run died or hit max
#                                           between turns) → run claude at K
#                                           first, then continue from K+1.
#
# `--max` counts iterations *this invocation*, not total. Re-run to grant more.

if (( LOCAL_MODE == 1 )); then
  LAST_CODEX=$(latest_local_iter codex)
  LAST_CLAUDE=$(latest_local_iter claude)
  (( LAST_CODEX  > ITER_FLOOR )) || LAST_CODEX=$ITER_FLOOR
  (( LAST_CLAUDE > ITER_FLOOR )) || LAST_CLAUDE=$ITER_FLOOR
else
  # || die: a failed thread read must name itself — resuming at iter 1 on
  # a partial answer would double-post, and a bare set -e abort leaves no
  # ERROR line for the operator or the log monitor.
  LAST_CODEX=$(latest_ai_comment_iter codex) \
    || die "could not read the AI thread for resume detection"
  LAST_CLAUDE=$(latest_ai_comment_iter claude) \
    || die "could not read the AI thread for resume detection"
fi
LAST_CODEX="${LAST_CODEX:-0}"
LAST_CLAUDE="${LAST_CLAUDE:-0}"

# A codex run can crash after its summary POSTs but before the thread read
# that gates canonical persistence succeeds — its stdout record survives as
# provisional *.stdout files. The fetch above just confirmed which summaries
# are public: adopt the provisional counts/verdict for the landed iteration
# when the canonical files are missing, so convergence accounting and the
# verdict-aware resume see what the PR already shows. Provisional files of
# an iteration whose summary never landed are never adopted.
adopt_landed_codex_artifacts() {
  local it="$1" d
  (( it > 0 )) || return 0
  d="$STATE_DIR/$(printf 'iter-%02d' "$it")"
  # Copy-then-rename: a kill mid-adoption must not leave a truncated
  # canonical file that would block a later retry of the same adoption.
  if [[ ! -f "$d/issue_counts" && -f "$d/issue_counts.stdout" ]]; then
    cp "$d/issue_counts.stdout" "$d/issue_counts.tmp.$$"
    mv -f "$d/issue_counts.tmp.$$" "$d/issue_counts"
    log "resume: adopted stdout issue counts for landed codex iter $it"
  fi
  if [[ ! -f "$d/verdict" && -f "$d/verdict.stdout" ]]; then
    cp "$d/verdict.stdout" "$d/verdict.tmp.$$"
    mv -f "$d/verdict.tmp.$$" "$d/verdict"
    log "resume: adopted stdout verdict for landed codex iter $it"
  fi
}
adopt_landed_codex_artifacts "$LAST_CODEX"

RESUME_CLAUDE_FIRST=0
if (( RESTART == 1 )) && (( LAST_CODEX > 0 || LAST_CLAUDE > 0 )); then
  # --restart exists to get past a prior APPROVED verdict; it must not skip
  # work the thread still owes. A pending half-step — codex posted a
  # non-APPROVED review and claude did not reply, e.g. the restarted round
  # died mid-way and this is the relaunch — resumes as usual; only a
  # completed round bumps to a fresh one. The verdict check matters: the
  # natural post-approval state has the same codex>claude count shape
  # (claude never answers an approval), and --restart there means a new
  # round, not a claude reply to the approval. That makes the flag safe to
  # replay on auto-resume relaunches, and a relaunch that finds no new
  # posts still gets the forced round instead of the "already APPROVED —
  # nothing to do" exit.
  RESTART_VERDICT_FILE="$STATE_DIR/$(printf 'iter-%02d' "$LAST_CODEX")/verdict"
  RESTART_APPROVED=0
  [[ -f "$RESTART_VERDICT_FILE" && "$(cat "$RESTART_VERDICT_FILE")" == "APPROVED" ]] \
    && RESTART_APPROVED=1
  if (( LAST_CODEX > LAST_CLAUDE && REVIEW_ONLY == 0 && RESTART_APPROVED == 0 )); then
    ITER="$LAST_CODEX"
    RESUME_CLAUDE_FIRST=1
    log "--restart: codex iter=$LAST_CODEX awaits a claude reply — running the half-step first"
  else
    # An approval at or past the invocation's baseline landed during THIS
    # invocation: the forced round already ran and codex approved it. The
    # replayed --restart of a relaunch must end as approved, not force yet
    # another round on the approval it just earned. (BASE exists only on
    # relaunches; a first worker — where the approval predates the
    # invocation — bumps as requested.)
    RESTART_BASE=''
    [[ "$ROLE" == "worker" && -f "$STATE_DIR/worker.progress" ]] \
      && RESTART_BASE=$(awk -F= '/^BASE=/{print $2}' "$STATE_DIR/worker.progress")
    if (( RESTART_APPROVED == 1 )) && [[ "$RESTART_BASE" =~ ^[0-9]+$ ]] \
       && (( LAST_CODEX >= RESTART_BASE )); then
      log "--restart: the forced round already ran — codex APPROVED at iter $LAST_CODEX; nothing to do"
      log "PR: $PR_URL"
      write_worker_status approved
      exit 0
    fi
    HIGH=$(( LAST_CODEX > LAST_CLAUDE ? LAST_CODEX : LAST_CLAUDE ))
    ITER=$(( HIGH + 1 ))
    log "--restart: bypassing prior APPROVED state — starting fresh at iter $ITER (codex first)"
  fi
elif (( LAST_CODEX == 0 && LAST_CLAUDE == 0 )); then
  ITER=1
  log "no prior AI round on this target — starting fresh at iter 1"
elif (( LAST_CODEX > LAST_CLAUDE )); then
  # Half-step: codex reviewed but claude hasn't replied. Check on-disk verdict
  # to avoid running claude on top of an APPROVED review.
  PRIOR_VERDICT_FILE="$STATE_DIR/$(printf 'iter-%02d' "$LAST_CODEX")/verdict"
  if [[ -f "$PRIOR_VERDICT_FILE" && "$(cat "$PRIOR_VERDICT_FILE")" == "APPROVED" ]]; then
    log "codex already APPROVED at iter $LAST_CODEX — nothing to do"
    # Local mode: the review is over but its single commit may still be
    # unpushed — a rejected push, or a --no-push run being re-run to push.
    # finalize_turn.sh reuses the composed message when the squash already
    # exists, so this is a push retry, not another agent turn.
    if (( LOCAL_MODE == 1 )); then
      run_finalize
      (( FINALIZE_RC == 0 || FINALIZE_RC == 3 )) || exit 1
    fi
    log "PR: $PR_URL"
    write_worker_status approved
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
STREAK_AT=0         # last iteration the streak accounted
RUNS_BASE_ITER="$ITER"

# A relaunched worker continues the invocation's budget. The supervisor
# clears this file before its first worker, so values here are what this
# invocation's earlier workers already spent. RUNS alone can trail the
# public thread — a claude summary that landed right before the worker
# failed was never counted — so reconcile against the resume point: every
# iteration between the invocation's baseline and where this worker starts
# completed publicly and is spent budget.
if [[ "$ROLE" == "worker" && -f "$STATE_DIR/worker.progress" ]]; then
  RUNS=$(awk -F= '/^RUNS=/{print $2}' "$STATE_DIR/worker.progress")
  CONVERGE_STREAK=$(awk -F= '/^STREAK=/{print $2}' "$STATE_DIR/worker.progress")
  STREAK_AT=$(awk -F= '/^STREAK_AT=/{print $2}' "$STATE_DIR/worker.progress")
  RUNS_BASE_ITER=$(awk -F= '/^BASE=/{print $2}' "$STATE_DIR/worker.progress")
  [[ "$RUNS" =~ ^[0-9]+$ ]] || RUNS=0
  [[ "$CONVERGE_STREAK" =~ ^[0-9]+$ ]] || CONVERGE_STREAK=0
  [[ "$STREAK_AT" =~ ^[0-9]+$ ]] || STREAK_AT=0
  [[ "$RUNS_BASE_ITER" =~ ^[0-9]+$ ]] || RUNS_BASE_ITER="$ITER"
  LANDED=$(( ITER - RUNS_BASE_ITER ))
  if (( LANDED > RUNS )); then
    log "auto-resume: the PR thread shows $LANDED iteration(s) completed this invocation (persisted count $RUNS) — reconciling the budget"
    RUNS="$LANDED"
  fi
  if (( RUNS > 0 || CONVERGE_STREAK > 0 )); then
    log "auto-resume: this invocation already ran $RUNS of $MAX_ITER iteration(s) (converge streak $CONVERGE_STREAK) — continuing on the remaining budget"
  fi
  # A streak at the threshold means the run converged and was killed in
  # the moment between persisting the streak and writing its status. The
  # outcome already happened; report it instead of running more turns on
  # a converged review.
  if (( CONVERGE_N > 0 && CONVERGE_STREAK >= CONVERGE_N )); then
    log "convergence: restored streak $CONVERGE_STREAK already meets $CONVERGE_N — the run converged before this relaunch; nothing to do"
    write_worker_status converged_no_major
    exit 0
  fi
elif [[ "$ROLE" == "worker" ]]; then
  # First worker of the invocation: record the baseline immediately, so a
  # relaunch can reconcile even when no counter was ever incremented.
  persist_worker_progress
fi

while (( RUNS < MAX_ITER )); do
  export ITER
  log ""
  log "===== Iteration $ITER (run $((RUNS + 1)) / $MAX_ITER this invocation) ====="

  if (( RESUME_CLAUDE_FIRST == 1 )); then
    log "skipping codex turn — codex already posted at iter $ITER in a prior run"
    RESUME_CLAUDE_FIRST=0
    # The skipped turn's review is landed and counts: reconcile the streak
    # from its persisted issue_counts so a qualifying review posted right
    # before a crash is not lost from convergence (STREAK_AT keeps replays
    # of the same landed review from counting twice).
    if update_converge_streak "$ITER"; then
      FINAL_STATUS="converged_no_major"
      break
    fi
  else
    # Codex review.
    set +e
    audit_target_snapshot
    bash "$LOOP_HOME/codex_turn.sh"
    CODEX_RC=$?
    set -e
    audit_target_verify "the codex review turn"

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
    if update_converge_streak "$ITER"; then
      FINAL_STATUS="converged_no_major"
      break
    fi

    # Drop whatever the review turn left in the worktree. Forge mode also
    # re-syncs to the PR head in case anything landed remotely between turns;
    # local mode keeps its own rounds, which exist nowhere else.
    if (( LOCAL_MODE == 1 )); then
      sync_repo_to_local_head
    else
      sync_repo_to_pr_head
    fi
  fi

  # Claude response.
  # Two-phase receipt for the anchor window. `pending` before the turn
  # marks a round whose outcome is not yet validated: a kill here re-runs
  # it, never anchors it. Only after the turn returns rc 0 — which
  # claude_turn.sh grants only with the marker AND its response artifact —
  # is the receipt upgraded to `done` with the EXACT committed SHA, so
  # recovery anchors that precise commit and nothing else.
  _pretip=''
  if (( LOCAL_MODE == 1 )); then
    _pretip=$(git -C "$REPO_DIR" rev-parse HEAD)
    write_state_atomic "$(local_pending_turn_file)" "pending $ITER $_pretip"
  fi
  set +e
  audit_target_snapshot
  bash "$LOOP_HOME/claude_turn.sh"
  CLAUDE_RC=$?
  set -e
  audit_target_verify "the claude implementer turn"

  if [[ $CLAUDE_RC -ne 0 ]]; then
    log "claude turn failed on iter $ITER (rc=$CLAUDE_RC)"
    # A failed turn is re-run in full next invocation, so any commits it
    # left are abandoned work. PR scope drops them by syncing to the tip
    # ref; the branch must be put back the same way, or the next resume
    # reads them as the branch moving outside the loop and fails closed.
    # (A turn that detached HEAD is left for that fail-closed check.)
    if (( LOCAL_MODE == 1 )); then
      # The response artifact answers for the commits dropped below:
      # keeping it would advance latest_local_iter past this round, and
      # the discarded fix would never rerun. Removed BEFORE the pending
      # receipt — a kill between the two must leave the receipt (whose
      # reconcile path re-runs the round), never a bare response that
      # resume would count as the round completing. The round report the
      # turn already emitted stays — it is the operator's record.
      if [[ -e "$(local_artifact_path claude "$ITER")" ]]; then
        rm -f "$(local_artifact_path claude "$ITER")"
        log "claude: iter $ITER response discarded with the rolled-back round — resume reruns this iteration"
      fi
      rm -f "$(local_pending_turn_file)"    # the round is being re-run, not anchored
      if [[ -s "$(local_tip_file)" ]]; then
        if [[ "$LOCAL_SCOPE" != "branch" ]]; then
          sync_repo_to_local_head
        elif [[ "$(git -C "$REPO_DIR" symbolic-ref --quiet HEAD 2>/dev/null)" == "refs/heads/$HEAD_REF" ]]; then
          force_clean_to_commit "$REPO_DIR" "$(<"$(local_tip_file)")" attach
        fi
      fi
    fi
    FINAL_STATUS="claude_error"
    break
  fi

  if (( LOCAL_MODE == 1 )); then
    # The turn is validated: record the exact commit it produced, then
    # anchor it. A kill between the two leaves a `done` receipt naming that
    # commit, which recovery re-points the tip at. Drop the receipt last.
    write_state_atomic "$(local_pending_turn_file)" \
      "done $ITER $_pretip $(git -C "$REPO_DIR" rev-parse HEAD)"
    local_record_tip
    rm -f "$(local_pending_turn_file)"
  fi

  # The round is complete once claude answered: persist the spent iteration
  # before the sync below, whose network fetch can kill the worker — a
  # relaunch must not be granted this iteration again.
  ITER=$((ITER + 1))
  RUNS=$((RUNS + 1))
  persist_worker_progress

  if (( LOCAL_MODE == 1 )); then
    # Local rounds are never pushed: clean the worktree back to the round the
    # turn just anchored, keeping every commit the review has produced.
    sync_repo_to_local_head
  else
    # Re-sync — Claude pushed; the local checkout must track the new PR head.
    sync_repo_to_pr_head
  fi
done

# The review ended in agreement: collapse every local round into the single
# commit that gets pushed.
if (( LOCAL_MODE == 1 )) && [[ "$FINAL_STATUS" == "approved" || "$FINAL_STATUS" == "converged_no_major" ]]; then
  run_finalize
  (( FINALIZE_RC == 0 || FINALIZE_RC == 3 )) || FINAL_STATUS="finalize_error"
fi

if [[ "$FINAL_STATUS" == "unknown" ]]; then
  FINAL_STATUS="max_iterations_reached"
fi

log ""
log "============================================================"
log "AI PR loop finished: $FINAL_STATUS"
log "  ran $RUNS iteration(s) this invocation; last iter attempted = $ITER"
if [[ "$FINAL_STATUS" == "max_iterations_reached" ]]; then
  log "  re-run the same command to grant another $MAX_ITER iterations"
  if (( LOCAL_MODE == 1 )); then
    log "  local rounds so far are committed in $REPO_DIR and unpushed; the next run continues them"
  fi
fi
log "  PR:    $PR_URL"
log "  Logs:  $STATE_DIR"
log "============================================================"

write_worker_status "$FINAL_STATUS"

case "$FINAL_STATUS" in
  approved|converged_no_major|review_posted) exit 0 ;;
  *)                                          exit 1 ;;
esac
