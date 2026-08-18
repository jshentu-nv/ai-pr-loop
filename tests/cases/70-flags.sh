# --- run.sh flag validation ----------------------------------------------

t "run.sh: empty --claude-bin is rejected"
run_run_sh 1 --repo o/n --claude-bin ''
assert_dies_with "--claude-bin needs an executable"

t "run.sh: empty --codex-bin is rejected"
run_run_sh 1 --repo o/n --codex-bin ''
assert_dies_with "--codex-bin needs an executable"

t "run.sh: --claude-bin refuses the next flag as its value"
run_run_sh 1 --repo o/n --claude-bin --review-only
assert_dies_with "--claude-bin needs an executable"

t "run.sh: --codex-bin refuses the next flag as its value"
run_run_sh 1 --repo o/n --codex-bin --review-only
assert_dies_with "--codex-bin needs an executable"

t "run.sh: a bare option-like executable name requires a path spelling"
run_run_sh CLAUDE_BIN=-claude --repo o/n --print-config
assert_dies_with "--claude-bin executable must not begin with '-'"

t "run.sh: shell builtins are rejected as agent executables"
run_run_sh 1 --repo o/n --claude-bin eval
assert_dies_with "missing required command: eval"

t "run.sh: a command-shaped executable value is never shell-evaluated"
BIN_INJECTION_WITNESS="$WORK/bin-injection-ran"
run_run_sh 1 --repo o/n --codex-bin "codex;touch $BIN_INJECTION_WITNESS"
assert_dies_with "missing required command: codex;touch $BIN_INJECTION_WITNESS"
if [[ -e "$BIN_INJECTION_WITNESS" ]]; then
  bad "the executable override was evaluated as shell"
else
  ok
fi

t "run.sh: a missing custom executable fails preflight by its selected path"
MISSING_AGENT_BIN="$WORK/missing agent bin"
run_run_sh 1 --repo o/n --claude-bin "$MISSING_AGENT_BIN"
assert_dies_with "missing required command: $MISSING_AGENT_BIN"

t "run.sh: existing custom executables pass command preflight"
run_run_sh 1 --repo o/n --claude-bin "$ALT_CLAUDE" --codex-bin "$ALT_CODEX"
assert_dies_with "GH_TOKEN/GITHUB_TOKEN not set"

t "run.sh: empty --codex-effort is rejected"
run_run_sh 1 --repo o/n --codex-effort ''
assert_dies_with "--codex-effort needs a level"

t "run.sh: unknown --codex-effort is rejected"
run_run_sh 1 --repo o/n --codex-effort bogus
assert_dies_with "--codex-effort must be one of"

t "run.sh: unknown --claude-effort is rejected"
run_run_sh 1 --repo o/n --claude-effort bogus
assert_dies_with "--claude-effort must be one of"

t "run.sh: empty --claude-context-window is rejected"
run_run_sh 1 --repo o/n --claude-context-window ''
assert_dies_with "--claude-context-window"

t "run.sh: empty --codex-context-window is rejected"
run_run_sh 1 --repo o/n --codex-context-window ''
assert_dies_with "--codex-context-window"

t "run.sh: --claude-context-window refuses the next flag as its value"
run_run_sh 1 --repo o/n --claude-context-window --review-only
assert_dies_with "--claude-context-window"

t "run.sh: --codex-context-window refuses the next flag as its value"
run_run_sh 1 --repo o/n --codex-context-window --review-only
assert_dies_with "--codex-context-window"

t "run.sh: nonnumeric --claude-context-window is rejected"
run_run_sh 1 --repo o/n --claude-context-window huge
assert_dies_with "--claude-context-window must be"

t "run.sh: zero --codex-context-window is rejected"
run_run_sh 1 --repo o/n --codex-context-window 0
assert_dies_with "--codex-context-window must be"

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

# --- run.sh forge resolution (URL / --forge / --host) ----------------------
# --print-config reports the resolved forge line before any network access.

t "run.sh: github PR URL pins forge, repo, and number"
run_run_sh https://github.com/foo/bar/pull/42 --print-config
assert_prints 'forge: github host=github.com scheme=https repo=foo/bar pr=42'

# URL classification runs on the CANONICAL authority: equivalent spellings
# of the GitHub endpoint are github links, not unrecognized/GitLab.
t "run.sh: uppercase github URL classifies as github"
run_run_sh https://GITHUB.COM/foo/bar/pull/42 --print-config
assert_prints 'forge: github host=github.com scheme=https repo=foo/bar pr=42'

