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
'

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
# default path; everything else uses the XDG default.
glab_config_file() {
  if [[ -n "${GLAB_CONFIG_DIR:-}" ]]; then
    printf '%s/config.yml\n' "$GLAB_CONFIG_DIR"
  elif [[ "$(command -v glab 2>/dev/null)" == /snap/* ]]; then
    printf '%s/snap/glab/current/.config/glab-cli/config.yml\n' "$HOME"
  else
    printf '%s/glab-cli/config.yml\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
  fi
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
# threads; a thread whose ROOT is a DiffNote (has a position) is an inline
# discussion, anything else a top-level MR note. Surface, path, and line are
# computed once from the root and INHERITED by every note in the thread:
# replies in a diff discussion arrive as unpositioned DiscussionNote objects
# (and some servers echo DiffNote replies), so classifying each note by its
# own type/position would strip inline replies of their diff context and
# misfile them as issue-surface notes. System notes (push/merge events) are
# skipped. The first note of a thread is its root; later notes map to
# in_reply_to_id=<root id>. Pagination is manual (curl has no --paginate):
# fetch 100-per-page until a short page. API failures (curl non-2xx,
# non-array body) RETURN NON-ZERO rather than ending the loop quietly: a
# swallowed failure here would make resume detection see an empty thread and
# restart a live MR at iter 1 (double-posting), or silently truncate a
# >100-note thread mid-pagination — the GitHub path aborts on the equivalent
# gh failure, and this must too.
fetch_ai_thread_gitlab() {
  local page=1 chunk
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
      | select(.body | test("<!-- ai-loop:"))
      | { surface: $surface,
          id: .id,
          discussion_id: $did,
          path: $path,
          line: $line,
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
          "${FORGE_SCHEME:-https}://${FORGE_HOST}/api/v4/projects/${PROJECT_ENC}/merge_requests/${PR_NUMBER}/notes" \
          >/dev/null
      ;;
    *)
      gh pr comment "$PR_NUMBER" --repo "${REPO_OWNER}/${REPO_NAME}" --body "$wrapped" >/dev/null
      ;;
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
  local marker alert banner
  case "$tag" in
    codex)  marker="$CODEX_MARKER_TAG";  alert="$CODEX_SUMMARY_ALERT";  banner="$CODEX_SUMMARY_BANNER_PFX"  ;;
    claude) marker="$CLAUDE_MARKER_TAG"; alert="$CLAUDE_SUMMARY_ALERT"; banner="$CLAUDE_SUMMARY_BANNER_PFX" ;;
    *) die "unknown tag: $tag" ;;
  esac
  fetch_ai_thread \
    | jq -r --arg t "$marker" --arg a "$alert" --arg b "$banner" \
        "$AI_SUMMARY_JQ_DEF"'
         select(.tag==$t and .surface=="issue" and .in_reply_to_id==null)
         | select(is_summary($t; $a; $b; .iter))
         | .iter' \
    | sort -n | tail -1
}

# True iff the bot's iteration-$2 summary comment exists on the PR right now
# (same structural definition as latest_ai_comment_iter). The turn scripts
# call this after each turn instead of trusting the agent's stdout markers
# alone: an agent can print its verdict/completion marker even though the
# summary POST failed, or die after posting only inline notes. A failed
# thread fetch (or an empty thread) returns non-zero — fail closed.
ai_summary_posted() {
  local who="$1" iter="$2" marker alert banner
  case "$who" in
    codex)  marker="$CODEX_MARKER_TAG";  alert="$CODEX_SUMMARY_ALERT";  banner="$CODEX_SUMMARY_BANNER_PFX"  ;;
    claude) marker="$CLAUDE_MARKER_TAG"; alert="$CLAUDE_SUMMARY_ALERT"; banner="$CLAUDE_SUMMARY_BANNER_PFX" ;;
    *) die "unknown bot tag: $who" ;;
  esac
  fetch_ai_thread \
    | jq -es --arg t "$marker" --arg a "$alert" --arg b "$banner" --argjson it "$iter" \
        "$AI_SUMMARY_JQ_DEF"'
         any(.[]; .tag==$t and .iter==$it and .surface=="issue" and .in_reply_to_id==null
                  and is_summary($t; $a; $b; $it))' \
    >/dev/null
}

# Post-turn completion check with one short retry, absorbing forge
# read-after-write lag on the comment list endpoints just after the POST.
verify_ai_summary() {
  local who="$1" iter="$2"
  ai_summary_posted "$who" "$iter" && return 0
  sleep 5
  ai_summary_posted "$who" "$iter"
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
  if [[ "${FORGE:-github}" == "github" ]]; then
    printf '%s\n' "${REPO_SLUG//\//__}"
  else
    printf '%s__%s\n' "$FORGE_HOST" "${REPO_SLUG//\//__}"
  fi
}

# Full repo identity for marker files. GitHub keeps the bare slug (the
# pre-gitlab marker format, so existing state dirs validate unchanged);
# other forges record forge + scheme://host + slug. The scheme is part of
# the canonical identity: http://gl.example (port 80) and https://gl.example
# (port 443) are different endpoints, and the flat directory name alone
# cannot tell them apart.
repo_ident() {
  if [[ "${FORGE:-github}" == "github" ]]; then
    printf '%s\n' "$REPO_SLUG"
  else
    printf '%s %s://%s %s\n' "$FORGE" "${FORGE_SCHEME:-https}" "$FORGE_HOST" "$REPO_SLUG"
  fi
}

ensure_state_dir() {
  STATE_DIR="$LOOP_HOME/state/$(repo_ident_name)/pr-${PR_NUMBER}"
  mkdir -p "$STATE_DIR"
  local marker="$STATE_DIR/.repo-slug" owner want
  want=$(repo_ident)
  if [[ -s "$marker" ]]; then
    owner=$(<"$marker")
    # A scheme-less gitlab marker ('gitlab <host> <slug>', written before
    # the scheme joined the identity) is AMBIGUOUS: it could belong to the
    # host's http or https endpoint, and nothing persisted proves which.
    # Refuse it rather than adopt the current invocation's scheme — silently
    # attaching one endpoint's sessions/context/history to the other would
    # recreate the very identity confusion the scheme exists to prevent.
    # The operator, who knows which endpoint the old runs used, migrates
    # explicitly (one command, preserving sessions) or cleans the dir.
    if [[ "$owner" == "gitlab ${FORGE_HOST:-} $REPO_SLUG" && "$owner" != "$want" ]]; then
      die "state dir $STATE_DIR carries a pre-scheme identity marker ('$owner') whose original scheme cannot be inferred. If that state belongs to ${FORGE_SCHEME:-https}://${FORGE_HOST:-}, migrate it explicitly with:  echo '$want' > \"$marker\"  — otherwise clean the state dir"
    fi
    [[ "$owner" == "$want" ]] \
      || die "state dir $STATE_DIR belongs to '$owner', not '$want' (identity collision — use distinct project paths or clean the state dir)"
  else
    printf '%s\n' "$want" > "$marker"
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
