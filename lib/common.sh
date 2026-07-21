# Shared helpers for the AI PR loop.
# Sourced by codex_turn.sh, claude_turn.sh, run.sh.

# --- Forge selection ------------------------------------------------------------
#
# The loop speaks to one of two forges, selected by $FORGE (github | gitlab)
# with $FORGE_HOST carrying the hostname (github.com, or the GitLab host —
# gitlab.com or self-hosted). GitLab terminology note: "PR" == MR and
# PR_NUMBER == the MR iid throughout; state lives under the same layout.
#
# GitHub access goes through the gh CLI (authed via GH_TOKEN/GITHUB_TOKEN).
# GitLab access goes through curl against the REST API v4 with a
# PRIVATE-TOKEN header; glab is used only for auth/token resolution and the
# initial clone. Rationale: `glab api` silently drops `position[...]`
# payloads when posting inline (line-anchored) MR discussions — the comment
# lands as a general note with HTTP 200 — and rejects `--input` JSON bodies
# with HTTP 400, so curl is the only reliable path for MR mutations. The
# orchestrator (and the agent prompts) therefore standardize on curl for
# every GitLab REST call.

FORGE="${FORGE:-github}"

# --- Identity / marker scheme -------------------------------------------------
#
# Both bots authenticate to the forge via the same user token (the human's),
# so we distinguish them inside comment bodies in two ways:
#
#   1. A hidden HTML marker the orchestrator can grep:
#        <!-- ai-loop:codex-reviewer    iter=N -->
#        <!-- ai-loop:claude-implementer iter=N -->
#
#   2. A visible label at the top of every comment, e.g.:
#        **[AI · Codex Reviewer · iteration N]**
#
# Code commits made by the Claude implementer use a distinct git author so they
# can be told apart from the human's commits in `git log`:
#        Author: claude-implementer (ai-bot) <claude-implementer+bot@users.noreply.github.com>

CODEX_MARKER_TAG="ai-loop:codex-reviewer"
CLAUDE_MARKER_TAG="ai-loop:claude-implementer"

CODEX_LABEL="AI · Codex Reviewer"
CLAUDE_LABEL="AI · Claude Implementer"

CLAUDE_GIT_NAME="claude-implementer (ai-bot)"
CLAUDE_GIT_EMAIL="claude-implementer+bot@users.noreply.github.com"

# --- Logging ------------------------------------------------------------------

log()  { printf '[ai-loop %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

# --- Pre-flight ---------------------------------------------------------------

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

preflight() {
  require_cmd codex
  require_cmd claude
  require_cmd git
  require_cmd jq
  case "$FORGE" in
    github)
      require_cmd gh
      [[ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]] || die "GH_TOKEN/GITHUB_TOKEN not set"
      # Resolve the authenticated user so prompts can render the banner with
      # the right @handle (instead of a hardcoded one). Also doubles as an
      # auth check.
      export GH_USER
      GH_USER=$(gh api user --jq .login 2>/dev/null) \
        || die "gh is not authenticated; run 'gh auth login' or set a valid GH_TOKEN"
      [[ -n "$GH_USER" ]] || die "gh api user returned empty login"
      ;;
    gitlab)
      require_cmd glab
      require_cmd curl
      # A raw token is required: every GitLab REST call — orchestrator and
      # agents alike — goes through curl (see the forge note above). Env
      # wins; otherwise pull the host's token out of the glab config.
      if [[ -z "${GITLAB_TOKEN:-}" ]]; then
        GITLAB_TOKEN=$(glab config get token --host "$FORGE_HOST" 2>/dev/null) \
          || GITLAB_TOKEN=''
      fi
      [[ -n "${GITLAB_TOKEN:-}" ]] \
        || die "no GitLab token for $FORGE_HOST: set GITLAB_TOKEN or run 'glab auth login --hostname $FORGE_HOST'"
      export GITLAB_TOKEN
      # URL-encoded project path ("group/sub/proj" -> "group%2Fsub%2Fproj"),
      # the id segment every /projects/:id API path needs.
      export PROJECT_ENC
      PROJECT_ENC=$(jq -rn --arg s "$REPO_SLUG" '$s|@uri')
      # GH_USER doubles as the forge login on GitLab (kept under one name so
      # prompts and turn scripts stay forge-agnostic). Doubles as auth check.
      export GH_USER
      GH_USER=$(gl_api_get user 2>/dev/null | jq -r '.username // empty') \
        || GH_USER=''
      [[ -n "$GH_USER" ]] \
        || die "GitLab auth failed against https://$FORGE_HOST/api/v4/user (token invalid or wrong host?)"
      ;;
    *) die "unknown forge: $FORGE (expected github or gitlab)" ;;
  esac
}

