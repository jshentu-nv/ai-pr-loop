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
assert_no_substr "$ARGV" '# Claude Implementer turn'
assert_substr "$ARGV.stdin" '# Claude Implementer turn'

t "claude: github prompt signs every reply producer with resolved runtime metadata"
assert_count "$CASE_DIR/state/iter-01/claude.prompt.md" "$CLAUDE_DEFAULT_SIGNATURE" 2
t "claude: rendered prompt leaves no runtime-signature placeholder"
if grep -qE '\{\{[^}]*SIGNATURE[^}]*\}\}' "$CASE_DIR/state/iter-01/claude.prompt.md" 2>/dev/null; then
  bad "runtime-signature placeholder survived rendering"
else
  ok
fi

t "claude: fresh session pins --session-id"
assert_line "$ARGV" "--session-id=$(cat "$CASE_DIR/state/claude.session.uuid")"
assert_no_line "$ARGV" --resume

t "claude: executable override reaches both the auto-mode probe and turn"
new_case claude-custom-bin
run_turn claude CLAUDE_BIN="$ALT_CLAUDE"
assert_rc0
assert_eq "$(cat "$ARGV.probe-exe" 2>/dev/null)" "$ALT_CLAUDE"
assert_eq "$(cat "$ARGV.exe" 2>/dev/null)" "$ALT_CLAUDE"

t "claude: metadata handshake is control-only and uses the exact fresh session"
assert_line "$ARGV.probe-argv" --no-session-persistence
assert_pair "$ARGV.probe-argv" --input-format stream-json
assert_pair "$ARGV.probe-argv" --output-format stream-json
assert_line "$ARGV.probe-argv" "--session-id=$(cat "$CASE_DIR/state/claude.session.uuid")"
assert_pair "$ARGV.probe-argv" --model fable
assert_value_has "$ARGV.probe-argv" --settings '"ultracode": true'
assert_line "$ARGV.probe-requests" get_settings
assert_line "$ARGV.probe-requests" get_context_usage

t "claude: control response, not the selector, signs the runtime model/window"
new_case claude-runtime-actual
run_turn claude STUB_CLAUDE_ACTUAL_MODEL=claude-opus-4-8 \
  STUB_CLAUDE_ACTUAL_EFFORT=medium STUB_CLAUDE_ACTUAL_ULTRACODE=false \
  STUB_CLAUDE_CONTEXT_WINDOW=750000
assert_rc0
assert_count "$CASE_DIR/state/iter-01/claude.prompt.md" \
  '<sub>Model: <code>claude-opus-4-8</code> · Effort: <code>medium</code> · Context window: <code>750000 tokens (effective)</code></sub>' 2

t "claude: disagreeing applied/context models fail closed"
new_case claude-runtime-model-mismatch
run_turn claude STUB_CLAUDE_SETTINGS_MODEL=claude-opus-4-8 \
  STUB_CLAUDE_ACTUAL_MODEL=claude-sonnet-5
assert_eq "$TURN_RC" 1
assert_substr "$CASE_DIR/turn.log" 'control responses disagreed on the applied model'
if [[ -e "$ARGV.calls" ]]; then
  bad "a model-mismatched metadata probe reached the real turn"
else
  ok
fi

t "claude: bare effort level uses --effort and drops the settings payload"
new_case claude-xhigh
run_turn claude CLAUDE_EFFORT=xhigh
assert_rc0
assert_pair "$ARGV" --effort xhigh
assert_no_line "$ARGV" --settings

t "claude: model/effort off omits overrides and signs applied CLI settings"
new_case claude-off
run_turn claude CLAUDE_MODEL=off CLAUDE_EFFORT=off
assert_rc0
assert_no_line "$ARGV" --model
assert_no_line "$ARGV" --effort
assert_no_line "$ARGV" --settings
assert_pair "$ARGV" --permission-mode auto
assert_count "$CASE_DIR/state/iter-01/claude.prompt.md" \
  '<sub>Model: <code>claude-sonnet-5[1m]</code> · Effort: <code>medium</code> · Context window: <code>967000 tokens (effective)</code></sub>' 2

t "claude: resumed delegated effort uses applied settings, not stale transcript metadata"
new_case claude-off-resume
claude_resume_id=11111111-2222-3333-4444-555555555555
mkdir -p "$CASE_DIR/.claude/projects/project"
printf '{"type":"assistant","sessionId":"%s","cwd":"%s","effort":"low"}\n' \
  "$claude_resume_id" "$(cd "$CASE_DIR/repo" && pwd -P)" \
  > "$CASE_DIR/.claude/projects/project/$claude_resume_id.jsonl"
