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
- Before committing code changes, self-reviews this iteration's
  uncommitted diff with the `/code-review` skill and folds any valid
  findings into the same commit — catching its own bugs before they
  reach Codex.
- Replies inline to every finding via `in_reply_to`, posts a summary
  issue-comment, never force-pushes / amends / rebases.

Each agent keeps its own per-PR session (Claude `--session-id` / `--resume`,
Codex `exec resume`), so internal memory persists across iterations on top
of the publicly auditable PR thread.

## Additional context (web links, notes, files)

Both agents review the diff against the PR description and the repo's own
conventions. You can hand them **extra reference material** — a design doc,
an RFC, a related issue, an API reference, a style guide — and it's shared
by *both* the Codex Reviewer and the Claude Implementer:

```bash
# Attach web links (repeatable). The agents fetch them themselves
# (Claude via WebFetch, Codex via curl).
~/ai-pr-loop/run.sh 42 --repo owner/repo \
  --context-url https://example.com/design-doc \
  --context-url https://github.com/owner/repo/issues/123

# Free-text notes (repeatable) and a local file injected verbatim.
~/ai-pr-loop/run.sh 42 --repo owner/repo \
  --context "The auth flow must follow section 3 of the linked RFC." \
  --context-file ./docs/migration-plan.md
```

| Flag | Effect |
|---|---|
| `--context-url URL` | A web link. Repeatable. The agents fetch it. |
| `--context TEXT` | A free-text note. Repeatable. |
| `--context-file FILE` | A local file; its contents are injected verbatim. Read at launch, so the path needn't survive to later re-runs. Repeatable. |
| `--clear-context` | Drop context stored from a prior run on this PR. |

All inputs are rendered once to `state/<owner>__<name>/pr-<N>/context.md`,
whose path is injected into both prompts; each agent reads it (and fetches
any URLs) at the start of every turn. The material is treated as **trusted,
authoritative background** that supplements the PR description and repo
conventions. The agents fetch the URLs you provide under your `gh` identity,
so attach the references you want them to act on.

**Persistence.** Context is stored per-PR and survives re-runs: pass the
`--context*` flags once and every subsequent re-invocation (e.g. to grant
more `--max` iterations) reuses the same `context.md`. Pass any `--context*`
flag again to **replace** the stored context, or `--clear-context` to drop
it. (`--clear-context` is ignored when new `--context*` flags are also
given — those win.)

## Models & reasoning effort

Both agents run on a pinned model at high reasoning effort by default; you
can dial each one. All of these are passed explicitly on every turn (fresh
and resumed), so the loop doesn't silently depend on the host's global
`claude` settings or `~/.codex/config.toml`.

**Claude Implementer** — `claude -p` turns default to model **`fable`**
(Claude Fable 5; the alias resolves to the latest model in the claude CLI)
at effort **`ultracode`**: `xhigh` reasoning plus dynamic-workflow
orchestration (passed via `--settings '{"ultracode": true}'`, the documented
headless mechanism; it degrades to plain `xhigh` where orchestration doesn't
apply in `-p` mode). Dial with:

- `--claude-model MODEL` — passed as `--model`. Default `fable`; `off`
  leaves the CLI/settings default untouched.
- `--claude-effort LEVEL` — one of `ultracode` (default), `low`, `medium`,
  `high`, `xhigh`, `max`, or `off`.

**Codex Reviewer** — `codex exec` turns default to model **`gpt-5.6-sol`**
at reasoning effort **`ultra`** (the ceiling for gpt-5.6-sol/-terra; older
gpt-5.x models top out at `xhigh`) on the **`fast`** service tier (the
"Fast" speed tier: 1.5x speed, increased usage), applied as
`-m gpt-5.6-sol -c model_reasoning_effort=ultra -c service_tier=fast` on
every turn. Turns run with `--yolo` (autorun — the alias for
`--dangerously-bypass-approvals-and-sandbox`) so gh/git mutations proceed
unattended. Dial with:

- `--codex-model MODEL` — passed as `-m`. Default `gpt-5.6-sol`; `off`
  leaves the host's codex config untouched.
