# --- sync_repo_to_pr_head (real git: exact head, fail-closed, literal) -------
# Build a bare remote with 'main' and a head branch (whose name may be
# option-like/ambiguous), plus a clone, and exercise the sync directly.
sync_setup() {  # <head-branch> -> $SYNC_REMOTE $SYNC_CLONE $SYNC_SEED $SYNC_HEAD $SYNC_BASE
  local hb="$1" n="sync$RANDOM$RANDOM"
  SYNC_REMOTE="$WORK/$n-remote.git"; git init -q --bare -b main "$SYNC_REMOTE"
  SYNC_SEED="$WORK/$n-seed"; git init -q -b main "$SYNC_SEED"
  git -C "$SYNC_SEED" config user.email t@t; git -C "$SYNC_SEED" config user.name t
  echo base > "$SYNC_SEED/f"; git -C "$SYNC_SEED" add f; git -C "$SYNC_SEED" commit -qm base
  SYNC_BASE=$(git -C "$SYNC_SEED" rev-parse HEAD)
  git -C "$SYNC_SEED" push -q "$SYNC_REMOTE" HEAD:refs/heads/main
  echo head >> "$SYNC_SEED/f"; git -C "$SYNC_SEED" commit -qam head
  SYNC_HEAD=$(git -C "$SYNC_SEED" rev-parse HEAD)
  git -C "$SYNC_SEED" push -q "$SYNC_REMOTE" "HEAD:refs/heads/$hb"
  SYNC_CLONE="$WORK/$n-clone"; git clone -q "$SYNC_REMOTE" "$SYNC_CLONE"
}
sync_run() {  # <head-ref> [VAR=VAL ...]
  env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
    REPO_DIR="$SYNC_CLONE" BASE_REF=main HEAD_REF="$1" "${@:2}" \
    "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; sync_repo_to_pr_head" >/dev/null 2>&1
}
sync_head_now() { git -C "$SYNC_CLONE" rev-parse HEAD; }

t "sync: managed clone lands on the exact head (ordinary branch)"
sync_setup feature/x
if sync_run feature/x && [[ "$(sync_head_now)" == "$SYNC_HEAD" ]]; then ok
else bad "sync did not land the managed clone on the head"; fi

t "sync: an option-like '-f' head branch is selected literally"
sync_setup -f
if sync_run -f && [[ "$(sync_head_now)" == "$SYNC_HEAD" ]]; then ok
else bad "'-f' head not selected literally (checkout mis-parsed it as a flag?)"; fi

t "sync: an ambiguous '@' head branch is selected literally"
sync_setup '@'
if sync_run '@' && [[ "$(sync_head_now)" == "$SYNC_HEAD" ]]; then ok
else bad "'@' head not selected literally"; fi

t "sync: a leading-'+' head branch is selected literally"
sync_setup '+weird'
if sync_run '+weird' && [[ "$(sync_head_now)" == "$SYNC_HEAD" ]]; then ok
else bad "'+weird' head not selected literally"; fi

t "sync: a force-rewound managed clone hard-resets to the new head"
sync_setup feature/x
git -C "$SYNC_CLONE" checkout -q --detach "$SYNC_HEAD"   # local at B
git -C "$SYNC_SEED" push -q --force "$SYNC_REMOTE" "$SYNC_BASE:refs/heads/feature/x"  # remote B->A
if sync_run feature/x && [[ "$(sync_head_now)" == "$SYNC_BASE" ]]; then ok
else bad "sync did not reset the stale local HEAD to the rewound remote head"; fi

t "sync: a --dir clone with local-ahead work fails closed (not discarded)"
sync_setup feature/x
git -C "$SYNC_CLONE" checkout -q --detach "$SYNC_HEAD"
git -C "$SYNC_CLONE" config user.email t@t; git -C "$SYNC_CLONE" config user.name t
echo local >> "$SYNC_CLONE/f"; git -C "$SYNC_CLONE" commit -qam localahead
SYNC_AHEAD=$(sync_head_now)
if sync_run feature/x MANAGED_CLONE=0; then bad "discarded local-ahead work in a --dir clone"
elif [[ "$(sync_head_now)" == "$SYNC_AHEAD" ]]; then ok
else bad "--dir local-ahead HEAD was moved despite the fail-closed guard"; fi

t "sync: a --dir clone behind the head advances cleanly"
sync_setup feature/x
git -C "$SYNC_CLONE" checkout -q --detach "$SYNC_BASE"   # ancestor of head
if sync_run feature/x MANAGED_CLONE=0 && [[ "$(sync_head_now)" == "$SYNC_HEAD" ]]; then ok
else bad "--dir clone behind the head did not advance to it"; fi

t "sync: a head branch literally named 'HEAD' stays stable across repeated syncs"
sync_setup HEAD
SYNC_OK=1
for _ in 1 2 3 4; do   # the origin/HEAD-symref alias made this alternate base/head
  sync_run HEAD && [[ "$(sync_head_now)" == "$SYNC_HEAD" ]] || SYNC_OK=0
done
if [[ "$SYNC_OK" == 1 ]] \
   && [[ "$(git -C "$SYNC_CLONE" rev-parse refs/ai-pr-loop/base)" == "$SYNC_BASE" ]]; then ok
else bad "'HEAD'-named branch aliased a symref: sync alternated or corrupted the base ref"; fi

