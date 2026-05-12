# Shared helpers for the AI PR loop.
# Sourced by codex_turn.sh, claude_turn.sh, run.sh.

# --- Identity / marker scheme -------------------------------------------------
#
# Both bots authenticate to GitHub via the same user PAT (the human's), so we
# distinguish them inside comment bodies in two ways:
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
  require_cmd gh
  require_cmd codex
  require_cmd claude
  require_cmd git
  require_cmd jq
  [[ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]] || die "GH_TOKEN/GITHUB_TOKEN not set"
  # Resolve the authenticated user so prompts can render the banner with the
  # right @handle (instead of a hardcoded one). Also doubles as an auth check.
  export GH_USER
  GH_USER=$(gh api user --jq .login 2>/dev/null) \
    || die "gh is not authenticated; run 'gh auth login' or set a valid GH_TOKEN"
  [[ -n "$GH_USER" ]] || die "gh api user returned empty login"
}

# Ensure $REPO_DIR contains a clone of $REPO_OWNER/$REPO_NAME. If it doesn't
# exist (or is an empty directory), clone via `gh repo clone` so the loop is
# self-contained — the caller never has to pre-clone the repo. If $REPO_DIR
# already holds a different repo, fail rather than mangle it.
ensure_repo_clone() {
  if [[ -d "$REPO_DIR/.git" ]]; then
    local origin_url remote_slug
    origin_url=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)
    # Normalize git@github.com:OWNER/NAME(.git) and https://github.com/OWNER/NAME(.git)
    remote_slug=$(sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##' <<<"$origin_url")
    if [[ -n "$remote_slug" && "$remote_slug" != "${REPO_OWNER}/${REPO_NAME}" ]]; then
      die "REPO_DIR=$REPO_DIR is a clone of '$remote_slug', not '${REPO_OWNER}/${REPO_NAME}'"
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
  log "cloning ${REPO_OWNER}/${REPO_NAME} into $REPO_DIR"
  gh repo clone "${REPO_OWNER}/${REPO_NAME}" "$REPO_DIR" >&2 \
    || die "failed to clone ${REPO_OWNER}/${REPO_NAME}"
}

# --- GitHub helpers -----------------------------------------------------------

# Fetch every AI-marked comment on the PR — both surfaces:
#   - `surface=issue`  → top-level PR comments (the summary / verdict comment)
#   - `surface=inline` → review comments attached to a specific file+line
# Output: NDJSON, one comment per line, fields:
#   { tag, iter, surface, id, path, line, in_reply_to_id, created_at, body }
# `id` is the GitHub comment id (needed for `in_reply_to` on inline replies).
# `path` / `line` / `in_reply_to_id` are null for issue comments.
fetch_ai_thread() {
  {
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
  } \
  | jq -c '
      . as $c
      | ($c.body | capture("<!-- (?<tag>ai-loop:[a-z-]+)\\s+iter=(?<iter>[0-9]+) -->") ) as $m
      | { tag: $m.tag, iter: ($m.iter|tonumber),
          surface: $c.surface, id: $c.id, path: $c.path, line: $c.line,
          in_reply_to_id: $c.in_reply_to_id,
          created_at: $c.created_at, body: $c.body }'
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
  gh pr comment "$PR_NUMBER" --repo "${REPO_OWNER}/${REPO_NAME}" --body "$wrapped" >/dev/null
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

# --- State dirs ---------------------------------------------------------------

ensure_state_dir() {
  STATE_DIR="$LOOP_HOME/state/${REPO_OWNER}__${REPO_NAME}/pr-${PR_NUMBER}"
  mkdir -p "$STATE_DIR"
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

# Diff the current session-file list against the snapshot, take the newest new
# file, and extract its session UUID from the first JSONL line (session_meta).
# Prints UUID on success; returns non-zero on failure.
discover_new_codex_session_id() {
  local before="$1"
  local codex_home="${CODEX_HOME:-$HOME/.codex}"
  local newest
  newest=$(find "$codex_home/sessions" -type f -name 'rollout-*.jsonl' 2>/dev/null \
            | sort | comm -23 - "$before" | tail -1)
  [[ -n "$newest" ]] || return 1
  head -1 "$newest" | jq -er '.payload.id // empty' 2>/dev/null
}
