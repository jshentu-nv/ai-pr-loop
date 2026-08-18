# --- auto-resume: restart decision table -----------------------------------
# The supervisor reads these files after every worker exit. Each row is
# exercised on its own fixture dir; the run.sh tests below then drive the
# same table through real front-end/supervisor/worker processes.

AR="$WORK/ar-state"
ar_reset() { rm -rf "$AR"; mkdir -p "$AR"; }

t "auto-resume: the stop sentinel outranks a restartable status"
ar_reset; : > "$AR/stop"; : > "$AR/worker.started"; printf 'codex_error\n' > "$AR/worker.status"
assert_eq "$(auto_resume_decision "$AR")" "stop stopped by request"

for _st in approved converged_no_major review_posted max_iterations_reached; do
  t "auto-resume: $_st is terminal"
  ar_reset; : > "$AR/worker.started"; printf '%s\n' "$_st" > "$AR/worker.status"
  assert_eq "$(auto_resume_decision "$AR")" "stop worker finished: $_st"
done

for _st in codex_error claude_error; do
  t "auto-resume: $_st restarts"
  ar_reset; : > "$AR/worker.started"; printf '%s\n' "$_st" > "$AR/worker.status"
  assert_eq "$(auto_resume_decision "$AR")" "restart agent turn failed ($_st)"
done

t "auto-resume: no status and no start stops (config/preflight error)"
ar_reset
assert_eq "$(auto_resume_decision "$AR")" "stop worker failed before it started (config/preflight error)"

t "auto-resume: no status after a start restarts (killed externally)"
ar_reset; : > "$AR/worker.started"
assert_eq "$(auto_resume_decision "$AR")" "restart worker died without writing a status (killed externally)"

t "auto-resume: an unrecognized status stops"
ar_reset; : > "$AR/worker.started"; printf 'weird\n' > "$AR/worker.status"
assert_eq "$(auto_resume_decision "$AR")" "stop unrecognized worker status: weird"

t "auto-resume: the first restart waits the floor, then doubles to the cap"
assert_eq "$(auto_resume_backoff 0)" 10
assert_eq "$(auto_resume_backoff 1)" 20
assert_eq "$(auto_resume_backoff 4)" 160
assert_eq "$(auto_resume_backoff 5)" 300
assert_eq "$(auto_resume_backoff 40)" 300

# --- auto-resume: context flags dropped from relaunch argv -------------------
# A retry that replays --context-file re-reads a path that may be gone; the
# supervisor relaunches with the context flags stripped and the worker
# reuses the persisted context.md. --restart passes through — its resume
# branch is half-step-aware, so replaying it is safe and keeps the forced
# round alive across retries.

t "auto-resume: relaunch argv drops --context-file with its value, keeps --restart"
strip_context_worker_flags 5 --repo o/n --restart --context-file /tmp/x --max 3
assert_eq "${STRIPPED_ARGV[*]+"${STRIPPED_ARGV[*]}"}" "5 --repo o/n --restart --max 3"

t "auto-resume: relaunch argv drops a newline-holding --context value intact"
strip_context_worker_flags --context "$(printf 'a\nb')" 7 --converge 2 --clear-context
assert_eq "${STRIPPED_ARGV[*]+"${STRIPPED_ARGV[*]}"}" "7 --converge 2"

t "auto-resume: a flag-shaped --context-file value is dropped with its flag"
strip_context_worker_flags 1 --context-file --no-auto-resume --repo o/n
assert_eq "${STRIPPED_ARGV[*]+"${STRIPPED_ARGV[*]}"}" "1 --repo o/n"

t "auto-resume: relaunch argv without context flags is unchanged"
strip_context_worker_flags 5 --repo o/n --max 3 --review-only
assert_eq "${STRIPPED_ARGV[*]+"${STRIPPED_ARGV[*]}"}" "5 --repo o/n --max 3 --review-only"

t "auto-resume: relaunch preserves both agent executable overrides"
strip_context_worker_flags 5 --claude-bin "$ALT_CLAUDE" --context note \
  --codex-bin "$ALT_CODEX" --max 3
assert_eq "${#STRIPPED_ARGV[@]}" 7
assert_eq "${STRIPPED_ARGV[0]}" 5
assert_eq "${STRIPPED_ARGV[1]}" --claude-bin
assert_eq "${STRIPPED_ARGV[2]}" "$ALT_CLAUDE"
assert_eq "${STRIPPED_ARGV[3]}" --codex-bin
assert_eq "${STRIPPED_ARGV[4]}" "$ALT_CODEX"
assert_eq "${STRIPPED_ARGV[5]}" --max
assert_eq "${STRIPPED_ARGV[6]}" 3

# --- auto-resume: run.sh roles ---------------------------------------------
# These start a real detached supervisor. Every case here kills the loop
# early (missing token, missing context file, failing fetch), so no case
# reaches an agent turn.  is gitignored; fixtures are removed as
# each case finishes.

AR_GH_STATE="$ROOT/state/o__n/pr-1"

t "run.sh: auto-resume is on by default and reports its budget"
rm -rf "$ROOT/state/o__n"
run_run_sh_supervised 1 --repo o/n
assert_substr "$AR_GH_STATE/supervisor.log" "auto-resume: supervisor started"
assert_substr "$AR_GH_STATE/supervisor.log" "budget 10 restart(s)"

t "run.sh: a worker that fails before starting is not relaunched"
assert_substr "$AR_GH_STATE/supervisor.log" "worker failed before it started"
if grep -Fq 'auto-resume: restart' "$AR_GH_STATE/supervisor.log"; then
  bad "the supervisor relaunched a config/preflight failure"
else
  ok
fi

t "run.sh: the front-end tails the supervisor log to its own stderr"
assert_substr "$WORK/run.err" "worker failed before it started"

t "run.sh: an unfinished run exits non-zero"
if [[ "$RUN_RC" -ne 0 ]]; then ok; else bad "front-end exited 0"; fi

t "run.sh: the supervisor removes its pid file on exit"
if [[ -e "$AR_GH_STATE/supervisor.pid" ]]; then
  bad "supervisor.pid survived the supervisor"
else
  ok
fi

t "run.sh: the supervisor hands the worker its argv verbatim (newline + quote)"
# A --context-file path carrying a newline and a quote: the worker dies on it
# and echoes the path, so the log proves the value crossed two process
# boundaries intact.
rm -rf "$ROOT/state/o__n"
run_run_sh_supervised 1 --repo o/n --context-file "$(printf 'ab\n"q" c')"
assert_substr "$AR_GH_STATE/supervisor.log" "not found or not a regular file: ab"
if grep -Fxq -- '"q" c' "$AR_GH_STATE/supervisor.log"; then ok; else bad "the newline in the forwarded argument was lost"; fi

t "run.sh: a flag-shaped option value is forwarded, not consumed"
rm -rf "$ROOT/state/o__n"
run_run_sh_supervised 1 --repo o/n --context-file --no-auto-resume
assert_substr "$AR_GH_STATE/supervisor.log" "not found or not a regular file: --no-auto-resume"

t "run.sh: --auto-resume rejects a non-numeric budget"
run_run_sh_supervised 1 --repo o/n --auto-resume abc
assert_dies_with "--auto-resume needs a non-negative count"

t "run.sh: --auto-resume needs a value"
run_run_sh_supervised 1 --repo o/n --auto-resume
assert_dies_with "--auto-resume needs a restart budget"

t "run.sh: --auto-resume 0 runs the loop in this process"
rm -rf "$ROOT/state/o__n"
run_run_sh_supervised 1 --repo o/n --auto-resume 0
assert_dies_with "GH_TOKEN/GITHUB_TOKEN not set"
if [[ -e "$ROOT/state/o__n" ]]; then bad "--auto-resume 0 still started a supervisor"; else ok; fi

t "run.sh: --no-auto-resume runs the loop in this process"
rm -rf "$ROOT/state/o__n"
run_run_sh 1 --repo o/n
assert_dies_with "GH_TOKEN/GITHUB_TOKEN not set"
if [[ -e "$ROOT/state/o__n" ]]; then bad "--no-auto-resume still started a supervisor"; else ok; fi

t "run.sh: --print-config never starts a supervisor"
rm -rf "$ROOT/state/o__n"
run_run_sh_supervised 1 --repo o/n --print-config
assert_prints 'codex: model=gpt-5.6-sol effort=ultra tier=fast context-window=258400 context-source=catalog-estimate'
if [[ -e "$ROOT/state/o__n" ]]; then bad "--print-config started a supervisor"; else ok; fi

t "run.sh: --preflight-only never starts a supervisor"
rm -rf "$ROOT/state/gitlab.com__g__p" "$ROOT/checkouts/gitlab.com__g__p"
run_run_sh_supervised STUB_MR_OPEN=1 9 --repo g/p --forge gitlab --preflight-only
assert_prints 'identity: testuser'
if [[ -e "$ROOT/state/gitlab.com__g__p" ]]; then bad "--preflight-only started a supervisor"; else ok; fi

t "run.sh: --stop ignores missing agent executables and exits 0 without a preflight"
rm -rf "$ROOT/state/o__n"
run_run_sh_supervised 1 --repo o/n \
  --claude-bin "$WORK/removed claude" --codex-bin "$WORK/removed codex" --stop
if [[ "$RUN_RC" -eq 0 && -e "$AR_GH_STATE/stop" ]]; then ok; else bad "--stop rc=$RUN_RC, sentinel missing"; fi
assert_substr "$WORK/run.err" "stop: wrote"

t "run.sh: a fresh run clears a prior stop sentinel"
run_run_sh_supervised 1 --repo o/n
if [[ -e "$AR_GH_STATE/stop" ]]; then bad "the stale sentinel survived a new invocation"; else ok; fi
rm -rf "$ROOT/state/o__n"

t "run.sh: a worker killed after it started is relaunched until the budget ends"
# The git stub fails the PR-head fetch, which happens after the worker
# recorded worker.started — the row the supervisor exists for. Budget 1, so
# one restart then a stop.
AR_BIN="$WORK/ar-bin"
mkdir -p "$AR_BIN"
cat > "$AR_BIN/git" <<'EOF'
#!/usr/bin/env bash
# Real git everywhere except the PR-head fetch, which fails.
for a in "$@"; do [[ "$a" == "fetch" ]] && exit 1; done
exec "$REAL_GIT" "$@"
EOF
chmod +x "$AR_BIN/git"
AR_REPO="$WORK/ar-repo"
git init -q "$AR_REPO"
git -C "$AR_REPO" remote add origin https://gl.example/g/p.git
rm -rf "$ROOT/state/gl.example__g__p"
SUP_PATH="$AR_BIN:$STUBS:$SYSPATH"
run_run_sh_supervised STUB_MR_OPEN=1 AUTO_RESUME_BACKOFF_FLOOR=1 \
  https://gl.example/g/p/-/merge_requests/9 --dir "$AR_REPO" --auto-resume 1
SUP_PATH=""
AR_GL_LOG="$ROOT/state/gl.example__g__p/pr-9/supervisor.log"
assert_substr "$AR_GL_LOG" "restart 1/1 in 1s — worker died without writing a status"
t "run.sh: the restart budget stops the loop"
assert_substr "$AR_GL_LOG" "budget exhausted after 1 restart(s)"
t "run.sh: a supervised run that never finished exits non-zero"
if [[ "$RUN_RC" -ne 0 ]]; then ok; else bad "front-end exited 0"; fi
rm -rf "$ROOT/state/gl.example__g__p"

# --- auto-resume: a long-lived worker resets the backoff --------------------
# Two quick deaths double the backoff; a worker that then outlives
# AUTO_RESUME_LONG_RUN is not a crash loop, so the next restart waits the
# floor again. The git stub counts fetches and makes the third one slow.

