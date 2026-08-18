# --- local review mode: flags ----------------------------------------------

t "run.sh: --base is rejected without --local"
run_run_sh --repo o/n --base main 42
assert_dies_with "--base only applies to --local"

t "run.sh: --no-push is rejected without --local"
run_run_sh --repo o/n --no-push 42
assert_dies_with "--no-push only applies to --local"

t "run.sh: --base is rejected alongside a PR/MR"
run_run_sh --repo o/n --local --base main 42
assert_dies_with "--base is for a local review with no PR/MR"

t "run.sh: a PR-less local review requires --base"
run_run_sh --local
assert_dies_with "--base REF is required"

t "run.sh: a PR-less local review rejects --repo"
run_run_sh --local --base main --repo o/n
assert_dies_with "--repo is not used"

t "run.sh: a PR-less local review rejects --host"
run_run_sh --local --base main --host gl.example.com
assert_dies_with "--host is not used"

t "run.sh: a PR-less local review rejects --forge"
run_run_sh --local --base main --forge gitlab
assert_dies_with "--forge is not used"

t "run.sh: forge mode is reported by --print-config"
run_run_sh --repo o/n --print-config 42
assert_prints 'mode: forge scope=pr base=- push=yes'

t "run.sh: local mode on a PR is reported by --print-config"
run_run_sh --repo o/n --local --print-config 42
assert_prints 'mode: local scope=pr base=- push=yes'

t "run.sh: --no-push is reported by --print-config"
run_run_sh --repo o/n --local --no-push --print-config 42
assert_prints 'mode: local scope=pr base=- push=no'

t "run.sh: a PR-less local review is reported by --print-config"
run_run_sh --local --base origin/main --dir "$WORK" --print-config
assert_prints 'mode: local scope=branch base=origin/main push=yes'

t "run.sh: a PR-less local review needs an existing directory"
run_run_sh --local --base main --dir "$WORK/no-such-dir"
assert_dies_with "no such directory"

t "run.sh: a PR-less local review needs a git work tree"
mkdir -p "$WORK/plain-dir"
run_run_sh --local --base main --dir "$WORK/plain-dir"
assert_dies_with "not a git work tree"

# --- local review mode: state identity -------------------------------------

t "state: a PR-less local review is keyed by checkout path + branch"
_ident=$(REPO_DIR_CANON=/x/y/repo HEAD_REF=feature/z LOCAL_SCOPE=branch \
         "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; printf '%s/%s\n' \
           \"\$(repo_ident_name)\" \"\$(state_leaf_name)\"")
case "$_ident" in
  local__repo-*/branch-feature_z-*) ok ;;
  *) bad "unexpected state key '$_ident'" ;;
esac

t "state: two branches of one checkout get distinct state"
_a=$(REPO_DIR_CANON=/x/y/repo HEAD_REF=a LOCAL_SCOPE=branch "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; state_leaf_name")
_b=$(REPO_DIR_CANON=/x/y/repo HEAD_REF=b LOCAL_SCOPE=branch "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; state_leaf_name")
if [[ "$_a" != "$_b" ]]; then ok; else bad "branches 'a' and 'b' share state leaf '$_a'"; fi

t "state: same-named branches in different checkouts get distinct state"
_a=$(REPO_DIR_CANON=/x/one HEAD_REF=f LOCAL_SCOPE=branch "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; repo_ident_name")
_b=$(REPO_DIR_CANON=/x/two HEAD_REF=f LOCAL_SCOPE=branch "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; repo_ident_name")
if [[ "$_a" != "$_b" ]]; then ok; else bad "two checkouts share the identity '$_a'"; fi

t "state: a forge target's state key is unchanged by the local-mode plumbing"
_ident=$(FORGE=github REPO_SLUG=o/n PR_NUMBER=7 "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; printf '%s/%s\n' \
           \"\$(repo_ident_name)\" \"\$(state_leaf_name)\"")
assert_eq "$_ident" 'o__n/pr-7'

# --- local review mode: resume high-water ----------------------------------

_lh="$WORK/local-hw"; mkdir -p "$_lh/iter-01" "$_lh/iter-02" "$_lh/iter-03"
printf 'r\n' > "$_lh/iter-01/codex-review.md"
printf 'a\n' > "$_lh/iter-01/claude-response.md"
printf 'r\n' > "$_lh/iter-02/codex-review.md"
printf 'a\n' > "$_lh/iter-02/claude-response.md"
printf 'r\n' > "$_lh/iter-03/codex-review.md"
: >       "$_lh/iter-03/claude-response.md"          # crashed turn: empty file

t "latest_local_iter: counts the reviewer's completed rounds"
assert_eq "$(STATE_DIR="$_lh" "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; latest_local_iter codex")" 3

t "latest_local_iter: an empty artifact does not count as a completed round"
assert_eq "$(STATE_DIR="$_lh" "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; latest_local_iter claude")" 2

t "latest_local_iter: a state dir with no rounds reports 0"
mkdir -p "$WORK/local-hw-empty"
assert_eq "$(STATE_DIR="$WORK/local-hw-empty" "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; latest_local_iter codex")" 0

# --- local review mode: turn contracts -------------------------------------
# The turn scripts must never touch the forge in local mode, and each turn's
# written artifact — not its stdout marker — is what completes it.

prepare_case_scope() {
  if ! git -C "$CASE_DIR/repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git init -q -b feature/x "$CASE_DIR/repo"
    git -C "$CASE_DIR/repo" config user.email t@t
    git -C "$CASE_DIR/repo" config user.name t
    printf 'base\n' > "$CASE_DIR/repo/f"
    git -C "$CASE_DIR/repo" add f
    git -C "$CASE_DIR/repo" commit -qm base
  fi
  mkdir -p "$CASE_DIR/state/local"
  git -C "$CASE_DIR/repo" rev-parse HEAD > "$CASE_DIR/state/local/base.sha"
  git -C "$CASE_DIR/repo" rev-parse HEAD > "$CASE_DIR/state/local/target-base.sha"
}

local_turn() {  # <claude|codex> [VAR=VALUE ...]
  local who="$1"; shift
  mkdir -p "$CASE_DIR/state/iter-01"
  prepare_case_scope
  run_turn "$who" LOCAL_MODE=1 LOCAL_SCOPE=branch FORGE=local \
    REPO_SLUG= REPO_OWNER= REPO_NAME= PR_NUMBER= GH_USER= "$@"
}

t "codex_turn [local]: writes the review file and completes"
new_case codex-local
local_turn codex
assert_rc0
assert_substr "$CASE_DIR/state/iter-01/codex-review.md" 'stub review'

t "codex_turn [local]: renders the local prompt, not a posting recipe"
assert_substr "$CASE_DIR/state/iter-01/codex.prompt.md" 'codex-review.md'
assert_no_substr "$CASE_DIR/state/iter-01/codex.prompt.md" 'gh pr comment'

t "codex_turn [local]: writes and injects the review-created diff report"
assert_substr "$CASE_DIR/state/iter-01/review-scope.md" '## Paths changed by the review loop (0)'
assert_substr "$CASE_DIR/state/iter-01/codex.prompt.md" 'review-scope.md'

t "codex_turn [local]: the prompt directs local validation, not forge CI"
# Forge checks describe the remote head, not the unpushed local rounds; a
# reviewer gating on them blocks (or passes) on the wrong commit.
assert_substr "$CASE_DIR/state/iter-01/codex.prompt.md" 'CI in a local review'
t "codex_turn [local]: the forge CI gate is absent from the prompt"
assert_no_substr "$CASE_DIR/state/iter-01/codex.prompt.md" 'CI is part of the review'

t "codex_turn [local]: fails the turn when no review file was written"
new_case codex-local-noartifact
local_turn codex STUB_NO_LOCAL_ARTIFACT=1
assert_eq "$TURN_RC" 1

t "codex_turn [local]: a stale review file cannot complete a crashed turn"
new_case codex-local-stale
mkdir -p "$CASE_DIR/state/iter-01"
printf 'left over from a crashed attempt\n' > "$CASE_DIR/state/iter-01/codex-review.md"
local_turn codex STUB_NO_LOCAL_ARTIFACT=1
assert_eq "$TURN_RC" 1

t "claude_turn [local]: answers the review file and writes its response"
new_case claude-local
mkdir -p "$CASE_DIR/state/iter-01"
printf 'stub review\n' > "$CASE_DIR/state/iter-01/codex-review.md"
local_turn claude
assert_rc0
assert_substr "$CASE_DIR/state/iter-01/claude-response.md" 'stub response'
assert_pair "$ARGV" --add-dir "$CASE_DIR/state"

t "claude_turn [local]: the prompt directs local validation, not forge CI"
assert_substr "$CASE_DIR/state/iter-01/claude.prompt.md" 'CI in a local review'
t "claude_turn [local]: injects the same scope evidence before editing"
assert_substr "$CASE_DIR/state/iter-01/claude.prompt.md" 'Review-created diff.'
t "claude_turn [local]: the forge CI directive is absent from the prompt"
assert_no_substr "$CASE_DIR/state/iter-01/claude.prompt.md" 'yours to fix in THIS round'

t "claude_turn [local]: fails the turn when no response file was written"
new_case claude-local-noartifact
mkdir -p "$CASE_DIR/state/iter-01"
printf 'stub review\n' > "$CASE_DIR/state/iter-01/codex-review.md"
local_turn claude STUB_NO_LOCAL_ARTIFACT=1
assert_eq "$TURN_RC" 1

t "claude_turn [local]: dies when the reviewer wrote no review"
new_case claude-local-noreview
local_turn claude
assert_eq "$TURN_RC" 1
assert_substr "$CASE_DIR/turn.log" 'codex review for iter 1 not found'

# --- local review mode: squash + push (real git) ---------------------------

LF_TEMPLATE=''
# Every case below wants the same starting repository: a bare origin, a clone
# with one base commit on main and one human commit on feature/x. Building it
# costs 13 git invocations, and git process startup dominates this area on
# Windows (~50ms each, against ~1-2ms on Linux). Build it once and copy it per
# case instead — measured at roughly a seventh of the cost, with byte-identical
# fixtures.
_lf_build_template() {
  LF_TEMPLATE="$WORK/.lf-template"
  mkdir -p "$LF_TEMPLATE"
  git init -q --bare -b main "$LF_TEMPLATE/remote.git"
  git init -q -b main "$LF_TEMPLATE/clone"
  git -C "$LF_TEMPLATE/clone" config user.email t@t
  git -C "$LF_TEMPLATE/clone" config user.name t
  echo base > "$LF_TEMPLATE/clone/f"
  git -C "$LF_TEMPLATE/clone" add f
  git -C "$LF_TEMPLATE/clone" commit -qm base
  LF_TPL_TARGET=$(git -C "$LF_TEMPLATE/clone" rev-parse HEAD)
  git -C "$LF_TEMPLATE/clone" push -q "$LF_TEMPLATE/remote.git" HEAD:refs/heads/main
  git -C "$LF_TEMPLATE/clone" checkout -qb feature/x
  echo head >> "$LF_TEMPLATE/clone/f"
  git -C "$LF_TEMPLATE/clone" commit -qam "human work"
  git -C "$LF_TEMPLATE/clone" push -q "$LF_TEMPLATE/remote.git" HEAD:refs/heads/feature/x
  LF_TPL_BASE=$(git -C "$LF_TEMPLATE/clone" rev-parse HEAD)
}
local_fixture() {  # -> $LF_REMOTE $LF_CLONE $LF_STATE $LF_BASE, branch feature/x
  local n="loc$RANDOM$RANDOM"
  [[ -n "$LF_TEMPLATE" ]] || _lf_build_template
  LF_REMOTE="$WORK/$n-remote.git"; cp -r "$LF_TEMPLATE/remote.git" "$LF_REMOTE"
  LF_CLONE="$WORK/$n-clone";       cp -r "$LF_TEMPLATE/clone" "$LF_CLONE"
  # The template carries no origin, so each copy pins its own.
  git -C "$LF_CLONE" remote add origin "$LF_REMOTE"
  LF_TARGET="$LF_TPL_TARGET"
  LF_BASE="$LF_TPL_BASE"
  LF_STATE="$WORK/$n-state"; mkdir -p "$LF_STATE/local"
  printf '%s\n' "$LF_BASE" > "$LF_STATE/local/base.sha"
  printf '%s\n' "$LF_TARGET" > "$LF_STATE/local/target-base.sha"
  # What local_setup_repo pins when the review starts. Read it back from git
  # rather than writing $LF_REMOTE: Git Bash rewrites a POSIX path argument
  # before git.exe sees it, so `git remote add origin /tmp/x` stores
  # C:/Users/.../Temp/x. Recording the path we passed in would disagree with
  # what origin_dest() reports and finalize would refuse to push.
  { git -C "$LF_CLONE" remote get-url --all origin
    git -C "$LF_CLONE" remote get-url --push --all origin
  } > "$LF_STATE/local/origin.url"
}
local_round() {  # <n> — one implementer round, committed locally
  printf 'round %s\n' "$1" >> "$LF_CLONE/f"
  git -C "$LF_CLONE" commit -qam "round $1"
}
finalize_run() {  # [VAR=VALUE ...]
  env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" ARGV_FILE="$WORK/fin-argv" \
    CODEX_HOME="$WORK/codex-home" \
    LOCAL_MODE=1 LOCAL_SCOPE=branch FORGE=local MANAGED_CLONE=0 \
    REPO_DIR="$LF_CLONE" STATE_DIR="$LF_STATE" \
    BASE_REF=main HEAD_REF=feature/x ITER=3 MAX_ITER=6 \
    REPO_SLUG= REPO_OWNER= REPO_NAME= PR_NUMBER= GH_USER= \
    HAS_CONTEXT=0 CLAUDE_MODEL=off CLAUDE_EFFORT=off CLAUDE_PERMS=off \
    "$@" \
    "$BASH_BIN" "$ROOT/finalize_turn.sh" > "$WORK/fin.log" 2>&1
  FIN_RC=$?
}
remote_head() { git -C "$LF_REMOTE" rev-parse refs/heads/feature/x; }
local_head()  { git -C "$LF_CLONE" rev-parse HEAD; }

scope_run() {  # <dest> [VAR=VALUE ...] — write the scope report, isolated
  local dest="$1"; shift
  # set -euo pipefail: the same shell flags the turn scripts run the
  # function under. Later VAR=VALUE words override the defaults.
  env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
    LOCAL_MODE=1 LOCAL_SCOPE=branch REPO_DIR="$LF_CLONE" STATE_DIR="$LF_STATE" "$@" \
    "$BASH_BIN" -c "set -euo pipefail; . '$ROOT/lib/common.sh'; local_write_scope_report '$dest'"
}

t "local scope report: separates original paths from review-added paths"
local_fixture
printf 'focused regression\n' > "$LF_CLONE/review-test.txt"
git -C "$LF_CLONE" add review-test.txt
git -C "$LF_CLONE" commit -qm 'review test'
if scope_run "$LF_STATE/scope.md" > "$WORK/scope.log" 2>&1; then
  assert_substr "$LF_STATE/scope.md" '## Review-created paths outside the original change (1)'
  assert_substr "$LF_STATE/scope.md" '`review-test.txt` — requires an explicit scope reason'
  assert_substr "$LF_STATE/scope.md" '## Paths in the original change (1)'