t "sync: a managed clone's staged/unstaged/untracked dirt is dropped, not committed"
sync_setup feature/x
git -C "$SYNC_CLONE" checkout -q --detach "$SYNC_HEAD"   # already at target
echo tampered >> "$SYNC_CLONE/f"                       # unstaged
echo staged > "$SYNC_CLONE/staged.txt"; git -C "$SYNC_CLONE" add staged.txt   # staged
echo stray > "$SYNC_CLONE/untracked.txt"               # untracked
if sync_run feature/x && [[ "$(sync_head_now)" == "$SYNC_HEAD" ]] \
   && [[ -z "$(git -C "$SYNC_CLONE" status --porcelain)" ]]; then ok
else bad "managed clone kept dirty state after sync (an agent turn could commit it)"; fi

t "sync: a --dir clone at the exact head but with dirt fails closed, dirt intact"
sync_setup feature/x
git -C "$SYNC_CLONE" checkout -q --detach "$SYNC_HEAD"   # already at target
echo staged > "$SYNC_CLONE/staged.txt"; git -C "$SYNC_CLONE" add staged.txt
echo stray > "$SYNC_CLONE/untracked.txt"
if sync_run feature/x MANAGED_CLONE=0; then bad "dirty --dir clone at the head was accepted"
elif [[ -f "$SYNC_CLONE/staged.txt" && -f "$SYNC_CLONE/untracked.txt" ]]; then ok
else bad "--dir dirt was destroyed by the fail-closed path"; fi

t "sync: a --dir clone behind the head with dirt fails closed, HEAD unmoved"
sync_setup feature/x
git -C "$SYNC_CLONE" checkout -q --detach "$SYNC_BASE"   # behind the head
echo stray > "$SYNC_CLONE/untracked.txt"
if sync_run feature/x MANAGED_CLONE=0; then bad "dirty behind --dir clone advanced anyway"
elif [[ "$(sync_head_now)" == "$SYNC_BASE" && -f "$SYNC_CLONE/untracked.txt" ]]; then ok
else bad "--dir behind-with-dirt moved HEAD or lost the dirt"; fi

t "sync: a clean --dir clone is detached even when already at the head"
sync_setup feature/x
git -C "$SYNC_CLONE" checkout -q -b atspot "$SYNC_HEAD"  # attached branch at target
if sync_run feature/x MANAGED_CLONE=0 && [[ "$(sync_head_now)" == "$SYNC_HEAD" ]] \
   && ! git -C "$SYNC_CLONE" symbolic-ref -q HEAD >/dev/null; then ok
else bad "sync left HEAD attached to a local branch (a turn's commit would move it)"; fi

t "sync: --dir dirt guard sees untracked files despite status.showUntrackedFiles=no"
sync_setup feature/x
git -C "$SYNC_CLONE" checkout -q --detach "$SYNC_HEAD"
git -C "$SYNC_CLONE" config status.showUntrackedFiles no   # caller perf setting
echo stray > "$SYNC_CLONE/untracked.txt"
if sync_run feature/x MANAGED_CLONE=0; then
  bad "caller config hid the untracked file from the --dir dirt guard"
else ok; fi

t "sync: after the first clean --dir sync, agent-turn artifacts are cleaned, not fatal"
sync_setup feature/x
if env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
     REPO_DIR="$SYNC_CLONE" BASE_REF=main HEAD_REF=feature/x MANAGED_CLONE=0 \
     "$BASH_BIN" -c '
       . "$1/lib/common.sh"
       sync_repo_to_pr_head                    # strict first sync (clean clone)
       echo artifact > "$REPO_DIR/agent-scratch.log"   # a turn leaves test output
       sync_repo_to_pr_head                    # between-turn sync must not die
     ' _ "$ROOT" >/dev/null 2>&1 \
   && [[ "$(sync_head_now)" == "$SYNC_HEAD" ]] \
   && [[ ! -e "$SYNC_CLONE/agent-scratch.log" ]]; then ok
else bad "mid-run --dir sync died on (or kept) the loop's own turn artifact"; fi

t "sync: managed clean removes an embedded git repo (would publish as a gitlink)"
sync_setup feature/x
git init -q "$SYNC_CLONE/vendor-embed" && echo x > "$SYNC_CLONE/vendor-embed/f"
if sync_run feature/x && [[ ! -e "$SYNC_CLONE/vendor-embed" ]]; then ok
else bad "embedded repo survived sync; a later git add -A would commit a gitlink"; fi

t "sync: pre-existing symrefs at the private destinations cannot rewrite local branches"
sync_setup feature/x
# Each victim sits at the SHA the OTHER destination would write, so a fetch
# leaking through either surviving symref produces an observable rewrite.
git -C "$SYNC_CLONE" branch -q victim1 "$SYNC_HEAD"   # base refspec would write SYNC_BASE
git -C "$SYNC_CLONE" branch -q victim2 "$SYNC_BASE"   # head refspec would write SYNC_HEAD
git -C "$SYNC_CLONE" symbolic-ref refs/ai-pr-loop/base refs/heads/victim1
git -C "$SYNC_CLONE" symbolic-ref refs/ai-pr-loop/head refs/heads/victim2
if sync_run feature/x \
   && [[ "$(git -C "$SYNC_CLONE" rev-parse refs/heads/victim1)" == "$SYNC_HEAD" ]] \
   && [[ "$(git -C "$SYNC_CLONE" rev-parse refs/heads/victim2)" == "$SYNC_BASE" ]] \
   && ! git -C "$SYNC_CLONE" symbolic-ref -q refs/ai-pr-loop/base >/dev/null \
   && ! git -C "$SYNC_CLONE" symbolic-ref -q refs/ai-pr-loop/head >/dev/null \
   && [[ "$(git -C "$SYNC_CLONE" rev-parse refs/ai-pr-loop/base)" == "$SYNC_BASE" ]] \
   && [[ "$(git -C "$SYNC_CLONE" rev-parse refs/ai-pr-loop/head)" == "$SYNC_HEAD" ]]; then ok