t "run.sh: a worker that outlives the long-run threshold resets the backoff"
AR_LR_BIN="$WORK/ar-longrun-bin"
mkdir -p "$AR_LR_BIN"
cat > "$AR_LR_BIN/git" <<'EOF'
#!/usr/bin/env bash
# Real git everywhere except the PR-head fetch: count the attempts, make
# attempt $STUB_FETCH_SLOW_ON outlive the long-run threshold, fail them all.
for a in "$@"; do
  if [[ "$a" == "fetch" ]]; then
    n=0; [[ -s "$STUB_FETCH_COUNT_FILE" ]] && n=$(cat "$STUB_FETCH_COUNT_FILE")
    n=$((n + 1)); printf '%s\n' "$n" > "$STUB_FETCH_COUNT_FILE"
    if [[ "$n" == "$STUB_FETCH_SLOW_ON" ]]; then sleep "$STUB_FETCH_SLOW_SECS"; fi
    exit 1
  fi
done
exec "$REAL_GIT" "$@"
EOF
chmod +x "$AR_LR_BIN/git"
rm -rf "$ROOT/state/gl.example__g__p"
# A leftover progress file from some earlier invocation must not eat the new
# invocation's budget; the supervisor clears it before its first worker.
mkdir -p "$ROOT/state/gl.example__g__p/pr-9"
printf 'RUNS=9\nSTREAK=9\n' > "$ROOT/state/gl.example__g__p/pr-9/worker.progress"
rm -f "$WORK/ar-lr-count"
# Git Bash process startup is materially slower than a native Unix fork.
# Keep ordinary retries comfortably below the long-run threshold, then make
# only the selected third attempt cross it.
AR_LR_THRESHOLD=15
AR_LR_SLOW_SECS=16
SUP_PATH="$AR_LR_BIN:$STUBS:$SYSPATH"
run_run_sh_supervised STUB_MR_OPEN=1 AUTO_RESUME_BACKOFF_FLOOR=1 \
  AUTO_RESUME_LONG_RUN="$AR_LR_THRESHOLD" STUB_FETCH_COUNT_FILE="$WORK/ar-lr-count" \
  STUB_FETCH_SLOW_ON=3 STUB_FETCH_SLOW_SECS="$AR_LR_SLOW_SECS" \
  https://gl.example/g/p/-/merge_requests/9 --dir "$AR_REPO" --auto-resume 3
SUP_PATH=""
assert_substr "$AR_GL_LOG" "restart 2/3 in 2s"
t "run.sh: the post-long-run restart waits the floor again"
assert_substr "$AR_GL_LOG" "restart 3/3 in 1s"
t "run.sh: a fresh supervised invocation clears a stale worker.progress"
if [[ -e "$ROOT/state/gl.example__g__p/pr-9/worker.progress" ]]; then
  bad "the stale worker.progress survived a new invocation"
else ok; fi
rm -rf "$ROOT/state/gl.example__g__p"

# --- auto-resume: a relaunch reuses the stored context -----------------------
# --context* inputs are read once, at launch. A relaunch must not re-read
# the original paths — here the temporary file is gone by the time the
# retry runs — it reuses the context.md the first worker persisted.

t "run.sh: a relaunch reuses stored context instead of re-reading --context-file"
AR_CTX_BIN="$WORK/ar-ctx-bin"
mkdir -p "$AR_CTX_BIN"
cat > "$AR_CTX_BIN/git" <<'EOF'
#!/usr/bin/env bash
# Real git everywhere except the PR-head fetch: remove the temporary
# context file — its content is already persisted to context.md — and fail.
for a in "$@"; do
  if [[ "$a" == "fetch" ]]; then
    rm -f "$STUB_CTX_KILL"
    exit 1
  fi
done
exec "$REAL_GIT" "$@"
EOF
chmod +x "$AR_CTX_BIN/git"
AR_CTX_FILE="$WORK/ar-ctx-note.md"
printf 'temporary trusted context\n' > "$AR_CTX_FILE"
rm -rf "$ROOT/state/gl.example__g__p"
SUP_PATH="$AR_CTX_BIN:$STUBS:$SYSPATH"
run_run_sh_supervised STUB_MR_OPEN=1 AUTO_RESUME_BACKOFF_FLOOR=1 \
  STUB_CTX_KILL="$AR_CTX_FILE" \
  https://gl.example/g/p/-/merge_requests/9 --dir "$AR_REPO" --auto-resume 1 \
  --context-file "$AR_CTX_FILE"
SUP_PATH=""
assert_substr "$AR_GL_LOG" "auto-resume: relaunches reuse the stored context once a worker lands this invocation's snapshot"
t "run.sh: the retried worker reads the persisted context.md"
assert_substr "$AR_GL_LOG" "context: reusing stored context"
t "run.sh: the retry does not die on the vanished --context-file path"
if grep -Fq 'not found or not a regular file' "$AR_GL_LOG"; then
  bad "the retry revalidated the removed --context-file path"
else ok; fi
rm -rf "$ROOT/state/gl.example__g__p"

# --- auto-resume: a render that dies mid-read leaves no partial context ------
# The snapshot lands via rename, whole or not at all: a source read that
# emits part of its content and then fails kills that worker with only the
# .tmp written. No context.applied stamp lands, so the retry replays the
# context flags and retries the replacement — failing loudly when the
# source keeps failing — instead of running on partial or absent context.

t "run.sh: a failed context render leaves no truncated context.md"
AR_PC_BIN="$WORK/ar-partialctx-bin"
mkdir -p "$AR_PC_BIN"
cp "$AR_BIN/git" "$AR_PC_BIN/git"
chmod +x "$AR_PC_BIN/git"
# The passthrough path is resolved while writing the stub — cat lives at
# /usr/bin/cat or /bin/cat depending on the host, and the stub's own PATH
# entry must not be consulted at run time.
cat > "$AR_PC_BIN/cat" <<EOF
#!/usr/bin/env bash
# Real cat, except the marked context source: emit a truncated read and
# fail, the shape of a source that vanishes mid-read.
if [[ "\${1:-}" == "--" && "\${2:-}" == "\${STUB_CTX_PARTIAL:-}" ]]; then
  printf 'PARTIAL-ONLY'
  exit 1
fi
exec $(command -v cat) "\$@"
EOF
chmod +x "$AR_PC_BIN/cat"
AR_PC_FILE="$WORK/ar-partial-note.md"
printf 'full trusted context\n' > "$AR_PC_FILE"
rm -rf "$ROOT/state/gl.example__g__p"
SUP_PATH="$AR_PC_BIN:$STUBS:$SYSPATH"
run_run_sh_supervised STUB_MR_OPEN=1 AUTO_RESUME_BACKOFF_FLOOR=1 \
  STUB_CTX_PARTIAL="$AR_PC_FILE" \
  https://gl.example/g/p/-/merge_requests/9 --dir "$AR_REPO" --auto-resume 1 \
  --context-file "$AR_PC_FILE"
SUP_PATH=""
if [[ -e "$ROOT/state/gl.example__g__p/pr-9/context.md" ]]; then
  bad "a truncated context.md landed as the trusted snapshot"
else ok; fi
t "run.sh: the retry replays the context flags and retries the replacement"
if grep -Fq 'reusing stored context' "$AR_GL_LOG"; then
  bad "the retry adopted stored context instead of retrying the replacement"
else ok; fi
assert_substr "$AR_GL_LOG" "budget exhausted"
rm -rf "$ROOT/state/gl.example__g__p"

t "run.sh: a failed replacement never falls back to the old stored context"
# An existing context.md is being REPLACED; the replacement read keeps
# failing. No worker may run against the old material — the run retries
# the replacement and stops, and the old file survives untouched for the
# operator.
AR_STALE_STATE="$ROOT/state/gl.example__g__p/pr-9"
rm -rf "$ROOT/state/gl.example__g__p"
mkdir -p "$AR_STALE_STATE"
printf 'OLD-CONTEXT-SHOULD-NOT-BE-USED\n' > "$AR_STALE_STATE/context.md"
printf 'fresh replacement\n' > "$AR_PC_FILE"
SUP_PATH="$AR_PC_BIN:$STUBS:$SYSPATH"
run_run_sh_supervised STUB_MR_OPEN=1 AUTO_RESUME_BACKOFF_FLOOR=1 \
  STUB_CTX_PARTIAL="$AR_PC_FILE" \
  https://gl.example/g/p/-/merge_requests/9 --dir "$AR_REPO" --auto-resume 1 \
  --context-file "$AR_PC_FILE"
SUP_PATH=""
if grep -Fq 'AI PR loop starting' "$AR_GL_LOG"; then
  bad "a worker ran while the replacement snapshot never landed"
else ok; fi
t "run.sh: the failed replacement leaves the old context.md intact"
if grep -Fxq 'OLD-CONTEXT-SHOULD-NOT-BE-USED' "$AR_STALE_STATE/context.md" 2>/dev/null; then ok
else bad "the old context.md was clobbered by the failed replacement"; fi
rm -rf "$ROOT/state/gl.example__g__p"

# --- auto-resume: a stale supervisor.pid -----------------------------------
# A supervisor killed with SIGKILL leaves its pid file behind, and that pid
# ends up owned by something else. The decoy leads its own session, so a
# group kill aimed at it would take down a whole unrelated process group.

# Run "$@" as the leader of its own session, in the background; the pid
# lands in SESSION_PID. perl is preferred over setsid(1) even where both
# exist: a background job of a non-job-control shell starts with SIGINT
# ignored, a signal ignored at entry cannot be re-trapped by a child bash,
# and the Ctrl-C case below needs the front-end's INT trap armed — perl
# restores the default disposition before detaching, which setsid(1)
# cannot do.
spawn_in_session() {
  if command -v perl >/dev/null 2>&1; then
    perl -e '$SIG{INT} = "DEFAULT"; use POSIX qw(setsid); setsid();
             exec @ARGV or exit 127' -- "$@" &
  elif command -v setsid >/dev/null 2>&1; then
    setsid "$@" &
  else
    "$@" &
  fi
  SESSION_PID=$!
}

t "run.sh: a stale supervisor.pid does not block a fresh run"
rm -rf "$ROOT/state/o__n"
mkdir -p "$AR_GH_STATE"
spawn_in_session sleep 120
AR_DECOY=$SESSION_PID
printf '%s\n' "$AR_DECOY" > "$AR_GH_STATE/supervisor.pid"
run_run_sh_supervised 1 --repo o/n
assert_substr "$AR_GH_STATE/supervisor.log" "auto-resume: supervisor started"

t "run.sh: --stop leaves a supervisor.pid naming an unrelated process alone"
printf '%s\n' "$AR_DECOY" > "$AR_GH_STATE/supervisor.pid"
run_run_sh_supervised 1 --repo o/n --stop
if [[ "$RUN_RC" -eq 0 ]] && kill -0 "$AR_DECOY" 2>/dev/null; then ok
else bad "--stop signalled a process that is not this loop's supervisor"; fi

t "run.sh: --stop reports no supervisor when the pid file is stale"
assert_substr "$WORK/run.err" "stop: no live supervisor"
kill "$AR_DECOY" 2>/dev/null
wait "$AR_DECOY" 2>/dev/null
rm -rf "$ROOT/state/o__n"

# --- auto-resume: a recycled pid that looks like a supervisor ---------------
# The OS can hand a dead supervisor's pid to ANOTHER loop's supervisor: the
# argv matches, but the start time does not. The decoy carries --_supervise
# in its argv and a pid-file token from another incarnation; neither --stop
# nor a fresh start may treat it as this PR's supervisor.