printf '%s\n' "$claude_resume_id" > "$CASE_DIR/state/claude.session.uuid"
run_turn claude CLAUDE_MODEL=off CLAUDE_EFFORT=off \
  STUB_CLAUDE_ACTUAL_EFFORT=high
assert_rc0
assert_line "$ARGV" "--resume=$claude_resume_id"
assert_no_line "$ARGV" --model
assert_no_line "$ARGV" --effort
assert_count "$CASE_DIR/state/iter-01/claude.prompt.md" \
  '<sub>Model: <code>claude-sonnet-5[1m]</code> · Effort: <code>high</code> · Context window: <code>967000 tokens (effective)</code></sub>' 2

t "claude: an explicit effort overrides a resumed session transcript"
run_turn claude CLAUDE_MODEL=off CLAUDE_EFFORT=xhigh \
  STUB_CLAUDE_ACTUAL_EFFORT=medium
assert_rc0
assert_pair "$ARGV" --effort xhigh
assert_count "$CASE_DIR/state/iter-01/claude.prompt.md" \
  '<sub>Model: <code>claude-sonnet-5[1m]</code> · Effort: <code>medium</code> · Context window: <code>967000 tokens (effective)</code></sub>' 2

t "claude: explicit context window is reflected in every github reply recipe"
new_case claude-context-explicit
run_turn claude CLAUDE_CONTEXT_WINDOW=200000 STUB_CLAUDE_NO_CONTEXT_RESPONSE=1
assert_rc0
assert_no_line "$ARGV.probe-requests" get_context_usage
assert_count "$CASE_DIR/state/iter-01/claude.prompt.md" \
  '<sub>Model: <code>claude-fable-5</code> · Effort: <code>xhigh (ultracode)</code> · Context window: <code>200000 tokens (configured)</code></sub>' 2

t "claude: custom model uses control-reported model and context"
new_case claude-context-custom
run_turn claude CLAUDE_MODEL=custom-model CLAUDE_EFFORT=high
assert_rc0
assert_count "$CASE_DIR/state/iter-01/claude.prompt.md" \
  '<sub>Model: <code>custom-model</code> · Effort: <code>high</code> · Context window: <code>1000000 tokens (effective)</code></sub>' 2

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

t "claude: effective permissions are re-read instead of using stale cache"
run_turn claude STUB_EFFECTIVE_PERMS=auto
assert_rc0
assert_pair "$ARGV" --permission-mode auto
assert_line "$ARGV.probe-argv" "--resume=$(cat "$CASE_DIR/state/claude.session.uuid")"

t "claude: eligible auto mode keeps classifier gating after the probe"
new_case claude-auto-eligible
run_turn claude STUB_EFFECTIVE_PERMS=auto
assert_rc0
assert_pair "$ARGV" --permission-mode auto

t "claude: changing the model re-probes instead of reusing cached eligibility"
new_case claude-cache-model
run_turn claude CLAUDE_MODEL=model-a STUB_EFFECTIVE_PERMS=auto
assert_rc0
assert_pair "$ARGV" --permission-mode auto
run_turn claude CLAUDE_MODEL=model-b STUB_EFFECTIVE_PERMS=default
assert_rc0
assert_no_line "$ARGV" --permission-mode
assert_value_has "$ARGV" --settings '"defaultMode": "acceptEdits"'

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

t "claude: changing the executable re-probes cached auto-mode eligibility"
new_case claude-cache-bin
run_turn claude STUB_EFFECTIVE_PERMS=auto
assert_rc0
assert_pair "$ARGV" --permission-mode auto
run_turn claude CLAUDE_BIN="$ALT_CLAUDE" STUB_EFFECTIVE_PERMS=default
assert_rc0
assert_no_line "$ARGV" --permission-mode
assert_value_has "$ARGV" --settings '"defaultMode": "acceptEdits"'
assert_eq "$(cat "$ARGV.probe-exe" 2>/dev/null)" "$ALT_CLAUDE"