else bad "a planted symref destination redirected the fetch onto a local branch"; fi

t "sync: eol/filter non-idempotent content fails closed (a turn's add -A would stage it)"
EOLN="eol$RANDOM$RANDOM"
EOL_REMOTE="$WORK/$EOLN-up.git"; git init -q --bare -b main "$EOL_REMOTE"
EOL_SEED="$WORK/$EOLN-seed"; git init -q -b main "$EOL_SEED"
git -C "$EOL_SEED" config user.email t@t; git -C "$EOL_SEED" config user.name t
printf 'line1\r\nline2\r\n' > "$EOL_SEED/w.txt"
git -C "$EOL_SEED" -c core.autocrlf=false add w.txt; git -C "$EOL_SEED" commit -qm crlf
git -C "$EOL_SEED" push -q "$EOL_REMOTE" HEAD:refs/heads/main
printf 'w.txt text eol=lf\n' > "$EOL_SEED/.gitattributes"
git -C "$EOL_SEED" add .gitattributes; git -C "$EOL_SEED" commit -qm attrs   # no renormalize
git -C "$EOL_SEED" push -q "$EOL_REMOTE" HEAD:refs/heads/feature/x
EOL_CLONE="$WORK/$EOLN-clone"; git clone -q "$EOL_REMOTE" "$EOL_CLONE"
if env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
     REPO_DIR="$EOL_CLONE" BASE_REF=main HEAD_REF=feature/x \
     "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; sync_repo_to_pr_head" >/dev/null 2>&1; then
  bad "sync accepted eol-renormalization dirt that git add -A would publish"
elif git -C "$EOL_CLONE" diff --cached --quiet; then ok   # nothing ever staged
else bad "sync failed but left staged content behind"; fi

t "sync: --dir dirt guard sees a drifted gitlink despite submodule.<name>.ignore=all"
SMIN="smi$RANDOM$RANDOM"
SMI_REPO="$WORK/$SMIN-dep"; git init -q -b main "$SMI_REPO"
git -C "$SMI_REPO" config user.email t@t; git -C "$SMI_REPO" config user.name t
echo s1 > "$SMI_REPO/g"; git -C "$SMI_REPO" add g; git -C "$SMI_REPO" commit -qm s1
SMI_S1=$(git -C "$SMI_REPO" rev-parse HEAD)
echo s2 >> "$SMI_REPO/g"; git -C "$SMI_REPO" commit -qam s2
SMI_S2=$(git -C "$SMI_REPO" rev-parse HEAD)
SMI_REMOTE="$WORK/$SMIN-up.git"; git init -q --bare -b main "$SMI_REMOTE"
SMI_SEED="$WORK/$SMIN-seed"; git init -q -b main "$SMI_SEED"
git -C "$SMI_SEED" config user.email t@t; git -C "$SMI_SEED" config user.name t
echo a > "$SMI_SEED/f"; git -C "$SMI_SEED" add f
git -C "$SMI_SEED" -c protocol.file.allow=always submodule add -q "$SMI_REPO" dep 2>/dev/null
git -C "$SMI_SEED/dep" checkout -q "$SMI_S1"
git -C "$SMI_SEED" add dep .gitmodules; git -C "$SMI_SEED" commit -qm super
git -C "$SMI_SEED" push -q "$SMI_REMOTE" HEAD:refs/heads/main
git -C "$SMI_SEED" push -q "$SMI_REMOTE" HEAD:refs/heads/feature/x
SMI_CLONE="$WORK/$SMIN-clone"
git -c protocol.file.allow=always clone -q --recurse-submodules "$SMI_REMOTE" "$SMI_CLONE"
git -C "$SMI_CLONE/dep" checkout -q "$SMI_S2"          # caller drifted the gitlink
git -C "$SMI_CLONE" config submodule.dep.ignore all    # ...and their config hides it
if env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
     REPO_DIR="$SMI_CLONE" BASE_REF=main HEAD_REF=feature/x MANAGED_CLONE=0 \
     "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; sync_repo_to_pr_head" >/dev/null 2>&1; then
  bad "submodule.<name>.ignore=all hid the drifted gitlink from the --dir dirt guard"
elif [[ "$(git -C "$SMI_CLONE/dep" rev-parse HEAD)" == "$SMI_S2" ]]; then ok
else bad "the guard fired but the caller's submodule state was changed"; fi

t "sync: a caller post-checkout hook cannot inject artifacts during --dir sync"
HKN="hk$RANDOM$RANDOM"
HK_REMOTE="$WORK/$HKN-up.git"; git init -q --bare -b main "$HK_REMOTE"
HK_SEED="$WORK/$HKN-seed"; git init -q -b main "$HK_SEED"
git -C "$HK_SEED" config user.email t@t; git -C "$HK_SEED" config user.name t
echo a > "$HK_SEED/f"; git -C "$HK_SEED" add f; git -C "$HK_SEED" commit -qm base
git -C "$HK_SEED" push -q "$HK_REMOTE" HEAD:refs/heads/main
echo b >> "$HK_SEED/f"; git -C "$HK_SEED" commit -qam head
HK_HEAD=$(git -C "$HK_SEED" rev-parse HEAD)
git -C "$HK_SEED" push -q "$HK_REMOTE" HEAD:refs/heads/feature/x
HK_CLONE="$WORK/$HKN-clone"; git clone -q "$HK_REMOTE" "$HK_CLONE"   # clean, at base
printf '#!/bin/sh\ntouch generated.txt\n' > "$HK_CLONE/.git/hooks/post-checkout"
chmod +x "$HK_CLONE/.git/hooks/post-checkout"
if env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
     REPO_DIR="$HK_CLONE" BASE_REF=main HEAD_REF=feature/x MANAGED_CLONE=0 \
     "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; sync_repo_to_pr_head" >/dev/null 2>&1 \
   && [[ "$(git -C "$HK_CLONE" rev-parse HEAD)" == "$HK_HEAD" ]] \
   && [[ ! -e "$HK_CLONE/generated.txt" ]]; then ok