t "run.sh: --stop leaves a recycled pid with a matching argv alone"
rm -rf "$ROOT/state/o__n"
mkdir -p "$AR_GH_STATE"
# The compound command keeps bash resident (a single command would be
# exec-optimized into a bare `sleep`, losing --_supervise from the argv and
# making these cases pass on the argv check alone).
spawn_in_session bash -c 'sleep 120; :' decoy --_supervise
AR_DECOY2=$SESSION_PID
if tp_argv "$AR_DECOY2" | grep -q -- '--_supervise'; then
  printf '%s\nWed Jan 1 00:00:00 2020\n' "$AR_DECOY2" > "$AR_GH_STATE/supervisor.pid"
  run_run_sh_supervised 1 --repo o/n --stop
  if [[ "$RUN_RC" -eq 0 ]] && kill -0 "$AR_DECOY2" 2>/dev/null; then ok
  else bad "--stop signalled a recycled pid from another incarnation"; fi
  assert_substr "$WORK/run.err" "stop: no live supervisor"
else
  bad "fixture: decoy argv lost --_supervise"
fi

t "run.sh: a recycled pid with a matching argv does not block a fresh run"
rm -rf "$ROOT/state/o__n"
mkdir -p "$AR_GH_STATE"
printf '%s\nWed Jan 1 00:00:00 2020\n' "$AR_DECOY2" > "$AR_GH_STATE/supervisor.pid"
run_run_sh_supervised 1 --repo o/n
assert_substr "$AR_GH_STATE/supervisor.log" "auto-resume: supervisor started"
kill "$AR_DECOY2" 2>/dev/null
wait "$AR_DECOY2" 2>/dev/null
rm -rf "$ROOT/state/o__n"

# --- auto-resume: no session primitive → inline, loudly ---------------------
# Without setsid or perl there is no detached session: a supervisor would
# share the caller's process group and die with it. The front-end must say
# so and run the loop in this process instead of spawning a supervisor that
# provides no isolation.

t "run.sh: no setsid and no perl runs the loop inline with a warning"
AR_NP_BIN="$WORK/ar-noprim-bin"
mkdir -p "$AR_NP_BIN"
for _c in bash sh dirname date mkdir rmdir rm cat head tail grep sed awk tr \
          wc sleep ps git jq sort uniq cut ls env mktemp touch mv ln uname \
          id; do
  add_tool "$AR_NP_BIN" "$_c" || true
done
rm -rf "$ROOT/state/o__n"
env -i PATH="$STUBS:$AR_NP_BIN" HOME="$WORK" REAL_GIT="$REAL_GIT" \
  bash "$ROOT/run.sh" 1 --repo o/n > "$WORK/run.out" 2> "$WORK/run.err"
RUN_RC=$?
assert_dies_with "auto-resume: disabled — neither setsid nor perl found"
t "run.sh: the no-primitive inline run proceeds to the normal flow"
assert_dies_with "GH_TOKEN/GITHUB_TOKEN not set"
t "run.sh: the no-primitive run starts no supervisor"
if [[ -e "$ROOT/state/o__n" ]]; then bad "a supervisor state dir appeared without a session primitive"; else ok; fi

t "run.sh: setsid without flock or perl runs inline with a warning"
# A session primitive alone is not enough: supervision without a lock tool
# would run unlocked, so simultaneous starts could all win.
AR_SO_BIN="$WORK/ar-setsidonly-bin"
mkdir -p "$AR_SO_BIN"
clone_tool_dir "$AR_NP_BIN" "$AR_SO_BIN"
# Only `command -v setsid` consults this — the inline path never executes
# it — so a dummy keeps the case meaningful on hosts without setsid (macOS).
if _p=$(command -v setsid 2>/dev/null); then
  tool_shim "$AR_SO_BIN" setsid "$_p"
else
  printf '#!/bin/sh\nexit 0\n' > "$AR_SO_BIN/setsid"
  chmod +x "$AR_SO_BIN/setsid"
fi
rm -rf "$ROOT/state/o__n"
env -i PATH="$STUBS:$AR_SO_BIN" HOME="$WORK" REAL_GIT="$REAL_GIT" \
  bash "$ROOT/run.sh" 1 --repo o/n > "$WORK/run.out" 2> "$WORK/run.err"
RUN_RC=$?
assert_dies_with "no flock or perl to hold the single-supervisor lock"
t "run.sh: the setsid-only inline run proceeds to the normal flow"
assert_dies_with "GH_TOKEN/GITHUB_TOKEN not set"
t "run.sh: the setsid-only run starts no supervisor"
if [[ -e "$ROOT/state/o__n" ]]; then bad "a supervisor state dir appeared without a lock primitive"; else ok; fi

t "run.sh: a setsid without -f and no perl runs inline with a warning"
# BusyBox setsid has no -f: a session without reparenting cannot escape a
# tree reaper, so supervision must not start — and the warning must name
# the real gap, not claim setsid is missing.
AR_NF_BIN="$WORK/ar-nofork-bin"
mkdir -p "$AR_NF_BIN"
clone_tool_dir "$AR_NP_BIN" "$AR_NF_BIN"
cat > "$AR_NF_BIN/setsid" <<'EOF'
#!/bin/sh
# BusyBox-shaped setsid: rejects -f.
case "$1" in -f) echo "setsid: invalid option -- f" >&2; exit 1 ;; esac
exec "$@"
EOF
chmod +x "$AR_NF_BIN/setsid"
rm -rf "$ROOT/state/o__n"
env -i PATH="$STUBS:$AR_NF_BIN" HOME="$WORK" REAL_GIT="$REAL_GIT" \
  bash "$ROOT/run.sh" 1 --repo o/n > "$WORK/run.out" 2> "$WORK/run.err"
RUN_RC=$?
assert_dies_with "this setsid does not support -f"
t "run.sh: the no-fork inline run proceeds to the normal flow"
assert_dies_with "GH_TOKEN/GITHUB_TOKEN not set"
t "run.sh: the no-fork run starts no supervisor"
if [[ -e "$ROOT/state/o__n" ]]; then bad "a supervisor state dir appeared without a reparenting primitive"; else ok; fi

# --- auto-resume: state-path identity collisions -----------------------------
# The flat state path is not injective: o__c/r and o/c__r share a
# directory. Every entry point validates the .repo-slug marker before
# touching the dir, so a colliding repo's --stop or start fails loudly
# instead of stopping or sharing another repository's supervisor.

t "run.sh: --stop refuses a state dir owned by a colliding identity"
rm -rf "$ROOT/state/o__c__r"
mkdir -p "$ROOT/state/o__c__r/pr-1"
printf 'o__c/r\n' > "$ROOT/state/o__c__r/pr-1/.repo-slug"
run_run_sh_supervised 1 --repo o/c__r --stop
assert_dies_with "belongs to 'o__c/r', not 'o/c__r'"
t "run.sh: the colliding --stop writes no sentinel"
if [[ -e "$ROOT/state/o__c__r/pr-1/stop" ]]; then
  bad "the sentinel landed in another repository's state dir"
else ok; fi
t "run.sh: a supervised start refuses a colliding state dir"
run_run_sh_supervised 1 --repo o/c__r
assert_dies_with "belongs to 'o__c/r', not 'o/c__r'"
rm -rf "$ROOT/state/o__c__r"

t "run.sh: simultaneous first-touch stops elect exactly one identity"
# The marker is hard-linked into place, so among racing first-touchers of
# one fresh colliding dir the kernel picks one winner; the loser validates
# the winner's marker and dies. Exactly one of each pair may succeed.
AR_RACE_BAD=0
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
          21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
  rm -rf "$ROOT/state/race__o__r"
  env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" bash "$ROOT/run.sh" \
    1 --repo 'race__o/r' --stop >/dev/null 2>"$WORK/race.a.err" &
  _pa=$!
  env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" bash "$ROOT/run.sh" \
    1 --repo 'race/o__r' --stop >/dev/null 2>"$WORK/race.b.err" &
  _pb=$!
  _ra=0; wait "$_pa" || _ra=$?
  _rb=0; wait "$_pb" || _rb=$?
  if [[ "$_ra" -eq 0 && "$_rb" -eq 0 ]]; then AR_RACE_BAD=$((AR_RACE_BAD + 1)); fi
  if [[ "$_ra" -ne 0 && "$_rb" -ne 0 ]]; then AR_RACE_BAD=$((AR_RACE_BAD + 1)); fi
done
if [[ "$AR_RACE_BAD" -eq 0 ]]; then ok
else bad "$AR_RACE_BAD of 40 racing pairs did not elect exactly one owner"; fi
rm -rf "$ROOT/state/race__o__r"

t "run.sh: first-touch anchoring survives a filesystem without hard links"
# When ln cannot make hard links, the anchor falls back to a plain write —
# sequential validation must keep working.
AR_LN_BIN="$WORK/ar-noln-bin"
mkdir -p "$AR_LN_BIN"
printf '#!/bin/sh\nexit 1\n' > "$AR_LN_BIN/ln"
chmod +x "$AR_LN_BIN/ln"
rm -rf "$ROOT/state/o__n"
SUP_PATH="$AR_LN_BIN:$STUBS:$SYSPATH"
run_run_sh_supervised 1 --repo o/n --stop
SUP_PATH=""
if [[ "$RUN_RC" -eq 0 ]]; then ok; else bad "--stop failed under a failing ln (rc=$RUN_RC)"; fi
t "run.sh: the no-hard-link fallback still writes the identity marker"
assert_eq "$(cat "$AR_GH_STATE/.repo-slug" 2>/dev/null)" "o/n"
rm -rf "$ROOT/state/o__n"

t "run.sh: an empty identity marker is repaired on the next touch"
rm -rf "$ROOT/state/o__n"
mkdir -p "$AR_GH_STATE"
: > "$AR_GH_STATE/.repo-slug"
run_run_sh_supervised 1 --repo o/n --stop
if [[ "$RUN_RC" -eq 0 ]]; then ok; else bad "--stop failed on an empty marker (rc=$RUN_RC)"; fi
assert_eq "$(cat "$AR_GH_STATE/.repo-slug" 2>/dev/null)" "o/n"
rm -rf "$ROOT/state/o__n"

t "run.sh: racing first-touch stops elect one identity without hard links too"
# With ln failing, election goes through mkdir — atomic on every
# filesystem. Same contract as the hard-link path: one winner per pair.
AR_LNRACE_BAD=0
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
          21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
  rm -rf "$ROOT/state/race__o__r"
  env -i PATH="$AR_LN_BIN:$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" bash "$ROOT/run.sh" \
    1 --repo 'race__o/r' --stop >/dev/null 2>"$WORK/race.a.err" &
  _pa=$!
  env -i PATH="$AR_LN_BIN:$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" bash "$ROOT/run.sh" \
    1 --repo 'race/o__r' --stop >/dev/null 2>"$WORK/race.b.err" &
  _pb=$!
  _ra=0; wait "$_pa" || _ra=$?
  _rb=0; wait "$_pb" || _rb=$?
  if [[ "$_ra" -eq 0 && "$_rb" -eq 0 ]]; then AR_LNRACE_BAD=$((AR_LNRACE_BAD + 1)); fi
  if [[ "$_ra" -ne 0 && "$_rb" -ne 0 ]]; then AR_LNRACE_BAD=$((AR_LNRACE_BAD + 1)); fi
done
if [[ "$AR_LNRACE_BAD" -eq 0 ]]; then ok
else bad "$AR_LNRACE_BAD of 40 no-hard-link racing pairs did not elect exactly one owner"; fi
rm -rf "$ROOT/state/race__o__r"

# --- auto-resume: a live supervised run ------------------------------------
# The git stub blocks in the PR-head fetch and records its own pid, standing
# in for an agent turn in progress. That pid is how these cases tell whether a
# stop reached below the worker's shell.

