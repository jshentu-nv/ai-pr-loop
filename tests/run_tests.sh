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
: > "$ARGV_FILE"
for a in "$@"; do printf '%s\n' "$a" >> "$ARGV_FILE"; done
# Simulate a host/account where auto permission mode is unavailable: the
# real CLI rejects the flag at startup before doing any work.
if [[ "${STUB_REJECT_AUTO:-0}" == "1" ]]; then
  for a in "$@"; do
    if [[ "$a" == "--permission-mode" ]]; then
      echo "Error: --permission-mode auto is not available on this account" >&2
      exit 1
    fi
  done
fi
# Simulate a turn that did real work, then died with stderr that happens to
# mention the permission mode — the fallback must NOT rerun such a turn.
if [[ "${STUB_FAIL_MIDRUN:-0}" == "1" ]]; then
  echo "partial turn output, no completion marker"
  echo "Error: crashed mid-run; see --permission-mode docs" >&2
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

# fetch_ai_thread hits gh twice (issue + inline comments). Emit one codex
# summary comment for the issues endpoint so claude_turn.sh has a review to
# read; everything else returns empty.
cat > "$STUBS/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"/issues/"*"/comments"*)
    printf '{"surface":"issue","id":101,"path":null,"line":null,"in_reply_to_id":null,"created_at":"2026-01-01T00:00:00Z","body":"<!-- ai-loop:codex-reviewer iter=%s -->\\nStub codex review."}\n' "${ITER:-1}"
    ;;
esac
EOF
chmod +x "$STUBS/claude" "$STUBS/codex" "$STUBS/gh"

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

# run_run_sh [args ...] — run.sh with no GH_TOKEN, so anything that survives
# flag validation dies in preflight ("GH_TOKEN/GITHUB_TOKEN not set") before
# touching git or the network.
run_run_sh() {
  env -i PATH="$STUBS:/usr/bin:/bin" HOME="$WORK" \
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

t "claude: rejected auto mode falls back to the settings safety net"
new_case claude-auto-fallback
run_turn claude STUB_REJECT_AUTO=1
assert_rc0
assert_no_line "$ARGV" --permission-mode
assert_no_line "$ARGV" --dangerously-skip-permissions
assert_value_has "$ARGV" --settings '"ultracode": true'
assert_value_has "$ARGV" --settings '"defaultMode": "acceptEdits"'

t "claude: rejected auto attempt's stderr is preserved for audit"
if [[ -f "$CASE_DIR/state/iter-01/claude.stderr.auto-rejected" ]]; then
  ok
else
  bad "missing claude.stderr.auto-rejected from the rejected first attempt"
fi

t "claude: a mid-run failure never triggers the auto fallback rerun"
new_case claude-midrun-fail
run_turn claude STUB_FAIL_MIDRUN=1
assert_eq "$TURN_RC" 1
assert_pair "$ARGV" --permission-mode auto
if [[ -f "$CASE_DIR/state/iter-01/claude.stderr.auto-rejected" ]]; then
  bad "fallback fired on a turn that had already produced output"
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
