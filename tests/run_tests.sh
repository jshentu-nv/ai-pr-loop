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
#     session-id capture from the rollout file
#   - run.sh flag validation die-paths (empty / unknown values) and resolved
#     knob output via --print-config (adaptive default / explicit precedence)
#
# Usage: tests/run_tests.sh
set -uo pipefail

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
echo "[CLAUDE_TURN: COMPLETE]"
EOF

cat > "$STUBS/codex" <<'EOF'
#!/usr/bin/env bash
: > "$ARGV_FILE"
for a in "$@"; do printf '%s\n' "$a" >> "$ARGV_FILE"; done
# Real `codex exec` writes a session rollout file; emulate it so the
# session-capture path (snapshot / discover / persist) is exercised.
mkdir -p "$CODEX_HOME/sessions"
printf '{"payload":{"id":"stub-session-uuid"}}\n' > "$CODEX_HOME/sessions/rollout-stub.jsonl"
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

t "codex: seeded session resumes with 'exec resume <id>'"
new_case codex-resume
echo "cafebabe-dead-beef-sess" > "$CASE_DIR/state/codex.session.id"
run_turn codex
assert_rc0
assert_pair "$ARGV" exec resume
assert_pair "$ARGV" resume cafebabe-dead-beef-sess

t "codex: resume keeps the seeded session id"
assert_eq "$(cat "$CASE_DIR/state/codex.session.id" 2>/dev/null)" cafebabe-dead-beef-sess

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