- `--codex-effort LEVEL` — one of `low`, `medium`, `high`, `xhigh`, `max`,
  `ultra`, or `off`. The default adapts to the model: `ultra` when the codex
  model is gpt-5.6-sol/-terra, `xhigh` for any other `--codex-model` (older
  gpt-5.x models reject `ultra`/`max` — the request 400s). An explicit level
  is passed verbatim.
- `--codex-tier TIER` — passed as `-c service_tier=TIER`. Default `fast`;
  `off` leaves the host's codex config untouched.

```bash
~/ai-pr-loop/run.sh 42 --repo owner/repo --claude-effort xhigh   # implementer: reasoning only, no orchestration
~/ai-pr-loop/run.sh 42 --repo owner/repo --codex-effort high     # reviewer: dial reasoning down
~/ai-pr-loop/run.sh 42 --repo owner/repo --codex-model gpt-5.5  # older reviewer model (effort auto-drops to xhigh)
~/ai-pr-loop/run.sh 42 --repo owner/repo \
  --claude-model off --claude-effort off \
  --codex-model off --codex-effort off --codex-tier off   # both: CLI/config defaults
```

The heavier levels are more thorough but cost more tokens and wall time per
iteration. Beyond the effort knob, the Codex review prompt itself runs a
self-check-before-posting pass, a severity rubric, and targeted
security/concurrency, breaking-change, and test-gap passes to keep findings
high-signal.

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
- A single codex turn completed under `--review-only` (status
  `review_posted` for CHANGES_REQUESTED, `approved` for APPROVED) → exit 0.
- The iteration cap (`--max`) is hit → exit 1.
- Either agent's turn errors → exit 1.

## Review-only mode

Pass `--review-only` to run a single Codex review turn and stop, without
ever running the Claude implementer. Useful when you want an AI review
posted on the PR but don't want auto-fixup commits.

- Implies `--max 1` and disables `--converge`.
- Both `APPROVED` and `CHANGES_REQUESTED` exit 0 — the goal is to post a
  review, not to converge.

### Codex review → human fix → codex re-review

The natural workflow for `--review-only` is:

1. Run `--review-only` once. Codex posts findings, exits 0 with status
   `review_posted`.
2. You push commits addressing the findings (no bot author).
3. Re-run the same `--review-only` command. Codex resumes its session,
   re-reads the prior thread, marks resolved findings with `Resolved.`,
   and either approves or re-raises what's still open. Iter increments
   to `last_codex+1` automatically.

A prior `APPROVED` still short-circuits a plain re-run; pass `--restart`
if you want a re-review on top of new commits after an approval. Codex's
per-PR session is reused across all re-runs, so it remembers the prior
discussion even though Claude is never invoked.

```bash
~/ai-pr-loop/run.sh 42 --repo owner/repo --review-only
# ... push fixes ...
~/ai-pr-loop/run.sh 42 --repo owner/repo --review-only   # codex iter 2
```

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
| Codex APPROVED at iter K, new commits since | Plain re-run is a no-op. Pass `--restart` to start a new round at iter K+1, codex first. |

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

# New commits landed after a prior APPROVED verdict — re-review them:
~/ai-pr-loop/run.sh 42 --repo owner/repo --restart

# Just post a review, don't auto-fix anything:
~/ai-pr-loop/run.sh 42 --repo owner/repo --review-only

# Attach reference material (web links / notes / a local file) for both agents:
~/ai-pr-loop/run.sh 42 --repo owner/repo \
  --context-url https://example.com/design-doc \
  --context "Must stay backward-compatible with the v1 API." \
  --context-file ./docs/spec.md

# Dial models / reasoning effort (defaults: implementer fable @ ultracode,
# reviewer gpt-5.6-sol @ ultra on the fast tier):
~/ai-pr-loop/run.sh 42 --repo owner/repo --claude-effort xhigh --codex-effort high
~/ai-pr-loop/run.sh 42 --repo owner/repo --codex-model gpt-5.5 --codex-tier off
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