# Normalize a git remote URL to its repo slug: ssh://git@host[:port]/PATH(.git),
# git@host:PATH(.git), and https://host/PATH(.git) all reduce to PATH, which
# may contain subgroups on GitLab (group/sub/proj). The ssh:// form strips
# through the first / (the host part may carry :port); the scp-style form
# strips through the first :.
normalize_remote_slug() {
  sed -E 's#^ssh://git@[^/]+/##; s#^git@[^:/]+:##; s#^https?://[^/]+/##; s#\.git$##; s#^/##' <<<"$1"
}

# Ensure $REPO_DIR contains a clone of $REPO_SLUG. If it doesn't exist (or is
# an empty directory), clone via the forge CLI (`gh repo clone` /
# `glab repo clone`) so the loop is self-contained — the caller never has to
# pre-clone the repo. If $REPO_DIR already holds a different repo, fail rather
# than mangle it.
ensure_repo_clone() {
  if [[ -d "$REPO_DIR/.git" ]]; then
    local origin_url remote_slug
    origin_url=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)
    remote_slug=$(normalize_remote_slug "$origin_url")
    if [[ -n "$remote_slug" && "$remote_slug" != "$REPO_SLUG" ]]; then
      die "REPO_DIR=$REPO_DIR is a clone of '$remote_slug', not '$REPO_SLUG'"
    fi
    log "using existing clone at $REPO_DIR"
    return
  fi
  if [[ -e "$REPO_DIR" && ! -d "$REPO_DIR" ]]; then
    die "REPO_DIR exists but is not a directory: $REPO_DIR"
  fi
  if [[ -d "$REPO_DIR" && -n "$(ls -A "$REPO_DIR" 2>/dev/null)" ]]; then
    die "REPO_DIR exists and is non-empty but is not a git repo: $REPO_DIR"
  fi
  mkdir -p "$(dirname "$REPO_DIR")"
  log "cloning $REPO_SLUG into $REPO_DIR"
  case "$FORGE" in
    gitlab)
      GITLAB_HOST="$FORGE_HOST" glab repo clone "$REPO_SLUG" "$REPO_DIR" >&2 \
        || die "failed to clone $REPO_SLUG from $FORGE_HOST"
      ;;
    *)
      gh repo clone "$REPO_SLUG" "$REPO_DIR" >&2 \
        || die "failed to clone $REPO_SLUG"
      ;;
  esac
}

# --- GitLab API helper ----------------------------------------------------------

# GET a path (with optional query) under https://$FORGE_HOST/api/v4/.
# curl -f: HTTP >= 400 exits non-zero so callers can `|| die`.
gl_api_get() {
  curl -sSf -H "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" \
    "https://${FORGE_HOST:-gitlab.com}/api/v4/$1"
}

# --- Forge helpers --------------------------------------------------------------

# Fetch every AI-marked comment on the PR — both surfaces:
#   - `surface=issue`  → top-level PR/MR comments (the summary / verdict comment)
#   - `surface=inline` → review comments attached to a specific file+line
# Output: NDJSON, one comment per line, fields:
#   { tag, iter, surface, id, discussion_id, path, line, in_reply_to_id,
#     created_at, body }
# `id` is the forge comment id. On GitHub, inline replies target it via
# `in_reply_to` and `discussion_id` is null. On GitLab, replies POST to
# `discussions/<discussion_id>/notes` instead, so every note carries its
# thread's discussion id. `path` / `line` / `in_reply_to_id` are null for
# issue comments.
fetch_ai_thread() {
  case "$FORGE" in
    gitlab) fetch_ai_thread_gitlab ;;
    *)      fetch_ai_thread_github ;;
  esac \
  | jq -c '
      . as $c
      | ($c.body | capture("<!-- (?<tag>ai-loop:[a-z-]+)\\s+iter=(?<iter>[0-9]+) -->") ) as $m
      | { tag: $m.tag, iter: ($m.iter|tonumber),
          surface: $c.surface, id: $c.id,
          discussion_id: ($c.discussion_id // null),
          path: $c.path, line: $c.line,
          in_reply_to_id: $c.in_reply_to_id,
          created_at: $c.created_at, body: $c.body }'
}

