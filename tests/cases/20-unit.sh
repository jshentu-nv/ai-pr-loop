# --- resolve_codex_effort ------------------------------------------------


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
t "authority: trailing-dot FQDN spelling folds to the bare name"
assert_eq "$(normalize_remote_http_authority 'https://gl.example./g/p.git')" gl.example
t "host: trailing-dot ssh hostname folds to the bare name"
assert_eq "$(normalize_remote_host 'git@gl.example.:g/p.git')" gl.example
t "host: trailing-dot ssh:// URL hostname folds too (host_sans_port path)"
assert_eq "$(normalize_remote_host 'ssh://git@gl.example.:2222/g/p.git')" gl.example
t "host: bracketed IPv6 scp origin parses its address"
assert_eq "$(normalize_remote_host 'git@[::1]:g/p.git')" ::1
t "host: userless bracketed IPv6 scp origin parses its address"
assert_eq "$(normalize_remote_host '[::1]:g/p.git')" ::1
t "slug: bracketed IPv6 scp origin"
assert_eq "$(normalize_remote_slug 'git@[::1]:g/p.git')" g/p
t "slug: userless bracketed IPv6 scp origin"
assert_eq "$(normalize_remote_slug '[::1]:g/p.git')" g/p
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
REAL_SLEEP="$(command -v sleep)"
REAL_HEAD="$(command -v head)"
cat > "$FBIN/sleep" <<EOF
#!$BASH_BIN
exec "$REAL_SLEEP" "\$@"
EOF
cat > "$FBIN/head" <<EOF
#!$BASH_BIN
exec "$REAL_HEAD" "\$@"
EOF
chmod +x "$FBIN/sleep" "$FBIN/head"

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

# --- runtime metadata JSONL lifecycle --------------------------------------

t "runtime RPC: a closed reader returns failure without SIGPIPEing the turn"
trap ':' PIPE
RPC_PIPE_TRAP=$(trap -p PIPE)
_runtime_rpc_start "$WORK" /usr/bin/true
sleep 0.2
if _runtime_rpc_send '{"id":"too-late"}'; then
  bad "write to a closed runtime RPC unexpectedly succeeded"
else
  ok
fi
assert_eq "$(trap -p PIPE)" "$RPC_PIPE_TRAP"
_runtime_rpc_stop
trap - PIPE

t "runtime RPC: EOF-spawned wrapper children are killed with the probe group"
RPC_CHILD_FILE="$WORK/runtime-rpc-child.pid"
_runtime_rpc_start "$WORK" /bin/sh -c \
  '/bin/cat >/dev/null; trap "" TERM; /bin/sleep 30 & printf "%s\n" "$!" > "$1"' \
  runtime-wrapper "$RPC_CHILD_FILE"
_runtime_rpc_stop
RPC_CHILD_PID=$(cat "$RPC_CHILD_FILE" 2>/dev/null || true)
if [[ "$RPC_CHILD_PID" =~ ^[0-9]+$ ]] && kill -0 "$RPC_CHILD_PID" 2>/dev/null; then
  kill -KILL "$RPC_CHILD_PID" 2>/dev/null || true
  bad "runtime RPC wrapper child survived cleanup"
else
  ok
fi

t "runtime capture: valid-looking output from a failed command is rejected"
RPC_FAILED_RC=0
RPC_FAILED_OUTPUT=$(_runtime_capture_with_timeout "$WORK" 5 /bin/sh -c \
  'printf "{\"models\":[]}\n"; exit 42') || RPC_FAILED_RC=$?
assert_eq "$RPC_FAILED_OUTPUT" '{"models":[]}'
assert_eq "$RPC_FAILED_RC" 42