t "run.sh: default-port github URL classifies as github"
run_run_sh https://github.com:443/foo/bar/pull/42 --print-config
assert_prints 'forge: github host=github.com scheme=https repo=foo/bar pr=42'

t "run.sh: trailing-dot github URL classifies as github"
run_run_sh https://github.com./foo/bar/pull/42 --print-config
assert_prints 'forge: github host=github.com scheme=https repo=foo/bar pr=42'

t "run.sh: a redundant --host agreeing in another spelling is accepted"
run_run_sh https://gl.example/g/p/-/merge_requests/9 --host GL.EXAMPLE:443 --print-config
assert_prints 'forge: gitlab host=gl.example scheme=https repo=g/p pr=9'

t "run.sh: a genuinely different --host still conflicts with the URL"
run_run_sh https://gl.example/g/p/-/merge_requests/9 --host other.example --print-config
assert_dies_with "conflicts with the URL host"

t "run.sh: gitlab.com MR URL selects the gitlab forge (subgroups kept)"
run_run_sh https://gitlab.com/group/sub/proj/-/merge_requests/7 --print-config
assert_prints 'forge: gitlab host=gitlab.com scheme=https repo=group/sub/proj pr=7'

t "run.sh: self-hosted MR URL keeps its host"
run_run_sh https://gitlab-master.example.com/omniverse/kit/-/merge_requests/123 --print-config
assert_prints 'forge: gitlab host=gitlab-master.example.com scheme=https repo=omniverse/kit pr=123'

t "run.sh: MR URL with a trailing tab path still parses"
run_run_sh https://gitlab.com/g/p/-/merge_requests/5/diffs --print-config
assert_prints 'forge: gitlab host=gitlab.com scheme=https repo=g/p pr=5'

t "run.sh: legacy MR URL (no /-/) parses"
run_run_sh https://gitlab.example.com/g/p/merge_requests/6 --print-config
assert_prints 'forge: gitlab host=gitlab.example.com scheme=https repo=g/p pr=6'

t "run.sh: --host other than github.com implies gitlab"
run_run_sh 3 --repo g/sub/p --host gitlab.example.com --print-config
assert_prints 'forge: gitlab host=gitlab.example.com scheme=https repo=g/sub/p pr=3'

t "run.sh: bare number + --repo stays github on github.com"
run_run_sh 1 --repo o/n --print-config
assert_prints 'forge: github host=github.com scheme=https repo=o/n pr=1'

# Equivalent spellings of the supported GitHub endpoint must infer github,
# not gitlab, and normalize to the canonical host.
t "run.sh: --host GITHUB.COM infers github and canonicalizes"
run_run_sh 1 --repo o/n --host GITHUB.COM --print-config
assert_prints 'forge: github host=github.com scheme=https repo=o/n pr=1'

t "run.sh: --host github.com:443 with --forge github is accepted"
run_run_sh 1 --repo o/n --forge github --host github.com:443 --print-config
assert_prints 'forge: github host=github.com scheme=https repo=o/n pr=1'

t "run.sh: --host GITHUB.COM:443 infers github"
run_run_sh 1 --repo o/n --host GITHUB.COM:443 --print-config
assert_prints 'forge: github host=github.com scheme=https repo=o/n pr=1'

t "run.sh: --repo conflicting with the URL repo dies"
run_run_sh https://github.com/foo/bar/pull/42 --repo other/name --print-config
assert_dies_with "conflicts with the URL repo"

t "run.sh: --forge conflicting with the URL forge dies"
run_run_sh https://github.com/foo/bar/pull/42 --forge gitlab --print-config
assert_dies_with "conflicts with the URL"

t "run.sh: unrecognized URL dies"
run_run_sh https://example.com/not-a-pr --print-config
assert_dies_with "unrecognized PR/MR URL"

t "run.sh: unknown --forge is rejected"
run_run_sh 1 --repo o/n --forge sourcehut --print-config
assert_dies_with "--forge must be github or gitlab"

t "run.sh: self-hosted GitHub is rejected"
run_run_sh 1 --repo o/n --forge github --host ghe.example.com --print-config
assert_dies_with "self-hosted GitHub is not supported"

t "run.sh: gitlab preflight dies with guidance when no token resolves"
run_run_sh STUB_GLAB_NO_TOKEN=1 1 --repo g/p --forge gitlab
assert_dies_with "no GitLab token for gitlab.com"

t "run.sh: gitlab preflight resolves the token via glab and reaches MR fetch"
run_run_sh 1 --repo g/p --forge gitlab --dir "$WORK/glclone"
assert_dies_with "MR is not open"