else bad "a post-checkout hook artifact survived the --dir sync (add -A would publish it)"; fi

t "sync: --dir dirt guard sees inner untracked hidden by submodule-local config"
SMH="smh$RANDOM$RANDOM"
SMH_REPO="$WORK/$SMH-dep"; git init -q -b main "$SMH_REPO"
git -C "$SMH_REPO" config user.email t@t; git -C "$SMH_REPO" config user.name t
echo s1 > "$SMH_REPO/g"; git -C "$SMH_REPO" add g; git -C "$SMH_REPO" commit -qm s1
SMH_REMOTE="$WORK/$SMH-up.git"; git init -q --bare -b main "$SMH_REMOTE"
SMH_SEED="$WORK/$SMH-seed"; git init -q -b main "$SMH_SEED"
git -C "$SMH_SEED" config user.email t@t; git -C "$SMH_SEED" config user.name t
echo a > "$SMH_SEED/f"; git -C "$SMH_SEED" add f
git -C "$SMH_SEED" -c protocol.file.allow=always submodule add -q "$SMH_REPO" dep 2>/dev/null
git -C "$SMH_SEED" add dep .gitmodules; git -C "$SMH_SEED" commit -qm super
git -C "$SMH_SEED" push -q "$SMH_REMOTE" HEAD:refs/heads/main
git -C "$SMH_SEED" push -q "$SMH_REMOTE" HEAD:refs/heads/feature/x
SMH_CLONE="$WORK/$SMH-clone"
git -c protocol.file.allow=always clone -q --recurse-submodules "$SMH_REMOTE" "$SMH_CLONE"
echo caller-data > "$SMH_CLONE/dep/notes.txt"          # caller's untracked file inside dep
git -C "$SMH_CLONE/dep" config status.showUntrackedFiles no   # ...hidden by inner config
if env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
     REPO_DIR="$SMH_CLONE" BASE_REF=main HEAD_REF=feature/x MANAGED_CLONE=0 \
     "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; sync_repo_to_pr_head" >/dev/null 2>&1; then
  bad "inner config hid caller's untracked submodule file (later trusted syncs would delete it)"
elif [[ -f "$SMH_CLONE/dep/notes.txt" ]]; then ok
else bad "the guard fired but the caller's inner file was destroyed"; fi

t "sync: a PR-supplied .gitmodules update=merge cannot mutate the caller's submodule branch"
SMM="smm$RANDOM$RANDOM"
SMM_REPO="$WORK/$SMM-dep"; git init -q -b main "$SMM_REPO"
git -C "$SMM_REPO" config user.email t@t; git -C "$SMM_REPO" config user.name t
echo d2 > "$SMM_REPO/g"; git -C "$SMM_REPO" add g; git -C "$SMM_REPO" commit -qm d2
SMM_D2=$(git -C "$SMM_REPO" rev-parse HEAD)
echo d3 >> "$SMM_REPO/g"; git -C "$SMM_REPO" commit -qam d3
SMM_D3=$(git -C "$SMM_REPO" rev-parse HEAD)
SMM_REMOTE="$WORK/$SMM-up.git"; git init -q --bare -b main "$SMM_REMOTE"
SMM_SEED="$WORK/$SMM-seed"; git init -q -b main "$SMM_SEED"
git -C "$SMM_SEED" config user.email t@t; git -C "$SMM_SEED" config user.name t
echo a > "$SMM_SEED/f"; git -C "$SMM_SEED" add f
git -C "$SMM_SEED" -c protocol.file.allow=always submodule add -q "$SMM_REPO" dep 2>/dev/null
git -C "$SMM_SEED/dep" checkout -q "$SMM_D2"
git -C "$SMM_SEED" add dep .gitmodules; git -C "$SMM_SEED" commit -qm super
git -C "$SMM_SEED" push -q "$SMM_REMOTE" HEAD:refs/heads/main
git -C "$SMM_SEED" config -f .gitmodules submodule.dep.update merge   # PR-controlled strategy
git -C "$SMM_SEED/dep" checkout -q "$SMM_D3"
git -C "$SMM_SEED" add dep .gitmodules; git -C "$SMM_SEED" commit -qm "move dep, merge strategy"
git -C "$SMM_SEED" push -q "$SMM_REMOTE" HEAD:refs/heads/feature/x
SMM_CLONE="$WORK/$SMM-clone"
git -c protocol.file.allow=always clone -q --recurse-submodules "$SMM_REMOTE" "$SMM_CLONE"
git -C "$SMM_CLONE/dep" checkout -q -b callerwork      # caller branch at recorded D2
if env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
     REPO_DIR="$SMM_CLONE" BASE_REF=main HEAD_REF=feature/x MANAGED_CLONE=0 \
     "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; sync_repo_to_pr_head" >/dev/null 2>&1 \
   && [[ "$(git -C "$SMM_CLONE/dep" rev-parse refs/heads/callerwork)" == "$SMM_D2" ]] \
   && [[ "$(git -C "$SMM_CLONE/dep" rev-parse HEAD)" == "$SMM_D3" ]] \
   && ! git -C "$SMM_CLONE/dep" symbolic-ref -q HEAD >/dev/null; then ok