t "runtime RPC: a guardian kills the detached probe tree after owner SIGKILL"
RPC_GUARD_DIR="$WORK/runtime-rpc-guardian"
mkdir -p "$RPC_GUARD_DIR"
"$BASH_BIN" -c '
  set -euo pipefail
  . "$1/lib/common.sh"
  mkdir -p "$2/tmp"
  TMPDIR="$2/tmp"; export TMPDIR
  _runtime_rpc_start "$2" /bin/sh -c '\''
    /bin/cat >/dev/null
    trap "" TERM
    /bin/sleep 30 & printf "%s\n" "$!" > "$1/child.pid"
    wait
  '\'' runtime-wrapper "$2"
  printf "%s\n" "$RUNTIME_RPC_PID" > "$2/rpc.pid"
  printf "%s\n" "$RUNTIME_RPC_GUARDIAN_PID" > "$2/guardian.pid"
  printf "%s\n" "$RUNTIME_RPC_DIR" > "$2/runtime-dir"
  printf ready > "$2/owner.ready"
  sleep 30
' rpc-owner "$ROOT" "$RPC_GUARD_DIR" &
RPC_OWNER_PID=$!
for (( _n = 0; _n < 100; _n++ )); do
  [[ -s "$RPC_GUARD_DIR/owner.ready" ]] && break
  sleep 0.05
done
if [[ ! -s "$RPC_GUARD_DIR/owner.ready" ]]; then
  kill -KILL "$RPC_OWNER_PID" 2>/dev/null || true
  wait "$RPC_OWNER_PID" 2>/dev/null || true
  bad "runtime RPC owner never completed guarded startup"