AR_LIVE_BIN="$WORK/ar-live-bin"
mkdir -p "$AR_LIVE_BIN"
cat > "$AR_LIVE_BIN/git" <<'EOF'
#!/usr/bin/env bash
# Real git everywhere except the PR-head fetch: that one records its pid and
# blocks, the shape of a worker with an agent CLI under it.
for a in "$@"; do
  if [[ "$a" == "fetch" ]]; then
    printf '%s\n' "$$" > "$STUB_FETCH_PID_FILE"
    exec sleep 120
  fi
done
exec "$REAL_GIT" "$@"
EOF
chmod +x "$AR_LIVE_BIN/git"
AR_LIVE_REPO="$WORK/ar-live-repo"
git init -q "$AR_LIVE_REPO"
git -C "$AR_LIVE_REPO" remote add origin https://gl.example/g/p.git
AR_LIVE_STATE="$ROOT/state/gl.example__g__p/pr-9"
AR_LIVE_AGENT_FILE="$WORK/ar-live-agent.pid"
LIVE_FRONT=''; LIVE_SUP=''; LIVE_WORKER=''; LIVE_AGENT=''

live_wait() {  # path — up to 30s for it to appear
  local i
  for (( i = 0; i < 300; i++ )); do [[ -e "$1" ]] && return 0; sleep 0.1; done
  return 1
}
live_gone() {  # pid — up to 15s for it to exit
  local i
  for (( i = 0; i < 150; i++ )); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done
  return 1
}
# Start a supervised run in its own session and wait for the worker to reach
# the blocking fetch. LIVE_FRONT leads that session, so a process-group signal
# to it is what a terminal's Ctrl-C or a task runner's reap looks like.
live_start() {  # [extra PATH dir]
  local extra="${1:-}"
  rm -rf "$ROOT/state/gl.example__g__p" "$AR_LIVE_AGENT_FILE"
  spawn_in_session env -i PATH="${extra:+$extra:}$AR_LIVE_BIN:$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" \
    STUB_MR_OPEN=1 AUTO_RESUME_BACKOFF_FLOOR=1 \
    STUB_FETCH_PID_FILE="$AR_LIVE_AGENT_FILE" \
    bash "$ROOT/run.sh" https://gl.example/g/p/-/merge_requests/9 \
      --dir "$AR_LIVE_REPO" \
    > "$WORK/live.out" 2> "$WORK/live.err"
  LIVE_FRONT=$SESSION_PID
  [[ "$(tp_pgid "$LIVE_FRONT")" == "$LIVE_FRONT" ]] || return 1
  live_wait "$AR_LIVE_AGENT_FILE" || return 1
  LIVE_AGENT=$(head -1 "$AR_LIVE_AGENT_FILE")
  LIVE_WORKER=$(tp_ppid "$LIVE_AGENT")
  LIVE_SUP=$(head -1 "$AR_LIVE_STATE/supervisor.pid" 2>/dev/null)
  [[ -n "$LIVE_AGENT" && -n "$LIVE_WORKER" && -n "$LIVE_SUP" ]]
}
live_cleanup() {
  env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" bash "$ROOT/run.sh" \
    9 --repo g/p --forge gitlab --host gl.example --stop >/dev/null 2>&1
  # Belt and braces with fixture-owned pids only: a --stop that raced a
  # relaunch can miss its signal, and a leaked supervisor (default budget,
  # 120s worker cycles) would stomp this shared state dir for the next
  # twenty minutes of suite runs. The sentinel from --stop is on disk, so
  # a direct TERM takes the shutdown path.
  local _lp
  _lp=$(head -1 "$AR_LIVE_STATE/supervisor.pid" 2>/dev/null)
  [[ "$_lp" =~ ^[0-9]+$ ]] && kill -TERM "$_lp" 2>/dev/null
  [[ -n "${LIVE_SUP:-}" ]] && kill -TERM "$LIVE_SUP" 2>/dev/null
  [[ -n "${LIVE_WORKER:-}" ]] && kill -TERM "$LIVE_WORKER" 2>/dev/null
  kill "$LIVE_FRONT" 2>/dev/null
  wait "$LIVE_FRONT" 2>/dev/null
  kill "$LIVE_AGENT" 2>/dev/null
  [[ -n "${LIVE_SUP:-}" ]] && live_gone "$LIVE_SUP"
  rm -rf "$ROOT/state/gl.example__g__p"
}

t "run.sh: the front-end names the live supervisor it started"
if live_start; then
  assert_substr "$WORK/live.err" "auto-resume: supervisor pid $LIVE_SUP,"
else
  bad "the supervised run never reached the blocking fetch"
fi

t "run.sh: a process-group TERM on the front-end leaves the supervisor running"
kill -TERM -- "-$LIVE_FRONT" 2>/dev/null
wait "$LIVE_FRONT" 2>/dev/null
if kill -0 "$LIVE_SUP" 2>/dev/null && kill -0 "$LIVE_AGENT" 2>/dev/null; then ok
else bad "the reaped front-end took the supervisor or the agent with it"; fi

t "run.sh: the reaped front-end says where the run continues"
assert_substr "$WORK/live.err" "front-end signalled; supervisor pid $LIVE_SUP keeps running"

t "run.sh: a second run refuses to start while a supervisor is live"
run_run_sh_supervised STUB_MR_OPEN=1 \
  https://gl.example/g/p/-/merge_requests/9 --dir "$AR_LIVE_REPO"
assert_dies_with "a supervisor for this PR is already running"

t "run.sh: --stop ends the supervisor and the agent below the worker"
env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" bash "$ROOT/run.sh" \
  9 --repo g/p --forge gitlab --host gl.example --stop >/dev/null 2>&1
if live_gone "$LIVE_SUP" && live_gone "$LIVE_AGENT"; then ok
else bad "the supervisor or the agent survived --stop"; fi
live_cleanup

# --- agent_guard: expiry against a real supervised run ---------------------
#
# The stub-level guard cases prove the sequencing. This one proves the whole
# boundary: a real detached supervisor, a real worker, and a real blocking
# agent below it. The lease is held by hand until the agent is up, so the
# expiry lands at a known point instead of racing the fetch.

t "agent_guard: an expired lease stops a real supervised run and its agent"
rm -rf "$ROOT/state/gl.example__g__p" "$AR_LIVE_AGENT_FILE"
GEX_HB="$WORK/guard-expiry.heartbeat"
rm -f "$GEX_HB" "$GEX_HB.exit" "$GEX_HB.guard-pid"
env -i PATH="$AR_LIVE_BIN:$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" \
  STUB_MR_OPEN=1 AUTO_RESUME_BACKOFF_FLOOR=1 \
  STUB_FETCH_PID_FILE="$AR_LIVE_AGENT_FILE" \
  AI_PR_LOOP_AGENT_GUARD_MIN_TIMEOUT_SECONDS=5 \
  AI_PR_LOOP_AGENT_GUARD_POLL_SECONDS=1 \
  AI_PR_LOOP_AGENT_GUARD_STOP_GRACE_SECONDS=20 \
  bash "$ROOT/agent_guard.sh" "$GEX_HB" 5 -- \
    bash "$ROOT/run.sh" https://gl.example/g/p/-/merge_requests/9 \
      --dir "$AR_LIVE_REPO" \
  > "$WORK/guard-expiry.out" 2>&1 &
GEX_GUARD=$!
GEX_UP=0
for (( _i = 0; _i < 400; _i++ )); do
  date +%s > "$GEX_HB" 2>/dev/null || true   # hold the lease while it starts
  [[ -e "$AR_LIVE_AGENT_FILE" ]] && { GEX_UP=1; break; }
  sleep 0.1
done
if (( GEX_UP == 1 )); then
  GEX_AGENT=$(head -1 "$AR_LIVE_AGENT_FILE")
  GEX_SUP=$(head -1 "$AR_LIVE_STATE/supervisor.pid" 2>/dev/null)
  wait "$GEX_GUARD"; GEX_RC=$?          # renewals stopped: the lease expires
  assert_eq "$GEX_RC" 124
  assert_substr "$WORK/guard-expiry.out" 'stop: signalled supervisor pid'
  if [[ -n "$GEX_SUP" ]] && live_gone "$GEX_SUP"; then ok
  else bad "the supervisor survived the expired lease (pid ${GEX_SUP:-unknown})"; fi
  if live_gone "$GEX_AGENT"; then ok
  else bad "the agent survived the expired lease (pid $GEX_AGENT)"; fi
  assert_eq "$(cat "$GEX_HB.exit" 2>/dev/null)" 124
  kill -9 "$GEX_AGENT" "${GEX_SUP:-0}" 2>/dev/null
else
  kill -9 "$GEX_GUARD" 2>/dev/null
  bad "the guarded run never reached the blocking fetch"
fi
rm -rf "$ROOT/state/gl.example__g__p"

# --- auto-resume: simultaneous starts --------------------------------------
# Several front-ends starting the same PR at once race the supervisor lock;
# the kernel elects exactly one. The losers either refuse or attach to the
# winner as observers — none may start a second supervisor.

t "run.sh: simultaneous starts elect exactly one supervisor"
rm -rf "$ROOT/state/gl.example__g__p" "$AR_LIVE_AGENT_FILE"
AR_SIM_PIDS=()
for _i in 1 2 3 4 5 6; do
  env -i PATH="$AR_LIVE_BIN:$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" \
    STUB_MR_OPEN=1 AUTO_RESUME_BACKOFF_FLOOR=1 \
    STUB_FETCH_PID_FILE="$AR_LIVE_AGENT_FILE" \
    bash "$ROOT/run.sh" https://gl.example/g/p/-/merge_requests/9 \
      --dir "$AR_LIVE_REPO" \
    > "$WORK/sim.$_i.out" 2> "$WORK/sim.$_i.err" &
  AR_SIM_PIDS+=($!)
done
if live_wait "$AR_LIVE_AGENT_FILE"; then
  sleep 2   # let every straggler finish its start attempt
  AR_SIM_STARTED=$(grep -c 'auto-resume: supervisor started' "$AR_LIVE_STATE/supervisor.log")
  if [[ "$AR_SIM_STARTED" == 1 ]]; then ok
  else bad "expected exactly 1 supervisor, got $AR_SIM_STARTED"; fi
else
  bad "no supervisor's worker ever reached the blocking fetch"
fi
env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" bash "$ROOT/run.sh" \
  9 --repo g/p --forge gitlab --host gl.example --stop >/dev/null 2>&1
# Front-ends observing the stopped supervisor drain on their own; TERM any
# straggler so a regression here cannot hang the suite.
for _p in ${AR_SIM_PIDS[@]+"${AR_SIM_PIDS[@]}"}; do
  live_gone "$_p" || kill -TERM "$_p" 2>/dev/null
  wait "$_p" 2>/dev/null
done
rm -rf "$ROOT/state/gl.example__g__p"

# Only the stop sentinel means the review should end; a TERM aimed straight
# at the supervisor without one is the external noise auto-resume exists to
# survive.
t "run.sh: a sentinel-less TERM to the supervisor is ignored — the review continues"
if live_start; then
  kill -TERM "$LIVE_SUP" 2>/dev/null
  sleep 1
  if kill -0 "$LIVE_SUP" 2>/dev/null && kill -0 "$LIVE_AGENT" 2>/dev/null; then ok
  else bad "a TERM without the stop sentinel took the supervisor or the agent down"; fi
  t "run.sh: the ignored signal is logged"
  assert_substr "$AR_LIVE_STATE/supervisor.log" "signalled without a stop request"
  t "run.sh: --stop still ends a supervisor that ignored a stray TERM"
  env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" bash "$ROOT/run.sh" \
    9 --repo g/p --forge gitlab --host gl.example --stop >/dev/null 2>&1
  if live_gone "$LIVE_SUP" && live_gone "$LIVE_AGENT"; then ok
  else bad "--stop failed after an ignored stray TERM"; fi