else bad "update=merge from the PR's .gitmodules advanced or rewrote the caller's branch"; fi

t "sync: a caller fsmonitor hook cannot hide tracked edits from the --dir dirt guard"
FSM="fsm$RANDOM$RANDOM"
FSM_REMOTE="$WORK/$FSM-up.git"; git init -q --bare -b main "$FSM_REMOTE"
FSM_SEED="$WORK/$FSM-seed"; git init -q -b main "$FSM_SEED"
git -C "$FSM_SEED" config user.email t@t; git -C "$FSM_SEED" config user.name t
echo a > "$FSM_SEED/f"; git -C "$FSM_SEED" add f; git -C "$FSM_SEED" commit -qm base
git -C "$FSM_SEED" push -q "$FSM_REMOTE" HEAD:refs/heads/main
echo b >> "$FSM_SEED/f"; git -C "$FSM_SEED" commit -qam head
git -C "$FSM_SEED" push -q "$FSM_REMOTE" HEAD:refs/heads/feature/x
FSM_CLONE="$WORK/$FSM-clone"; git clone -q "$FSM_REMOTE" "$FSM_CLONE"
printf '#!/bin/sh\nprintf "v2tok\\0"\n' > "$FSM_CLONE/.git/fsmon"   # "nothing changed"
chmod +x "$FSM_CLONE/.git/fsmon"
git -C "$FSM_CLONE" config core.fsmonitor "$FSM_CLONE/.git/fsmon"
git -C "$FSM_CLONE" update-index --fsmonitor              # prime the index extension
git -C "$FSM_CLONE" status --porcelain >/dev/null         # ...while the tree is clean
echo caller-edit >> "$FSM_CLONE/f"                        # NOW the hook hides this edit
if [[ -n "$(git -C "$FSM_CLONE" status --porcelain)" ]]; then
  bad "test precondition failed: the fsmonitor hook did not hide the edit from status"
elif env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
     REPO_DIR="$FSM_CLONE" BASE_REF=main HEAD_REF=feature/x MANAGED_CLONE=0 \
     "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; sync_repo_to_pr_head" >/dev/null 2>&1; then
  bad "an fsmonitor hook hid the caller's tracked edit from the --dir dirt guard"
elif grep -q caller-edit "$FSM_CLONE/f"; then ok
else bad "the guard fired but the caller's edit was destroyed"; fi

t "sync: a lying fsmonitor hook cannot wedge the trusted-path cleanup"
FST="fst$RANDOM$RANDOM"
FST_REMOTE="$WORK/$FST-up.git"; git init -q --bare -b main "$FST_REMOTE"
FST_SEED="$WORK/$FST-seed"; git init -q -b main "$FST_SEED"
git -C "$FST_SEED" config user.email t@t; git -C "$FST_SEED" config user.name t
echo a > "$FST_SEED/f"; git -C "$FST_SEED" add f; git -C "$FST_SEED" commit -qm base
git -C "$FST_SEED" push -q "$FST_REMOTE" HEAD:refs/heads/main
git -C "$FST_SEED" push -q "$FST_REMOTE" HEAD:refs/heads/feature/x
FST_CLONE="$WORK/$FST-clone"; git clone -q "$FST_REMOTE" "$FST_CLONE"
printf '#!/bin/sh\nprintf "v2tok\\0"\n' > "$FST_CLONE/.git/fsmon"; chmod +x "$FST_CLONE/.git/fsmon"
if env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
     REPO_DIR="$FST_CLONE" BASE_REF=main HEAD_REF=feature/x MANAGED_CLONE=0 \
     "$BASH_BIN" -c '
       . "$1/lib/common.sh"
       sync_repo_to_pr_head                    # clean first sync -> trusted
       git -C "$REPO_DIR" config core.fsmonitor "$REPO_DIR/.git/fsmon"
       git -C "$REPO_DIR" update-index --fsmonitor
       git -C "$REPO_DIR" status --porcelain >/dev/null   # prime while clean
       echo agent-edit >> "$REPO_DIR/f"        # a turn leaves a tracked edit
       sync_repo_to_pr_head                    # trusted cleanup must drop it
     ' _ "$ROOT" >/dev/null 2>&1 \
   && ! grep -q agent-edit "$FST_CLONE/f"; then ok
else bad "fsmonitor-primed edit survived (or wedged) the trusted-path cleanup"; fi

t "sync: --dir refuses a sparse-checkout clone with accurate guidance"
SPC="spc$RANDOM$RANDOM"
SPC_REMOTE="$WORK/$SPC-up.git"; git init -q --bare -b main "$SPC_REMOTE"
SPC_SEED="$WORK/$SPC-seed"; git init -q -b main "$SPC_SEED"
git -C "$SPC_SEED" config user.email t@t; git -C "$SPC_SEED" config user.name t
mkdir -p "$SPC_SEED/dirA" "$SPC_SEED/dirB"
echo a > "$SPC_SEED/dirA/a.txt"; echo b > "$SPC_SEED/dirB/b.txt"
git -C "$SPC_SEED" add .; git -C "$SPC_SEED" commit -qm base
git -C "$SPC_SEED" push -q "$SPC_REMOTE" HEAD:refs/heads/main
git -C "$SPC_SEED" push -q "$SPC_REMOTE" HEAD:refs/heads/feature/x
SPC_CLONE="$WORK/$SPC-clone"; git clone -q "$SPC_REMOTE" "$SPC_CLONE"
git -C "$SPC_CLONE" sparse-checkout set dirA 2>/dev/null
SPC_ERR=$(env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
    REPO_DIR="$SPC_CLONE" BASE_REF=main HEAD_REF=feature/x MANAGED_CLONE=0 \
    "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; sync_repo_to_pr_head" 2>&1) && SPC_RC=0 || SPC_RC=$?