else
  kill -KILL "$RPC_OWNER_PID" 2>/dev/null || true
  wait "$RPC_OWNER_PID" 2>/dev/null || true
  RPC_PROBE_PID=$(cat "$RPC_GUARD_DIR/rpc.pid" 2>/dev/null || true)
  RPC_GUARD_PID=$(cat "$RPC_GUARD_DIR/guardian.pid" 2>/dev/null || true)
  RPC_RUNTIME_DIR=$(cat "$RPC_GUARD_DIR/runtime-dir" 2>/dev/null || true)
  _live=1
  for (( _n = 0; _n < 100; _n++ )); do
    RPC_CHILD_PID=$(cat "$RPC_GUARD_DIR/child.pid" 2>/dev/null || true)
    _live=0
    for _pid in "$RPC_PROBE_PID" "$RPC_GUARD_PID" "$RPC_CHILD_PID"; do
      if [[ "$_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$_pid" 2>/dev/null \
         && [[ "$(ps -o stat= -p "$_pid" 2>/dev/null)" != *Z* ]]; then
        _live=1
      fi
    done
    (( _live == 0 )) && break
    sleep 0.05
  done
  if (( _live == 0 )) && [[ -n "$RPC_RUNTIME_DIR" && ! -e "$RPC_RUNTIME_DIR" ]]; then
    ok
  else
    for _pid in "$RPC_PROBE_PID" "$RPC_GUARD_PID" "$RPC_CHILD_PID"; do
      [[ "$_pid" =~ ^[1-9][0-9]*$ ]] && kill -KILL "$_pid" 2>/dev/null || true
    done
    bad "runtime RPC process or temp directory survived its owner being SIGKILLed"
  fi
fi

t "runtime RPC: guardian retains a stubborn group during normal-stop owner death"
RPC_STOP_RACE_DIR="$WORK/runtime-rpc-stop-race"
mkdir -p "$RPC_STOP_RACE_DIR"
"$BASH_BIN" -c '
  set -euo pipefail
  . "$1/lib/common.sh"
  mkdir -p "$2/tmp"
  TMPDIR="$2/tmp"; export TMPDIR
  _runtime_rpc_start "$2" /bin/sh -c '\''
    /bin/cat >/dev/null
    trap "" TERM
    /bin/sleep 30 </dev/null &
    printf "%s\n" "$!" > "$1/child.pid"
    exit 0
  '\'' runtime-wrapper "$2"
  printf "%s\n" "$RUNTIME_RPC_PID" > "$2/rpc.pid"
  printf "%s\n" "$RUNTIME_RPC_GUARDIAN_PID" > "$2/guardian.pid"
  printf "%s\n" "$RUNTIME_RPC_DIR" > "$2/runtime-dir"
  printf ready > "$2/owner.ready"
  _runtime_rpc_stop
' rpc-stop-owner "$ROOT" "$RPC_STOP_RACE_DIR" &
RPC_STOP_OWNER_PID=$!
RPC_STOP_WINDOW=0
for (( _n = 0; _n < 200; _n++ )); do
  if [[ -s "$RPC_STOP_RACE_DIR/owner.ready" \
        && -s "$RPC_STOP_RACE_DIR/child.pid" ]]; then
    RPC_STOP_PROBE_PID=$(cat "$RPC_STOP_RACE_DIR/rpc.pid" 2>/dev/null || true)
    RPC_STOP_GUARD_PID=$(cat "$RPC_STOP_RACE_DIR/guardian.pid" 2>/dev/null || true)
    RPC_STOP_CHILD_PID=$(cat "$RPC_STOP_RACE_DIR/child.pid" 2>/dev/null || true)
    _leader_state=$(ps -o stat= -p "$RPC_STOP_PROBE_PID" 2>/dev/null || true)
    if [[ ! "$RPC_STOP_PROBE_PID" =~ ^[1-9][0-9]*$ \
          || ! -n "$_leader_state" || "$_leader_state" == *Z* ]] \
       && [[ "$RPC_STOP_GUARD_PID" =~ ^[1-9][0-9]*$ ]] \
       && kill -0 "$RPC_STOP_GUARD_PID" 2>/dev/null \
       && [[ "$RPC_STOP_CHILD_PID" =~ ^[1-9][0-9]*$ ]] \
       && kill -0 "$RPC_STOP_CHILD_PID" 2>/dev/null; then
      RPC_STOP_WINDOW=1
      break
    fi
  fi
  sleep 0.01
done
if (( RPC_STOP_WINDOW == 0 )); then
  kill -KILL "$RPC_STOP_OWNER_PID" 2>/dev/null || true
  wait "$RPC_STOP_OWNER_PID" 2>/dev/null || true
  bad "did not observe the leader-exited/stubborn-group normal-stop window"
else
  kill -KILL "$RPC_STOP_OWNER_PID" 2>/dev/null || true
  wait "$RPC_STOP_OWNER_PID" 2>/dev/null || true
  RPC_STOP_RUNTIME_DIR=$(cat "$RPC_STOP_RACE_DIR/runtime-dir" 2>/dev/null || true)
  _live=1
  for (( _n = 0; _n < 100; _n++ )); do
    _live=0
    for _pid in "$RPC_STOP_GUARD_PID" "$RPC_STOP_CHILD_PID"; do
      if [[ "$_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$_pid" 2>/dev/null \
         && [[ "$(ps -o stat= -p "$_pid" 2>/dev/null)" != *Z* ]]; then
        _live=1
      fi
    done
    (( _live == 0 )) && break
    sleep 0.05
  done
  if (( _live == 0 )) \
     && [[ -n "$RPC_STOP_RUNTIME_DIR" && ! -e "$RPC_STOP_RUNTIME_DIR" ]]; then
    ok
  else
    kill -KILL "$RPC_STOP_GUARD_PID" "$RPC_STOP_CHILD_PID" 2>/dev/null || true
    bad "guardian lost the stubborn process group during owner SIGKILL"
  fi
fi

t "runtime RPC: ambient cleanup variables are inert after common.sh is sourced"
RPC_AMBIENT_VICTIM="$WORK/runtime-rpc-ambient-victim"
printf keep > "$RPC_AMBIENT_VICTIM"
sleep 30 & RPC_AMBIENT_PID=$!
env -i PATH="$SYSPATH" HOME="$WORK" \
  RUNTIME_RPC_ACTIVE=1 RUNTIME_RPC_PID="$RPC_AMBIENT_PID" \
  RUNTIME_RPC_DIR="$WORK" RUNTIME_RPC_IN="$RPC_AMBIENT_VICTIM" \
  RUNTIME_RPC_OUT="$RPC_AMBIENT_VICTIM" RUNTIME_RPC_ERR="$RPC_AMBIENT_VICTIM" \
  "$BASH_BIN" -c '. "$1/lib/common.sh"; trap _runtime_rpc_stop_if_active EXIT; exit 1' \
  rpc-ambient "$ROOT" >/dev/null 2>&1 || true
if kill -0 "$RPC_AMBIENT_PID" 2>/dev/null && [[ -f "$RPC_AMBIENT_VICTIM" ]]; then
  ok
else
  bad "ambient RPC variables triggered unowned process/file cleanup"
fi
kill -KILL "$RPC_AMBIENT_PID" 2>/dev/null || true
wait "$RPC_AMBIENT_PID" 2>/dev/null || true

t "runtime RPC: an interrupted temporary pid handoff is never trusted"
sleep 30 & RPC_TMP_VICTIM_PID=$!
RPC_TMP_DIR="$WORK/runtime-rpc-unpublished-pid"
mkdir -p "$RPC_TMP_DIR"
RUNTIME_RPC_ACTIVE=1
RUNTIME_RPC_PID=''
RUNTIME_RPC_GUARDIAN_PID=''
RUNTIME_RPC_DIR="$RPC_TMP_DIR"
RUNTIME_RPC_IN="$RPC_TMP_DIR/in"
RUNTIME_RPC_OUT="$RPC_TMP_DIR/out"
RUNTIME_RPC_ERR="$RPC_TMP_DIR/err"
RUNTIME_RPC_READY="$RPC_TMP_DIR/ready"
RUNTIME_RPC_STATUS="$RPC_TMP_DIR/status"
RUNTIME_RPC_GUARDIAN_READY="$RPC_TMP_DIR/guardian-ready"
RUNTIME_RPC_PID_FILE="$RPC_TMP_DIR/rpc.pid"
printf '%s\n' "$RPC_TMP_VICTIM_PID" > "$RUNTIME_RPC_PID_FILE.tmp"
_runtime_rpc_stop
if kill -0 "$RPC_TMP_VICTIM_PID" 2>/dev/null; then
  ok
else
  bad "cleanup trusted an unpublished temporary pid"
fi
kill -KILL "$RPC_TMP_VICTIM_PID" 2>/dev/null || true
wait "$RPC_TMP_VICTIM_PID" 2>/dev/null || true

t "runtime RPC: no containment primitive fails before launching a subprocess"
RPC_NOSESSION_BIN="$WORK/runtime-rpc-no-session-bin"
mkdir -p "$RPC_NOSESSION_BIN"
ln -s "$(command -v mktemp)" "$RPC_NOSESSION_BIN/mktemp"
ln -s "$(command -v rm)" "$RPC_NOSESSION_BIN/rm"
ln -s "$(command -v rmdir)" "$RPC_NOSESSION_BIN/rmdir"
if env -i PATH="$RPC_NOSESSION_BIN" HOME="$WORK" "$BASH_BIN" -c '
  . "$1/lib/common.sh"
  if _runtime_rpc_start "$2" /bin/true; then exit 1; fi
  [[ "$RUNTIME_RPC_ACTIVE" == 0 && -z "$RUNTIME_RPC_PID" ]]
' rpc-no-session "$ROOT" "$WORK" >/dev/null 2>&1; then
  ok
else
  bad "runtime RPC launched or leaked state without setsid/perl"
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

t "codex cwd: native Windows and Git-Bash drive paths are equivalent"
if codex_cwd_matches 'D:\src\repo' /d/src/repo; then
  ok
else
  bad "equivalent Windows/MSYS paths differed"
fi

t "codex cwd: distinct Windows drive paths remain distinct"
if codex_cwd_matches 'D:\src\repo-a' /d/src/repo-b; then
  bad "distinct Windows/MSYS paths matched"
else
  ok
fi

DISC4="$WORK/discover-win-cwd"
mkdir -p "$DISC4/sessions"
: > "$DISC4/before-empty"
printf '%s\n' '{"payload":{"id":"win-root-uuid","cwd":"D:\\src\\repo","source":"exec"}}' \
  > "$DISC4/sessions/rollout-2026-01-01T00-00-01-root.jsonl"

t "discover: binds a native Windows rollout cwd to its Git-Bash checkout"
assert_eq "$(CODEX_HOME="$DISC4" discover_new_codex_session_id "$DISC4/before-empty" /d/src/repo)" win-root-uuid

t "discover: cwd binding fails closed on rollouts without a cwd (older codex)"
if CODEX_HOME="$DISC2" discover_new_codex_session_id "$DISC2/before-empty" /anywhere >/dev/null 2>&1; then
  bad "unexpectedly captured a root that cannot prove checkout ownership"
else
  ok
fi

DISC5="$WORK/discover4"
mkdir -p "$DISC5/sessions"
: > "$DISC5/before-empty"
printf '{"payload":{"id":"probe-uuid","cwd":"/checkout","source":"exec","model_provider":"ai_pr_loop_metadata_probe_cccc"}}\n' \
  > "$DISC5/sessions/rollout-2026-01-01T00-00-01-probe.jsonl"
printf '{"payload":{"id":"real-uuid","cwd":"/checkout","source":"exec"}}\n' \
  > "$DISC5/sessions/rollout-2026-01-01T00-00-02-real.jsonl"

t "discover: skips a metadata probe rollout that sorts first"
assert_eq "$(CODEX_HOME="$DISC5" discover_new_codex_session_id "$DISC5/before-empty" /checkout)" real-uuid

# --- _codex_metadata_probe_rollout -----------------------------------------
# One managed clone serves every PR of a repo, so two loops can probe from the
# same checkout at the same moment and both see both new rollouts. The peer
# below shares this probe's cwd, leaving the nonce as the only discriminator.

PROBE_SEL="$WORK/probe-select"
mkdir -p "$PROBE_SEL/sessions"
: > "$PROBE_SEL/before-empty"
printf '{"payload":{"cwd":"/checkout","model_provider":"ai_pr_loop_metadata_probe_aaaa"}}\n' \
  > "$PROBE_SEL/sessions/rollout-a-peer.jsonl"
printf '{"payload":{"cwd":"/checkout","model_provider":"ai_pr_loop_metadata_probe_bbbb"}}\n' \
  > "$PROBE_SEL/sessions/rollout-b-mine.jsonl"

t "probe select: picks this probe's nonce over an earlier-sorting peer"
assert_eq "$(CODEX_HOME="$PROBE_SEL" _codex_metadata_probe_rollout \
  "$PROBE_SEL/before-empty" ai_pr_loop_metadata_probe_bbbb /checkout)" \
  "$PROBE_SEL/sessions/rollout-b-mine.jsonl"

t "probe select: rejects this probe's nonce recorded for another checkout"
if CODEX_HOME="$PROBE_SEL" _codex_metadata_probe_rollout \
     "$PROBE_SEL/before-empty" ai_pr_loop_metadata_probe_bbbb /elsewhere \
     >/dev/null 2>&1; then
  bad "selected a rollout recorded for a different checkout"
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

t "resolve-session: validates a native Windows root against Git-Bash cwd"
assert_eq "$(CODEX_HOME="$DISC4" resolve_codex_root_session_id win-root-uuid /d/src/repo)" win-root-uuid

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