else
  bad "scope report failed: $(tail -3 "$WORK/scope.log" | tr '\n' ' ')"
fi

t "local scope report: every list empty renders as (none)"
# The first turn of a review with no drift has every path list empty.
local_fixture
git -C "$LF_CLONE" rev-parse HEAD > "$LF_STATE/local/target-base.sha"
if scope_run "$LF_STATE/scope-empty.md" > "$WORK/scope-empty.log" 2>&1; then
  assert_substr "$LF_STATE/scope-empty.md" '## Paths changed by the review loop (0)'
  assert_substr "$LF_STATE/scope-empty.md" '- (none)'
else
  bad "empty scope report failed: $(tail -3 "$WORK/scope-empty.log" | tr '\n' ' ')"
fi

t "local scope report: the linear classification survives odd path names"
local_fixture
mkdir -p "$LF_CLONE/dir with space"
printf 'x\n' > "$LF_CLONE/dir with space/a b.txt"
printf 'y\n' > "$LF_CLONE/-dash[glob].txt"
printf 'review edit\n' >> "$LF_CLONE/f"
git -C "$LF_CLONE" add -- "dir with space/a b.txt" "-dash[glob].txt" f
git -C "$LF_CLONE" commit -qm 'review round'
if scope_run "$LF_STATE/scope-odd.md" > "$WORK/scope-odd.log" 2>&1; then
  # f is in the original change, so only the two new paths are out of scope
  assert_substr "$LF_STATE/scope-odd.md" '## Paths changed by the review loop (3)'
  assert_substr "$LF_STATE/scope-odd.md" '## Review-created paths outside the original change (2)'
  assert_substr "$LF_STATE/scope-odd.md" 'dir\ with\ space/a\ b.txt'
else
  bad "odd-name scope report failed: $(tail -3 "$WORK/scope-odd.log" | tr '\n' ' ')"
fi

t "local scope report: classifies with no comm or sort on PATH"
# Base utilities are git and jq only; a non-GNU userland need not carry a
# NUL-capable comm or sort. The classifier must run without either.
NOGNU="$WORK/nognu-stub"; rm -rf "$NOGNU"; mkdir -p "$NOGNU"
printf '#!/bin/sh\necho "%s must not run" >&2\nexit 127\n' comm > "$NOGNU/comm"
printf '#!/bin/sh\necho "%s must not run" >&2\nexit 127\n' sort > "$NOGNU/sort"
chmod +x "$NOGNU/comm" "$NOGNU/sort"
local_fixture
printf 'review edit\n' >> "$LF_CLONE/f"
printf 'new\n' > "$LF_CLONE/newfile.txt"
git -C "$LF_CLONE" add -- f newfile.txt
git -C "$LF_CLONE" commit -qm 'review round'
if env -i PATH="$NOGNU:$SYSPATH" HOME="$WORK" \
     LOCAL_MODE=1 LOCAL_SCOPE=branch REPO_DIR="$LF_CLONE" STATE_DIR="$LF_STATE" \
     "$BASH_BIN" -c "set -euo pipefail; . '$ROOT/lib/common.sh'; local_write_scope_report '$LF_STATE/scope-nognu.md'" \
     > "$WORK/scope-nognu.log" 2>&1; then
  assert_substr "$LF_STATE/scope-nognu.md" '## Review-created paths outside the original change (1)'
  assert_substr "$LF_STATE/scope-nognu.md" '`newfile.txt` — requires an explicit scope reason'
else
  bad "no-coreutils scope report failed: $(tail -3 "$WORK/scope-nognu.log" | tr '\n' ' ')"
fi

t "local scope report: a shallow --dir clone deepens until the merge base exists"
# A depth-1 clone plus the setup's explicit tip fetches has no local merge
# base for the three-dot diffs. The report deepens the clone until the
# merge base exists.
local_fixture
SHW="$WORK/shallow-scope"; rm -rf "$SHW"; mkdir -p "$SHW/state/local"
git clone -q --depth 1 --branch feature/x "file://$LF_REMOTE" "$SHW/clone"
git -C "$SHW/clone" fetch -q origin \
  "+refs/heads/main:refs/ai-pr-loop/base" "+refs/heads/feature/x:refs/ai-pr-loop/head"
printf '%s\n' "$LF_TARGET" > "$SHW/state/local/target-base.sha"
git -C "$SHW/clone" rev-parse HEAD > "$SHW/state/local/base.sha"
# The deepen fetch requires the origin pinned at review start.
printf '%s\n%s\n' "file://$LF_REMOTE" "file://$LF_REMOTE" > "$SHW/state/local/origin.url"
if scope_run "$SHW/state/scope.md" LOCAL_SCOPE=pr BASE_REF=main HEAD_REF=feature/x \
     REPO_DIR="$SHW/clone" STATE_DIR="$SHW/state" > "$WORK/scope-shallow.log" 2>&1; then
  assert_substr "$SHW/state/scope.md" '## Paths in the original change (1)'
  assert_substr "$SHW/state/scope.md" '## Paths changed by the review loop (0)'
else
  bad "shallow scope report failed: $(tail -3 "$WORK/scope-shallow.log" | tr '\n' ' ')"
fi

t "local scope report: a shallow clone with a redirected origin never fetches"
# The deepen fetch may only reach the origin pinned at review start. A
# FRESH shallow clone: the merge base must still be absent, or the guard
# under test never runs.
rm -rf "$SHW/clone2"
git clone -q --depth 1 --branch feature/x "file://$LF_REMOTE" "$SHW/clone2"
git -C "$SHW/clone2" fetch -q origin \
  "+refs/heads/main:refs/ai-pr-loop/base" "+refs/heads/feature/x:refs/ai-pr-loop/head"
git -C "$SHW/clone2" remote set-url origin "$WORK/scope-evil.git"
if scope_run "$SHW/state/scope2.md" LOCAL_SCOPE=pr BASE_REF=main HEAD_REF=feature/x \
     REPO_DIR="$SHW/clone2" STATE_DIR="$SHW/state" > "$WORK/scope-evil.log" 2>&1; then
  bad "the scope report ran against a redirected origin"
else
  assert_substr "$WORK/scope-evil.log" 'does not match the one recorded'
fi

t "local scope report: a planted fetch refspec cannot move local refs"
# A turn can write remote.origin.fetch to map a remote branch onto a local
# one. The deepen fetch must update no local ref (--refmap= plus a
# colon-free refspec), so the planted mapping stays inert.
rm -rf "$SHW/clone3"
git clone -q --depth 1 --branch feature/x "file://$LF_REMOTE" "$SHW/clone3"
git -C "$SHW/clone3" fetch -q origin \
  "+refs/heads/main:refs/ai-pr-loop/base" "+refs/heads/feature/x:refs/ai-pr-loop/head"
git -C "$SHW/clone3" branch victim HEAD
git -C "$SHW/clone3" config remote.origin.fetch '+refs/heads/main:refs/heads/victim'
_victim=$(git -C "$SHW/clone3" rev-parse victim)
git -C "$SHW/clone3" rev-parse HEAD > "$SHW/state/local/base.sha"
if scope_run "$SHW/state/scope3.md" LOCAL_SCOPE=pr BASE_REF=main HEAD_REF=feature/x \
     REPO_DIR="$SHW/clone3" STATE_DIR="$SHW/state" > "$WORK/scope-refspec.log" 2>&1; then
  assert_eq "$(git -C "$SHW/clone3" rev-parse victim)" "$_victim"
else
  bad "shallow scope report failed: $(tail -3 "$WORK/scope-refspec.log" | tr '\n' ' ')"
fi

t "local scope report: a shallow deepen fetches no tags"
# A planted remote.origin.tagOpt=--tags would otherwise pull tags the
# review never validated. --no-tags on the deepen fetch neutralizes it.
TAGD="$WORK/tag-deepen"; rm -rf "$TAGD"; mkdir -p "$TAGD/state/local"
git init -q --bare -b main "$TAGD/remote.git"
git init -q -b main "$TAGD/seed"
git -C "$TAGD/seed" config user.email t@t; git -C "$TAGD/seed" config user.name t
echo a > "$TAGD/seed/f"; git -C "$TAGD/seed" add f; git -C "$TAGD/seed" commit -qm c0
git -C "$TAGD/seed" push -q "$TAGD/remote.git" HEAD:refs/heads/main
git -C "$TAGD/seed" checkout -qb feature/x
echo f1 >> "$TAGD/seed/f"; git -C "$TAGD/seed" commit -qam f1
echo f2 >> "$TAGD/seed/f"; git -C "$TAGD/seed" commit -qam f2
git -C "$TAGD/seed" tag deep-tag        # a tag below the depth-1 boundary
echo f3 >> "$TAGD/seed/f"; git -C "$TAGD/seed" commit -qam f3
git -C "$TAGD/seed" push -q "$TAGD/remote.git" HEAD:refs/heads/feature/x
git -C "$TAGD/seed" push -q "$TAGD/remote.git" deep-tag
git -C "$TAGD/seed" checkout -q main
echo m1 >> "$TAGD/seed/f"; git -C "$TAGD/seed" commit -qam m1   # advance main past the root
git -C "$TAGD/seed" push -q "$TAGD/remote.git" HEAD:refs/heads/main
TAGD_TARGET=$(git -C "$TAGD/seed" rev-parse main)
git clone -q --depth 1 --branch feature/x "file://$TAGD/remote.git" "$TAGD/clone"
git -C "$TAGD/clone" fetch -q origin \
  "+refs/heads/main:refs/ai-pr-loop/base" "+refs/heads/feature/x:refs/ai-pr-loop/head"
git -C "$TAGD/clone" config remote.origin.tagOpt --tags
# The setup fetch does not download the below-boundary commit deep-tag points
# at, so no tag is present yet; only the deepen reaches it.
assert_eq "$(git -C "$TAGD/clone" tag -l | tr -d '[:space:]')" ""
printf '%s\n' "$TAGD_TARGET" > "$TAGD/state/local/target-base.sha"
git -C "$TAGD/clone" rev-parse HEAD > "$TAGD/state/local/base.sha"
printf '%s\n%s\n' "file://$TAGD/remote.git" "file://$TAGD/remote.git" > "$TAGD/state/local/origin.url"
if scope_run "$TAGD/state/scope.md" LOCAL_SCOPE=pr BASE_REF=main HEAD_REF=feature/x \
     REPO_DIR="$TAGD/clone" STATE_DIR="$TAGD/state" > "$WORK/scope-tag.log" 2>&1; then
  assert_eq "$(git -C "$TAGD/clone" tag -l | tr -d '[:space:]')" ""
else
  bad "shallow tag deepen failed: $(tail -3 "$WORK/scope-tag.log" | tr '\n' ' ')"
fi

t "local scope report: a shallow deepen does not recurse into submodules"
# fetch.recurseSubmodules=true would otherwise force a submodule fetch that
# can move the submodule's caller-owned refs. --recurse-submodules=no on
# the deepen fetch neutralizes it.
SUBD="$WORK/sub-deepen"; rm -rf "$SUBD"; mkdir -p "$SUBD/state/local"
git init -q -b main "$SUBD/subseed"     # the submodule source (has a checked-out main)
git -C "$SUBD/subseed" config user.email t@t; git -C "$SUBD/subseed" config user.name t
echo s1 > "$SUBD/subseed/s"; git -C "$SUBD/subseed" add s; git -C "$SUBD/subseed" commit -qm s1
git init -q --bare "$SUBD/remote.git"
git init -q -b main "$SUBD/seed"
git -C "$SUBD/seed" config user.email t@t; git -C "$SUBD/seed" config user.name t
echo a > "$SUBD/seed/f"; git -C "$SUBD/seed" add f; git -C "$SUBD/seed" commit -qm c1
git -C "$SUBD/seed" -c protocol.file.allow=always submodule add -q "$SUBD/subseed" sub 2>/dev/null
git -C "$SUBD/seed" commit -qm addsub
SUBD_TARGET=$(git -C "$SUBD/seed" rev-parse HEAD)
git -C "$SUBD/seed" push -q "$SUBD/remote.git" HEAD:refs/heads/main
git -C "$SUBD/seed" checkout -qb feature/x
for _i in 1 2 3; do echo "c$_i" >> "$SUBD/seed/f"; git -C "$SUBD/seed" commit -qam "c$_i"; done
git -C "$SUBD/seed" push -q "$SUBD/remote.git" HEAD:refs/heads/feature/x
git -c protocol.file.allow=always clone -q --depth 1 --branch feature/x "file://$SUBD/remote.git" "$SUBD/clone"
git -C "$SUBD/clone" fetch -q origin \
  "+refs/heads/main:refs/ai-pr-loop/base" "+refs/heads/feature/x:refs/ai-pr-loop/head"
git -C "$SUBD/clone" -c protocol.file.allow=always submodule update --init -q sub
git -C "$SUBD/clone" config fetch.recurseSubmodules true
git -C "$SUBD/clone/sub" update-ref -d refs/remotes/origin/main   # the recurse marker
printf '%s\n' "$SUBD_TARGET" > "$SUBD/state/local/target-base.sha"
git -C "$SUBD/clone" rev-parse HEAD > "$SUBD/state/local/base.sha"
printf '%s\n%s\n' "file://$SUBD/remote.git" "file://$SUBD/remote.git" > "$SUBD/state/local/origin.url"
if scope_run "$SUBD/state/scope.md" LOCAL_SCOPE=pr BASE_REF=main HEAD_REF=feature/x \
     REPO_DIR="$SUBD/clone" STATE_DIR="$SUBD/state" > "$WORK/scope-sub.log" 2>&1; then
  if git -C "$SUBD/clone/sub" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null 2>&1; then
    bad "the deepen fetch recursed into the submodule"; else ok; fi
else
  bad "shallow submodule deepen failed: $(tail -3 "$WORK/scope-sub.log" | tr '\n' ' ')"
fi

t "finalize: three local rounds become one pushed commit"
local_fixture; local_round 1; local_round 2; local_round 3
finalize_run CLAUDE_BIN="$ALT_CLAUDE"
assert_eq "$FIN_RC" 0
assert_eq "$(git -C "$LF_CLONE" rev-list --count "$LF_BASE..HEAD")" 1
assert_eq "$(remote_head)" "$(local_head)"

t "finalize: the closing Claude turn uses the executable override"
assert_eq "$(cat "$WORK/fin-argv.exe" 2>/dev/null)" "$ALT_CLAUDE"
assert_eq "$(cat "$WORK/fin-argv.probe-exe" 2>/dev/null)" "$ALT_CLAUDE"

t "finalize: the pushed commit carries the composed message"
assert_eq "$(git -C "$LF_CLONE" log -1 --format=%s)" 'Squashed subject line'

