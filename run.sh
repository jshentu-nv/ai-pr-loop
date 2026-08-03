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
# Auto-resume: a supervisor in its own session restarts the loop when a run
# dies without finishing, so an external kill does not end the review. On by
# default; see --auto-resume / --no-auto-resume / --stop.
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
#                      [--auto-resume N] [--no-auto-resume] [--stop]
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
#                 relaunched. The supervisor logs to
#                 state/<ident>/pr-<N>/supervisor.log; this command tails
#                 that log, so foreground output is the same as an inline
#                 run. --print-config and --preflight-only always run
#                 inline.
#   --no-auto-resume
#                 Run the loop in this process. Nothing restarts it.
#   --stop        Write the stop sentinel for this PR and signal its
#                 supervisor, then exit. Runs no preflight and clones
#                 nothing. Ctrl-C on the foreground command does the same.
#
# Context flags persist per-PR: re-running without them reuses the prior
# context.md, so you only pass them once. Pass any --context* flag to replace
# the stored context, or --clear-context to drop it.
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
if [[ -z "$REPO_DIR" ]]; then
  REPO_DIR="$LOOP_HOME/checkouts/$(repo_ident_name)"
fi

# --print-config: report the resolved knobs and exit before any forge access.
# Lets tests (and humans) observe adaptive-default and URL/forge/scheme/dir
# resolution directly.
if (( PRINT_CONFIG == 1 )); then
  printf 'forge: %s host=%s scheme=%s repo=%s pr=%s\n' "$FORGE" "$FORGE_HOST" "$FORGE_SCHEME" "$REPO_SLUG" "${PR_NUMBER:--}"
  printf 'dir: %s\n' "$REPO_DIR"
  printf 'claude: model=%s effort=%s perms=%s\n' "$CLAUDE_MODEL" "$CLAUDE_EFFORT" "$CLAUDE_PERMS"
  printf 'codex: model=%s effort=%s tier=%s\n' "$CODEX_MODEL" "$CODEX_EFFORT" "$CODEX_TIER"
  exit 0
fi