else
  bad "the supervised run never reached the blocking fetch"
  t "run.sh: the ignored signal is logged"
  bad "the supervised run never reached the blocking fetch"
  t "run.sh: --stop still ends a supervisor that ignored a stray TERM"
  bad "the supervised run never reached the blocking fetch"
fi
live_cleanup

# --- auto-resume: a tree reaper ---------------------------------------------
# Task runners kill jobs by walking the job's process TREE, which a new
# session alone does not escape. The supervisor is reparented at spawn
# (setsid -f / perl fork), so the walk must not find it, and TERMing the
# front-end plus every found descendant must leave the review running.

tree_pids() {  # pid → all its descendant pids, from one ps snapshot
  ps -eo pid=,ppid= | awk -v root="$1" '
    { kid[$2] = kid[$2] " " $1 }
    END {
      queue = kid[root]
      while (queue != "") {
        n = split(queue, q, " "); queue = ""
        for (i = 1; i <= n; i++) if (q[i] != "") { print q[i]; queue = queue kid[q[i]] }
      }
    }'
}

t "run.sh: the supervisor is not a descendant of the front-end"
if live_start; then
  AR_TREE=$(tree_pids "$LIVE_FRONT")
  if grep -qx "$LIVE_SUP" <<<"$AR_TREE"; then
    bad "the supervisor is still in the front-end's descendant tree"
  else ok; fi
  t "run.sh: a tree reaper TERMing the front-end and descendants leaves the review"
  for _p in $AR_TREE; do kill -TERM "$_p" 2>/dev/null; done
  kill -TERM "$LIVE_FRONT" 2>/dev/null
  wait "$LIVE_FRONT" 2>/dev/null
  sleep 1
  if kill -0 "$LIVE_SUP" 2>/dev/null && kill -0 "$LIVE_AGENT" 2>/dev/null; then ok
  else bad "the tree reap took the supervisor or the agent down"; fi
else
  bad "the supervised run never reached the blocking fetch"
  t "run.sh: a tree reaper TERMing the front-end and descendants leaves the review"
  bad "the supervised run never reached the blocking fetch"
fi
live_cleanup

# The perl-only battery needs perl on the host (the same convention as the
# Ctrl-C block): without it the curated PATH has no session primitive at
# all and the run falls back inline, which is a different case entirely.
if ! command -v perl >/dev/null 2>&1; then
  printf 'SKIP: perl-only live cases need perl on the host\n' >&2
else

t "run.sh: perl-only hosts reparent the supervisor out of the front-end tree"
# macOS shape: no setsid at all, perl does the fork+setsid+exec. The
# whole run executes on a curated PATH without setsid; the reparenting
# contract must hold exactly as on util-linux hosts.
AR_PERLONLY_BIN="$WORK/ar-perlonly-bin"
mkdir -p "$AR_PERLONLY_BIN"
clone_tool_dir "$AR_NP_BIN" "$AR_PERLONLY_BIN"
for _c in perl flock; do
  add_tool "$AR_PERLONLY_BIN" "$_c" || true
done
rm -rf "$ROOT/state/gl.example__g__p" "$AR_LIVE_AGENT_FILE"
spawn_in_session env -i PATH="$AR_LIVE_BIN:$STUBS:$AR_PERLONLY_BIN" HOME="$WORK" REAL_GIT="$REAL_GIT" \
  STUB_MR_OPEN=1 AUTO_RESUME_BACKOFF_FLOOR=1 \
  STUB_FETCH_PID_FILE="$AR_LIVE_AGENT_FILE" \
  bash "$ROOT/run.sh" https://gl.example/g/p/-/merge_requests/9 \
    --dir "$AR_LIVE_REPO" \
  > "$WORK/po.out" 2> "$WORK/po.err"
AR_PO_FRONT=$SESSION_PID
if live_wait "$AR_LIVE_AGENT_FILE"; then
  AR_PO_SUP=$(head -1 "$AR_LIVE_STATE/supervisor.pid" 2>/dev/null)
  AR_PO_AGENT=$(head -1 "$AR_LIVE_AGENT_FILE")
  AR_PO_TREE=$(tree_pids "$AR_PO_FRONT")
  if [[ -n "$AR_PO_SUP" ]] && ! grep -qx "$AR_PO_SUP" <<<"$AR_PO_TREE"; then ok
  else bad "the perl-only spawn left the supervisor in the front-end tree (sup=${AR_PO_SUP:-none})"; fi
  t "run.sh: a tree reap on the perl-only front-end leaves the review running"
  for _p in $AR_PO_TREE; do kill -TERM "$_p" 2>/dev/null; done
  kill -TERM "$AR_PO_FRONT" 2>/dev/null
  wait "$AR_PO_FRONT" 2>/dev/null
  sleep 1
  if kill -0 "$AR_PO_SUP" 2>/dev/null && kill -0 "$AR_PO_AGENT" 2>/dev/null; then ok
  else bad "the tree reap took the perl-only supervisor or agent down"; fi
else
  bad "the perl-only supervised run never reached the blocking fetch ($(tail -2 "$WORK/po.err" 2>/dev/null | tr '\n' ' '))"
  t "run.sh: a tree reap on the perl-only front-end leaves the review running"
  bad "the perl-only supervised run never reached the blocking fetch"
fi
env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" bash "$ROOT/run.sh" \
  9 --repo g/p --forge gitlab --host gl.example --stop >/dev/null 2>&1
# Fixture-owned belt and braces: the sentinel from --stop is on disk, so a
# direct TERM takes the shutdown path even if --stop's own signal missed.
[[ "${AR_PO_SUP:-}" =~ ^[0-9]+$ ]] && kill -TERM "$AR_PO_SUP" 2>/dev/null
[[ -n "${AR_PO_SUP:-}" ]] && live_gone "$AR_PO_SUP"
kill "$AR_PO_FRONT" 2>/dev/null
wait "$AR_PO_FRONT" 2>/dev/null
[[ -n "${AR_PO_AGENT:-}" ]] && kill "$AR_PO_AGENT" 2>/dev/null
rm -rf "$ROOT/state/gl.example__g__p"

fi  # perl guard for the perl-only live cases

t "run.sh: a sentinel-less group TERM during the backoff is survived"
# The ignore-trap returns into an interrupted `sleep`, whose 143 must not
# end the supervisor through set -e; the loop continues to the relaunch.
rm -rf "$ROOT/state/gl.example__g__p"
spawn_in_session env -i PATH="$AR_BIN:$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" \
  STUB_MR_OPEN=1 AUTO_RESUME_BACKOFF_FLOOR=6 \
  bash "$ROOT/run.sh" https://gl.example/g/p/-/merge_requests/9 \
    --dir "$AR_REPO" --auto-resume 1 > "$WORK/bk.out" 2> "$WORK/bk.err"
AR_BK_FRONT=$SESSION_PID
for (( _i = 0; _i < 300; _i++ )); do
  grep -q 'restart 1/1 in 6s' "$AR_GL_LOG" 2>/dev/null && break
  sleep 0.1
done
AR_BK_SUP=$(head -1 "$ROOT/state/gl.example__g__p/pr-9/supervisor.pid" 2>/dev/null)
if [[ "$AR_BK_SUP" =~ ^[0-9]+$ ]]; then
  sleep 1   # land inside the backoff sleep
  kill -TERM -- "-$AR_BK_SUP" 2>/dev/null
  wait "$AR_BK_FRONT" 2>/dev/null
  if grep -Fq 'signalled without a stop request' "$AR_GL_LOG" \
     && grep -Fq 'budget exhausted' "$AR_GL_LOG"; then ok
  else bad "the group TERM during the backoff ended the supervisor early"; fi
else
  bad "no supervisor pid recorded before the backoff"
fi
rm -rf "$ROOT/state/gl.example__g__p"

# --- auto-resume: --stop reaches a worker orphaned by a supervisor SIGKILL --
# A SIGKILLed supervisor leaves its worker tree alive (holding the lock),
# and the worker never reads the stop sentinel. --stop must find the
# recorded worker, verify its incarnation, and TERM its process group.

t "run.sh: --stop reaches the worker tree after the supervisor is SIGKILLed"
if live_start; then
  kill -9 "$LIVE_SUP" 2>/dev/null
  live_gone "$LIVE_SUP"
  if kill -0 "$LIVE_AGENT" 2>/dev/null; then
    env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" bash "$ROOT/run.sh" \
      9 --repo g/p --forge gitlab --host gl.example --stop \
      > "$WORK/orph.out" 2> "$WORK/orph.err"
    if live_gone "$LIVE_AGENT" && live_gone "$LIVE_WORKER"; then ok
    else bad "the orphaned worker/agent survived --stop"; fi
    t "run.sh: the orphan stop names the worker group it signalled"
    assert_substr "$WORK/orph.err" "signalled the orphaned worker"
  else
    bad "fixture: the agent died with the SIGKILLed supervisor"
    t "run.sh: the orphan stop names the worker group it signalled"
    bad "fixture: the agent died with the SIGKILLed supervisor"
  fi
else
  bad "the supervised run never reached the blocking fetch"
  t "run.sh: the orphan stop names the worker group it signalled"
  bad "the supervised run never reached the blocking fetch"
fi
live_cleanup

# --- auto-resume: a real Ctrl-C ---------------------------------------------
# SIGINT to the front-end's process group is what a terminal Ctrl-C
# delivers (the supervisor sits in another session and only hears about it
# from the trap). The whole contract in one shot: exit 130, sentinel
# written, supervisor and agent down, pid file removed, nothing relaunched.
# Needs perl: only spawn_in_session's perl arm restores the default SIGINT
# disposition a background-launched shell starts without, and bash cannot
# re-trap a signal that was ignored at entry.

if ! command -v perl >/dev/null 2>&1; then
  printf 'SKIP: Ctrl-C live cases need perl to arm SIGINT in the fixture\n' >&2
else

t "run.sh: Ctrl-C exits 130 and writes the stop sentinel"
if live_start; then
  kill -INT -- "-$LIVE_FRONT" 2>/dev/null
  if live_gone "$LIVE_FRONT"; then
    AR_INT_RC=0; wait "$LIVE_FRONT" 2>/dev/null || AR_INT_RC=$?
    if [[ "$AR_INT_RC" -eq 130 && -e "$AR_LIVE_STATE/stop" ]]; then ok
    else bad "rc=$AR_INT_RC, sentinel $([[ -e "$AR_LIVE_STATE/stop" ]] && echo present || echo missing)"; fi
  else
    bad "the front-end survived SIGINT"
  fi
  t "run.sh: Ctrl-C takes the supervisor and the agent down"
  if live_gone "$LIVE_SUP" && live_gone "$LIVE_AGENT"; then ok
  else bad "the supervisor or the agent survived Ctrl-C"; fi
  t "run.sh: Ctrl-C leaves no pid file and no relaunch behind"
  if [[ ! -e "$AR_LIVE_STATE/supervisor.pid" ]] \
     && ! grep -Fq 'auto-resume: restart' "$AR_LIVE_STATE/supervisor.log"; then ok
  else bad "supervisor.pid survived Ctrl-C, or the supervisor relaunched"; fi
else
  bad "the supervised run never reached the blocking fetch"
  t "run.sh: Ctrl-C takes the supervisor and the agent down"
  bad "the supervised run never reached the blocking fetch"
  t "run.sh: Ctrl-C leaves no pid file and no relaunch behind"
  bad "the supervised run never reached the blocking fetch"
fi
live_cleanup

fi  # perl guard for the Ctrl-C live cases