if [[ "$SPC_RC" != 0 ]] && grep -q 'sparse-checkout disable' <<< "$SPC_ERR"; then ok
else bad "sparse-checkout --dir clone was accepted, or the die message lacks accurate guidance"; fi

t "sync: assume-unchanged edits inside a submodule fail the --dir guard, edit intact"
SAU="sau$RANDOM$RANDOM"
SAU_REPO="$WORK/$SAU-dep"; git init -q -b main "$SAU_REPO"
git -C "$SAU_REPO" config user.email t@t; git -C "$SAU_REPO" config user.name t
echo s1 > "$SAU_REPO/g"; git -C "$SAU_REPO" add g; git -C "$SAU_REPO" commit -qm s1
SAU_REMOTE="$WORK/$SAU-up.git"; git init -q --bare -b main "$SAU_REMOTE"
SAU_SEED="$WORK/$SAU-seed"; git init -q -b main "$SAU_SEED"
git -C "$SAU_SEED" config user.email t@t; git -C "$SAU_SEED" config user.name t
echo a > "$SAU_SEED/f"; git -C "$SAU_SEED" add f
git -C "$SAU_SEED" -c protocol.file.allow=always submodule add -q "$SAU_REPO" dep 2>/dev/null
git -C "$SAU_SEED" add dep .gitmodules; git -C "$SAU_SEED" commit -qm super
git -C "$SAU_SEED" push -q "$SAU_REMOTE" HEAD:refs/heads/main
git -C "$SAU_SEED" push -q "$SAU_REMOTE" HEAD:refs/heads/feature/x   # gitlink does NOT move
SAU_CLONE="$WORK/$SAU-clone"
git -c protocol.file.allow=always clone -q --recurse-submodules "$SAU_REMOTE" "$SAU_CLONE"
echo hidden-edit >> "$SAU_CLONE/dep/g"
git -C "$SAU_CLONE/dep" update-index --assume-unchanged g   # invisible to every status
if env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
     REPO_DIR="$SAU_CLONE" BASE_REF=main HEAD_REF=feature/x MANAGED_CLONE=0 \
     "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; sync_repo_to_pr_head" >/dev/null 2>&1; then
  bad "an assume-unchanged submodule edit passed the --dir guard (later syncs destroy it)"
elif grep -q hidden-edit "$SAU_CLONE/dep/g"; then ok
else bad "the guard fired but the caller's submodule edit was destroyed"; fi

t "sync: assume-unchanged and skip-worktree edits fail the --dir guard, edits intact"
AUW="auw$RANDOM$RANDOM"
AUW_REMOTE="$WORK/$AUW-up.git"; git init -q --bare -b main "$AUW_REMOTE"
AUW_SEED="$WORK/$AUW-seed"; git init -q -b main "$AUW_SEED"
git -C "$AUW_SEED" config user.email t@t; git -C "$AUW_SEED" config user.name t
echo a > "$AUW_SEED/f"; git -C "$AUW_SEED" add f; git -C "$AUW_SEED" commit -qm base
git -C "$AUW_SEED" push -q "$AUW_REMOTE" HEAD:refs/heads/main
git -C "$AUW_SEED" push -q "$AUW_REMOTE" HEAD:refs/heads/feature/x
AUW_CLONE="$WORK/$AUW-clone"; git clone -q "$AUW_REMOTE" "$AUW_CLONE"   # at head already
echo hidden-edit >> "$AUW_CLONE/f"
git -C "$AUW_CLONE" update-index --assume-unchanged f   # status now empty
AUW_OK=1
env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
    REPO_DIR="$AUW_CLONE" BASE_REF=main HEAD_REF=feature/x MANAGED_CLONE=0 \
    "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; sync_repo_to_pr_head" >/dev/null 2>&1 && AUW_OK=0
grep -q hidden-edit "$AUW_CLONE/f" || AUW_OK=0
git -C "$AUW_CLONE" update-index --no-assume-unchanged f
git -C "$AUW_CLONE" update-index --skip-worktree f      # same hazard, other bit
env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
    REPO_DIR="$AUW_CLONE" BASE_REF=main HEAD_REF=feature/x MANAGED_CLONE=0 \
    "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; sync_repo_to_pr_head" >/dev/null 2>&1 && AUW_OK=0
grep -q hidden-edit "$AUW_CLONE/f" || AUW_OK=0
if [[ "$AUW_OK" == 1 ]]; then ok
else bad "an assume-unchanged/skip-worktree edit passed the --dir guard or was destroyed"; fi