[[ -n "$PR_NUMBER" ]] || die "PR number is required (first positional arg)"
[[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || die "PR number must be numeric: $PR_NUMBER"

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
#   supervisor.pid   the supervisor's pid; removed when it exits
#   supervisor.log   what the front-end tails; appended, never truncated
#   worker.started   touched once the run is known to be well-formed
#   worker.status    the worker's FINAL_STATUS on a normal exit
#   stop             stop sentinel; the supervisor stops and does not relaunch
#
# The state path is the one ensure_state_dir computes; the front-end and the
# supervisor need it before the run is authenticated, so they derive it from
# the resolved forge identity alone.
PR_STATE_DIR="$LOOP_HOME/state/$(repo_ident_name)/pr-${PR_NUMBER}"

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

# True when $1 is a supervisor of this loop. A supervisor killed with SIGKILL
# leaves its pid file behind and the operating system hands that pid to
# something else, so match the command line before signalling the pid or
# refusing to start a run.
supervisor_is_live() {
  local pid="${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ps -o args= -p "$pid" 2>/dev/null | grep -q -- '--_supervise'
}

# Run a command in its own session. setsid is util-linux; perl's POSIX::setsid
# covers hosts without it (macOS). With neither, the command still outlives
# this process but shares its process group, so a group kill takes both down.
spawn_detached() {
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'use POSIX qw(setsid); setsid(); exec @ARGV or exit 127' -- "$@"
  else
    "$@"
  fi
}

# Record this run's outcome for the supervisor. Only a worker reports; an
# inline run has no supervisor reading it.
write_worker_status() {
  [[ "$ROLE" == "worker" ]] || return 0
  printf '%s\n' "$1" > "$STATE_DIR/worker.status"
}

# --stop: write the sentinel and signal the supervisor. No preflight, no
# clone — a stop must work even when the forge is unreachable.
if (( STOP_ONLY == 1 )); then
  mkdir -p "$PR_STATE_DIR"
  : > "$PR_STATE_DIR/stop"
  log "stop: wrote $PR_STATE_DIR/stop — the supervisor will not relaunch this PR"
  STOP_PID=''
  [[ -s "$PR_STATE_DIR/supervisor.pid" ]] && STOP_PID=$(head -1 "$PR_STATE_DIR/supervisor.pid")
  if supervisor_is_live "$STOP_PID"; then
    signal_supervisor "$STOP_PID"
    log "stop: signalled supervisor pid $STOP_PID"
  else
    log "stop: no live supervisor for this PR"
  fi
  exit 0
fi

if [[ "$ROLE" == "worker" ]]; then
  # Clear the status files this run will write: a previous run's values must
  # never be read as this one's outcome.
  mkdir -p "$PR_STATE_DIR"
  rm -f "$PR_STATE_DIR/worker.status" "$PR_STATE_DIR/worker.started"
fi

if [[ "$ROLE" == "frontend" ]] && (( AUTO_RESUME > 0 )) && (( PREFLIGHT_ONLY == 0 )); then
  SUP_LOG="$PR_STATE_DIR/supervisor.log"
  SUP_PID_FILE="$PR_STATE_DIR/supervisor.pid"
  mkdir -p "$PR_STATE_DIR"
  # Two supervisors on one PR would double-post. A pid file is stale once its
  # process is gone, or once that pid belongs to something else.
  OLD_PID=''
  [[ -s "$SUP_PID_FILE" ]] && OLD_PID=$(head -1 "$SUP_PID_FILE")
  if supervisor_is_live "$OLD_PID"; then
    die "a supervisor for this PR is already running (pid $OLD_PID); stop it with --stop, or pass --no-auto-resume to run in this process"
  fi
  # A stop from an earlier run must not block this one.
  rm -f "$PR_STATE_DIR/stop" "$SUP_PID_FILE"
  : >> "$SUP_LOG"
  # Tail from the end of what is already there, so a fresh invocation shows
  # its own output and not the whole history.
  SUP_LOG_OFFSET=$(wc -c < "$SUP_LOG" | tr -d ' ')

  STOP_HINT="$0 $PR_NUMBER --repo $REPO_SLUG"
  [[ "$FORGE" == "github" ]] || STOP_HINT="$STOP_HINT --forge $FORGE --host ${FORGE_SCHEME}://${FORGE_HOST}"
  STOP_HINT="$STOP_HINT --stop"
  SUP_PID=''
  TAIL_PID=''

  # Ctrl-C is a deliberate stop: leave the sentinel behind so the supervisor
  # cannot relaunch, and take the whole session down.
  frontend_interrupt() {
    : > "$PR_STATE_DIR/stop"
    if [[ -z "$SUP_PID" && -s "$SUP_PID_FILE" ]]; then SUP_PID=$(head -1 "$SUP_PID_FILE"); fi
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
    if [[ -z "$SUP_PID" && -s "$SUP_PID_FILE" ]]; then SUP_PID=$(head -1 "$SUP_PID_FILE"); fi
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
  # "already finished". The log line settles which.
  SUP_RAN=0
  for (( SUP_WAIT = 0; SUP_WAIT < 100; SUP_WAIT++ )); do
    if [[ -s "$SUP_PID_FILE" ]]; then
      SUP_PID=$(head -1 "$SUP_PID_FILE"); SUP_RAN=1; break
    fi
    if tail -c "+$((SUP_LOG_OFFSET + 1))" "$SUP_LOG" | grep -q 'auto-resume: supervisor started'; then
      # The pid lands before that line, so read the file again: a live
      # supervisor has written it by now, and an empty file means the
      # supervisor already exited.
      [[ -s "$SUP_PID_FILE" ]] && SUP_PID=$(head -1 "$SUP_PID_FILE")
      SUP_RAN=1; break
    fi
    sleep 0.1
  done
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
  printf '%s\n' "$$" > "$PR_STATE_DIR/supervisor.pid"
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
  # Forward the signal to the worker and leave the sentinel alone: whoever
  # sent it decides whether this PR resumes later.
  supervisor_signalled() {
    log "auto-resume: supervisor signalled — shutting down (worker pid ${WORKER_PID:-none})"
    kill_worker_tree
    rm -f "$PR_STATE_DIR/supervisor.pid"
    exit 143
  }
  trap supervisor_signalled TERM HUP

  log "auto-resume: supervisor started (pid $$, budget $AUTO_RESUME restart(s))"
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
    bash "$0" --_worker ${WORKER_ARGV[@]+"${WORKER_ARGV[@]}"} &
    WORKER_PID=$!
    WORKER_RC=0
    wait "$WORKER_PID" || WORKER_RC=$?
    # The worker's shell is gone; anything it started goes with it, or a
    # relaunch would put a second agent on the same checkout and PR.
    kill_worker_tree
    WORKER_PID=''
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
    sleep "$BACKOFF"
  done

  rm -f "$PR_STATE_DIR/supervisor.pid"
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
       CLAUDE_MODEL CLAUDE_EFFORT CLAUDE_PERMS CODEX_MODEL CODEX_EFFORT CODEX_TIER

preflight
# --preflight-only stops before any side effect: no clone, no state dir, no
# comment. It still needs branch discovery below for the open check and the
# canonical URL, so only the clone is skipped here.
(( PREFLIGHT_ONLY == 1 )) || ensure_repo_clone

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

# --preflight-only: report what a real run would use — the API/comment
# identity (resolved from the actual credential via /user or gh; pushes
# use the checkout's own git credential, which may differ), the canonical
# PR/MR URL, and the branches — then stop. Reaching this line already
# proves authority validation, credential resolution, and the open check
# all passed; any failure died above with its specific message.
if (( PREFLIGHT_ONLY == 1 )); then
  printf 'identity: %s\n' "$GH_USER"
  printf 'pr: %s\n' "$PR_URL"
  printf 'branches: %s <- %s\n' "$BASE_REF" "$HEAD_REF"
  exit 0
fi

ensure_state_dir
export STATE_DIR
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
log "  forge: $FORGE ($FORGE_SCHEME://$FORGE_HOST)"
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

# Position the local checkout at the EXACT PR head (fail-closed; handles
# option-like/ambiguous branch names and force-rewound remotes). See
# sync_repo_to_pr_head in lib/common.sh.
sync_repo_to_pr_head

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

    # Re-sync to the PR head in case anything landed remotely between turns.
    sync_repo_to_pr_head
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

  # Re-sync — Claude pushed; the local checkout must track the new PR head.
  sync_repo_to_pr_head

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

write_worker_status "$FINAL_STATUS"

case "$FINAL_STATUS" in
  approved|converged_no_major|review_posted) exit 0 ;;
  *)                                          exit 1 ;;
esac