t "run.sh: the stop sentinel stops a live supervisor instead of relaunching"
if live_start; then
  : > "$AR_LIVE_STATE/stop"
  kill -TERM "$LIVE_WORKER" 2>/dev/null
  if live_gone "$LIVE_SUP"; then
    assert_substr "$AR_LIVE_STATE/supervisor.log" "stopping — stopped by request"
  else
    bad "the supervisor ignored the stop sentinel"
  fi
  t "run.sh: a killed worker's agent does not outlive it"
  if live_gone "$LIVE_AGENT"; then ok
  else bad "the agent survived the worker the supervisor is done with"; fi
else
  bad "the supervised run never reached the blocking fetch"
  t "run.sh: a killed worker's agent does not outlive it"
  bad "the supervised run never reached the blocking fetch"
fi
live_cleanup

t "run.sh: a SIGKILLed front-end leaves no tail behind"
if live_start; then
  # live_start returns when the worker's fetch blocks, which can precede
  # the front-end spawning its tail — poll for the tail child first.
  LIVE_TAIL=''
  for (( _i = 0; _i < 100; _i++ )); do
    LIVE_TAIL=$(tp_child_matching "$LIVE_FRONT" tail) || LIVE_TAIL=''
    [[ -n "$LIVE_TAIL" ]] && break
    sleep 0.1
  done
  kill -9 "$LIVE_FRONT" 2>/dev/null
  wait "$LIVE_FRONT" 2>/dev/null
  if [[ -z "$LIVE_TAIL" ]]; then bad "no tail found under the front-end"
  elif live_gone "$LIVE_TAIL"; then ok
  else bad "the tail outlived the front-end that started it"; fi
else
  bad "the supervised run never reached the blocking fetch"
fi
live_cleanup

t "run.sh: the front-end reads the supervisor pid when the log line wins the race"
# The startup poll checks the pid file, then greps the log. A slow tail lets
# the supervisor write both while that grep is in flight, so the poll returns
# on the log line — and must still come back with the pid.
AR_RACE_BIN="$WORK/ar-race-bin"
mkdir -p "$AR_RACE_BIN"
cat > "$AR_RACE_BIN/tail" <<'EOF'
#!/usr/bin/env bash
sleep 0.3
exec /usr/bin/tail "$@"
EOF
chmod +x "$AR_RACE_BIN/tail"
if live_start "$AR_RACE_BIN"; then
  assert_substr "$WORK/live.err" "auto-resume: supervisor pid $LIVE_SUP,"
else
  bad "the supervised run never reached the blocking fetch"
fi
live_cleanup

# --- auto-resume: a stop that lands before the supervisor is up ------------
# Ctrl-C in the first moments of a run writes the sentinel while the
# supervisor is still starting, so the supervisor reads it before each worker.

t "run.sh: the front-end arms its Ctrl-C trap before it spawns the supervisor"
AR_TRAP_LINE=$(grep -n '^  trap frontend_interrupt INT$' "$ROOT/run.sh" | head -1 | cut -d: -f1)
AR_SPAWN_LINE=$(grep -n '^  spawn_detached bash ' "$ROOT/run.sh" | head -1 | cut -d: -f1)
if [[ -n "$AR_TRAP_LINE" && -n "$AR_SPAWN_LINE" ]] && (( AR_TRAP_LINE < AR_SPAWN_LINE )); then ok
else bad "a Ctrl-C between the spawn and the trap would orphan the supervisor (trap line ${AR_TRAP_LINE:-none}, spawn line ${AR_SPAWN_LINE:-none})"; fi

t "run.sh: a supervisor that starts on a stop sentinel runs no worker"
rm -rf "$ROOT/state/gl.example__g__p"
mkdir -p "$AR_LIVE_STATE"
: > "$AR_LIVE_STATE/stop"
env -i PATH="$AR_BIN:$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" STUB_MR_OPEN=1 \
  bash "$ROOT/run.sh" --_supervise --auto-resume 1 \
    https://gl.example/g/p/-/merge_requests/9 --dir "$AR_LIVE_REPO" \
  > "$WORK/sup.out" 2> "$WORK/sup.err"
if grep -Fq 'stopping — stopped by request' "$WORK/sup.err" \
   && [[ ! -e "$AR_LIVE_STATE/worker.started" ]]; then ok
else bad "the supervisor ran a worker although the run was already stopped"; fi
rm -rf "$ROOT/state/gl.example__g__p"

# --- auto-resume: a run that reaches a terminal status ----------------------
# The only case here that gets past an agent turn: the git stub serves the PR
# head from a local bare repo and the codex stub approves, so the worker
# reports a terminal status the supervisor must not relaunch.

AR_APP_BIN="$WORK/ar-approve-bin"
mkdir -p "$AR_APP_BIN"
cat > "$AR_APP_BIN/git" <<'EOF'
#!/usr/bin/env bash
# Real git, with the PR-head fetch served by a local bare repo (origin's URL
# names the MR's project, which no test may reach).
args=(); fetching=0
for a in "$@"; do [[ "$a" == "fetch" ]] && fetching=1; done
for a in "$@"; do
  if (( fetching == 1 )) && [[ "$a" == "origin" ]]; then a="$STUB_GIT_REMOTE"; fi
  args+=("$a")
done
exec "$REAL_GIT" "${args[@]}"
EOF
chmod +x "$AR_APP_BIN/git"
AR_APP_REMOTE="$WORK/ar-approve-remote.git"
AR_APP_SEED="$WORK/ar-approve-seed"
AR_APP_REPO="$WORK/ar-approve-repo"
git init -q --bare "$AR_APP_REMOTE"
git init -q "$AR_APP_SEED"
git -C "$AR_APP_SEED" symbolic-ref HEAD refs/heads/main
printf 'seed\n' > "$AR_APP_SEED/f.txt"
git -C "$AR_APP_SEED" add f.txt
git -C "$AR_APP_SEED" -c user.email=t@example -c user.name=t commit -q -m seed
git -C "$AR_APP_SEED" branch feat/x
git -C "$AR_APP_SEED" push -q "$AR_APP_REMOTE" main feat/x
git -C "$AR_APP_REMOTE" symbolic-ref HEAD refs/heads/main
git clone -q "$AR_APP_REMOTE" "$AR_APP_REPO"
git -C "$AR_APP_REPO" checkout -q feat/x
git -C "$AR_APP_REPO" remote set-url origin https://gl.example/g/p.git

t "run.sh: a worker that finishes records its status"
rm -rf "$ROOT/state/gl.example__g__p"
mkdir -p "$WORK/ar-approve-codex/sessions"
AR_SUP_AGENT_LOG="$WORK/ar-supervised-agent-exe.log"
: > "$AR_SUP_AGENT_LOG"
SUP_PATH="$AR_APP_BIN:$STUBS:$SYSPATH"
# Budget 1 at a 1s backoff: an approved run must not relaunch at all, and a
# fixture that breaks stops in seconds instead of backing off for minutes.
run_run_sh_supervised STUB_MR_OPEN=1 STUB_GIT_REMOTE="$AR_APP_REMOTE" \
  CODEX_HOME="$WORK/ar-approve-codex" AGENT_EXE_LOG="$AR_SUP_AGENT_LOG" \
  AUTO_RESUME_BACKOFF_FLOOR=1 AUTO_RESUME_BACKOFF_CAP=1 \
  https://gl.example/g/p/-/merge_requests/9 --dir "$AR_APP_REPO" --auto-resume 1 \
  --claude-bin "$ALT_CLAUDE" --codex-bin "$ALT_CODEX"
SUP_PATH=""
AR_APP_LOG="$AR_LIVE_STATE/supervisor.log"
assert_eq "$(head -1 "$AR_LIVE_STATE/worker.status" 2>/dev/null)" approved

t "run.sh: a terminal status stops the supervisor without a relaunch"
if grep -Fq 'stopping — worker finished: approved' "$AR_APP_LOG" \
   && ! grep -Fq 'auto-resume: restart' "$AR_APP_LOG"; then ok
else bad "the supervisor did not stop on a terminal status ($(tail -2 "$AR_APP_LOG" | tr '\n' ' '))"; fi

t "run.sh: a supervised run that finished exits 0"
if [[ "$RUN_RC" -eq 0 ]]; then ok; else bad "front-end exited rc=$RUN_RC"; fi

t "run.sh: the front-end reports the finished run's status"
assert_substr "$WORK/run.err" "supervisor exited; last worker status: approved"

t "run.sh: executable flags survive the supervised launch"
assert_substr "$AR_SUP_AGENT_LOG" $'codex\t'"$ALT_CODEX"

# The stub thread already carries a completed round 1, so this invocation's
# first worker resumed at iter 2 — that resume point is its budget baseline.
t "run.sh: the first worker records the invocation's budget baseline"
assert_eq "$(awk -F= '/^BASE=/{print $2}' "$AR_LIVE_STATE/worker.progress" 2>/dev/null)" 2
rm -rf "$ROOT/state/gl.example__g__p"

t "run.sh: executable flags reach Codex, Claude's probe, and Claude through a worker"
AGENT_FLAG_LOG="$WORK/agent-flag-e2e.log"
: > "$AGENT_FLAG_LOG"
mkdir -p "$WORK/ar-bin-e2e-codex/sessions"
env -i PATH="$AR_APP_BIN:$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" \
  STUB_MR_OPEN=1 STUB_GIT_REMOTE="$AR_APP_REMOTE" \
  CODEX_HOME="$WORK/ar-bin-e2e-codex" ARGV_FILE="$WORK/ar-bin-e2e-argv" \
  AGENT_EXE_LOG="$AGENT_FLAG_LOG" STUB_CODEX_VERDICT=CHANGES_REQUESTED \
  bash "$ROOT/run.sh" --_worker https://gl.example/g/p/-/merge_requests/9 \
    --dir "$AR_APP_REPO" --max 1 \
    --claude-bin "$ALT_CLAUDE" --codex-bin "$ALT_CODEX" \
    > "$WORK/ar-bin-e2e.out" 2> "$WORK/ar-bin-e2e.err"
assert_substr "$AGENT_FLAG_LOG" $'codex\t'"$ALT_CODEX"
assert_substr "$AGENT_FLAG_LOG" $'claude-probe\t'"$ALT_CLAUDE"
assert_substr "$AGENT_FLAG_LOG" $'claude\t'"$ALT_CLAUDE"
rm -rf "$ROOT/state/gl.example__g__p"

# --- auto-resume: the iteration budget spans relaunches ----------------------
# worker.progress carries what earlier workers of the same invocation spent.
# A relaunched worker (run directly here, seeded the way a supervisor retry
# finds the file) that already spent --max reports max_iterations_reached
# without running another agent turn — the cap is per invocation, not per
# worker process.

t "run.sh: a relaunched worker resumes the invocation's spent budget"
rm -rf "$ROOT/state/gl.example__g__p"
mkdir -p "$AR_LIVE_STATE"
printf 'RUNS=2\nSTREAK=0\n' > "$AR_LIVE_STATE/worker.progress"
env -i PATH="$AR_APP_BIN:$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" \
  STUB_MR_OPEN=1 STUB_GIT_REMOTE="$AR_APP_REMOTE" \
  CODEX_HOME="$WORK/ar-approve-codex" \
  bash "$ROOT/run.sh" --_worker https://gl.example/g/p/-/merge_requests/9 \
    --dir "$AR_APP_REPO" --max 2 > "$WORK/wk.out" 2> "$WORK/wk.err"
assert_substr "$WORK/wk.err" "already ran 2 of 2 iteration(s)"
t "run.sh: a worker with no remaining budget runs no agent turn"
if grep -Fq '===== Iteration' "$WORK/wk.err"; then
  bad "the worker started an iteration past the invocation cap"
else ok; fi
t "run.sh: the over-budget relaunch reports max_iterations_reached"
assert_eq "$(head -1 "$AR_LIVE_STATE/worker.status" 2>/dev/null)" max_iterations_reached
rm -rf "$ROOT/state/gl.example__g__p"