fetch_ai_thread_github() {
  gh api --paginate \
    "repos/${REPO_OWNER}/${REPO_NAME}/issues/${PR_NUMBER}/comments" \
    --jq '.[]
          | select(.body | test("<!-- ai-loop:"))
          | {surface:"issue", id:.id, path:null, line:null,
             in_reply_to_id:null, created_at, body}'
  gh api --paginate \
    "repos/${REPO_OWNER}/${REPO_NAME}/pulls/${PR_NUMBER}/comments" \
    --jq '.[]
          | select(.body | test("<!-- ai-loop:"))
          | {surface:"inline", id:.id, path:.path,
             line:(.line // .original_line),
             in_reply_to_id:(.in_reply_to_id // null),
             created_at, body}'
}

# GitLab: one endpoint carries both surfaces. /discussions groups notes into
# threads; a DiffNote (has a position) is an inline finding, anything else a
# top-level MR note. System notes (push/merge events) are skipped. The first
# note of a thread is its root; later notes map to in_reply_to_id=<root id>.
# Pagination is manual (curl has no --paginate): fetch 100-per-page until a
# short page. API failures (curl non-2xx, non-array body) RETURN NON-ZERO
# rather than ending the loop quietly: a swallowed failure here would make
# resume detection see an empty thread and restart a live MR at iter 1
# (double-posting), or silently truncate a >100-note thread mid-pagination —
# the GitHub path aborts on the equivalent gh failure, and this must too.
fetch_ai_thread_gitlab() {
  local page=1 chunk
  while :; do
    chunk=$(gl_api_get "projects/${PROJECT_ENC}/merge_requests/${PR_NUMBER}/discussions?per_page=100&page=${page}") \
      || return 1
    jq -e 'type == "array"' <<<"$chunk" >/dev/null 2>&1 || return 1
    jq -c '
      .[]
      | .id as $did
      | (.notes[0].id) as $root
      | .notes[]?
      | select((.system // false) | not)
      | select(.body | test("<!-- ai-loop:"))
      | { surface: (if .type == "DiffNote" then "inline" else "issue" end),
          id: .id,
          discussion_id: $did,
          path: (.position.new_path // .position.old_path // null),
          line: (.position.new_line // .position.old_line // null),
          in_reply_to_id: (if .id == $root then null else $root end),
          created_at, body }' <<<"$chunk"
    (( $(jq 'length' <<<"$chunk") < 100 )) && break
    page=$((page + 1))
  done
}

post_ai_comment() {
  # $1 = tag (codex|claude), $2 = iter, $3 = body markdown (no marker yet)
  local who="$1" iter="$2" body="$3"
  local tag label
  case "$who" in
    codex)  tag="$CODEX_MARKER_TAG";  label="$CODEX_LABEL"  ;;
    claude) tag="$CLAUDE_MARKER_TAG"; label="$CLAUDE_LABEL" ;;
    *) die "unknown bot tag: $who" ;;
  esac
  local wrapped
  wrapped=$(printf '<!-- %s iter=%d -->\n**[%s · iteration %d]**\n\n%s' \
            "$tag" "$iter" "$label" "$iter" "$body")
  case "$FORGE" in
    gitlab)
      jq -n --arg body "$wrapped" '{body: $body}' \
      | curl -sSf -X POST -H "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" \
          -H 'Content-Type: application/json' --data @- \
          "https://${FORGE_HOST}/api/v4/projects/${PROJECT_ENC}/merge_requests/${PR_NUMBER}/notes" \
          >/dev/null
      ;;
    *)
      gh pr comment "$PR_NUMBER" --repo "${REPO_OWNER}/${REPO_NAME}" --body "$wrapped" >/dev/null
      ;;
  esac
}

# Returns the most recent comment with the given tag (codex|claude) on PR.
latest_ai_comment_iter() {
  local tag="$1"  # codex|claude
  local marker
  case "$tag" in
    codex)  marker="$CODEX_MARKER_TAG"  ;;
    claude) marker="$CLAUDE_MARKER_TAG" ;;
    *) die "unknown tag: $tag" ;;
  esac
  fetch_ai_thread \
    | jq -r --arg t "$marker" 'select(.tag==$t) | .iter' \
    | sort -n | tail -1
}