t "run.sh: OAuth-backed glab session is rejected with guidance"
run_run_sh STUB_GLAB_OAUTH=true 1 --repo g/p --forge gitlab
assert_dies_with "OAuth-backed"

t "run.sh: explicit GITLAB_TOKEN bypasses the glab OAuth check"
run_run_sh GITLAB_TOKEN=pat STUB_GLAB_OAUTH=true 1 --repo g/p --forge gitlab --dir "$WORK/glclone-oauth"
assert_dies_with "MR is not open"

t "run.sh: ambient GLAB_IS_OAUTH2 cannot mask a stored OAuth session"
run_run_sh GLAB_IS_OAUTH2=false STUB_GLAB_OAUTH=true 1 --repo g/p --forge gitlab
assert_dies_with "OAuth-backed"

t "run.sh: ambient GITLAB_IS_OAUTH2 cannot mask a stored OAuth session"
run_run_sh GITLAB_IS_OAUTH2=false STUB_GLAB_OAUTH=true 1 --repo g/p --forge gitlab
assert_dies_with "OAuth-backed"

t "run.sh: ambient GLAB_TOKEN cannot shadow the host's configured PAT"
GLABTOK_HDR_LOG="$WORK/glabtok-hdr.log"
run_run_sh GLAB_TOKEN=glab-ambient CURL_HDR_LOG="$GLABTOK_HDR_LOG" 1 --repo g/p --forge gitlab --dir "$WORK/glclone-glabtok"
assert_dies_with "MR is not open"
t "run.sh: the PRIVATE-TOKEN sent is the config PAT, not the ambient GLAB_TOKEN"
if grep -q 'PRIVATE-TOKEN: stub-glab-token' "$GLABTOK_HDR_LOG" 2>/dev/null \
   && ! grep -q 'glab-ambient' "$GLABTOK_HDR_LOG" 2>/dev/null; then
  ok
else
  bad "ambient GLAB_TOKEN leaked into the API calls (hdrs: $(sort -u "$GLABTOK_HDR_LOG" 2>/dev/null | tr '\n' ' '))"
fi

t "run.sh: ambient OAUTH_TOKEN cannot shadow the host's configured PAT"
OAUTH_HDR_LOG="$WORK/oauth-hdr.log"
run_run_sh OAUTH_TOKEN=oauth-foreign CURL_HDR_LOG="$OAUTH_HDR_LOG" 1 --repo g/p --forge gitlab --dir "$WORK/glclone-shadow"
assert_dies_with "MR is not open"
t "run.sh: the PRIVATE-TOKEN sent is the config PAT, not the ambient OAuth token"
if grep -q 'PRIVATE-TOKEN: stub-glab-token' "$OAUTH_HDR_LOG" 2>/dev/null \
   && ! grep -q 'oauth-foreign' "$OAUTH_HDR_LOG" 2>/dev/null; then
  ok
else
  bad "ambient OAUTH_TOKEN leaked into the API calls (hdrs: $(sort -u "$OAUTH_HDR_LOG" 2>/dev/null | tr '\n' ' '))"
fi

t "run.sh: http MR URL preserves the scheme"
run_run_sh http://gl.example/g/p/-/merge_requests/9 --print-config
assert_prints 'forge: gitlab host=gl.example scheme=http repo=g/p pr=9'

t "run.sh: scheme-qualified --host implies gitlab and keeps http"
run_run_sh 3 --repo g/p --host http://gitlab.lab --print-config
assert_prints 'forge: gitlab host=gitlab.lab scheme=http repo=g/p pr=3'

t "run.sh: --host scheme conflicting with the URL scheme dies"
run_run_sh https://gl.example/g/p/-/merge_requests/9 --host http://gl.example --print-config
assert_dies_with "conflicts with the URL scheme"

# Authority validation: the resolved host goes verbatim into every curl
# target, so URL-grammar tricks (userinfo, paths) must die before any use —
# https://good.host@attacker.invalid/... would otherwise send the PAT to
# attacker.invalid.
t "run.sh: MR URL with userinfo in the authority is rejected (PAT exfiltration)"
run_run_sh 'https://gitlab.example.com@attacker.invalid/g/p/-/merge_requests/1' --print-config
assert_dies_with "invalid forge host"

t "run.sh: --host with userinfo is rejected"
run_run_sh 1 --repo g/p --host 'good.host@attacker.invalid' --print-config
assert_dies_with "invalid forge host"

t "run.sh: --host with a path is rejected"
run_run_sh 1 --repo g/p --host 'gl.example/evil' --print-config
assert_dies_with "invalid forge host"