# --- auto-resume: --restart is half-step-aware --------------------------------
# --restart bypasses a prior APPROVED verdict, but must not skip work the
# thread still owes: when codex posted an iteration claude never answered
# (the restarted round died mid-way and this is the relaunch), the claude
# half-step runs first. Only a completed round bumps to a fresh one. The
# stub knobs pin the two summary iterations independently.

t "run.sh: --restart resumes a pending claude half-step instead of skipping it"
rm -rf "$ROOT/state/gl.example__g__p"
env -i PATH="$AR_APP_BIN:$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" \
  STUB_MR_OPEN=1 STUB_GIT_REMOTE="$AR_APP_REMOTE" \
  CODEX_HOME="$WORK/ar-approve-codex" ARGV_FILE="$WORK/ar-restart-argv" \
  STUB_GL_CODEX_ITER=2 STUB_GL_CLAUDE_ITER=1 STUB_FAIL_MIDRUN=1 \
  bash "$ROOT/run.sh" --_worker https://gl.example/g/p/-/merge_requests/9 \
    --dir "$AR_APP_REPO" --restart > "$WORK/rs.out" 2> "$WORK/rs.err"
assert_substr "$WORK/rs.err" "--restart: codex iter=2 awaits a claude reply — running the half-step first"

t "run.sh: --restart with a completed round starts the next round codex-first"
rm -rf "$ROOT/state/gl.example__g__p"
env -i PATH="$AR_APP_BIN:$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" \
  STUB_MR_OPEN=1 STUB_GIT_REMOTE="$AR_APP_REMOTE" \
  CODEX_HOME="$WORK/ar-approve-codex" ARGV_FILE="$WORK/ar-restart-argv" \
  bash "$ROOT/run.sh" --_worker https://gl.example/g/p/-/merge_requests/9 \
    --dir "$AR_APP_REPO" --restart > "$WORK/rs2.out" 2> "$WORK/rs2.err"
assert_substr "$WORK/rs2.err" "--restart: bypassing prior APPROVED state — starting fresh at iter 2 (codex first)"
rm -rf "$ROOT/state/gl.example__g__p"

t "run.sh: --restart treats an approval without a claude reply as a completed round"
# The natural post-approval state has the same codex>claude count shape as
# a pending half-step — claude never answers an approval. The persisted
# verdict is what tells them apart: --restart here means a fresh round.
rm -rf "$ROOT/state/gl.example__g__p"
mkdir -p "$AR_LIVE_STATE/iter-01"
printf 'APPROVED\n' > "$AR_LIVE_STATE/iter-01/verdict"
env -i PATH="$AR_APP_BIN:$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" \
  STUB_MR_OPEN=1 STUB_GIT_REMOTE="$AR_APP_REMOTE" \
  CODEX_HOME="$WORK/ar-approve-codex" ARGV_FILE="$WORK/ar-restart-argv" \
  STUB_GL_CODEX_ITER=1 STUB_GL_CLAUDE_ITER=0 \
  bash "$ROOT/run.sh" --_worker https://gl.example/g/p/-/merge_requests/9 \
    --dir "$AR_APP_REPO" --restart > "$WORK/rs3.out" 2> "$WORK/rs3.err"
assert_substr "$WORK/rs3.err" "--restart: bypassing prior APPROVED state — starting fresh at iter 2 (codex first)"
if grep -Fq 'awaits a claude reply' "$WORK/rs3.err"; then
  bad "--restart ran claude against a prior approval"
else ok; fi
rm -rf "$ROOT/state/gl.example__g__p"

t "run.sh: --restart still resumes the half-step when the verdict is not APPROVED"
rm -rf "$ROOT/state/gl.example__g__p"
mkdir -p "$AR_LIVE_STATE/iter-02"
printf 'CHANGES_REQUESTED\n' > "$AR_LIVE_STATE/iter-02/verdict"
env -i PATH="$AR_APP_BIN:$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" \
  STUB_MR_OPEN=1 STUB_GIT_REMOTE="$AR_APP_REMOTE" \
  CODEX_HOME="$WORK/ar-approve-codex" ARGV_FILE="$WORK/ar-restart-argv" \
  STUB_GL_CODEX_ITER=2 STUB_GL_CLAUDE_ITER=1 STUB_FAIL_MIDRUN=1 \
  bash "$ROOT/run.sh" --_worker https://gl.example/g/p/-/merge_requests/9 \
    --dir "$AR_APP_REPO" --restart > "$WORK/rs4.out" 2> "$WORK/rs4.err"
assert_substr "$WORK/rs4.err" "--restart: codex iter=2 awaits a claude reply — running the half-step first"
rm -rf "$ROOT/state/gl.example__g__p"

t "run.sh: a relaunched --restart ends as approved when its own round was approved"
# The relaunch replays --restart. An APPROVED verdict at or past the
# invocation's baseline (BASE in worker.progress) was earned by the forced
# round itself: the run must end approved, not force yet another round.
rm -rf "$ROOT/state/gl.example__g__p"
mkdir -p "$AR_LIVE_STATE/iter-01"
printf 'APPROVED\n' > "$AR_LIVE_STATE/iter-01/verdict"
printf 'RUNS=0\nSTREAK=0\nBASE=1\n' > "$AR_LIVE_STATE/worker.progress"
env -i PATH="$AR_APP_BIN:$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" \
  STUB_MR_OPEN=1 STUB_GIT_REMOTE="$AR_APP_REMOTE" \
  CODEX_HOME="$WORK/ar-approve-codex" ARGV_FILE="$WORK/ar-restart-argv" \
  STUB_GL_CODEX_ITER=1 STUB_GL_CLAUDE_ITER=0 \
  bash "$ROOT/run.sh" --_worker https://gl.example/g/p/-/merge_requests/9 \
    --dir "$AR_APP_REPO" --restart > "$WORK/rs5.out" 2> "$WORK/rs5.err"
assert_substr "$WORK/rs5.err" "--restart: the forced round already ran — codex APPROVED at iter 1; nothing to do"
t "run.sh: the already-approved --restart relaunch reports approved"
assert_eq "$(head -1 "$AR_LIVE_STATE/worker.status" 2>/dev/null)" approved
rm -rf "$ROOT/state/gl.example__g__p"

# --- auto-resume: the budget reconciles with summaries already landed --------
# A claude summary can land right before its worker fails, leaving the
# persisted RUNS behind the public thread. The relaunch compares its resume
# point against the invocation's baseline iteration (BASE) and counts every
# publicly completed round as spent budget.

t "run.sh: a relaunch reconciles the budget with summaries already on the PR"
rm -rf "$ROOT/state/gl.example__g__p"
mkdir -p "$AR_LIVE_STATE"
printf 'RUNS=0\nSTREAK=0\nBASE=1\n' > "$AR_LIVE_STATE/worker.progress"
env -i PATH="$AR_APP_BIN:$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" \
  STUB_MR_OPEN=1 STUB_GIT_REMOTE="$AR_APP_REMOTE" \
  CODEX_HOME="$WORK/ar-approve-codex" \
  bash "$ROOT/run.sh" --_worker https://gl.example/g/p/-/merge_requests/9 \
    --dir "$AR_APP_REPO" --max 1 > "$WORK/wk2.out" 2> "$WORK/wk2.err"
assert_substr "$WORK/wk2.err" "reconciling the budget"
t "run.sh: the reconciled budget runs no extra agent turn"
if grep -Fq '===== Iteration' "$WORK/wk2.err"; then
  bad "the worker ran an iteration past the reconciled cap"
else ok; fi
t "run.sh: the reconciled run reports max_iterations_reached"
assert_eq "$(head -1 "$AR_LIVE_STATE/worker.status" 2>/dev/null)" max_iterations_reached
rm -rf "$ROOT/state/gl.example__g__p"

# --- auto-resume: a landed review counts toward convergence -------------------
# A qualifying codex review that posted right before its worker died is
# skipped on resume (claude runs first), but its persisted issue_counts
# still feed the streak — including the converged exit, taken before the
# claude half-step just as a live turn would.

t "run.sh: a landed codex review counts toward convergence on the resumed half-step"
rm -rf "$ROOT/state/gl.example__g__p"
mkdir -p "$AR_LIVE_STATE/iter-01"
printf 'BLOCKER=0\nMAJOR=0\nNIT=1\n' > "$AR_LIVE_STATE/iter-01/issue_counts"
env -i PATH="$AR_APP_BIN:$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" \
  STUB_MR_OPEN=1 STUB_GIT_REMOTE="$AR_APP_REMOTE" \
  CODEX_HOME="$WORK/ar-approve-codex" ARGV_FILE="$WORK/ar-conv-argv" \
  STUB_GL_CODEX_ITER=1 STUB_GL_CLAUDE_ITER=0 \
  bash "$ROOT/run.sh" --_worker https://gl.example/g/p/-/merge_requests/9 \
    --dir "$AR_APP_REPO" --max 2 --converge 1 > "$WORK/cv.out" 2> "$WORK/cv.err"
assert_substr "$WORK/cv.err" "convergence: iter 1 BLOCKER=0 MAJOR=0 (streak 1 / 1)"
t "run.sh: the reconciled streak converges before the claude half-step"
assert_eq "$(head -1 "$AR_LIVE_STATE/worker.status" 2>/dev/null)" converged_no_major
rm -rf "$ROOT/state/gl.example__g__p"

t "run.sh: a relaunch after convergence landed exits converged without a turn"
# A kill between persisting the threshold streak and writing the status
# loses only the status; the relaunch must report the convergence that
# already happened, not spend more turns on a converged review.
rm -rf "$ROOT/state/gl.example__g__p"
mkdir -p "$AR_LIVE_STATE"
printf 'RUNS=1\nSTREAK=1\nSTREAK_AT=1\nBASE=1\n' > "$AR_LIVE_STATE/worker.progress"
env -i PATH="$AR_APP_BIN:$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" \
  STUB_MR_OPEN=1 STUB_GIT_REMOTE="$AR_APP_REMOTE" \
  CODEX_HOME="$WORK/ar-approve-codex" ARGV_FILE="$WORK/ar-conv-argv" \
  bash "$ROOT/run.sh" --_worker https://gl.example/g/p/-/merge_requests/9 \
    --dir "$AR_APP_REPO" --max 2 --converge 1 > "$WORK/cv3.out" 2> "$WORK/cv3.err"
assert_substr "$WORK/cv3.err" "restored streak 1 already meets 1"
t "run.sh: the replayed convergence reports converged_no_major"
assert_eq "$(head -1 "$AR_LIVE_STATE/worker.status" 2>/dev/null)" converged_no_major
if grep -Fq '===== Iteration' "$WORK/cv3.err"; then
  bad "the relaunch ran a turn on an already-converged review"
else ok; fi
rm -rf "$ROOT/state/gl.example__g__p"

t "run.sh: a relaunch does not count the same landed review twice"
# STREAK_AT records the last accounted iteration; a second relaunch over
# the same landed review leaves the streak alone.
rm -rf "$ROOT/state/gl.example__g__p"
mkdir -p "$AR_LIVE_STATE/iter-01"
printf 'BLOCKER=0\nMAJOR=0\nNIT=1\n' > "$AR_LIVE_STATE/iter-01/issue_counts"
printf 'RUNS=0\nSTREAK=1\nSTREAK_AT=1\nBASE=1\n' > "$AR_LIVE_STATE/worker.progress"
env -i PATH="$AR_APP_BIN:$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" \
  STUB_MR_OPEN=1 STUB_GIT_REMOTE="$AR_APP_REMOTE" \
  CODEX_HOME="$WORK/ar-approve-codex" ARGV_FILE="$WORK/ar-conv-argv" \
  STUB_GL_CODEX_ITER=1 STUB_GL_CLAUDE_ITER=0 STUB_FAIL_MIDRUN=1 \
  bash "$ROOT/run.sh" --_worker https://gl.example/g/p/-/merge_requests/9 \
    --dir "$AR_APP_REPO" --max 2 --converge 2 > "$WORK/cv2.out" 2> "$WORK/cv2.err"