t "claude: a stale legacy auto-mode cache is ignored"
new_case claude-cache-legacy
printf 'default fable\n' > "$CASE_DIR/state/claude.automode.effective"
run_turn claude STUB_EFFECTIVE_PERMS=auto
assert_rc0
assert_pair "$ARGV" --permission-mode auto
assert_eq "$(cat "$ARGV.probe-exe" 2>/dev/null)" "$STUBS/claude"
assert_eq "$(cat "$CASE_DIR/state/claude.automode.effective" 2>/dev/null)" \
  'default fable'

t "claude: rejected auto mode falls back to the settings safety net"
new_case claude-auto-fallback
run_turn claude STUB_REJECT_AUTO=1
assert_rc0
assert_no_line "$ARGV" --permission-mode
assert_no_line "$ARGV" --dangerously-skip-permissions
assert_value_has "$ARGV" --settings '"ultracode": true'
assert_value_has "$ARGV" --settings '"defaultMode": "acceptEdits"'
assert_eq "$(wc -c < "$ARGV.calls" | tr -d ' ')" 1

t "claude: rejected auto control probe writes no cache"
if [[ -f "$CASE_DIR/state/claude.automode.effective" ]]; then
  bad "cache written from an inconclusive (rejected) probe"
else
  ok
fi

t "claude: metadata retry removes auto before the only real turn"
assert_no_line "$ARGV" --permission-mode

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
assert_line "$ARGV" --resume=11111111-2222-3333-4444-555555555555
assert_no_line "$ARGV" --session-id

t "claude: poisoned session state is rejected before it can become a CLI flag"
new_case claude-session-poisoned
printf '%s\n' '--version' > "$CASE_DIR/state/claude.session.uuid"
run_turn claude
assert_eq "$TURN_RC" 1
assert_substr "$CASE_DIR/turn.log" 'invalid Claude session UUID'
if [[ -e "$ARGV" || -e "$ARGV.probe-argv" ]]; then
  bad "poisoned session reached a Claude process"
else
  ok
fi

t "claude: failed runtime discovery posts nothing and does not persist a phantom session"
new_case claude-runtime-missing
run_turn claude STUB_CLAUDE_NO_CONTEXT_RESPONSE=1
assert_eq "$TURN_RC" 1
assert_substr "$CASE_DIR/turn.log" 'did not report an effective context window'
assert_pair "$ARGV.probe-argv" --permission-mode auto
if [[ -e "$CASE_DIR/state/claude.session.uuid" || -e "$ARGV.calls" ]]; then
  bad "failed metadata discovery persisted/launched a real session"
else
  ok
fi

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
assert_eq "$(cat "$ARGV.probe-experimental" 2>/dev/null)" true

t "codex: github prompt signs every finding, reply, and summary producer"
assert_count "$CASE_DIR/state/iter-01/codex.prompt.md" "$CODEX_DEFAULT_SIGNATURE" 5
t "codex: rendered prompt leaves no runtime-signature placeholder"
if grep -qE '\{\{[^}]*SIGNATURE[^}]*\}\}' "$CASE_DIR/state/iter-01/codex.prompt.md" 2>/dev/null; then
  bad "runtime-signature placeholder survived rendering"
else
  ok
fi

t "codex: fresh run captures the session id from the rollout file"
assert_eq "$(cat "$CASE_DIR/state/codex.session.id" 2>/dev/null)" stub-session-uuid

t "codex: working metadata subcommands start no session"
if [[ -e "$ARGV.session-probe-argv" ]]; then
  bad "the control-only probe still started a session"
else
  ok
fi

t "codex: executable override is used for a fresh turn"
new_case codex-custom-bin
run_turn codex CODEX_BIN="$ALT_CODEX"
assert_rc0
assert_eq "$(cat "$ARGV.exe" 2>/dev/null)" "$ALT_CODEX"
assert_eq "$(cat "$ARGV.probe-exe" 2>/dev/null)" "$ALT_CODEX"
assert_eq "$(cat "$ARGV.catalog-exe" 2>/dev/null)" "$ALT_CODEX"
assert_line "$ARGV" exec

t "codex: non-sol model with unset effort forces no reasoning level"
new_case codex-alt-model
run_turn codex CODEX_MODEL=gpt-oss-120b
assert_rc0
assert_pair "$ARGV" -m gpt-oss-120b
assert_no_substr "$ARGV" model_reasoning_effort
assert_pair "$ARGV" -c 'service_tier="fast"'

