# --- prompt rendering ------------------------------------------------------
# The agent prompts are one source per agent, shared by every forge. These
# guard the split: a forge block that leaks (or silently vanishes) would ship
# an agent the wrong posting recipe, which no other test would catch.

assert_render_has()   { if grep -Fq -- "$2" <<<"$1"; then ok; else bad "render missing '$2'"; fi; }
assert_render_lacks() { if grep -Fq -- "$2" <<<"$1"; then bad "render leaked '$2'"; else ok; fi; }

render_fixture() {  # body on stdin -> rendered for forge $1
  local forge="$1" f="$WORK/frag.md"
  cat > "$f"
  render_forge_blocks "$f" "$forge"
}

t "render_forge_blocks: keeps the matching forge, drops the other"
_r=$(printf 'a\n{{#github}}\ngh-only\n{{/github}}\n{{#gitlab}}\nglab-only\n{{/gitlab}}\nz\n' \
     | render_fixture github)
assert_eq "$_r" "$(printf 'a\ngh-only\nz')"

t "render_forge_blocks: same template, other forge"
_r=$(printf 'a\n{{#github}}\ngh-only\n{{/github}}\n{{#gitlab}}\nglab-only\n{{/gitlab}}\nz\n' \
     | render_fixture gitlab)
assert_eq "$_r" "$(printf 'a\nglab-only\nz')"

t "render_forge_blocks: unclosed block is an error, not a silent truncation"
printf 'a\n{{#github}}\nx\n' > "$WORK/bad.md"
if render_forge_blocks "$WORK/bad.md" github >/dev/null 2>&1; then
  bad "unclosed block exited 0"; else ok; fi

t "render_forge_blocks: unmatched close is an error"
printf 'a\n{{/github}}\n' > "$WORK/bad.md"
if render_forge_blocks "$WORK/bad.md" github >/dev/null 2>&1; then
  bad "unmatched close exited 0"; else ok; fi

t "render_forge_blocks: crossed close markers are an error"
printf '{{#pr}}\n{{#github}}\nx\n{{/pr}}\n{{/github}}\n' > "$WORK/bad.md"
if render_forge_blocks "$WORK/bad.md" "pr github" >/dev/null 2>&1; then
  bad "crossed close markers exited 0"; else ok; fi

t "render_forge_blocks: a tag outside the vocabulary is an error, not a silent drop"
printf '{{#gitlba}}\nx\n{{/gitlba}}\n' > "$WORK/bad.md"
if render_forge_blocks "$WORK/bad.md" "gitlab pr" >/dev/null 2>&1; then
  bad "typo'd tag exited 0"; else ok; fi

t "render_forge_blocks: nested blocks keep the inner text only when both tags are active"
_frag=$(printf 'a\n{{#pr}}\npr\n{{#gitlab}}\nglab\n{{/gitlab}}\n{{#github}}\ngh\n{{/github}}\n{{/pr}}\n{{#branch}}\nbr\n{{/branch}}\nz\n')
_r=$(printf '%s\n' "$_frag" | render_fixture "local pr gitlab")
assert_eq "$_r" "$(printf 'a\npr\nglab\nz')"

t "render_forge_blocks: an inactive outer block drops its active inner block"
_r=$(printf '%s\n' "$_frag" | render_fixture "local branch")
assert_eq "$_r" "$(printf 'a\nbr\nz')"

t "prompt_tags: forge/local and pr/branch axes"
assert_eq "$(LOCAL_MODE=0 LOCAL_SCOPE=pr FORGE=gitlab prompt_tags)" 'forge pr gitlab'
assert_eq "$(LOCAL_MODE=1 LOCAL_SCOPE=pr FORGE=github prompt_tags)" 'local pr github'
assert_eq "$(LOCAL_MODE=1 LOCAL_SCOPE=branch FORGE=local prompt_tags)" 'local branch'

t "forge_vocab: github nouns"
FORGE=github REPO_SLUG=o/n PR_NUMBER=7 FORGE_HOST=github.com forge_vocab
assert_eq "$PR_NOUN|$SUMMARY_NOUN|$TOKEN_NOUN" 'PR|issue-comment|PAT'

