#!/usr/bin/env bash
# Regression tests for the loop's CLI argv construction. No network and no
# real claude/codex/gh: the turn scripts run against PATH stubs that record
# their argv to a file, and assertions check the recorded vectors.
#
# Covers:
#   - resolve_codex_effort: adaptive default, explicit precedence, off
#   - claude_turn.sh argv: --model, ultracode --settings payload, --effort
#     levels, off omission, --claude-perms modes (auto / bypass safety net /
#     off), --session-id vs --resume
#   - codex_turn.sh argv: -m / model_reasoning_effort / service_tier mapping,
#     off omission, adaptive effort for non-sol models, fresh vs `exec resume`,
#     root-session discovery (sub-agent skip + cwd binding), stored-id
#     migration / discard of unresumable ids
#   - run.sh flag validation die-paths (empty / unknown / next-flag-as-value)
#     and resolved knob output via --print-config (adaptive default / explicit
#     precedence)
#   - forge resolution: PR/MR URL parsing (github / gitlab.com / self-hosted /
#     legacy no-/-/ form), --host implying gitlab, URL-vs-flag conflicts,
#     scheme preservation (http MR URLs / scheme-qualified --host),
#     authority validation (userinfo/path rejection, port + IPv6 acceptance)
#   - summary-as-completion: resume high-water counts only STRUCTURAL
#     summary roots (marker first line, alert + banner first visible);
#     inline notes, replies, banner-quoting prose, and misplaced markers
#     are excluded; both turn scripts fail when their iteration summary
#     never landed
#   - gitlab plumbing: preflight token resolution via the glab stub (incl.
#     OAuth-session rejection), fetch_ai_thread mapping of /discussions
#     (surfaces, discussion_id, reply chaining, system/non-marker filtering),
#     API-failure propagation (no silent empty thread), state-dir flat-name
#     collision guard, forge/host-namespaced state + checkout identity (clone
#     origin host guard), post_ai_comment via curl, gitlab prompt-template
#     selection in both turn scripts, remote-URL slug/host normalization
#
# Usage: tests/run_tests.sh
set -uo pipefail
# A user-exported CDPATH makes a successful relative `cd` print its
# destination, corrupting cd-based fixture paths; the scripts under test
# guard their own substitutions, the runner clears it once here.
unset CDPATH

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
CURRENT=""

t()   { CURRENT="$1"; }
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s — %s\n' "$CURRENT" "$1" >&2; }

# Argv files hold one argument per line.
assert_line()      { if grep -Fxq -- "$2" "$1"; then ok; else bad "argv missing exact arg: $2"; fi; }
assert_no_line()   { if grep -Fxq -- "$2" "$1"; then bad "argv unexpectedly contains: $2"; else ok; fi; }
assert_no_substr() { if grep -Fq  -- "$2" "$1"; then bad "argv unexpectedly has substring: $2"; else ok; fi; }
assert_pair() {  # file flag value — value must be the arg right after flag
  if awk -v f="$2" -v v="$3" 'prev==f && $0==v {found=1} {prev=$0} END {exit !found}' "$1"; then
    ok
  else
    bad "argv missing pair: $2 $3"
  fi
}
assert_eq() { if [[ "$1" == "$2" ]]; then ok; else bad "got '$1', want '$2'"; fi; }
# Scoped to a single flag's value (the claude prompt rides in argv, so
# whole-file substring checks would match prompt prose).
flag_value() { awk -v f="$2" 'prev==f {print; exit} {prev=$0}' "$1"; }
assert_value_has()   { local v; v=$(flag_value "$1" "$2"); if [[ "$v" == *"$3"* ]]; then ok; else bad "$2 value missing '$3' (got: $v)"; fi; }
assert_value_lacks() { local v; v=$(flag_value "$1" "$2"); if [[ "$v" == *"$3"* ]]; then bad "$2 value unexpectedly has '$3'"; else ok; fi; }
assert_rc0() { if [[ "$TURN_RC" -eq 0 ]]; then ok; else bad "turn exited rc=$TURN_RC (log: $(tail -3 "$CASE_DIR/turn.log" 2>/dev/null | tr '\n' ' '))"; fi; }

# --- stubs ---------------------------------------------------------------

STUBS="$WORK/bin"
mkdir -p "$STUBS"

cat > "$STUBS/claude" <<'EOF'
#!/usr/bin/env bash
# Auto-mode preflight probes (stream-json) get a CLI-style init line
# reporting the effective permission mode; they are not turn attempts, so
# they are neither argv-recorded nor counted. A hard-reject host rejects
# the probe as well (it passes --permission-mode auto), so it yields no
# init line — the inconclusive path in claude_turn.sh.
for a in "$@"; do
  if [[ "$a" == "stream-json" ]]; then
    if [[ "${STUB_REJECT_AUTO:-0}" == "1" ]]; then
      echo "Error: auto mode is unavailable for your plan" >&2
      exit 1
    fi
    printf '{"type":"system","subtype":"init","permissionMode":"%s"}\n' \
      "${STUB_EFFECTIVE_PERMS:-auto}"
    exit 0
  fi
done
: > "$ARGV_FILE"
for a in "$@"; do printf '%s\n' "$a" >> "$ARGV_FILE"; done
printf 'x' >> "${ARGV_FILE}.calls"   # 1 byte per invocation
# Record the background-task wait ceiling the turn script exported; without
# it headless claude drops the final message (and the completion marker)
# when a backgrounded build outlives the CLI's 600s default.
printf '%s\n' "${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-unset}" > "${ARGV_FILE}.bgwait"
# Simulate a host/account where auto permission mode is unavailable: the
# real CLI rejects the flag at startup, before doing any work, with one of
# its startup-eligibility diagnostics.
if [[ "${STUB_REJECT_AUTO:-0}" == "1" ]]; then
  for a in "$@"; do
    if [[ "$a" == "--permission-mode" ]]; then
      echo "Error: auto mode is unavailable for your plan" >&2
      exit 1
    fi
  done
fi
# Simulate a turn that did real work, produced output, then died with stderr
# matching a startup-eligibility diagnostic — only the empty-stdout guard
# stands between this and a duplicate rerun.
if [[ "${STUB_FAIL_MIDRUN:-0}" == "1" ]]; then
  echo "partial turn output, no completion marker"
  echo "Error: auto mode is unavailable for your plan" >&2
  exit 1
fi
# Simulate the documented runtime classifier abort: side effects happened,
# stdout is EMPTY (text mode only prints the final response), and stderr
# mentions auto mode — the fallback must never rerun this turn.
if [[ "${STUB_RUNTIME_AUTO_ABORT:-0}" == "1" ]]; then
  touch "${ARGV_FILE}.side-effect"
  echo "Error: repeated permission blocks, so auto mode cannot determine the safety of this action" >&2
  exit 1
fi
echo "[CLAUDE_TURN: COMPLETE]"
EOF

cat > "$STUBS/codex" <<'EOF'
#!/usr/bin/env bash
: > "$ARGV_FILE"
for a in "$@"; do printf '%s\n' "$a" >> "$ARGV_FILE"; done
# Real `codex exec` writes a session rollout file recording its cwd; emulate
# it so the session-capture path (snapshot / discover with cwd binding /
# persist) is exercised. Also drop a DECOY root recorded for another checkout
# that sorts before the real one — a concurrent loop's interleaved root —
# so the fresh-capture assertions fail if discovery loses its cwd binding.
mkdir -p "$CODEX_HOME/sessions"
printf '{"payload":{"id":"foreign-root-uuid","cwd":"/other-checkout","source":"exec"}}\n' \
  > "$CODEX_HOME/sessions/rollout-a-decoy.jsonl"
printf '{"payload":{"id":"stub-session-uuid","cwd":"%s"}}\n' "$(pwd -P)" \
  > "$CODEX_HOME/sessions/rollout-stub.jsonl"
echo "[CODEX_ISSUES: BLOCKER=0 MAJOR=0 NIT=0]"
echo "[CODEX_VERDICT: APPROVED]"
EOF

# fetch_ai_thread hits gh twice (issue + inline comments). Emit one codex and
# one claude summary comment for the issues endpoint — claude_turn.sh needs a
# review to read, and both turn scripts verify their own summary landed after
# the turn. STUB_NO_*_SUMMARY knobs simulate a turn whose summary POST never
# landed (crash after inline-only posts / rejected POST); everything else
# returns empty.
cat > "$STUBS/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"/issues/"*"/comments"*)
    if [[ "${STUB_NO_CODEX_SUMMARY:-0}" != "1" ]]; then
      CX_ITER="${ITER:-1}"
      # Stale-thread shape: only an OLDER iteration's codex summary exists
      # (the current iter's summary POST never landed).
      [[ "${STUB_STALE_CODEX_SUMMARY:-0}" == "1" ]] && CX_ITER=0
      printf '{"surface":"issue","id":101,"path":null,"line":null,"in_reply_to_id":null,"created_at":"2026-01-01T00:00:00Z","body":"<!-- ai-loop:codex-reviewer iter=%s -->\\n\\n> [!IMPORTANT]\\n> **AUTOMATED REVIEW — AI agent (Codex Reviewer), iteration %s.**\\nStub codex review."}\n' "$CX_ITER" "$CX_ITER"
    fi
    # A tagged top-level note WITHOUT the summary wrapper — the shape an
    # inline finding takes when it loses its diff position and lands as a
    # general note. Its prose QUOTES the banner (as restatements do), so a
    # substring predicate would wrongly accept it; the structural predicate
    # must not.
    if [[ "${STUB_BANNERLESS_CODEX_SUMMARY:-0}" == "1" ]]; then
      printf '{"surface":"issue","id":103,"path":null,"line":null,"in_reply_to_id":null,"created_at":"2026-01-01T00:00:01Z","body":"<!-- ai-loop:codex-reviewer iter=%s -->\\n**[AI · Codex Reviewer · iter %s] [BLOCKER]**\\nOrphaned finding; the summary must open with > [!IMPORTANT] and **AUTOMATED REVIEW — AI agent (Codex Reviewer), iteration %s.** as its banner."}\n' "${ITER:-1}" "${ITER:-1}" "${ITER:-1}"
    fi
    if [[ "${STUB_NO_CLAUDE_SUMMARY:-0}" != "1" ]]; then
      printf '{"surface":"issue","id":102,"path":null,"line":null,"in_reply_to_id":null,"created_at":"2026-01-01T00:00:10Z","body":"<!-- ai-loop:claude-implementer iter=%s -->\\n\\n> [!NOTE]\\n> **AUTOMATED REPLY — AI agent (Claude Implementer), iteration %s.**\\nStub claude reply."}\n' "${ITER:-1}" "${ITER:-1}"
    fi
    ;;
esac
EOF
# glab: token resolution (preflight) and clone are the only orchestrator
# uses; everything else on GitLab goes through curl.
cat > "$STUBS/glab" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "config get token --host "*)
    # Emulate glab's env precedence: any ambient token env var shadows the
    # host-scoped config value (the exact behavior glab_config_get defuses
    # by clearing these before invoking glab).
    if [[ -n "${GITLAB_TOKEN:-}${GITLAB_ACCESS_TOKEN:-}${OAUTH_TOKEN:-}${GLAB_TOKEN:-}" ]]; then
      echo "${GITLAB_TOKEN:-${GITLAB_ACCESS_TOKEN:-${OAUTH_TOKEN:-$GLAB_TOKEN}}}"
      exit 0
    fi
    if [[ "${STUB_GLAB_NO_TOKEN:-0}" == "1" ]]; then exit 1; fi
    # Host-sensitive mode: glab keys host config by the exact authority
    # string used at login, so a PAT stored under 'host:443' is invisible
    # under the bare spelling. When set, only that exact --host key hits.
    if [[ -n "${STUB_GLAB_TOKEN_HOST:-}" && "$*" != *"--host $STUB_GLAB_TOKEN_HOST" ]]; then
      exit 1
    fi
    echo "stub-glab-token"
    ;;
  "config get is_oauth2 --host "*)
    # Emulate glab's generic env-override precedence for config keys:
    # GLAB_IS_OAUTH2 / GITLAB_IS_OAUTH2 shadow the stored per-host value
    # unless cleared.
    echo "${GLAB_IS_OAUTH2:-${GITLAB_IS_OAUTH2:-${STUB_GLAB_OAUTH:-false}}}"
    ;;
  "repo clone "*)
    # Create the target dir like real glab would, so tests asserting that a
    # code path did NOT clone have teeth (argv: repo clone SLUG DIR).
    if [[ -n "${4:-}" ]]; then mkdir -p "$4"; fi
    ;;
esac
EOF