t "sync: an ignored caller file inside a submodule the PR starts tracking fails closed"
SIG="sig$RANDOM$RANDOM"
SIG_REPO="$WORK/$SIG-dep"; git init -q -b main "$SIG_REPO"
git -C "$SIG_REPO" config user.email t@t; git -C "$SIG_REPO" config user.name t
printf 'secret\n' > "$SIG_REPO/.gitignore"; echo d1 > "$SIG_REPO/g"
git -C "$SIG_REPO" add .gitignore g; git -C "$SIG_REPO" commit -qm d1
SIG_D1=$(git -C "$SIG_REPO" rev-parse HEAD)
echo from-pr > "$SIG_REPO/secret"; git -C "$SIG_REPO" add -f secret
git -C "$SIG_REPO" commit -qm "track secret"
SIG_D2=$(git -C "$SIG_REPO" rev-parse HEAD)
SIG_REMOTE="$WORK/$SIG-up.git"; git init -q --bare -b main "$SIG_REMOTE"
SIG_SEED="$WORK/$SIG-seed"; git init -q -b main "$SIG_SEED"
git -C "$SIG_SEED" config user.email t@t; git -C "$SIG_SEED" config user.name t
echo a > "$SIG_SEED/f"; git -C "$SIG_SEED" add f
git -C "$SIG_SEED" -c protocol.file.allow=always submodule add -q "$SIG_REPO" dep 2>/dev/null
git -C "$SIG_SEED/dep" checkout -q "$SIG_D1"
git -C "$SIG_SEED" add dep .gitmodules; git -C "$SIG_SEED" commit -qm super
git -C "$SIG_SEED" push -q "$SIG_REMOTE" HEAD:refs/heads/main
git -C "$SIG_SEED/dep" checkout -q "$SIG_D2"
git -C "$SIG_SEED" add dep; git -C "$SIG_SEED" commit -qm "move dep to D2"
git -C "$SIG_SEED" push -q "$SIG_REMOTE" HEAD:refs/heads/feature/x
SIG_CLONE="$WORK/$SIG-clone"
git -c protocol.file.allow=always clone -q --recurse-submodules "$SIG_REMOTE" "$SIG_CLONE"
echo caller-private > "$SIG_CLONE/dep/secret"          # ignored at D1: probes clean
if env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
     REPO_DIR="$SIG_CLONE" BASE_REF=main HEAD_REF=feature/x MANAGED_CLONE=0 \
     "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; sync_repo_to_pr_head" >/dev/null 2>&1; then
  bad "--dir sync silently replaced the caller's ignored file inside the submodule"
elif [[ "$(cat "$SIG_CLONE/dep/secret")" == "caller-private" ]] \
   && [[ "$(git -C "$SIG_CLONE/dep" rev-parse HEAD)" == "$SIG_D1" ]]; then ok
else bad "the guard fired but the caller's submodule file or HEAD was changed"; fi

t "sync: submodule-internal eol noise does not wedge the managed loop"
SME="sme$RANDOM$RANDOM"
SME_REPO="$WORK/$SME-dep"; git init -q -b main "$SME_REPO"
git -C "$SME_REPO" config user.email t@t; git -C "$SME_REPO" config user.name t
printf 'l1\r\nl2\r\n' > "$SME_REPO/w.txt"
git -C "$SME_REPO" -c core.autocrlf=false add w.txt; git -C "$SME_REPO" commit -qm crlf
printf 'w.txt text eol=lf\n' > "$SME_REPO/.gitattributes"
git -C "$SME_REPO" add .gitattributes; git -C "$SME_REPO" commit -qm attrs   # no renormalize
SME_REMOTE="$WORK/$SME-up.git"; git init -q --bare -b main "$SME_REMOTE"
SME_SEED="$WORK/$SME-seed"; git init -q -b main "$SME_SEED"
git -C "$SME_SEED" config user.email t@t; git -C "$SME_SEED" config user.name t
echo a > "$SME_SEED/f"; git -C "$SME_SEED" add f
git -C "$SME_SEED" -c protocol.file.allow=always submodule add -q "$SME_REPO" dep 2>/dev/null
git -C "$SME_SEED" add dep .gitmodules; git -C "$SME_SEED" commit -qm super
git -C "$SME_SEED" push -q "$SME_REMOTE" HEAD:refs/heads/main
git -C "$SME_SEED" push -q "$SME_REMOTE" HEAD:refs/heads/feature/x
SME_CLONE="$WORK/$SME-clone"
git -c protocol.file.allow=always clone -q --recurse-submodules "$SME_REMOTE" "$SME_CLONE"
SME_HEAD=$(git -C "$SME_SEED" rev-parse HEAD)
if env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
     REPO_DIR="$SME_CLONE" BASE_REF=main HEAD_REF=feature/x \
     "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; sync_repo_to_pr_head" >/dev/null 2>&1 \
   && [[ "$(git -C "$SME_CLONE" rev-parse HEAD)" == "$SME_HEAD" ]]; then ok
else bad "inner eol noise (not publishable via the superproject) wedged the managed sync"; fi

t "sync: untracked artifacts inside an initialized submodule are cleaned (managed)"
SMC="smc$RANDOM$RANDOM"
SMC_REPO="$WORK/$SMC-dep"; git init -q -b main "$SMC_REPO"
git -C "$SMC_REPO" config user.email t@t; git -C "$SMC_REPO" config user.name t
echo s1 > "$SMC_REPO/g"; git -C "$SMC_REPO" add g; git -C "$SMC_REPO" commit -qm s1
SMC_REMOTE="$WORK/$SMC-up.git"; git init -q --bare -b main "$SMC_REMOTE"
SMC_SEED="$WORK/$SMC-seed"; git init -q -b main "$SMC_SEED"
git -C "$SMC_SEED" config user.email t@t; git -C "$SMC_SEED" config user.name t
echo a > "$SMC_SEED/f"; git -C "$SMC_SEED" add f
git -C "$SMC_SEED" -c protocol.file.allow=always submodule add -q "$SMC_REPO" dep 2>/dev/null
git -C "$SMC_SEED" add dep .gitmodules; git -C "$SMC_SEED" commit -qm super
git -C "$SMC_SEED" push -q "$SMC_REMOTE" HEAD:refs/heads/main
git -C "$SMC_SEED" push -q "$SMC_REMOTE" HEAD:refs/heads/feature/x
SMC_CLONE="$WORK/$SMC-clone"
git -c protocol.file.allow=always clone -q --recurse-submodules "$SMC_REMOTE" "$SMC_CLONE"
echo tampered >> "$SMC_CLONE/dep/g"                    # tracked edit inside submodule
echo cache > "$SMC_CLONE/dep/generated.cache"          # untracked artifact inside submodule
if env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
     REPO_DIR="$SMC_CLONE" BASE_REF=main HEAD_REF=feature/x \
     "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; sync_repo_to_pr_head" >/dev/null 2>&1 \
   && [[ ! -e "$SMC_CLONE/dep/generated.cache" ]] \
   && ! grep -q tampered "$SMC_CLONE/dep/g" \
   && [[ -z "$(git -C "$SMC_CLONE" status --porcelain --untracked-files=normal --ignore-submodules=none)" ]]; then ok