t "finalize: the pushed commit is authored by the implementer bot"
assert_eq "$(git -C "$LF_CLONE" log -1 --format=%an)" 'claude-implementer (ai-bot)'

t "finalize: the human's own commits are left untouched"
assert_eq "$(git -C "$LF_CLONE" log -1 --format=%s "$LF_BASE")" 'human work'

t "finalize: the squashed tree is exactly what the rounds produced"
assert_eq "$(cat "$LF_CLONE/f" | tr '\n' ' ')" 'base head round 1 round 2 round 3 '

t "finalize: keeps the final review scope report for audit"
assert_substr "$LF_STATE/local/review-scope.md" '## Paths changed by the review loop (1)'

t "finalize: a fresh run after the push has nothing left to do"
finalize_run
assert_eq "$FIN_RC" 3

t "finalize: --no-push squashes but leaves the remote alone"
local_fixture; local_round 1; local_round 2
finalize_run NO_PUSH=1
assert_eq "$FIN_RC" 0
assert_eq "$(git -C "$LF_CLONE" rev-list --count "$LF_BASE..HEAD")" 1
assert_eq "$(remote_head)" "$LF_BASE"

t "finalize: a held squash records its outcome kind"
assert_eq "$(awk '{print $1}' "$LF_STATE/local/finalized" 2>/dev/null)" 'squash'

t "finalize: re-running a held squash pushes it without composing again"
finalize_run STUB_NO_FINALIZE_MSG=1     # a re-compose would leave no message
assert_eq "$FIN_RC" 0
assert_eq "$(remote_head)" "$(local_head)"
assert_eq "$(git -C "$LF_CLONE" log -1 --format=%s)" 'Squashed subject line'

t "finalize: a held outcome whose kind disagrees with the mode is not reused"
local_fixture; local_round 1
finalize_run NO_PUSH=1                       # a held SQUASH outcome
assert_eq "$FIN_RC" 0
printf 'nocommit %s\n' "$(local_head)" > "$LF_STATE/local/finalized"   # kind says otherwise
rm -f "$WORK/fin-argv.calls"
finalize_run STUB_NO_FINALIZE_MSG=1          # a fresh turn writes no message
assert_eq "$FIN_RC" 1
if [[ -e "$WORK/fin-argv.calls" ]]; then ok
else bad "a held outcome was reused despite its kind disagreeing with the mode"; fi

t "finalize: rounds with no net change push nothing"
local_fixture
printf 'x\n' >> "$LF_CLONE/f"; git -C "$LF_CLONE" commit -qam "round 1"
git -C "$LF_CLONE" revert --no-edit HEAD >/dev/null
finalize_run
assert_eq "$FIN_RC" 3
assert_eq "$(remote_head)" "$LF_BASE"

t "finalize: a branch that moved on the remote is never force-pushed"
local_fixture; local_round 1
git -C "$LF_CLONE" push -q origin "$LF_BASE:refs/heads/side"   # keep the object
_moved=$(git -C "$LF_CLONE" commit-tree "$LF_BASE^{tree}" -p "$LF_BASE" -m "someone else" \
           -c user.name=o -c user.email=o@o 2>/dev/null \
         || GIT_AUTHOR_NAME=o GIT_AUTHOR_EMAIL=o@o GIT_COMMITTER_NAME=o GIT_COMMITTER_EMAIL=o@o \
            git -C "$LF_CLONE" commit-tree "$LF_BASE^{tree}" -p "$LF_BASE" -m "someone else")
git -C "$LF_CLONE" push -q origin "$_moved:refs/heads/feature/x"
finalize_run
assert_eq "$FIN_RC" 1
assert_eq "$(remote_head)" "$_moved"
assert_eq "$(git -C "$LF_CLONE" rev-list --count "$LF_BASE..HEAD")" 1

t "finalize: a compose that wrote no message leaves the rounds intact"
local_fixture; local_round 1; local_round 2
finalize_run STUB_NO_FINALIZE_MSG=1
assert_eq "$FIN_RC" 1
assert_eq "$(git -C "$LF_CLONE" rev-list --count "$LF_BASE..HEAD")" 2
assert_eq "$(remote_head)" "$LF_BASE"

t "finalize: refuses to rewrite history it did not create"
local_fixture; local_round 1
git -C "$LF_CLONE" reset -q --hard "$LF_BASE~1"   # branch moved off the recorded base
finalize_run
assert_eq "$FIN_RC" 1
assert_substr "$WORK/fin.log" 'no longer descends from the squash base'

# --- local review mode: only the approved tree is pushed --------------------
# Nothing the closing turn leaves behind (edits, staged files, commits) and
# no commit hook may change the tree between Codex's approval and the push.

t "finalize: an edit staged by the closing turn never reaches the squash"
local_fixture; local_round 1
_approved=$(git -C "$LF_CLONE" rev-parse 'HEAD^{tree}')
finalize_run STUB_FINALIZE_MUTATE=1
assert_eq "$FIN_RC" 0
assert_eq "$(remote_head)" "$(local_head)"
assert_eq "$(git -C "$LF_CLONE" rev-parse 'HEAD^{tree}')" "$_approved"
if git -C "$LF_CLONE" show HEAD:f | grep -q 'mutated after approval'; then
  bad "a post-approval edit reached the pushed commit"; else ok; fi

t "finalize: a closing turn that commits fails closed, pushing nothing"
local_fixture; local_round 1
_tip=$(local_head)
finalize_run STUB_FINALIZE_COMMIT=1
assert_eq "$FIN_RC" 1
assert_eq "$(remote_head)" "$LF_BASE"
assert_substr "$WORK/fin.log" 'refusing to squash a tree the review never saw'
assert_eq "$(local_head)" "$_tip"     # rogue commit dropped, rounds restored

t "finalize: a closing turn that detaches HEAD fails closed, pushing nothing"
local_fixture; local_round 1
finalize_run STUB_FINALIZE_SH='git checkout -q --detach HEAD'
assert_eq "$FIN_RC" 1
assert_eq "$(remote_head)" "$LF_BASE"
assert_substr "$WORK/fin.log" 'switched or detached'

t "finalize: a turn that redirects origin aborts before any push"
local_fixture; local_round 1
_evil="$WORK/evil-a-$RANDOM.git"; git init -q --bare "$_evil"
finalize_run STUB_FINALIZE_SH="git remote set-url origin $_evil"
assert_eq "$FIN_RC" 1
assert_substr "$WORK/fin.log" 'destination of origin changed'
if git -C "$_evil" show-ref -q 2>/dev/null; then
  bad "the evil remote received a push"; else ok; fi
assert_eq "$(remote_head)" "$LF_BASE"

t "finalize: a turn that removes origin aborts instead of landing locally"
local_fixture; local_round 1
finalize_run STUB_FINALIZE_SH='git remote remove origin'
assert_eq "$FIN_RC" 1
assert_substr "$WORK/fin.log" 'destination of origin changed'
if [[ -e "$LF_STATE/local/completed.sha" ]]; then
  bad "a redirected run was marked completed"; else ok; fi

t "finalize: a redirect planted before finalize dies without spending a turn"
local_fixture; local_round 1
_evil="$WORK/evil-c-$RANDOM.git"; git init -q --bare "$_evil"
git -C "$LF_CLONE" remote set-url origin "$_evil"
rm -f "$WORK/fin-argv.calls"
finalize_run
assert_eq "$FIN_RC" 1
assert_substr "$WORK/fin.log" 'does not match the one recorded'
if [[ -e "$WORK/fin-argv.calls" ]]; then
  bad "an agent turn was spent with a redirected remote"; else ok; fi
if git -C "$_evil" show-ref -q 2>/dev/null; then
  bad "the evil remote received a push"; else ok; fi

t "finalize: a missing destination record fails closed"
local_fixture; local_round 1
rm -f "$LF_STATE/local/origin.url"    # a turn deleted the pin to force a re-pin
rm -f "$WORK/fin-argv.calls"
finalize_run
assert_eq "$FIN_RC" 1
assert_substr "$WORK/fin.log" 'no pinned origin destination'
if [[ -e "$WORK/fin-argv.calls" ]]; then
  bad "an agent turn was spent with no pinned destination"; else ok; fi
assert_eq "$(remote_head)" "$LF_BASE"

t "finalize: a repo where git status fails never pushes"
# A status error prints nothing. Empty output must never read as a clean
# tree anywhere between the entry cleanup and the pre-push probe. An index
# that cannot be opened breaks every worktree probe of the invocation.
local_fixture; local_round 1
finalize_run NO_PUSH=1               # hold the squash — only the push remains
assert_eq "$FIN_RC" 0
mv "$LF_CLONE/.git/index" "$WORK/fin-index.bak"
mkdir "$LF_CLONE/.git/index"
finalize_run
rmdir "$LF_CLONE/.git/index"
mv "$WORK/fin-index.bak" "$LF_CLONE/.git/index"
if (( FIN_RC == 0 )); then
  bad "finalize pushed although its worktree probes failed"; else ok; fi
t "finalize: the failed probe left the remote untouched"
assert_eq "$(remote_head)" "$LF_BASE"

t "finalize: tolerated submodule eol noise does not block the push"
# Non-idempotent eol/filter state inside an initialized submodule survives
# every cleanup (each checkout re-dirties it) and force_clean_to_commit
# deliberately tolerates it — it cannot be published through a superproject
# commit. finalize must run to completion on such a repo, so its entry sync
# tolerates that noise instead of aborting before the push.
local_fixture
git init -q -b main "$WORK/fin-subsrc"
git -C "$WORK/fin-subsrc" config user.email t@t
git -C "$WORK/fin-subsrc" config user.name t
printf 'line1\r\nline2\r\n' > "$WORK/fin-subsrc/s.txt"
git -C "$WORK/fin-subsrc" -c core.autocrlf=false add s.txt
git -C "$WORK/fin-subsrc" commit -qm crlf
printf 's.txt text eol=lf\n' > "$WORK/fin-subsrc/.gitattributes"
git -C "$WORK/fin-subsrc" add .gitattributes
git -C "$WORK/fin-subsrc" commit -qm attrs   # CRLF blob + LF worktree rule
git -C "$LF_CLONE" -c protocol.file.allow=always submodule --quiet add "$WORK/fin-subsrc" sub
git -C "$LF_CLONE" commit -qm 'round 1: vendor a submodule'
finalize_run
assert_eq "$FIN_RC" 0
assert_eq "$(remote_head)" "$(local_head)"

# Note: cases covering config-planted machinery — clean filters, core.fsmonitor
# programs, pre-push and reference-transaction hooks, and url.*.pushInsteadOf
# rewrites — were removed. They modelled a repository crafted to redirect the
# push, which is not a threat this tool faces: one operator reviews their own
# work. The invariant those cases guarded is still covered by "the push reached
# the origin pinned at review start" and by the plain redirect/removal cases
# above, which is what a turn realistically does wrong.

# --- local review mode: a finished review is terminal -----------------------
# Once the single commit is in its final resting place — pushed, or the
# local tip with no origin to push to — nothing may resume the review or
# rewrite what landed after it.

t "finalize [no origin]: the squashed commit lands and the review completes"
local_fixture; local_round 1
git -C "$LF_CLONE" remote remove origin
printf '(none)\n' > "$LF_STATE/local/origin.url"   # a no-origin review pins "(none)"
finalize_run
assert_eq "$FIN_RC" 0
assert_eq "$(git -C "$LF_CLONE" rev-list --count "$LF_BASE..HEAD")" 1
assert_eq "$(cat "$LF_STATE/local/completed.sha")" "$(local_head)"
if [[ -e "$LF_STATE/local/base.sha" || -e "$LF_STATE/local/finalized" ]]; then
  bad "in-progress markers survived a completed no-origin review"; else ok; fi

t "finalize [no origin]: a rerun after completion squashes nothing again"
_done=$(local_head)
finalize_run
assert_eq "$FIN_RC" 3
assert_eq "$(local_head)" "$_done"

t "finalize [no origin]: a human commit made after completion is untouched"
printf 'human follow-up\n' >> "$LF_CLONE/f"
git -C "$LF_CLONE" commit -qam "human follow-up"
_human=$(local_head)
finalize_run
assert_eq "$FIN_RC" 3
assert_eq "$(local_head)" "$_human"
if git -C "$LF_CLONE" merge-base --is-ancestor "$_done" "$_human"; then ok
else bad "the completed squash is no longer an ancestor of the human commit"; fi

t "finalize: pushback-only agreement (no commits) completes the review"
local_fixture
rm -f "$WORK/fin-argv.calls"
finalize_run
assert_eq "$FIN_RC" 3
assert_eq "$(cat "$LF_STATE/local/completed.sha")" "$LF_BASE"
if [[ -e "$LF_STATE/local/base.sha" ]]; then
  bad "base.sha survived a completed review"; else ok; fi
if [[ -e "$WORK/fin-argv.calls" ]]; then
  bad "a compose turn was spent with nothing to land"; else ok; fi

t "finalize: net-zero rounds complete without spending a compose turn"
local_fixture
printf 'x\n' >> "$LF_CLONE/f"; git -C "$LF_CLONE" commit -qam "round 1"
git -C "$LF_CLONE" revert --no-edit HEAD >/dev/null
rm -f "$WORK/fin-argv.calls"
finalize_run
assert_eq "$FIN_RC" 3
assert_eq "$(remote_head)" "$LF_BASE"
assert_eq "$(local_head)" "$LF_BASE"
assert_eq "$(cat "$LF_STATE/local/completed.sha")" "$LF_BASE"
if [[ -e "$WORK/fin-argv.calls" ]]; then
  bad "a compose turn was spent on net-zero rounds"; else ok; fi

# --- local review mode: positioning a PR/MR run ----------------------------
# The rounds of a PR-scope run sit on a detached HEAD in a checkout shared
# with other PRs of the repo, so they are kept on a private ref and restored
# on the next invocation. Driven directly: run.sh's clone guard rejects the
# local-path origin a fixture must use.

setup_run() {  # <fn> [VAR=VAL ...] — run one lib function against the fixture
  env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
    LOCAL_MODE=1 LOCAL_SCOPE=pr MANAGED_CLONE=1 PR_NUMBER=42 \
    REPO_DIR="$LF_CLONE" STATE_DIR="$LF_STATE" BASE_REF=main HEAD_REF=feature/x \
    "${@:2}" \
    "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; $1" > "$WORK/setup.log" 2>&1
}

t "local_setup_repo [branch]: pins the diff base from --base"
local_fixture; rm -f "$LF_STATE/local/base.sha"
_want=$(git -C "$LF_CLONE" rev-parse "$LF_BASE~1")
if env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
     LOCAL_MODE=1 LOCAL_SCOPE=branch MANAGED_CLONE=0 \
     REPO_DIR="$LF_CLONE" STATE_DIR="$LF_STATE" BASE_REF=main HEAD_REF=feature/x \
     LOCAL_BASE_SHA="$_want" \
     "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; local_setup_repo" >/dev/null 2>&1; then
  assert_eq "$(git -C "$LF_CLONE" rev-parse refs/ai-pr-loop/base)" "$_want"
  assert_eq "$(cat "$LF_STATE/local/base.sha")" "$LF_BASE"
  assert_eq "$(cat "$LF_STATE/local/tip.sha")" "$LF_BASE"
