# AI PR loop

Two-agent autonomous PR review loop, designed to be driven by an AI agent.
Codex reviews; Claude responds (fix code or push back); they iterate until
Codex approves or the loop converges on NIT-only findings.

The primary interface is a **Claude Code skill** (`ai-pr-review`) shipped
in this repo. Ask an AI agent to review a PR, the skill takes care of the
orchestration. The underlying `run.sh` is also runnable directly for
scripted use.

## Install

```bash
# 1. Clone somewhere stable.
git clone https://github.com/jshentu-nv/ai-pr-loop.git ~/ai-pr-loop

# 2. Expose the skill to Claude Code globally (so it's available from any
#    working directory, not just inside this clone).
mkdir -p ~/.claude/skills
ln -s ~/ai-pr-loop/.claude/skills/ai-pr-review ~/.claude/skills/ai-pr-review

# 3. Make the orchestrator findable. The skill checks $AI_PR_LOOP_HOME
#    first, then ~/ai-pr-loop. Either is fine.
echo 'export AI_PR_LOOP_HOME=$HOME/ai-pr-loop' >> ~/.bashrc
```

Requirements on the host:

- `gh` CLI authenticated (`gh auth login` or `GH_TOKEN`/`GITHUB_TOKEN`
  with `repo` scope on the target repo).
- `codex` CLI installed and logged in.
- `claude` CLI installed and logged in.
- `git`, `jq` available on `$PATH`.

No NVIDIA / org-specific config — works on any GitHub repo the
authenticated user can comment on and push to.

## Use it (the intended way)

In Claude Code, just ask:

> Review https://github.com/owner/repo/pull/42

> Run the AI review on PR 17 of owner/repo, don't stop until they agree.

> Kick off the review bots on this PR, max 4 iterations.

The `ai-pr-review` skill kicks in, parses the PR, preflights auth,
confirms before posting, launches the loop in the background, and streams
per-iteration progress (verdicts, issue counts, errors) back into the
conversation. When the loop terminates it reports the final verdict, the
per-iter wall time, and a link to the PR.

The agent will only act under your gh-authed identity, only on the PR you
named, and will ask you to confirm the first time it's about to post.

## What the agents do

**Codex Reviewer**

- Reads the PR's full discussion (issue comments, inline review comments,
  description, linked issues) plus the local diff and any callers/callees
  of changed code.
- Posts **inline review comments** at the exact `path:line` for
  line-specific findings via `POST /pulls/N/reviews` (one atomic review
  per turn).
- Posts a **summary issue-comment** with cross-cutting concerns + verdict.
- Marks fully-addressed prior threads with a one-line `Resolved.` reply
  (does *not* flip GitHub's resolved-thread state — that's left to humans).
- Emits `[CODEX_VERDICT: APPROVED|CHANGES_REQUESTED]` so the orchestrator
  can terminate.

**Claude Implementer**

- Reads Codex's inline + summary review.
- For each finding: either edits the code and commits under a bot git
  identity (`claude-implementer (ai-bot)
  <claude-implementer+bot@users.noreply.github.com>`) and pushes, or
  pushes back inline with reasoning.
- Replies inline to every finding via `in_reply_to`, posts a summary
  issue-comment, never force-pushes / amends / rebases.

Each agent keeps its own per-PR session (Claude `--session-id` / `--resume`,
Codex `exec resume`), so internal memory persists across iterations on top
of the publicly auditable PR thread.

## How agents are distinguished

Both bots post under the same human PAT (whichever account the local `gh`
is logged in as — resolved at startup via `gh api user`). The loop tags
every artifact three ways:

| Signal | Codex Reviewer | Claude Implementer |
|---|---|---|
| Hidden HTML marker (orchestrator parses) | `<!-- ai-loop:codex-reviewer iter=N -->` | `<!-- ai-loop:claude-implementer iter=N -->` |
| Visible banner | `**[AI · Codex Reviewer · iter N]**` | `**[AI · Claude Implementer · iter N]**` |
| Git commit author (Claude only) | — | `claude-implementer (ai-bot) <claude-implementer+bot@users.noreply.github.com>` |

`fetch_ai_thread` (in `lib/common.sh`) pulls both surfaces
(`/issues/N/comments` + `/pulls/N/comments`) and emits NDJSON tagged with
`surface=issue|inline` plus `id`, `path`, `line`, `in_reply_to_id`.
Comments are never edited or deleted by the bots.

## Termination

The loop exits when one of:

- Codex emits `[CODEX_VERDICT: APPROVED]` → exit 0.
- Codex reports `BLOCKER=0 MAJOR=0` for `--converge` consecutive iters
  (NIT-only, "converged_no_major") → exit 0.
- The iteration cap (`--max`) is hit → exit 1.
- Either agent's turn errors → exit 1.

## Resumability

`--max` counts iterations *this invocation*, so if you hit the cap
without agreement, **just re-run the same command** (or re-invoke the
skill). On startup the orchestrator inspects the PR's existing AI
comments and continues from the high-water mark:

| State on PR | Resume behavior |
|---|---|
| No AI comments | Fresh start — iter 1, codex first. |
| Both bots through iter K | Next round is iter K+1, codex first. |
| Codex iter K but no Claude reply | Run claude at iter K first, then continue from K+1. |

Per-PR session ids for both agents are stored under
`state/<owner>__<name>/pr-<N>/{claude.session.uuid,codex.session.id}`,
so resumed runs also restore the agents' internal memory.

## Direct CLI (advanced)

The skill is just a wrapper around `run.sh`. You can drive it directly:

```bash
# Minimal: PR number + repo slug. The loop manages its own clone at
# ~/ai-pr-loop/checkouts/<owner>__<name>/ (created on first use).
~/ai-pr-loop/run.sh 42 --repo owner/repo

# Uncapped, with convergence on 3 consecutive NIT-only iters:
~/ai-pr-loop/run.sh 42 --repo owner/repo --max 0 --converge 3

# Point at an existing local clone instead of letting the loop manage one:
~/ai-pr-loop/run.sh 42 --repo owner/repo --dir ~/src/some-checkout
```

Iteration artifacts (prompts, full stdout/stderr, fetched thread, codex
verdict, per-iter session captures) are kept under
`state/<owner>__<name>/pr-<N>/iter-NN/` so you can replay any decision
after the fact.

## Notes

- The gh-authed user's PAT is used for all GitHub mutations (comments +
  pushes). Don't run on PRs you don't intend the bots to act on under
  that identity.
- Claude never force-pushes, amends, or rebases — only adds new commits
  to the PR head ref.
- Managed checkouts live at `~/ai-pr-loop/checkouts/<owner>__<name>/`
  (one clone per repo, shared across PRs). For concurrent loops on the
  same repo, pass `--dir` to point each loop at its own clone.
- All AI comments are preserved on the PR for human audit; the bots do
  not delete or flip resolved state.
