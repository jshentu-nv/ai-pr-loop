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

# --- Review exchange mode -------------------------------------------------
#
# LOCAL_MODE selects how the two agents exchange the review:
#   0 (default) — forge mode: the reviewer posts {{PR_NOUN}} comments, the
#                 implementer replies to them, and every iteration's commit
#                 is pushed as it is made.
#   1           — local mode: the review never touches the forge. The
#                 reviewer writes $STATE_DIR/iter-NN/codex-review.md, the
#                 implementer writes $STATE_DIR/iter-NN/claude-response.md
#                 and commits locally without pushing. When the review ends
#                 in agreement, finalize_turn.sh squashes every local round
#                 into ONE commit and pushes that.
#
# LOCAL_SCOPE says what local mode is reviewing:
#   pr     — a PR/MR (the forge is still read for metadata, and the single
#            squashed commit is pushed to the PR/MR's source branch).
#   branch — a local branch against a base ref, with no PR/MR at all.
LOCAL_MODE="${LOCAL_MODE:-0}"
LOCAL_SCOPE="${LOCAL_SCOPE:-pr}"

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

# Exact summary wrapper every summary comment must open with (see
# prompts/*): the bot's marker as the ENTIRE first line, then — blank lines
# aside — the alert opener and the banner line as the first visible
# content. The wrapper, not just the hidden marker, is what distinguishes a
# summary from any other tagged top-level note: on GitLab an attempted
# inline finding that loses its position lands as a general (issue-surface,
# root) note carrying the same marker, and counting that as a summary would
# let a turn that crashed before its real summary advance the resume
# high-water. All three summary consumers (high-water, post-turn
# verification, claude_turn's extraction) share the is_summary predicate
# below.
CODEX_SUMMARY_ALERT='> [!IMPORTANT]'
CLAUDE_SUMMARY_ALERT='> [!NOTE]'
CODEX_SUMMARY_BANNER_PFX='**AUTOMATED REVIEW — AI agent (Codex Reviewer), iteration '
CLAUDE_SUMMARY_BANNER_PFX='**AUTOMATED REPLY — AI agent (Claude Implementer), iteration '