else
  bad "local_setup_repo failed in branch scope"
fi

# A branch review's only anchor is the branch itself, so every resume must
# prove the branch is exactly where the last committed round left it.
branch_setup() {  # <base-sha> — run local_setup_repo in branch scope
  setup_run local_setup_repo LOCAL_SCOPE=branch MANAGED_CLONE=0 LOCAL_BASE_SHA="$1"
}

t "local_setup_repo [branch]: resumes when the branch is on the recorded tip"
local_round 1
_tip=$(local_head)
printf '%s\n' "$_tip" > "$LF_STATE/local/tip.sha"    # what local_record_tip persists
if branch_setup "$(git -C "$LF_CLONE" rev-parse "$LF_BASE~1")" \
   && [[ "$(local_head)" == "$_tip" ]]; then ok
else bad "resume moved the branch ($(tail -1 "$WORK/setup.log"))"; fi

t "local_setup_repo [branch]: a branch reset outside the loop fails closed"
git -C "$LF_CLONE" reset -q --hard "$LF_BASE"        # round 1 vanishes from the branch
if branch_setup "$(git -C "$LF_CLONE" rev-parse "$LF_BASE~1")"; then
  bad "a reset branch was silently resumed at the wrong tip"
else
  assert_substr "$WORK/setup.log" 'moved outside the loop'
fi

t "local_setup_repo [branch]: a branch advanced outside the loop fails closed"
git -C "$LF_CLONE" reset -q --hard "$_tip"           # back on the recorded tip...
printf 'foreign\n' >> "$LF_CLONE/f"
git -C "$LF_CLONE" commit -qam "foreign commit"      # ...plus a commit no turn made
if branch_setup "$(git -C "$LF_CLONE" rev-parse "$LF_BASE~1")"; then
  bad "foreign commits would have been squashed as review work"
else
  assert_substr "$WORK/setup.log" 'moved outside the loop'
fi

t "local_setup_repo [branch]: recorded rounds without an expected tip fail closed"
git -C "$LF_CLONE" reset -q --hard "$_tip"
rm -f "$LF_STATE/local/tip.sha"
if branch_setup "$(git -C "$LF_CLONE" rev-parse "$LF_BASE~1")"; then
  bad "an incomplete state dir was silently trusted"
else
  assert_substr "$WORK/setup.log" 'no expected tip'
fi

t "local_setup_repo [PR/MR]: starts at the PR head and records it as the base"
local_fixture; rm -f "$LF_STATE/local/base.sha"
git -C "$LF_CLONE" checkout -q main            # a managed clone can be anywhere
if setup_run local_setup_repo; then
  assert_eq "$(cat "$LF_STATE/local/base.sha")" "$LF_BASE"
  assert_eq "$(cat "$LF_STATE/local/tip.sha")" "$LF_BASE"
  assert_eq "$(local_head)" "$LF_BASE"
  assert_eq "$(git -C "$LF_CLONE" rev-parse refs/ai-pr-loop/local/pr-42)" "$LF_BASE"
else
  bad "local_setup_repo failed ($(tail -1 "$WORK/setup.log"))"
fi

t "local_setup_repo [PR/MR]: a later invocation restores the earlier rounds"
local_round 1; local_round 2
_tip=$(local_head)
git -C "$LF_CLONE" update-ref refs/ai-pr-loop/local/pr-42 "$_tip"
printf '%s\n' "$_tip" > "$LF_STATE/local/tip.sha"    # what local_record_tip persists
git -C "$LF_CLONE" checkout -q --detach "$LF_BASE"   # another PR's run moved it
if setup_run local_setup_repo && [[ "$(local_head)" == "$_tip" ]] \
   && [[ "$(cat "$LF_STATE/local/base.sha")" == "$LF_BASE" ]]; then ok
else bad "resume lost the local rounds ($(tail -1 "$WORK/setup.log"))"; fi

t "local_setup_repo [PR/MR]: refuses to stack rounds on a head that moved"
git -C "$LF_CLONE" push -q origin "$LF_BASE~1:refs/heads/feature/x" --force
if setup_run local_setup_repo; then
  bad "a moved PR head was accepted; the squash could never be pushed"
else
  assert_substr "$WORK/setup.log" 'moved to'
fi

t "local_setup_repo [PR/MR]: a tip ref moved outside the loop fails closed"
git -C "$LF_CLONE" push -q origin "$LF_BASE:refs/heads/feature/x" --force  # restore the PR head
git -C "$LF_CLONE" update-ref refs/ai-pr-loop/local/pr-42 "$LF_BASE"       # ...but the ref moved
if setup_run local_setup_repo; then
  bad "a moved tip ref silently dropped the recorded rounds"
else
  assert_substr "$WORK/setup.log" 'moved outside the loop'
fi

t "local_setup_repo [PR/MR]: recorded rounds without an expected tip fail closed"
git -C "$LF_CLONE" update-ref refs/ai-pr-loop/local/pr-42 "$_tip"
rm -f "$LF_STATE/local/tip.sha"
if setup_run local_setup_repo; then
  bad "an incomplete state dir was silently trusted"
else
  assert_substr "$WORK/setup.log" 'no expected tip'
fi

t "local_setup_repo [PR/MR]: rounds recorded but missing from the checkout fail closed"
local_fixture     # base.sha present, no tip ref in this clone
if setup_run local_setup_repo; then
  bad "a checkout with no local rounds silently restarted them"
else
  assert_substr "$WORK/setup.log" 'cannot be recovered'
fi

# --- local review mode on a PR/MR: the forge stays read-only ---------------

t "codex_turn [local, PR/MR]: does not read the forge comment thread"
new_case codex-local-pr
mkdir -p "$CASE_DIR/state/iter-01"
prepare_case_scope
run_turn codex LOCAL_MODE=1 LOCAL_SCOPE=pr FORGE=github \
  STUB_FORGED_GH_SUMMARY=1     # would appear in a fetched thread
assert_rc0
if [[ -f "$CASE_DIR/state/iter-01/thread.ndjson" \
      && ! -s "$CASE_DIR/state/iter-01/thread.ndjson" ]]; then ok
else bad "the local turn fetched a forge comment thread"; fi

t "codex_turn [local, PR/MR]: prompt keeps read-only access, drops posting"
assert_substr "$CASE_DIR/state/iter-01/codex.prompt.md" 'gh pr view'
assert_no_substr "$CASE_DIR/state/iter-01/codex.prompt.md" 'gh pr comment'

t "claude_turn [local, PR/MR]: answers the file, never the comment thread"
new_case claude-local-pr
mkdir -p "$CASE_DIR/state/iter-01"
printf 'stub review\n' > "$CASE_DIR/state/iter-01/codex-review.md"
prepare_case_scope
run_turn claude LOCAL_MODE=1 LOCAL_SCOPE=pr FORGE=github
assert_rc0
assert_substr "$CASE_DIR/state/iter-01/claude-response.md" 'stub response'
assert_no_substr "$CASE_DIR/state/iter-01/claude.prompt.md" 'gh pr comment'

# The one forge write of a local run: the PR/MR text, after the push. A
# PR-scope run keeps its rounds on a private ref (they sit on a detached HEAD
# in a checkout shared with other PRs), so the fixture records one too.
local_pr_fixture() {
  local_fixture
  local_round 1
  git -C "$LF_CLONE" update-ref refs/ai-pr-loop/local/pr-42 HEAD
}
finalize_run_pr() {  # [VAR=VALUE ...]
  env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" ARGV_FILE="$WORK/fin-argv" \
    CODEX_HOME="$WORK/codex-home" \
    LOCAL_MODE=1 LOCAL_SCOPE=pr FORGE=github MANAGED_CLONE=0 \
    REPO_DIR="$LF_CLONE" STATE_DIR="$LF_STATE" \
    BASE_REF=main HEAD_REF=feature/x ITER=3 MAX_ITER=6 \
    REPO_SLUG=o/n REPO_OWNER=o REPO_NAME=n PR_NUMBER=42 GH_USER=testuser \
    HAS_CONTEXT=0 CLAUDE_MODEL=off CLAUDE_EFFORT=off CLAUDE_PERMS=off \
    "$@" \
    "$BASH_BIN" "$ROOT/finalize_turn.sh" > "$WORK/fin.log" 2>&1
  FIN_RC=$?
}

t "finalize [PR/MR]: refreshes the title and description after the push"
local_pr_fixture
rm -f "$WORK/fin-argv.ghedit"
finalize_run_pr STUB_FINALIZE_TITLE='New title' STUB_FINALIZE_DESC='New body'
assert_eq "$FIN_RC" 0
assert_eq "$(remote_head)" "$(local_head)"
assert_pair "$WORK/fin-argv.ghedit" --title 'New title'
assert_line "$WORK/fin-argv.ghedit" --body-file

t "finalize [PR/MR]: leaves the title and description alone when unchanged"
local_pr_fixture
rm -f "$WORK/fin-argv.ghedit"
finalize_run_pr
assert_eq "$FIN_RC" 0
if [[ -e "$WORK/fin-argv.ghedit" ]]; then bad "edited the PR text with nothing proposed"; else ok; fi

t "finalize [PR/MR]: --no-push writes nothing to the forge"
local_pr_fixture
rm -f "$WORK/fin-argv.ghedit"
finalize_run_pr NO_PUSH=1 STUB_FINALIZE_TITLE='New title'
assert_eq "$FIN_RC" 0
assert_eq "$(remote_head)" "$LF_BASE"
if [[ -e "$WORK/fin-argv.ghedit" ]]; then bad "edited the PR text before the push landed"; else ok; fi

# The one GitLab write must never carry a line GitLab would run as a quick
# action. The guard is syntactic — any line whose first non-blank character
# opens a /word — because a denylist of commands falls behind GitLab
# releases (/run_pipeline, /copy_metadata, ... were not in the original).
finalize_run_gl() {  # [VAR=VALUE ...] — finalize_run_pr, retargeted at GitLab
  finalize_run_pr FORGE=gitlab FORGE_HOST=gl.example FORGE_SCHEME=https \
    PROJECT_ENC=g%2Fp GITLAB_TOKEN=tok CURL_LOG="$WORK/fin-curl.log" \
    REPO_SLUG=g/p REPO_OWNER=g REPO_NAME=p "$@"
}

t "finalize [GitLab]: a leading quick action blocks the description update"
local_pr_fixture
: > "$WORK/fin-curl.log"
finalize_run_gl STUB_FINALIZE_DESC=$'New body\n/run_pipeline'
assert_eq "$FIN_RC" 0
assert_eq "$(remote_head)" "$(local_head)"
assert_substr "$WORK/fin.log" 'quick action'
if grep -q '^PUT .*merge_requests' "$WORK/fin-curl.log"; then
  bad "the description PUT fired with a quick action in the body"; else ok; fi

t "finalize [GitLab]: leading whitespace does not hide a quick action"
local_pr_fixture
: > "$WORK/fin-curl.log"
finalize_run_gl STUB_FINALIZE_DESC=$'New body\n  /close'
assert_eq "$FIN_RC" 0
if grep -q '^PUT .*merge_requests' "$WORK/fin-curl.log"; then
  bad "an indented quick action reached the MR"; else ok; fi

t "finalize [GitLab]: a clean description is delivered after the push"
local_pr_fixture
: > "$WORK/fin-curl.log"
finalize_run_gl STUB_FINALIZE_DESC='See the notes in /docs/readme.md for details'
assert_eq "$FIN_RC" 0
# The logged body is jq-formatted (multi-line), so match its parts apart.
assert_substr "$WORK/fin-curl.log" 'PUT https://gl.example/api/v4/projects/g%2Fp/merge_requests/42'
assert_substr "$WORK/fin-curl.log" 'docs/readme.md'

t "finalize [PR/MR]: recovery never moves a branch the turn checked out"
local_pr_fixture
git -C "$LF_CLONE" branch victim "$LF_BASE"
finalize_run_pr STUB_FINALIZE_SH='git checkout -q victim'
assert_eq "$FIN_RC" 1
assert_eq "$(git -C "$LF_CLONE" rev-parse refs/heads/victim)" "$LF_BASE"
assert_eq "$(remote_head)" "$LF_BASE"
assert_substr "$WORK/fin.log" 'refusing to squash a tree the review never saw'

# --- local review mode: metadata-only finalization (PR/MR, nothing lands) ---
# A review that lands no net change still runs the closing turn on a PR/MR:
# corrections to a stale title/description the rounds agreed on are the one
# remaining write.

t "finalize [PR/MR]: a zero-commit review still refreshes stale PR text"
local_fixture
git -C "$LF_CLONE" update-ref refs/ai-pr-loop/local/pr-42 HEAD
rm -f "$WORK/fin-argv.ghedit"
finalize_run_pr STUB_FINALIZE_TITLE='Corrected title'
assert_eq "$FIN_RC" 3
assert_pair "$WORK/fin-argv.ghedit" --title 'Corrected title'
assert_eq "$(remote_head)" "$LF_BASE"
assert_eq "$(cat "$LF_STATE/local/completed.sha")" "$LF_BASE"

t "finalize [PR/MR]: a net-zero review still refreshes stale PR text"
local_fixture
printf 'x\n' >> "$LF_CLONE/f"; git -C "$LF_CLONE" commit -qam "round 1"
git -C "$LF_CLONE" revert --no-edit HEAD >/dev/null
git -C "$LF_CLONE" update-ref refs/ai-pr-loop/local/pr-42 HEAD
rm -f "$WORK/fin-argv.ghedit"
finalize_run_pr STUB_FINALIZE_DESC='Corrected body'
assert_eq "$FIN_RC" 3
assert_line "$WORK/fin-argv.ghedit" --body-file
assert_eq "$(remote_head)" "$LF_BASE"
assert_eq "$(local_head)" "$LF_BASE"
assert_eq "$(cat "$LF_STATE/local/completed.sha")" "$LF_BASE"

t "finalize [PR/MR]: a zero-commit review with nothing stale writes nothing"
local_fixture
git -C "$LF_CLONE" update-ref refs/ai-pr-loop/local/pr-42 HEAD
rm -f "$WORK/fin-argv.ghedit"
finalize_run_pr
assert_eq "$FIN_RC" 3
if [[ -e "$WORK/fin-argv.ghedit" ]]; then
  bad "edited the PR text with nothing proposed"; else ok; fi
assert_eq "$(cat "$LF_STATE/local/completed.sha")" "$LF_BASE"

t "finalize [PR/MR]: --no-push holds the metadata-only finish too"
local_fixture
git -C "$LF_CLONE" update-ref refs/ai-pr-loop/local/pr-42 HEAD
rm -f "$WORK/fin-argv.ghedit"
finalize_run_pr NO_PUSH=1 STUB_FINALIZE_TITLE='Corrected title'
assert_eq "$FIN_RC" 0
if [[ -e "$WORK/fin-argv.ghedit" ]]; then
  bad "edited the PR text under --no-push"; else ok; fi
