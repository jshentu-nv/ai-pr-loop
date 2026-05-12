---
name: ai-pr-review
description: Orchestrate the two-agent ai-pr-loop on a GitHub pull request. Use when the user asks to "review PR X", "run AI review on <PR URL>", "kick off the review bots", or similar — the user wants Codex (reviewer) + Claude (implementer) to iterate on a PR autonomously until convergence or approval. Posts comments and pushes commits under the gh-authenticated user's PAT.
argument-hint: "[pr-number or pr-url] [--max N] [--converge N]"
allowed-tools: Bash, Read, Monitor
---

# AI PR Review

Drive the `ai-pr-loop` orchestrator (`run.sh`) end-to-end on behalf of the
user, then stream progress back into the conversation.

## What you're orchestrating

`ai-pr-loop` alternates two CLIs:

- **`codex exec`** as reviewer — reads the diff + prior thread, posts
  inline review comments via the GitHub reviews API for line-specific
  findings plus a summary issue-comment with a `[CODEX_VERDICT: …]` line.
- **`claude -p`** as implementer — replies inline to each finding,
  commits fixes under a bot git identity, pushes back when it disagrees.

Each agent's session persists across iterations (per-PR), so memory
accumulates round over round.

## Inputs

Parse the user's request into:

- `PR_NUMBER` — numeric PR id.
- `REPO_SLUG` — `OWNER/NAME`.

If the user pasted a URL like `https://github.com/foo/bar/pull/42`:
- `REPO_SLUG=foo/bar`, `PR_NUMBER=42`.

If only a bare number, ask the user for the repo slug — don't guess from cwd.

Optional flags worth surfacing if the user mentions a constraint:

- `--max N` — iteration cap *this invocation*. Default 6. Pass `0` for
  uncapped (hard ceiling 50). "Don't stop until they agree" → `--max 0`.
- `--converge N` — stop after N consecutive BLOCKER=0 MAJOR=0 codex iters.
  Default 3. Pass `0` to disable convergence-based termination.
- `--dir DIR` — use an existing local clone. Omit to let the loop manage
  its own at `$AI_PR_LOOP_HOME/checkouts/<owner>__<name>/`.

## Steps

### 1. Locate the orchestrator

Resolve the run script in this order:
1. `$AI_PR_LOOP_HOME/run.sh` if `AI_PR_LOOP_HOME` is set.
2. `$HOME/ai-pr-loop/run.sh`.
3. Anywhere else the user names.

If none exists, point the user at https://github.com/jshentu-nv/ai-pr-loop
and ask where they want it cloned. Do not silently clone for them.

### 2. Preflight

Run these checks in parallel and surface any failures **before** kicking off
the loop:

```bash
gh auth status 2>&1 | head -2
command -v codex && codex --version 2>&1 | head -1
command -v claude && claude --version 2>&1 | head -1
gh pr view <PR_NUMBER> --repo <REPO_SLUG> --json state,headRefName,title,url
```

Bail if `gh auth` is bad, either CLI is missing, or the PR isn't `OPEN`.

### 3. Confirm before posting

The loop writes to a live PR: it will post comments and (via Claude) push
commits using the gh-authed user's PAT. Always tell the user the exact
identity and the PR URL, then ask for confirmation **unless they already
authorized the run explicitly** in the same conversation (e.g. "start the
review", "kick it off", "go", a previous run in this session). When in
doubt, ask.

### 4. Launch in the background

```bash
"$RUN_SH" <PR_NUMBER> --repo <REPO_SLUG> --max <N> --converge <N>
```

Use the Bash tool with `run_in_background: true`. Note the returned task
ID and output file path — you'll need both for the monitor.

Each iteration can take 2–15 minutes depending on repo size and whether
the per-agent session is being resumed (cold codex run = slow; resumed =
fast). Don't poll synchronously; rely on the monitor.

### 5. Stream progress with a Monitor

Arm a persistent Monitor that tails the bg output file and emits one
event per high-signal line:

```bash
tail -F <BG_OUTPUT_FILE> 2>/dev/null \
  | grep -E --line-buffered \
      "Iteration |codex:|claude:|VERDICT|ISSUES|CLAUDE_TURN|convergence|approved|finished|ERROR|failed|exit "
```

Set `persistent: true` and a `timeout_ms` covering the expected run (e.g.
1 hour for a long loop). One event per iter boundary / verdict / issue
count / completion. Stop the monitor with TaskStop after the bg task
finishes.

### 6. Report the final state

When the background `run.sh` completes, summarize:

- Final status: `approved`, `converged_no_major`, `max_iterations_reached`,
  `codex_error`, or `claude_error`.
- Iter count + last codex `BLOCKER=… MAJOR=… NIT=…` counts.
- Wall time per iter (read from the timestamps in the log).
- PR URL so the user can audit.

Artifacts for each iteration live at
`$AI_PR_LOOP_HOME/state/<owner>__<name>/pr-<N>/iter-NN/`
(prompts, agent stdout/stderr, fetched thread, codex verdict file).

## Resumability

The loop is fully resumable across invocations. If a prior run hit `--max`
or died mid-iteration, just re-run the same `run.sh` command — the
orchestrator inspects the PR's existing AI comments and continues from
the high-water mark. Per-PR session ids for both agents are persisted in
`state/<owner>__<name>/pr-<N>/{claude.session.uuid,codex.session.id}`, so
agents keep their internal memory across re-runs too.

## Do not

- Edit, delete, or flip the resolved state on any PR comment. Humans
  audit; the bots only post.
- Run on PRs the user didn't intend the bots to act on under their PAT.
- Default to `--max 0` without warning the user. Uncapped runs can post
  many commits and many comments before reaching convergence.
- Try to "help" by editing the prompts in `prompts/codex.md` /
  `prompts/claude.md` mid-run. Re-tune them between runs, not during.