# jq prelude: the structural summary predicate. Deliberately NOT a
# substring check — restatement comments legitimately QUOTE the banner in
# their prose (Codex's own do), so contains() would let a quoted banner in
# a tagged general note pass as a completed summary. Structure is enforced
# instead: marker line first, alert + exact banner line as the first
# visible lines. \r and trailing whitespace are normalized; nothing else.
AI_SUMMARY_JQ_DEF='
  def is_summary($m; $alert; $bpfx; $it):
    (((.body // "") | gsub("\r"; "") | split("\n")) | map(sub("[[:space:]]+$"; ""))) as $l
    | ($l[0] == "<!-- " + $m + " iter=" + ($it|tostring) + " -->")
      and (([ $l[1:][] | select(. != "") ])[0:2] ==
           [$alert, "> " + $bpfx + ($it|tostring) + ".**"]);
  def is_summary_root($m; $alert; $bpfx; $it):
    .tag==$m and .iter==$it and .surface=="issue" and .in_reply_to_id==null
    and is_summary($m; $alert; $bpfx; $it);
'

CODEX_LABEL="AI · Codex Reviewer"
CLAUDE_LABEL="AI · Claude Implementer"

CLAUDE_GIT_NAME="claude-implementer (ai-bot)"
CLAUDE_GIT_EMAIL="claude-implementer+bot@users.noreply.github.com"

# --- Logging ------------------------------------------------------------------

log()  { printf '[ai-loop %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

# Every git command the ORCHESTRATOR runs against a checkout an agent turn
# can write to. The turn may plant hooks there — pre-commit, pre-push,
# post-checkout, reference-transaction (which fires on ref updates, so
# reset/update-ref/fetch are ref-changing commands too) — and none of them
# may execute with the loop's authority after the turn. core.fsmonitor is
# likewise a config-planted program, and a "nothing changed" answer from
# one would also fake the cleanliness probes.
git_safe() { git -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"; }

# Publish a state file so a kill mid-write leaves either the old content
# or the new one — never a truncated file a later run would misread. (A
# plain '>' redirection truncates first and writes second.)
write_state_atomic() {  # <path> <content>
  printf '%s\n' "$2" > "$1.tmp" \
    && mv -f "$1.tmp" "$1"
}

# --- Pre-flight ---------------------------------------------------------------

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

# Read a host-scoped glab config value with glab's environment overrides
# cleared — both the token vars (GITLAB_TOKEN / GITLAB_ACCESS_TOKEN /
# OAUTH_TOKEN / GLAB_TOKEN: any of them shadows every host's configured
# token, so an ambient OAUTH_TOKEN minted for some other host would be
# returned as this host's "token", sail past the is_oauth2 guard, and be
# sent as a PRIVATE-TOKEN it was never meant to be) and the generic
# GLAB_<KEY>/GITLAB_<KEY> config overrides for the keys we read
# (GLAB_IS_OAUTH2=false would otherwise mask a stored OAuth session right
# before its token gets exported). The loop's only supported environment
# credential is GITLAB_TOKEN, which preflight consumes before ever reaching
# the glab-config fallback.
# The host key defaults to $FORGE_HOST; preflight may pin $GLAB_HOST_KEY
# to an equivalent stored spelling instead (glab keys host config by the
# exact authority string used at login, so a PAT stored under
# 'gl.example:443' or 'GL.EXAMPLE' is invisible under the canonical
# 'gl.example').
glab_config_get() {
  env -u GITLAB_TOKEN -u GITLAB_ACCESS_TOKEN -u OAUTH_TOKEN -u GLAB_TOKEN \
      -u GLAB_IS_OAUTH2 -u GITLAB_IS_OAUTH2 \
    glab config get "$1" --host "${GLAB_HOST_KEY:-$FORGE_HOST}" 2>/dev/null
}

# The config file the glab BINARY actually reads: $GLAB_CONFIG_DIR wins;
# a Snap-installed glab is confined to its own remapped HOME
# (~/snap/glab/current/.config/glab-cli), invisible at the caller's
# default path — snapd launches from /snap/bin or, on distributions
# without the /snap symlink, from /var/lib/snapd/snap/bin; then glab's
# legacy location ($HOME/.config/glab-cli) when it EXISTS — glab prefers
# it over an XDG_CONFIG_HOME override — and the XDG default last.
glab_config_file() {
  if [[ -n "${GLAB_CONFIG_DIR:-}" ]]; then
    printf '%s/config.yml\n' "$GLAB_CONFIG_DIR"
    return
  fi
  case "$(command -v glab 2>/dev/null)" in
    /snap/*|/var/lib/snapd/snap/*)
      printf '%s/snap/glab/current/.config/glab-cli/config.yml\n' "${HOME:-}"
      ;;
    *)
      if [[ -f "${HOME:-}/.config/glab-cli/config.yml" ]]; then
        printf '%s/.config/glab-cli/config.yml\n' "${HOME:-}"
      else
        printf '%s/glab-cli/config.yml\n' "${XDG_CONFIG_HOME:-${HOME:-}/.config}"
      fi
      ;;
  esac
}

# List the EXACT host-key spellings configured in glab (one per line).
# glab exposes no list command, so read the hosts: section of its config
# file directly — host keys are the 4-space-indented `key:` lines between
# `hosts:` and the next top-level key, with one layer of YAML quoting
# stripped (glab quotes keys like '[abcd::1]'). Used only as a candidate
# source for the preflight probe (the values are still read through the
# glab binary), so an unreadable/moved config degrades to the enumerated
# candidates.
glab_config_host_keys() {
  local cfg
  cfg=$(glab_config_file)
  [[ -r "$cfg" ]] || return 0
  awk '
    /^hosts:[[:space:]]*$/ { in_hosts = 1; next }
    in_hosts && /^[^[:space:]]/ { in_hosts = 0 }
    in_hosts && /^    [^[:space:]].*:[[:space:]]*$/ {
      k = $0
      sub(/^    /, "", k); sub(/:[[:space:]]*$/, "", k)
      if (k ~ /^\047.*\047$/ || k ~ /^".*"$/) k = substr(k, 2, length(k) - 2)
      print k
    }' "$cfg" 2>/dev/null
}

preflight() {
  require_cmd codex
  require_cmd claude
  require_cmd git
  require_cmd jq
  # Local branch scope never speaks to a forge: no CLI, no token, no
  # identity. GH_USER is exported empty so the fail-closed author filter in
  # fetch_ai_thread can never match anything if some path reaches it.
  if [[ "$LOCAL_SCOPE" == "branch" ]]; then
    export GH_USER=''
    log "local branch review: no forge credential needed"
    return
  fi
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
      # The glab fallback only works for PAT-backed sessions: a web/device
      # OAuth login stores an OAuth access token, which the REST API accepts
      # only as "Authorization: Bearer" (PRIVATE-TOKEN reads it as a PAT →
      # 401) and which expires mid-loop unless glab's own refresh runs.
      # Detect that configuration and reject it with instructions rather
      # than failing obscurely on /user (or hours later on token expiry).
      if [[ -z "${GITLAB_TOKEN:-}" ]]; then
        # FORGE_HOST is canonical (host lowercased, port numerically
        # normalized), but glab keys its host config by the EXACT string
        # used at login — a PAT stored under 'gl.example:443' or
        # 'gl.example:0443' is invisible under 'gl.example'. Probe the
        # canonical key, then the invocation's original validated spelling
        # (run.sh's ORIG_HOST), then EVERY accepted zero-padded spelling of
        # the endpoint's port (the validator caps ports at 5 digits, so
        # the paddings are finite), and pin ONE key for the paired
        # is_oauth2/token reads so the auth mode and the token can never
        # come from different sessions.
        local _glab_cand _glab_base _glab_obase _glab_b _glab_port _glab_pad _glab_seen _glab_bare
        GLAB_HOST_KEY="$FORGE_HOST"
        _glab_base="$FORGE_HOST"; _glab_port=''; _glab_bare=1
        if [[ "$FORGE_HOST" =~ ^(.+):([0-9]+)$ ]]; then
          _glab_base="${BASH_REMATCH[1]}"; _glab_port="${BASH_REMATCH[2]}"; _glab_bare=0
        else
          case "${FORGE_SCHEME:-https}" in
            http)  _glab_port=80  ;;
            https) _glab_port=443 ;;
          esac
        fi
        # glab stores login spellings verbatim and case-preserved, so when
        # the invocation's original host part differs in case from the
        # lowercased canonical base, its spellings must be enumerated too.
        _glab_obase="${ORIG_HOST:-}"
        if [[ "$_glab_obase" =~ ^(.+):([0-9]+)$ ]]; then
          _glab_obase="${BASH_REMATCH[1]}"
        fi
        [[ "$_glab_obase" == "$_glab_base" ]] && _glab_obase=''
        if [[ -z "$(glab_config_get token)" ]]; then
          _glab_seen=" $GLAB_HOST_KEY "
          set -- "${ORIG_HOST:-}"
          for _glab_b in "$_glab_base" "$_glab_obase"; do
            [[ -n "$_glab_b" ]] || continue
            # The bare spelling is equivalent only when the endpoint sits
            # on the scheme's default port (the canonical bare form was
            # already probed; this adds the original-cased one).
            if [[ "$_glab_bare" == 1 && "$_glab_b" != "$_glab_base" ]]; then
              set -- "$@" "$_glab_b"
            fi
            _glab_pad="$_glab_port"
            while [[ -n "$_glab_pad" && ${#_glab_pad} -le 5 ]]; do
              set -- "$@" "${_glab_b}:${_glab_pad}"
              _glab_pad="0${_glab_pad}"
            done
          done
          # Last: DISCOVER configured host keys and keep those whose
          # canonical authority is this endpoint — covers spellings no
          # enumeration can (arbitrary case mixed with padding, e.g. a PAT
          # logged in under 'GL.EXAMPLE' probed from a lowercase run).
          while IFS= read -r _glab_cand; do
            [[ -n "$_glab_cand" ]] || continue
            [[ "$(canon_authority "$_glab_cand" "${FORGE_SCHEME:-https}")" == "$FORGE_HOST" ]] \
              && set -- "$@" "$_glab_cand"
          done < <(glab_config_host_keys)
          for _glab_cand in "$@"; do
            [[ -n "$_glab_cand" ]] || continue
            [[ "$_glab_seen" == *" $_glab_cand "* ]] && continue
            _glab_seen="${_glab_seen}${_glab_cand} "
            if [[ -n "$(GLAB_HOST_KEY="$_glab_cand"; glab_config_get token)" ]]; then
              log "glab config: PAT stored under host key '$_glab_cand' — using that key"
              GLAB_HOST_KEY="$_glab_cand"
              break
            fi
          done
        fi
        if [[ "$(glab_config_get is_oauth2)" == "true" ]]; then
          die "glab session for $GLAB_HOST_KEY is OAuth-backed (web/device login) — its token cannot be sent as PRIVATE-TOKEN and expires mid-loop. Set GITLAB_TOKEN to a personal access token (api scope), or re-run 'glab auth login --hostname $FORGE_HOST' and authenticate with a token instead"
        fi
        GITLAB_TOKEN=$(glab_config_get token) || GITLAB_TOKEN=''
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
        || die "GitLab auth failed against ${FORGE_SCHEME:-https}://$FORGE_HOST/api/v4/user (token invalid or wrong host?)"
      ;;
    *) die "unknown forge: $FORGE (expected github or gitlab)" ;;
  esac
}

# Normalize a git remote URL to its repo slug: ssh://git@host[:port]/PATH(.git),
# [user@]host:PATH(.git), and https://host/PATH(.git) all reduce to PATH,
# which may contain subgroups on GitLab (group/sub/proj). The ssh:// form
# strips through the first / (the host part may carry :port); the scp-style
# forms strip through the first : (the userless form only when nothing
# before the colon contains a slash — i.e. it is a host, not a local path,
# matching git's own interpretation).
normalize_remote_slug() {
  # In order: ssh://[user@]host[:port]/PATH; [user@][v6bracket]:PATH and
  # [user@]host:PATH (scp-style); http(s)://[cred@]host/PATH; userless
  # host:PATH (scp-style — only when the char after the colon isn't '/',
  # so scheme prefixes like file:// and absolute scp paths are left intact
  # for the mismatch report). Bracketed IPv6 strips before the general scp
  # expressions, whose [^:/]+ would otherwise stop at the first colon
  # inside the brackets.
  sed -E 's#^ssh://[^/]+/##; s#^[^/:@]+@\[[^]]+\]:##; s#^[^/:@]+@[^:/]+:##; s#^https?://[^/]+/##; s#^\[[^]]+\]:([^/])#\1#; s#^[^/:@]+:([^/])#\1#; s#\.git$##; s#^/##' <<<"$1"
}

# Validate a forge authority before it is ever embedded in an API URL: a
# bare hostname (dot-separated alphanumeric/hyphen labels) or a bracketed
# IPv6 literal, plus an optional numeric port — nothing else. The authority
# is captured from a user-supplied MR URL / --host and pasted verbatim into
# every curl target, so URL-grammar tricks must die here: in
# https://gitlab.example.com@attacker.invalid/g/p/-/merge_requests/1 the
# "host" segment parses as gitlab.example.com@attacker.invalid, which curl
# reads as userinfo@attacker.invalid — a crafted MR link would send the
# PRIVATE-TOKEN header (the PAT) to the attacker's server.
validate_forge_authority() {
  local a="$1"
  # Labels admit underscores (common on intranet DNS, harmless here) and a
  # single trailing dot (an absolute FQDN) — neither can smuggle userinfo
  # or path characters.
  [[ "$a" =~ ^([A-Za-z0-9_]([A-Za-z0-9_-]*[A-Za-z0-9_])?(\.[A-Za-z0-9_]([A-Za-z0-9_-]*[A-Za-z0-9_])?)*\.?|\[[0-9A-Fa-f:]+\])(:[0-9]{1,5})?$ ]] \
    || die "invalid forge host '$a' — expected host[:port] (userinfo, paths, or other URL characters are not allowed)"
}

# Lowercase a host string: DNS reg-names (and IPv6 hex digits) are
# case-insensitive, so GL.EXAMPLE and gl.example are one endpoint. bash 3.2
# (stock macOS) lacks ${var,,}, hence tr.
lc_host() { LC_ALL=C tr '[:upper:]' '[:lower:]' <<<"$1"; }

# Comparable DNS-host form: lowercased, with one trailing dot — the
# absolute-FQDN spelling of the same name — stripped. IP literals
# (bracketed or bare IPv6) only lowercase.
canon_dns_host() {
  local h
  h=$(lc_host "$1")
  if [[ "$h" != \[* && "$h" != *:* && "$h" == *. ]]; then h="${h%.}"; fi
  printf '%s\n' "$h"
}

# Canonicalize an http(s) authority for a scheme: the host lowercases (DNS
# matching is case-insensitive) and the port normalizes NUMERICALLY —
# leading zeros drop (:0443 is :443 — curl parses the number), the scheme's
# default port drops entirely, any other port keeps its canonical digits.
# The single normalizer behind target-identity canonicalization, remote
# comparison, and legacy-state discovery — equivalent spellings must agree
# everywhere or they fork identity at whichever layer was missed.
canon_authority() {
  local a="$1" scheme="$2" host port def=''
  case "$scheme" in http) def=80 ;; https) def=443 ;; esac
  if [[ "$a" =~ ^(.+):([0-9]+)$ ]]; then
    host=$(canon_dns_host "${BASH_REMATCH[1]}"); port=$((10#${BASH_REMATCH[2]}))
    if [[ -n "$def" ]] && (( port == def )); then
      printf '%s\n' "$host"
    else
      printf '%s:%s\n' "$host" "$port"
    fi
  else
    canon_dns_host "$a"
  fi
}

# Drop a trailing :port from a host string (IPv6 bracket literals unwrap to
# their address) and reduce to the comparable DNS form (lowercased, one
# trailing dot stripped). This is the form normalize_remote_host emits —
# hostname comparisons are case- and absolute-FQDN-insensitive.
host_sans_port() {
  local h="$1"
  if [[ "$h" == \[* ]]; then
    h="${h#[}"; h="${h%%]*}"
  else
    h="${h%%:*}"
  fi
  canon_dns_host "$h"
}

# Hostname of a git remote URL: scheme://[user@]host[:port]/path and the
# scp-style [user@]host:path both reduce to host (:port stripped — an ssh
# remote's port legitimately differs from the web port; a userless
# host:path counts as scp-style only when no slash precedes the colon,
# matching git's own URL interpretation). Prints nothing when no host can
# be parsed (local path, file://, exotic transport) — callers must treat
# that as NOT the forge, not as unknown-but-fine.
normalize_remote_host() {
  local url="$1" head
  case "$url" in
    ssh://*|git://*|http://*|https://*)
      url="${url#*://}"; url="${url%%/*}"; url="${url#*@}"
      host_sans_port "$url"
      ;;
    *://*)
      # Unknown transport (file://, ftp://, ...) — not a forge endpoint.
      : ;;
    *@*:*)
      url="${url#*@}"
      if [[ "$url" == \[* ]]; then
        # scp-style with a bracketed IPv6 host: git@[::1]:path
        head="${url%%]*}"; lc_host "${head#[}"
      else
        canon_dns_host "${url%%:*}"
      fi
      ;;
    \[*\]:*)
      # userless bracketed IPv6: [::1]:path
      head="${url%%]*}"; lc_host "${head#[}"
      ;;
    [!/]*:*)
      head="${url%%:*}"
      if [[ "$head" != */* ]]; then canon_dns_host "$head"; fi
      ;;
    *)
      : ;;
  esac
}

# Authority (host[:port], userinfo stripped, the port canonicalized
# numerically per scheme) of an http(s) git remote; prints nothing for any
# other transport. Unlike ssh — where the transport port is unrelated to
# the web port — an HTTP(S) port is part of the instance identity:
# gitlab.lab:8929 and gitlab.lab:9999 are different GitLabs, while
# gl.example:0443 and gl.example are the same https endpoint.
normalize_remote_http_authority() {
  local url="$1" scheme authority
  case "$url" in
    http://*)  scheme=http  ;;
    https://*) scheme=https ;;
    *) return 0 ;;
  esac
  authority="${url#*://}"; authority="${authority%%/*}"; authority="${authority#*@}"
  canon_authority "$authority" "$scheme"
}

# $FORGE_HOST normalized the same way, so the two sides of the http(s)
# authority comparison agree (a no-op when run.sh already canonicalized).
forge_http_authority() {
  canon_authority "$FORGE_HOST" "${FORGE_SCHEME:-https}"
}

# Ensure $REPO_DIR contains a clone of $REPO_SLUG. If it doesn't exist (or is
# an empty directory), clone via the forge CLI (`gh repo clone` /
# `glab repo clone`) so the loop is self-contained — the caller never has to
# pre-clone the repo. If $REPO_DIR already holds a different repo, fail rather
# than mangle it.
# Validate ONE remote URL of the checkout against the loop's target repo.
# $1 = the URL, $2 = its role (fetch|push, for messages). Same-slug projects
# on different forges/hosts are different repositories (github.com/g/p vs
# gitlab.example/g/p); fetching or pushing this checkout while posting to
# the other host's PR would mangle both. The comparison is scheme-aware:
#   - http(s) URL → scheme AND full authority must match (default ports
#     dropped per scheme on both sides): an HTTP(S) endpoint is identified
#     by scheme://host:port, so gitlab.lab:8929 vs gitlab.lab:9999 — and
#     http://gl.example (port 80) vs https://gl.example (port 443) — never
#     pass as each other.
#   - ssh/scp/git URL → hostnames only (a transport port is unrelated to
#     the web port), with the forges' documented alternate ssh endpoints
#     (ssh.github.com, altssh.gitlab.com) counting as their host, and a
#     dotless parsed host treated as a ~/.ssh/config alias — unverifiable,
#     so the slug check has to carry it alone.
# A mismatch dies: if the URL reaches the right host through an alias or
# rewrite, point it at the canonical authority, or use a fresh --dir and
# let the loop clone canonically itself.
validate_origin_url() {
  local url="$1" kind="$2"
  local remote_slug remote_host remote_auth remote_scheme want_host want_auth
  remote_slug=$(normalize_remote_slug "$url")
  if [[ -n "$remote_slug" && "$remote_slug" != "$REPO_SLUG" ]]; then
    die "REPO_DIR=$REPO_DIR origin $kind URL is a clone of '$remote_slug', not '$REPO_SLUG'"
  fi
  remote_auth=$(normalize_remote_http_authority "$url")
  if [[ -n "$remote_auth" ]]; then
    remote_scheme="${url%%://*}"
    want_auth=$(forge_http_authority)
    [[ "${remote_scheme}://${remote_auth}" == "${FORGE_SCHEME:-https}://${want_auth}" ]] \
      || die "REPO_DIR=$REPO_DIR origin $kind URL points at '${remote_scheme}://${remote_auth}', not '${FORGE_SCHEME:-https}://${want_auth}' — same slug on a different forge/scheme/host/port is a different repository (same instance under another name, e.g. a search-domain short name? point origin at the canonical authority, or use a fresh --dir)"
  else
    remote_host=$(normalize_remote_host "$url")
    want_host=$(host_sans_port "${FORGE_HOST:-github.com}")
    if [[ -z "$remote_host" ]]; then
      # No parseable endpoint at all: a local/relative path or file://
      # mirror. That is definitively NOT the forge — a matching slug
      # (e.g. origin 'g/p.git' for gl.example/g/p) would let the loop
      # review and push a local mirror while its comments go to the MR.
      die "REPO_DIR=$REPO_DIR origin $kind URL '$url' has no forge endpoint (local path or unsupported transport) — the loop must fetch/push the MR's repository; point origin at the forge, or use a fresh --dir"
    fi
    # The public forges' documented alternate ssh endpoints are SPECIFIC
    # literal mappings — ssh.github.com is github.com, altssh.gitlab.com is
    # gitlab.com — not a general "<prefix>.<host>" rule: on a self-host,
    # ssh.gl.example is just another DNS name that need not route to
    # gl.example, so a prefixed form there is a different endpoint and must
    # be rejected like any other mismatch. '/' is an impossible hostname,
    # used as the no-alternate placeholder.
    local alt_host='/'
    case "$want_host" in
      github.com) alt_host='ssh.github.com'    ;;
      gitlab.com) alt_host='altssh.gitlab.com' ;;
    esac
    case "$remote_host" in
      "$want_host"|"$alt_host")
        : ;;
      *.*)
        die "REPO_DIR=$REPO_DIR origin $kind URL points at host '$remote_host', not '$want_host' — same slug on a different forge/host is a different repository (ssh alias or URL rewrite for the right host? point origin at the canonical hostname, or use a fresh --dir)"
        ;;
      *:*)
        # An IP literal is an exact endpoint, never a ~/.ssh/config alias —
        # a nonmatching IPv6 origin must not ride the dotless-name
        # leniency below ([::2] is simply a different server than [::1]).
        # The comparison is TEXTUAL: hextet spellings are not
        # canonicalized, so [0:0:0:0:0:0:0:1] does not equal [::1] here —
        # the remediation names that case.
        die "REPO_DIR=$REPO_DIR origin $kind URL points at IPv6 host '[$remote_host]', not '[$want_host]' — same slug on a different host is a different repository (IPv6 literals compare textually: if this is the same address in another spelling, point origin at the target's exact spelling)"
        ;;
      *)
        # A dotless ALL-NUMERIC name is an IP literal in disguise —
        # decimal (2130706433), legacy octal (017700000001), or hex
        # (0x7f000001) spellings of an IPv4 address that the resolver
        # happily connects to. Those are endpoints, not ~/.ssh/config
        # aliases, and must never ride the alias leniency below.
        if [[ "$remote_host" =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]]; then
          die "REPO_DIR=$REPO_DIR origin $kind URL host '$remote_host' is a numeric IP spelling, not '$want_host' — same slug on a different host is a different repository"
        fi
        log "origin $kind host '$remote_host' looks like an ssh alias — cannot verify it matches $want_host (slug check passed)"
        ;;
    esac
  fi
}