t "run.sh: port-qualified --host passes validation"
run_run_sh 3 --repo g/p --host gitlab.lab:8929 --print-config
assert_prints 'forge: gitlab host=gitlab.lab:8929 scheme=https repo=g/p pr=3'

t "run.sh: bracketed IPv6 --host passes validation"
run_run_sh 3 --repo g/p --host '[::1]:8443' --print-config
assert_prints 'forge: gitlab host=[::1]:8443 scheme=https repo=g/p pr=3'

t "run.sh: underscore intranet hostname passes validation"
run_run_sh 3 --repo g/p --host gitlab_master.corp --print-config
assert_prints 'forge: gitlab host=gitlab_master.corp scheme=https repo=g/p pr=3'

t "run.sh: trailing-dot absolute FQDN passes validation and canonicalizes"
run_run_sh 3 --repo g/p --host gitlab.example.com. --print-config
assert_prints 'forge: gitlab host=gitlab.example.com scheme=https repo=g/p pr=3'

t "run.sh: --host github.com. infers github (absolute-FQDN spelling)"
run_run_sh 1 --repo o/n --host github.com. --print-config
assert_prints 'forge: github host=github.com scheme=https repo=o/n pr=1'

t "run.sh: --host github.com. with explicit --forge github is accepted"
run_run_sh 1 --repo o/n --forge github --host github.com. --print-config
assert_prints 'forge: github host=github.com scheme=https repo=o/n pr=1'

t "run.sh: http URL reaches the API on http (actual curl target)"
HTTP_CURL_LOG="$WORK/http-curl.log"
GLHTTP="$WORK/glclone-http"
git init -q "$GLHTTP" >/dev/null 2>&1
git -C "$GLHTTP" remote add origin http://gl.example/g/p.git
run_run_sh CURL_LOG="$HTTP_CURL_LOG" http://gl.example/g/p/-/merge_requests/9 --dir "$GLHTTP"
assert_dies_with "MR is not open"
t "run.sh: preflight /user call went over http"
if grep -q '^GET http://gl.example/api/v4/user' "$HTTP_CURL_LOG" 2>/dev/null; then
  ok
else
  bad "no http GET to /user recorded (log: $(head -3 "$HTTP_CURL_LOG" 2>/dev/null | tr '\n' ' '))"
fi

t "run.sh: managed gitlab checkout is namespaced by host"
run_run_sh https://gl.example/g/p/-/merge_requests/9 --print-config
assert_prints "dir: $ROOT/checkouts/gl.example__g__p"

# Default-port canonicalization: https://gl.example:443 IS https://gl.example
# — both spellings must resolve to one identity (host, checkout, state,
# marker), or re-invoking the same MR in the equivalent form would split
# its sessions/context/verdict across two state dirs.
t "run.sh: explicit https default port canonicalizes to the bare host"
run_run_sh https://gl.example:443/g/p/-/merge_requests/9 --print-config
assert_prints 'forge: gitlab host=gl.example scheme=https repo=g/p pr=9'
assert_prints "dir: $ROOT/checkouts/gl.example__g__p"

t "run.sh: explicit http default port canonicalizes to the bare host"
run_run_sh 3 --repo g/p --host http://gitlab.lab:80 --print-config
assert_prints 'forge: gitlab host=gitlab.lab scheme=http repo=g/p pr=3'

t "run.sh: a non-default port is preserved in the identity"
run_run_sh http://gitlab.lab:8929/g/p/-/merge_requests/9 --print-config
assert_prints 'forge: gitlab host=gitlab.lab:8929 scheme=http repo=g/p pr=9'
assert_prints "dir: $ROOT/checkouts/gitlab.lab:8929__g__p"

# Ports normalize NUMERICALLY: curl reaches the same endpoint for :0443
# and :443, so a leading-zero spelling must not fork the identity.
t "run.sh: leading-zero https default port canonicalizes to the bare host"
run_run_sh https://gl.example:0443/g/p/-/merge_requests/9 --print-config
assert_prints 'forge: gitlab host=gl.example scheme=https repo=g/p pr=9'
assert_prints "dir: $ROOT/checkouts/gl.example__g__p"

t "run.sh: leading-zero http default port canonicalizes to the bare host"
run_run_sh 3 --repo g/p --host http://gitlab.lab:080 --print-config
assert_prints 'forge: gitlab host=gitlab.lab scheme=http repo=g/p pr=3'

t "run.sh: leading-zero NON-default port normalizes its digits"
run_run_sh https://gl.example:08443/g/p/-/merge_requests/9 --print-config
assert_prints 'forge: gitlab host=gl.example:8443 scheme=https repo=g/p pr=9'