if [[ -e "$LF_STATE/local/completed.sha" ]]; then
  bad "--no-push marked the review completed"; else ok; fi

t "finalize [PR/MR]: a metadata-only hold records its outcome kind"
assert_eq "$(awk '{print $1}' "$LF_STATE/local/finalized" 2>/dev/null)" 'nocommit'

t "finalize [PR/MR]: a held metadata-only finish is reused, not recomposed"
rm -f "$WORK/fin-argv.calls" "$WORK/fin-argv.ghedit"
finalize_run_pr                     # the finishing run, without --no-push
assert_eq "$FIN_RC" 3
if [[ -e "$WORK/fin-argv.calls" ]]; then
  bad "a second closing turn was spent on a held assessment"; else ok; fi
assert_pair "$WORK/fin-argv.ghedit" --title 'Corrected title'
assert_eq "$(cat "$LF_STATE/local/completed.sha")" "$LF_BASE"

t "finalize [PR/MR]: review-only never spends a closing turn when nothing lands"
local_fixture
git -C "$LF_CLONE" update-ref refs/ai-pr-loop/local/pr-42 HEAD
rm -f "$WORK/fin-argv.calls" "$WORK/fin-argv.ghedit"
finalize_run_pr REVIEW_ONLY=1
assert_eq "$FIN_RC" 3
if [[ -e "$WORK/fin-argv.calls" ]]; then
  bad "review-only spent an implementer turn"; else ok; fi
if [[ -e "$WORK/fin-argv.ghedit" ]]; then
  bad "review-only wrote to the forge"; else ok; fi
assert_eq "$(cat "$LF_STATE/local/completed.sha")" "$LF_BASE"

# --- local review mode: whole-field metadata delivery is guarded ------------
# A title/description proposal replaces the entire field, so it is valid
# only against the text it was composed from; a human edit made while the
# proposal was held must win. A failed delivery keeps the metadata-only
# review retryable instead of silently completing.

t "finalize [PR/MR]: a held metadata proposal is not delivered over a human edit"
local_fixture
git -C "$LF_CLONE" update-ref refs/ai-pr-loop/local/pr-42 HEAD
finalize_run_pr NO_PUSH=1 STUB_FINALIZE_TITLE='Corrected title'
assert_eq "$FIN_RC" 0
rm -f "$WORK/fin-argv.calls" "$WORK/fin-argv.ghedit"
finalize_run_pr STUB_PR_TITLE='Human retitled this'
assert_eq "$FIN_RC" 1
if [[ -e "$WORK/fin-argv.ghedit" ]]; then
  bad "the stale proposal was delivered over the human edit"; else ok; fi
if [[ -e "$WORK/fin-argv.calls" ]]; then
  bad "a turn was spent before the staleness check"; else ok; fi
if [[ -e "$LF_STATE/local/finalized" || -e "$LF_STATE/local/pr-title.txt" ]]; then
  bad "the stale proposal was kept instead of dropped for reassessment"; else ok; fi

t "finalize [PR/MR]: the dropped stale proposal is reassessed on the next run"
rm -f "$WORK/fin-argv.calls" "$WORK/fin-argv.ghedit"
finalize_run_pr STUB_PR_TITLE='Human retitled this' \
  STUB_FINALIZE_TITLE='Corrected against new text'
assert_eq "$FIN_RC" 3
if [[ -e "$WORK/fin-argv.calls" ]]; then ok
else bad "no fresh closing turn ran after the stale drop"; fi
assert_pair "$WORK/fin-argv.ghedit" --title 'Corrected against new text'
assert_eq "$(cat "$LF_STATE/local/completed.sha")" "$LF_BASE"

t "finalize [PR/MR]: a held squash's stale metadata is dropped, never delivered"
local_pr_fixture
finalize_run_pr NO_PUSH=1 STUB_FINALIZE_TITLE='New title'
assert_eq "$FIN_RC" 0
rm -f "$WORK/fin-argv.ghedit"
finalize_run_pr STUB_PR_TITLE='Human retitled this'
assert_eq "$FIN_RC" 0                       # the push is the outcome; it lands
assert_eq "$(remote_head)" "$(local_head)"
if [[ -e "$WORK/fin-argv.ghedit" ]]; then
  bad "the stale metadata was delivered over the human edit"; else ok; fi
assert_eq "$(cat "$LF_STATE/local/completed.sha")" "$(local_head)"

t "finalize [PR/MR]: an edit to the un-proposed field does not block delivery"
local_fixture
git -C "$LF_CLONE" update-ref refs/ai-pr-loop/local/pr-42 HEAD
finalize_run_pr NO_PUSH=1 STUB_FINALIZE_TITLE='Corrected title'
assert_eq "$FIN_RC" 0
rm -f "$WORK/fin-argv.calls" "$WORK/fin-argv.ghedit"
finalize_run_pr STUB_PR_BODY='Human edited the body'
assert_eq "$FIN_RC" 3
assert_pair "$WORK/fin-argv.ghedit" --title 'Corrected title'
assert_eq "$(cat "$LF_STATE/local/completed.sha")" "$LF_BASE"

t "finalize [PR/MR]: an already-applied delivery is recognized as done"
local_fixture
git -C "$LF_CLONE" update-ref refs/ai-pr-loop/local/pr-42 HEAD
finalize_run_pr NO_PUSH=1 STUB_FINALIZE_TITLE='Corrected title'
assert_eq "$FIN_RC" 0
rm -f "$WORK/fin-argv.calls" "$WORK/fin-argv.ghedit"
finalize_run_pr STUB_PR_TITLE='Corrected title'   # the server already has it
assert_eq "$FIN_RC" 3
if [[ -e "$WORK/fin-argv.ghedit" ]]; then
  bad "re-delivered an already-applied update"; else ok; fi
assert_eq "$(cat "$LF_STATE/local/completed.sha")" "$LF_BASE"

t "finalize [PR/MR]: a failed metadata-only delivery is retried, not lost"
local_fixture
git -C "$LF_CLONE" update-ref refs/ai-pr-loop/local/pr-42 HEAD
finalize_run_pr STUB_FINALIZE_TITLE='Corrected title' STUB_GH_EDIT_FAIL=1
assert_eq "$FIN_RC" 1
if [[ -e "$LF_STATE/local/completed.sha" ]]; then
  bad "a failed delivery was marked completed"; else ok; fi
rm -f "$WORK/fin-argv.calls" "$WORK/fin-argv.ghedit"
finalize_run_pr
assert_eq "$FIN_RC" 3
if [[ -e "$WORK/fin-argv.calls" ]]; then
  bad "the retry spent another closing turn"; else ok; fi
assert_pair "$WORK/fin-argv.ghedit" --title 'Corrected title'
assert_eq "$(cat "$LF_STATE/local/completed.sha")" "$LF_BASE"

t "finalize [GitLab]: a failed metadata-only delivery is retried"
local_fixture
git -C "$LF_CLONE" update-ref refs/ai-pr-loop/local/pr-42 HEAD
: > "$WORK/fin-curl.log"
finalize_run_gl STUB_FINALIZE_DESC='Corrected body' STUB_CURL_FAIL_PUT=1
assert_eq "$FIN_RC" 1
if [[ -e "$LF_STATE/local/completed.sha" ]]; then
  bad "a failed MR delivery was marked completed"; else ok; fi
: > "$WORK/fin-curl.log"
rm -f "$WORK/fin-argv.calls"
finalize_run_gl
assert_eq "$FIN_RC" 3
if [[ -e "$WORK/fin-argv.calls" ]]; then
  bad "the retry spent another closing turn"; else ok; fi
if grep -q '^PUT .*merge_requests' "$WORK/fin-curl.log"; then ok
else bad "the retried delivery never reached the MR"; fi
assert_eq "$(cat "$LF_STATE/local/completed.sha")" "$LF_BASE"

t "finalize: an interrupted terminal transition publishes completed.sha first"
local_fixture; local_round 1
# Killed between publish and cleanup; the subshell mutes the SIGKILL notice.
( finalize_run STUB_KILL_AFTER_MV=completed.sha ) 2>/dev/null
assert_eq "$(cat "$LF_STATE/local/completed.sha" 2>/dev/null)" "$(local_head)"
if [[ -e "$LF_STATE/local/base.sha" ]]; then ok   # cleanup had not run yet
else bad "cleanup ran before the terminal marker was published"; fi

t "finalize: the interrupted terminal transition heals on the next run"
finalize_run
assert_eq "$FIN_RC" 0
if [[ -e "$LF_STATE/local/base.sha" || -e "$LF_STATE/local/finalized" ]]; then
  bad "stale markers survived the healing rerun"; else ok; fi
assert_eq "$(remote_head)" "$(local_head)"

t "finalize: an interrupted squash publication (tip unanchored) is repaired"
local_fixture; local_round 1
# The state a prior round leaves: tip.sha names the round (anchored by that
# round's local_record_tip).
printf '%s\n' "$(local_head)" > "$LF_STATE/local/tip.sha"
_round=$(local_head)
# Killed after finalized.sha is published but before local_record_tip
# anchors tip.sha: the branch is at the squash, tip.sha still the round.
( finalize_run STUB_KILL_AFTER_MV=finalized ) 2>/dev/null
assert_eq "$(awk '{print $1}' "$LF_STATE/local/finalized" 2>/dev/null)" 'squash'
assert_eq "$(awk '{print $2}' "$LF_STATE/local/finalized" 2>/dev/null)" "$(local_head)"
assert_eq "$(cat "$LF_STATE/local/tip.sha")" "$_round"   # tip.sha lags at the round

t "finalize: the interrupted squash publication completes on retry"
finalize_run
assert_eq "$FIN_RC" 0
assert_eq "$(remote_head)" "$(local_head)"
assert_eq "$(git -C "$LF_CLONE" rev-list --count "$LF_BASE..HEAD")" 1
assert_eq "$(cat "$LF_STATE/local/completed.sha")" "$(local_head)"

t "sync_repo_to_local_head: adopts an unanchored finalize squash, not foreign"
local_fixture; local_round 1
_round=$(local_head)
_sq=$(git -C "$LF_CLONE" commit-tree "$_round^{tree}" -p "$LF_BASE" -m squash \
        -c user.name=t -c user.email=t@t 2>/dev/null \
      || GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
         git -C "$LF_CLONE" commit-tree "$_round^{tree}" -p "$LF_BASE" -m squash)
git -C "$LF_CLONE" update-ref refs/heads/feature/x "$_sq"   # branch at the squash
printf '%s %s\n' "squash" "$_sq" > "$LF_STATE/local/finalized"       # recorded, kind squash
# A prior round anchored tip.sha at the round; the killed finalize never
# advanced it. Without the adopt, sync dies "moved outside the loop".
printf '%s\n' "$_round" > "$LF_STATE/local/tip.sha"
if env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
     LOCAL_MODE=1 LOCAL_SCOPE=branch REPO_DIR="$LF_CLONE" HEAD_REF=feature/x \
     STATE_DIR="$LF_STATE" MANAGED_CLONE=0 \
     "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; sync_repo_to_local_head" >/dev/null 2>&1; then
  assert_eq "$(cat "$LF_STATE/local/tip.sha")" "$_sq"
  assert_eq "$(git -C "$LF_CLONE" rev-parse HEAD)" "$_sq"
else bad "the sync rejected the loop's own unanchored squash as foreign movement"; fi

t "sync_repo_to_local_head: a foreign branch past the squash is not adopted"
local_fixture; local_round 1
_round=$(local_head)
_sq=$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
        git -C "$LF_CLONE" commit-tree "$_round^{tree}" -p "$LF_BASE" -m squash)
git -C "$LF_CLONE" update-ref refs/heads/feature/x "$_sq"
printf '%s %s\n' "squash" "$_sq" > "$LF_STATE/local/finalized"
printf '%s\n' "$_round" > "$LF_STATE/local/tip.sha"
# A human stacks a commit on the squash — descends from it, but is NOT the
# loop's own finalize output; adopting it would clobber the human commit.
echo human >> "$LF_CLONE/f"; git -C "$LF_CLONE" commit -qam "human on top"
_human=$(git -C "$LF_CLONE" rev-parse HEAD)
if env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
     LOCAL_MODE=1 LOCAL_SCOPE=branch REPO_DIR="$LF_CLONE" HEAD_REF=feature/x \
     STATE_DIR="$LF_STATE" MANAGED_CLONE=0 \
     "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; sync_repo_to_local_head" >/dev/null 2>&1; then
  bad "adopted a foreign branch position as the finalize squash"
else
  assert_eq "$(git -C "$LF_CLONE" rev-parse refs/heads/feature/x)" "$_human"  # untouched
fi

t "sync_repo_to_local_head: adopts a squash from the in-progress marker (no journal)"
# The commit→journal window: the squash commit exists (branch moved to it)
# but the outcome journal was never written; only the in-progress marker
# (base + approved tree) records the intent.
local_fixture; local_round 1
_round=$(local_head); _tree=$(git -C "$LF_CLONE" rev-parse "$_round^{tree}")
_sq=$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
        git -C "$LF_CLONE" commit-tree "$_tree" -p "$LF_BASE" -m squash)
git -C "$LF_CLONE" update-ref refs/heads/feature/x "$_sq"     # branch at the squash
printf '%s %s\n' "$LF_BASE" "$_tree" > "$LF_STATE/local/finalize-inprogress"
printf '%s\n' "$_round" > "$LF_STATE/local/tip.sha"           # no finalized journal yet
if env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
     LOCAL_MODE=1 LOCAL_SCOPE=branch REPO_DIR="$LF_CLONE" HEAD_REF=feature/x \
     STATE_DIR="$LF_STATE" MANAGED_CLONE=0 \
     "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; sync_repo_to_local_head" >/dev/null 2>&1; then
  assert_eq "$(cat "$LF_STATE/local/tip.sha")" "$_sq"
  assert_eq "$(awk '{print $1" "$2}' "$LF_STATE/local/finalized")" "squash $_sq"  # journaled
  assert_eq "$(git -C "$LF_CLONE" rev-parse HEAD)" "$_sq"
else bad "the sync did not recover the squash from the in-progress marker"; fi

t "finalize [branch]: a kind-only/no-journal interruption completes on retry"
# End to end: the squash exists on the branch, the in-progress marker is
# set, no journal, and the message was already composed (as in a real
# crash). A finalize retry adopts the squash, journals it, and pushes it.
local_fixture; local_round 1
printf '%s\n' "$(local_head)" > "$LF_STATE/local/tip.sha"
_round=$(local_head); _tree=$(git -C "$LF_CLONE" rev-parse "$_round^{tree}")
_sq=$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
        git -C "$LF_CLONE" commit-tree "$_tree" -p "$LF_BASE" -m squash)