t "forge_vocab: gitlab nouns"
FORGE=gitlab REPO_SLUG=g/s/p PR_NUMBER=7 FORGE_HOST=gl.example.com forge_vocab
assert_eq "$PR_NOUN|$SUMMARY_NOUN|$TOKEN_NOUN" 'MR|MR note|GitLab token'

t "forge_vocab: gitlab reference carries the host"
assert_eq "$PR_REF" '`g/s/p!7` on `gl.example.com`'

# Every combination the loop can run: exchange mode (forge | local) x scope
# (pr | branch) x forge. A block that leaks — or silently vanishes — would
# ship an agent the wrong contract, which no other test would catch.
for _agent in claude codex; do
  [[ "$_agent" == claude ]] && _tag=ai-loop:claude-implementer || _tag=ai-loop:codex-reviewer
  [[ "$_agent" == claude ]] && _artifact=claude-response.md || _artifact=codex-review.md
  for _tags in "forge pr github" "forge pr gitlab" \
               "local pr github" "local pr gitlab" "local branch"; do
    _out=$(render_forge_blocks "$ROOT/prompts/$_agent.md" "$_tags") || _out=''

    t "prompts/$_agent.md [$_tags]: renders and leaves no block markers"
    if [[ -n "$_out" ]] && ! grep -qE '\{\{[#/]' <<<"$_out"; then ok
    else bad "empty render or leftover {{#…}} markers"; fi

    t "prompts/$_agent.md [$_tags]: runtime-validation mandate survives"
    assert_render_has "$_out" 'A missing toolchain is not an excuse'

    t "prompts/$_agent.md [$_tags]: scope is based on changed behavior, not touched files"
    assert_render_has "$_out" 'touched file'

    t "prompts/$_agent.md [$_tags]: contract changes require producer-to-consumer analysis"
    assert_render_has "$_out" 'producer -> storage -> readers'

    t "prompts/$_agent.md [$_tags]: cleanup requires behavior comparison"
    if [[ "$_agent" == claude ]]; then
      assert_render_has "$_out" 'validation strictness'
    else
      assert_render_has "$_out" 'strictness, accepted layouts'
    fi

    if [[ "$_agent" == claude ]]; then
      t "prompts/claude.md [$_tags]: every changed path needs a scope reason"
      assert_render_has "$_out" '### Scope check'
      t "prompts/claude.md [$_tags]: staging is explicit and checked"
      assert_render_has "$_out" 'git diff --cached --name-status'
    else
      t "prompts/codex.md [$_tags]: review comments lead with impact"
      assert_render_has "$_out" 'a caller or user'
    fi

    t "prompts/$_agent.md [$_tags]: the CI policy matches the mode"
    # Forge mode reads the head's checks; local mode validates locally —
    # forge checks describe the remote head, not the unpushed rounds.
    case "$_tags" in
      forge*)
        assert_render_has  "$_out" 'CI is part of the review'
        assert_render_lacks "$_out" 'CI in a local review'
        ;;
      *)
        assert_render_has  "$_out" 'CI in a local review'
        assert_render_lacks "$_out" 'CI is part of the review'
        ;;
    esac

    case "$_tags" in
      forge*)
        t "prompts/$_agent.md [$_tags]: orchestrator's comment marker survives"
        assert_render_has "$_out" "$_tag"
        ;;
      *)
        t "prompts/$_agent.md [$_tags]: names the file that is the turn's contract"
        assert_render_has "$_out" "$_artifact"
        if [[ "$_agent" == codex ]]; then
          t "prompts/$_agent.md [$_tags]: reads the separate review scope report"
          assert_render_has "$_out" 'review-scope.md'
        fi
        t "prompts/$_agent.md [$_tags]: no comment-posting recipe survives"
        assert_render_lacks "$_out" 'gh pr comment'
        assert_render_lacks "$_out" 'gh api --method POST'
        assert_render_lacks "$_out" '/notes"'
        assert_render_lacks "$_out" 'in_reply_to'
        ;;
    esac

    case "$_tags" in
      forge*github)
        t "prompts/$_agent.md [$_tags]: no GitLab mechanics leak"
        assert_render_lacks "$_out" 'PRIVATE-TOKEN'
        t "prompts/$_agent.md [$_tags]: uses the gh CLI"
        assert_render_has "$_out" 'gh pr'
        ;;
      forge*gitlab)
        t "prompts/$_agent.md [$_tags]: no GitHub mechanics leak"
        assert_render_lacks "$_out" 'gh api'
        t "prompts/$_agent.md [$_tags]: uses curl with the token header"
        assert_render_has "$_out" 'PRIVATE-TOKEN'
        ;;
      local*github)
        t "prompts/$_agent.md [$_tags]: no GitLab mechanics leak"
        assert_render_lacks "$_out" 'PRIVATE-TOKEN'
        ;;
      local*gitlab)
        t "prompts/$_agent.md [$_tags]: no GitHub mechanics leak"
        assert_render_lacks "$_out" 'gh api'
        assert_render_lacks "$_out" 'gh pr'
        ;;
      *branch)
        t "prompts/$_agent.md [$_tags]: no forge mechanics at all"
        assert_render_lacks "$_out" 'PRIVATE-TOKEN'
        assert_render_lacks "$_out" 'gh pr'
        assert_render_lacks "$_out" 'gh api'
        assert_render_lacks "$_out" 'glab '
        ;;
    esac
  done