# --- Portable watchdog ----------------------------------------------------------
#
# run_with_timeout SECS CMD [ARGS...] — run CMD under a watchdog. Prefers GNU
# timeout, then gtimeout (macOS with brew coreutils, where the command carries
# the g prefix unless gnubin is on PATH), and otherwise falls back to a pure
# bash background-kill implementation, so no host needs a new dependency.
# Returns CMD's exit status (or the kill status when the watchdog fires).
run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    local pid watchdog rc=0
    "$@" &
    pid=$!
    # Detach the watchdog's stdio: it must not inherit (and hold open) the
    # caller's stdout pipe, or a fast empty-output command leaves pipeline
    # readers blocked until the full timeout expires.
    ( sleep "$secs"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    watchdog=$!
    wait "$pid" || rc=$?
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    return "$rc"
  fi
}

# --- Codex effort resolution ----------------------------------------------------
#
# Resolve the reviewer's reasoning effort. $1 = codex model ('off'/'' = host
# default), $2 = explicit effort ('' = not supplied). An explicit effort always
# wins verbatim. Otherwise the default adapts to the model: ultra for
# gpt-5.6-sol/-terra (the only models that support it), and 'off' (no level
# forced — the host codex config / model default applies) for everything else:
# effort ceilings vary per model (older gpt-5.x reject ultra/max, some catalog
# models top out below xhigh), so forcing a level on an arbitrary model risks
# 400ing every request.
resolve_codex_effort() {
  local model="$1" explicit="$2"
  if [[ -n "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return
  fi
  case "$model" in
    gpt-5.6-sol|gpt-5.6-terra) printf 'ultra\n' ;;
    *)                         printf 'off\n' ;;
  esac
}

# --- State dirs ---------------------------------------------------------------

ensure_state_dir() {
  # Slug-derived name: path components join with __. Identical to the old
  # <owner>__<name> layout for two-component GitHub slugs. The flat name is
  # NOT injective for GitLab paths containing a literal "__"
  # (group/sub__proj and group/sub/proj both map to group__sub__proj), so a
  # slug marker guards the dir the same way ensure_repo_clone guards the
  # clone: fail loudly rather than silently share sessions/state between
  # two different projects.
  STATE_DIR="$LOOP_HOME/state/${REPO_SLUG//\//__}/pr-${PR_NUMBER}"
  mkdir -p "$STATE_DIR"
  local marker="$STATE_DIR/.repo-slug" owner
  if [[ -s "$marker" ]]; then
    owner=$(<"$marker")
    [[ "$owner" == "$REPO_SLUG" ]] \
      || die "state dir $STATE_DIR belongs to '$owner', not '$REPO_SLUG' (flat-name collision — use distinct project paths or clean the state dir)"
  else
    printf '%s\n' "$REPO_SLUG" > "$marker"
  fi
}

iter_dir() {
  printf '%s/iter-%02d' "$STATE_DIR" "$1"
}

# --- Agent session persistence ------------------------------------------------
#
# Each PR gets one Claude session and one Codex session that persist across
# iterations (and across run.sh invocations), so the agents retain their own
# internal memory of the review process — not just the public PR thread.
#
#   $STATE_DIR/claude.session.uuid  — UUID we pin via `claude --session-id`
#   $STATE_DIR/codex.session.id     — UUID discovered after the first codex run
#                                     (codex has no pre-pin flag) and reused
#                                     via `codex exec resume <id>` thereafter.

gen_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  else
    die "no UUID source available (need /proc/sys/kernel/random/uuid or uuidgen)"
  fi
}

# Snapshot the current set of codex session files. Use this immediately before
# a fresh `codex exec` so `discover_new_codex_session_id` can identify the new
# rollout file the run creates.
snapshot_codex_sessions() {
  local out="$1"
  local codex_home="${CODEX_HOME:-$HOME/.codex}"
  find "$codex_home/sessions" -type f -name 'rollout-*.jsonl' 2>/dev/null \
    | sort > "$out"
}

