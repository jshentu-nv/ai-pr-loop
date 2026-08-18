#!/usr/bin/env bash
# Regression tests for the loop's CLI argv construction. No network and no
# real claude/codex/gh: the turn scripts run against PATH stubs that record
# their argv to a file, and assertions check the recorded vectors.
#
# Covers:
#   - resolve_codex_effort: adaptive default, explicit precedence, off
#   - claude_turn.sh argv: --model, ultracode --settings payload, --effort
#     levels, off omission, --claude-perms modes (auto / bypass safety net /
#     off), executable override + cache isolation, --session-id vs --resume
#   - codex_turn.sh argv: -m / model_reasoning_effort / service_tier mapping,
#     off omission, adaptive effort for non-sol models, fresh vs `exec resume`,
#     executable override, root-session discovery (sub-agent skip + cwd
#     binding), stored-id migration / discard of unresumable ids
#   - run.sh flag validation die-paths (empty / unknown / next-flag-as-value)
#     and resolved knob output via --print-config (adaptive default / explicit
#     precedence), including safe executable resolution and flag-over-env
#     precedence
#   - forge resolution: PR/MR URL parsing (github / gitlab.com / self-hosted /
#     legacy no-/-/ form), --host implying gitlab, URL-vs-flag conflicts,
#     scheme preservation (http MR URLs / scheme-qualified --host),
#     authority validation (userinfo/path rejection, port + IPv6 acceptance)
#   - summary-as-completion: resume high-water counts only STRUCTURAL
#     summary roots (marker first line, alert + banner first visible);
#     inline notes, replies, banner-quoting prose, and misplaced markers
#     are excluded; both turn scripts fail when their iteration summary
#     never landed
#   - round reports: each completed turn saves iter-NN/<who>-report.md and
#     logs the body between BEGIN/END markers behind a single tagged
#     announcement line, honours AI_REPORT_LOG_MAX_LINES while keeping the
#     whole body on disk, reads the written review in local mode without
#     consuming it, and writes nothing when the summary never landed; a
#     response that landed before a CLI failure or lost stdout marker still
#     reports; a malformed or zero-padded AI_REPORT_LOG_MAX_LINES warns
#     and falls back instead of failing a landed turn; a clamped GitLab
#     page size never truncates the thread read
#   - thread atomicity: a page or endpoint failing mid-fetch yields no
#     partial thread — the turn fails closed instead of answering a
#     truncated one
#   - CI policy: the forge prompts direct both agents to read the head's
#     checks themselves; local-mode prompts direct local validation, since
#     forge checks describe the remote head, not the unpushed rounds
#   - auto-resume: the restart decision table, the backoff curve, and the
#     context-flag stripper as helpers, plus real front-end/supervisor/
#     worker runs — default budget, inline --no-auto-resume,
#     --print-config/--preflight-only never supervising, argv forwarded
#     verbatim (newline + quote, flag-shaped values), the stop sentinel,
#     budget exhaustion, the long-run backoff reset, a relaunch reusing the
#     stored context.md after its --context-file path vanished, the
#     iteration budget spanning relaunches (and reconciling with summaries
#     already landed on the PR), a landed qualifying review counting toward
#     convergence on the resumed half-step (once — STREAK_AT), --restart
#     resuming a pending claude half-step (bumping a completed round,
#     including an approval whose codex>claude shape mimics a half-step), a
#     failed context render leaving no truncated snapshot and a failed
#     replacement retried instead of falling back to stale stored context,
#     state-path identity collisions refused by --stop and by starts
#     (first-touch elected atomically — 40 racing pairs), and inline
#     fallback (with a warning) when setsid/perl (session) or flock/perl
#     (lock) are missing
#   - auto-resume, orphan recovery: --stop TERMs the recorded worker group
#     after a supervisor SIGKILL leaves the tree alive
#   - auto-resume, live runs: a reaped front-end leaves the supervisor and
#     its worker running, a tree reaper TERMing the front-end's whole
#     descendant walk leaves the review running (the supervisor is
#     reparented at spawn), a sentinel-less TERM to the supervisor is
#     ignored while --stop still works afterwards, --stop reaches the
#     agent under the worker, a stale supervisor.pid is neither signalled
#     nor obeyed (including a recycled pid whose argv matches but whose
#     start time does not), simultaneous starts elect exactly one
#     supervisor, a second run on the same PR refuses to start, a real
#     SIGINT to the front-end group stops everything with exit 130, a
#     worker that finishes reports a terminal status, and a SIGKILLed
#     front-end leaves no tail behind
#   - codex_turn: a landed summary followed by a nonzero CLI exit persists
#     its counts and verdict before the turn fails, and the relaunch
#     converges from them; a verification read that fails right after the
#     POST leaves a provisional stdout record that resume adopts once the
#     public thread confirms the summary
#   - portability branches, live: a perl-only PATH (no setsid) reparents
#     the supervisor and survives the tree reap; a setsid without -f and
#     no perl falls back inline with a warning naming the -f gap
#   - local review mode: flag validation and --print-config reporting, the
#     state key for a PR-less branch review, resume high-water from the
#     per-round files, both turn scripts' file contracts (written artifact
#     completes the turn; a stale one does not; a failed turn's rollback
#     discards its response so resume reruns the round), the forge staying
#     read-only on a PR/MR target, and — against real git — checkout
#     positioning across invocations, squash-into-one-commit, the
#     fast-forward-only push, and the single post-push PR/MR text write
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
# AI_PR_LOOP_TEST_KEEP_WORK=1 leaves the scratch tree behind. A failure here
# is usually only diagnosable from the run's own output files, and this is the
# only way to read them after the suite exits.
if [[ "${AI_PR_LOOP_TEST_KEEP_WORK:-0}" == "1" ]]; then
  trap 'printf "\nwork tree kept: %s\n" "$WORK"' EXIT