t "run.sh: pre-canonicalization port-spelled state refuses with migration guidance"
# State written by an earlier build under the ':443' spelling must not be
# silently orphaned (the approved-resume no-op depends on its verdict file).
# The tree is identified by its markers, not just its name.  is
# gitignored; the fixture is removed right after.
mkdir -p "$ROOT/state/gl.example:443__g__p/pr-9"
printf 'gitlab https://gl.example:443 g/p\n' > "$ROOT/state/gl.example:443__g__p/pr-9/.repo-slug"
run_run_sh https://gl.example:443/g/p/-/merge_requests/9 --print-config
rm -rf "$ROOT/state/gl.example:443__g__p"
assert_dies_with "pre-canonicalization spelling"

t "run.sh: the BARE spelling also refuses when legacy port-spelled state exists"
# The guard must be two-sided: a bare re-invocation would otherwise
# silently select a fresh bare-host tree and orphan the legacy one.
mkdir -p "$ROOT/state/gl.example:443__g__p/pr-9"
printf 'gitlab gl.example:443 g/p\n' > "$ROOT/state/gl.example:443__g__p/pr-9/.repo-slug"
run_run_sh https://gl.example/g/p/-/merge_requests/9 --print-config
rm -rf "$ROOT/state/gl.example:443__g__p"
assert_dies_with "pre-canonicalization spelling"

t "run.sh: legacy state keyed by a leading-zero spelling also refuses"
# A pre-normalization build keyed a ':0443'-spelled run verbatim; the
# guard discovers equivalent-spelling trees by scanning, so ANY re-entry
# spelling must refuse, not just the one that recreates the old name.
mkdir -p "$ROOT/state/gl.example:0443__g__p/pr-9"
printf 'gitlab https://gl.example:0443 g/p\n' > "$ROOT/state/gl.example:0443__g__p/pr-9/.repo-slug"
run_run_sh https://gl.example:0443/g/p/-/merge_requests/9 --print-config
rm -rf "$ROOT/state/gl.example:0443__g__p"
assert_dies_with "pre-canonicalization spelling"

t "run.sh: BARE invocation refuses a ':0443'-keyed legacy tree (reverse spelling)"
mkdir -p "$ROOT/state/gl.example:0443__g__p/pr-9"
printf 'gitlab https://gl.example:0443 g/p\n' > "$ROOT/state/gl.example:0443__g__p/pr-9/.repo-slug"
run_run_sh https://gl.example/g/p/-/merge_requests/9 --print-config
rm -rf "$ROOT/state/gl.example:0443__g__p"
assert_dies_with "pre-canonicalization spelling"

t "run.sh: bare HTTP invocation refuses a ':080'-keyed legacy tree"
mkdir -p "$ROOT/state/gitlab.lab:080__g__p/pr-9"
printf 'gitlab http://gitlab.lab:080 g/p\n' > "$ROOT/state/gitlab.lab:080__g__p/pr-9/.repo-slug"
run_run_sh http://gitlab.lab/g/p/-/merge_requests/9 --print-config
rm -rf "$ROOT/state/gitlab.lab:080__g__p"
assert_dies_with "pre-canonicalization spelling"

t "run.sh: canonical ':8443' invocation refuses an ':08443'-keyed legacy tree"
mkdir -p "$ROOT/state/gl.example:08443__g__p/pr-9"
printf 'gitlab https://gl.example:08443 g/p\n' > "$ROOT/state/gl.example:08443__g__p/pr-9/.repo-slug"
run_run_sh https://gl.example:8443/g/p/-/merge_requests/9 --print-config
rm -rf "$ROOT/state/gl.example:08443__g__p"
assert_dies_with "pre-canonicalization spelling"

t "run.sh: the canonical tree itself never triggers the guard (resume works)"
# The scan enumerates the canonical tree too; skipping it is load-bearing —
# without the skip, every resumed GitLab run would die on its own state.
mkdir -p "$ROOT/state/gl.example__g__p/pr-9"
printf 'gitlab https://gl.example g/p\n' > "$ROOT/state/gl.example__g__p/pr-9/.repo-slug"
run_run_sh https://gl.example/g/p/-/merge_requests/9 --print-config
rm -rf "$ROOT/state/gl.example__g__p"
assert_prints 'forge: gitlab host=gl.example scheme=https repo=g/p pr=9'