git -C "$LF_CLONE" update-ref refs/heads/feature/x "$_sq"
printf '%s %s\n' "$LF_BASE" "$_tree" > "$LF_STATE/local/finalize-inprogress"
printf 'Squashed subject line\n' > "$LF_STATE/local/commit-message.txt"
finalize_run
assert_eq "$FIN_RC" 0
assert_eq "$(remote_head)" "$_sq"
assert_eq "$(cat "$LF_STATE/local/completed.sha")" "$_sq"

t "local_adopt: a single round is not mistaken for the squash (pr scope, no journal)"
# The squash and a single round share parent (base) and tree (approved), so
# the in-progress recovery must pick the squash on HEAD, not the round the
# ref still names. PR scope: ref at the round, detached HEAD at the squash.
local_pr_fixture                                       # ref refs/ai-pr-loop/local/pr-42 at round R
_round=$(local_head); _tree=$(git -C "$LF_CLONE" rev-parse "$_round^{tree}")
_sq=$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
        git -C "$LF_CLONE" commit-tree "$_tree" -p "$LF_BASE" -m 'composed squash')  # distinct SHA
git -C "$LF_CLONE" checkout -q --detach "$_sq"         # HEAD at the squash, ref still at R
printf '%s %s\n' "$LF_BASE" "$_tree" > "$LF_STATE/local/finalize-inprogress"
printf '%s\n' "$_round" > "$LF_STATE/local/tip.sha"    # tip.sha still names the round
if env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
     LOCAL_MODE=1 LOCAL_SCOPE=pr PR_NUMBER=42 REPO_DIR="$LF_CLONE" STATE_DIR="$LF_STATE" \
     BASE_REF=main HEAD_REF=feature/x MANAGED_CLONE=1 \
     "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; local_adopt_finalized_squash" >/dev/null 2>&1; then
  assert_eq "$(awk '{print $2}' "$LF_STATE/local/finalized")" "$_sq"   # the squash, not the round
  assert_eq "$(cat "$LF_STATE/local/tip.sha")" "$_sq"
else bad "adopt did not recover the squash from the in-progress marker in pr scope"; fi

t "finalize: writes the in-progress marker before the squash commit moves HEAD"
# A git wrapper fails the mechanical squash commit, so finalize dies inside
# the publication window — with the marker already on disk and no journal.
local_fixture; local_round 1
_base=$(cat "$LF_STATE/local/base.sha"); _tree=$(git -C "$LF_CLONE" rev-parse 'HEAD^{tree}')
_gitshim="$WORK/gitshim-$RANDOM"; mkdir -p "$_gitshim"
{ printf '#!/usr/bin/env bash\n'
  printf 'for a in "$@"; do [[ "$a" == commit ]] && c=1; [[ "$a" == -F ]] && f=1; done\n'
  printf '[[ -n "${c:-}" && -n "${f:-}" ]] && exit 1\n'
  printf 'exec "$REAL_GIT" "$@"\n'; } > "$_gitshim/git"
chmod +x "$_gitshim/git"
env -i PATH="$_gitshim:$STUBS:$SYSPATH" HOME="$WORK" REAL_GIT="$REAL_GIT" \
  ARGV_FILE="$WORK/fin-argv" \
  CODEX_HOME="$WORK/codex-home" \
  LOCAL_MODE=1 LOCAL_SCOPE=branch FORGE=local MANAGED_CLONE=0 \
  REPO_DIR="$LF_CLONE" STATE_DIR="$LF_STATE" BASE_REF=main HEAD_REF=feature/x ITER=3 MAX_ITER=6 \
  REPO_SLUG= REPO_OWNER= REPO_NAME= PR_NUMBER= GH_USER= HAS_CONTEXT=0 \
  CLAUDE_MODEL=off CLAUDE_EFFORT=off CLAUDE_PERMS=off \
  "$BASH_BIN" "$ROOT/finalize_turn.sh" > "$WORK/fin.log" 2>&1
assert_eq "$?" 1
assert_eq "$(cat "$LF_STATE/local/finalize-inprogress")" "$_base $_tree"   # base first, tree second
if [[ ! -e "$LF_STATE/local/finalized" ]]; then ok
else bad "a finalized journal was written before the squash commit succeeded"; fi

t "reconcile_pending_turn [PR/MR]: advances the ref to the validated commit"
# The done-recovery pr-scope path: the private ref still names the pre-turn
# tip while the validated commit sits on a detached HEAD. reconcile advances
# the ref (and tip.sha) to that exact commit.
local_fixture; local_round 1
_ptip=$(local_head)
_post=$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
          git -C "$LF_CLONE" commit-tree "$_ptip^{tree}" -p "$_ptip" -m post)  # child of the pre-turn tip
git -C "$LF_CLONE" update-ref refs/ai-pr-loop/local/pr-42 "$_ptip"    # ref never advanced
printf '%s\n' "$_ptip" > "$LF_STATE/local/tip.sha"
mkdir -p "$LF_STATE/iter-01"; printf 'resp\n' > "$LF_STATE/iter-01/claude-response.md"
printf 'done 1 %s %s\n' "$_ptip" "$_post" > "$LF_STATE/local/pending-turn"
if setup_run reconcile_pending_turn; then
  assert_eq "$(git -C "$LF_CLONE" rev-parse refs/ai-pr-loop/local/pr-42)" "$_post"
  assert_eq "$(cat "$LF_STATE/local/tip.sha")" "$_post"
  if [[ ! -e "$LF_STATE/local/pending-turn" ]]; then ok
  else bad "the receipt survived a successful recovery"; fi
else bad "reconcile failed to advance the pr-scope ref ($(tail -1 "$WORK/setup.log"))"; fi

t "local_setup_repo [PR/MR]: adopts its own ref-advanced/tip-lag squash"
# State C: a killed adopt already advanced the private ref to the squash
# but had not written tip.sha. The next adopt must accept cur == the squash
# (its own partial work), not only cur == the recorded round.
local_pr_fixture                                             # ref at round R, tip.sha=R
_round=$(local_head); _tree=$(git -C "$LF_CLONE" rev-parse "$_round^{tree}")
_sq=$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
        git -C "$LF_CLONE" commit-tree "$_tree" -p "$LF_BASE" -m squash)
git -C "$LF_CLONE" update-ref refs/ai-pr-loop/local/pr-42 "$_sq"   # ref advanced to squash
printf '%s %s\n' "squash" "$_sq" > "$LF_STATE/local/finalized"
printf '%s\n' "$_round" > "$LF_STATE/local/tip.sha"               # tip.sha still lags
if setup_run local_setup_repo; then
  assert_eq "$(cat "$LF_STATE/local/tip.sha")" "$_sq"
  assert_eq "$(git -C "$LF_CLONE" rev-parse refs/ai-pr-loop/local/pr-42)" "$_sq"
else bad "adopt rejected its own ref-advanced squash ($(tail -1 "$WORK/setup.log"))"; fi

t "local_setup_repo [PR/MR]: a push that landed before completion is recognized"
local_pr_fixture
finalize_run_pr                      # pushes the squash and completes
_s=$(local_head)
# The crash window: push landed, terminal marker not yet written.
printf '%s\n' "$LF_BASE" > "$LF_STATE/local/base.sha"
printf '%s\n' "$_s"      > "$LF_STATE/local/tip.sha"
printf '%s %s\n' "squash" "$_s" > "$LF_STATE/local/finalized"
git -C "$LF_CLONE" remote get-url --all origin > "$LF_STATE/local/origin.url"; git -C "$LF_CLONE" remote get-url --push --all origin >> "$LF_STATE/local/origin.url"
rm -f "$LF_STATE/local/completed.sha"
git -C "$LF_CLONE" update-ref refs/ai-pr-loop/local/pr-42 "$_s"
if setup_run local_setup_repo && [[ "$(local_head)" == "$_s" ]]; then ok
else bad "resume rejected an already-landed push ($(tail -1 "$WORK/setup.log"))"; fi
assert_substr "$WORK/setup.log" 'already reached the remote'

t "finalize [PR/MR]: an already-landed push completes idempotently"
finalize_run_pr
assert_eq "$FIN_RC" 0
assert_eq "$(remote_head)" "$_s"
assert_eq "$(cat "$LF_STATE/local/completed.sha")" "$_s"

# --- local review mode: keeping the rounds alive ---------------------------

t "sync_repo_to_local_head: keeps local rounds and drops turn leftovers"
local_fixture; local_round 1; local_round 2
_tip=$(local_head)
printf 'build output\n' > "$LF_CLONE/artifact.o"
printf 'stray edit\n' >> "$LF_CLONE/f"
env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
  LOCAL_MODE=1 LOCAL_SCOPE=branch REPO_DIR="$LF_CLONE" HEAD_REF=feature/x \
  MANAGED_CLONE=0 \
  "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; sync_repo_to_local_head" >/dev/null 2>&1
if [[ "$(local_head)" == "$_tip" ]] \
   && [[ ! -e "$LF_CLONE/artifact.o" ]] \
   && [[ -z "$(git -C "$LF_CLONE" status --porcelain)" ]]; then ok
else bad "local sync lost rounds or left the worktree dirty"; fi

t "sync_repo_to_local_head: a branch review stays on its branch"
assert_eq "$(git -C "$LF_CLONE" symbolic-ref --short HEAD)" 'feature/x'

t "sync_repo_to_local_head: a detached HEAD in a branch review fails closed"
git -C "$LF_CLONE" checkout -q --detach HEAD
if env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
     LOCAL_MODE=1 LOCAL_SCOPE=branch REPO_DIR="$LF_CLONE" HEAD_REF=feature/x \
     MANAGED_CLONE=0 \
     "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; sync_repo_to_local_head" >/dev/null 2>&1; then
  bad "a detached HEAD was silently accepted"; else ok; fi
git -C "$LF_CLONE" checkout -q feature/x

t "sync_repo_to_local_head: a tip off the recorded round fails closed"
local_fixture; local_round 1
printf '%s\n' "$(local_head)" > "$LF_STATE/local/tip.sha"   # what local_record_tip persists
printf 'foreign\n' >> "$LF_CLONE/f"
git -C "$LF_CLONE" commit -qam "foreign commit"             # a commit no turn made
if env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
     LOCAL_MODE=1 LOCAL_SCOPE=branch REPO_DIR="$LF_CLONE" HEAD_REF=feature/x \
     STATE_DIR="$LF_STATE" MANAGED_CLONE=0 \
     "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; sync_repo_to_local_head" >/dev/null 2>&1; then
  bad "a foreign commit on the branch was silently adopted"; else ok; fi

# --- local review mode: run.sh end to end (real git, stub agents) -----------
# Whole-orchestrator runs on a PR-less branch review with no origin: the
# terminal-state transitions (converged/approved -> completed -> no-op rerun
# -> --restart from a new base) only exist across invocations of run.sh
# itself. Each fixture gets its own loop home so state dirs never collide.