ensure_repo_clone() {
  if [[ -d "$REPO_DIR/.git" ]]; then
    local url n_urls=0
    # Validate every fetch AND push URL of origin: the loop's `git push
    # origin` honors remote.origin.pushurl (which can differ arbitrarily
    # from the fetch URL, and can be multi-valued), so a checkout fetching
    # the right repo but pushing elsewhere would pass a fetch-only check
    # and then deliver the implementer's commits to the wrong server.
    # `get-url --push` falls back to the fetch URL when no pushurl is set —
    # a harmless double-validation.
    while IFS= read -r url; do
      if [[ -n "$url" ]]; then
        validate_origin_url "$url" fetch
        n_urls=$((n_urls + 1))
      fi
    done < <(git -C "$REPO_DIR" remote get-url --all origin 2>/dev/null || true)
    while IFS= read -r url; do
      if [[ -n "$url" ]]; then
        validate_origin_url "$url" push
        n_urls=$((n_urls + 1))
      fi
    done < <(git -C "$REPO_DIR" remote get-url --push --all origin 2>/dev/null || true)
    # A repo with no origin URL at all can't be validated — and can't serve
    # the loop, which fetches and pushes origin to track the MR branch.
    (( n_urls > 0 )) \
      || die "REPO_DIR=$REPO_DIR has no origin remote URL — the loop fetches/pushes origin to reach the MR's source branch; clone the repository properly or use a fresh --dir"
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
      if [[ "${FORGE_SCHEME:-https}" == "http" ]]; then
        # glab can't be steered to plain HTTP without per-host config (a
        # scheme inside GITLAB_HOST is stripped and it still speaks https),
        # so clone with git directly. Auth for a private repo — and for the
        # pushes this remote will take later — comes from the ambient git
        # credential setup, the same non-interactive push-path requirement
        # the loop already documents.
        git clone "http://${FORGE_HOST}/${REPO_SLUG}.git" "$REPO_DIR" >&2 \
          || die "failed to clone $REPO_SLUG from http://$FORGE_HOST"
      else
        GITLAB_HOST="$FORGE_HOST" glab repo clone "$REPO_SLUG" "$REPO_DIR" >&2 \
          || die "failed to clone $REPO_SLUG from $FORGE_HOST"
      fi
      ;;
    *)
      gh repo clone "$REPO_SLUG" "$REPO_DIR" >&2 \
        || die "failed to clone $REPO_SLUG"
      ;;
  esac
}

# Move $REPO_DIR's working tree to the EXACT PR/MR head — clean and
# detached — or die. Called before every turn so the agents never operate
# on (or commit) anything outside the PR. Hazards it defends against:
#   - Option-like / ambiguous forge branch names. `refs/heads/-f` and `@`
#     are valid refs, but `git checkout "$HEAD_REF"` reads `-f` as a flag
#     (silently NOT switching, rc 0) and `@` as HEAD. We resolve the head
#     to a literal COMMIT and detach onto it — a SHA can't be reparsed as
#     an option.
#   - Branch-derived tracking-ref destinations. A branch literally named
#     `HEAD` (forges allow it) maps to `refs/remotes/origin/HEAD`, normally
#     a SYMREF to origin/<default> — fetching into it follows the symref
#     and corrupts the base tracking ref instead (alternating checkouts).
#     We fetch into fixed, private refs (refs/ai-pr-loop/*), which branch
#     names can never alias — and clear each destination with a --no-deref
#     delete first, so even a pre-planted symref AT the destination cannot
#     redirect the fetch onto some other ref.
#   - A force-rewound remote (B→A) leaving a stale local HEAD at B. The
#     leading-'+' refspec force-updates our private ref to mirror the
#     remote, then we detach onto it.
#   - Leftover working-tree state. An agent turn runs `git add`/`commit`,
#     so any staged/unstaged/untracked file lying around would be published
#     with the PR. A managed clone (the loop's own) is force-reset and
#     cleaned before every turn. A caller-supplied --dir clone is checked
#     ONCE, on the first sync of this invocation: ANY dirt (probed with
#     --untracked-files=normal, so a caller's status.showUntrackedFiles=no
#     can't hide files) or a HEAD that is not an ancestor of the fetched
#     head (local-ahead/divergent) dies rather than have caller work
#     discarded or committed. After that first clean sync the invocation
#     owns the clone: later syncs force-reset and clean it like a managed
#     one, so build/test artifacts the loop's own agent turns leave behind
#     are dropped instead of wedging the loop or being committed.
#   - Swallowed failures. No `|| true`; every step `|| die`, and HEAD is
#     asserted equal to the fetched head at the end.

# Internal sentinel: 1 after the first verified-clean --dir sync of THIS
# process. Reset at source time — an inherited environment value must never
# be able to skip the first-sync safety checks.
SYNC_DIR_TRUSTED=0
# 1 once THIS process's own fetch saw the remote at the finalized squash
# (local_setup_repo sets it). Reset at source time: an inherited
# environment value must never stand in for that fetch.
LOCAL_FINALIZE_LANDED=0

# Force $1's worktree onto commit $2, dropping everything not in that commit.
# $3 selects how HEAD gets there:
#   detach (default) — check out the commit detached, so a turn's commit can
#                      never advance a branch the caller cares about.
#   attach           — keep HEAD on its current branch and reset it to the
#                      commit. Used by local branch reviews, where the branch
#                      IS the work product and its tip is already $2; the
#                      branch name is never re-parsed (an option-like name
#                      like `-f` would be read as a flag).
# Shared by the PR-head sync and the local-head sync so both clean identically.
force_clean_to_commit() {
  local d="$1" target="$2" mode="${3:-detach}" dirt
  # --force drops staged/unstaged changes; clean -ffd drops untracked files
  # including embedded git repos (single -f leaves those, and `git add -A`
  # would publish one as a gitlink). Ignored files may stay — `git add -A`
  # never commits them. core.hooksPath=/dev/null: no caller-installed hook
  # may run (a post-checkout hook could recreate artifacts right after
  # cleanup).
  if [[ "$mode" == "attach" ]]; then
    git_safe -C "$d" reset --quiet --hard "$target" \
      || die "could not reset $d to $target"
  else
    git_safe -C "$d" checkout --quiet --force --detach "$target" \
      || die "could not check out $target in $d"
  fi
  git -C "$d" -c core.fsmonitor=false clean -qffd \
    || die "could not remove untracked files in $d"
  # An initialized submodule left on a different commit would be staged by
  # `git add -A` as a changed gitlink; put every initialized one back on the
  # recorded commit, and drop untracked artifacts inside them — not
  # publishable through a superproject commit, but they change builds, tests,
  # and what the agents analyze. --checkout: the update strategy must never
  # come from the just-checked-out .gitmodules (update=merge/rebase would
  # create commits instead of detaching). (Both are no-ops when there are no
  # submodules.)
  git_safe -C "$d" submodule update --quiet --checkout --recursive --force \
    || die "could not reset initialized submodules in $d"
  git_safe -C "$d" submodule --quiet foreach --recursive \
      git -c core.hooksPath=/dev/null -c core.fsmonitor=false clean -qffd \
    || die "could not clean initialized submodules in $d"
  # Fail closed on anything the cleanup above did not cover.
  # --ignore-submodules=dirty is config-independent where it matters: it
  # overrides a submodule.<name>.ignore=all and still reports a DRIFTED
  # GITLINK (publishable via `git add -A`), while tolerating
  # submodule-internal worktree state — which cannot be published through a
  # superproject commit, and whose eol/filter non-idempotent variant no
  # cleanup could ever silence (dying on it would wedge the loop). A
  # top-level ' M' here includes checkout-non-idempotent eol/filter content:
  # an agent's ordinary `git add -A` would stage that renormalization diff,
  # publishing content the turn did not author — refusing to run is the only
  # way to keep the commit invariant; the repo owner can fix the branch with
  # `git add --renormalize . && git commit`.
  # core.fsmonitor=false: a formerly---dir clone keeps its caller config, and
  # a "nothing changed" fsmonitor answer must not fake this probe.
  dirt=$(git_safe -C "$d" status --porcelain --untracked-files=normal --ignore-submodules=dirty) \
    || die "git status failed in $d"
  [[ -z "$dirt" ]] \
    || die "residual uncommitted state in $d survived cleanup — refusing to run agents on it (if this is eol/filter renormalization noise, fix the branch with 'git add --renormalize . && git commit'): $dirt"
}

# Refuse a caller-supplied (--dir) clone that carries ANY state this
# invocation's later forced syncs would destroy: worktree dirt (superproject
# or submodule), a sparse checkout, or index bits that hide edits from
# status. Target-independent, so both the PR-head sync and a local branch
# review run it before taking ownership of the clone.
verify_caller_clone_clean() {
  local d="$1" dirt
  # Probe config-independently: a caller's submodule.<name>.ignore=all would
  # otherwise hide a drifted gitlink from this check, and a turn's `git add
  # -A` would stage it. core.fsmonitor=false: a caller's fsmonitor
  # hook/daemon claiming "nothing changed" would make status skip the real
  # worktree and report a tracked edit as clean.
  dirt=$(git_safe -C "$d" status --porcelain --untracked-files=normal --ignore-submodules=none) \
    || die "git status failed in $d"
  [[ -z "$dirt" ]] \
    || die "REPO_DIR=$d has uncommitted changes (staged, unstaged, untracked, or submodule drift) — refusing to run agents in a dirty --dir clone (a turn's git add/commit would publish them); commit, stash, or clean first"
  # Probe every initialized submodule's own worktree as well: the
  # superproject probe recurses using EACH SUBMODULE's config, so a
  # submodule-local status.showUntrackedFiles=no (or a nested
  # submodule.<name>.ignore=all) could hide caller state that this
  # invocation's later trusted syncs would clean away.
  dirt=$(git_safe -C "$d" submodule --quiet foreach --recursive \
           git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c status.showUntrackedFiles=normal status --porcelain --untracked-files=normal --ignore-submodules=none) \
    || die "git submodule status probe failed in $d"
  [[ -z "$dirt" ]] \
    || die "REPO_DIR=$d has uncommitted changes inside initialized submodules — refusing to run agents in a dirty --dir clone; commit, stash, or clean them first: $dirt"
  # An active sparse checkout marks every out-of-cone file skip-worktree,
  # hiding it from the status probes; refuse it with accurate guidance (the
  # generic index-bits advice below would only mislead here).
  if [[ "$(git -C "$d" config --get core.sparseCheckout 2>/dev/null)" == "true" ]]; then
    die "REPO_DIR=$d uses sparse-checkout, which the loop cannot safely run on (out-of-cone files are hidden from its safety probes) — run 'git sparse-checkout disable' first, or omit --dir to use a managed checkout"
  fi
  # assume-unchanged / skip-worktree index bits make status skip a file
  # entirely: a caller edit behind one would pass the probes above and be
  # destroyed by this invocation's later forced syncs. ls-files -v tags them
  # (lowercase = assume-unchanged, 'S'/'s' = skip-worktree); refuse both, in
  # the superproject and in every initialized submodule.
  dirt=$(git -C "$d" ls-files -v | { grep -E '^(S|[a-z]) ' || true; }) \
    || die "git ls-files probe failed in $d"
  [[ -z "$dirt" ]] \
    || die "REPO_DIR=$d has assume-unchanged/skip-worktree index entries that hide edits from status — clear them (git update-index --no-assume-unchanged/--no-skip-worktree) before running with --dir: $dirt"
  dirt=$(git_safe -C "$d" submodule --quiet foreach --recursive \
           'git ls-files -v | { grep -E "^(S|[a-z]) " || true; }') \
    || die "git submodule ls-files probe failed in $d"
  [[ -z "$dirt" ]] \
    || die "REPO_DIR=$d has assume-unchanged/skip-worktree index entries inside initialized submodules — clear them before running with --dir: $dirt"
}