t "run.sh: a same-slug tree for an UNRELATED host never triggers the guard"
# The canon-equivalence filter is load-bearing too: gitlab.internal is not
# a spelling of gl.example, whatever its marker says.
mkdir -p "$ROOT/state/gitlab.internal__g__p/pr-9"
printf 'gitlab https://gitlab.internal g/p\n' > "$ROOT/state/gitlab.internal__g__p/pr-9/.repo-slug"
run_run_sh https://gl.example/g/p/-/merge_requests/9 --print-config
rm -rf "$ROOT/state/gitlab.internal__g__p"
assert_prints 'forge: gitlab host=gl.example scheme=https repo=g/p pr=9'

t "run.sh: a canonical http-on-443 tree is NOT mistaken for legacy https state"
# 443 is not http's default port, so state/gl.example:443__g__p with an
# http marker is another endpoint's canonical tree — a bare https run must
# leave it alone and proceed.
mkdir -p "$ROOT/state/gl.example:443__g__p/pr-9"
printf 'gitlab http://gl.example:443 g/p\n' > "$ROOT/state/gl.example:443__g__p/pr-9/.repo-slug"
run_run_sh https://gl.example/g/p/-/merge_requests/9 --print-config
rm -rf "$ROOT/state/gl.example:443__g__p"
assert_prints 'forge: gitlab host=gl.example scheme=https repo=g/p pr=9'

t "run.sh: stored PAT under the default-port glab key is found (port-spelled invocation)"
run_run_sh STUB_GLAB_TOKEN_HOST=gl.example:443 https://gl.example:443/g/p/-/merge_requests/9 --dir "$WORK/glclone-pk1"
assert_dies_with "MR is not open"

t "run.sh: stored PAT under the default-port glab key is found (bare invocation)"
run_run_sh STUB_GLAB_TOKEN_HOST=gl.example:443 https://gl.example/g/p/-/merge_requests/9 --dir "$WORK/glclone-pk2"
assert_dies_with "MR is not open"

t "run.sh: stored PAT under the exact leading-zero glab key is found"
# glab keys config by the exact login string; the invocation's original
# validated spelling must be probed alongside canonical + default twin.
run_run_sh STUB_GLAB_TOKEN_HOST=gl.example:0443 https://gl.example:0443/g/p/-/merge_requests/9 --dir "$WORK/glclone-pk3"
assert_dies_with "MR is not open"

t "run.sh: BARE invocation finds a PAT stored under a zero-padded key"
# Reverse spelling: login used ':0443', invocation is bare — the probe must
# enumerate every accepted zero-padded spelling of the endpoint's port.
run_run_sh STUB_GLAB_TOKEN_HOST=gl.example:0443 https://gl.example/g/p/-/merge_requests/9 --dir "$WORK/glclone-pk4"
assert_dies_with "MR is not open"

t "run.sh: canonical ':8443' invocation finds a PAT stored under ':08443'"
run_run_sh STUB_GLAB_TOKEN_HOST=gl.example:08443 https://gl.example:8443/g/p/-/merge_requests/9 --dir "$WORK/glclone-pk5"
assert_dies_with "MR is not open"

t "run.sh: uppercase MR URL canonicalizes to the lowercase identity"
run_run_sh https://GL.EXAMPLE/g/p/-/merge_requests/9 --print-config
assert_prints 'forge: gitlab host=gl.example scheme=https repo=g/p pr=9'
assert_prints "dir: $ROOT/checkouts/gl.example__g__p"

t "run.sh: PAT under a case-preserved port-spelled key is found from the bare uppercase URL"
# glab stores login spellings verbatim (case-preserved): the probe must
# enumerate the original-cased base's spellings, not just the lowercased
# canonical ones.
run_run_sh STUB_GLAB_TOKEN_HOST=GL.EXAMPLE:443 https://GL.EXAMPLE/g/p/-/merge_requests/9 --dir "$WORK/glclone-pk6"
assert_dies_with "MR is not open"

t "run.sh: PAT under a case-preserved bare key is found from the port-spelled URL"
run_run_sh STUB_GLAB_TOKEN_HOST=GL.EXAMPLE https://GL.EXAMPLE:443/g/p/-/merge_requests/9 --dir "$WORK/glclone-pk7"
assert_dies_with "MR is not open"

t "run.sh: LOWERCASE invocation discovers a PAT under an UPPERCASE stored key"
# Arbitrary case can't be enumerated — the probe falls back to discovering
# glab's configured host keys (from its config file) and matching their
# canonical authorities.
GLAB_CFG_FIX="$WORK/glab-cfg"
mkdir -p "$GLAB_CFG_FIX"
cat > "$GLAB_CFG_FIX/config.yml" <<'CFG'
git_protocol: ssh
hosts:
    gitlab.com:
        token:
    GL.EXAMPLE:
        token: from-config