else bad "state inside an initialized submodule survived the managed sync"; fi

t "sync: an inherited SYNC_DIR_TRUSTED=1 cannot bypass the first --dir dirt check"
sync_setup feature/x
git -C "$SYNC_CLONE" checkout -q --detach "$SYNC_HEAD"
echo caller-edit >> "$SYNC_CLONE/f"                    # tracked, unstaged dirt
if sync_run feature/x MANAGED_CLONE=0 SYNC_DIR_TRUSTED=1; then
  bad "ambient SYNC_DIR_TRUSTED skipped the first-sync safety checks"
elif grep -q caller-edit "$SYNC_CLONE/f"; then ok
else bad "the bypass was rejected but the caller's edit was destroyed"; fi

t "sync: an initialized submodule on another commit is reset, not staged as a gitlink"
SUBN="sub$RANDOM$RANDOM"
SUB_REPO="$WORK/$SUBN-dep"; git init -q -b main "$SUB_REPO"
git -C "$SUB_REPO" config user.email t@t; git -C "$SUB_REPO" config user.name t
echo s1 > "$SUB_REPO/g"; git -C "$SUB_REPO" add g; git -C "$SUB_REPO" commit -qm s1
SUB_S1=$(git -C "$SUB_REPO" rev-parse HEAD)
echo s2 >> "$SUB_REPO/g"; git -C "$SUB_REPO" commit -qam s2
SUB_S2=$(git -C "$SUB_REPO" rev-parse HEAD)
SUB_REMOTE="$WORK/$SUBN-up.git"; git init -q --bare -b main "$SUB_REMOTE"
SUB_SEED="$WORK/$SUBN-seed"; git init -q -b main "$SUB_SEED"
git -C "$SUB_SEED" config user.email t@t; git -C "$SUB_SEED" config user.name t
echo a > "$SUB_SEED/f"; git -C "$SUB_SEED" add f
git -C "$SUB_SEED" -c protocol.file.allow=always submodule add -q "$SUB_REPO" dep 2>/dev/null
git -C "$SUB_SEED/dep" checkout -q "$SUB_S1"
git -C "$SUB_SEED" add dep .gitmodules; git -C "$SUB_SEED" commit -qm super
git -C "$SUB_SEED" push -q "$SUB_REMOTE" HEAD:refs/heads/main
git -C "$SUB_SEED" push -q "$SUB_REMOTE" HEAD:refs/heads/feature/x
SUB_CLONE="$WORK/$SUBN-clone"
git -c protocol.file.allow=always clone -q --recurse-submodules "$SUB_REMOTE" "$SUB_CLONE"
git -C "$SUB_CLONE/dep" checkout -q "$SUB_S2"          # drift the submodule HEAD
if env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
     REPO_DIR="$SUB_CLONE" BASE_REF=main HEAD_REF=feature/x \
     "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; sync_repo_to_pr_head" >/dev/null 2>&1 \
   && [[ "$(git -C "$SUB_CLONE/dep" rev-parse HEAD)" == "$SUB_S1" ]]; then ok
else bad "drifted submodule HEAD survived sync; git add -A would stage the gitlink"; fi

t "sync: an ignored caller file the head starts tracking fails closed (--dir)"
IGN="ign$RANDOM$RANDOM"
IGN_REMOTE="$WORK/$IGN-up.git"; git init -q --bare -b main "$IGN_REMOTE"
IGN_SEED="$WORK/$IGN-seed"; git init -q -b main "$IGN_SEED"
git -C "$IGN_SEED" config user.email t@t; git -C "$IGN_SEED" config user.name t
printf 'secret\n' > "$IGN_SEED/.gitignore"; echo a > "$IGN_SEED/f"
git -C "$IGN_SEED" add .gitignore f; git -C "$IGN_SEED" commit -qm base
git -C "$IGN_SEED" push -q "$IGN_REMOTE" HEAD:refs/heads/main
echo from-pr > "$IGN_SEED/secret"; git -C "$IGN_SEED" add -f secret
git -C "$IGN_SEED" commit -qm "track secret"
git -C "$IGN_SEED" push -q "$IGN_REMOTE" HEAD:refs/heads/feature/x
IGN_CLONE="$WORK/$IGN-clone"; git clone -q "$IGN_REMOTE" "$IGN_CLONE"   # at base
echo caller-private > "$IGN_CLONE/secret"              # ignored: porcelain empty
if env -i PATH="$REAL_GIT_DIR:$SYSPATH" HOME="$WORK" \
     REPO_DIR="$IGN_CLONE" BASE_REF=main HEAD_REF=feature/x MANAGED_CLONE=0 \
     "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; sync_repo_to_pr_head" >/dev/null 2>&1; then
  bad "--dir sync silently overwrote the caller's ignored file"
elif [[ "$(cat "$IGN_CLONE/secret")" == "caller-private" ]]; then ok
else bad "the checkout was rejected but the caller's ignored file was replaced"; fi