t "codex: non-default model resolves effort and context from effective config/catalog"
assert_count "$CASE_DIR/state/iter-01/codex.prompt.md" \
  '<sub>Model: <code>gpt-oss-120b</code> · Effort: <code>xhigh</code> · Context window: <code>131072 tokens (effective)</code></sub>' 5

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

t "codex: off knobs are replaced by effective host config values"
assert_count "$CASE_DIR/state/iter-01/codex.prompt.md" \
  '<sub>Model: <code>gpt-5.6-sol</code> · Effort: <code>xhigh</code> · Context window: <code>258400 tokens (effective)</code></sub>' 5

t "codex: delegated config uses namespaced active catalog and clamps context"
new_case codex-off-custom-config
run_turn codex CODEX_MODEL=off CODEX_EFFORT=off CODEX_TIER=off \
  STUB_CODEX_CONFIG_MODEL=provider/custom-v2 STUB_CODEX_CONFIG_EFFORT=high \
  STUB_CODEX_CONFIG_CONTEXT=300000 \
  'STUB_CODEX_CATALOG={"models":[{"slug":"custom-v2","context_window":250000,"max_context_window":200000,"effective_context_window_percent":90}]}'
assert_rc0
assert_count "$CASE_DIR/state/iter-01/codex.prompt.md" \
  '<sub>Model: <code>provider/custom-v2</code> · Effort: <code>high</code> · Context window: <code>180000 tokens (effective)</code></sub>' 5

t "codex: null layered config falls back to model-list's actual default"
new_case codex-off-model-list-default
run_turn codex CODEX_MODEL=off CODEX_EFFORT=off CODEX_TIER=off \
  STUB_CODEX_CONFIG_MODEL=__NULL__ STUB_CODEX_CONFIG_EFFORT=__NULL__ \
  STUB_CODEX_DEFAULT_MODEL=gpt-5.6-terra STUB_CODEX_DEFAULT_EFFORT=medium
assert_rc0
assert_count "$CASE_DIR/state/iter-01/codex.prompt.md" \
  '<sub>Model: <code>gpt-5.6-terra</code> · Effort: <code>medium</code> · Context window: <code>258400 tokens (effective)</code></sub>' 5

t "codex: active catalog supplies default effort and the default 95% window"
new_case codex-catalog-fallbacks
run_turn codex CODEX_MODEL=custom-v3 CODEX_EFFORT=off \
  STUB_CODEX_CONFIG_EFFORT=__NULL__ \
  'STUB_CODEX_CATALOG={"models":[{"slug":"custom-v3","context_window":200000,"default_reasoning_level":"high"}]}'
assert_rc0
assert_count "$CASE_DIR/state/iter-01/codex.prompt.md" \
  '<sub>Model: <code>custom-v3</code> · Effort: <code>high</code> · Context window: <code>190000 tokens (effective)</code></sub>' 5

t "codex: a config/read error cannot silently fall back to model-list defaults"
new_case codex-config-error
run_turn codex STUB_CODEX_CONFIG_ERROR=1
assert_eq "$TURN_RC" 1
assert_substr "$CASE_DIR/turn.log" 'did not report its effective model'
if [[ -e "$ARGV" ]]; then
  bad "a failed layered-config probe reached the real turn"
else
  ok
fi

# A configured wrapper can add a global flag that codex accepts for `exec` and
# refuses for app-server and `debug models` — codex-hub adds `--profile`. The
# session-start probe then supplies the same three values from the rollout.
t "codex: a wrapper that refuses the metadata subcommands still signs runtime metadata"
new_case codex-wrapper-injection
run_turn codex STUB_CODEX_REJECT_GLOBAL_FLAGS=1 \
  CODEX_MODEL=off CODEX_EFFORT=off CODEX_TIER=off
assert_rc0
assert_count "$CASE_DIR/state/iter-01/codex.prompt.md" \
  '<sub>Model: <code>gpt-5.6-sol</code> · Effort: <code>xhigh</code> · Context window: <code>997500 tokens (effective)</code></sub>' 5

t "codex: the session probe points its request at a closed loopback port"
assert_line "$ARGV.session-probe-argv" exec
assert_substr "$ARGV.session-probe-argv" 'model_provider="ai_pr_loop_metadata_probe_'
assert_substr "$ARGV.session-probe-argv" 'base_url="http://127.0.0.1:1/v1"'

