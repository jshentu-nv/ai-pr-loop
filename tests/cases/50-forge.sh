# --- gitlab forge plumbing -------------------------------------------------
# The gitlab path talks to /api/v4 via the curl stub: one summary note, one
# inline DiffNote thread with a reply, one system note, one human note.

# `export` so GH_USER reaches jq's env.GH_USER (the author filter); the
# other values are read as shell vars by the sourced functions either way.
GL_ENV='export FORGE=gitlab FORGE_HOST=gl.example PROJECT_ENC=g%2Fr REPO_SLUG=g/r PR_NUMBER=9 GITLAB_TOKEN=t GH_USER=testuser'

t "gitlab thread: maps discussions to the NDJSON schema (4 marked notes)"
GL_THREAD=$(env -i PATH="$STUBS:$SYSPATH" ITER=3 "$BASH_BIN" -c \
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

t "gitlab thread: a marked note on page 2 survives a clamped page size"
# The reader paginates until an EMPTY page: a short page 1 is not the
# end, and stopping there would drop this note entirely. The rc is
# asserted too — a reader that finds the notes but then walks to the
# page cap and fails would otherwise pass this test.
GLCT_RC=0
GLCT=$(env -i PATH="$STUBS:$SYSPATH" ITER=1 STUB_GL_CLAMPED_THREAD=1 "$BASH_BIN" -c \
  "$GL_ENV; . '$ROOT/lib/common.sh'; fetch_ai_thread" 2>/dev/null) || GLCT_RC=$?
GLCT_IDS=$(jq -r '.id' <<<"$GLCT" | tr -d '\r' | tr '\n' ' ')
if [[ "$GLCT_RC" == 0 && " $GLCT_IDS " == *" 201 "* && " $GLCT_IDS " == *" 202 "* ]]; then
  ok
else
  bad "clamped thread read failed (rc=$GLCT_RC ids: $GLCT_IDS)"
fi

t "gitlab thread: a failed later page yields no partial thread"
# Atomicity: the four page-1 notes must not escape when page 2 fails — a
# partial thread can carry a valid summary while missing the inline
# findings that lived on the failed pages.
FT_RC=0
FT_OUT=$(env -i PATH="$STUBS:$SYSPATH" ITER=1 STUB_GL_FAIL_PAGE2=1 \
  "$BASH_BIN" -c "$GL_ENV; . '$ROOT/lib/common.sh'; fetch_ai_thread" 2>/dev/null) || FT_RC=$?
if [[ "$FT_RC" != 0 && -z "$FT_OUT" ]]; then
  ok
else
  bad "partial thread escaped a failed page (rc=$FT_RC bytes=${#FT_OUT})"
fi

t "gitlab thread: a page that breaks the note mapping aborts the read"
# The buffering caller suppresses errexit inside the substitution, so the
# mapping jq's own guard is what keeps a bad page from being skipped.
FTB_RC=0
FTB_OUT=$(env -i PATH="$STUBS:$SYSPATH" ITER=1 STUB_GL_BAD_PAGE2=1 \
  "$BASH_BIN" -c "$GL_ENV; . '$ROOT/lib/common.sh'; fetch_ai_thread" 2>/dev/null) || FTB_RC=$?
if [[ "$FTB_RC" != 0 && -z "$FTB_OUT" ]]; then
  ok
else
  bad "a mapping-breaking page was skipped instead of aborting (rc=$FTB_RC bytes=${#FTB_OUT})"
fi

t "github thread: a failed second endpoint yields no partial thread"
FT2_RC=0
FT2_OUT=$(env -i PATH="$STUBS:$SYSPATH" ITER=1 GH_USER=testuser \
  REPO_OWNER=o REPO_NAME=r PR_NUMBER=1 FORGE=github STUB_GH_FAIL_PULLS=1 \
  "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; fetch_ai_thread" 2>/dev/null) || FT2_RC=$?
if [[ "$FT2_RC" != 0 && -z "$FT2_OUT" ]]; then
  ok
else
  bad "partial thread escaped a failed pulls endpoint (rc=$FT2_RC bytes=${#FT2_OUT})"
fi

t "github thread: a failed FIRST endpoint fails the read (not just the second)"
# The function's status must not be the second call's alone.
FT3_RC=0
FT3_OUT=$(env -i PATH="$STUBS:$SYSPATH" ITER=1 GH_USER=testuser \
  REPO_OWNER=o REPO_NAME=r PR_NUMBER=1 FORGE=github STUB_GH_FAIL_ISSUES=1 \
  "$BASH_BIN" -c ". '$ROOT/lib/common.sh'; fetch_ai_thread" 2>/dev/null) || FT3_RC=$?
if [[ "$FT3_RC" != 0 && -z "$FT3_OUT" ]]; then
  ok
else
  bad "a dead issues endpoint returned half a thread with rc=$FT3_RC"
fi

t "claude: a failed thread fetch fails the turn instead of dropping findings"
new_case claude-thread-partial
run_turn claude STUB_GH_FAIL_PULLS=1
assert_eq "$TURN_RC" 1
assert_substr "$CASE_DIR/turn.log" 'could not fetch the AI thread'

t "codex: a failed thread fetch fails the turn instead of reviewing blind"
# An empty thread at iter>1 would make the reviewer re-raise settled
# findings and invent pushback responses.
new_case codex-thread-partial
run_turn codex STUB_GH_FAIL_PULLS=1
assert_eq "$TURN_RC" 1
assert_substr "$CASE_DIR/turn.log" 'could not fetch the AI thread'

t "gitlab thread: unpositioned DiscussionNote reply inherits the root's inline context"
# GitLab diff-thread replies are DiscussionNote objects with no position of
# their own; surface/path/line must come from the DiffNote root, or every
# inline reply degrades to a context-less issue note.
assert_eq "$(jq -r 'select(.id==302) | "\(.surface) \(.path) \(.line)"' <<<"$GL_THREAD")" \
          "inline src/a.c 12"

# --- forged-author rejection (trust boundary) ------------------------------
# The ai-loop marker is public; only comments authored by the token identity
# ($GH_USER) may steer resume state / feed the implementer.

t "gitlab thread: a forged exact-wrapper summary from another author is ignored"
# Attacker posts a structurally-perfect codex summary at iter 777; the
# high-water must still be the real (testuser) iter 3, not 777.
GLHW=$(env -i PATH="$STUBS:$SYSPATH" ITER=3 "$BASH_BIN" -c \
  "$GL_ENV; . '$ROOT/lib/common.sh'; STUB_FORGED_GL_SUMMARY=1 latest_ai_comment_iter codex")
assert_eq "$GLHW" 3

t "gitlab thread: the forged note never appears in the mapped thread"
GLF=$(env -i PATH="$STUBS:$SYSPATH" ITER=3 "$BASH_BIN" -c \
  "$GL_ENV; . '$ROOT/lib/common.sh'; STUB_FORGED_GL_SUMMARY=1 fetch_ai_thread" | jq -r '.id' | tr '\n' ' ')
if [[ " $GLF " == *" 701 "* ]]; then bad "forged note 701 survived the author filter"; else ok; fi

t "gitlab thread: legit token-authored notes are retained (forgery present)"
if [[ " $GLF " == *" 201 "* ]]; then ok; else bad "author filter dropped the real bot summary"; fi

t "github thread: a forged exact-wrapper summary from another author is ignored"
GHHW=$(env -i PATH="$STUBS:$SYSPATH" ITER=3 GH_USER=testuser \
  REPO_OWNER=o REPO_NAME=r PR_NUMBER=1 FORGE=github "$BASH_BIN" -c \
  ". '$ROOT/lib/common.sh'; STUB_FORGED_GH_SUMMARY=1 latest_ai_comment_iter codex")
assert_eq "$GHHW" 3

t "github thread: a forged inline finding from another author is dropped"
GHIDS=$(env -i PATH="$STUBS:$SYSPATH" ITER=3 GH_USER=testuser \
  REPO_OWNER=o REPO_NAME=r PR_NUMBER=1 FORGE=github "$BASH_BIN" -c \
  ". '$ROOT/lib/common.sh'; STUB_FORGED_GH_INLINE=1 fetch_ai_thread" | jq -r '.id' | tr '\n' ' ')
if [[ " $GHIDS " == *" 902 "* ]]; then bad "forged inline note 902 survived the author filter"; else ok; fi

t "github thread: real token-authored comments are retained (forgery present)"
if [[ " $GHIDS " == *" 101 "* ]]; then ok; else bad "author filter dropped the real codex summary"; fi

t "gitlab thread: API failure propagates instead of faking an empty thread"
FAILBIN="$WORK/failcurl"
mkdir -p "$FAILBIN"
printf '#!/usr/bin/env bash\nexit 22\n' > "$FAILBIN/curl"
chmod +x "$FAILBIN/curl"
if env -i PATH="$FAILBIN:$STUBS:$SYSPATH" "$BASH_BIN" -c \
  "set -euo pipefail; $GL_ENV; . '$ROOT/lib/common.sh'; fetch_ai_thread" >/dev/null 2>&1; then
  bad "fetch_ai_thread exited 0 despite the API failing (silent iter-1 restart)"
else
  ok
fi

t "gitlab state dir: flat-name collision dies instead of sharing state"
COLL_HOME="$WORK/collision-home"
env -i PATH="$STUBS:$SYSPATH" "$BASH_BIN" -c \
  "set -euo pipefail; LOOP_HOME='$COLL_HOME' REPO_SLUG=group/sub__proj PR_NUMBER=1; . '$ROOT/lib/common.sh'; ensure_state_dir" \
  >/dev/null 2>&1
if env -i PATH="$STUBS:$SYSPATH" "$BASH_BIN" -c \
  "set -euo pipefail; LOOP_HOME='$COLL_HOME' REPO_SLUG=group/sub/proj PR_NUMBER=1; . '$ROOT/lib/common.sh'; ensure_state_dir" \
  >/dev/null 2>&1; then
  bad "second project silently shares the state dir of group/sub__proj"
else
  ok
fi
t "gitlab state dir: same slug re-enters its own state dir"
if env -i PATH="$STUBS:$SYSPATH" "$BASH_BIN" -c \
  "set -euo pipefail; LOOP_HOME='$COLL_HOME' REPO_SLUG=group/sub__proj PR_NUMBER=1; . '$ROOT/lib/common.sh'; ensure_state_dir" \
  >/dev/null 2>&1; then
  ok
else
  bad "re-run on the owning slug was rejected"
fi

# Forge/host identity: same-slug repos on different forges/hosts must never
# share state, checkouts, or clones.

t "state dir: gitlab identity is namespaced by host"
GLSD=$(env -i PATH="$STUBS:$SYSPATH" "$BASH_BIN" -c \
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
if env -i PATH="$STUBS:$SYSPATH" "$BASH_BIN" -c \
  "set -euo pipefail; LOOP_HOME='$SD_MIG' FORGE=gitlab FORGE_HOST=gl.example FORGE_SCHEME=https REPO_SLUG=g/p PR_NUMBER=9; . '$ROOT/lib/common.sh'; ensure_state_dir" \
  >"$WORK/sd-mig.out" 2>&1; then
  bad "pre-scheme marker silently adopted the invocation's scheme"
else
  if grep -q "migrate it explicitly" "$WORK/sd-mig.out"; then ok; else bad "refusal lacks migration guidance"; fi
fi
t "state dir: refused pre-scheme marker is left untouched"
assert_eq "$(cat "$SD_MIG/state/gl.example__g__p/pr-9/.repo-slug" 2>/dev/null)" "gitlab gl.example g/p"

t "state dir: same host under a different scheme dies (different endpoint)"
if env -i PATH="$STUBS:$SYSPATH" "$BASH_BIN" -c \
  "set -euo pipefail; LOOP_HOME='$WORK/sd-home' FORGE=gitlab FORGE_HOST=gl.example FORGE_SCHEME=http REPO_SLUG=g/p PR_NUMBER=2; . '$ROOT/lib/common.sh'; ensure_state_dir" \
  >/dev/null 2>&1; then
  bad "http target silently reused the https target's state dir"
else
  ok
fi

t "state dir: github keeps the legacy layout and marker format"
GHSD=$(env -i PATH="$STUBS:$SYSPATH" "$BASH_BIN" -c \
  "set -euo pipefail; LOOP_HOME='$WORK/sd-home' FORGE=github FORGE_HOST=github.com REPO_SLUG=o/r PR_NUMBER=1; . '$ROOT/lib/common.sh'; ensure_state_dir; printf '%s' \"\$STATE_DIR\"")
assert_eq "$GHSD" "$WORK/sd-home/state/o__r/pr-1"
assert_eq "$(cat "$WORK/sd-home/state/o__r/pr-1/.repo-slug" 2>/dev/null)" "o/r"

CLONE_FIX="$WORK/clone-host"
git init -q "$CLONE_FIX" >/dev/null 2>&1
git -C "$CLONE_FIX" remote add origin https://github.com/g/r.git

t "clone guard: same slug on a different forge/host is rejected"
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=gitlab FORGE_HOST=gl.example REPO_SLUG=g/r REPO_DIR='$CLONE_FIX'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  bad "github.com clone accepted for a gl.example repo of the same slug"
else
  ok
fi

t "clone guard: matching host re-enters its own clone"
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
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
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=gitlab FORGE_HOST=gitlab.lab:8929 FORGE_SCHEME=http REPO_SLUG=g/p REPO_DIR='$CLONE_PORT'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  ok
else
  bad "resume on a port-qualified host rejected its own clone"
fi

t "clone guard: http origin for an https target is a different endpoint"
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
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
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=github FORGE_HOST=github.com REPO_SLUG=g/r REPO_DIR='$CLONE_PUSH'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  bad "checkout with pushurl to evil.example accepted (push would deliver commits there)"
else
  ok
fi

t "clone guard: a matching explicit pushurl passes"
git -C "$CLONE_PUSH" remote set-url --push origin https://github.com/g/r.git
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
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
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
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
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
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
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
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
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
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
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
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
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=gitlab FORGE_HOST=gl.example REPO_SLUG=g/p REPO_DIR='$CLONE_CASE2'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  ok
else
  bad "uppercase ssh origin rejected for the lowercase host"
fi

t "clone guard: bracketed IPv6 scp origin passes for the IPv6 target"
CLONE_V6="$WORK/clone-v6"
git init -q "$CLONE_V6" >/dev/null 2>&1
git -C "$CLONE_V6" remote add origin 'git@[::1]:g/p.git'
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=gitlab FORGE_HOST='[::1]' REPO_SLUG=g/p REPO_DIR='$CLONE_V6'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  ok
else
  bad "IPv6 scp origin rejected for its own IPv6 target"
fi

t "clone guard: a DIFFERENT IPv6 scp origin is rejected (never an 'alias')"
# [::2] is simply another server than [::1] — an IP literal must not ride
# the dotless-ssh-alias leniency.
CLONE_V6X="$WORK/clone-v6x"
git init -q "$CLONE_V6X" >/dev/null 2>&1
git -C "$CLONE_V6X" remote add origin 'git@[::2]:g/p.git'
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=gitlab FORGE_HOST='[::1]' REPO_SLUG=g/p REPO_DIR='$CLONE_V6X'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  bad "origin [::2] accepted for target [::1] — wrong-instance push hole"
else
  ok
fi

t "clone guard: dotless decimal-IPv4 origin is rejected (never an 'alias')"
# 2130706433 == 127.0.0.1 — a resolvable endpoint in disguise, not a
# ~/.ssh/config alias.
CLONE_DEC="$WORK/clone-dec"
git init -q "$CLONE_DEC" >/dev/null 2>&1
git -C "$CLONE_DEC" remote add origin 'git@2130706433:g/p.git'
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=gitlab FORGE_HOST=gl.example REPO_SLUG=g/p REPO_DIR='$CLONE_DEC'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  bad "decimal-IPv4 origin accepted as an ssh alias"
else
  ok
fi

t "clone guard: hex-IPv4 origin is rejected"
CLONE_HEX="$WORK/clone-hex"
git init -q "$CLONE_HEX" >/dev/null 2>&1
git -C "$CLONE_HEX" remote add origin 'git@0x7f000001:g/p.git'
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=gitlab FORGE_HOST=gl.example REPO_SLUG=g/p REPO_DIR='$CLONE_HEX'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  bad "hex-IPv4 origin accepted as an ssh alias"
else
  ok
fi

t "clone guard: octal-IPv4 pushurl is rejected even with a clean fetch URL"
CLONE_OCT="$WORK/clone-oct"
git init -q "$CLONE_OCT" >/dev/null 2>&1
git -C "$CLONE_OCT" remote add origin https://gl.example/g/p.git
git -C "$CLONE_OCT" remote set-url --push origin 'git@017700000001:g/p.git'
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=gitlab FORGE_HOST=gl.example REPO_SLUG=g/p REPO_DIR='$CLONE_OCT'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  bad "octal-IPv4 pushurl accepted — commits would go to 127.0.0.1"
else
  ok
fi

t "clone guard: a numeric target matches its own numeric origin exactly"
CLONE_NUM="$WORK/clone-num"
git init -q "$CLONE_NUM" >/dev/null 2>&1
git -C "$CLONE_NUM" remote add origin 'git@2130706433:g/p.git'
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=gitlab FORGE_HOST=2130706433 REPO_SLUG=g/p REPO_DIR='$CLONE_NUM'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  ok
else
  bad "numeric origin rejected for its own numeric target"
fi

t "clone guard: a different ssh:// IPv6 origin is rejected too"
CLONE_V6Y="$WORK/clone-v6y"
git init -q "$CLONE_V6Y" >/dev/null 2>&1
git -C "$CLONE_V6Y" remote add origin 'ssh://git@[::2]:22/g/p.git'
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=gitlab FORGE_HOST='[::1]' REPO_SLUG=g/p REPO_DIR='$CLONE_V6Y'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  bad "ssh:// origin [::2] accepted for target [::1]"
else
  ok
fi

t "clone guard: ssh.github.com (SSH over 443) counts as github.com"
CLONE_SSHGH="$WORK/clone-sshgh"
git init -q "$CLONE_SSHGH" >/dev/null 2>&1
git -C "$CLONE_SSHGH" remote add origin 'ssh://git@ssh.github.com:443/g/r.git'
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
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
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
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
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
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
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=gitlab FORGE_HOST=gl.example REPO_SLUG=g/p REPO_DIR='$CLONE_FILE'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  bad "file:// origin accepted"
else
  ok
fi

t "clone guard: a checkout with no origin remote is rejected"
CLONE_NOREMOTE="$WORK/clone-noremote"
git init -q "$CLONE_NOREMOTE" >/dev/null 2>&1
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
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
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
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
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
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
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
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
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
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
if env -i PATH="$STUBS:$SYSPATH" HOME="$WORK" "$BASH_BIN" -c \
  "set -euo pipefail; FORGE=github FORGE_HOST=github.com REPO_SLUG=g/r REPO_DIR='$CLONE_ALIAS'; . '$ROOT/lib/common.sh'; ensure_repo_clone" \
  >/dev/null 2>&1; then
  ok
else
  bad "pre-existing ssh-alias --dir checkout rejected"
fi

t "gitlab post_ai_comment: POSTs a JSON note via curl with the marker"
PC_LOG="$WORK/post-comment.log"
env -i PATH="$STUBS:$SYSPATH" CURL_LOG="$PC_LOG" "$BASH_BIN" -c \
  "$GL_ENV; PR_NUMBER=4; . '$ROOT/lib/common.sh'; post_ai_comment codex 2 'hello'" >/dev/null 2>&1
if grep -q '^POST https://gl.example/api/v4/projects/g%2Fr/merge_requests/4/notes ' "$PC_LOG" 2>/dev/null; then
  ok
else
  bad "no POST to the notes endpoint recorded (log: $(cat "$PC_LOG" 2>/dev/null))"
fi
t "gitlab post_ai_comment: body carries the hidden marker"
if grep -q 'ai-loop:codex-reviewer iter=2' "$PC_LOG" 2>/dev/null; then ok; else bad "marker missing from POST body"; fi
t "gitlab post_ai_comment: helper-generated comments carry runtime metadata"
if grep -Fq "$CODEX_DEFAULT_SIGNATURE" "$PC_LOG" 2>/dev/null; then
  ok
else
  bad "runtime signature missing from POST body"
fi

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
t "codex gitlab: every finding, reply, and summary recipe carries the signature"
assert_count "$GL_PROMPT" "$CODEX_DEFAULT_SIGNATURE" 4
t "codex gitlab: signature placeholder is fully rendered"
if grep -qE '\{\{[^}]*SIGNATURE[^}]*\}\}' "$GL_PROMPT" 2>/dev/null; then
  bad "runtime-signature placeholder survived rendering"
else
  ok
fi

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
t "claude gitlab: both inline and summary reply recipes carry the signature"
assert_count "$GL_PROMPT" "$CLAUDE_DEFAULT_SIGNATURE" 2
t "claude gitlab: signature placeholder is fully rendered"
if grep -qE '\{\{[^}]*SIGNATURE[^}]*\}\}' "$GL_PROMPT" 2>/dev/null; then
  bad "runtime-signature placeholder survived rendering"
else
  ok
fi

t "claude gitlab: http scheme renders into the prompt API base"
new_case claude-gitlab-http
run_turn claude FORGE=gitlab FORGE_HOST=gl.example FORGE_SCHEME=http PROJECT_ENC=g%2Fr REPO_SLUG=g/r GITLAB_TOKEN=tok
assert_rc0
if grep -q 'http://gl.example/api/v4/projects/g%2Fr' "$CASE_DIR/state/iter-01/claude.prompt.md" 2>/dev/null; then
  ok
else
  bad "claude prompt API base not rendered with the http scheme"
fi

# --- malicious branch-name rendering (both renderers, both forges) ---------
# BASE_REF/HEAD_REF are forge metadata; a Git-valid branch name can carry
# sed/shell metacharacters (the payload below closes a `s|...|...|` and
# enables GNU sed's `e` flag, executing during rendering under the old
# substitution). The templates must reference the exported $HEAD_REF shell
# variable instead, so the payload never enters sed and never appears in the
# rendered prompt.
MALREF='x;printf${IFS}PROMPT_RENDER_EXECUTED>/dev/stderr;#|e;#'

check_malref_render() {  # <who> <prompt-file> [extra run_turn VAR=VALUE ...]
  local who="$1" pf="$2"; shift 2
  new_case "$who-malref-$RANDOM"
  run_turn "$who" "HEAD_REF=$MALREF" "$@"
  assert_rc0
  local rp="$CASE_DIR/state/iter-01/$pf"
  if grep -q 'PROMPT_RENDER_EXECUTED' "$CASE_DIR/turn.log" 2>/dev/null; then
    bad "$who: branch-name payload executed during rendering"
  elif grep -q 'PROMPT_RENDER_EXECUTED' "$rp" 2>/dev/null; then
    bad "$who: raw attacker branch value was substituted into the prompt"
  elif grep -q '\$HEAD_REF' "$rp" 2>/dev/null; then
    ok
  else
    bad "$who: rendered prompt does not reference \$HEAD_REF"
  fi
}

t "codex (github): a malicious branch name cannot inject via sed rendering"
check_malref_render codex codex.prompt.md
t "claude (github): a malicious branch name cannot inject via sed rendering"
check_malref_render claude claude.prompt.md
t "codex (gitlab): a malicious branch name cannot inject via sed rendering"
check_malref_render codex codex.prompt.md \
  FORGE=gitlab FORGE_HOST=gl.example PROJECT_ENC=g%2Fr REPO_SLUG=g/r GITLAB_TOKEN=tok
t "claude (gitlab): a malicious branch name cannot inject via sed rendering"
check_malref_render claude claude.prompt.md \
  FORGE=gitlab FORGE_HOST=gl.example PROJECT_ENC=g%2Fr REPO_SLUG=g/r GITLAB_TOKEN=tok

# --- refspec-safe, literal branch handling ---------------------------------
# A Git-valid branch like '+main' is read as a force-refspec ('+src'),
# '-f'/'@' are option-like/ambiguous to `git checkout`, and a branch named
# 'HEAD' aliases the origin/HEAD symref if fetched into refs/remotes/origin.
# So recipes fetch into private non-symbolic refs (refs/ai-pr-loop/*), detach
# onto the head (codex) / push HEAD:refs/heads/<ref> (claude), and diff
# refs/ai-pr-loop/base...HEAD; run.sh syncs via sync_repo_to_pr_head.

t "codex (github): fetch/checkout/diff recipes fully-qualify refs literally"
new_case codex-refspec-gh
run_turn codex
assert_rc0
CRP="$CASE_DIR/state/iter-01/codex.prompt.md"
assert_substr    "$CRP" 'git update-ref --no-deref -d "refs/ai-pr-loop/base"; git update-ref --no-deref -d "refs/ai-pr-loop/head"'
assert_substr    "$CRP" 'git fetch origin "+refs/heads/$BASE_REF:refs/ai-pr-loop/base" "+refs/heads/$HEAD_REF:refs/ai-pr-loop/head"'
assert_substr    "$CRP" 'git checkout --detach "refs/ai-pr-loop/head"'
assert_substr    "$CRP" 'git diff "refs/ai-pr-loop/base...HEAD"'
assert_no_substr "$CRP" 'git checkout "$HEAD_REF"'
assert_no_substr "$CRP" 'git fetch origin "$BASE_REF" "$HEAD_REF"'

t "codex (gitlab): fetch/checkout/diff recipes fully-qualify refs literally"
new_case codex-refspec-gl
run_turn codex FORGE=gitlab FORGE_HOST=gl.example PROJECT_ENC=g%2Fr REPO_SLUG=g/r GITLAB_TOKEN=tok
assert_rc0
CRP="$CASE_DIR/state/iter-01/codex.prompt.md"
assert_substr    "$CRP" 'git update-ref --no-deref -d "refs/ai-pr-loop/base"; git update-ref --no-deref -d "refs/ai-pr-loop/head"'
assert_substr    "$CRP" 'git checkout --detach "refs/ai-pr-loop/head"'
assert_substr    "$CRP" 'git diff "refs/ai-pr-loop/base...HEAD"'
assert_no_substr "$CRP" 'git checkout "$HEAD_REF"'

t "claude (github): push recipe fully-qualifies the destination ref"
new_case claude-refspec-gh
run_turn claude
assert_rc0
CRP="$CASE_DIR/state/iter-01/claude.prompt.md"
assert_substr    "$CRP" 'git push origin "HEAD:refs/heads/$HEAD_REF"'
assert_no_substr "$CRP" 'git push origin "$HEAD_REF"'

t "claude (gitlab): push recipe fully-qualifies the destination ref"
new_case claude-refspec-gl
run_turn claude FORGE=gitlab FORGE_HOST=gl.example PROJECT_ENC=g%2Fr REPO_SLUG=g/r GITLAB_TOKEN=tok
assert_rc0
CRP="$CASE_DIR/state/iter-01/claude.prompt.md"
assert_substr    "$CRP" 'git push origin "HEAD:refs/heads/$HEAD_REF"'
assert_no_substr "$CRP" 'git push origin "$HEAD_REF"'

t "run.sh: syncs via sync_repo_to_pr_head, not a bare best-effort pull"
if grep -Fq 'sync_repo_to_pr_head' "$ROOT/run.sh" \
   && ! grep -Fq 'git pull --ff-only --quiet origin "refs/heads/$HEAD_REF" || true' "$ROOT/run.sh" \
   && ! grep -Fq 'git checkout "$HEAD_REF"' "$ROOT/run.sh"; then
  ok
else
  bad "run.sh still uses a bare pull/checkout instead of the fail-closed sync"
fi