done

t "prompts/codex.md [local pr github]: keeps read-only PR access"
_out=$(render_forge_blocks "$ROOT/prompts/codex.md" "local pr github")
assert_render_has "$_out" 'gh pr view'
assert_render_has "$_out" 'Never write to it'

t "prompts/codex.md [local pr gitlab]: keeps read-only MR access"
_out=$(render_forge_blocks "$ROOT/prompts/codex.md" "local pr gitlab")
assert_render_has "$_out" 'PRIVATE-TOKEN'
assert_render_has "$_out" 'Never write to it'

t "prompts/claude.md [local pr *]: the implementer defers the title/description"
for _f in github gitlab; do
  _out=$(render_forge_blocks "$ROOT/prompts/claude.md" "local pr $_f")
  assert_render_has "$_out" 'Description drift'
done

# The finalize prompt exists only for local mode. squash composes the
# squashed commit's message; nocommit (nothing landed, PR/MR only) assesses
# just the title/description.
for _tags in "local pr github squash" "local pr gitlab squash" "local branch squash"; do
  _out=$(render_forge_blocks "$ROOT/prompts/finalize.md" "$_tags") || _out=''

  t "prompts/finalize.md [$_tags]: renders and leaves no block markers"
  if [[ -n "$_out" ]] && ! grep -qE '\{\{[#/]' <<<"$_out"; then ok
  else bad "empty render or leftover {{#…}} markers"; fi

  t "prompts/finalize.md [$_tags]: bans review churn from the message"
  assert_render_has "$_out" 'No churn from inside the review'

  t "prompts/finalize.md [$_tags]: demands the completion marker"
  assert_render_has "$_out" '[CLAUDE_FINALIZE: COMPLETE]'

  t "prompts/finalize.md [$_tags]: audits the review-created path set"
  assert_render_has "$_out" 'The scope report'

  case "$_tags" in
    *branch*)
      t "prompts/finalize.md [$_tags]: no title/description step without a PR/MR"
      assert_render_lacks "$_out" 'title and description true'
      ;;
    *)
      t "prompts/finalize.md [$_tags]: keeps the title/description step"
      assert_render_has "$_out" 'title and description true'
      ;;
  esac
done

for _tags in "local pr github nocommit" "local pr gitlab nocommit"; do
  _out=$(render_forge_blocks "$ROOT/prompts/finalize.md" "$_tags") || _out=''

  t "prompts/finalize.md [$_tags]: renders and leaves no block markers"
  if [[ -n "$_out" ]] && ! grep -qE '\{\{[#/]' <<<"$_out"; then ok
  else bad "empty render or leftover {{#…}} markers"; fi

  t "prompts/finalize.md [$_tags]: only assesses the title/description"
  assert_render_has "$_out" 'title and description true'
  assert_render_lacks "$_out" 'Write the message'

  t "prompts/finalize.md [$_tags]: demands the completion marker"
  assert_render_has "$_out" '[CLAUDE_FINALIZE: COMPLETE]'
done

t "prompts: the forked per-forge copies are gone"
if [[ -e "$ROOT/prompts/claude.gitlab.md" || -e "$ROOT/prompts/codex.gitlab.md" ]]; then
  bad "a *.gitlab.md prompt fork still exists"; else ok; fi