CFG
run_run_sh GLAB_CONFIG_DIR="$GLAB_CFG_FIX" STUB_GLAB_TOKEN_HOST=GL.EXAMPLE https://gl.example/g/p/-/merge_requests/9 --dir "$WORK/glclone-pk8"
assert_dies_with "MR is not open"

t "config keys: discovery lists the exact stored spellings"
KEYS=$(env -i PATH="$STUBS:$SYSPATH" GLAB_CONFIG_DIR="$GLAB_CFG_FIX" "$BASH_BIN" -c \
  ". '$ROOT/lib/common.sh'; glab_config_host_keys" | tr '\n' ' ')
assert_eq "$KEYS" "gitlab.com GL.EXAMPLE "

t "config file: GLAB_CONFIG_DIR wins"
assert_eq "$(env -i PATH="$STUBS:$SYSPATH" GLAB_CONFIG_DIR=/x "$BASH_BIN" -c \
  ". '$ROOT/lib/common.sh'; glab_config_file")" "/x/config.yml"

t "config file: XDG default when glab is not a snap"
assert_eq "$(env -i PATH="$STUBS:$SYSPATH" XDG_CONFIG_HOME=/xdg "$BASH_BIN" -c \
  ". '$ROOT/lib/common.sh'; glab_config_file")" "/xdg/glab-cli/config.yml"

t "config file: snap-installed glab reads its remapped HOME"
# A shell function shadows the command builtin, faking a /snap/bin/glab.
assert_eq "$(env -i PATH="$STUBS:$SYSPATH" HOME=/h "$BASH_BIN" -c \
  ". '$ROOT/lib/common.sh'; command() { echo /snap/bin/glab; }; glab_config_file")" \
  "/h/snap/glab/current/.config/glab-cli/config.yml"

t "config file: the alternate snapd launcher layout is a snap too"
# Distributions without the /snap symlink launch from /var/lib/snapd/snap/bin.
assert_eq "$(env -i PATH="$STUBS:$SYSPATH" HOME=/h "$BASH_BIN" -c \
  ". '$ROOT/lib/common.sh'; command() { echo /var/lib/snapd/snap/bin/glab; }; glab_config_file")" \
  "/h/snap/glab/current/.config/glab-cli/config.yml"

t "config file: an existing legacy config wins over an XDG override (glab precedence)"
LEGACY_HOME="$WORK/legacy-home"
mkdir -p "$LEGACY_HOME/.config/glab-cli"
printf 'hosts:\n    GL.EXAMPLE:\n        token: legacy\n' > "$LEGACY_HOME/.config/glab-cli/config.yml"
assert_eq "$(env -i PATH="$STUBS:$SYSPATH" HOME="$LEGACY_HOME" XDG_CONFIG_HOME=/nonexistent-xdg "$BASH_BIN" -c \
  ". '$ROOT/lib/common.sh'; glab_config_file")" \
  "$LEGACY_HOME/.config/glab-cli/config.yml"

t "run.sh: discovery reads the legacy config when XDG points elsewhere"
# HOME is $WORK inside run_run_sh; seed the legacy location there, then
# remove it so later gitlab tests don't pick up its keys.
mkdir -p "$WORK/.config/glab-cli"
printf 'hosts:\n    GL.EXAMPLE:\n        token: legacy\n' > "$WORK/.config/glab-cli/config.yml"
run_run_sh XDG_CONFIG_HOME=/nonexistent-xdg STUB_GLAB_TOKEN_HOST=GL.EXAMPLE https://gl.example/g/p/-/merge_requests/9 --dir "$WORK/glclone-pk10"
rm -rf "$WORK/.config/glab-cli"
assert_dies_with "MR is not open"

t "config keys: discovery unwraps YAML-quoted IPv6 keys"
# glab serializes bracket keys quoted: '[ABCD::1]':
GLAB_CFG_V6="$WORK/glab-cfg-v6"
mkdir -p "$GLAB_CFG_V6"
cat > "$GLAB_CFG_V6/config.yml" <<'CFG'
hosts:
    '[ABCD::1]':
        token: from-config
    "[cafe::2]:8443":
        token: also
CFG
KEYS=$(env -i PATH="$STUBS:$SYSPATH" GLAB_CONFIG_DIR="$GLAB_CFG_V6" "$BASH_BIN" -c \
  ". '$ROOT/lib/common.sh'; glab_config_host_keys" | tr '\n' ' ')
assert_eq "$KEYS" "[ABCD::1] [cafe::2]:8443 "