# curl: minimal GitLab API v4. Routes on the URL; records mutations to
# $CURL_LOG when set ("METHOD URL BODY", body read from --data @-).
cat > "$STUBS/curl" <<'EOF'
#!/usr/bin/env bash
url=''; method=GET; body=''; prev=''; hdrs=()
for a in "$@"; do
  case "$prev" in
    -X)     method="$a" ;;
    --data) body="$a" ;;
    -H)     hdrs+=("$a") ;;
  esac
  [[ "$a" == http://* || "$a" == https://* ]] && url="$a"
  prev="$a"
done
if [[ "$body" == "@-" || "$body" == "-" ]]; then body="$(cat)"; fi
[[ -n "${CURL_LOG:-}" ]] && printf '%s %s %s\n' "$method" "$url" "$body" >> "$CURL_LOG"
[[ -n "${CURL_HDR_LOG:-}" ]] && printf '%s\n' ${hdrs[@]+"${hdrs[@]}"} >> "$CURL_HDR_LOG"
case "$method $url" in
  "GET "*"/api/v4/user")
    echo '{"username":"testuser"}'
    ;;
  "GET "*"/discussions"*)
    # One codex + one claude summary note (markers; both turn scripts verify
    # their own summary landed), one inline DiffNote thread with a claude
    # reply, one system note, one human note without a marker. The page is
    # short (<100), so the pagination loop stops after one fetch.
    cat <<PAYLOAD
[
 {"id":"disc-sum","notes":[{"id":201,"type":null,"system":false,"created_at":"2026-01-01T00:00:00Z","body":"<!-- ai-loop:codex-reviewer iter=${ITER:-1} -->\n\n> [!IMPORTANT]\n> **AUTOMATED REVIEW — AI agent (Codex Reviewer), iteration ${ITER:-1}.**\nStub codex review.","position":null}]},
 {"id":"disc-claude-sum","notes":[{"id":202,"type":null,"system":false,"created_at":"2026-01-01T00:00:05Z","body":"<!-- ai-loop:claude-implementer iter=${ITER:-1} -->\n\n> [!NOTE]\n> **AUTOMATED REPLY — AI agent (Claude Implementer), iteration ${ITER:-1}.**\nStub claude reply.","position":null}]},
 {"id":"disc-inline","notes":[
   {"id":301,"type":"DiffNote","system":false,"created_at":"2026-01-01T00:00:01Z","body":"<!-- ai-loop:codex-reviewer iter=${ITER:-1} -->\nInline finding.","position":{"new_path":"src/a.c","new_line":12}},
   {"id":302,"type":"DiscussionNote","system":false,"created_at":"2026-01-01T00:00:02Z","body":"<!-- ai-loop:claude-implementer iter=0 -->\nOld reply.","position":null}]},
 {"id":"disc-sys","notes":[{"id":401,"type":null,"system":true,"created_at":"2026-01-01T00:00:03Z","body":"added 1 commit"}]},
 {"id":"disc-human","notes":[{"id":501,"type":null,"system":false,"created_at":"2026-01-01T00:00:04Z","body":"human comment"}]}
]
PAYLOAD
    ;;
  "GET "*"/merge_requests/"*)
    # Gated: most tests want the terminal "MR is not open" die; the
    # --preflight-only tests need a real open MR.
    if [[ "${STUB_MR_OPEN:-0}" == "1" ]]; then
      echo '{"state":"opened","source_branch":"feat/x","target_branch":"main","web_url":"https://gl.example/g/p/-/merge_requests/9","source_project_id":1,"target_project_id":1}'
    else
      echo '{}'
    fi
    ;;
  "POST "*)
    echo '{"id":"stub-post"}'
    ;;
  *)
    echo '{}'
    ;;
esac
EOF
chmod +x "$STUBS/claude" "$STUBS/codex" "$STUBS/gh" "$STUBS/glab" "$STUBS/curl"

# --- turn runners --------------------------------------------------------

new_case() {
  CASE_DIR="$WORK/case-$1"
  mkdir -p "$CASE_DIR/state" "$CASE_DIR/repo" "$CASE_DIR/codex-home/sessions"
  ARGV="$CASE_DIR/argv"
}

# run_turn <claude|codex> [VAR=VALUE ...] — runs the turn script with a
# sanitized env (so a live loop's exported CODEX_*/CLAUDE_* can't leak in).
run_turn() {
  local script="$1"; shift
  env -i \
    PATH="$STUBS:/usr/bin:/bin" \
    HOME="$CASE_DIR" \
    ARGV_FILE="$ARGV" \
    CODEX_HOME="$CASE_DIR/codex-home" \
    REPO_OWNER=o REPO_NAME=r PR_NUMBER=1 \
    REPO_DIR="$CASE_DIR/repo" STATE_DIR="$CASE_DIR/state" \
    BASE_REF=main HEAD_REF=feature/x ITER=1 MAX_ITER=6 \
    GH_USER=testuser REVIEW_ONLY=0 HAS_CONTEXT=0 \
    "$@" \
    bash "$ROOT/${script}_turn.sh" > "$CASE_DIR/turn.log" 2>&1
  TURN_RC=$?
}