# Diff the current session-file list against the snapshot and extract the new
# ROOT session's UUID from its first JSONL line (session_meta). A gpt-5.6
# review can spawn sub-agent threads mid-run, each with its own rollout file
# whose session_meta carries a source.subagent marker; `codex exec resume`
# rejects those ("direct app-server input is not allowed for multi-agent v2
# sub-agents"), so skip them and take the earliest non-subagent file — the
# root session is created at run start, sub-agents later.
# $2 (optional) binds the search to one invocation: concurrent loops all see
# each other's new rollouts in the host-global sessions dir, so only a root
# whose session_meta records exactly this cwd is accepted. FAIL CLOSED: a
# rollout without a cwd (older codex) cannot prove ownership and is skipped —
# the loop then starts fresh each iteration rather than risk capturing a
# concurrent loop's session.
# Prints UUID on success; returns non-zero on failure.
discover_new_codex_session_id() {
  local before="$1" want_cwd="${2:-}"
  local codex_home="${CODEX_HOME:-$HOME/.codex}"
  local f meta id cwd
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    meta=$(head -1 "$f" 2>/dev/null) || continue
    jq -e '.payload.source | (type == "object" and has("subagent")) | not' \
      <<<"$meta" >/dev/null 2>&1 || continue
    if [[ -n "$want_cwd" ]]; then
      cwd=$(jq -r '.payload.cwd // empty' <<<"$meta" 2>/dev/null) || cwd=''
      [[ "$cwd" == "$want_cwd" ]] || continue
    fi
    id=$(jq -er '.payload.id // empty' <<<"$meta" 2>/dev/null) || continue
    [[ -n "$id" ]] || continue
    printf '%s\n' "$id"
    return 0
  done < <(find "$codex_home/sessions" -type f -name 'rollout-*.jsonl' 2>/dev/null \
            | sort | comm -23 - "$before")
  return 1
}

# Print the session_meta (first JSONL line) of the rollout whose payload.id
# matches $1, or fail. Codex embeds the session uuid in the rollout filename
# (rollout-<timestamp>-<uuid>.jsonl), so try a targeted filename lookup first;
# only fall back to scanning first lines when that misses (hosts accumulate
# thousands of rollouts, and a head+jq per file over all of them costs
# minutes). The payload.id check guards both paths, so an odd filename can't
# return the wrong session.
codex_rollout_meta_for_id() {
  local id="$1"
  local codex_home="${CODEX_HOME:-$HOME/.codex}"
  local f meta
  while IFS= read -r f; do
    meta=$(head -1 "$f" 2>/dev/null) || continue
    if [[ "$(jq -r '.payload.id // empty' <<<"$meta" 2>/dev/null)" == "$id" ]]; then
      printf '%s\n' "$meta"
      return 0
    fi
  done < <(
    find "$codex_home/sessions" -type f -name "rollout-*-${id}.jsonl" 2>/dev/null
    find "$codex_home/sessions" -type f -name 'rollout-*.jsonl' 2>/dev/null
  )
  return 1
}

# Resolve a stored codex session id to a resumable ROOT session id:
#   - id belongs to a root rollout      → print it unchanged
#   - id belongs to a sub-agent rollout → follow parent_thread_id up to the
#                                          root (bounded hops) and print that;
#                                          repairs state persisted by the old
#                                          newest-file selector
#   - id has no rollout / broken chain  → return 1 (caller starts fresh)
# $2 (optional): the root must have been recorded for exactly this cwd — a
# stored id whose root belongs to another checkout (poisoned by a concurrent
# loop before discovery was cwd-bound) is rejected rather than hijacking that
# loop's conversation. FAIL CLOSED: a root without a cwd (older codex) cannot
# prove ownership and is rejected too; the caller starts fresh. Deliberate
# trade-off: a session whose checkout legitimately moved (e.g. the same PR
# re-run with a different --dir) is also rejected and restarts fresh — losing
# cross-iteration memory is recoverable, resuming another PR's conversation is
# not, and the two cases are indistinguishable from the rollout alone.
resolve_codex_root_session_id() {
  local id="$1" want_cwd="${2:-}"
  local hops found parent cwd
  for (( hops = 0; hops < 5; hops++ )); do
    found=$(codex_rollout_meta_for_id "$id") || return 1
    if jq -e '.payload.source | (type == "object" and has("subagent")) | not' \
         <<<"$found" >/dev/null 2>&1; then
      if [[ -n "$want_cwd" ]]; then
        cwd=$(jq -r '.payload.cwd // empty' <<<"$found" 2>/dev/null) || cwd=''
        [[ "$cwd" == "$want_cwd" ]] || return 1
      fi
      printf '%s\n' "$id"
      return 0
    fi
    parent=$(jq -er '.payload.source.subagent.thread_spawn.parent_thread_id // empty' \
               <<<"$found" 2>/dev/null) || return 1
    [[ -n "$parent" ]] || return 1
    id="$parent"
  done
  return 1
}