probe_provider_arg() {  # <session-probe argv file>
  local raw
  raw=$(grep -o 'model_provider="[^"]*"' "$1" | head -1) || return 1
  raw=${raw#model_provider=\"}
  printf '%s' "${raw%\"}"
}

t "codex: each session probe gets its own provider nonce"
PROBE_PROVIDER_1=$(probe_provider_arg "$ARGV.session-probe-argv")
if [[ "$PROBE_PROVIDER_1" == ai_pr_loop_metadata_probe_?* ]]; then
  ok
else
  bad "probe provider carried no nonce (got: $PROBE_PROVIDER_1)"
fi

t "codex: the session probe removes its own rollout"
if [[ -e "$CASE_DIR/codex-home/sessions/rollout-metadata-probe.jsonl" ]]; then
  bad "the metadata probe left its session behind"
else
  ok
fi

t "codex: the session probe does not become the resumable review session"
assert_eq "$(cat "$CASE_DIR/state/codex.session.id" 2>/dev/null)" stub-session-uuid

# The peer's rollout appears after this probe's snapshot, shares its cwd, and
# sorts first, so a selector that matched any probe returns the peer's numbers.
t "codex: a simultaneous probe on another loop is not read"
new_case codex-wrapper-concurrent-probe
run_turn codex STUB_CODEX_REJECT_GLOBAL_FLAGS=1 \
  CODEX_MODEL=off CODEX_EFFORT=off CODEX_TIER=off \
  STUB_CODEX_PEER_PROBE=ai_pr_loop_metadata_probe_00000000000000000000000000000000
assert_rc0
assert_count "$CASE_DIR/state/iter-01/codex.prompt.md" \
  '<sub>Model: <code>gpt-5.6-sol</code> · Effort: <code>xhigh</code> · Context window: <code>997500 tokens (effective)</code></sub>' 5

t "codex: a simultaneous probe on another loop is not deleted"
if [[ -e "$CASE_DIR/codex-home/sessions/rollout-aaaa-peer-probe.jsonl" ]]; then
  ok
else
  bad "the metadata probe removed another loop's session"
fi

t "codex: a peer probe rollout cannot become the resumable review session"
assert_eq "$(cat "$CASE_DIR/state/codex.session.id" 2>/dev/null)" stub-session-uuid

t "codex: a probe nonce is not reused across turns"
PROBE_PROVIDER_2=$(probe_provider_arg "$ARGV.session-probe-argv")
if [[ -n "$PROBE_PROVIDER_2" && "$PROBE_PROVIDER_2" != "$PROBE_PROVIDER_1" ]]; then
  ok
else
  bad "two probes shared the provider nonce $PROBE_PROVIDER_2"
fi

t "codex: a wrapper that refuses everything fails before posting a guess"
new_case codex-wrapper-no-exec
run_turn codex STUB_CODEX_REJECT_GLOBAL_FLAGS=1 STUB_CODEX_NO_PROBE_SESSION=1
assert_eq "$TURN_RC" 1
assert_substr "$CASE_DIR/turn.log" 'did not report its effective model'

t "codex: explicit context window wins over bundled model metadata"
new_case codex-context-explicit
run_turn codex CODEX_CONTEXT_WINDOW=131072
assert_rc0
assert_count "$CASE_DIR/state/iter-01/codex.prompt.md" \
  '<sub>Model: <code>gpt-5.6-sol</code> · Effort: <code>ultra</code> · Context window: <code>131072 tokens (configured)</code></sub>' 5

t "codex: signature rendering HTML-escapes model text without sed corruption"
new_case codex-signature-escaping
run_turn codex 'CODEX_MODEL=model&|\<tag>$(not-a-command)`also-not`%s' CODEX_EFFORT=high CODEX_CONTEXT_WINDOW=123456
assert_rc0
assert_count "$CASE_DIR/state/iter-01/codex.prompt.md" \
  '<sub>Model: <code>model&amp;|&#92;&lt;tag&gt;&#36;(not-a-command)&#96;also-not&#96;&#37;s</code> · Effort: <code>high</code> · Context window: <code>123456 tokens (configured)</code></sub>' 5
assert_no_substr "$CASE_DIR/state/iter-01/codex.prompt.md" '{{COMMENT_SIGNATURE}}'
t "codex: hostile free-form model still leaves the github review recipe valid JSON"
if awk '
    /--input - <<'\''JSON'\''/ { body=1; next }
    body && /^[[:space:]]*JSON$/ { exit }
    body { sub(/^   /, ""); print }
  ' "$CASE_DIR/state/iter-01/codex.prompt.md" | jq -e . >/dev/null 2>&1; then
  ok
else
  bad "rendered github review JSON was corrupted by the model signature"
fi

t "codex: control bytes in a model selector are normalized in public metadata"
new_case codex-signature-control
run_turn codex $'CODEX_MODEL=control\033model' CODEX_EFFORT=high CODEX_CONTEXT_WINDOW=123456
assert_rc0
assert_count "$CASE_DIR/state/iter-01/codex.prompt.md" \
  '<sub>Model: <code>control�model</code> · Effort: <code>high</code> · Context window: <code>123456 tokens (configured)</code></sub>' 5

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

t "codex: delegated resume signs current exec-shaped resume values, not stale rollout values"
new_case codex-resume-runtime
{
  printf '{"type":"session_meta","payload":{"id":"resume-runtime-id","source":"exec","cwd":"%s"}}\n' \
    "$(cd "$CASE_DIR/repo" && pwd -P)"
  printf '%s\n' '{"type":"event_msg","payload":{"type":"task_started","model_context_window":123456}}'
  printf '%s\n' '{"type":"turn_context","payload":{"model":"session-model","effort":"high"}}'
} > "$CASE_DIR/codex-home/sessions/rollout-2026-01-01T00-00-01-seed.jsonl"
echo "resume-runtime-id" > "$CASE_DIR/state/codex.session.id"
run_turn codex CODEX_MODEL=off CODEX_EFFORT=off CODEX_TIER=off
assert_rc0
assert_pair "$ARGV" resume resume-runtime-id
assert_count "$CASE_DIR/state/iter-01/codex.prompt.md" \
  '<sub>Model: <code>gpt-5.6-sol</code> · Effort: <code>xhigh</code> · Context window: <code>258400 tokens (effective)</code></sub>' 5
assert_eq "$(jq -r '.model' "$ARGV.probe-resume")" gpt-5.6-sol
assert_eq "$(jq -r '.cwd' "$ARGV.probe-resume")" "$(cd "$CASE_DIR/repo" && pwd -P)"
assert_eq "$(jq -r '.excludeTurns' "$ARGV.probe-resume")" true

t "codex: a failed authoritative resume probe cannot fall back to stale rollout metadata"
new_case codex-resume-probe-error
printf '{"payload":{"id":"resume-error-id","source":"exec","cwd":"%s"}}\n' \
    "$(cd "$CASE_DIR/repo" && pwd -P)" \
  > "$CASE_DIR/codex-home/sessions/rollout-2026-01-01T00-00-01-seed.jsonl"
echo "resume-error-id" > "$CASE_DIR/state/codex.session.id"
run_turn codex STUB_CODEX_RESUME_ERROR=1
assert_eq "$TURN_RC" 1
assert_substr "$CASE_DIR/turn.log" 'did not report its effective model'

t "codex: executable override is used for a resumed turn"
new_case codex-resume-custom-bin
printf '{"payload":{"id":"cafebabe-dead-beef-sess","source":"exec","cwd":"%s"}}\n' \
    "$(cd "$CASE_DIR/repo" && pwd -P)" \
  > "$CASE_DIR/codex-home/sessions/rollout-2026-01-01T00-00-01-seed.jsonl"
echo "cafebabe-dead-beef-sess" > "$CASE_DIR/state/codex.session.id"
run_turn codex CODEX_BIN="$ALT_CODEX"
assert_rc0
assert_eq "$(cat "$ARGV.exe" 2>/dev/null)" "$ALT_CODEX"
assert_pair "$ARGV" resume cafebabe-dead-beef-sess

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

t "codex: an ambient session id cannot force an unrecorded resume"
new_case codex-ambient-session
printf '{"payload":{"id":"ambient-root","source":"exec","cwd":"%s"}}\n' \
  "$(cd "$CASE_DIR/repo" && pwd -P)" \
  > "$CASE_DIR/codex-home/sessions/rollout-2026-01-01T00-00-01-ambient.jsonl"
run_turn codex CODEX_SESSION_ID=ambient-root
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
    PATH="$STUBS:$SYSPATH" \
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
assert_eq "$(cat "$ARGV.probe-cwd" 2>/dev/null)" "$(cd "$CASE_DIR/repo" && pwd -P)"