sync_repo_to_pr_head() {
  local d="$REPO_DIR" target head dirt r
  # The fetch destinations must be DIRECT refs: git dereferences a
  # pre-existing symref destination and would force-rewrite whatever local
  # branch it points at. --no-deref delete removes the symref itself (rc 0
  # when absent), so the fetch below always creates fresh direct refs.
  for r in refs/ai-pr-loop/base refs/ai-pr-loop/head; do
    git_safe -C "$d" update-ref --no-deref -d "$r" \
      || die "could not clear stale ref $r in $d"
  done
  git_safe -C "$d" fetch --quiet origin \
      "+refs/heads/$BASE_REF:refs/ai-pr-loop/base" \
      "+refs/heads/$HEAD_REF:refs/ai-pr-loop/head" \
    || die "git fetch of '$BASE_REF'/'$HEAD_REF' from origin failed"
  target=$(git -C "$d" rev-parse --verify --quiet "refs/ai-pr-loop/head^{commit}") \
    || die "could not resolve the PR head (refs/ai-pr-loop/head) after fetch"
  if [[ "${MANAGED_CLONE:-1}" == "1" || "$SYNC_DIR_TRUSTED" == "1" ]]; then
    # Unconditionally, even when HEAD already matches.
    force_clean_to_commit "$d" "$target" detach
  else
    verify_caller_clone_clean "$d"
    head=$(git -C "$d" rev-parse --verify --quiet HEAD 2>/dev/null) || head=''
    if [[ -n "$head" && "$head" != "$target" ]] \
       && ! git -C "$d" merge-base --is-ancestor HEAD "$target" 2>/dev/null; then
      die "REPO_DIR=$d HEAD ($head) is not an ancestor of the PR head ($target) — refusing to discard local work in a --dir clone; reconcile it manually or omit --dir to use a managed checkout"
    fi
    # Detach even when the SHA already matches, so a turn's commit can
    # never advance a caller's local branch. --no-overwrite-ignore: an
    # ignored caller file whose path the PR head starts tracking must fail
    # the checkout (fail closed), not be silently replaced — the porcelain
    # probe above cannot see ignored files. core.hooksPath=/dev/null: a
    # caller-installed post-checkout hook must not run (it could create
    # artifacts a turn's `git add -A` would publish).
    git_safe -C "$d" checkout --quiet --detach --no-overwrite-ignore "$target" \
      || die "could not check out the PR head $target in $d (a caller file may collide with a path the PR tracks; reconcile manually)"
    # Align each initialized submodule with the gitlink its (just-updated)
    # superproject records, exactly as the superproject was treated: a
    # literal detached checkout with --no-overwrite-ignore, so an ignored
    # caller file inside a submodule whose path the new gitlink starts
    # tracking fails closed instead of being silently replaced
    # ('submodule update --force' has no such protection). $sha1 is
    # foreach's recorded-gitlink variable — single quotes are deliberate.
    # Not honoring .gitmodules update strategies is also what keeps a
    # PR-supplied update=merge/rebase from committing onto caller branches.
    # If the recorded commit is not fetched yet (e.g. the caller set
    # fetch.recurseSubmodules=false), try to fetch it best-effort first —
    # 'submodule update' used to do this; the checkout still fails closed
    # if the commit stays unavailable.
    git_safe -C "$d" submodule --quiet foreach --recursive \
        'git rev-parse --verify --quiet "$sha1^{commit}" >/dev/null 2>&1 \
           || git -c core.hooksPath=/dev/null fetch --quiet origin "$sha1" 2>/dev/null \
           || git -c core.hooksPath=/dev/null fetch --quiet origin 2>/dev/null \
           || true; \
         git -c core.hooksPath=/dev/null -c core.fsmonitor=false checkout --quiet --detach --no-overwrite-ignore "$sha1"' \
      || die "could not align initialized submodules with the PR head in $d (a caller file inside a submodule may collide with a path the PR tracks, or a recorded commit could not be fetched; reconcile manually)"
    # Config-independent post-check (superproject and submodule
    # worktrees): nothing — hook output, submodule drift, filter effects —
    # may have appeared between the pre-check and here. Caller-preserving:
    # on failure we die without cleaning.
    dirt=$(git_safe -C "$d" status --porcelain --untracked-files=normal --ignore-submodules=none) \
      || die "git status failed in $d"
    [[ -z "$dirt" ]] \
      || die "REPO_DIR=$d is not clean after checking out the PR head (a hook or filter may have produced state a turn could publish): $dirt"
    dirt=$(git_safe -C "$d" submodule --quiet foreach --recursive \
             git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c status.showUntrackedFiles=normal status --porcelain --untracked-files=normal --ignore-submodules=none) \
      || die "git submodule status probe failed in $d"
    [[ -z "$dirt" ]] \
      || die "REPO_DIR=$d has state inside initialized submodules after checking out the PR head: $dirt"
    # The caller's clone was verified clean; from here this invocation owns
    # it, and later syncs clean the loop's own turn artifacts (above).
    SYNC_DIR_TRUSTED=1
  fi
  [[ "$(git -C "$d" rev-parse HEAD)" == "$target" ]] \
    || die "post-sync HEAD in $d is not the PR head $target"
}

# --- Local mode: checkout positioning -------------------------------------
#
# Local rounds are committed but never pushed, so between turns the checkout
# must be cleaned WITHOUT being reset to the forge head — that would delete
# the very commits the run is producing. The loop's local tip is tracked by a
# ref of its own:
#   pr scope     — refs/ai-pr-loop/local/pr-<N>, because local rounds sit on
#                  a detached HEAD in a managed checkout shared with other
#                  PRs of the same repo; another PR's sync would otherwise
#                  leave them unreachable (and collectable).
#   branch scope — refs/heads/<branch>: the branch under review IS the work
#                  product, so HEAD stays attached to it.

# Run-level local metadata (base.sha, the composed commit message, the
# pushed/finalized markers). Per-iteration review files live in iter-NN/.
local_state_dir() { printf '%s/local\n' "$STATE_DIR"; }

local_tip_ref() {
  if [[ "$LOCAL_SCOPE" == "branch" ]]; then
    printf 'refs/heads/%s\n' "$HEAD_REF"
  else
    printf 'refs/ai-pr-loop/local/pr-%s\n' "$PR_NUMBER"
  fi
}

# The commit the whole local run started from: everything after it is the
# loop's own work, and exactly that range is squashed into the single pushed
# commit. Written once per run and read by finalize_turn.sh.
local_base_file() { printf '%s/base.sha\n' "$(local_state_dir)"; }

# Where the last committed round left HEAD. The tip ref keeps pr-scope
# rounds reachable; this file is the EXPECTED tip for both scopes, checked
# on every resume and sync so a branch or ref that moved outside the loop's
# own turns is caught instead of silently adopted (rounds lost, or foreign
# commits squashed as review work).
local_tip_file() { printf '%s/tip.sha\n' "$(local_state_dir)"; }

# The finalize outcome journal: one line "<kind> <sha>" written atomically,
# so an interruption during publication never leaves a half-recorded
# outcome (a kind without its SHA, or the reverse). kind is 'squash' (a
# commit to push) or 'nocommit' (nothing lands; only a title/description
# proposal) — a nocommit's SHA equals the base, so the SHA alone cannot
# tell the two apart. Records a held --no-push outcome or a rejected push
# awaiting retry, until it lands terminally.
local_finalized_file() { printf '%s/finalized\n' "$(local_state_dir)"; }
local_finalized_kind() { local f; f=$(local_finalized_file); [[ -s "$f" ]] && awk '{print $1}' "$f"; return 0; }
local_finalized_sha()  { local f; f=$(local_finalized_file); [[ -s "$f" ]] && awk '{print $2}' "$f"; return 0; }
# <sha> <kind> — one atomic write.
local_write_finalized() { write_state_atomic "$(local_finalized_file)" "$2 $1"; }

# Written before the squash commit moves HEAD, "<base> <approved-tree>": a
# finalize interrupted before it journaled its squash is recognized by it.
local_finalize_inprogress_file() { printf '%s/finalize-inprogress\n' "$(local_state_dir)"; }

# The review's terminal marker: its single commit was pushed, or landed as
# the local tip when there is no origin, or the rounds landed nothing. A
# plain rerun of a completed review is a no-op; --restart clears this.
local_completed_file() { printf '%s/completed.sha\n' "$(local_state_dir)"; }

# Iterations at or below this floor belong to earlier, completed reviews
# whose artifacts remain on disk as history; resume detection reads them as
# absent. Written by run.sh when --restart follows a completed review.
local_iter_floor_file() { printf '%s/iter-floor\n' "$(local_state_dir)"; }

# Durable --restart intent. Written before the floor and every marker a
# restart consumes, cleared only once the new review's base is established:
# a restart interrupted anywhere in between is re-driven by the next run,
# so no plain retry can resurrect the superseded review or exit as
# "already completed" without the requested new review.
local_restart_pending_file() { printf '%s/restart-pending\n' "$(local_state_dir)"; }

# A receipt written before each implementer round and cleared once its
# commit is anchored: "<iter> <pre-turn-tip>". Recovers the crash window
# where the turn committed and wrote its response but the loop was killed
# before anchoring the commit to the tip ref.
local_pending_turn_file() { printf '%s/pending-turn\n' "$(local_state_dir)"; }

# The origin destination the review is allowed to push to, recorded once
# when the review starts and held for its whole life. A missing file mid-
# review fails finalize closed (a turn could otherwise delete it to get a
# poisoned re-pin); an operator who legitimately moved the remote writes
# the new destination into the file by hand.
local_origin_file() { printf '%s/origin.url\n' "$(local_state_dir)"; }

# The effective fetch and push destinations of origin — every configured
# url/pushurl, with url.*.insteadOf / url.*.pushInsteadOf rewrites applied
# — or "(none)" when the remote does not exist. This covers the URL level
# only: transport config a turn could plant (core.sshCommand,
# credential.helper, http.proxy, remote.*.receivepack) is arbitrary code
# execution with the operator's powers and cannot be policed here.
origin_dest() {
  if git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1; then
    printf '%s\n%s\n' "$(git -C "$REPO_DIR" remote get-url --all origin)" \
                      "$(git -C "$REPO_DIR" remote get-url --push --all origin)"
  else
    printf '(none)\n'
  fi
}

# Record HEAD as the local tip: point the pr-scope ref at it (branch scope
# needs no ref — the branch itself is the tip), and persist it as the
# expected tip for later syncs and resumes. Runs at setup and after every
# turn that may have committed.
local_record_tip() {
  local ref head
  head=$(git -C "$REPO_DIR" rev-parse HEAD) || die "could not read HEAD in $REPO_DIR"
  if [[ "$LOCAL_SCOPE" == "branch" ]]; then
    # The branch is the work product: recording a detached or off-branch
    # HEAD would poison the expected tip with a commit the branch never
    # carried. Keep the previous round's record and stop.
    [[ "$(git -C "$REPO_DIR" symbolic-ref --quiet HEAD 2>/dev/null)" == "$(local_tip_ref)" ]] \
      || die "HEAD in $REPO_DIR is not on the branch under review — refusing to record it as the local tip; put the branch back and re-run"
  else
    ref=$(local_tip_ref)
    git_safe -C "$REPO_DIR" update-ref "$ref" "$head" \
      || die "could not update $ref in $REPO_DIR"
  fi
  write_state_atomic "$(local_tip_file)" "$head"
}

# A finalize was interrupted mid-publication: its squash commit exists but
# the tip is not yet anchored to it. Recover from EVERY partial state and
# leave a consistent, journaled, anchored tip so finalize can complete it.
# Returns 1 when there is nothing to repair; safe to call unconditionally,
# since during active rounds neither the outcome journal nor the in-progress
# marker exists.
#
# The squash is recognized two ways:
#   - the outcome journal (kind squash + its SHA), written after the commit;
#   - or, before that journal was written, the in-progress marker (base +
#     approved tree): the tip ref or HEAD is then a commit collapsing that
#     base onto that tree, which only the loop's own squash can be.
local_adopt_finalized_squash() {
  local fsha base cur ibase itree iround c ref_head head
  base=''; [[ -s "$(local_base_file)" ]] && base=$(<"$(local_base_file)")
  [[ -n "$base" ]] || return 1
  ref_head=$(git -C "$REPO_DIR" rev-parse --verify --quiet "$(local_tip_ref)^{commit}" 2>/dev/null || true)
  head=$(git -C "$REPO_DIR" rev-parse --verify --quiet HEAD 2>/dev/null || true)

  fsha=$(local_finalized_sha)
  if [[ "$(local_finalized_kind)" != "squash" || -z "$fsha" ]]; then
    # No squash journal yet. Was one being published? The in-progress marker
    # names the base and the approved tree; the squash is the ref/HEAD commit
    # that collapses them.
    [[ -s "$(local_finalize_inprogress_file)" ]] || return 1
    read -r ibase itree < "$(local_finalize_inprogress_file)"
    [[ "$ibase" == "$base" ]] || return 1
    # The recorded round must NOT be mistaken for the squash: a single round
    # has the same parent (base) and tree (approved) as its squash, so only a
    # DIFFERENT commit is the real squash. tip.sha still names that round (the
    # squash is journaled before local_record_tip advances tip.sha).
    iround=''; [[ -s "$(local_tip_file)" ]] && iround=$(<"$(local_tip_file)")
    fsha=''
    for c in "$ref_head" "$head"; do
      [[ -n "$c" ]] || continue
      [[ -n "$iround" && "$c" == "$iround" ]] && continue
      [[ "$(git -C "$REPO_DIR" rev-parse --verify --quiet "${c}^" 2>/dev/null)" == "$base" ]] || continue
      [[ "$(git -C "$REPO_DIR" rev-parse --verify --quiet "${c}^{tree}" 2>/dev/null)" == "$itree" ]] || continue
      fsha="$c"; break
    done
    [[ -n "$fsha" ]] || return 1
    # Journal it now — from here it is an ordinary recorded squash.
    local_write_finalized "$fsha" squash
  fi

  # Already anchored — nothing to repair.
  [[ -s "$(local_tip_file)" && "$(<"$(local_tip_file)")" == "$fsha" ]] && return 1
  # It must be a real commit that collapses base.. onto the base.
  git -C "$REPO_DIR" rev-parse --verify --quiet "${fsha}^{commit}" >/dev/null 2>&1 || return 1
  git -C "$REPO_DIR" merge-base --is-ancestor "$base" "$fsha" >/dev/null 2>&1 || return 1
  # The tip ref must be exactly where the loop's own finalize left it — the
  # squash (already advanced) or the recorded round (not yet) — never a
  # human's commit, which would be a descendant to fail closed on.
  cur="$ref_head"
  if [[ "$cur" == "$fsha" ]]; then
    : # ref already advanced (branch commit, or a killed adopt's update-ref); only tip.sha lags
  elif [[ -s "$(local_tip_file)" && "$cur" == "$(<"$(local_tip_file)")" ]]; then
    if [[ "$LOCAL_SCOPE" != "branch" ]]; then
      git_safe -C "$REPO_DIR" update-ref "$(local_tip_ref)" "$fsha" \
        || die "could not anchor the interrupted finalize squash $fsha in $REPO_DIR"
    else
      # Branch scope: the commit itself moves the branch. A branch still at
      # the round means the squash lives only on a detached HEAD; move the
      # branch onto it (the loop's own squash), not a foreign commit.
      git_safe -C "$REPO_DIR" update-ref "$(local_tip_ref)" "$fsha" \
        || die "could not anchor the interrupted finalize squash $fsha in $REPO_DIR"
    fi
  else
    return 1
  fi
  write_state_atomic "$(local_tip_file)" "$fsha"
  log "local: recovered an interrupted finalize — anchored the squash $fsha as the local tip"
  return 0
}