t "run.sh: lowercase IPv6 invocation discovers the PAT under the quoted uppercase key"
run_run_sh GLAB_CONFIG_DIR="$GLAB_CFG_V6" STUB_GLAB_TOKEN_HOST='[ABCD::1]' 'https://[abcd::1]/g/p/-/merge_requests/9' --dir "$WORK/glclone-pk9"
assert_dies_with "MR is not open"

t "run.sh: --preflight-only reports identity, MR URL, and branches"
# Pre-clean so a guard regression in a previous suite run can't leave
# debris that fails the side-effect assertion below against fixed code.
rm -rf "$ROOT/state/gitlab.com__g__p" "$ROOT/checkouts/gitlab.com__g__p"
run_run_sh STUB_MR_OPEN=1 9 --repo g/p --forge gitlab --preflight-only
assert_prints 'identity: testuser'
assert_prints 'pr: https://gl.example/g/p/-/merge_requests/9'
assert_prints 'branches: main <- feat/x'

t "run.sh: --preflight-only creates no clone or state dir"
if [[ -e "$ROOT/checkouts/gitlab.com__g__p" || -e "$ROOT/state/gitlab.com__g__p" ]]; then
  bad "preflight-only left side effects on disk"
else
  ok
fi

t "run.sh: --preflight-only still dies on a non-open MR"
run_run_sh 9 --repo g/p --forge gitlab --preflight-only
assert_dies_with "MR is not open"

t "run.sh: managed github checkout keeps the legacy layout"
run_run_sh 1 --repo o/n --print-config
assert_prints "dir: $ROOT/checkouts/o__n"

# --print-config exposes run.sh's own resolution (not just the helper's), so
# these have teeth against run.sh regressing to a forced level.
t "run.sh: default knobs resolve to sol @ ultra on fast"
run_run_sh --repo o/n --print-config
assert_prints "claude-bin: $STUBS/claude"
assert_prints 'claude: model=fable effort=ultracode perms=auto context-window=unknown context-source=unknown'
assert_prints "codex-bin: $STUBS/codex"
assert_prints 'codex: model=gpt-5.6-sol effort=ultra tier=fast context-window=258400 context-source=catalog-estimate'

t "run.sh: explicit numeric context windows are reported verbatim"
run_run_sh --repo o/n --claude-context-window 200000 \
  --codex-context-window 131072 --print-config
assert_prints 'claude: model=fable effort=ultracode perms=auto context-window=200000 context-source=configured'
assert_prints 'codex: model=gpt-5.6-sol effort=ultra tier=fast context-window=131072 context-source=configured'

t "run.sh: print-config leaves Claude runtime discovery to the turn"
run_run_sh --repo o/n --claude-context-window auto \
  --codex-context-window auto --print-config
assert_prints 'claude: model=fable effort=ultracode perms=auto context-window=unknown context-source=unknown'
assert_prints 'codex: model=gpt-5.6-sol effort=ultra tier=fast context-window=258400 context-source=catalog-estimate'

t "run.sh: executable flags override environment defaults without splitting paths"
run_run_sh CLAUDE_BIN=env-claude CODEX_BIN=env-codex --repo o/n \
  --claude-bin "$ALT_CLAUDE" --codex-bin "$ALT_CODEX" --print-config
assert_prints "claude-bin: $ALT_CLAUDE"
assert_prints "codex-bin: $ALT_CODEX"

t "run.sh: relative executable paths are pinned to absolute paths"
TEST_CALLER_DIR=$PWD
cd "$ALT_BINS"
run_run_sh --repo o/n --claude-bin './claude custom' \
  --codex-bin './codex custom' --print-config
cd "$TEST_CALLER_DIR"
assert_prints "claude-bin: $ALT_CLAUDE"
assert_prints "codex-bin: $ALT_CODEX"

t "run.sh: executable environment overrides are used when flags are absent"
run_run_sh CLAUDE_BIN="$ALT_CLAUDE" CODEX_BIN="$ALT_CODEX" --repo o/n --print-config
assert_prints "claude-bin: $ALT_CLAUDE"
assert_prints "codex-bin: $ALT_CODEX"

t "run.sh: non-sol model resolves to adaptive off (no forced level)"
run_run_sh --repo o/n --codex-model gpt-oss-120b --print-config
assert_prints 'codex: model=gpt-oss-120b effort=off tier=fast context-window=131072 context-source=catalog-estimate'

t "run.sh: explicit effort wins through run.sh's resolution"
run_run_sh --repo o/n --codex-model gpt-oss-120b --codex-effort high --print-config
assert_prints 'codex: model=gpt-oss-120b effort=high tier=fast context-window=131072 context-source=catalog-estimate'