# run_run_sh [VAR=VALUE ...] [args ...] — run.sh with no GH_TOKEN, so any
# github-forge invocation that survives flag validation dies in preflight
# ("GH_TOKEN/GITHUB_TOKEN not set") before touching git or the network.
# Leading VAR=VALUE words become env for the run (e.g. STUB_GLAB_NO_TOKEN=1).
run_run_sh() {
  local envs=()
  while [[ $# -gt 0 && "$1" == [A-Z_]*=* ]]; do envs+=("$1"); shift; done
  # ${arr[@]+...} keeps the empty-array expansion safe under `set -u` on
  # bash 3.2 (stock macOS).
  env -i PATH="$STUBS:/usr/bin:/bin" HOME="$WORK" ${envs[@]+"${envs[@]}"} \
    bash "$ROOT/run.sh" "$@" > "$WORK/run.out" 2> "$WORK/run.err"
  RUN_RC=$?
}
assert_dies_with() {  # expected stderr substring
  if [[ "$RUN_RC" -eq 0 ]]; then bad "run.sh unexpectedly exited 0"; return; fi
  if grep -Fq -- "$1" "$WORK/run.err"; then ok; else bad "stderr missing '$1' (got: $(tail -1 "$WORK/run.err"))"; fi
}
assert_prints() {  # expected exact stdout line (run.sh must exit 0)
  if [[ "$RUN_RC" -ne 0 ]]; then bad "run.sh exited rc=$RUN_RC ($(tail -1 "$WORK/run.err"))"; return; fi
  if grep -Fxq -- "$1" "$WORK/run.out"; then ok; else bad "stdout missing line '$1' (got: $(cat "$WORK/run.out" | tr '\n' ' '))"; fi
}

# --- resolve_codex_effort ------------------------------------------------

. "$ROOT/lib/common.sh"

t "resolve: sol adaptive default is ultra"
assert_eq "$(resolve_codex_effort gpt-5.6-sol '')" ultra
t "resolve: terra adaptive default is ultra"
assert_eq "$(resolve_codex_effort gpt-5.6-terra '')" ultra
t "resolve: unknown model adaptive default is off (no forced level)"
assert_eq "$(resolve_codex_effort gpt-oss-120b '')" off
t "resolve: model 'off' adaptive default is off"
assert_eq "$(resolve_codex_effort off '')" off
t "resolve: explicit effort wins on sol"
assert_eq "$(resolve_codex_effort gpt-5.6-sol high)" high
t "resolve: explicit effort wins on unknown model"
assert_eq "$(resolve_codex_effort gpt-oss-120b xhigh)" xhigh
t "resolve: explicit off stays off"
assert_eq "$(resolve_codex_effort gpt-5.6-sol off)" off

# --- normalize_remote_slug -------------------------------------------------
# Clone-guard slug extraction across the remote URL shapes gh/glab produce.

t "slug: scp-style github remote"
assert_eq "$(normalize_remote_slug 'git@github.com:o/r.git')" o/r
t "slug: https remote with .git"
assert_eq "$(normalize_remote_slug 'https://github.com/o/r.git')" o/r
t "slug: https remote without .git"
assert_eq "$(normalize_remote_slug 'https://github.com/o/r')" o/r
t "slug: ssh:// gitlab remote with subgroups"
assert_eq "$(normalize_remote_slug 'ssh://git@gitlab.example.com/group/sub/proj.git')" group/sub/proj
t "slug: ssh:// remote with a port"
assert_eq "$(normalize_remote_slug 'ssh://git@gitlab.example.com:2222/g/p.git')" g/p
t "slug: scp-style gitlab remote with subgroups"
assert_eq "$(normalize_remote_slug 'git@gitlab-master.example.com:group/sub/proj.git')" group/sub/proj
t "slug: userless scp-style remote"
assert_eq "$(normalize_remote_slug 'github.com:o/r.git')" o/r
t "slug: scp-style remote with a non-git user"
assert_eq "$(normalize_remote_slug 'alice@gitlab.example.com:g/p.git')" g/p
t "slug: ssh:// remote without a user"
assert_eq "$(normalize_remote_slug 'ssh://gitlab.example.com/g/p.git')" g/p
t "slug: file:// URL keeps its scheme (mismatch caught by slug check)"
assert_eq "$(normalize_remote_slug 'file:///g/p.git')" "file:///g/p"
t "slug: relative local path keeps its path (mismatch caught by slug check)"
assert_eq "$(normalize_remote_slug 'dir/sub:odd.git')" dir/sub:odd

# --- normalize_remote_host --------------------------------------------------
# Host extraction for the clone guard's forge/host identity check.

t "host: scp-style remote"
assert_eq "$(normalize_remote_host 'git@github.com:o/r.git')" github.com
t "host: https remote"
assert_eq "$(normalize_remote_host 'https://gitlab.example.com/g/p.git')" gitlab.example.com
t "host: https remote with credentials"
assert_eq "$(normalize_remote_host 'https://user@gitlab.example.com/g/p.git')" gitlab.example.com
t "host: https remote with a port"
assert_eq "$(normalize_remote_host 'https://gl.example:8443/g/p.git')" gl.example
t "host: ssh:// remote with a port"
assert_eq "$(normalize_remote_host 'ssh://git@gitlab.example.com:2222/g/p.git')" gitlab.example.com
t "host: local path yields nothing (rejected by the clone guard)"
assert_eq "$(normalize_remote_host '/srv/git/mirror.git')" ""
t "host: userless scp-style remote parses its host"
assert_eq "$(normalize_remote_host 'github.com:o/r.git')" github.com
t "host: relative local path with a slash before the colon yields nothing"
assert_eq "$(normalize_remote_host 'dir/sub:odd.git')" ""
t "host: file:// URL yields nothing (not a forge endpoint)"
assert_eq "$(normalize_remote_host 'file:///srv/git/g/p.git')" ""
t "host: port stripped from a plain host string"
assert_eq "$(host_sans_port 'gitlab.lab:8929')" gitlab.lab

t "authority: http remote keeps its non-default port"
assert_eq "$(normalize_remote_http_authority 'http://gitlab.lab:8929/g/p.git')" gitlab.lab:8929
t "authority: https remote drops an explicit default port"
assert_eq "$(normalize_remote_http_authority 'https://gl.example:443/g/p.git')" gl.example
t "authority: leading-zero default port drops numerically"
assert_eq "$(normalize_remote_http_authority 'https://gl.example:0443/g/p.git')" gl.example
t "authority: leading-zero non-default port normalizes its digits"
assert_eq "$(normalize_remote_http_authority 'http://gitlab.lab:08929/g/p.git')" gitlab.lab:8929
t "authority: hostname case folds (DNS matching is case-insensitive)"
assert_eq "$(normalize_remote_http_authority 'https://GL.EXAMPLE:443/g/p.git')" gl.example
t "host: ssh hostname case folds"
assert_eq "$(normalize_remote_host 'git@GL.EXAMPLE:g/p.git')" gl.example
t "host: ssh:// URL hostname case folds (host_sans_port path)"
assert_eq "$(normalize_remote_host 'ssh://git@GL.EXAMPLE:2222/g/p.git')" gl.example
t "host: userless scp hostname case folds"
assert_eq "$(normalize_remote_host 'GL.EXAMPLE:g/p.git')" gl.example
t "authority: userinfo is stripped"
assert_eq "$(normalize_remote_http_authority 'https://user@gl.example/g/p.git')" gl.example
t "authority: ssh remote yields nothing (hostname comparison instead)"
assert_eq "$(normalize_remote_http_authority 'ssh://git@gl.example:2222/g/p.git')" ""

# --- run_with_timeout -------------------------------------------------------
# The probe watchdog must be portable: GNU timeout, gtimeout (brew coreutils
# on macOS), or the pure-bash fallback when neither exists (stock macOS).

t "watchdog: passes through a zero exit status"
if run_with_timeout 5 true; then ok; else bad "true under watchdog returned nonzero"; fi

t "watchdog: passes through a failure exit status"
if run_with_timeout 5 false; then bad "false under watchdog returned zero"; else ok; fi

t "watchdog: kills a hung command"
WD_START=$SECONDS
if run_with_timeout 1 sleep 30 2>/dev/null; then bad "hung command not killed"; else ok; fi
t "watchdog: hung-command kill is prompt"
if (( SECONDS - WD_START < 10 )); then ok; else bad "kill took $((SECONDS - WD_START))s"; fi

FBIN="$WORK/fallback-bin"
mkdir -p "$FBIN"
ln -s "$(command -v sleep)" "$FBIN/sleep"
ln -s "$(command -v head)" "$FBIN/head"
BASH_BIN="$(command -v bash)"

t "watchdog: fallback without timeout/gtimeout passes through exit status"
if env -i PATH="$FBIN" "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; run_with_timeout 5 sleep 0"; then
  ok
else
  bad "fallback returned nonzero for a fast command"
fi

t "watchdog: fallback without timeout/gtimeout kills a hung command"
WD_START=$SECONDS
if env -i PATH="$FBIN" "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; run_with_timeout 1 sleep 30" 2>/dev/null; then
  bad "fallback did not kill the hung command"
else
  ok
fi
t "watchdog: fallback kill is prompt"
if (( SECONDS - WD_START < 10 )); then ok; else bad "fallback kill took $((SECONDS - WD_START))s"; fi

t "watchdog: fallback does not hold the stdout pipe open after the command exits"
# The 1s command guarantees the watchdog subshell has forked its sleep before
# being killed, so without stdio detachment the orphan would deterministically
# hold the pipe and block the reader for the remaining ~7s.
WD_START=$SECONDS
env -i PATH="$FBIN" "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; run_with_timeout 8 sleep 1 | head -1" >/dev/null 2>&1
if (( SECONDS - WD_START < 5 )); then
  ok
else
  bad "pipeline reader blocked $((SECONDS - WD_START))s on the watchdog's inherited pipe fd"
fi

# --- discover_new_codex_session_id ----------------------------------------
# A gpt-5.6 review can spawn sub-agent threads, each writing its own (newer)
# rollout file; `codex exec resume` rejects sub-agent ids, so discovery must
# return the ROOT session even when a sub-agent file is newest.

DISC="$WORK/discover"
mkdir -p "$DISC/sessions/d"
: > "$DISC/before-empty"
printf '{"payload":{"id":"root-uuid","source":"exec"}}\n' \
  > "$DISC/sessions/d/rollout-2026-01-01T00-00-01-root.jsonl"
printf '{"payload":{"id":"sub-uuid","source":{"subagent":{"thread_spawn":{"parent_thread_id":"root-uuid","depth":1}}}}}\n' \
  > "$DISC/sessions/d/rollout-2026-01-01T00-00-02-sub.jsonl"

t "discover: picks the root session over a newer sub-agent rollout"
assert_eq "$(CODEX_HOME="$DISC" discover_new_codex_session_id "$DISC/before-empty")" root-uuid

t "discover: fails when only sub-agent rollouts are new"
CODEX_HOME="$DISC" snapshot_codex_sessions "$DISC/before-full"
printf '{"payload":{"id":"sub2-uuid","source":{"subagent":{"thread_spawn":{"parent_thread_id":"root-uuid","depth":1}}}}}\n' \
  > "$DISC/sessions/d/rollout-2026-01-01T00-00-03-sub2.jsonl"
if CODEX_HOME="$DISC" discover_new_codex_session_id "$DISC/before-full" >/dev/null 2>&1; then
  bad "unexpectedly discovered an id from sub-agent-only rollouts"
else
  ok
fi

t "discover: treats rollouts without a source field as root (older codex)"
DISC2="$WORK/discover2"
mkdir -p "$DISC2/sessions"
: > "$DISC2/before-empty"
printf '{"payload":{"id":"legacy-uuid"}}\n' \
  > "$DISC2/sessions/rollout-2026-01-01T00-00-01-legacy.jsonl"
assert_eq "$(CODEX_HOME="$DISC2" discover_new_codex_session_id "$DISC2/before-empty")" legacy-uuid

# Concurrent loops: both loops' new root rollouts appear in the shared
# sessions dir; cwd binding must pick this checkout's root, not the first
# one by sort order.
DISC3="$WORK/discover3"
mkdir -p "$DISC3/sessions"
: > "$DISC3/before-empty"
printf '{"payload":{"id":"root-a-uuid","cwd":"/checkout-a","source":"exec"}}\n' \
  > "$DISC3/sessions/rollout-2026-01-01T00-00-01-a.jsonl"
printf '{"payload":{"id":"root-b-uuid","cwd":"/checkout-b","source":"exec"}}\n' \
  > "$DISC3/sessions/rollout-2026-01-01T00-00-02-b.jsonl"

t "discover: interleaved roots — cwd binding picks this checkout's root"
assert_eq "$(CODEX_HOME="$DISC3" discover_new_codex_session_id "$DISC3/before-empty" /checkout-b)" root-b-uuid

t "discover: cwd binding fails closed on rollouts without a cwd (older codex)"
if CODEX_HOME="$DISC2" discover_new_codex_session_id "$DISC2/before-empty" /anywhere >/dev/null 2>&1; then
  bad "unexpectedly captured a root that cannot prove checkout ownership"
else
  ok
fi

# --- resolve_codex_root_session_id -----------------------------------------
# Stored ids from older selectors may point at a sub-agent rollout (which
# `codex exec resume` rejects) or another checkout's root; resolution must
# migrate or reject instead of leaving the loop wedged.

printf '{"payload":{"id":"sub3-uuid","source":{"subagent":{"thread_spawn":{"parent_thread_id":"sub-uuid","depth":2}}}}}\n' \
  > "$DISC/sessions/d/rollout-2026-01-01T00-00-04-sub3.jsonl"

t "resolve-session: root id resolves to itself"
assert_eq "$(CODEX_HOME="$DISC" resolve_codex_root_session_id root-uuid)" root-uuid

t "resolve-session: sub-agent id migrates to its parent root"
assert_eq "$(CODEX_HOME="$DISC" resolve_codex_root_session_id sub-uuid)" root-uuid

t "resolve-session: depth-2 sub-agent follows the chain to the root"
assert_eq "$(CODEX_HOME="$DISC" resolve_codex_root_session_id sub3-uuid)" root-uuid

t "resolve-session: unknown id fails"
if CODEX_HOME="$DISC" resolve_codex_root_session_id no-such-uuid >/dev/null 2>&1; then
  bad "unexpectedly resolved an unknown id"
else
  ok
fi

t "resolve-session: root recorded for another checkout is rejected"
if CODEX_HOME="$DISC3" resolve_codex_root_session_id root-a-uuid /checkout-b >/dev/null 2>&1; then
  bad "unexpectedly accepted a root bound to a different cwd"
else
  ok
fi

t "resolve-session: cwd binding fails closed on roots without a cwd"
if CODEX_HOME="$DISC" resolve_codex_root_session_id root-uuid /anywhere >/dev/null 2>&1; then
  bad "unexpectedly validated a root that cannot prove checkout ownership"
else
  ok
fi

# The poisoned-state shape the resume validation exists for: a sub-agent id
# captured by the old unbound discovery whose parent chain ends at ANOTHER
# checkout's root. The cwd check must hold after following the chain, not
# just on the stored id itself.
printf '{"payload":{"id":"sub-a-uuid","source":{"subagent":{"thread_spawn":{"parent_thread_id":"root-a-uuid","depth":1}}}}}\n' \
  > "$DISC3/sessions/rollout-2026-01-01T00-00-03-sub-a.jsonl"

t "resolve-session: sub-agent chain ending at a foreign root is rejected"
if CODEX_HOME="$DISC3" resolve_codex_root_session_id sub-a-uuid /checkout-b >/dev/null 2>&1; then
  bad "unexpectedly migrated to another checkout's root"
else
  ok
fi

t "resolve-session: sub-agent chain ending at this checkout's root migrates"
assert_eq "$(CODEX_HOME="$DISC3" resolve_codex_root_session_id sub-a-uuid /checkout-a)" root-a-uuid

# --- claude_turn.sh ------------------------------------------------------

t "claude: defaults (fable + ultracode + auto perms)"
new_case claude-default
run_turn claude
assert_rc0
assert_pair "$ARGV" --model fable
assert_value_has "$ARGV" --settings '"ultracode": true'
assert_no_line "$ARGV" --effort
assert_pair "$ARGV" --permission-mode auto
assert_no_line "$ARGV" --dangerously-skip-permissions
assert_value_lacks "$ARGV" --settings acceptEdits
assert_pair "$ARGV" --add-dir "$CASE_DIR/repo"
assert_pair "$ARGV" --add-dir "$CASE_DIR/state"

t "claude: fresh session pins --session-id"
assert_pair "$ARGV" --session-id "$(cat "$CASE_DIR/state/claude.session.uuid")"
assert_no_line "$ARGV" --resume

t "claude: bare effort level uses --effort and drops the settings payload"
new_case claude-xhigh
run_turn claude CLAUDE_EFFORT=xhigh
assert_rc0
assert_pair "$ARGV" --effort xhigh
assert_no_line "$ARGV" --settings

t "claude: model/effort off omits --model and --effort"
new_case claude-off
run_turn claude CLAUDE_MODEL=off CLAUDE_EFFORT=off
assert_rc0
assert_no_line "$ARGV" --model
assert_no_line "$ARGV" --effort
assert_no_line "$ARGV" --settings
assert_pair "$ARGV" --permission-mode auto

t "claude: bypass perms use skip-permissions plus the settings safety net"
new_case claude-bypass
run_turn claude CLAUDE_PERMS=bypass
assert_rc0
assert_line "$ARGV" --dangerously-skip-permissions
assert_no_line "$ARGV" --permission-mode
assert_value_has "$ARGV" --settings '"ultracode": true'
assert_value_has "$ARGV" --settings '"defaultMode": "acceptEdits"'

t "claude: perms off leaves permission handling untouched"
new_case claude-perms-off
run_turn claude CLAUDE_PERMS=off
assert_rc0
assert_no_line "$ARGV" --permission-mode
assert_no_line "$ARGV" --dangerously-skip-permissions

t "claude: silently downgraded auto mode selects the settings safety net upfront"
new_case claude-auto-downgraded
run_turn claude STUB_EFFECTIVE_PERMS=default
assert_rc0
assert_no_line "$ARGV" --permission-mode
assert_no_line "$ARGV" --dangerously-skip-permissions
assert_value_has "$ARGV" --settings '"defaultMode": "acceptEdits"'
assert_eq "$(wc -c < "$ARGV.calls" | tr -d ' ')" 1

t "claude: downgrade probe result is cached per PR and model"
assert_eq "$(cat "$CASE_DIR/state/claude.automode.effective" 2>/dev/null)" "default fable"
run_turn claude STUB_EFFECTIVE_PERMS=auto
assert_rc0
assert_no_line "$ARGV" --permission-mode

t "claude: eligible auto mode keeps classifier gating after the probe"
new_case claude-auto-eligible
run_turn claude STUB_EFFECTIVE_PERMS=auto
assert_rc0
assert_pair "$ARGV" --permission-mode auto
assert_eq "$(cat "$CASE_DIR/state/claude.automode.effective" 2>/dev/null)" "auto fable"

t "claude: changing the model re-probes instead of reusing cached eligibility"
new_case claude-cache-model
run_turn claude CLAUDE_MODEL=model-a STUB_EFFECTIVE_PERMS=auto
assert_rc0
assert_pair "$ARGV" --permission-mode auto
run_turn claude CLAUDE_MODEL=model-b STUB_EFFECTIVE_PERMS=default
assert_rc0
assert_no_line "$ARGV" --permission-mode
assert_value_has "$ARGV" --settings '"defaultMode": "acceptEdits"'
assert_eq "$(cat "$CASE_DIR/state/claude.automode.effective" 2>/dev/null)" "default model-b"

t "claude: switching back to an eligible model restores classifier gating"
run_turn claude CLAUDE_MODEL=model-a STUB_EFFECTIVE_PERMS=auto
assert_rc0
assert_pair "$ARGV" --permission-mode auto

t "claude: a whitespace model's cache line cannot false-hit a prefix model"
new_case claude-cache-space
run_turn claude 'CLAUDE_MODEL=fable extra' STUB_EFFECTIVE_PERMS=auto
assert_rc0
run_turn claude CLAUDE_MODEL=fable STUB_EFFECTIVE_PERMS=auto
assert_rc0
assert_pair "$ARGV" --permission-mode auto
assert_eq "$(cat "$CASE_DIR/state/claude.automode.effective" 2>/dev/null)" "auto fable"

t "claude: rejected auto mode falls back to the settings safety net"
new_case claude-auto-fallback
run_turn claude STUB_REJECT_AUTO=1
assert_rc0
assert_no_line "$ARGV" --permission-mode
assert_no_line "$ARGV" --dangerously-skip-permissions
assert_value_has "$ARGV" --settings '"ultracode": true'
assert_value_has "$ARGV" --settings '"defaultMode": "acceptEdits"'
assert_eq "$(wc -c < "$ARGV.calls" | tr -d ' ')" 2

t "claude: inconclusive probe stays optimistic and caches nothing"
if [[ -f "$CASE_DIR/state/claude.automode.effective" ]]; then
  bad "cache written from an inconclusive (rejected) probe"
else
  ok
fi

t "claude: rejected auto attempt's stderr is preserved for audit"
if [[ -f "$CASE_DIR/state/iter-01/claude.stderr.auto-rejected" ]]; then
  ok
else
  bad "missing claude.stderr.auto-rejected from the rejected first attempt"
fi

t "claude: a mid-run failure with output never triggers the auto fallback"
new_case claude-midrun-fail
run_turn claude STUB_FAIL_MIDRUN=1
assert_eq "$TURN_RC" 1
assert_pair "$ARGV" --permission-mode auto
assert_eq "$(wc -c < "$ARGV.calls" | tr -d ' ')" 1
if [[ -f "$CASE_DIR/state/iter-01/claude.stderr.auto-rejected" ]]; then
  bad "fallback fired on a turn that had already produced output"
else
  ok
fi

t "claude: runtime auto abort after side effects never triggers the fallback"
new_case claude-runtime-abort
run_turn claude STUB_RUNTIME_AUTO_ABORT=1
assert_eq "$TURN_RC" 1
assert_pair "$ARGV" --permission-mode auto
assert_eq "$(wc -c < "$ARGV.calls" | tr -d ' ')" 1
if [[ -f "$CASE_DIR/state/iter-01/claude.stderr.auto-rejected" ]]; then
  bad "fallback fired on the documented runtime classifier abort"
else
  ok
fi

t "claude: seeded session resumes with --resume"
new_case claude-resume
echo "11111111-2222-3333-4444-555555555555" > "$CASE_DIR/state/claude.session.uuid"
run_turn claude
assert_rc0
assert_pair "$ARGV" --resume 11111111-2222-3333-4444-555555555555
assert_no_line "$ARGV" --session-id

t "claude: turn raises the background-task wait ceiling to 60 min"
new_case claude-bgwait-default
run_turn claude
assert_rc0
assert_eq "$(cat "$ARGV.bgwait" 2>/dev/null)" 3600000

t "claude: yield-style tools are disallowed in one-shot turns"
assert_pair "$ARGV" --disallowedTools "ScheduleWakeup,Monitor,CronCreate"

t "claude: background-task wait ceiling honors the env override"
new_case claude-bgwait-override
run_turn claude CLAUDE_BG_WAIT_CEILING_MS=120000
assert_rc0
assert_eq "$(cat "$ARGV.bgwait" 2>/dev/null)" 120000

# --- codex_turn.sh -------------------------------------------------------

t "codex: defaults (gpt-5.6-sol @ ultra, fast tier)"
new_case codex-default
run_turn codex
assert_rc0
assert_line "$ARGV" exec
assert_pair "$ARGV" -m gpt-5.6-sol
assert_pair "$ARGV" -c 'model_reasoning_effort="ultra"'
assert_pair "$ARGV" -c 'service_tier="fast"'
assert_line "$ARGV" --yolo
assert_line "$ARGV" --skip-git-repo-check
assert_no_line "$ARGV" resume

t "codex: fresh run captures the session id from the rollout file"
assert_eq "$(cat "$CASE_DIR/state/codex.session.id" 2>/dev/null)" stub-session-uuid

t "codex: non-sol model with unset effort forces no reasoning level"
new_case codex-alt-model
run_turn codex CODEX_MODEL=gpt-oss-120b
assert_rc0
assert_pair "$ARGV" -m gpt-oss-120b
assert_no_substr "$ARGV" model_reasoning_effort
assert_pair "$ARGV" -c 'service_tier="fast"'

t "codex: explicit effort wins on non-sol model"
new_case codex-alt-explicit
run_turn codex CODEX_MODEL=gpt-oss-120b CODEX_EFFORT=high
assert_rc0
assert_pair "$ARGV" -c 'model_reasoning_effort="high"'

t "codex: explicit effort wins over sol's ultra default"
new_case codex-sol-explicit
run_turn codex CODEX_EFFORT=xhigh
assert_rc0
assert_pair "$ARGV" -c 'model_reasoning_effort="xhigh"'
assert_no_substr "$ARGV" ultra

t "codex: all knobs off omit -m / effort / tier"
new_case codex-off
run_turn codex CODEX_MODEL=off CODEX_EFFORT=off CODEX_TIER=off
assert_rc0
assert_no_line "$ARGV" -m
assert_no_substr "$ARGV" model_reasoning_effort
assert_no_substr "$ARGV" service_tier
assert_line "$ARGV" --yolo

t "codex: seeded root session resumes with 'exec resume <id>'"
new_case codex-resume
printf '{"payload":{"id":"cafebabe-dead-beef-sess","source":"exec","cwd":"%s"}}\n' \
    "$(cd "$CASE_DIR/repo" && pwd -P)" \
  > "$CASE_DIR/codex-home/sessions/rollout-2026-01-01T00-00-01-seed.jsonl"
echo "cafebabe-dead-beef-sess" > "$CASE_DIR/state/codex.session.id"
run_turn codex
assert_rc0
assert_pair "$ARGV" exec resume
assert_pair "$ARGV" resume cafebabe-dead-beef-sess

t "codex: resume keeps the seeded session id"
assert_eq "$(cat "$CASE_DIR/state/codex.session.id" 2>/dev/null)" cafebabe-dead-beef-sess

t "codex: stored sub-agent session id migrates to its root before resume"
new_case codex-migrate
printf '{"payload":{"id":"old-root-uuid","source":"exec","cwd":"%s"}}\n' \
    "$(cd "$CASE_DIR/repo" && pwd -P)" \
  > "$CASE_DIR/codex-home/sessions/rollout-2026-01-01T00-00-01-root.jsonl"
printf '{"payload":{"id":"stale-sub-uuid","source":{"subagent":{"thread_spawn":{"parent_thread_id":"old-root-uuid","depth":1}}}}}\n' \
  > "$CASE_DIR/codex-home/sessions/rollout-2026-01-01T00-00-02-sub.jsonl"
echo "stale-sub-uuid" > "$CASE_DIR/state/codex.session.id"
run_turn codex
assert_rc0
assert_pair "$ARGV" resume old-root-uuid
assert_eq "$(cat "$CASE_DIR/state/codex.session.id" 2>/dev/null)" old-root-uuid

t "codex: unresumable stored session id is discarded and a fresh session captured"
new_case codex-stale
echo "gone-uuid" > "$CASE_DIR/state/codex.session.id"
run_turn codex
assert_rc0
assert_no_line "$ARGV" resume
assert_eq "$(cat "$CASE_DIR/state/codex.session.id" 2>/dev/null)" stub-session-uuid

t "codex: stored root recorded for another checkout is discarded, not hijacked"
new_case codex-foreign
printf '{"payload":{"id":"other-loop-root","source":"exec","cwd":"/other-checkout"}}\n' \
  > "$CASE_DIR/codex-home/sessions/rollout-2026-01-01T00-00-01-other.jsonl"
echo "other-loop-root" > "$CASE_DIR/state/codex.session.id"
run_turn codex
assert_rc0
assert_no_line "$ARGV" resume
assert_eq "$(cat "$CASE_DIR/state/codex.session.id" 2>/dev/null)" stub-session-uuid

t "codex: stored root without a recorded cwd is discarded (fail closed)"
new_case codex-nocwd
printf '{"payload":{"id":"legacy-root-uuid","source":"exec"}}\n' \
  > "$CASE_DIR/codex-home/sessions/rollout-2026-01-01T00-00-01-legacy.jsonl"
echo "legacy-root-uuid" > "$CASE_DIR/state/codex.session.id"
run_turn codex
assert_rc0
assert_no_line "$ARGV" resume
assert_eq "$(cat "$CASE_DIR/state/codex.session.id" 2>/dev/null)" stub-session-uuid

t "codex: session persistence survives inherited CDPATH with a relative --dir"
new_case codex-cdpath
printf '{"payload":{"id":"cafe-cdpath-sess","source":"exec","cwd":"%s"}}\n' \
    "$(cd "$CASE_DIR/repo" && pwd -P)" \
  > "$CASE_DIR/codex-home/sessions/rollout-2026-01-01T00-00-01-seed.jsonl"
echo "cafe-cdpath-sess" > "$CASE_DIR/state/codex.session.id"
# Bespoke invocation: relative REPO_DIR resolved from $CASE_DIR, with a
# hostile CDPATH that makes every successful relative `cd` echo its
# destination — canonicalization must still produce a single clean path.
( cd "$CASE_DIR" && env -i \
    PATH="$STUBS:/usr/bin:/bin" \
    HOME="$CASE_DIR" \
    ARGV_FILE="$CASE_DIR/argv" \
    CODEX_HOME="$CASE_DIR/codex-home" \
    CDPATH=".:$WORK" \
    REPO_OWNER=o REPO_NAME=r PR_NUMBER=1 \
    REPO_DIR=repo STATE_DIR="$CASE_DIR/state" \
    BASE_REF=main HEAD_REF=feature/x ITER=1 MAX_ITER=6 \
    GH_USER=testuser REVIEW_ONLY=0 HAS_CONTEXT=0 \
    bash "$ROOT/codex_turn.sh" > "$CASE_DIR/turn.log" 2>&1 )
TURN_RC=$?
assert_rc0
assert_pair "$ARGV" resume cafe-cdpath-sess
assert_eq "$(cat "$CASE_DIR/state/codex.session.id" 2>/dev/null)" cafe-cdpath-sess

# --- summary-as-completion enforcement --------------------------------------
# The summary comment is each turn's completion contract: the resume
# high-water counts only summaries (inline-only turns are incomplete), and
# both turn scripts refetch the thread to verify their own summary landed —
# a crash after inline-only posts, or a rejected summary POST, must fail the
# turn instead of advancing the loop past an incomplete review/response.

t "resume high-water: only structural summary roots advance it"
# iter 1: real summary (issue root, marker first, alert + banner as first
# visible lines) — counts. iter 2: structurally perfect body but inline
# surface — excluded. iter 3: structurally perfect body but a reply in a
# summary thread — excluded. iter 5: tagged issue ROOT whose inline-style
# prose QUOTES the banner (the shape of a restatement that lost its diff
# position) — the structural predicate excludes what a substring check
# would have accepted. iter 6: alert+banner present but the marker is not
# the first line — excluded.
HW=$(env -i PATH="$STUBS:/usr/bin:/bin" "$BASH_BIN" -c "
  . '$ROOT/lib/common.sh'
  fetch_ai_thread() {
    printf '%s\n' '{\"tag\":\"ai-loop:codex-reviewer\",\"iter\":1,\"surface\":\"issue\",\"in_reply_to_id\":null,\"body\":\"<!-- ai-loop:codex-reviewer iter=1 -->\\n\\n> [!IMPORTANT]\\n> **AUTOMATED REVIEW — AI agent (Codex Reviewer), iteration 1.**\\nSummary text.\"}'
    printf '%s\n' '{\"tag\":\"ai-loop:codex-reviewer\",\"iter\":2,\"surface\":\"inline\",\"in_reply_to_id\":null,\"body\":\"<!-- ai-loop:codex-reviewer iter=2 -->\\n\\n> [!IMPORTANT]\\n> **AUTOMATED REVIEW — AI agent (Codex Reviewer), iteration 2.**\\nSummary text.\"}'
    printf '%s\n' '{\"tag\":\"ai-loop:codex-reviewer\",\"iter\":3,\"surface\":\"issue\",\"in_reply_to_id\":201,\"body\":\"<!-- ai-loop:codex-reviewer iter=3 -->\\n\\n> [!IMPORTANT]\\n> **AUTOMATED REVIEW — AI agent (Codex Reviewer), iteration 3.**\\nSummary text.\"}'
    printf '%s\n' '{\"tag\":\"ai-loop:codex-reviewer\",\"iter\":5,\"surface\":\"issue\",\"in_reply_to_id\":null,\"body\":\"<!-- ai-loop:codex-reviewer iter=5 -->\\n**[AI · Codex Reviewer · iter 5] [BLOCKER]**\\nRestating: the summary must open with > [!IMPORTANT] and **AUTOMATED REVIEW — AI agent (Codex Reviewer), iteration 5.** as its banner.\"}'
    printf '%s\n' '{\"tag\":\"ai-loop:codex-reviewer\",\"iter\":6,\"surface\":\"issue\",\"in_reply_to_id\":null,\"body\":\"preamble\\n<!-- ai-loop:codex-reviewer iter=6 -->\\n\\n> [!IMPORTANT]\\n> **AUTOMATED REVIEW — AI agent (Codex Reviewer), iteration 6.**\\nSummary text.\"}'
  }
  latest_ai_comment_iter codex")
assert_eq "$HW" 1

t "codex: turn fails when its summary never landed despite an APPROVED stdout"
new_case codex-no-summary
run_turn codex STUB_NO_CODEX_SUMMARY=1
assert_eq "$TURN_RC" 1

t "codex: a tagged general note without the summary banner is not a completed turn"
new_case codex-bannerless
run_turn codex STUB_NO_CODEX_SUMMARY=1 STUB_BANNERLESS_CODEX_SUMMARY=1
assert_eq "$TURN_RC" 1
t "codex: no verdict is recorded for a summary-less turn"
if [[ -e "$CASE_DIR/state/iter-01/verdict" ]]; then
  bad "verdict recorded despite the missing summary"
else
  ok
fi

t "claude: turn fails when its summary never landed despite the COMPLETE marker"
new_case claude-no-summary
run_turn claude STUB_NO_CLAUDE_SUMMARY=1
assert_eq "$TURN_RC" 1

t "claude: dies instead of answering a stale review when this iter's codex summary is missing"
new_case claude-stale-review
run_turn claude STUB_NO_CODEX_SUMMARY=1
assert_eq "$TURN_RC" 1
if grep -q "codex summary for iter 1 not found" "$CASE_DIR/turn.log"; then
  ok
else
  bad "missing die message (log: $(tail -2 "$CASE_DIR/turn.log" 2>/dev/null | tr '\n' ' '))"
fi

t "claude: an older-iter codex summary is not answered as a fallback"
new_case claude-stale-summary
run_turn claude STUB_STALE_CODEX_SUMMARY=1
assert_eq "$TURN_RC" 1
t "claude: the stale-review die happens before any claude invocation"
if [[ -e "$ARGV" ]]; then
  bad "claude was invoked despite only a stale (iter-0) codex summary being present"
else
  ok
fi

t "claude: a bannerless codex general note is not answered as the review"
new_case claude-bannerless-review
run_turn claude STUB_NO_CODEX_SUMMARY=1 STUB_BANNERLESS_CODEX_SUMMARY=1
assert_eq "$TURN_RC" 1
if [[ -e "$ARGV" ]]; then
  bad "claude was invoked with an orphaned inline note as its review"
else
  ok
fi

# --- gitlab forge plumbing -------------------------------------------------
# The gitlab path talks to /api/v4 via the curl stub: one summary note, one
# inline DiffNote thread with a reply, one system note, one human note.

GL_ENV='FORGE=gitlab FORGE_HOST=gl.example PROJECT_ENC=g%2Fr REPO_SLUG=g/r PR_NUMBER=9 GITLAB_TOKEN=t'

t "gitlab thread: maps discussions to the NDJSON schema (4 marked notes)"
GL_THREAD=$(env -i PATH="$STUBS:/usr/bin:/bin" ITER=3 "$BASH_BIN" -c \
  "$GL_ENV; . '$ROOT/lib/common.sh'; fetch_ai_thread")
assert_eq "$(printf '%s\n' "$GL_THREAD" | wc -l | tr -d ' ')" 4

t "gitlab thread: claude summary note is surface=issue"
assert_eq "$(jq -r 'select(.id==202) | "\(.surface) \(.iter) \(.tag)"' <<<"$GL_THREAD")" \
          "issue 3 ai-loop:claude-implementer"

t "gitlab thread: summary note is surface=issue with its discussion id"
assert_eq "$(jq -r 'select(.id==201) | "\(.surface) \(.discussion_id) \(.iter) \(.tag)"' <<<"$GL_THREAD")" \
          "issue disc-sum 3 ai-loop:codex-reviewer"

t "gitlab thread: DiffNote root is surface=inline with path/line, no reply id"
assert_eq "$(jq -r 'select(.id==301) | "\(.surface) \(.path) \(.line) \(.discussion_id) \(.in_reply_to_id)"' <<<"$GL_THREAD")" \
          "inline src/a.c 12 disc-inline null"

t "gitlab thread: reply note chains to the thread root"
assert_eq "$(jq -r 'select(.id==302) | "\(.in_reply_to_id) \(.tag)"' <<<"$GL_THREAD")" \
          "301 ai-loop:claude-implementer"

t "gitlab thread: unpositioned DiscussionNote reply inherits the root's inline context"
# GitLab diff-thread replies are DiscussionNote objects with no position of
# their own; surface/path/line must come from the DiffNote root, or every
# inline reply degrades to a context-less issue note.
assert_eq "$(jq -r 'select(.id==302) | "\(.surface) \(.path) \(.line)"' <<<"$GL_THREAD")" \
          "inline src/a.c 12"

t "gitlab thread: API failure propagates instead of faking an empty thread"
FAILBIN="$WORK/failcurl"
mkdir -p "$FAILBIN"
printf '#!/usr/bin/env bash\nexit 22\n' > "$FAILBIN/curl"
chmod +x "$FAILBIN/curl"
if env -i PATH="$FAILBIN:$STUBS:/usr/bin:/bin" "$BASH_BIN" -c \
  "set -euo pipefail; $GL_ENV; . '$ROOT/lib/common.sh'; fetch_ai_thread" >/dev/null 2>&1; then
  bad "fetch_ai_thread exited 0 despite the API failing (silent iter-1 restart)"
else
  ok
fi

t "gitlab state dir: flat-name collision dies instead of sharing state"
COLL_HOME="$WORK/collision-home"
env -i PATH="$STUBS:/usr/bin:/bin" "$BASH_BIN" -c \
  "set -euo pipefail; LOOP_HOME='$COLL_HOME' REPO_SLUG=group/sub__proj PR_NUMBER=1; . '$ROOT/lib/common.sh'; ensure_state_dir" \
  >/dev/null 2>&1
if env -i PATH="$STUBS:/usr/bin:/bin" "$BASH_BIN" -c \
  "set -euo pipefail; LOOP_HOME='$COLL_HOME' REPO_SLUG=group/sub/proj PR_NUMBER=1; . '$ROOT/lib/common.sh'; ensure_state_dir" \
  >/dev/null 2>&1; then
  bad "second project silently shares the state dir of group/sub__proj"
else
  ok
fi
t "gitlab state dir: same slug re-enters its own state dir"
if env -i PATH="$STUBS:/usr/bin:/bin" "$BASH_BIN" -c \
  "set -euo pipefail; LOOP_HOME='$COLL_HOME' REPO_SLUG=group/sub__proj PR_NUMBER=1; . '$ROOT/lib/common.sh'; ensure_state_dir" \
  >/dev/null 2>&1; then
  ok
else
  bad "re-run on the owning slug was rejected"
fi

# Forge/host identity: same-slug repos on different forges/hosts must never
# share state, checkouts, or clones.

t "state dir: gitlab identity is namespaced by host"
GLSD=$(env -i PATH="$STUBS:/usr/bin:/bin" "$BASH_BIN" -c \
  "set -euo pipefail; LOOP_HOME='$WORK/sd-home' FORGE=gitlab FORGE_HOST=gl.example REPO_SLUG=g/p PR_NUMBER=2; . '$ROOT/lib/common.sh'; ensure_state_dir; printf '%s' \"\$STATE_DIR\"")
assert_eq "$GLSD" "$WORK/sd-home/state/gl.example__g__p/pr-2"

t "state dir: marker records the full gitlab identity (scheme included)"
assert_eq "$(cat "$WORK/sd-home/state/gl.example__g__p/pr-2/.repo-slug" 2>/dev/null)" "gitlab https://gl.example g/p"

t "state dir: ambiguous pre-scheme gitlab marker is refused with explicit migration guidance"
# The old marker could belong to either the http or the https endpoint —
# nothing persisted proves which — so the run must not adopt the current
# invocation's scheme; the operator migrates explicitly.
SD_MIG="$WORK/sd-migrate"
mkdir -p "$SD_MIG/state/gl.example__g__p/pr-9"
printf 'gitlab gl.example g/p\n' > "$SD_MIG/state/gl.example__g__p/pr-9/.repo-slug"
if env -i PATH="$STUBS:/usr/bin:/bin" "$BASH_BIN" -c \
  "set -euo pipefail; LOOP_HOME='$SD_MIG' FORGE=gitlab FORGE_HOST=gl.example FORGE_SCHEME=https REPO_SLUG=g/p PR_NUMBER=9; . '$ROOT/lib/common.sh'; ensure_state_dir" \
  >"$WORK/sd-mig.out" 2>&1; then
  bad "pre-scheme marker silently adopted the invocation's scheme"
else
  if grep -q "migrate it explicitly" "$WORK/sd-mig.out"; then ok; else bad "refusal lacks migration guidance"; fi
fi
t "state dir: refused pre-scheme marker is left untouched"
assert_eq "$(cat "$SD_MIG/state/gl.example__g__p/pr-9/.repo-slug" 2>/dev/null)" "gitlab gl.example g/p"

t "state dir: same host under a different scheme dies (different endpoint)"
if env -i PATH="$STUBS:/usr/bin:/bin" "$BASH_BIN" -c \
  "set -euo pipefail; LOOP_HOME='$WORK/sd-home' FORGE=gitlab FORGE_HOST=gl.example FORGE_SCHEME=http REPO_SLUG=g/p PR_NUMBER=2; . '$ROOT/lib/common.sh'; ensure_state_dir" \
  >/dev/null 2>&1; then
  bad "http target silently reused the https target's state dir"
else
  ok
fi

t "state dir: github keeps the legacy layout and marker format"
GHSD=$(env -i PATH="$STUBS:/usr/bin:/bin" "$BASH_BIN" -c \
  "set -euo pipefail; LOOP_HOME='$WORK/sd-home' FORGE=github FORGE_HOST=github.com REPO_SLUG=o/r PR_NUMBER=1; . '$ROOT/lib/common.sh'; ensure_state_dir; printf '%s' \"\$STATE_DIR\"")
assert_eq "$GHSD" "$WORK/sd-home/state/o__r/pr-1"
assert_eq "$(cat "$WORK/sd-home/state/o__r/pr-1/.repo-slug" 2>/dev/null)" "o/r"

CLONE_FIX="$WORK/clone-host"
git init -q "$CLONE_FIX" >/dev/null 2>&1
git -C "$CLONE_FIX" remote add origin https://github.com/g/r.git

t "clone guard: same slug on a different forge/host is rejected"
if env -i PATH="$STUBS:/usr/bin:/bin" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=gitlab FORGE_HOST=gl.example REPO_SLUG=g/r REPO_DIR='$CLONE_FIX'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  bad "github.com clone accepted for a gl.example repo of the same slug"
else
  ok
fi

t "clone guard: matching host re-enters its own clone"
if env -i PATH="$STUBS:/usr/bin:/bin" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=github FORGE_HOST=github.com REPO_SLUG=g/r REPO_DIR='$CLONE_FIX'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  ok
else
  bad "matching-host clone rejected"
fi

t "clone guard: port-qualified FORGE_HOST re-enters its own clone"
CLONE_PORT="$WORK/clone-port"
git init -q "$CLONE_PORT" >/dev/null 2>&1
git -C "$CLONE_PORT" remote add origin http://gitlab.lab:8929/g/p.git
if env -i PATH="$STUBS:/usr/bin:/bin" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=gitlab FORGE_HOST=gitlab.lab:8929 FORGE_SCHEME=http REPO_SLUG=g/p REPO_DIR='$CLONE_PORT'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  ok
else
  bad "resume on a port-qualified host rejected its own clone"
fi

t "clone guard: http origin for an https target is a different endpoint"
if env -i PATH="$STUBS:/usr/bin:/bin" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=gitlab FORGE_HOST=gitlab.lab:8929 REPO_SLUG=g/p REPO_DIR='$CLONE_PORT'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  bad "http:// origin accepted for an https:// target on the same authority"
else
  ok
fi

t "clone guard: a divergent pushurl is rejected even when the fetch URL matches"
CLONE_PUSH="$WORK/clone-pushurl"
git init -q "$CLONE_PUSH" >/dev/null 2>&1
git -C "$CLONE_PUSH" remote add origin https://github.com/g/r.git
git -C "$CLONE_PUSH" remote set-url --push origin https://evil.example/g/r.git
if env -i PATH="$STUBS:/usr/bin:/bin" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=github FORGE_HOST=github.com REPO_SLUG=g/r REPO_DIR='$CLONE_PUSH'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  bad "checkout with pushurl to evil.example accepted (push would deliver commits there)"
else
  ok
fi

t "clone guard: a matching explicit pushurl passes"
git -C "$CLONE_PUSH" remote set-url --push origin https://github.com/g/r.git
if env -i PATH="$STUBS:/usr/bin:/bin" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=github FORGE_HOST=github.com REPO_SLUG=g/r REPO_DIR='$CLONE_PUSH'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  ok
else
  bad "matching explicit pushurl rejected"
fi

t "clone guard: same hostname on a different HTTP port is a different instance"
CLONE_PORT2="$WORK/clone-port2"
git init -q "$CLONE_PORT2" >/dev/null 2>&1
git -C "$CLONE_PORT2" remote add origin http://gitlab.lab:8929/g/p.git
if env -i PATH="$STUBS:/usr/bin:/bin" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=gitlab FORGE_HOST=gitlab.lab:9999 FORGE_SCHEME=http REPO_SLUG=g/p REPO_DIR='$CLONE_PORT2'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  bad "clone of gitlab.lab:8929 accepted for the gitlab.lab:9999 instance"
else
  ok
fi

t "clone guard: explicit https default port equals the bare host"
CLONE_443="$WORK/clone-443"
git init -q "$CLONE_443" >/dev/null 2>&1
git -C "$CLONE_443" remote add origin https://gl.example:443/g/p.git
if env -i PATH="$STUBS:/usr/bin:/bin" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=gitlab FORGE_HOST=gl.example REPO_SLUG=g/p REPO_DIR='$CLONE_443'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  ok
else
  bad "https origin with explicit :443 rejected for the bare host"
fi

t "clone guard: leading-zero default-port origin equals the bare host"
CLONE_LZ="$WORK/clone-lz"
git init -q "$CLONE_LZ" >/dev/null 2>&1
git -C "$CLONE_LZ" remote add origin https://gl.example:0443/g/p.git
if env -i PATH="$STUBS:/usr/bin:/bin" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=gitlab FORGE_HOST=gl.example REPO_SLUG=g/p REPO_DIR='$CLONE_LZ'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  ok
else
  bad "https origin with :0443 rejected for the bare host (same endpoint)"
fi

t "clone guard: leading-zero non-default-port origin equals its canonical spelling"
CLONE_LZ2="$WORK/clone-lz2"
git init -q "$CLONE_LZ2" >/dev/null 2>&1
git -C "$CLONE_LZ2" remote add origin http://gitlab.lab:08929/g/p.git
if env -i PATH="$STUBS:/usr/bin:/bin" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=gitlab FORGE_HOST=gitlab.lab:8929 FORGE_SCHEME=http REPO_SLUG=g/p REPO_DIR='$CLONE_LZ2'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  ok
else
  bad "http origin with :08929 rejected for canonical :8929 target"
fi

t "clone guard: lowercase origin passes for an uppercase-spelled target (https)"
CLONE_CASE="$WORK/clone-case"
git init -q "$CLONE_CASE" >/dev/null 2>&1
git -C "$CLONE_CASE" remote add origin https://gl.example/g/p.git
if env -i PATH="$STUBS:/usr/bin:/bin" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=gitlab FORGE_HOST=GL.EXAMPLE REPO_SLUG=g/p REPO_DIR='$CLONE_CASE'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  ok
else
  bad "case-differing spellings of one DNS host rejected as different endpoints"
fi

t "clone guard: uppercase ssh origin passes for the lowercase host"
CLONE_CASE2="$WORK/clone-case2"
git init -q "$CLONE_CASE2" >/dev/null 2>&1
git -C "$CLONE_CASE2" remote add origin 'git@GL.EXAMPLE:g/p.git'
if env -i PATH="$STUBS:/usr/bin:/bin" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=gitlab FORGE_HOST=gl.example REPO_SLUG=g/p REPO_DIR='$CLONE_CASE2'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  ok
else
  bad "uppercase ssh origin rejected for the lowercase host"
fi

t "clone guard: ssh.github.com (SSH over 443) counts as github.com"
CLONE_SSHGH="$WORK/clone-sshgh"
git init -q "$CLONE_SSHGH" >/dev/null 2>&1
git -C "$CLONE_SSHGH" remote add origin 'ssh://git@ssh.github.com:443/g/r.git'
if env -i PATH="$STUBS:/usr/bin:/bin" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=github FORGE_HOST=github.com REPO_SLUG=g/r REPO_DIR='$CLONE_SSHGH'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  ok
else
  bad "documented alternate ssh endpoint rejected"
fi

t "clone guard: relative local-path origin with a matching slug is rejected"
# Codex's reproduction: origin 'g/p.git' normalizes to slug g/p but is a
# local mirror — the loop would push there while commenting on the MR.
CLONE_LOCAL="$WORK/clone-local"
git init -q "$CLONE_LOCAL" >/dev/null 2>&1
git -C "$CLONE_LOCAL" remote add origin g/p.git
if env -i PATH="$STUBS:/usr/bin:/bin" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=gitlab FORGE_HOST=gl.example REPO_SLUG=g/p REPO_DIR='$CLONE_LOCAL'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  bad "local-path origin accepted — pushes would go to the mirror, comments to the MR"
else
  ok
fi

t "clone guard: absolute local-path origin with a matching slug is rejected"
# Origin /g/p.git normalizes to slug g/p (leading slash stripped), so ONLY
# the no-forge-endpoint check stands between this mirror and the push —
# this pins the empty-host die, not the slug comparison.
CLONE_ABS="$WORK/clone-abs"
git init -q "$CLONE_ABS" >/dev/null 2>&1
git -C "$CLONE_ABS" remote add origin /g/p.git
if env -i PATH="$STUBS:/usr/bin:/bin" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=gitlab FORGE_HOST=gl.example REPO_SLUG=g/p REPO_DIR='$CLONE_ABS'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  bad "absolute local-path origin accepted"
else
  ok
fi

t "clone guard: file:// origin is rejected"
CLONE_FILE="$WORK/clone-file"
git init -q "$CLONE_FILE" >/dev/null 2>&1
git -C "$CLONE_FILE" remote add origin file:///srv/git/g/p.git
if env -i PATH="$STUBS:/usr/bin:/bin" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=gitlab FORGE_HOST=gl.example REPO_SLUG=g/p REPO_DIR='$CLONE_FILE'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  bad "file:// origin accepted"
else
  ok
fi

t "clone guard: a checkout with no origin remote is rejected"
CLONE_NOREMOTE="$WORK/clone-noremote"
git init -q "$CLONE_NOREMOTE" >/dev/null 2>&1
if env -i PATH="$STUBS:/usr/bin:/bin" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=github FORGE_HOST=github.com REPO_SLUG=g/r REPO_DIR='$CLONE_NOREMOTE'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  bad "origin-less checkout accepted despite nothing to fetch/push"
else
  ok
fi

t "clone guard: userless scp-style origin validates its host"
CLONE_SCP="$WORK/clone-scp"
git init -q "$CLONE_SCP" >/dev/null 2>&1
git -C "$CLONE_SCP" remote add origin github.com:g/r.git
if env -i PATH="$STUBS:/usr/bin:/bin" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=github FORGE_HOST=github.com REPO_SLUG=g/r REPO_DIR='$CLONE_SCP'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  ok
else
  bad "userless scp-style origin for the right host rejected"
fi

t "clone guard: ssh.<self-host> is rejected (a prefix is not proof of the forge)"
# The documented alternate ssh endpoints are literal public mappings
# (ssh.github.com, altssh.gitlab.com) — on a self-host, ssh.gl.example is
# just another DNS name that need not route to gl.example.
CLONE_SSHSELF="$WORK/clone-sshself"
git init -q "$CLONE_SSHSELF" >/dev/null 2>&1
git -C "$CLONE_SSHSELF" remote add origin 'ssh://git@ssh.gl.example:443/g/p.git'
if env -i PATH="$STUBS:/usr/bin:/bin" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=gitlab FORGE_HOST=gl.example REPO_SLUG=g/p REPO_DIR='$CLONE_SSHSELF'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  bad "ssh.gl.example accepted as gl.example on a self-host"
else
  ok
fi

t "clone guard: altssh.<self-host> scp form is rejected too"
CLONE_ALTSELF="$WORK/clone-altself"
git init -q "$CLONE_ALTSELF" >/dev/null 2>&1
git -C "$CLONE_ALTSELF" remote add origin 'git@altssh.gl.example:g/p.git'
if env -i PATH="$STUBS:/usr/bin:/bin" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=gitlab FORGE_HOST=gl.example REPO_SLUG=g/p REPO_DIR='$CLONE_ALTSELF'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  bad "altssh.gl.example accepted as gl.example on a self-host"
else
  ok
fi

t "clone guard: altssh.gitlab.com counts as gitlab.com (documented mapping)"
CLONE_ALTGL="$WORK/clone-altgl"
git init -q "$CLONE_ALTGL" >/dev/null 2>&1
git -C "$CLONE_ALTGL" remote add origin 'git@altssh.gitlab.com:g/p.git'
if env -i PATH="$STUBS:/usr/bin:/bin" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=gitlab FORGE_HOST=gitlab.com REPO_SLUG=g/p REPO_DIR='$CLONE_ALTGL'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  ok
else
  bad "documented altssh.gitlab.com mapping rejected"
fi

t "clone guard: dotless ssh-alias origin is allowed (unverifiable, slug check holds)"
CLONE_ALIAS="$WORK/clone-alias"
git init -q "$CLONE_ALIAS" >/dev/null 2>&1
git -C "$CLONE_ALIAS" remote add origin 'git@github-work:g/r.git'
if env -i PATH="$STUBS:/usr/bin:/bin" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=github FORGE_HOST=github.com REPO_SLUG=g/r REPO_DIR='$CLONE_ALIAS'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  ok
else
  bad "pre-existing ssh-alias --dir checkout rejected"
fi

t "gitlab post_ai_comment: POSTs a JSON note via curl with the marker"
PC_LOG="$WORK/post-comment.log"
env -i PATH="$STUBS:/usr/bin:/bin" CURL_LOG="$PC_LOG" "$BASH_BIN" -c \
  "$GL_ENV; PR_NUMBER=4; . '$ROOT/lib/common.sh'; post_ai_comment codex 2 'hello'" >/dev/null 2>&1
if grep -q '^POST https://gl.example/api/v4/projects/g%2Fr/merge_requests/4/notes ' "$PC_LOG" 2>/dev/null; then
  ok
else
  bad "no POST to the notes endpoint recorded (log: $(cat "$PC_LOG" 2>/dev/null))"
fi
t "gitlab post_ai_comment: body carries the hidden marker"
if grep -q 'ai-loop:codex-reviewer iter=2' "$PC_LOG" 2>/dev/null; then ok; else bad "marker missing from POST body"; fi

t "codex gitlab: renders the gitlab prompt template with host + project id"
new_case codex-gitlab
run_turn codex FORGE=gitlab FORGE_HOST=gl.example PROJECT_ENC=g%2Fr REPO_SLUG=g/r GITLAB_TOKEN=tok
assert_rc0
GL_PROMPT="$CASE_DIR/state/iter-01/codex.prompt.md"
if grep -q 'https://gl.example/api/v4/projects/g%2Fr' "$GL_PROMPT" 2>/dev/null; then
  ok
else
  bad "gitlab prompt not rendered (missing API base) in $GL_PROMPT"
fi
t "codex gitlab: prompt bans glab api for posting"
if grep -q 'glab api' "$GL_PROMPT" 2>/dev/null; then ok; else bad "missing glab api warning"; fi
t "codex gitlab: model knobs unchanged on the gitlab path"
assert_pair "$ARGV" -m gpt-5.6-sol

t "codex gitlab: http scheme renders into the prompt API base"
new_case codex-gitlab-http
run_turn codex FORGE=gitlab FORGE_HOST=gl.example FORGE_SCHEME=http PROJECT_ENC=g%2Fr REPO_SLUG=g/r GITLAB_TOKEN=tok
assert_rc0
if grep -q 'http://gl.example/api/v4/projects/g%2Fr' "$CASE_DIR/state/iter-01/codex.prompt.md" 2>/dev/null; then
  ok
else
  bad "prompt API base not rendered with the http scheme"
fi

t "codex gitlab: HEAD capture is path-free (safe for space-containing --dir)"
# The recipe runs inside the checkout (step 1 cd's there); embedding the
# rendered path unquoted would break 'git -C /tmp/my repo rev-parse HEAD'.
if grep -qF 'EXPECTED_HEAD=$(git rev-parse HEAD)' "$CASE_DIR/state/iter-01/codex.prompt.md" 2>/dev/null \
   && ! grep -q 'git -C .*rev-parse HEAD' "$CASE_DIR/state/iter-01/codex.prompt.md" 2>/dev/null; then
  ok
else
  bad "rendered prompt embeds a path in the HEAD capture"
fi

t "claude gitlab: renders the gitlab prompt and extracts discussion_id"
new_case claude-gitlab
run_turn claude FORGE=gitlab FORGE_HOST=gl.example PROJECT_ENC=g%2Fr REPO_SLUG=g/r GITLAB_TOKEN=tok
assert_rc0
GL_PROMPT="$CASE_DIR/state/iter-01/claude.prompt.md"
if grep -q 'discussions/<discussion_id>/notes' "$GL_PROMPT" 2>/dev/null; then
  ok
else
  bad "gitlab prompt not rendered (missing discussion reply endpoint)"
fi
t "claude gitlab: summary review extracted from the discussions surface"
if grep -q 'Stub codex review.' "$CASE_DIR/state/iter-01/codex-review.md" 2>/dev/null; then
  ok
else
  bad "codex-review.md missing the stubbed summary"
fi
t "claude gitlab: inline finding carries its discussion_id"
assert_eq "$(jq -r '.discussion_id' "$CASE_DIR/state/iter-01/codex-inline.ndjson" 2>/dev/null)" disc-inline

t "claude gitlab: http scheme renders into the prompt API base"
new_case claude-gitlab-http
run_turn claude FORGE=gitlab FORGE_HOST=gl.example FORGE_SCHEME=http PROJECT_ENC=g%2Fr REPO_SLUG=g/r GITLAB_TOKEN=tok
assert_rc0
if grep -q 'http://gl.example/api/v4/projects/g%2Fr' "$CASE_DIR/state/iter-01/claude.prompt.md" 2>/dev/null; then
  ok
else
  bad "claude prompt API base not rendered with the http scheme"
fi

# --- run.sh flag validation ----------------------------------------------

t "run.sh: empty --codex-effort is rejected"
run_run_sh 1 --repo o/n --codex-effort ''
assert_dies_with "--codex-effort needs a level"

t "run.sh: unknown --codex-effort is rejected"
run_run_sh 1 --repo o/n --codex-effort bogus
assert_dies_with "--codex-effort must be one of"

t "run.sh: unknown --claude-effort is rejected"
run_run_sh 1 --repo o/n --claude-effort bogus
assert_dies_with "--claude-effort must be one of"

t "run.sh: empty --codex-model is rejected"
run_run_sh 1 --repo o/n --codex-model ''
assert_dies_with "--codex-model needs a model"

# Anti-swallow branch: a free-form flag must not consume the next option as
# its value (e.g. --codex-model --review-only would otherwise eat the mode
# flag and silently drop review-only).
t "run.sh: --codex-model refuses the next flag as its value"
run_run_sh 1 --repo o/n --codex-model --review-only
assert_dies_with "--codex-model needs a model"

t "run.sh: --claude-model refuses the next flag as its value"
run_run_sh 1 --repo o/n --claude-model --review-only
assert_dies_with "--claude-model needs a model"

t "run.sh: --codex-tier refuses the next flag as its value"
run_run_sh 1 --repo o/n --codex-tier --review-only
assert_dies_with "--codex-tier needs a tier"

t "run.sh: --claude-perms refuses the next flag as its value"
run_run_sh 1 --repo o/n --claude-perms --review-only
assert_dies_with "--claude-perms needs a mode"

t "run.sh: unknown --claude-perms is rejected"
run_run_sh 1 --repo o/n --claude-perms bogus
assert_dies_with "--claude-perms must be one of"

t "run.sh: non-sol model with explicit ultra passes validation"
run_run_sh 1 --repo o/n --codex-model gpt-oss-120b --codex-effort ultra
assert_dies_with "GH_TOKEN/GITHUB_TOKEN not set"

# --- run.sh forge resolution (URL / --forge / --host) ----------------------
# --print-config reports the resolved forge line before any network access.

t "run.sh: github PR URL pins forge, repo, and number"
run_run_sh https://github.com/foo/bar/pull/42 --print-config
assert_prints 'forge: github host=github.com scheme=https repo=foo/bar pr=42'

t "run.sh: gitlab.com MR URL selects the gitlab forge (subgroups kept)"
run_run_sh https://gitlab.com/group/sub/proj/-/merge_requests/7 --print-config
assert_prints 'forge: gitlab host=gitlab.com scheme=https repo=group/sub/proj pr=7'

t "run.sh: self-hosted MR URL keeps its host"
run_run_sh https://gitlab-master.example.com/omniverse/kit/-/merge_requests/123 --print-config
assert_prints 'forge: gitlab host=gitlab-master.example.com scheme=https repo=omniverse/kit pr=123'

t "run.sh: MR URL with a trailing tab path still parses"
run_run_sh https://gitlab.com/g/p/-/merge_requests/5/diffs --print-config
assert_prints 'forge: gitlab host=gitlab.com scheme=https repo=g/p pr=5'

t "run.sh: legacy MR URL (no /-/) parses"
run_run_sh https://gitlab.example.com/g/p/merge_requests/6 --print-config
assert_prints 'forge: gitlab host=gitlab.example.com scheme=https repo=g/p pr=6'

t "run.sh: --host other than github.com implies gitlab"
run_run_sh 3 --repo g/sub/p --host gitlab.example.com --print-config
assert_prints 'forge: gitlab host=gitlab.example.com scheme=https repo=g/sub/p pr=3'

t "run.sh: bare number + --repo stays github on github.com"
run_run_sh 1 --repo o/n --print-config
assert_prints 'forge: github host=github.com scheme=https repo=o/n pr=1'

t "run.sh: --repo conflicting with the URL repo dies"
run_run_sh https://github.com/foo/bar/pull/42 --repo other/name --print-config
assert_dies_with "conflicts with the URL repo"

t "run.sh: --forge conflicting with the URL forge dies"
run_run_sh https://github.com/foo/bar/pull/42 --forge gitlab --print-config
assert_dies_with "conflicts with the URL"

t "run.sh: unrecognized URL dies"
run_run_sh https://example.com/not-a-pr --print-config
assert_dies_with "unrecognized PR/MR URL"

t "run.sh: unknown --forge is rejected"
run_run_sh 1 --repo o/n --forge sourcehut --print-config
assert_dies_with "--forge must be github or gitlab"

t "run.sh: self-hosted GitHub is rejected"
run_run_sh 1 --repo o/n --forge github --host ghe.example.com --print-config
assert_dies_with "self-hosted GitHub is not supported"

t "run.sh: gitlab preflight dies with guidance when no token resolves"
run_run_sh STUB_GLAB_NO_TOKEN=1 1 --repo g/p --forge gitlab
assert_dies_with "no GitLab token for gitlab.com"

t "run.sh: gitlab preflight resolves the token via glab and reaches MR fetch"
run_run_sh 1 --repo g/p --forge gitlab --dir "$WORK/glclone"
assert_dies_with "MR is not open"

t "run.sh: OAuth-backed glab session is rejected with guidance"
run_run_sh STUB_GLAB_OAUTH=true 1 --repo g/p --forge gitlab
assert_dies_with "OAuth-backed"

t "run.sh: explicit GITLAB_TOKEN bypasses the glab OAuth check"
run_run_sh GITLAB_TOKEN=pat STUB_GLAB_OAUTH=true 1 --repo g/p --forge gitlab --dir "$WORK/glclone-oauth"
assert_dies_with "MR is not open"

t "run.sh: ambient GLAB_IS_OAUTH2 cannot mask a stored OAuth session"
run_run_sh GLAB_IS_OAUTH2=false STUB_GLAB_OAUTH=true 1 --repo g/p --forge gitlab
assert_dies_with "OAuth-backed"

t "run.sh: ambient GITLAB_IS_OAUTH2 cannot mask a stored OAuth session"
run_run_sh GITLAB_IS_OAUTH2=false STUB_GLAB_OAUTH=true 1 --repo g/p --forge gitlab
assert_dies_with "OAuth-backed"

t "run.sh: ambient GLAB_TOKEN cannot shadow the host's configured PAT"
GLABTOK_HDR_LOG="$WORK/glabtok-hdr.log"
run_run_sh GLAB_TOKEN=glab-ambient CURL_HDR_LOG="$GLABTOK_HDR_LOG" 1 --repo g/p --forge gitlab --dir "$WORK/glclone-glabtok"
assert_dies_with "MR is not open"
t "run.sh: the PRIVATE-TOKEN sent is the config PAT, not the ambient GLAB_TOKEN"
if grep -q 'PRIVATE-TOKEN: stub-glab-token' "$GLABTOK_HDR_LOG" 2>/dev/null \
   && ! grep -q 'glab-ambient' "$GLABTOK_HDR_LOG" 2>/dev/null; then
  ok
else
  bad "ambient GLAB_TOKEN leaked into the API calls (hdrs: $(sort -u "$GLABTOK_HDR_LOG" 2>/dev/null | tr '\n' ' '))"
fi

t "run.sh: ambient OAUTH_TOKEN cannot shadow the host's configured PAT"
OAUTH_HDR_LOG="$WORK/oauth-hdr.log"
run_run_sh OAUTH_TOKEN=oauth-foreign CURL_HDR_LOG="$OAUTH_HDR_LOG" 1 --repo g/p --forge gitlab --dir "$WORK/glclone-shadow"
assert_dies_with "MR is not open"
t "run.sh: the PRIVATE-TOKEN sent is the config PAT, not the ambient OAuth token"
if grep -q 'PRIVATE-TOKEN: stub-glab-token' "$OAUTH_HDR_LOG" 2>/dev/null \
   && ! grep -q 'oauth-foreign' "$OAUTH_HDR_LOG" 2>/dev/null; then
  ok
else
  bad "ambient OAUTH_TOKEN leaked into the API calls (hdrs: $(sort -u "$OAUTH_HDR_LOG" 2>/dev/null | tr '\n' ' '))"
fi

t "run.sh: http MR URL preserves the scheme"
run_run_sh http://gl.example/g/p/-/merge_requests/9 --print-config
assert_prints 'forge: gitlab host=gl.example scheme=http repo=g/p pr=9'

t "run.sh: scheme-qualified --host implies gitlab and keeps http"
run_run_sh 3 --repo g/p --host http://gitlab.lab --print-config
assert_prints 'forge: gitlab host=gitlab.lab scheme=http repo=g/p pr=3'

t "run.sh: --host scheme conflicting with the URL scheme dies"
run_run_sh https://gl.example/g/p/-/merge_requests/9 --host http://gl.example --print-config
assert_dies_with "conflicts with the URL scheme"

# Authority validation: the resolved host goes verbatim into every curl
# target, so URL-grammar tricks (userinfo, paths) must die before any use —
# https://good.host@attacker.invalid/... would otherwise send the PAT to
# attacker.invalid.
t "run.sh: MR URL with userinfo in the authority is rejected (PAT exfiltration)"
run_run_sh 'https://gitlab.example.com@attacker.invalid/g/p/-/merge_requests/1' --print-config
assert_dies_with "invalid forge host"

t "run.sh: --host with userinfo is rejected"
run_run_sh 1 --repo g/p --host 'good.host@attacker.invalid' --print-config
assert_dies_with "invalid forge host"

t "run.sh: --host with a path is rejected"
run_run_sh 1 --repo g/p --host 'gl.example/evil' --print-config
assert_dies_with "invalid forge host"

t "run.sh: port-qualified --host passes validation"
run_run_sh 3 --repo g/p --host gitlab.lab:8929 --print-config
assert_prints 'forge: gitlab host=gitlab.lab:8929 scheme=https repo=g/p pr=3'

t "run.sh: bracketed IPv6 --host passes validation"
run_run_sh 3 --repo g/p --host '[::1]:8443' --print-config
assert_prints 'forge: gitlab host=[::1]:8443 scheme=https repo=g/p pr=3'

t "run.sh: underscore intranet hostname passes validation"
run_run_sh 3 --repo g/p --host gitlab_master.corp --print-config
assert_prints 'forge: gitlab host=gitlab_master.corp scheme=https repo=g/p pr=3'

t "run.sh: trailing-dot absolute FQDN passes validation"
run_run_sh 3 --repo g/p --host gitlab.example.com. --print-config
assert_prints 'forge: gitlab host=gitlab.example.com. scheme=https repo=g/p pr=3'

t "run.sh: http URL reaches the API on http (actual curl target)"
HTTP_CURL_LOG="$WORK/http-curl.log"
GLHTTP="$WORK/glclone-http"
git init -q "$GLHTTP" >/dev/null 2>&1
git -C "$GLHTTP" remote add origin http://gl.example/g/p.git
run_run_sh CURL_LOG="$HTTP_CURL_LOG" http://gl.example/g/p/-/merge_requests/9 --dir "$GLHTTP"
assert_dies_with "MR is not open"
t "run.sh: preflight /user call went over http"
if grep -q '^GET http://gl.example/api/v4/user' "$HTTP_CURL_LOG" 2>/dev/null; then
  ok
else
  bad "no http GET to /user recorded (log: $(head -3 "$HTTP_CURL_LOG" 2>/dev/null | tr '\n' ' '))"
fi

t "run.sh: managed gitlab checkout is namespaced by host"
run_run_sh https://gl.example/g/p/-/merge_requests/9 --print-config
assert_prints "dir: $ROOT/checkouts/gl.example__g__p"

# Default-port canonicalization: https://gl.example:443 IS https://gl.example
# — both spellings must resolve to one identity (host, checkout, state,
# marker), or re-invoking the same MR in the equivalent form would split
# its sessions/context/verdict across two state dirs.
t "run.sh: explicit https default port canonicalizes to the bare host"
run_run_sh https://gl.example:443/g/p/-/merge_requests/9 --print-config
assert_prints 'forge: gitlab host=gl.example scheme=https repo=g/p pr=9'
assert_prints "dir: $ROOT/checkouts/gl.example__g__p"

t "run.sh: explicit http default port canonicalizes to the bare host"
run_run_sh 3 --repo g/p --host http://gitlab.lab:80 --print-config
assert_prints 'forge: gitlab host=gitlab.lab scheme=http repo=g/p pr=3'

t "run.sh: a non-default port is preserved in the identity"
run_run_sh http://gitlab.lab:8929/g/p/-/merge_requests/9 --print-config
assert_prints 'forge: gitlab host=gitlab.lab:8929 scheme=http repo=g/p pr=9'
assert_prints "dir: $ROOT/checkouts/gitlab.lab:8929__g__p"

# Ports normalize NUMERICALLY: curl reaches the same endpoint for :0443
# and :443, so a leading-zero spelling must not fork the identity.
t "run.sh: leading-zero https default port canonicalizes to the bare host"
run_run_sh https://gl.example:0443/g/p/-/merge_requests/9 --print-config
assert_prints 'forge: gitlab host=gl.example scheme=https repo=g/p pr=9'
assert_prints "dir: $ROOT/checkouts/gl.example__g__p"

t "run.sh: leading-zero http default port canonicalizes to the bare host"
run_run_sh 3 --repo g/p --host http://gitlab.lab:080 --print-config
assert_prints 'forge: gitlab host=gitlab.lab scheme=http repo=g/p pr=3'

t "run.sh: leading-zero NON-default port normalizes its digits"
run_run_sh https://gl.example:08443/g/p/-/merge_requests/9 --print-config
assert_prints 'forge: gitlab host=gl.example:8443 scheme=https repo=g/p pr=9'

t "run.sh: pre-canonicalization port-spelled state refuses with migration guidance"
# State written by an earlier build under the ':443' spelling must not be
# silently orphaned (the approved-resume no-op depends on its verdict file).
# The tree is identified by its markers, not just its name. $ROOT/state is
# gitignored; the fixture is removed right after.
mkdir -p "$ROOT/state/gl.example:443__g__p/pr-9"
printf 'gitlab https://gl.example:443 g/p\n' > "$ROOT/state/gl.example:443__g__p/pr-9/.repo-slug"
run_run_sh https://gl.example:443/g/p/-/merge_requests/9 --print-config
rm -rf "$ROOT/state/gl.example:443__g__p"
assert_dies_with "pre-canonicalization spelling"

t "run.sh: the BARE spelling also refuses when legacy port-spelled state exists"
# The guard must be two-sided: a bare re-invocation would otherwise
# silently select a fresh bare-host tree and orphan the legacy one.
mkdir -p "$ROOT/state/gl.example:443__g__p/pr-9"
printf 'gitlab gl.example:443 g/p\n' > "$ROOT/state/gl.example:443__g__p/pr-9/.repo-slug"
run_run_sh https://gl.example/g/p/-/merge_requests/9 --print-config
rm -rf "$ROOT/state/gl.example:443__g__p"
assert_dies_with "pre-canonicalization spelling"

t "run.sh: legacy state keyed by a leading-zero spelling also refuses"
# A pre-normalization build keyed a ':0443'-spelled run verbatim; the
# guard discovers equivalent-spelling trees by scanning, so ANY re-entry
# spelling must refuse, not just the one that recreates the old name.
mkdir -p "$ROOT/state/gl.example:0443__g__p/pr-9"
printf 'gitlab https://gl.example:0443 g/p\n' > "$ROOT/state/gl.example:0443__g__p/pr-9/.repo-slug"
run_run_sh https://gl.example:0443/g/p/-/merge_requests/9 --print-config
rm -rf "$ROOT/state/gl.example:0443__g__p"
assert_dies_with "pre-canonicalization spelling"

t "run.sh: BARE invocation refuses a ':0443'-keyed legacy tree (reverse spelling)"
mkdir -p "$ROOT/state/gl.example:0443__g__p/pr-9"
printf 'gitlab https://gl.example:0443 g/p\n' > "$ROOT/state/gl.example:0443__g__p/pr-9/.repo-slug"
run_run_sh https://gl.example/g/p/-/merge_requests/9 --print-config
rm -rf "$ROOT/state/gl.example:0443__g__p"
assert_dies_with "pre-canonicalization spelling"

t "run.sh: bare HTTP invocation refuses a ':080'-keyed legacy tree"
mkdir -p "$ROOT/state/gitlab.lab:080__g__p/pr-9"
printf 'gitlab http://gitlab.lab:080 g/p\n' > "$ROOT/state/gitlab.lab:080__g__p/pr-9/.repo-slug"
run_run_sh http://gitlab.lab/g/p/-/merge_requests/9 --print-config
rm -rf "$ROOT/state/gitlab.lab:080__g__p"
assert_dies_with "pre-canonicalization spelling"

t "run.sh: canonical ':8443' invocation refuses an ':08443'-keyed legacy tree"
mkdir -p "$ROOT/state/gl.example:08443__g__p/pr-9"
printf 'gitlab https://gl.example:08443 g/p\n' > "$ROOT/state/gl.example:08443__g__p/pr-9/.repo-slug"
run_run_sh https://gl.example:8443/g/p/-/merge_requests/9 --print-config
rm -rf "$ROOT/state/gl.example:08443__g__p"
assert_dies_with "pre-canonicalization spelling"

t "run.sh: the canonical tree itself never triggers the guard (resume works)"
# The scan enumerates the canonical tree too; skipping it is load-bearing —
# without the skip, every resumed GitLab run would die on its own state.
mkdir -p "$ROOT/state/gl.example__g__p/pr-9"
printf 'gitlab https://gl.example g/p\n' > "$ROOT/state/gl.example__g__p/pr-9/.repo-slug"
run_run_sh https://gl.example/g/p/-/merge_requests/9 --print-config
rm -rf "$ROOT/state/gl.example__g__p"
assert_prints 'forge: gitlab host=gl.example scheme=https repo=g/p pr=9'

t "run.sh: a same-slug tree for an UNRELATED host never triggers the guard"
# The canon-equivalence filter is load-bearing too: gitlab.internal is not
# a spelling of gl.example, whatever its marker says.
mkdir -p "$ROOT/state/gitlab.internal__g__p/pr-9"
printf 'gitlab https://gitlab.internal g/p\n' > "$ROOT/state/gitlab.internal__g__p/pr-9/.repo-slug"
run_run_sh https://gl.example/g/p/-/merge_requests/9 --print-config
rm -rf "$ROOT/state/gitlab.internal__g__p"
assert_prints 'forge: gitlab host=gl.example scheme=https repo=g/p pr=9'

t "run.sh: a canonical http-on-443 tree is NOT mistaken for legacy https state"
# 443 is not http's default port, so state/gl.example:443__g__p with an
# http marker is another endpoint's canonical tree — a bare https run must
# leave it alone and proceed.
mkdir -p "$ROOT/state/gl.example:443__g__p/pr-9"
printf 'gitlab http://gl.example:443 g/p\n' > "$ROOT/state/gl.example:443__g__p/pr-9/.repo-slug"
run_run_sh https://gl.example/g/p/-/merge_requests/9 --print-config
rm -rf "$ROOT/state/gl.example:443__g__p"
assert_prints 'forge: gitlab host=gl.example scheme=https repo=g/p pr=9'

t "run.sh: stored PAT under the default-port glab key is found (port-spelled invocation)"
run_run_sh STUB_GLAB_TOKEN_HOST=gl.example:443 https://gl.example:443/g/p/-/merge_requests/9 --dir "$WORK/glclone-pk1"
assert_dies_with "MR is not open"

t "run.sh: stored PAT under the default-port glab key is found (bare invocation)"
run_run_sh STUB_GLAB_TOKEN_HOST=gl.example:443 https://gl.example/g/p/-/merge_requests/9 --dir "$WORK/glclone-pk2"
assert_dies_with "MR is not open"

t "run.sh: stored PAT under the exact leading-zero glab key is found"
# glab keys config by the exact login string; the invocation's original
# validated spelling must be probed alongside canonical + default twin.
run_run_sh STUB_GLAB_TOKEN_HOST=gl.example:0443 https://gl.example:0443/g/p/-/merge_requests/9 --dir "$WORK/glclone-pk3"
assert_dies_with "MR is not open"

t "run.sh: BARE invocation finds a PAT stored under a zero-padded key"
# Reverse spelling: login used ':0443', invocation is bare — the probe must
# enumerate every accepted zero-padded spelling of the endpoint's port.
run_run_sh STUB_GLAB_TOKEN_HOST=gl.example:0443 https://gl.example/g/p/-/merge_requests/9 --dir "$WORK/glclone-pk4"
assert_dies_with "MR is not open"

t "run.sh: canonical ':8443' invocation finds a PAT stored under ':08443'"
run_run_sh STUB_GLAB_TOKEN_HOST=gl.example:08443 https://gl.example:8443/g/p/-/merge_requests/9 --dir "$WORK/glclone-pk5"
assert_dies_with "MR is not open"

t "run.sh: uppercase MR URL canonicalizes to the lowercase identity"
run_run_sh https://GL.EXAMPLE/g/p/-/merge_requests/9 --print-config
assert_prints 'forge: gitlab host=gl.example scheme=https repo=g/p pr=9'
assert_prints "dir: $ROOT/checkouts/gl.example__g__p"

t "run.sh: PAT under a case-preserved port-spelled key is found from the bare uppercase URL"
# glab stores login spellings verbatim (case-preserved): the probe must
# enumerate the original-cased base's spellings, not just the lowercased
# canonical ones.
run_run_sh STUB_GLAB_TOKEN_HOST=GL.EXAMPLE:443 https://GL.EXAMPLE/g/p/-/merge_requests/9 --dir "$WORK/glclone-pk6"
assert_dies_with "MR is not open"

t "run.sh: PAT under a case-preserved bare key is found from the port-spelled URL"
run_run_sh STUB_GLAB_TOKEN_HOST=GL.EXAMPLE https://GL.EXAMPLE:443/g/p/-/merge_requests/9 --dir "$WORK/glclone-pk7"
assert_dies_with "MR is not open"

t "run.sh: --preflight-only reports identity, MR URL, and branches"
# Pre-clean so a guard regression in a previous suite run can't leave
# debris that fails the side-effect assertion below against fixed code.
rm -rf "$ROOT/state/gitlab.com__g__p" "$ROOT/checkouts/gitlab.com__g__p"
run_run_sh STUB_MR_OPEN=1 9 --repo g/p --forge gitlab --preflight-only
assert_prints 'identity: testuser'
assert_prints 'pr: https://gl.example/g/p/-/merge_requests/9'
assert_prints 'branches: main <- feat/x'

t "run.sh: --preflight-only creates no clone or state dir"
if [[ -e "$ROOT/checkouts/gitlab.com__g__p" || -e "$ROOT/state/gitlab.com__g__p" ]]; then
  bad "preflight-only left side effects on disk"
else
  ok
fi

t "run.sh: --preflight-only still dies on a non-open MR"
run_run_sh 9 --repo g/p --forge gitlab --preflight-only
assert_dies_with "MR is not open"

t "run.sh: managed github checkout keeps the legacy layout"
run_run_sh 1 --repo o/n --print-config
assert_prints "dir: $ROOT/checkouts/o__n"

# --print-config exposes run.sh's own resolution (not just the helper's), so
# these have teeth against run.sh regressing to a forced level.
t "run.sh: default knobs resolve to sol @ ultra on fast"
run_run_sh --repo o/n --print-config
assert_prints 'claude: model=fable effort=ultracode perms=auto'
assert_prints 'codex: model=gpt-5.6-sol effort=ultra tier=fast'

t "run.sh: non-sol model resolves to adaptive off (no forced level)"
run_run_sh --repo o/n --codex-model gpt-oss-120b --print-config
assert_prints 'codex: model=gpt-oss-120b effort=off tier=fast'

t "run.sh: explicit effort wins through run.sh's resolution"
run_run_sh --repo o/n --codex-model gpt-oss-120b --codex-effort high --print-config
assert_prints 'codex: model=gpt-oss-120b effort=high tier=fast'

# --- summary ---------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
exit 0