# Recover a round killed in the window between its commit and the anchoring
# of that commit to the tip ref. The `done` receipt names the EXACT commit
# the validated turn produced; recovery re-points the tip ref at precisely
# that commit — never at whatever HEAD happens to hold, so a human commit or
# a turn claude_turn.sh rejected is never adopted. A `pending` receipt (turn
# outcome never validated) invalidates the round so it re-runs. Runs on
# every startup, including under --restart, so a validated fix is anchored
# into the current state before the restart re-bases from it.
reconcile_pending_turn() {
  local pt state piter ptip post reftip
  pt=$(cat "$(local_pending_turn_file)" 2>/dev/null) || pt=''
  read -r state piter ptip post <<<"$pt"
  if [[ "$state" == "done" && "$piter" =~ ^[0-9]+$ ]] \
     && [[ "$ptip" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]] \
     && [[ "$post" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]] \
     && [[ -s "$(local_artifact_path claude "$piter")" ]] \
     && git -C "$REPO_DIR" rev-parse --verify --quiet "${post}^{commit}" >/dev/null 2>&1; then
    # The turn validated and produced exactly $post. Anchor it, but only
    # when the tip ref is where the loop itself left it — already at $post
    # (the branch-scope commit moved it, or a re-run already anchored) or
    # still at the pre-turn tip (never advanced). A ref anywhere else is a
    # human's; refuse rather than clobber it.
    reftip=$(git -C "$REPO_DIR" rev-parse --verify --quiet "$(local_tip_ref)^{commit}" 2>/dev/null || true)
    if [[ "$reftip" == "$post" || "$reftip" == "$ptip" ]]; then
      if [[ "$reftip" != "$post" ]]; then
        git_safe -C "$REPO_DIR" update-ref "$(local_tip_ref)" "$post" \
          || die "could not anchor iter $piter's commit $post in $REPO_DIR"
      fi
      write_state_atomic "$(local_tip_file)" "$post"
      log "local: recovered iter $piter — anchored its commit $post"
    else
      rm -f "$(local_pending_turn_file)"
      die "iter $piter produced commit $post but $(local_tip_ref) now points at $reftip — refusing to move it. Reconcile $REPO_DIR by hand, or remove $(local_state_dir) to start over"
    fi
  elif [[ "$piter" =~ ^[0-9]+$ ]]; then
    # `pending` (or malformed): the turn's outcome was never validated, and
    # the receipt records no committed SHA to prove which commit — if any —
    # the turn produced. Invalidate the round so it re-runs. A PR-scope
    # commit is on a detached HEAD local_setup_repo cleans; a branch-scope
    # commit left the branch ahead of the recorded tip, which — since it
    # cannot be told from a human commit — is left to local_setup_repo's
    # fail-closed "moved outside the loop" check rather than force-reset
    # (which would clobber a human commit made in the crash window).
    rm -f "$(local_artifact_path claude "$piter")"
  fi
  rm -f "$(local_pending_turn_file)"
}

# Position the checkout for the first turn of this invocation. Fresh run:
# start from the forge head (pr scope) or the branch tip (branch scope) and
# record it as the squash base. Resumed run: restore the local tip so earlier
# rounds are not lost.
local_setup_repo() {
  local d="$REPO_DIR" ref tip base origin_head r expected finalized
  mkdir -p "$(local_state_dir)"
  # Pin the push destination for the review's whole life: finalize refuses
  # to push anywhere else, whichever turn or invocation changed the
  # configuration in between. Written only when the review STARTS — a
  # missing pin mid-review is not re-adopted (a turn could delete the file
  # and redirect the remote); finalize fails closed on it instead.
  [[ -s "$(local_base_file)" ]] || origin_dest > "$(local_origin_file)"
  ref=$(local_tip_ref)
  # A caller-supplied clone is checked ONCE per invocation before this
  # process takes it over, exactly as sync_repo_to_pr_head does — every
  # positioning path below force-cleans, and a resumed local run reaches
  # those paths without going through that sync.
  if [[ "${MANAGED_CLONE:-1}" != "1" && "$SYNC_DIR_TRUSTED" != "1" ]]; then
    verify_caller_clone_clean "$d"
    SYNC_DIR_TRUSTED=1
  fi
  if [[ "$LOCAL_SCOPE" == "branch" ]]; then
    tip=$(git -C "$d" rev-parse --verify --quiet "${ref}^{commit}") \
      || die "could not resolve the branch under review ($ref) in $d"
    # Resumed run: only this loop's own turns may move the branch mid-review.
    # Check it against the expected tip recorded after the last committed
    # round — before any cleanup touches the worktree. A branch that was
    # reset lost rounds; one that advanced would get foreign commits squashed
    # as review work. Both fail closed.
    if [[ -s "$(local_base_file)" ]]; then
      # A finalize interrupted before it anchored its squash left the branch
      # at that squash while tip.sha still names the round; adopt it before
      # comparing, so the loop's own work is not read as foreign movement.
      local_adopt_finalized_squash || true
      expected=''
      [[ -s "$(local_tip_file)" ]] && expected=$(<"$(local_tip_file)")
      [[ -n "$expected" ]] \
        || die "local rounds are recorded for branch $HEAD_REF (base $(<"$(local_base_file)")) but no expected tip is — the state at $(local_state_dir) is incomplete; remove it to review the branch as it is now"
      [[ "$tip" == "$expected" ]] \
        || die "branch $HEAD_REF is at $tip but the last committed round left it at $expected — the branch moved outside the loop. Put it back on $expected to continue this review, or remove $(local_state_dir) to review the branch as it is now"
    fi
    # Pin the diff base for the whole review. Both prompts diff against
    # refs/ai-pr-loop/base; with no forge to fetch it from, it comes from
    # --base (resolved by run.sh). The --no-deref delete first: a pre-planted
    # symref at that path would otherwise redirect the update onto some other
    # ref (rc 0 when the ref does not exist).
    git_safe -C "$d" update-ref --no-deref -d refs/ai-pr-loop/base \
      || die "could not clear stale ref refs/ai-pr-loop/base in $d"
    git_safe -C "$d" update-ref refs/ai-pr-loop/base "$LOCAL_BASE_SHA" \
      || die "could not point refs/ai-pr-loop/base at $LOCAL_BASE_SHA in $d"
    force_clean_to_commit "$d" "$tip" attach
    if [[ ! -s "$(local_base_file)" ]]; then
      printf '%s\n' "$tip" > "$(local_base_file)"
      local_record_tip
      log "local: squash base recorded at $tip (branch $HEAD_REF)"
    fi
    return
  fi
  base=''
  [[ -s "$(local_base_file)" ]] && base=$(<"$(local_base_file)")
  if [[ -n "$base" ]]; then
    # A finalize interrupted before it anchored its squash left the ref at
    # the round while finalized.sha names the squash; advance the ref to it
    # (the killed local_record_tip's job) before resolving the tip.
    local_adopt_finalized_squash || true
    tip=$(git -C "$d" rev-parse --verify --quiet "${ref}^{commit}") \
      || die "local rounds are recorded for this PR (base $base) but their commits are not in $d — the checkout was recreated or pruned, and that work cannot be recovered; remove $(local_state_dir) to start a fresh local run"
    # The tip ref must still name the last committed round: a ref that moved
    # outside the loop's own turns would silently drop rounds or adopt
    # commits no turn produced.
    expected=''
    [[ -s "$(local_tip_file)" ]] && expected=$(<"$(local_tip_file)")
    [[ -n "$expected" ]] \
      || die "local rounds are recorded for this PR (base $base) but no expected tip is — the state at $(local_state_dir) is incomplete; remove it to start a fresh local run"
    [[ "$tip" == "$expected" ]] \
      || die "the local tip ref $ref is at $tip but the last committed round left it at $expected — it moved outside the loop; repoint it at $expected to continue this review, or remove $(local_state_dir) to start a fresh local run"
    # Refresh the base ref for this invocation's diffs, and prove the PR head
    # has not moved under us: local rounds are stacked on $base, so a remote
    # that advanced past it makes the eventual single push a non-fast-forward
    # (and the loop never force-pushes). Better to say so now than after
    # another few hours of agent turns.
    for r in refs/ai-pr-loop/base refs/ai-pr-loop/head; do
      git_safe -C "$d" update-ref --no-deref -d "$r" || die "could not clear stale ref $r in $d"
    done
    git_safe -C "$d" fetch --quiet origin \
        "+refs/heads/$BASE_REF:refs/ai-pr-loop/base" \
        "+refs/heads/$HEAD_REF:refs/ai-pr-loop/head" \
      || die "git fetch of '$BASE_REF'/'$HEAD_REF' from origin failed"
    origin_head=$(git -C "$d" rev-parse --verify --quiet "refs/ai-pr-loop/head^{commit}") \
      || die "could not resolve the PR head after fetch"
    if [[ "$origin_head" != "$base" ]]; then
      # One remote position is not external movement: the exact squash this
      # run already validated and pushed, with the crash landing between
      # the push and the terminal marker. Resume so the finalize shortcut
      # can complete the interrupted run (its re-push is a no-op).
      finalized=$(local_finalized_sha)
      if [[ -n "$finalized" && "$origin_head" == "$finalized" && "$tip" == "$finalized" ]] \
         && [[ "$(local_finalized_kind)" == "squash" ]]; then
        # Proof for the caller: this fetch saw the remote at the finalized
        # squash, so a later probe that cannot reach the remote must not
        # downgrade the conclusion.
        LOCAL_FINALIZE_LANDED=1
        log "local: the squashed commit $finalized already reached the remote — completing the interrupted finalization"
      else
        die "the PR head moved to $origin_head since this local run started at $base — its rounds can no longer be pushed as a fast-forward. Reconcile $d manually (the local rounds are at $ref), or remove $(local_state_dir) and re-run to review the new head from scratch"
      fi
    fi
    force_clean_to_commit "$d" "$tip" detach
    log "local: resuming local rounds at $tip (squash base $base)"
  else
    sync_repo_to_pr_head
    tip=$(git -C "$d" rev-parse HEAD) || die "could not read HEAD in $d"
    printf '%s\n' "$tip" > "$(local_base_file)"
    local_record_tip
    log "local: squash base recorded at $tip (PR head)"
  fi
}

# Between-turn cleanup: drop whatever the last turn left in the worktree,
# keep every local round.
sync_repo_to_local_head() {
  local d="$REPO_DIR" ref tip mode=detach
  ref=$(local_tip_ref)
  if [[ "$LOCAL_SCOPE" == "branch" ]]; then
    mode=attach
    # The branch IS the work product: a turn that detached HEAD would commit
    # onto nothing the loop tracks, and resetting the branch here would drop
    # those commits. Stop instead of choosing for the operator.
    [[ "$(git -C "$d" symbolic-ref --quiet HEAD 2>/dev/null)" == "$ref" ]] \
      || die "HEAD in $d is not on $ref any more (a turn detached or switched it) — a local branch review commits onto that branch; put it back before re-running"
  fi
  # A finalize interrupted before it anchored its squash left the tip at
  # that squash while tip.sha still names the round; adopt it as the loop's
  # own work before the check below would read it as foreign movement.
  local_adopt_finalized_squash || true
  tip=$(git -C "$d" rev-parse --verify --quiet "${ref}^{commit}") \
    || die "local tip ref $ref is missing in $d — this run's local rounds are unreachable"
  # The expected tip is recorded right after every committed round; a tip
  # that moved off it means something other than an implementer turn
  # committed, and syncing to it would adopt content no round produced.
  # Checked only when recorded — this function is also driven standalone.
  if [[ -s "$(local_tip_file)" ]] && [[ "$tip" != "$(<"$(local_tip_file)")" ]]; then
    die "local tip $ref is at $tip but the last committed round left it at $(<"$(local_tip_file)") — it moved outside the loop's own turns; refusing to sync to it"
  fi
  force_clean_to_commit "$d" "$tip" "$mode"
  [[ "$(git -C "$d" rev-parse HEAD)" == "$tip" ]] \
    || die "post-sync HEAD in $d is not the local tip $tip"
}