else
  trap 'rm -rf "$WORK"' EXIT
fi
BASH_BIN="$(command -v bash)"

# Process probes for the live fixtures. Git Bash's ps rejects every -o
# option, so these read /proc when it answers instead — the same fallback the
# loop itself uses, spelled separately so the fixtures do not depend on the
# code under test.
tp_field() {  # <pid> <ps-o-key> <proc-file>
  local v=''
  v=$(ps -o "$2=" -p "$1" 2>/dev/null | tr -d ' ') || v=''
  if [[ -z "$v" && -r "/proc/$1/$3" ]]; then
    read -r v < "/proc/$1/$3" || v=''
    v="${v//[[:space:]]/}"
  fi
  printf '%s\n' "$v"
}
tp_pgid() { tp_field "$1" pgid pgid; }
tp_ppid() { tp_field "$1" ppid ppid; }
tp_argv() {  # <pid>
  local v=''
  v=$(ps -o args= -p "$1" 2>/dev/null) || v=''
  if [[ -z "${v//[[:space:]]/}" && -r "/proc/$1/cmdline" ]]; then
    v=$(tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null) || v=''
  fi
  printf '%s\n' "$v"
}
tp_all_pids() {
  if [[ -d /proc ]]; then
    local d
    for d in /proc/[0-9]*; do printf '%s\n' "${d##*/}"; done
    return 0
  fi
  ps -e -o pid= 2>/dev/null | tr -d ' '
}
tp_child_matching() {  # <ppid> <substring>
  local pid
  while IFS= read -r pid; do
    [[ "$(tp_ppid "$pid")" == "$1" ]] || continue
    [[ "$(tp_argv "$pid")" == *"$2"* ]] || continue
    printf '%s\n' "$pid"
    return 0
  done < <(tp_all_pids)
  return 1
}

# Curated-PATH fixtures below build a directory holding only the tools a case
# is allowed to see. `ln -s` cannot do that here: MSYS has no symlinks by
# default, so it COPIES the binary, and a copied `bash.exe` on a PATH without
# its DLL directory dies with "error while loading shared libraries". Write a
# shim instead — a text file with an absolute interpreter path, which runs
# whatever the PATH holds.
tool_shim() {  # <dir> <name> <target-path>
  printf '#!%s\nexec %s "$@"\n' "$BASH_BIN" "$(printf '%q' "$3")" > "$1/$2"
  chmod +x "$1/$2"
}
# Add <cmd> from the host to <dir>. Returns 1 when the host lacks it.
add_tool() {  # <dir> <cmd>
  local p
  p=$(command -v "$2" 2>/dev/null) || return 1
  tool_shim "$1" "$2" "$p"
}
# Copy a whole curated directory, preserving what each shim points at.
clone_tool_dir() {  # <src-dir> <dst-dir>
  local f
  mkdir -p "$2"
  for f in "$1"/*; do [[ -e "$f" ]] && cp -f "$f" "$2/${f##*/}"; done
  chmod +x "$2"/* 2>/dev/null || true
}

PASS=0
FAIL=0
CURRENT=""
SKIPPED=0
# A skipped case must be visible and counted: a silent block of unrun tests
# reads exactly like a passing suite.
skip() {  # <reason>
  SKIPPED=$((SKIPPED + 1))
  printf 'SKIP: %s — %s\n' "$CURRENT" "$1" >&2
}

t()   { CURRENT="$1"; }
ok()  { PASS=$((PASS + 1)); }
bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s — %s\n' "$CURRENT" "$1" >&2
  [[ "${AI_PR_LOOP_TEST_FAIL_FAST:-0}" != "1" ]] || exit 1
}

# Argv files hold one argument per line.
assert_line()      { if grep -Fxq -- "$2" "$1"; then ok; else bad "argv missing exact arg: $2"; fi; }
assert_no_line()   { if grep -Fxq -- "$2" "$1"; then bad "argv unexpectedly contains: $2"; else ok; fi; }
assert_no_substr() { if grep -Fq  -- "$2" "$1"; then bad "argv unexpectedly has substring: $2"; else ok; fi; }
assert_substr()    { if grep -Fq  -- "$2" "$1"; then ok; else bad "file missing substring: $2"; fi; }
assert_count() {  # file fixed-string expected-count
  local got
  got=$(grep -Fc -- "$2" "$1" 2>/dev/null || true)
  if [[ "$got" -eq "$3" ]]; then ok
  else bad "substring count for '$2' was $got, want $3"; fi
}
assert_pair() {  # file flag value — value must be the arg right after flag
  if awk -v f="$2" -v v="$3" 'prev==f && $0==v {found=1} {prev=$0} END {exit !found}' "$1"; then
    ok
  else
    bad "argv missing pair: $2 $3"
  fi
}
assert_eq() { if [[ "$1" == "$2" ]]; then ok; else bad "got '$1', want '$2'"; fi; }
# Scoped to a single flag's value.
flag_value() { awk -v f="$2" 'prev==f {print; exit} {prev=$0}' "$1"; }
assert_value_has()   { local v; v=$(flag_value "$1" "$2"); if [[ "$v" == *"$3"* ]]; then ok; else bad "$2 value missing '$3' (got: $v)"; fi; }
assert_value_lacks() { local v; v=$(flag_value "$1" "$2"); if [[ "$v" == *"$3"* ]]; then bad "$2 value unexpectedly has '$3'"; else ok; fi; }
assert_rc0() { if [[ "$TURN_RC" -eq 0 ]]; then ok; else bad "turn exited rc=$TURN_RC (log: $(tail -3 "$CASE_DIR/turn.log" 2>/dev/null | tr '\n' ' '))"; fi; }

