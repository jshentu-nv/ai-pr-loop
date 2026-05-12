# AI PR loop

Two-agent autonomous PR review loop. Codex reviews; Claude responds (fix code
or push back); they iterate until Codex approves or the iteration cap is hit.

## Quick start

```bash
# Minimal: PR number + repo slug. The loop manages its own clone at
# ~/ai-pr-loop/checkouts/<owner>__<name>/, fetching the PR branch on each run.
~/ai-pr-loop/run.sh 20 --repo OWNER/NAME

# Uncapped, with convergence on 3 consecutive NIT-only iters:
~/ai-pr-loop/run.sh 20 --repo OWNER/NAME --max 0 --converge 3

# Point at an existing local clone instead of letting the loop manage one:
~/ai-pr-loop/run.sh 20 --repo OWNER/NAME --dir ~/src/some-checkout
```

It runs unattended end-to-end. Works on any GitHub repo the authenticated
`gh` user can access. Logs and per-iteration artifacts go to
`~/ai-pr-loop/state/<owner>__<name>/pr-<N>/iter-NN/`.

## How agents are distinguished

Both bots authenticate to GitHub using the same human PAT (whichever user
the local `gh` CLI is logged in as — the loop resolves the @handle at
startup via `gh api user`), so the loop tags every artifact in two ways:

| Signal | Codex Reviewer | Claude Implementer |
|---|---|---|
| Hidden HTML marker (orchestrator parses this) | `<!-- ai-loop:codex-reviewer iter=N -->` | `<!-- ai-loop:claude-implementer iter=N -->` |
| Visible label (humans read this) | `**[AI · Codex Reviewer · iteration N]**` | `**[AI · Claude Implementer · iteration N]**` |
| Git commit author (Claude only) | — | `claude-implementer (ai-bot) <claude-implementer+bot@users.noreply.github.com>` |

The HTML marker is always the first line of every comment — across both
surfaces the loop uses:

- **Summary issue-comments** (one per turn): high-level read, cross-cutting
  concerns, Codex's verdict line.
- **Inline review comments** (line-specific): Codex attaches each
  line-specific finding to the exact `path:line` via the `pulls/N/reviews`
  API, and Claude replies inline via `in_reply_to`.

`fetch_ai_thread` (in `lib/common.sh`) pulls both surfaces and emits NDJSON
tagged with `surface=issue|inline` plus `id`/`path`/`line`/`in_reply_to_id`.
Comments are never edited or resolved — humans do the final audit.

## Termination

The loop exits when one of:

- Codex prints `[CODEX_VERDICT: APPROVED]` → exit 0 (success).
- Iteration cap is hit (`--max`, default 6) → exit 1.
- Either agent's turn errors out → exit 1.

## Resume

`--max` counts iterations *this invocation*, so if you hit the cap without
agreement, **just re-run the same command**. On startup the orchestrator
inspects the PR's existing AI comments and continues from the high-water
mark:

| State on PR | Resume behavior |
|---|---|
| No AI comments | Fresh start — iter 1, codex first. |
| Both bots through iter K | Next round is iter K+1, codex first. |
| Codex iter K but no Claude reply (prior run died or hit max mid-round) | Run claude at iter K first, then continue from K+1. |

If codex's last verdict in local state was already `APPROVED`, the loop
exits 0 immediately rather than re-reviewing.

## What each turn does

**Codex turn (`codex_turn.sh`)**
1. Fetches the prior AI thread from GitHub (both surfaces).
2. Pulls the latest PR branch.
3. Runs `codex exec --dangerously-bypass-approvals-and-sandbox` with the
   prompt at `prompts/codex.md` (resumes the per-PR codex session if one
   exists, so Codex retains its own internal review memory across iters).
4. Codex reads the diff + thread, posts (a) inline review comments via
   `POST /pulls/N/reviews` for line-specific findings and (b) a tagged
   summary issue-comment with cross-cutting concerns + verdict, then
   prints a final `[CODEX_VERDICT: …]` line that the wrapper greps.

**Claude turn (`claude_turn.sh`)**
1. Fetches the AI thread; splits Codex's iteration N output into a summary
   file (`codex-review.md`) and an NDJSON of inline findings
   (`codex-inline.ndjson`).
2. Runs `claude -p --dangerously-skip-permissions` with the prompt at
   `prompts/claude.md` (resumes the per-PR claude session if one exists).
3. Claude either edits & commits with the bot identity (`git push origin
   <branch>`), or pushes back in writing — per issue.
4. Claude replies inline to each line-specific finding via `in_reply_to`,
   posts a tagged summary issue-comment indexing the round's response,
   then prints `[CLAUDE_TURN: COMPLETE]`.

## Notes

- Auth: requires `GH_TOKEN` (or `GITHUB_TOKEN`) with `repo` scope on the
  target repo, plus `codex login` and `claude` already authenticated.
- The `gh`-authenticated user's PAT is used for all GitHub mutations
  (comments + pushes). Don't run this on PRs you don't intend the bots to
  comment on or push to under that identity.
- Managed checkouts live at `~/ai-pr-loop/checkouts/<owner>__<name>/`
  (one clone per repo, shared across PRs). For concurrent loops on the
  same repo, pass `--dir` to point each loop at its own clone.
- Claude never force-pushes, amends, or rebases — only adds new commits to
  the PR head ref.
- All AI comments are preserved on the PR for human audit; nothing is
  resolved or deleted.
- Iteration artifacts (prompt, full stdout/stderr, fetched thread, codex
  review markdown) are kept under `state/.../iter-NN/` so you can replay
  any decision after the fact.