# --- Local mode: the review exchange --------------------------------------
#
# Forge mode's completion contract is the summary comment; local mode's is a
# file. The reviewer writes iter-NN/codex-review.md, the implementer writes
# iter-NN/claude-response.md, and each turn script deletes its own artifact
# before running so a crashed turn's leftovers can never read as completion.

local_artifact_path() {  # <codex|claude> <iter>
  case "$1" in
    codex)  printf '%s/codex-review.md\n'    "$(iter_dir "$2")" ;;
    claude) printf '%s/claude-response.md\n' "$(iter_dir "$2")" ;;
    *) die "unknown bot tag: $1" ;;
  esac
}

# True iff the bot's iteration-$2 artifact exists and has content.
local_artifact_written() { [[ -s "$(local_artifact_path "$1" "$2")" ]]; }

# Highest iteration the bot completed — the local counterpart of
# latest_ai_comment_iter. Prints 0 when it has never run.
latest_local_iter() {
  local who="$1" d n hi=0
  for d in "$STATE_DIR"/iter-*; do
    [[ -d "$d" ]] || continue
    n="${d##*/iter-}"
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    n=$((10#$n))
    local_artifact_written "$who" "$n" || continue
    (( n > hi )) && hi=$n
  done
  printf '%s\n' "$hi"
}

# --- GitLab API helper ----------------------------------------------------------

# GET a path (with optional query) under $FORGE_SCHEME://$FORGE_HOST/api/v4/.
# $FORGE_SCHEME (default https) comes from the MR URL / --host, so an
# HTTP-only self-hosted GitLab is reached on the scheme it actually serves.
# curl -f: HTTP >= 400 exits non-zero so callers can `|| die`.
gl_api_get() {
  curl -sSf -H "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" \
    "${FORGE_SCHEME:-https}://${FORGE_HOST:-gitlab.com}/api/v4/$1"
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
  # Buffered end to end: a failure after earlier pages, endpoints, or
  # mapped records already produced output must yield NOTHING. A truncated
  # thread can still carry a valid summary while silently missing later
  # inline findings — and the readers that pipe this function (the resume
  # high-water scan, the summary verifier's snapshot) must never adopt a
  # partial thread as the real one.
  local raw mapped
  case "$FORGE" in
    gitlab) raw=$(fetch_ai_thread_gitlab) || return 1 ;;
    *)      raw=$(fetch_ai_thread_github) || return 1 ;;
  esac
  mapped=$(jq -c '
      . as $c
      | ($c.body | capture("<!-- (?<tag>ai-loop:[a-z-]+)\\s+iter=(?<iter>[0-9]+) -->") ) as $m
      | { tag: $m.tag, iter: ($m.iter|tonumber),
          surface: $c.surface, id: $c.id,
          discussion_id: ($c.discussion_id // null),
          path: $c.path, line: $c.line,
          in_reply_to_id: $c.in_reply_to_id,
          created_at: $c.created_at, body: $c.body }' <<<"$raw") || return 1
  if [[ -n "$mapped" ]]; then printf '%s\n' "$mapped"; fi
}

# The ai-loop marker is PUBLIC — anyone who can comment on the PR can post
# a comment bearing an exact bot wrapper. Trusting it by marker alone lets
# an attacker forge a summary at a high iteration (steering resume
# high-water so the real bot turn is skipped) or a review body the
# write-enabled implementer then acts on. So EVERY record is filtered to
# the authenticated posting identity ($GH_USER, resolved from the token in
# preflight) before any marker/summary parsing: on GitHub the comment
# author is `.user.login`. `env.GH_USER` reads the exported value; if it
# were empty the comparison excludes everything — fail closed.
fetch_ai_thread_github() {
  # The guard makes the FIRST endpoint's failure fail the whole read —
  # the function's status is otherwise the second call's alone, and a
  # dead issue-comments endpoint would yield half a thread with rc 0.
  gh api --paginate \
    "repos/${REPO_OWNER}/${REPO_NAME}/issues/${PR_NUMBER}/comments" \
    --jq '.[]
          | select(.user.login == env.GH_USER)
          | select(.body | test("<!-- ai-loop:"))
          | {surface:"issue", id:.id, path:null, line:null,
             in_reply_to_id:null, created_at, body}' || return 1
  gh api --paginate \
    "repos/${REPO_OWNER}/${REPO_NAME}/pulls/${PR_NUMBER}/comments" \
    --jq '.[]
          | select(.user.login == env.GH_USER)
          | select(.body | test("<!-- ai-loop:"))
          | {surface:"inline", id:.id, path:.path,
             line:(.line // .original_line),
             in_reply_to_id:(.in_reply_to_id // null),
             created_at, body}'
}

# GitLab: one endpoint carries both surfaces. /discussions groups notes into
# threads; a thread whose ROOT is a DiffNote (has a position) is an inline
# discussion, anything else a top-level MR note. Surface, path, and line are
# computed once from the root and INHERITED by every note in the thread:
# replies in a diff discussion arrive as unpositioned DiscussionNote objects
# (and some servers echo DiffNote replies), so classifying each note by its
# own type/position would strip inline replies of their diff context and
# misfile them as issue-surface notes. System notes (push/merge events) are
# skipped, and — like the GitHub reader — every note is filtered to the
# authenticated posting identity (`.author.username == $GH_USER`) so a
# forged bot marker from another commenter can't steer resume state or the
# implementer. The first note of a thread is its root; later notes map to
# in_reply_to_id=<root id>. Pagination is manual (curl has no --paginate):
# fetch 100-per-page until an empty page. API failures (curl non-2xx,
# non-array body) RETURN NON-ZERO rather than ending the loop quietly: a
# swallowed failure here would make resume detection see an empty thread and
# restart a live MR at iter 1 (double-posting), or silently truncate a
# >100-note thread mid-pagination — the GitHub path aborts on the equivalent
# gh failure, and this must too.
fetch_ai_thread_gitlab() {
  local page=1 chunk n
  while :; do
    chunk=$(gl_api_get "projects/${PROJECT_ENC}/merge_requests/${PR_NUMBER}/discussions?per_page=100&page=${page}") \
      || return 1
    jq -e 'type == "array"' <<<"$chunk" >/dev/null 2>&1 || return 1
    jq -c '
      .[]
      | .id as $did
      | (.notes[0]) as $rootnote
      | ($rootnote.id) as $root
      | (if $rootnote.type == "DiffNote" then "inline" else "issue" end) as $surface
      | ($rootnote.position.new_path // $rootnote.position.old_path // null) as $path
      | ($rootnote.position.new_line // $rootnote.position.old_line // null) as $line
      | .notes[]?
      | select((.system // false) | not)
      | select(.author.username == env.GH_USER)
      | select(.body | test("<!-- ai-loop:"))
      | { surface: $surface,
          id: .id,
          discussion_id: $did,
          path: $path,
          line: $line,
          in_reply_to_id: (if .id == $root then null else $root end),
          created_at, body }' <<<"$chunk" || return 1
    # Read until an EMPTY page: a page shorter than the requested 100 is
    # not proof of the end — a self-hosted server can clamp per_page
    # lower, and stopping there would silently truncate the thread
    # (resume would then restart a live MR at iter 1 and double-post).
    # The guards on the jq calls matter: the buffering caller runs this
    # function with errexit suppressed, so an unguarded failure would
    # skip a page and keep going instead of aborting the read.
    n=$(jq 'length' <<<"$chunk" 2>/dev/null) || return 1
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
    (( n > 0 )) || break
    page=$((page + 1))
    if (( page > 200 )); then  # never spin on a broken API; fail closed
      log "WARNING: /discussions pagination passed 200 pages — aborting the thread read"
      return 1
    fi
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
          "${FORGE_SCHEME:-https}://${FORGE_HOST}/api/v4/projects/${PROJECT_ENC}/merge_requests/${PR_NUMBER}/notes" \
          >/dev/null
      ;;
    *)
      gh pr comment "$PR_NUMBER" --repo "${REPO_OWNER}/${REPO_NAME}" --body "$wrapped" >/dev/null
      ;;
  esac
}

# A bot's marker and summary-wrapper strings: hidden marker tag, alert
# opener, banner prefix. Every consumer of the is_summary predicate
# resolves them here so the three stay in step. Separated by the unit
# separator (0x1f), which unlike tab is not IFS whitespace — an empty
# field survives the read instead of shifting its neighbours.
ai_marker_fields() {  # <codex|claude>
  case "$1" in
    codex)  printf '%s\x1f%s\x1f%s\n' "$CODEX_MARKER_TAG"  "$CODEX_SUMMARY_ALERT"  "$CODEX_SUMMARY_BANNER_PFX"  ;;
    claude) printf '%s\x1f%s\x1f%s\n' "$CLAUDE_MARKER_TAG" "$CLAUDE_SUMMARY_ALERT" "$CLAUDE_SUMMARY_BANNER_PFX" ;;
    *) die "unknown bot tag: $1" ;;
  esac
}

# Highest iteration for which the bot's SUMMARY comment exists on the PR.
# A summary is an issue-surface thread ROOT whose body opens with the bot's
# structural summary wrapper for its own iteration (is_summary above): the
# summary is each turn's completion contract (posted last, after every
# inline note), so a turn that crashed after inline-only posts — or whose
# summary POST was rejected, or whose inline note degraded into a general
# note (even one QUOTING the banner in its prose) — must not advance the
# resume high-water. run.sh would otherwise skip the codex turn of an
# incomplete review (and claude would have no summary to answer).
latest_ai_comment_iter() {
  local tag="$1"  # codex|claude
  local fields marker alert banner
  fields=$(ai_marker_fields "$tag") || return 1
  IFS=$'\x1f' read -r marker alert banner <<<"$fields"
  fetch_ai_thread \
    | jq -r --arg t "$marker" --arg a "$alert" --arg b "$banner" \
        "$AI_SUMMARY_JQ_DEF"'select(is_summary_root($t; $a; $b; .iter)) | .iter' \
    | sort -n | tail -1
}

# True iff the bot's iteration-$2 summary comment exists on the PR right now
# (same structural definition as latest_ai_comment_iter). The turn scripts
# call this after each turn instead of trusting the agent's stdout markers
# alone: an agent can print its verdict/completion marker even though the
# summary POST failed, or die after posting only inline notes. A failed
# thread fetch (or an empty thread) returns non-zero — fail closed.
# $3 names the snapshot file the fetched thread lands in, so the caller
# that needs the verified data afterwards (emit_round_report) reads what
# this check was made against instead of fetching again.
ai_summary_posted() {  # <codex|claude> <iter> <snapshot-file>
  local who="$1" iter="$2" snap="$3" fields marker alert banner
  fields=$(ai_marker_fields "$who") || return 1
  IFS=$'\x1f' read -r marker alert banner <<<"$fields"
  # Fetch stderr stays on the turn's stderr: an auth or API failure here
  # must reach the log, or 'summary not found' hides the real cause.
  fetch_ai_thread > "$snap" || { rm -f "$snap"; return 1; }
  jq -es --arg t "$marker" --arg a "$alert" --arg b "$banner" --argjson it "$iter" \
     "$AI_SUMMARY_JQ_DEF"'any(.[]; is_summary_root($t; $a; $b; $it))' \
     "$snap" >/dev/null
}

# Post-turn completion check with one short retry, absorbing forge
# read-after-write lag on the comment list endpoints just after the POST.
verify_ai_summary() {  # <codex|claude> <iter> <snapshot-file>
  local who="$1" iter="$2" snap="$3"
  ai_summary_posted "$who" "$iter" "$snap" && return 0
  sleep 5
  ai_summary_posted "$who" "$iter" "$snap"
}

# The thread snapshot the landed-probe verifies and emit_round_report
# reads back. One builder keeps writer and reader on the same file.
thread_snapshot_path() {  # <codex|claude> <iter>
  printf '%s/thread.%s-post.ndjson\n' "$(iter_dir "$2")" "$1"
}

# True iff <who>'s iteration-$2 turn artifact is public: the written
# review/response file in local mode, the verified summary comment in forge
# mode. Both turn scripts probe through this so the completion contract
# stays in one place. Forge mode saves the verified thread snapshot for
# emit_round_report — the report must not depend on a second network read
# succeeding after the verifying one already did.
turn_artifact_landed() {  # <codex|claude> <iter>
  local who="$1" iter="$2"
  if [[ "$LOCAL_MODE" == "1" ]]; then
    local_artifact_written "$who" "$iter"
  else
    verify_ai_summary "$who" "$iter" "$(thread_snapshot_path "$who" "$iter")"
  fi
}

# --- Round reports --------------------------------------------------------------
#
# Each turn writes its summary for the PR thread, but the session driving the
# loop reads the orchestrator's log. So every turn ends by saving its own
# summary to iter-NN/<who>-report.md and printing it: the reviewer's findings
# and the implementer's responses reach the operator through the stream they
# are already watching, with no second fetch of the thread.
#
# One announcement line carries the bot tag ("codex: iter N report ..."); the
# body lines deliberately do not, so a log monitor keyed on the bot tags fires
# once per report instead of once per line.

# Print <who>'s iteration-$2 summary body out of the thread snapshot $3.
# Same structural predicate as ai_summary_posted — a tagged general note
# without the summary wrapper is not a summary.
extract_ai_summary_body() {  # <codex|claude> <iter> <thread-file>
  local who="$1" iter="$2" thread="$3" fields marker alert banner
  fields=$(ai_marker_fields "$who") || return 1
  IFS=$'\x1f' read -r marker alert banner <<<"$fields"
  # The -n matters: without it jq binds the first input to `.` and
  # `inputs` collects only the rest, silently skipping the first comment.
  # `first` keeps a double-posted summary (a landed POST plus its
  # instructed retry) from rendering the report body twice.
  jq -rn --arg t "$marker" --arg a "$alert" --arg b "$banner" --argjson it "$iter" \
     "$AI_SUMMARY_JQ_DEF"'[ inputs | select(is_summary_root($t; $a; $b; $it)) ] | first // empty | .body' \
     "$thread"
}

# How many body lines of a round report reach the log
# (AI_REPORT_LOG_MAX_LINES, default 200). The rest stay in the report
# file. Normalized where it is consumed, in emit_round_report: a malformed
# value would otherwise blow up `head`/arithmetic there — after the round
# already landed publicly — and turn a reporting problem into a failed
# turn. Anything but a non-negative integer warns and uses 200.
normalize_report_cap() {  # <value>
  local z s
  case "$1" in
    ''|*[!0-9]*)
      log "WARNING: AI_REPORT_LOG_MAX_LINES='$1' is not a non-negative integer — using 200"
      printf '200\n'
      ;;
    *)
      # Leading zeros are stripped as a STRING, by regex, before the
      # length guard: guarding on the raw length would turn a zero-padded
      # small value (0000000010) into the 1000000 fallback, arithmetic on
      # the raw value could wrap past INT64 and make `head -n` drop the
      # whole body, and a character-at-a-time strip goes quadratic on a
      # huge value. After the strip, a value beyond 9 digits caps at
      # 1000000 — effectively "log everything", kept finite.
      if [[ "$1" =~ ^0*([0-9]+)$ ]]; then
        s="${BASH_REMATCH[1]}"
      else
        s=0  # unreachable: the case arm above admits only digits
      fi
      if (( ${#s} > 9 )); then
        log "WARNING: AI_REPORT_LOG_MAX_LINES='$1' exceeds 9 digits — using 1000000"
        s=1000000
      fi
      printf '%s\n' "$s"
      ;;
  esac
}

# Save and log <who>'s iteration-$2 report. Callers reach this only once the
# summary is verified, so the body exists. Any failure here is a reporting
# failure and returns 0 regardless: the review already landed publicly, and
# failing the turn over a missing log line would repost the entire round.
emit_round_report() {  # <codex|claude> <iter>
  local who="$1" iter="$2" id report thread total line cap
  id=$(iter_dir "$iter")
  report="$id/$who-report.md"
  # Cleanup failures are reporting failures too: an unremovable or
  # colliding path (say, a directory squatting on the report name) warns
  # and returns 0 — it must not abort a turn that already completed, and
  # a path this function did not create is never deleted recursively.
  if ! rm -f "$report" 2>/dev/null || [[ -e "$report" ]]; then
    log "$who: WARNING — iter $iter report path $report is occupied or unremovable; report not captured for the log"
    return 0
  fi

  cap=$(normalize_report_cap "${AI_REPORT_LOG_MAX_LINES:-200}")

  if [[ "$LOCAL_MODE" == "1" ]]; then
    cp -f "$(local_artifact_path "$who" "$iter")" "$report" 2>/dev/null || true
  else
    # turn_artifact_landed saved the thread snapshot it verified; extract
    # from that first. Fetch only when the snapshot is missing or holds no
    # summary — a fresh network read can fail transiently right after the
    # verifying one succeeded, and this report has no later chance.
    thread=$(thread_snapshot_path "$who" "$iter")
    if [[ -s "$thread" ]]; then
      extract_ai_summary_body "$who" "$iter" "$thread" > "$report" 2>/dev/null || true
    fi
    if [[ ! -s "$report" ]] && fetch_ai_thread > "$thread" 2>/dev/null; then
      extract_ai_summary_body "$who" "$iter" "$thread" > "$report" 2>/dev/null || true
    fi
  fi

  if [[ ! -s "$report" ]]; then
    rm -f "$report" 2>/dev/null || true
    log "$who: WARNING — iter $iter report could not be captured for the log"
    return 0
  fi

  total=$(grep -c '' "$report" 2>/dev/null || echo 0)
  log "$who: iter $iter report ($total lines) -> $report"
  log "----- BEGIN $who report (iter $iter) -----"
  # `|| [[ -n "$line" ]]` keeps a final line that lacks a trailing newline —
  # local mode copies agent-written files verbatim, and those often end
  # without one.
  # cap 0 logs no body at all; BSD head rejects `-n 0`, so skip the read.
  if (( cap > 0 )); then
    while IFS= read -r line || [[ -n "$line" ]]; do
      log "  $line"
    done < <(head -n "$cap" "$report")
  fi
  if (( total > cap )); then
    log "  [$(( total - cap )) more line(s) — read $report]"
  fi
  log "----- END $who report (iter $iter) -----"
  return 0
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

# --- Auto-resume ----------------------------------------------------------------
#
# The supervisor in run.sh decides what to do after each worker exit from the
# status files in the per-PR state dir (see the protocol comment in run.sh).
# Both helpers are pure so the decision table and the backoff curve are
# testable on their own.

AUTO_RESUME_BACKOFF_FLOOR="${AUTO_RESUME_BACKOFF_FLOOR:-10}"   # seconds before the first restart
AUTO_RESUME_BACKOFF_CAP="${AUTO_RESUME_BACKOFF_CAP:-300}"      # ceiling for the doubling
AUTO_RESUME_LONG_RUN="${AUTO_RESUME_LONG_RUN:-600}"            # a worker living longer than this is not a crash loop

# What to do after a worker exit. $1 = the per-PR state dir. Prints
# "<stop|restart> <reason>".
#
#   stop sentinel present         the operator asked for this
#   terminal status               the loop reached an end state
#   codex_error / claude_error    an agent turn failed; a fresh run picks up
#                                 at the PR's high-water mark
#   no status, worker started     killed externally mid-run
#   no status, never started      bad flags or a failed preflight; relaunching
#                                 would loop forever on the same error
auto_resume_decision() {
  local d="$1" status=''
  if [[ -e "$d/stop" ]]; then
    printf 'stop stopped by request\n'
    return 0
  fi
  if [[ -f "$d/worker.status" ]]; then
    status=$(head -1 "$d/worker.status" 2>/dev/null) || status=''
  fi
  case "$status" in
    approved|converged_no_major|review_posted|max_iterations_reached)
      printf 'stop worker finished: %s\n' "$status" ;;
    finalize_error)
      # The review itself is over; only the squash or its push failed, and
      # the usual cause — the branch moved on the remote — is not something
      # another worker can resolve. The rounds stay in the checkout for the
      # operator, who re-runs once the branch is reconciled.
      printf 'stop the review finished but its single commit could not be landed (%s)\n' "$status" ;;
    codex_error|claude_error)
      printf 'restart agent turn failed (%s)\n' "$status" ;;
    '')
      if [[ -e "$d/worker.started" ]]; then
        printf 'restart worker died without writing a status (killed externally)\n'
      else
        printf 'stop worker failed before it started (config/preflight error)\n'
      fi ;;
    *)
      printf 'stop unrecognized worker status: %s\n' "$status" ;;
  esac
}

# Drop the context flags a relaunch must not replay from a worker argv,
# into STRIPPED_ARGV: --clear-context, and the --context* inputs with
# their values — a retry reuses the context.md the first worker persisted,
# and the original paths may be temporary. Values may be flag-shaped or
# hold newlines; positionals and every other flag (including --restart,
# whose resume branch is half-step-aware and safe to replay) pass through
# untouched.
strip_context_worker_flags() {
  STRIPPED_ARGV=()
  while (( $# > 0 )); do
    case "$1" in
      --clear-context) shift ;;
      --context|--context-url|--context-file)
        if (( $# >= 2 )); then shift 2; else shift; fi ;;
      *) STRIPPED_ARGV+=("$1"); shift ;;
    esac
  done
}

# Seconds to wait before restart number $1 (0-based) of a crash loop: the
# floor, doubled per attempt, capped.
auto_resume_backoff() {
  local n="$1" w="$AUTO_RESUME_BACKOFF_FLOOR"
  while (( n > 0 && w < AUTO_RESUME_BACKOFF_CAP )); do
    w=$(( w * 2 )); n=$(( n - 1 ))
  done
  if (( w > AUTO_RESUME_BACKOFF_CAP )); then w="$AUTO_RESUME_BACKOFF_CAP"; fi
  printf '%s\n' "$w"
}

# --- Repo identity / state dirs -------------------------------------------------

# Canonical directory name for the repo's managed checkout and state: path
# components join with __, and any non-github.com forge prefixes its host so
# same-slug repositories on different forges/hosts (github.com/g/p,
# gitlab.com/g/p, gitlab.internal/g/p) can never share a checkout, state, or
# sessions. GitHub keeps the legacy <owner>__<name> layout so existing
# checkouts/state keep working. The flat name is still NOT injective in
# corner cases (a GitLab path with a literal "__" component; a dotless
# intranet hostname colliding with a GitHub owner), so the state marker and
# the clone origin check both validate the full identity and fail loudly
# rather than silently share.
repo_ident_name() {
  if [[ "$LOCAL_SCOPE" == "branch" ]]; then
    printf 'local__%s-%s\n' "$(ident_slug "$(basename -- "$REPO_DIR_CANON")")" \
                            "$(printf '%s' "$REPO_DIR_CANON" | short_hash)"
  elif [[ "${FORGE:-github}" == "github" ]]; then
    printf '%s\n' "${REPO_SLUG//\//__}"
  else
    printf '%s__%s\n' "$FORGE_HOST" "${REPO_SLUG//\//__}"
  fi
}

# Per-target leaf under the repo identity: one PR/MR, or one branch of one
# checkout.
state_leaf_name() {
  if [[ "$LOCAL_SCOPE" == "branch" ]]; then
    printf 'branch-%s-%s\n' "$(ident_slug "$HEAD_REF")" "$(printf '%s' "$HEAD_REF" | short_hash)"
  else
    printf 'pr-%s\n' "$PR_NUMBER"
  fi
}

# Readable, filesystem-safe stub of an arbitrary string (path component,
# branch name). Never identifying on its own — every name that uses it also
# carries a hash of the full value, and the state marker validates the whole
# identity anyway.
ident_slug() {
  local s
  s=$(printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')
  printf '%s\n' "${s:0:40}"
}

# 8 hex chars over stdin. git is already required, so its hasher saves
# depending on one of sha256sum / shasum / openssl being installed.
short_hash() { git hash-object --stdin | cut -c1-8; }

# Full repo identity for marker files. GitHub keeps the bare slug (the
# pre-gitlab marker format, so existing state dirs validate unchanged);
# other forges record forge + scheme://host + slug. The scheme is part of
# the canonical identity: http://gl.example (port 80) and https://gl.example
# (port 443) are different endpoints, and the flat directory name alone
# cannot tell them apart.
repo_ident() {
  if [[ "$LOCAL_SCOPE" == "branch" ]]; then
    printf 'local %s %s\n' "$REPO_DIR_CANON" "$HEAD_REF"
  elif [[ "${FORGE:-github}" == "github" ]]; then
    printf '%s\n' "$REPO_SLUG"
  else
    printf '%s %s://%s %s\n' "$FORGE" "${FORGE_SCHEME:-https}" "$FORGE_HOST" "$REPO_SLUG"
  fi
}

# Validate a state dir's identity marker against this invocation's resolved
# identity; die on a mismatch. $1 = the state dir. A missing/empty marker
# passes — there is nothing to protect yet. The flat state path is not
# injective (a literal "__" path component collides), so every entry point
# that reads or writes a state dir — --stop, the front-end, the supervisor,
# the worker — must check this BEFORE consulting the sentinel, pid records,
# or lock, or one repository's stop/start acts on another's supervisor.
check_state_marker() {
  local dir="$1" marker="$1/.repo-slug" owner want
  [[ -s "$marker" ]] || return 0
  owner=$(<"$marker")
  want=$(repo_ident)
  # A scheme-less gitlab marker ('gitlab <host> <slug>', written before
  # the scheme joined the identity) is AMBIGUOUS: it could belong to the
  # host's http or https endpoint, and nothing persisted proves which.
  # Refuse it rather than adopt the current invocation's scheme — silently
  # attaching one endpoint's sessions/context/history to the other would
  # recreate the very identity confusion the scheme exists to prevent.
  # The operator, who knows which endpoint the old runs used, migrates
  # explicitly (one command, preserving sessions) or cleans the dir.
  if [[ "$owner" == "gitlab ${FORGE_HOST:-} $REPO_SLUG" && "$owner" != "$want" ]]; then
    die "state dir $dir carries a pre-scheme identity marker ('$owner') whose original scheme cannot be inferred. If that state belongs to ${FORGE_SCHEME:-https}://${FORGE_HOST:-}, migrate it explicitly with:  echo '$want' > \"$marker\"  — otherwise clean the state dir"
  fi
  [[ "$owner" == "$want" ]] \
    || die "state dir $dir belongs to '$owner', not '$want' (identity collision — use distinct project paths or clean the state dir)"
}

# mkdir-elected marker write, for filesystems without hard links and for
# repairing a pre-existing empty marker. mkdir is atomic everywhere; the
# winner PUBLISHES BY RENAME of a complete temp while holding the election
# dir, so no observer ever sees a partial or zero-byte marker from this
# path — a bare `repo_ident > marker` would expose an empty file between
# the open and the write, which a concurrent claimant would treat as
# unanchored. The winner writes only when no identity has landed; a loser
# waits for the marker. A marker that never appears means a claimant died
# inside the election — refuse with a cleanup hint rather than run
# unanchored.
claim_marker_election() {
  local dir="$1" marker="$1/.repo-slug" etmp _w
  if mkdir "$marker.lck" 2>/dev/null; then
    if [[ ! -s "$marker" ]]; then
      etmp="$marker.elect.$$"
      repo_ident > "$etmp"
      mv -f "$etmp" "$marker"
    fi
    rmdir "$marker.lck" 2>/dev/null || true
  else
    for (( _w = 0; _w < 50; _w++ )); do
      [[ -s "$marker" ]] && break
      sleep 0.1
    done
    [[ -s "$marker" ]] || die "state identity election for $dir did not complete (a claimant died mid-election?); remove $marker.lck and re-run after confirming no other run is live on this dir"
  fi
}

# Validate an existing marker or stamp ours: the first process to touch a
# state dir anchors its identity, so later collisions fail loudly instead
# of sharing pid records, sentinels, and sessions. Election is atomic —
# the marker is written aside and hard-linked into place, so it only ever
# appears with its full content and ln(2) picks exactly one winner among
# simultaneous first-touchers; every loser falls through and validates the
# winner's identity like any later toucher. Where ln cannot elect, and for
# a pre-existing empty marker, claim_marker_election takes over with the
# same publish-complete-or-not-at-all guarantee.
claim_state_marker() {
  local dir="$1" marker="$1/.repo-slug" tmp
  tmp="$marker.claim.$$"
  if [[ ! -e "$marker" ]]; then
    repo_ident > "$tmp"
    if ln "$tmp" "$marker" 2>/dev/null; then
      rm -f "$tmp"
      return 0
    fi
    rm -f "$tmp"
    if [[ ! -e "$marker" ]]; then
      claim_marker_election "$dir"
    fi
  elif [[ ! -s "$marker" ]]; then
    claim_marker_election "$dir"
  fi
  check_state_marker "$dir"
}

ensure_state_dir() {
  STATE_DIR="$LOOP_HOME/state/$(repo_ident_name)/$(state_leaf_name)"
  mkdir -p "$STATE_DIR"
  claim_state_marker "$STATE_DIR"
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


# --- Claude CLI invocation ------------------------------------------------
#
# Shared by claude_turn.sh (one implementer round) and finalize_turn.sh (the
# closing turn of a local review): both run `claude -p` against the same
# per-PR session, model, effort, and permission handling, so a knob resolved
# one way for a round can never resolve the other way for the finalize.
#
#   claude_prepare_cli                 — resolve every knob into the *_ARG
#                                        arrays (call once per script).
#   claude_run_prompt <prompt> <out> <err>
#                                      — run one prompt through them; the
#                                        CLI's exit status lands in
#                                        $CLAUDE_RUN_RC.

claude_prepare_cli() {
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
}

# Run <prompt-file>, writing stdout to <out> and stderr to <err>. Sets
# $CLAUDE_RUN_RC (and returns it).
claude_run_prompt() {
  _CLAUDE_PROMPT_FILE="$1"; _CLAUDE_OUT="$2"; _CLAUDE_ERR="$3"
  # A failing turn is a value this function RETURNS, not a script-ending
  # error, so errexit is off inside it and restored exactly as the caller
  # had it — leaving it on would abort the caller at the `return` instead of
  # letting it inspect the status.
  local _saved_errexit=0
  case $- in *e*) _saved_errexit=1 ;; esac
  # claude -p runs non-interactively; permission handling for unattended
  # operation (user authorized this) is selected above via --claude-perms.
  _claude_exec() {
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
        "$(cat "$_CLAUDE_PROMPT_FILE")" \
        > "$_CLAUDE_OUT" 2> "$_CLAUDE_ERR" )
  }

  set +e
  TURN_START=$SECONDS
  _claude_exec
  CLAUDE_RUN_RC=$?
  TURN_ELAPSED=$(( SECONDS - TURN_START ))

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
  if [[ $CLAUDE_RUN_RC -ne 0 && "$CLAUDE_PERMS_RESOLVED" == "auto" ]] \
     && (( ${#CLAUDE_PERMS_ARG[@]} > 0 )) \
     && (( TURN_ELAPSED < 15 )) \
     && [[ ! -s "$_CLAUDE_OUT" ]] \
     && ! grep -qi 'cannot determine the safety' "$_CLAUDE_ERR" \
     && grep -qiE 'auto[ -]mode (is )?(disabled by settings|unavailable for (your plan|this model)|requires CLAUDE_CODE_ENABLE_AUTO_MODE)' "$_CLAUDE_ERR"; then
    log "claude: permission mode 'auto' unavailable on this host — retrying with the settings safety net"
    mv "$_CLAUDE_ERR" "${_CLAUDE_ERR}.auto-rejected"
    CLAUDE_PERMS_ARG=()
    SETTINGS_PARTS+=("$CLAUDE_PERMISSIONS_NET")
    _joined=$(IFS=,; printf '%s' "${SETTINGS_PARTS[*]}")
    CLAUDE_SETTINGS_ARG=(--settings "{${_joined}}")
    _claude_exec
    CLAUDE_RUN_RC=$?
  fi
  (( _saved_errexit == 1 )) && set -e
  return "$CLAUDE_RUN_RC"
}

# ---------------------------------------------------------------------------
# Prompt rendering
# ---------------------------------------------------------------------------
# The two agent prompts (prompts/claude.md, prompts/codex.md) and the
# finalize prompt are a single source shared by every forge and both review
# exchange modes. Passages that differ are wrapped in blocks whose open/close
# markers sit alone on their own lines:
#
#   {{#github}} … {{/github}}   forge is GitHub
#   {{#gitlab}} … {{/gitlab}}   forge is GitLab
#   {{#forge}}  … {{/forge}}    the review is exchanged as PR/MR comments
#   {{#local}}  … {{/local}}    the review is exchanged as files on disk
#   {{#pr}}     … {{/pr}}       a PR/MR exists, so its metadata is readable
#   {{#branch}} … {{/branch}}   no PR/MR: a local branch against a base ref
#
# render_forge_blocks keeps the blocks whose tag is in the ACTIVE SET ($2, a
# space-separated list built by prompt_tags) and drops the rest; text outside
# any block is always kept. Blocks nest — a {{#pr}} section may hold
# {{#github}} and {{#gitlab}} variants — and an inner block is kept only when
# every block enclosing it is. Rendering runs BEFORE placeholder
# substitution, so block bodies may use {{PLACEHOLDER}} freely.
#
# An unclosed marker, a mismatched close, or a tag outside the vocabulary is
# an error rather than a silent mis-render: a dropped block would quietly
# strip an agent's posting recipe, and a typo ({{#gitlba}}) has no other
# symptom.
# squash / nocommit select the finalize prompt's job: compose the squashed
# commit's message, or — when the rounds land no net change on a PR/MR —
# only assess the title/description.
PROMPT_BLOCK_TAGS='github gitlab forge local pr branch squash nocommit'

render_forge_blocks() {
  local template="$1" want="$2"
  awk -v want="$want" -v vocab="$PROMPT_BLOCK_TAGS" '
    function fail(msg) { printf("prompt template %s: %s (line %d)\n", FILENAME, msg, FNR) > "/dev/stderr"; failed = 1; exit 3 }
    BEGIN {
      n = split(want,  a, /[ \t]+/); for (i = 1; i <= n; i++) if (a[i] != "") active[a[i]] = 1
      n = split(vocab, b, /[ \t]+/); for (i = 1; i <= n; i++) if (b[i] != "") known[b[i]] = 1
      depth = 0; keep[0] = 1
    }
    /^[[:space:]]*\{\{#[a-z]+\}\}[[:space:]]*$/ {
      tag = $0; sub(/^[[:space:]]*\{\{#/, "", tag); sub(/\}\}[[:space:]]*$/, "", tag)
      if (!(tag in known)) fail("unknown block tag {{#" tag "}}")
      depth++
      opened[depth] = tag
      keep[depth] = (keep[depth - 1] && (tag in active))
      next
    }
    /^[[:space:]]*\{\{\/[a-z]+\}\}[[:space:]]*$/ {
      tag = $0; sub(/^[[:space:]]*\{\{\//, "", tag); sub(/\}\}[[:space:]]*$/, "", tag)
      if (!depth) fail("unmatched {{/" tag "}}")
      if (opened[depth] != tag) fail("{{/" tag "}} closes {{#" opened[depth] "}}")
      depth--
      next
    }
    { if (keep[depth]) print }
    END { if (!failed && depth) fail("unclosed block {{#" opened[depth] "}}") }
  ' "$template"
}

# The active block set for this run: exchange mode, review scope, and (when a
# forge is involved) which forge.
prompt_tags() {
  local tags
  if [[ "$LOCAL_MODE" == "1" ]]; then tags='local'; else tags='forge'; fi
  if [[ "$LOCAL_SCOPE" == "branch" ]]; then
    tags="$tags branch"
  else
    tags="$tags pr ${FORGE:-github}"
  fi
  printf '%s\n' "$tags"
}

# Export the forge-specific vocabulary the shared prompts interpolate, so the
# agent reads its own forge's nouns ("merge request", "MR note") rather than
# the other forge's. Callers must have FORGE, REPO_SLUG, PR_NUMBER and (for
# gitlab) FORGE_HOST set.
forge_vocab() {
  local slug="${REPO_SLUG:-${REPO_OWNER:-}/${REPO_NAME:-}}"
  if [[ "$LOCAL_SCOPE" == "branch" ]]; then
    # No forge at all. PR_REF names the branch through the exported shell
    # variable, never the literal name — the branch name is deliberately kept
    # out of every sed-substituted value (see the turn scripts).
    FORGE_NAME='git'
    PR_NOUN='change'
    PR_NOUN_LONG='local review'
    PR_REF='of the branch `$HEAD_REF`'
    SUMMARY_NOUN='review file'
    INLINE_NOUN='findings'
    INLINE_NOUN_TITLE='Findings'
    TOKEN_NOUN='credential'
    AUTOLINK_SIGILS='`#N`'
    return
  fi
  if [[ "${FORGE:-github}" == "gitlab" ]]; then
    FORGE_NAME='GitLab'
    PR_NOUN='MR'
    PR_NOUN_LONG='GitLab merge request'
    PR_REF="\`${slug}!${PR_NUMBER}\` on \`${FORGE_HOST}\`"
    SUMMARY_NOUN='MR note'
    INLINE_NOUN='inline diff notes'
    INLINE_NOUN_TITLE='Inline diff notes'
    TOKEN_NOUN='GitLab token'
    AUTOLINK_SIGILS='`#N` or `!N`'
  else
    FORGE_NAME='GitHub'
    PR_NOUN='PR'
    PR_NOUN_LONG='GitHub pull request'
    PR_REF="\`${slug}#${PR_NUMBER}\`"
    SUMMARY_NOUN='issue-comment'
    INLINE_NOUN='inline review comments'
    INLINE_NOUN_TITLE='Inline review comments'
    TOKEN_NOUN='PAT'
    AUTOLINK_SIGILS='`#N`'
  fi
}