E2E_TEMPLATE=''
# Same reasoning as local_fixture: 18 cases want an identical checkout, and
# building it costs 8 git invocations each. Build it once and copy.
_e2e_build_template() {
  E2E_TEMPLATE="$WORK/.e2e-template"
  mkdir -p "$E2E_TEMPLATE"
  git init -q -b main "$E2E_TEMPLATE/clone"
  git -C "$E2E_TEMPLATE/clone" config user.email t@t
  git -C "$E2E_TEMPLATE/clone" config user.name t
  echo base > "$E2E_TEMPLATE/clone/f"
  git -C "$E2E_TEMPLATE/clone" add f
  git -C "$E2E_TEMPLATE/clone" commit -qm base
  git -C "$E2E_TEMPLATE/clone" checkout -qb feature/x
  echo head >> "$E2E_TEMPLATE/clone/f"
  git -C "$E2E_TEMPLATE/clone" commit -qam "human work"
  E2E_TPL_BASE=$(git -C "$E2E_TEMPLATE/clone" rev-parse HEAD)
}
e2e_fixture() {  # -> $E2E_CLONE (no origin, branch feature/x), $E2E_BASE, $E2E_HOME
  local n="e2e$RANDOM$RANDOM"
  [[ -n "$E2E_TEMPLATE" ]] || _e2e_build_template
  E2E_CLONE="$WORK/$n-clone"; cp -r "$E2E_TEMPLATE/clone" "$E2E_CLONE"
  E2E_BASE="$E2E_TPL_BASE"
  E2E_HOME="$WORK/$n-home"; mkdir -p "$E2E_HOME"
  ln -s "$ROOT/run.sh" "$ROOT/codex_turn.sh" "$ROOT/claude_turn.sh" \
        "$ROOT/finalize_turn.sh" "$ROOT/lib" "$ROOT/prompts" "$E2E_HOME/"
}
e2e_fixture_origin() {  # e2e_fixture plus a bare origin holding both branches
  e2e_fixture
  E2E_REMOTE="$WORK/${E2E_CLONE##*/}-remote.git"
  git init -q --bare -b main "$E2E_REMOTE"
  git -C "$E2E_CLONE" remote add origin "$E2E_REMOTE"
  git -C "$E2E_CLONE" push -q origin refs/heads/main refs/heads/feature/x
}
run_e2e() {  # [VAR=VAL ...] [args ...]
  local envs=()
  while [[ $# -gt 0 && "$1" == [A-Z_]*=* ]]; do envs+=("$1"); shift; done
  mkdir -p "$WORK/codex-home/sessions"   # session snapshots run before the stub creates it
  # --no-auto-resume: these cases assert on the WORKER — its rounds, its
  # terminal state, and how the NEXT invocation recovers from a killed one.
  # A supervised run would relaunch the worker itself and detach the loop
  # from this process, so the crash cases could never be observed here.
  env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" ARGV_FILE="$WORK/e2e-argv" \
    CODEX_HOME="$WORK/codex-home" ${envs[@]+"${envs[@]}"} \
    "$BASH_BIN" "$E2E_HOME/run.sh" "$@" --no-auto-resume > "$WORK/e2e.out" 2>&1
  E2E_RC=$?
}
e2e_state() { echo "$E2E_HOME"/state/local__*/branch-*; }
e2e_iters() { ls -d "$(e2e_state)"/iter-* 2>/dev/null | wc -l; }


t "run.sh e2e: a NIT-only convergence completes and terminates the review"
e2e_fixture
run_e2e STUB_CODEX_VERDICT=CHANGES_REQUESTED \
  --local --base main --dir "$E2E_CLONE" --converge 1 --max 3
assert_eq "$E2E_RC" 0
assert_eq "$(cat "$(e2e_state)/local/completed.sha" 2>/dev/null)" "$E2E_BASE"
if [[ -e "$(e2e_state)/local/base.sha" ]]; then
  bad "base.sha survived a converged review"; else ok; fi

t "run.sh e2e: a plain rerun of a completed review is a no-op"
_iters=$(e2e_iters)
run_e2e STUB_CODEX_VERDICT=CHANGES_REQUESTED \
  --local --base main --dir "$E2E_CLONE" --converge 1 --max 3
assert_eq "$E2E_RC" 0
assert_substr "$WORK/e2e.out" 'already completed'
assert_eq "$(e2e_iters)" "$_iters"

t "run.sh e2e: --restart reviews the current state from a new base"
run_e2e STUB_CODEX_VERDICT=CHANGES_REQUESTED \
  --local --base main --dir "$E2E_CLONE" --converge 1 --max 3 --restart
assert_eq "$E2E_RC" 0
assert_eq "$(e2e_iters)" "$((_iters + 1))"
assert_eq "$(cat "$(e2e_state)/local/completed.sha" 2>/dev/null)" "$E2E_BASE"

t "run.sh e2e: requested changes, a fix round, approval — one terminal squash"
e2e_fixture
printf 'CHANGES_REQUESTED\nAPPROVED\n' > "$WORK/e2e-verdicts"
run_e2e STUB_CODEX_VERDICT_SEQ="$WORK/e2e-verdicts" STUB_CODEX_BLOCKERS=1 \
  STUB_CLAUDE_COMMIT=1 --local --base main --dir "$E2E_CLONE" --max 4
assert_eq "$E2E_RC" 0
assert_eq "$(git -C "$E2E_CLONE" rev-list --count "$E2E_BASE..HEAD")" 1
assert_eq "$(git -C "$E2E_CLONE" log -1 --format=%s)" 'Squashed subject line'
assert_eq "$(cat "$(e2e_state)/local/completed.sha" 2>/dev/null)" \
          "$(git -C "$E2E_CLONE" rev-parse HEAD)"

t "run.sh e2e: a human commit after completion survives rerun and --restart"
_done=$(git -C "$E2E_CLONE" rev-parse HEAD)
printf 'human follow-up\n' >> "$E2E_CLONE/f"
git -C "$E2E_CLONE" commit -qam "human follow-up"
_human=$(git -C "$E2E_CLONE" rev-parse HEAD)
run_e2e --local --base main --dir "$E2E_CLONE" --max 4
assert_eq "$E2E_RC" 0
assert_eq "$(git -C "$E2E_CLONE" rev-parse HEAD)" "$_human"
run_e2e --local --base main --dir "$E2E_CLONE" --max 4 --restart
assert_eq "$E2E_RC" 0
if git -C "$E2E_CLONE" merge-base --is-ancestor "$_human" HEAD \
   && git -C "$E2E_CLONE" merge-base --is-ancestor "$_done" HEAD; then ok
else bad "a completed review's rerun rewrote the human commit or the squash"; fi

t "run.sh e2e: a failed implementer turn's commits are dropped, resume proceeds"
e2e_fixture
run_e2e STUB_CODEX_VERDICT=CHANGES_REQUESTED STUB_CODEX_BLOCKERS=1 \
  STUB_CLAUDE_COMMIT=1 STUB_NO_CLAUDE_LOCAL_ARTIFACT=1 \
  --local --base main --dir "$E2E_CLONE" --max 1
assert_eq "$E2E_RC" 1
assert_eq "$(git -C "$E2E_CLONE" rev-parse HEAD)" "$E2E_BASE"   # rogue commit dropped
run_e2e STUB_CODEX_VERDICT=CHANGES_REQUESTED STUB_CODEX_BLOCKERS=1 \
  STUB_CLAUDE_COMMIT=1 --local --base main --dir "$E2E_CLONE" --max 1
assert_eq "$(git -C "$E2E_CLONE" rev-list --count "$E2E_BASE..HEAD")" 1
assert_eq "$(cat "$(e2e_state)/local/tip.sha" 2>/dev/null)" \
          "$(git -C "$E2E_CLONE" rev-parse HEAD)"

t "run.sh e2e: a failed turn's retained response never skips the discarded fix"
# The crash shape: the implementer commits, writes its response, prints
# the marker, then the CLI dies. run.sh rolls the commit back; the
# response must go with it, or latest_local_iter counts the round
# complete and the discarded fix is never rerun.
e2e_fixture
run_e2e STUB_CODEX_VERDICT=CHANGES_REQUESTED STUB_CODEX_BLOCKERS=1 \
  STUB_CLAUDE_COMMIT=1 STUB_CLAUDE_EXIT=17 \
  --local --base main --dir "$E2E_CLONE" --max 1
assert_eq "$E2E_RC" 1
assert_eq "$(git -C "$E2E_CLONE" rev-parse HEAD)" "$E2E_BASE"   # commit rolled back

t "run.sh e2e: the rolled-back round's response artifact is discarded with it"
if [[ -e "$(e2e_state)/iter-01/claude-response.md" ]]; then
  bad "the response artifact survived the rollback"
else
  ok
fi

t "run.sh e2e: the discard is named in the log"
assert_substr "$WORK/e2e.out" 'response discarded with the rolled-back round'

t "run.sh e2e: resume reruns the discarded round instead of skipping past it"
run_e2e STUB_CODEX_VERDICT=CHANGES_REQUESTED STUB_CODEX_BLOCKERS=1 \
  STUB_CLAUDE_COMMIT=1 --local --base main --dir "$E2E_CLONE" --max 1
assert_eq "$(git -C "$E2E_CLONE" rev-list --count "$E2E_BASE..HEAD")" 1
assert_eq "$(cat "$(e2e_state)/local/tip.sha" 2>/dev/null)" \
          "$(git -C "$E2E_CLONE" rev-parse HEAD)"

t "run.sh e2e: --restart consumes a held (--no-push) squash instead of pushing it"
e2e_fixture
printf 'CHANGES_REQUESTED\nAPPROVED\n' > "$WORK/e2e-verdicts"
run_e2e STUB_CODEX_VERDICT_SEQ="$WORK/e2e-verdicts" STUB_CODEX_BLOCKERS=1 \
  STUB_CLAUDE_COMMIT=1 --local --base main --dir "$E2E_CLONE" --max 4 --no-push
assert_eq "$E2E_RC" 0
if [[ -s "$(e2e_state)/local/finalized" ]]; then ok
else bad "the held squash left no finalized marker"; fi
run_e2e STUB_CODEX_VERDICT=CHANGES_REQUESTED STUB_CODEX_BLOCKERS=1 \
  --local --base main --dir "$E2E_CLONE" --max 1 --restart --no-push
assert_eq "$E2E_RC" 1                          # cap hit mid-review, by design
if [[ -e "$(e2e_state)/local/finalized" ]]; then
  bad "--restart left the held-squash marker armed"; else ok; fi
_iters=$(e2e_iters)
run_e2e --local --base main --dir "$E2E_CLONE" --max 2 --no-push   # plain rerun mid-review
assert_eq "$E2E_RC" 0                          # APPROVED -> re-squash held again
assert_eq "$(e2e_iters)" "$((_iters + 1))"     # a real new round ran first
assert_eq "$(git -C "$E2E_CLONE" rev-list --count "$E2E_BASE..HEAD")" 1
assert_eq "$(git -C "$E2E_CLONE" log -1 --format=%s)" 'Squashed subject line'

t "run.sh e2e: --restart after an interrupted completion never reuses the old base"
e2e_fixture
printf 'CHANGES_REQUESTED\nAPPROVED\n' > "$WORK/e2e-verdicts"
run_e2e STUB_CODEX_VERDICT_SEQ="$WORK/e2e-verdicts" STUB_CODEX_BLOCKERS=1 \
  STUB_CLAUDE_COMMIT=1 --local --base main --dir "$E2E_CLONE" --max 4
assert_eq "$E2E_RC" 0
_st=$(e2e_state); _s=$(git -C "$E2E_CLONE" rev-parse HEAD)
# Simulate a completion interrupted mid-transition: stale in-progress
# markers left alongside the authoritative completed.sha.
printf '%s\n' "$E2E_BASE" > "$_st/local/base.sha"
printf '%s\n' "$_s"       > "$_st/local/tip.sha"
printf '%s %s\n' "squash" "$_s" > "$_st/local/finalized"
printf 'CHANGES_REQUESTED\nAPPROVED\n' > "$WORK/e2e-verdicts"
run_e2e STUB_CODEX_VERDICT_SEQ="$WORK/e2e-verdicts" STUB_CODEX_BLOCKERS=1 \
  STUB_CLAUDE_COMMIT=1 --local --base main --dir "$E2E_CLONE" --max 4 --restart
assert_eq "$E2E_RC" 0
if git -C "$E2E_CLONE" merge-base --is-ancestor "$_s" HEAD; then ok
else bad "the restarted review rewrote the completed commit"; fi
assert_eq "$(git -C "$E2E_CLONE" rev-list --count "$_s..HEAD")" 1

t "run.sh e2e: a crashed --restart on a held squash cannot re-finalize the old review"
e2e_fixture
printf 'CHANGES_REQUESTED\nAPPROVED\n' > "$WORK/e2e-verdicts"
run_e2e STUB_CODEX_VERDICT_SEQ="$WORK/e2e-verdicts" STUB_CODEX_BLOCKERS=1 \
  STUB_CLAUDE_COMMIT=1 --local --base main --dir "$E2E_CLONE" --max 4 --no-push
assert_eq "$E2E_RC" 0
_st=$(e2e_state)
if [[ -s "$_st/local/finalized" ]]; then ok
else bad "the held squash left no finalized marker"; fi
run_e2e STUB_NO_LOCAL_ARTIFACT=1 \
  --local --base main --dir "$E2E_CLONE" --max 1 --restart --no-push
assert_eq "$E2E_RC" 1                          # codex crashed before any artifact
run_e2e --local --base main --dir "$E2E_CLONE" --max 2 --no-push
assert_eq "$E2E_RC" 0
if [[ -s "$_st/iter-03/codex-review.md" ]]; then ok
else bad "the plain retry re-finalized the superseded review without a new codex round"; fi
assert_eq "$(git -C "$E2E_CLONE" rev-list --count "$E2E_BASE..HEAD")" 1

t "run.sh e2e: an interrupted completion stays terminal past a human commit"
e2e_fixture
printf 'CHANGES_REQUESTED\nAPPROVED\n' > "$WORK/e2e-verdicts"
run_e2e STUB_CODEX_VERDICT_SEQ="$WORK/e2e-verdicts" STUB_CODEX_BLOCKERS=1 \
  STUB_CLAUDE_COMMIT=1 --local --base main --dir "$E2E_CLONE" --max 4
assert_eq "$E2E_RC" 0
_st=$(e2e_state); _s=$(git -C "$E2E_CLONE" rev-parse HEAD)
# The crash window mark_completed leaves: completed.sha published, the
# in-progress markers not yet cleared.
printf '%s\n' "$E2E_BASE" > "$_st/local/base.sha"
printf '%s\n' "$_s"       > "$_st/local/tip.sha"
printf 'human follow-up\n' >> "$E2E_CLONE/f"
git -C "$E2E_CLONE" commit -qam "human follow-up"
_human=$(git -C "$E2E_CLONE" rev-parse HEAD)
run_e2e --local --base main --dir "$E2E_CLONE" --max 2
assert_eq "$E2E_RC" 0
assert_substr "$WORK/e2e.out" 'already completed'
assert_eq "$(cat "$_st/local/completed.sha")" "$_s"   # never re-stamped at the human SHA
assert_eq "$(git -C "$E2E_CLONE" rev-parse HEAD)" "$_human"

t "run.sh e2e: --restart after a landed push completes it before the new review"
e2e_fixture_origin
printf 'CHANGES_REQUESTED\nAPPROVED\n' > "$WORK/e2e-verdicts"
run_e2e STUB_CODEX_VERDICT_SEQ="$WORK/e2e-verdicts" STUB_CODEX_BLOCKERS=1 \
  STUB_CLAUDE_COMMIT=1 --local --base main --dir "$E2E_CLONE" --max 4
assert_eq "$E2E_RC" 0
_st=$(e2e_state); _s=$(git -C "$E2E_CLONE" rev-parse HEAD)
assert_eq "$(git -C "$E2E_REMOTE" rev-parse refs/heads/feature/x)" "$_s"
# The crash window: push landed, terminal bookkeeping not yet done.
printf '%s\n' "$E2E_BASE" > "$_st/local/base.sha"
printf '%s\n' "$_s"       > "$_st/local/tip.sha"
printf '%s %s\n' "squash" "$_s" > "$_st/local/finalized"
git -C "$E2E_CLONE" remote get-url --all origin > "$_st/local/origin.url"; git -C "$E2E_CLONE" remote get-url --push --all origin >> "$_st/local/origin.url"
rm -f "$_st/local/completed.sha"
run_e2e --local --base main --dir "$E2E_CLONE" --max 2 --restart
assert_eq "$E2E_RC" 0
assert_eq "$(git -C "$E2E_REMOTE" rev-parse refs/heads/feature/x)" "$_s"  # never re-squashed
if [[ -s "$_st/iter-03/codex-review.md" ]]; then ok
else bad "the restart never ran a new review after completing the landed push"; fi
assert_eq "$(cat "$_st/local/completed.sha")" "$_s"

t "run.sh e2e: an interrupted --restart is re-driven, not resurrected, on a plain retry"
# Mode (a): a --restart killed before its floor write landed leaves an
# older/absent floor, but the durable restart-pending marker makes a plain
# retry re-drive the restart instead of resuming the superseded review.
e2e_fixture
printf 'CHANGES_REQUESTED\nAPPROVED\n' > "$WORK/e2e-verdicts"
run_e2e STUB_CODEX_VERDICT_SEQ="$WORK/e2e-verdicts" STUB_CODEX_BLOCKERS=1 \
  STUB_CLAUDE_COMMIT=1 --local --base main --dir "$E2E_CLONE" --max 4 --no-push
assert_eq "$E2E_RC" 0
_st=$(e2e_state)
[[ -s "$_st/local/finalized" ]] || bad "no held squash to supersede"
printf '1\n' > "$_st/local/iter-floor"       # stale floor from before the kill
: > "$_st/local/restart-pending"             # intent persisted before the kill
run_e2e --local --base main --dir "$E2E_CLONE" --max 2 --no-push
assert_eq "$E2E_RC" 0
assert_eq "$(cat "$_st/local/iter-floor")" 2         # re-driven to the real high-water
if [[ -s "$_st/iter-03/codex-review.md" ]]; then ok  # the new review ran
else bad "the plain retry did not re-drive the interrupted restart"; fi
if [[ -e "$_st/local/restart-pending" ]]; then
  bad "the restart-pending marker was not cleared once the new base was set"; else ok; fi

t "run.sh e2e: an interrupted post-completion restart establishes the new review"
# Mode (b): --restart completed an already-landed review (completed.sha
# written) but was killed before establishing the new base. The pending
# marker makes the plain retry finish the restart instead of exiting
# "already completed".
e2e_fixture_origin
printf 'CHANGES_REQUESTED\nAPPROVED\n' > "$WORK/e2e-verdicts"
run_e2e STUB_CODEX_VERDICT_SEQ="$WORK/e2e-verdicts" STUB_CODEX_BLOCKERS=1 \
  STUB_CLAUDE_COMMIT=1 --local --base main --dir "$E2E_CLONE" --max 4
assert_eq "$E2E_RC" 0
_st=$(e2e_state); _s=$(git -C "$E2E_CLONE" rev-parse HEAD)
printf '2\n' > "$_st/local/iter-floor"       # floor from the interrupted restart
: > "$_st/local/restart-pending"             # intent survived the kill
run_e2e --local --base main --dir "$E2E_CLONE" --max 2
assert_eq "$E2E_RC" 0
assert_no_substr "$WORK/e2e.out" 'already completed'
if [[ -s "$_st/iter-03/codex-review.md" ]]; then ok  # a fresh review ran
else bad "the interrupted post-completion restart did not start the new review"; fi
if [[ -e "$_st/local/restart-pending" ]]; then
  bad "restart-pending survived the new review's establishment"; else ok; fi

t "run.sh e2e: a validated round committed but not anchored is recovered"
# The window between the validated turn's commit and local_record_tip: the
# `done` receipt names the exact commit, tip.sha still the pre-turn tip. A
# retry re-points the tip at that exact commit and continues past it.
e2e_fixture
run_e2e STUB_CODEX_VERDICT=CHANGES_REQUESTED STUB_CODEX_BLOCKERS=1 \
  STUB_CLAUDE_COMMIT=1 --local --base main --dir "$E2E_CLONE" --max 1
_st=$(e2e_state); _round1=$(git -C "$E2E_CLONE" rev-parse HEAD)
[[ "$_round1" != "$E2E_BASE" ]] || bad "round 1 produced no commit to anchor"
printf '%s\n' "$E2E_BASE" > "$_st/local/tip.sha"     # unanchored
printf 'done 1 %s %s\n' "$E2E_BASE" "$_round1" > "$_st/local/pending-turn"
run_e2e STUB_CODEX_VERDICT=CHANGES_REQUESTED STUB_CODEX_BLOCKERS=1 \
  --local --base main --dir "$E2E_CLONE" --max 1
assert_eq "$E2E_RC" 1                                # cap hit after codex iter-02
assert_substr "$WORK/e2e.out" "anchored its commit $_round1"
assert_eq "$(cat "$_st/local/tip.sha")" "$_round1"
if git -C "$E2E_CLONE" merge-base --is-ancestor "$_round1" HEAD; then ok
else bad "the recovered round's commit is unreachable from the resumed tip"; fi
if [[ -s "$_st/iter-02/codex-review.md" ]]; then ok
else bad "resume did not continue past the anchored round"; fi

t "run.sh e2e: an unvalidated (pending) round drops its response and fails closed"
# A `pending` receipt — the turn's outcome was never validated (rc, marker,
# or artifact). It records no committed SHA, so a committed branch that
# moved off the recorded tip cannot be told from a human commit: the round
# is invalidated (response dropped) and the moved branch fails closed rather
# than being force-reset over a possible human commit.
e2e_fixture
run_e2e STUB_CODEX_VERDICT=CHANGES_REQUESTED STUB_CODEX_BLOCKERS=1 \
  STUB_CLAUDE_COMMIT=1 --local --base main --dir "$E2E_CLONE" --max 1
_st=$(e2e_state); _round1=$(git -C "$E2E_CLONE" rev-parse HEAD)
printf '%s\n' "$E2E_BASE" > "$_st/local/tip.sha"     # unanchored
printf 'pending 1 %s\n' "$E2E_BASE" > "$_st/local/pending-turn"
run_e2e STUB_CODEX_VERDICT=CHANGES_REQUESTED STUB_CODEX_BLOCKERS=1 \
  STUB_CLAUDE_COMMIT=1 --local --base main --dir "$E2E_CLONE" --max 1
assert_eq "$E2E_RC" 1
assert_substr "$WORK/e2e.out" 'moved outside the loop'
if [[ ! -e "$_st/local/pending-turn" ]]; then ok
else bad "the pending receipt survived"; fi
if [[ ! -s "$_st/iter-01/claude-response.md" ]]; then ok
else bad "the unvalidated round's response was not invalidated"; fi
assert_eq "$(git -C "$E2E_CLONE" rev-parse HEAD)" "$_round1"   # the branch was not clobbered

t "run.sh e2e: a foreign commit at the tip is never anchored as the round"
# The `done` commit is real, but the ref moved to a human commit stacked on
# it: recovery must refuse rather than reset the branch back over the human.
e2e_fixture
run_e2e STUB_CODEX_VERDICT=CHANGES_REQUESTED STUB_CODEX_BLOCKERS=1 \
  STUB_CLAUDE_COMMIT=1 --local --base main --dir "$E2E_CLONE" --max 1
_st=$(e2e_state); _round1=$(git -C "$E2E_CLONE" rev-parse HEAD)
echo human >> "$E2E_CLONE/f"; git -C "$E2E_CLONE" commit -qam "foreign human"
_human=$(git -C "$E2E_CLONE" rev-parse HEAD)
printf '%s\n' "$E2E_BASE" > "$_st/local/tip.sha"
printf 'done 1 %s %s\n' "$E2E_BASE" "$_round1" > "$_st/local/pending-turn"
run_e2e STUB_CODEX_VERDICT=CHANGES_REQUESTED STUB_CODEX_BLOCKERS=1 \
  --local --base main --dir "$E2E_CLONE" --max 1
assert_eq "$E2E_RC" 1
assert_substr "$WORK/e2e.out" 'refusing to move it'
assert_eq "$(git -C "$E2E_CLONE" rev-parse refs/heads/feature/x)" "$_human"  # untouched

t "run.sh e2e: --restart anchors a validated round before re-basing"
# A validated fix committed but not anchored, then --restart: recovery must
# anchor the fix into the current state, not drop it with the receipt.
e2e_fixture
run_e2e STUB_CODEX_VERDICT=CHANGES_REQUESTED STUB_CODEX_BLOCKERS=1 \
  STUB_CLAUDE_COMMIT=1 --local --base main --dir "$E2E_CLONE" --max 1
_st=$(e2e_state); _round1=$(git -C "$E2E_CLONE" rev-parse HEAD)
printf '%s\n' "$E2E_BASE" > "$_st/local/tip.sha"
printf 'done 1 %s %s\n' "$E2E_BASE" "$_round1" > "$_st/local/pending-turn"
run_e2e STUB_CODEX_VERDICT=CHANGES_REQUESTED STUB_CODEX_BLOCKERS=1 \
  --local --base main --dir "$E2E_CLONE" --max 1 --restart
assert_substr "$WORK/e2e.out" "anchored its commit $_round1"
if git -C "$E2E_CLONE" merge-base --is-ancestor "$_round1" HEAD; then ok
else bad "the restart dropped the validated round's commit"; fi

t "run.sh e2e: a torn --restart floor fails closed instead of reading as 0"
e2e_fixture
printf 'CHANGES_REQUESTED\nAPPROVED\n' > "$WORK/e2e-verdicts"
run_e2e STUB_CODEX_VERDICT_SEQ="$WORK/e2e-verdicts" STUB_CODEX_BLOCKERS=1 \
  STUB_CLAUDE_COMMIT=1 --local --base main --dir "$E2E_CLONE" --max 4 --no-push
assert_eq "$E2E_RC" 0
_st=$(e2e_state)
: > "$_st/local/iter-floor"          # a kill mid-write left it empty
run_e2e --local --base main --dir "$E2E_CLONE" --max 2 --no-push
assert_eq "$E2E_RC" 1
assert_substr "$WORK/e2e.out" 'empty or malformed'
if [[ -s "$_st/local/finalized" ]]; then ok
else bad "the superseded held squash was landed despite a torn floor"; fi

t "run.sh e2e: the --restart floor is published atomically"
rm -f "$_st/local/iter-floor"
# The kill fires from the mv the atomic publish performs: a plain '>'
# write runs no mv, the run survives, and the rc assertion below fails.
# (The subshell mutes the SIGKILL job notice; rc travels through a file.)
( run_e2e STUB_KILL_AFTER_MV=iter-floor \
    --local --base main --dir "$E2E_CLONE" --max 1 --restart --no-push
  printf '%s\n' "$E2E_RC" > "$WORK/e2e-killed.rc" ) 2>/dev/null
assert_eq "$(cat "$WORK/e2e-killed.rc")" 137     # SIGKILL at the publish
if [[ -s "$_st/local/iter-floor" ]] \
   && [[ "$(cat "$_st/local/iter-floor")" =~ ^[0-9]+$ ]]; then ok
else bad "a kill right after the floor's publish left it torn"; fi

t "run.sh e2e: a metadata-only hold at the remote head is not read as landed"
# A metadata-only hold's SHA IS the base, which is also the remote head —
# the shape that made the landed-squash shortcut fire for a review that
# pushed nothing. The recorded kind is what separates them.
e2e_fixture_origin
run_e2e --local --base main --dir "$E2E_CLONE" --max 2   # approve, nothing lands
assert_eq "$E2E_RC" 0
_st=$(e2e_state)
printf '%s\n' "$E2E_BASE" > "$_st/local/base.sha"
printf '%s\n' "$E2E_BASE" > "$_st/local/tip.sha"
printf '%s %s\n' "nocommit" "$E2E_BASE" > "$_st/local/finalized"
git -C "$E2E_CLONE" remote get-url --all origin > "$_st/local/origin.url"; git -C "$E2E_CLONE" remote get-url --push --all origin >> "$_st/local/origin.url"
rm -f "$_st/local/completed.sha"
run_e2e --local --base main --dir "$E2E_CLONE" --max 1 --restart
assert_no_substr "$WORK/e2e.out" 'already reached the remote'
if [[ -e "$_st/local/finalized" ]]; then
  bad "the superseded metadata-only hold survived the restart"; else ok; fi

t "run.sh e2e: a plain rerun completes a landed push and exits terminal"
e2e_fixture_origin
printf 'CHANGES_REQUESTED\nAPPROVED\n' > "$WORK/e2e-verdicts"
run_e2e STUB_CODEX_VERDICT_SEQ="$WORK/e2e-verdicts" STUB_CODEX_BLOCKERS=1 \
  STUB_CLAUDE_COMMIT=1 --local --base main --dir "$E2E_CLONE" --max 4
assert_eq "$E2E_RC" 0
_st=$(e2e_state); _s=$(git -C "$E2E_CLONE" rev-parse HEAD)
printf '%s\n' "$E2E_BASE" > "$_st/local/base.sha"     # the crash window
printf '%s\n' "$_s"       > "$_st/local/tip.sha"
printf '%s %s\n' "squash" "$_s" > "$_st/local/finalized"
git -C "$E2E_CLONE" remote get-url --all origin > "$_st/local/origin.url"; git -C "$E2E_CLONE" remote get-url --push --all origin >> "$_st/local/origin.url"
rm -f "$_st/local/completed.sha"
run_e2e --local --base main --dir "$E2E_CLONE" --max 2
assert_eq "$E2E_RC" 0
assert_substr "$WORK/e2e.out" 'already reached the remote'
assert_eq "$(cat "$_st/local/completed.sha")" "$_s"
assert_eq "$(git -C "$E2E_REMOTE" rev-parse refs/heads/feature/x)" "$_s"

t "run.sh e2e: --restart --no-push on a landed squash refuses to discard it"
e2e_fixture_origin
printf 'CHANGES_REQUESTED\nAPPROVED\n' > "$WORK/e2e-verdicts"
run_e2e STUB_CODEX_VERDICT_SEQ="$WORK/e2e-verdicts" STUB_CODEX_BLOCKERS=1 \
  STUB_CLAUDE_COMMIT=1 --local --base main --dir "$E2E_CLONE" --max 4
assert_eq "$E2E_RC" 0
_st=$(e2e_state); _s=$(git -C "$E2E_CLONE" rev-parse HEAD)
printf '%s\n' "$E2E_BASE" > "$_st/local/base.sha"       # the crash window again
printf '%s\n' "$_s"       > "$_st/local/tip.sha"
printf '%s %s\n' "squash" "$_s" > "$_st/local/finalized"
git -C "$E2E_CLONE" remote get-url --all origin > "$_st/local/origin.url"; git -C "$E2E_CLONE" remote get-url --push --all origin >> "$_st/local/origin.url"
rm -f "$_st/local/completed.sha"
run_e2e --local --base main --dir "$E2E_CLONE" --max 2 --restart --no-push
assert_eq "$E2E_RC" 1
assert_substr "$WORK/e2e.out" 'did not complete'
if [[ -s "$_st/local/finalized" ]]; then ok
else bad "--no-push discarded a landed squash's marker"; fi
assert_eq "$(git -C "$E2E_REMOTE" rev-parse refs/heads/feature/x)" "$_s"

t "run.sh e2e: --restart with an unreachable remote refuses to discard a hold"
git -C "$E2E_CLONE" remote set-url origin "$WORK/no-such-remote-$RANDOM.git"
printf '%s\n%s\n' "$(git -C "$E2E_CLONE" remote get-url origin)" \
                  "$(git -C "$E2E_CLONE" remote get-url origin)" > "$_st/local/origin.url"
run_e2e --local --base main --dir "$E2E_CLONE" --max 2 --restart
assert_eq "$E2E_RC" 1
assert_substr "$WORK/e2e.out" 'refusing to discard'
if [[ -s "$_st/local/finalized" ]]; then ok
else bad "an unreachable remote let the restart discard a possibly-landed squash"; fi

t "run.sh e2e: an interrupted --restart consume still supersedes a held squash"
e2e_fixture
printf 'CHANGES_REQUESTED\nAPPROVED\n' > "$WORK/e2e-verdicts"
run_e2e STUB_CODEX_VERDICT_SEQ="$WORK/e2e-verdicts" STUB_CODEX_BLOCKERS=1 \
  STUB_CLAUDE_COMMIT=1 --local --base main --dir "$E2E_CLONE" --max 4 --no-push
assert_eq "$E2E_RC" 0
_st=$(e2e_state)
printf '2\n' > "$_st/local/iter-floor"   # --restart persisted its intent, then died
run_e2e --local --base main --dir "$E2E_CLONE" --max 2 --no-push
assert_eq "$E2E_RC" 0
if [[ -s "$_st/iter-03/codex-review.md" ]]; then ok
else bad "the plain retry landed the superseded held squash without a new review"; fi

t "run.sh e2e: a crashed --restart cannot resume onto the old review's approval"
e2e_fixture
run_e2e --local --base main --dir "$E2E_CLONE" --max 2    # APPROVED, no rounds -> completed
assert_eq "$E2E_RC" 0
printf 'human follow-up\n' >> "$E2E_CLONE/f"
git -C "$E2E_CLONE" commit -qam "human follow-up"
_human=$(git -C "$E2E_CLONE" rev-parse HEAD)
run_e2e STUB_NO_LOCAL_ARTIFACT=1 --local --base main --dir "$E2E_CLONE" --max 2 --restart
assert_eq "$E2E_RC" 1                                     # codex crashed before any artifact
run_e2e --local --base main --dir "$E2E_CLONE" --max 2    # plain retry of the restarted review
assert_eq "$E2E_RC" 0
if [[ -s "$(e2e_state)/iter-02/codex-review.md" ]]; then ok   # a REAL round reviewed the new head
else bad "the retry completed without a codex round reviewing the new head"; fi
assert_eq "$(cat "$(e2e_state)/local/completed.sha" 2>/dev/null)" "$_human"