if grep -Fq 'streak 2 / 2' "$WORK/cv2.err"; then
  bad "the relaunch double-counted the already-accounted review"
else ok; fi
rm -rf "$ROOT/state/gl.example__g__p"

# --- codex_turn: a landed review with a failing CLI persists its record -----
# The real crash path: the summary posts, then the CLI exits nonzero. The
# turn still fails, but the counts and verdict from stdout must land on
# disk first — a relaunch's resume feeds convergence from them.

t "run.sh: a landed review with a failing CLI still persists its counts"
rm -rf "$ROOT/state/gl.example__g__p"
env -i PATH="$AR_APP_BIN:$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" \
  STUB_MR_OPEN=1 STUB_GIT_REMOTE="$AR_APP_REMOTE" \
  CODEX_HOME="$WORK/ar-approve-codex" ARGV_FILE="$WORK/ar-cx-argv" \
  STUB_CODEX_ISSUES='BLOCKER=0 MAJOR=0 NIT=1' \
  STUB_CODEX_VERDICT=CHANGES_REQUESTED STUB_CODEX_EXIT=17 \
  bash "$ROOT/run.sh" --_worker https://gl.example/g/p/-/merge_requests/9 \
    --dir "$AR_APP_REPO" --max 2 --converge 1 > "$WORK/cx.out" 2> "$WORK/cx.err"
assert_substr "$WORK/cx.err" "summary landed before the CLI failure"
t "run.sh: the failed turn's counts are on disk"
assert_eq "$(awk -F= '/^NIT=/{print $2}' "$AR_LIVE_STATE/iter-02/issue_counts" 2>/dev/null)" 1
t "run.sh: the failed turn's verdict is the conservative CHANGES_REQUESTED"
assert_eq "$(cat "$AR_LIVE_STATE/iter-02/verdict" 2>/dev/null)" CHANGES_REQUESTED
t "run.sh: the failed turn still reports codex_error"
assert_eq "$(head -1 "$AR_LIVE_STATE/worker.status" 2>/dev/null)" codex_error

t "run.sh: the relaunch converges from the failed turn's persisted counts"
env -i PATH="$AR_APP_BIN:$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" \
  STUB_MR_OPEN=1 STUB_GIT_REMOTE="$AR_APP_REMOTE" \
  CODEX_HOME="$WORK/ar-approve-codex" ARGV_FILE="$WORK/ar-cx-argv" \
  STUB_GL_CODEX_ITER=2 STUB_GL_CLAUDE_ITER=1 \
  bash "$ROOT/run.sh" --_worker https://gl.example/g/p/-/merge_requests/9 \
    --dir "$AR_APP_REPO" --max 2 --converge 1 > "$WORK/cx2.out" 2> "$WORK/cx2.err"
assert_substr "$WORK/cx2.err" "convergence: iter 2 BLOCKER=0 MAJOR=0 (streak 1 / 1)"
assert_eq "$(head -1 "$AR_LIVE_STATE/worker.status" 2>/dev/null)" converged_no_major
rm -rf "$ROOT/state/gl.example__g__p"

# --- codex_turn: a POST that landed but whose verification read failed -------
# The immediate thread read after a successful POST can fail transiently.
# The stdout record persists as provisional (*.stdout); resume adopts it
# only once the public thread confirms the summary landed. Pinning the
# thread stub to iter 0 makes the first worker's verification miss —
# exactly the outage shape — while the retry's stub shows the landed
# summary.

t "run.sh: a landed POST with a failed verification read keeps a provisional record"
rm -rf "$ROOT/state/gl.example__g__p"
env -i PATH="$AR_APP_BIN:$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" \
  STUB_MR_OPEN=1 STUB_GIT_REMOTE="$AR_APP_REMOTE" \
  CODEX_HOME="$WORK/ar-approve-codex" ARGV_FILE="$WORK/ar-cx-argv" \
  STUB_GL_CODEX_ITER=0 STUB_GL_CLAUDE_ITER=0 \
  STUB_CODEX_ISSUES='BLOCKER=0 MAJOR=0 NIT=1' \
  STUB_CODEX_VERDICT=CHANGES_REQUESTED STUB_CODEX_EXIT=17 \
  bash "$ROOT/run.sh" --_worker https://gl.example/g/p/-/merge_requests/9 \
    --dir "$AR_APP_REPO" --max 2 --converge 1 > "$WORK/cx3.out" 2> "$WORK/cx3.err"
if [[ ! -f "$AR_LIVE_STATE/iter-01/issue_counts" \
      && -f "$AR_LIVE_STATE/iter-01/issue_counts.stdout" ]]; then ok
else bad "provisional/canonical count files in the wrong state after the outage"; fi
t "run.sh: the provisional verdict is recorded without being canonical"
if [[ ! -f "$AR_LIVE_STATE/iter-01/verdict" ]] \
   && [[ "$(cat "$AR_LIVE_STATE/iter-01/verdict.stdout" 2>/dev/null)" == CHANGES_REQUESTED ]]; then ok
else bad "provisional/canonical verdict files in the wrong state after the outage"; fi

t "run.sh: a provisional record is never adopted while the thread shows nothing landed"
# The rejecting direction of the adoption invariant: provisional files are
# on disk (from the outage phase above), but the public thread still shows
# no landed summary — resume must not adopt, and codex re-reviews instead.
env -i PATH="$AR_APP_BIN:$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" \
  STUB_MR_OPEN=1 STUB_GIT_REMOTE="$AR_APP_REMOTE" \
  CODEX_HOME="$WORK/ar-approve-codex" ARGV_FILE="$WORK/ar-cx-argv" \
  STUB_GL_CODEX_ITER=0 STUB_GL_CLAUDE_ITER=0 \
  STUB_CODEX_ISSUES='BLOCKER=0 MAJOR=0 NIT=1' \
  STUB_CODEX_VERDICT=CHANGES_REQUESTED STUB_CODEX_EXIT=17 \
  bash "$ROOT/run.sh" --_worker https://gl.example/g/p/-/merge_requests/9 \
    --dir "$AR_APP_REPO" --max 2 --converge 1 > "$WORK/cx3b.out" 2> "$WORK/cx3b.err"
if grep -Fq 'resume: adopted' "$WORK/cx3b.err"; then
  bad "resume adopted a provisional record with no landed summary"
else ok; fi
t "run.sh: the unlanded iteration keeps no canonical record"
if [[ ! -e "$AR_LIVE_STATE/iter-01/verdict" && ! -e "$AR_LIVE_STATE/iter-01/issue_counts" ]]; then ok
else bad "canonical files appeared for an iteration the thread never showed"; fi

t "run.sh: resume adopts the provisional record once the thread shows the summary"
env -i PATH="$AR_APP_BIN:$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" \
  STUB_MR_OPEN=1 STUB_GIT_REMOTE="$AR_APP_REMOTE" \
  CODEX_HOME="$WORK/ar-approve-codex" ARGV_FILE="$WORK/ar-cx-argv" \
  STUB_GL_CODEX_ITER=1 STUB_GL_CLAUDE_ITER=0 \
  bash "$ROOT/run.sh" --_worker https://gl.example/g/p/-/merge_requests/9 \
    --dir "$AR_APP_REPO" --max 2 --converge 1 > "$WORK/cx4.out" 2> "$WORK/cx4.err"
assert_substr "$WORK/cx4.err" "resume: adopted stdout issue counts for landed codex iter 1"
assert_substr "$WORK/cx4.err" "convergence: iter 1 BLOCKER=0 MAJOR=0 (streak 1 / 1)"
t "run.sh: the adopted record converges the resumed half-step"
assert_eq "$(head -1 "$AR_LIVE_STATE/worker.status" 2>/dev/null)" converged_no_major
rm -rf "$ROOT/state/gl.example__g__p"

t "codex_turn: a fresh attempt clears the previous attempt's stdout record"
# A stale provisional from a failed prior attempt must never be adoptable
# as a later attempt's landed review: the turn clears the *.stdout files
# before the CLI runs, so even an attempt killed mid-run leaves nothing
# stale behind — here the CLI prints no markers at all, and the stale
# APPROVED must be gone afterwards.
rm -rf "$ROOT/state/gl.example__g__p"
mkdir -p "$AR_LIVE_STATE/iter-01"
printf 'APPROVED\n' > "$AR_LIVE_STATE/iter-01/verdict.stdout"
printf 'BLOCKER=0\nMAJOR=0\nNIT=0\n' > "$AR_LIVE_STATE/iter-01/issue_counts.stdout"
env -i PATH="$AR_APP_BIN:$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" \
  STUB_MR_OPEN=1 STUB_GIT_REMOTE="$AR_APP_REMOTE" \
  CODEX_HOME="$WORK/ar-approve-codex" ARGV_FILE="$WORK/ar-cx-argv" \
  STUB_GL_CODEX_ITER=0 STUB_GL_CLAUDE_ITER=0 \
  STUB_CODEX_SILENT=1 STUB_CODEX_EXIT=17 \
  bash "$ROOT/run.sh" --_worker https://gl.example/g/p/-/merge_requests/9 \
    --dir "$AR_APP_REPO" --max 2 > "$WORK/cx5.out" 2> "$WORK/cx5.err"
if [[ "$(cat "$AR_LIVE_STATE/iter-01/verdict.stdout" 2>/dev/null)" == CHANGES_REQUESTED \
      && ! -e "$AR_LIVE_STATE/iter-01/issue_counts.stdout" ]]; then ok
else bad "a stale stdout record survived a fresh attempt"; fi
rm -rf "$ROOT/state/gl.example__g__p"

t "run.sh: an adopted APPROVED verdict ends the resumed review as approved"
# The verdict half of adoption, at its highest stakes: codex approved and
# posted, the CLI then died before the verification read — the relaunch
# must honor the public approval instead of running claude against it.
rm -rf "$ROOT/state/gl.example__g__p"
env -i PATH="$AR_APP_BIN:$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" \
  STUB_MR_OPEN=1 STUB_GIT_REMOTE="$AR_APP_REMOTE" \
  CODEX_HOME="$WORK/ar-approve-codex" ARGV_FILE="$WORK/ar-cx-argv" \
  STUB_GL_CODEX_ITER=0 STUB_GL_CLAUDE_ITER=0 \
  STUB_CODEX_EXIT=17 \
  bash "$ROOT/run.sh" --_worker https://gl.example/g/p/-/merge_requests/9 \
    --dir "$AR_APP_REPO" --max 2 > "$WORK/cx6.out" 2> "$WORK/cx6.err"
env -i PATH="$AR_APP_BIN:$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" \
  STUB_MR_OPEN=1 STUB_GIT_REMOTE="$AR_APP_REMOTE" \
  CODEX_HOME="$WORK/ar-approve-codex" ARGV_FILE="$WORK/ar-cx-argv" \
  STUB_GL_CODEX_ITER=1 STUB_GL_CLAUDE_ITER=0 \
  bash "$ROOT/run.sh" --_worker https://gl.example/g/p/-/merge_requests/9 \
    --dir "$AR_APP_REPO" --max 2 > "$WORK/cx7.out" 2> "$WORK/cx7.err"
assert_substr "$WORK/cx7.err" "resume: adopted stdout verdict for landed codex iter 1"
assert_substr "$WORK/cx7.err" "codex already APPROVED at iter 1 — nothing to do"
t "run.sh: the adopted approval reports approved"
assert_eq "$(head -1 "$AR_LIVE_STATE/worker.status" 2>/dev/null)" approved
rm -rf "$ROOT/state/gl.example__g__p"

