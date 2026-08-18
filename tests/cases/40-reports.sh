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
HW=$(env -i PATH="$STUBS:$SYSPATH" "$BASH_BIN" -c "
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

t "resume high-water: runtime metadata after the exact banner preserves summary recognition"
HW_META=$(env -i PATH="$STUBS:$SYSPATH" "$BASH_BIN" -c "
  . '$ROOT/lib/common.sh'
  fetch_ai_thread() {
    printf '%s\n' '{\"tag\":\"ai-loop:codex-reviewer\",\"iter\":4,\"surface\":\"issue\",\"in_reply_to_id\":null,\"body\":\"<!-- ai-loop:codex-reviewer iter=4 -->\\n\\n> [!IMPORTANT]\\n> **AUTOMATED REVIEW — AI agent (Codex Reviewer), iteration 4.**\\n> <sub>Model: <code>gpt-5.6-sol</code> · Effort: <code>ultra</code> · Context window: <code>258400 tokens (effective)</code></sub>\\nSummary text.\"}'
  }
  latest_ai_comment_iter codex")
assert_eq "$HW_META" 4

t "codex: turn fails when its summary never landed despite an APPROVED stdout"
new_case codex-no-summary
run_turn codex STUB_NO_CODEX_SUMMARY=1
assert_eq "$TURN_RC" 1

t "codex: a landed summary without the exact runtime signature is incomplete"
new_case codex-no-signature
run_turn codex STUB_OMIT_AI_SIGNATURE=1
assert_eq "$TURN_RC" 1

t "resume high-water: a manifested unsigned summary is not treated as legacy"
HW_UNSIGNED=$(env -i PATH="$STUBS:$SYSPATH" HOME="$CASE_DIR" \
  STATE_DIR="$CASE_DIR/state" FORGE=github GH_USER=testuser ITER=1 \
  REPO_OWNER=o REPO_NAME=r PR_NUMBER=1 \
  STUB_PUBLIC_ATTEMPT=1 STUB_OMIT_AI_SIGNATURE=1 \
  "$BASH_BIN" -c '. "$1/lib/common.sh"; latest_ai_comment_iter codex' \
  high-water "$ROOT")
assert_eq "$HW_UNSIGNED" ''

t "summary extraction: a signed retry wins over its baseline unsigned summary"
new_case codex-signed-summary-retry
RETRY_BASELINE="$CASE_DIR/retry-baseline.ndjson"
RETRY_THREAD="$CASE_DIR/retry-thread.ndjson"
mkdir -p "$CASE_DIR/state/iter-01"
jq -cn --arg body '<!-- ai-loop:codex-reviewer iter=1 -->

> [!IMPORTANT]
> **AUTOMATED REVIEW — AI agent (Codex Reviewer), iteration 1.**
Stale unsigned summary.' \
  '{tag:"ai-loop:codex-reviewer",iter:1,surface:"issue",id:801,
    in_reply_to_id:null,body:$body}' > "$RETRY_BASELINE"
STATE_DIR="$CASE_DIR/state" \
  record_ai_signature_attempt codex 1 "$CODEX_DEFAULT_SIGNATURE" "$RETRY_BASELINE"
cp "$RETRY_BASELINE" "$RETRY_THREAD"
jq -cn --arg sig "$CODEX_DEFAULT_SIGNATURE" '
  {tag:"ai-loop:codex-reviewer",iter:1,surface:"issue",id:802,
   in_reply_to_id:null,
   body:("<!-- ai-loop:codex-reviewer iter=1 -->\n\n> [!IMPORTANT]\n> **AUTOMATED REVIEW — AI agent (Codex Reviewer), iteration 1.**\n> " + $sig + "\nFresh signed summary.")}' \
  >> "$RETRY_THREAD"
RETRY_BODY=$(STATE_DIR="$CASE_DIR/state" \
  extract_ai_summary_body codex 1 "$RETRY_THREAD")
if [[ "$RETRY_BODY" == *"Fresh signed summary."* \
      && "$RETRY_BODY" != *"Stale unsigned summary."* ]]; then
  ok
else
  bad "summary extraction did not select the signed retry"
fi

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

t "claude: a landed summary without the exact runtime signature is incomplete"
new_case claude-no-signature
run_turn claude STUB_OMIT_AI_SIGNATURE=1
assert_eq "$TURN_RC" 1

t "claude: dies instead of answering a stale review when this iter's codex summary is missing"
new_case claude-stale-review
run_turn claude STUB_NO_CODEX_SUMMARY=1
assert_eq "$TURN_RC" 1
if grep -q "codex review for iter 1 not found" "$CASE_DIR/turn.log"; then
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

# --- round reports ---------------------------------------------------------
# Every completed turn saves its own summary to iter-NN/<who>-report.md and
# prints it, so the session driving the loop reads the round's findings and
# responses out of the orchestrator's log instead of refetching the thread.

t "codex: a completed turn exits 0 and reports"
new_case codex-report
run_turn codex
assert_eq "$TURN_RC" 0

t "codex: the saved report holds the summary body"
if grep -q 'Stub codex review\.' "$CASE_DIR/state/iter-01/codex-report.md" 2>/dev/null; then
  ok
else
  bad "codex-report.md missing or without the summary body"
fi

t "codex: the report is logged between BEGIN/END markers"
if grep -qF -- '----- BEGIN codex report (iter 1) -----' "$CASE_DIR/turn.log" \
   && grep -qF -- '----- END codex report (iter 1) -----' "$CASE_DIR/turn.log"; then
  ok
else
  bad "report delimiters absent from the turn log"
fi

t "codex: the summary body reaches the log"
if grep -q 'Stub codex review\.' "$CASE_DIR/turn.log"; then
  ok
else
  bad "summary body absent from the turn log"
fi

t "codex: one logged line carries the bot tag for the report"
# A log monitor keyed on the bot tags fires once per report, not once per
# body line.
assert_eq "$(grep -c 'codex: iter 1 report' "$CASE_DIR/turn.log")" 1

t "claude: a completed turn exits 0 and reports"
new_case claude-report
run_turn claude
assert_eq "$TURN_RC" 0

t "claude: the saved report holds the reply body"
if grep -q 'Stub claude reply\.' "$CASE_DIR/state/iter-01/claude-report.md" 2>/dev/null; then
  ok
else
  bad "claude-report.md missing or without the reply body"
fi

t "claude: the report is logged between BEGIN/END markers"
if grep -qF -- '----- BEGIN claude report (iter 1) -----' "$CASE_DIR/turn.log" \
   && grep -qF -- '----- END claude report (iter 1) -----' "$CASE_DIR/turn.log"; then
  ok
else
  bad "report delimiters absent from the turn log"
fi

t "codex: a turn whose summary never landed writes no report"
new_case codex-report-none
run_turn codex STUB_NO_CODEX_SUMMARY=1
if [[ -e "$CASE_DIR/state/iter-01/codex-report.md" ]]; then
  bad "a report was written for a turn with no landed summary"
else
  ok
fi

# The crash window: the response landed publicly, then the CLI exited
# nonzero (or its stdout marker never printed). Resume advances past the
# iteration on the landed artifact, so the report must be emitted by the
# failing turn itself or never.

t "claude: a landed response followed by a CLI failure still reports"
new_case claude-report-crash
run_turn claude STUB_CLAUDE_EXIT=17
assert_eq "$TURN_RC" 1
if grep -q 'Stub claude reply\.' "$CASE_DIR/state/iter-01/claude-report.md" 2>/dev/null; then
  ok
else
  bad "claude-report.md missing after the crash-window failure"
fi

t "claude: the crash window is named in the log"
assert_substr "$CASE_DIR/turn.log" 'response landed before the CLI failure'

t "claude: a landed response without the stdout marker still reports"
new_case claude-report-nomarker
run_turn claude STUB_CLAUDE_SILENT=1
assert_eq "$TURN_RC" 1
if grep -q 'Stub claude reply\.' "$CASE_DIR/state/iter-01/claude-report.md" 2>/dev/null; then
  ok
else
  bad "claude-report.md missing after the marker-less turn"
fi

t "claude: a CLI failure with nothing landed reports nothing"
new_case claude-report-crash-none
run_turn claude STUB_CLAUDE_EXIT=17 STUB_NO_CLAUDE_SUMMARY=1
assert_eq "$TURN_RC" 1
if [[ -e "$CASE_DIR/state/iter-01/claude-report.md" ]]; then
  bad "a report was written with no landed response"
else
  ok
fi

t "extract_ai_summary_body: a bannerless tagged note is not the summary"
XB=$(env -i PATH="$STUBS:$SYSPATH" "$BASH_BIN" -c "
  . '$ROOT/lib/common.sh'
  printf '%s\n' '{\"tag\":\"ai-loop:codex-reviewer\",\"iter\":1,\"surface\":\"issue\",\"in_reply_to_id\":null,\"body\":\"<!-- ai-loop:codex-reviewer iter=1 -->\\nOrphaned finding.\"}' > '$WORK/xb.ndjson'
  extract_ai_summary_body codex 1 '$WORK/xb.ndjson'")
assert_eq "$XB" ""

# One summary note as fetch_ai_thread maps it: the structural wrapper around
# a three-line body (7 lines in all). Shared by the emit_round_report tests;
# interpolated into their inner scripts, so it must stay single-quote-free.
RPT_SUMMARY_LINE='{"tag":"ai-loop:codex-reviewer","iter":1,"surface":"issue","in_reply_to_id":null,"body":"<!-- ai-loop:codex-reviewer iter=1 -->\n\n> [!IMPORTANT]\n> **AUTOMATED REVIEW — AI agent (Codex Reviewer), iteration 1.**\nL1\nL2\nL3"}'

t "emit_round_report: the logged body stops at AI_REPORT_LOG_MAX_LINES"
mkdir -p "$WORK/rpt/state/iter-01"
RPT=$(env -i PATH="$STUBS:$SYSPATH" "$BASH_BIN" -c "
  STATE_DIR='$WORK/rpt/state'
  LOCAL_MODE=0
  AI_REPORT_LOG_MAX_LINES=2
  . '$ROOT/lib/common.sh'
  fetch_ai_thread() {
    printf '%s\n' '$RPT_SUMMARY_LINE'
  }
  emit_round_report codex 1" 2>&1)
if grep -qF 'more line(s)' <<<"$RPT"; then
  ok
else
  bad "no truncation notice (log: $(tr '\n' '|' <<<"$RPT"))"
fi

t "emit_round_report: the untruncated body is still on disk"
assert_eq "$(grep -c '' "$WORK/rpt/state/iter-01/codex-report.md")" 7

t "emit_round_report: local mode reports the written review file"
mkdir -p "$WORK/rptlocal/state/iter-01"
printf 'local review body\n' > "$WORK/rptlocal/state/iter-01/codex-review.md"
LRPT=$(env -i PATH="$STUBS:$SYSPATH" "$BASH_BIN" -c "
  STATE_DIR='$WORK/rptlocal/state'
  LOCAL_MODE=1
  . '$ROOT/lib/common.sh'
  emit_round_report codex 1" 2>&1)
if grep -qF 'local review body' <<<"$LRPT"; then
  ok
else
  bad "local review body absent from the log"
fi

t "emit_round_report: a directory squatting on the report path warns, never fails"
# The turn already completed when this runs; an unremovable report path
# must warn and return 0 under the caller's set -e, not abort the turn.
mkdir -p "$WORK/rptdir/state/iter-01/codex-report.md"
printf 'local review body\n' > "$WORK/rptdir/state/iter-01/codex-review.md"
RPTD=$(env -i PATH="$STUBS:$SYSPATH" "$BASH_BIN" -c "
  set -euo pipefail
  STATE_DIR='$WORK/rptdir/state'
  LOCAL_MODE=1
  . '$ROOT/lib/common.sh'
  emit_round_report codex 1
  echo EMIT_OK" 2>&1)
if grep -qF 'EMIT_OK' <<<"$RPTD" && grep -qF 'WARNING' <<<"$RPTD"; then
  ok
else
  bad "unremovable report path aborted the turn (log: $(tr '\n' '|' <<<"$RPTD"))"
fi

t "emit_round_report: the squatting directory is not deleted"
# A path this function did not create is never removed recursively.
if [[ -d "$WORK/rptdir/state/iter-01/codex-report.md" ]]; then
  ok
else
  bad "the colliding directory was deleted"
fi

t "emit_round_report: local mode leaves the review artifact in place"
if [[ -s "$WORK/rptlocal/state/iter-01/codex-review.md" ]]; then
  ok
else
  bad "the review artifact was consumed"
fi

# AI_REPORT_LOG_MAX_LINES is a documented knob: a malformed value must warn
# and fall back to the default, never blow up head/arithmetic under
# `set -euo pipefail` after the round already landed publicly.

t "emit_round_report: a malformed AI_REPORT_LOG_MAX_LINES is nonfatal"
mkdir -p "$WORK/rptbad/state/iter-01"
BADCAP=$(env -i PATH="$STUBS:$SYSPATH" "$BASH_BIN" -c "
  set -euo pipefail
  STATE_DIR='$WORK/rptbad/state'
  LOCAL_MODE=0
  AI_REPORT_LOG_MAX_LINES=banana
  . '$ROOT/lib/common.sh'
  fetch_ai_thread() {
    printf '%s\n' '$RPT_SUMMARY_LINE'
  }
  emit_round_report codex 1
  echo EMIT_OK" 2>&1)
if grep -qF 'EMIT_OK' <<<"$BADCAP"; then
  ok
else
  bad "emit_round_report died on the malformed cap (log: $(tr '\n' '|' <<<"$BADCAP"))"
fi

t "emit_round_report: the malformed cap warns and logs the whole body"
if grep -qF "AI_REPORT_LOG_MAX_LINES='banana'" <<<"$BADCAP" && grep -qF 'L3' <<<"$BADCAP"; then
  ok
else
  bad "warning or body missing (log: $(tr '\n' '|' <<<"$BADCAP"))"
fi

t "emit_round_report: a negative cap falls back the same way"
mkdir -p "$WORK/rptneg/state/iter-01"
NEGCAP=$(env -i PATH="$STUBS:$SYSPATH" "$BASH_BIN" -c "
  set -euo pipefail
  STATE_DIR='$WORK/rptneg/state'
  LOCAL_MODE=0
  AI_REPORT_LOG_MAX_LINES=-5
  . '$ROOT/lib/common.sh'
  fetch_ai_thread() {
    printf '%s\n' '$RPT_SUMMARY_LINE'
  }
  emit_round_report codex 1
  echo EMIT_OK" 2>&1)
if grep -qF 'EMIT_OK' <<<"$NEGCAP" && grep -qF "AI_REPORT_LOG_MAX_LINES='-5'" <<<"$NEGCAP"; then
  ok
else
  bad "negative cap not handled (log: $(tr '\n' '|' <<<"$NEGCAP"))"
fi

t "emit_round_report: a leading-zero cap is decimal, not octal"
# '010' must mean ten: head and the truncation arithmetic read it the same
# way, with no 'value too great for base' error and no bogus notice on a
# 7-line body.
mkdir -p "$WORK/rptoct/state/iter-01"
OCTCAP=$(env -i PATH="$STUBS:$SYSPATH" "$BASH_BIN" -c "
  set -euo pipefail
  STATE_DIR='$WORK/rptoct/state'
  LOCAL_MODE=0
  AI_REPORT_LOG_MAX_LINES=010
  . '$ROOT/lib/common.sh'
  fetch_ai_thread() {
    printf '%s\n' '$RPT_SUMMARY_LINE'
  }
  emit_round_report codex 1
  echo EMIT_OK" 2>&1)
if grep -qF 'EMIT_OK' <<<"$OCTCAP" && ! grep -q 'value too great' <<<"$OCTCAP" \
   && ! grep -qF 'more line(s)' <<<"$OCTCAP" && grep -qF 'L3' <<<"$OCTCAP"; then
  ok
else
  bad "leading-zero cap mishandled (log: $(tr '\n' '|' <<<"$OCTCAP"))"
fi

t "emit_round_report: a cap past INT64_MAX logs the whole body, not nothing"
# Digits-only but bigger than bash arithmetic: 10# would wrap it negative
# and `head -n <negative>` drops every line.
mkdir -p "$WORK/rptbig/state/iter-01"
BIGCAP=$(env -i PATH="$STUBS:$SYSPATH" "$BASH_BIN" -c "
  set -euo pipefail
  STATE_DIR='$WORK/rptbig/state'
  LOCAL_MODE=0
  AI_REPORT_LOG_MAX_LINES=9999999999999999999
  . '$ROOT/lib/common.sh'
  fetch_ai_thread() {
    printf '%s\n' '$RPT_SUMMARY_LINE'
  }
  emit_round_report codex 1
  echo EMIT_OK" 2>&1)
if grep -qF 'EMIT_OK' <<<"$BIGCAP" && grep -qF 'L3' <<<"$BIGCAP" \
   && ! grep -qF 'more line(s)' <<<"$BIGCAP"; then
  ok
else
  bad "overflowing cap mishandled (log: $(tr '\n' '|' <<<"$BIGCAP"))"
fi

t "normalize_report_cap: value-level edges hold"
# Direct asserts on the pure function; the harness sourced lib/common.sh.
# 0000000009 is the one shape where octal reinterpretation would error.
NC_OK=1
[[ "$(normalize_report_cap 0000000000)" == 0 ]] || NC_OK=0
[[ "$(normalize_report_cap 0000000009)" == 9 ]] || NC_OK=0
[[ "$(normalize_report_cap 0000000010)" == 10 ]] || NC_OK=0
[[ "$(normalize_report_cap 00000000000000000002 2>/dev/null)" == 2 ]] || NC_OK=0
[[ "$(normalize_report_cap 9999999999999999999 2>/dev/null)" == 1000000 ]] || NC_OK=0
if (( NC_OK )); then ok; else bad "normalize_report_cap edge values wrong"; fi

t "emit_round_report: a zero-padded zero cap logs no body lines"
# Zero-padding must not defeat the cap: 0000000000 is 0, not the
# everything-cap the raw string length would suggest.
mkdir -p "$WORK/rptzpad/state/iter-01"
ZPAD=$(env -i PATH="$STUBS:$SYSPATH" "$BASH_BIN" -c "
  set -euo pipefail
  STATE_DIR='$WORK/rptzpad/state'
  LOCAL_MODE=0
  AI_REPORT_LOG_MAX_LINES=0000000000
  . '$ROOT/lib/common.sh'
  fetch_ai_thread() {
    printf '%s\n' '$RPT_SUMMARY_LINE'
  }
  emit_round_report codex 1
  echo EMIT_OK" 2>&1)
# ']   L1' anchors to the logged body indent — a bare 'L1' could match
# the random mktemp path inside the report-path log lines.
if grep -qF 'EMIT_OK' <<<"$ZPAD" && ! grep -qF ']   L1' <<<"$ZPAD" \
   && grep -qF '7 more line(s)' <<<"$ZPAD"; then
  ok
else
  bad "zero-padded zero cap mishandled (log: $(tr '\n' '|' <<<"$ZPAD"))"
fi

t "emit_round_report: a ten-character zero-padded cap keeps its decimal value"
mkdir -p "$WORK/rptzpad2/state/iter-01"
ZPAD2=$(env -i PATH="$STUBS:$SYSPATH" "$BASH_BIN" -c "
  set -euo pipefail
  STATE_DIR='$WORK/rptzpad2/state'
  LOCAL_MODE=0
  AI_REPORT_LOG_MAX_LINES=0000000002
  . '$ROOT/lib/common.sh'
  fetch_ai_thread() {
    printf '%s\n' '$RPT_SUMMARY_LINE'
  }
  emit_round_report codex 1
  echo EMIT_OK" 2>&1)
# Lines 1-2 of the body (the marker line and a blank) are logged; L1 on
# line 5 must not be — that pins head's count, not just the arithmetic.
if grep -qF 'EMIT_OK' <<<"$ZPAD2" && grep -qF '5 more line(s)' <<<"$ZPAD2" \
   && grep -qF ']   <!--' <<<"$ZPAD2" && ! grep -qF ']   L1' <<<"$ZPAD2"; then
  ok
else
  bad "ten-character zero-padded 2 did not cap at 2 (log: $(tr '\n' '|' <<<"$ZPAD2"))"
fi

t "emit_round_report: a cap assigned after sourcing is still guarded"
mkdir -p "$WORK/rptlate/state/iter-01"
LATECAP=$(env -i PATH="$STUBS:$SYSPATH" "$BASH_BIN" -c "
  set -euo pipefail
  STATE_DIR='$WORK/rptlate/state'
  LOCAL_MODE=0
  . '$ROOT/lib/common.sh'
  AI_REPORT_LOG_MAX_LINES=banana
  fetch_ai_thread() {
    printf '%s\n' '$RPT_SUMMARY_LINE'
  }
  emit_round_report codex 1
  echo EMIT_OK" 2>&1)
if grep -qF 'EMIT_OK' <<<"$LATECAP" && grep -qF 'L3' <<<"$LATECAP"; then
  ok
else
  bad "post-source malformed cap not guarded (log: $(tr '\n' '|' <<<"$LATECAP"))"
fi

t "emit_round_report: the verified snapshot survives a dead thread fetch"
# turn_artifact_landed saved the snapshot it verified; a transient fetch
# failure right after must not lose the round's report.
mkdir -p "$WORK/rptsnap/state/iter-01"
printf '%s\n' "$RPT_SUMMARY_LINE" > "$WORK/rptsnap/state/iter-01/thread.codex-post.ndjson"
SNAPO=$(env -i PATH="$STUBS:$SYSPATH" "$BASH_BIN" -c "
  set -euo pipefail
  STATE_DIR='$WORK/rptsnap/state'
  LOCAL_MODE=0
  . '$ROOT/lib/common.sh'
  fetch_ai_thread() { return 1; }
  emit_round_report codex 1" 2>&1)
if grep -qF 'L1' <<<"$SNAPO"; then
  ok
else
  bad "report not captured from the saved snapshot (log: $(tr '\n' '|' <<<"$SNAPO"))"
fi

t "emit_round_report: a report without a trailing newline logs its last line"
mkdir -p "$WORK/rptnonl/state/iter-01"
printf 'first line\nlast line, no newline' > "$WORK/rptnonl/state/iter-01/codex-review.md"
NONL=$(env -i PATH="$STUBS:$SYSPATH" "$BASH_BIN" -c "
  set -euo pipefail
  STATE_DIR='$WORK/rptnonl/state'
  LOCAL_MODE=1
  . '$ROOT/lib/common.sh'
  emit_round_report codex 1" 2>&1)
if grep -qF 'last line, no newline' <<<"$NONL"; then
  ok
else
  bad "the unterminated last line never reached the log (log: $(tr '\n' '|' <<<"$NONL"))"
fi

t "codex: a malformed report cap never fails a landed turn"
new_case codex-report-badcap
run_turn codex AI_REPORT_LOG_MAX_LINES=banana
assert_eq "$TURN_RC" 0


t "codex: a real forge turn renders the CI policy into its prompt"
# End-to-end spot check on prompts already rendered by the report cases
# above; the render-matrix tests cover every tag set.
assert_substr "$WORK/case-codex-report/state/iter-01/codex.prompt.md" 'CI is part of the review'
t "claude: a real forge turn renders the CI policy into its prompt"
assert_substr "$WORK/case-claude-report/state/iter-01/claude.prompt.md" 'yours to fix in THIS round'

t "claude: the description rule forbids narrating superseded approaches"
# The description states the current change; an approach that was tried and
# replaced must be deleted from it, not contrasted with the new one.
assert_substr "$WORK/case-claude-report/state/iter-01/claude.prompt.md" \
  'State only what the PR does now'
t "claude: the description rule still allows shipped prior behaviour"
assert_substr "$WORK/case-claude-report/state/iter-01/claude.prompt.md" \
  'not the codebase'

t "codex: a self-narrating description is reviewable"
assert_substr "$WORK/case-codex-report/state/iter-01/codex.prompt.md" \
  'A description that narrates its own history is a finding'

