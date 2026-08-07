---
name: ai-pr-review
description: Orchestrate the two-agent ai-pr-loop on a GitHub pull request or a GitLab merge request (gitlab.com or self-hosted), or locally on a branch. Use when the user asks to "review PR X", "review MR X", "run AI review on <PR/MR URL>", "kick off the review bots", "review this branch locally", or similar — the user wants Codex (reviewer) + Claude (implementer) to iterate autonomously until convergence or approval. Posts comments under the user's forge API identity (gh PAT / GitLab token); pushes commits through the checkout's git credential, which may be a different account. With --local it posts nothing and lands the whole review as one squashed commit.
argument-hint: "[pr-number or pr/mr-url] [--forge github|gitlab] [--host HOST] [--max N] [--converge N] [--restart] [--review-only] [--local] [--base REF] [--no-push] [--context-url URL] [--context TEXT] [--context-file FILE] [--claude-model MODEL] [--claude-effort LEVEL] [--claude-perms MODE] [--codex-model MODEL] [--codex-effort LEVEL] [--codex-tier TIER] [--auto-resume N] [--no-auto-resume] [--stop]"
allowed-tools: Bash, Read, Monitor
---

# AI PR Review

Drive the `ai-pr-loop` orchestrator (`run.sh`) end-to-end on behalf of the
user, then stream progress back into the conversation.

## What you're orchestrating

`ai-pr-loop` alternates two CLIs:

- **`codex exec`** as reviewer — reads the diff + prior thread, posts
  inline review comments for line-specific findings (GitHub reviews API /
  GitLab positioned discussions) plus a summary comment with a
  `[CODEX_VERDICT: …]` line.
- **`claude -p`** as implementer — replies inline to each finding,
  commits fixes under a bot git identity, pushes back when it disagrees.

Each agent's session persists across iterations (per-PR), so memory
accumulates round over round.

With `--local` the same two agents exchange the review through files
under the state dir instead of PR/MR comments, the implementer commits
without pushing, and when they agree a final `claude -p` turn composes one
commit message for the whole review — the orchestrator then squashes every
round into that single commit and pushes it.

## Inputs

Parse the user's request into:

- `PR_NUMBER` — numeric PR id (GitLab: the MR iid).
- `REPO_SLUG` — `OWNER/NAME` (GitLab: the full project path, subgroups
  included, e.g. `group/subgroup/project`).
- Forge — GitHub (default) or GitLab (`--forge gitlab`, plus
  `--host <hostname>` for self-hosted).

**If the user pasted a PR/MR URL, pass it straight through as the
positional argument** — `run.sh` derives forge, host, repo, and number
itself:
- `https://github.com/foo/bar/pull/42` → GitHub
- `https://<any-host>/<group>/<project>/-/merge_requests/7` → GitLab
  (gitlab.com or self-hosted; the host is kept)

If only a bare number, ask the user for the repo slug — don't guess from
cwd. For a GitLab repo given as slug + number, also pass
`--host <hostname>` (implies the gitlab forge) unless it's gitlab.com,
where `--forge gitlab` alone suffices.

Optional flags worth surfacing if the user mentions a constraint:

- `--max N` — iteration cap *this invocation*. Default 6. Pass `0` for
  uncapped (hard ceiling 50). "Don't stop until they agree" → `--max 0`.
- `--converge N` — stop after N consecutive BLOCKER=0 MAJOR=0 codex iters.
  Default 3. Pass `0` to disable convergence-based termination.
- `--dir DIR` — use an existing local clone. Omit to let the loop manage
  its own at `$AI_PR_LOOP_HOME/checkouts/<owner>__<name>/` (GitLab repos:
  `checkouts/<host>__<slug with / -> __>/`).
- `--restart` — force a new review round even if codex previously
  APPROVED. Use after new commits land past a prior approval ("pull
  latest and review again", "new commits were pushed, run another round").
  Starts at `max(last_codex,last_claude)+1`, codex first. Without it,
  the orchestrator short-circuits on the prior APPROVED verdict and
  exits immediately.
- `--review-only` — run a single codex review turn and exit; do *not*
  run the claude implementer. Use when the user wants AI feedback posted
  on the PR but no auto-fixups ("just review it, don't touch the code",
  "review only", "review without fixing"). Implies `--max 1`, disables
  `--converge`. Both APPROVED and CHANGES_REQUESTED exit 0 (the goal is
  to post a review, not converge). Final status will be `approved` or
  `review_posted`.

  **Re-review after human fixes.** A natural workflow is: user runs
  `--review-only`, pushes fixes themselves, re-runs `--review-only`.
  This is fully supported — codex resumes its session, sees the prior
  thread, marks resolved findings with `Resolved.`, and re-reviews the
  new HEAD at `last_codex+1`. If codex previously APPROVED, add
  `--restart` to force a fresh round.

- `--local` — keep the review off the forge and land **one** squashed
  commit instead of a comment thread and a chain of fixup commits. Use it
  when the user says "don't clutter the PR", "review it locally", "just
  one commit", "no bot comments", "squash the review into a single
  commit". Details:
  - No comments are posted. Reviews and responses are files under
    `state/<repo-ident>/<target>/iter-NN/`.
  - Rounds are committed locally and pushed only once, on agreement
    (`approved` / `converged_no_major`). The commit's message carries the
    review's findings, fixes, and decisions. A review that changes nothing
    (all findings answered by pushback, or edits that cancel out) lands no
    commit; the exchange files are its only record — say so when reporting.
  - A completed review is terminal: re-running exits without doing
    anything. `--restart` reviews the target as it now stands.
  - The push is fast-forward only. If the branch moved on the remote, the
    run fails with the squashed commit left in the checkout — report that
    to the user; never force-push on their behalf.
  - On a PR/MR, the forge is read-only for the whole review except that
    final push plus one title/description refresh if the change made them
    stale.
  - Hitting `--max` pushes nothing; the rounds stay in the checkout and
    the next invocation continues them. Say so when reporting.
- `--base REF` + no PR/MR — a **local review with no PR/MR at all**:
  reviews the branch `--dir` has checked out (default: cwd) against `REF`
  (`main`, `origin/main`, a tag, a SHA). Only valid with `--local`. Use
  when the user asks to review a local branch or work-in-progress that has
  no PR yet. No forge credential is used.
- `--no-push` — `--local` only: create the squashed commit but stop before
  pushing, for inspection ("let me look before it goes up"). Re-running
  without the flag pushes it without composing the message again.

- **Additional context** (shared by both agents) — when the user wants the
  bots to consider external reference material (a design doc, RFC, related
  issue, API reference, style guide), pass it through. Phrases like "review
  this against <link>", "here's the design doc: <url>", "keep <url> in mind",
  "use this spec". All are repeatable and shared by both Codex and Claude:
  - `--context-url URL` — a web link. The agents fetch it themselves
    (Claude via WebFetch, Codex via curl).
  - `--context TEXT` — a free-text note.
  - `--context-file FILE` — a local file injected verbatim (read at launch).
  - `--clear-context` — drop context stored from a prior run on this PR.

  Context is stored per-PR and **persists across re-runs**: pass the flags
  once and later re-invocations reuse it. Passing any `--context*` flag again
  replaces the stored context. If the user pastes a URL as "context" or
  "background" (not the PR URL itself), route it to `--context-url`.

  Context is treated as trusted, authoritative background by both agents, and
  they fetch the URLs under the user's `gh` identity. Only attach links/files
  the user actually asked for — don't infer context URLs from the surrounding
  conversation.

- `--claude-model MODEL` — model for the Claude implementer's turns, passed
  as `--model MODEL`. **Default `fable`** (Claude Fable 5). Set it only if
  the user names a different implementer model; `off` leaves the CLI/settings
  default untouched.
- `--claude-effort LEVEL` — reasoning effort for the Claude implementer's
  turns. **Default `ultracode`** (xhigh + dynamic-workflow orchestration). Set
  it if the user asks for lighter/heavier implementer reasoning or flags cost:
  `xhigh` (reasoning only), `max`, `high`, `medium`, `low`, or `off` (CLI
  default).
- `--claude-perms MODE` — permission handling for the implementer's headless
  turns. **Default `auto`** (`--permission-mode auto`: actions gated by the
  Claude Code auto-mode classifier; works where bypass is policy-disabled;
  where auto mode itself is unavailable — silently downgraded or rejected —
  a deterministic preflight probe / one-shot retry switches the turn to the
  settings safety net). `bypass` = `--dangerously-skip-permissions` + the
  settings safety net for hosts that silently downgrade bypass; `off` = host
  default. Only set it if the user explicitly asks for unsandboxed/bypass
  operation.
- `--codex-model MODEL` — model for the Codex reviewer's turns, passed as
  `-m MODEL`. **Default `gpt-5.6-sol`**. Set it only if the user names a
  different reviewer model; `off` leaves the host's codex config untouched.
- `--codex-effort LEVEL` — reasoning effort for the Codex reviewer's turns,
  applied as `-c model_reasoning_effort=LEVEL`. The default adapts to the
  model: **`ultra`** when the codex model is gpt-5.6-sol/-terra (the
  default); for any other `--codex-model` no level is forced — the host
  codex config / model default applies (ceilings vary per model). Levels:
  `low`, `medium`, `high`, `xhigh`, `max`, `ultra`, or `off` (leave the
  host's codex config untouched). Dial down if the user flags cost/latency.
- `--codex-tier TIER` — service (speed) tier for the Codex reviewer, applied
  as `-c service_tier=TIER`. **Default `fast`** (1.5x speed, increased
  usage); `off` leaves the host's codex config untouched.
- `--auto-resume N` — restart budget for the auto-resume supervisor.
  **Default 10.** The supervisor runs in its own session and relaunches the
  loop when a run dies without finishing — killed externally, or an agent
  turn that errored — resuming at the PR's high-water mark each time. A run
  that fails before it starts (bad flags, failed preflight) is not
  relaunched. Lower it if the user wants fewer automatic retries.
- `--no-auto-resume` — run the loop in the launched process with nothing
  supervising it. Use when the user wants a single attempt and no restarts
  ("just one run", "don't retry").
- `--stop` — write the stop sentinel for this PR and signal its supervisor,
  then exit. Use when the user says "stop the review", "cancel the bots" and
  the background task is gone or unresponsive. Runs no preflight and clones
  nothing, so it is safe to call at any time.

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
the loop.

GitHub:

```bash
gh auth status 2>&1 | head -2
command -v codex && codex --version 2>&1 | head -1
command -v claude && claude --version 2>&1 | head -1
gh pr view <PR_NUMBER> --repo <REPO_SLUG> --json state,headRefName,title,url
```

GitLab (self-hosted: substitute the host):

```bash
command -v glab && glab --version 2>&1 | head -1
command -v codex && codex --version 2>&1 | head -1
command -v claude && claude --version 2>&1 | head -1
# The orchestrator's own side-effect-free authenticated preflight: it
# validates the URL/authority (rejecting e.g. userinfo smuggling before
# any credential is used), resolves the credential exactly as the run
# will (env-isolated, OAuth-rejecting), fetches the MR, and prints the
# posting identity + canonical URL + branches — without cloning, posting,
# or looping:
"$RUN_SH" <PR_OR_MR_URL or IID --repo SLUG --host HOST> --preflight-only
```

The `identity:` line names the exact GitLab account behind every **API
call and comment**. Pushes are different: they go through the checkout's
own git credential (SSH key or credential helper — the non-interactive
push path the README requires), which can belong to another account.
Quote the `identity:` line verbatim in the step-3 confirmation as the
comment/API account, and say that pushes use the checkout's git
credential, which may differ.

**Run no glab auth commands and no PAT-bearing curl (nor a raw
`glab config get token` lookup) in this preflight.** Hand-rolled checks
keep diverging from the orchestrator's auth model: `glab auth status`
resolves its credential and OAuth-vs-PAT mode from ambient env and config
overrides, so it can report success for a session `run.sh` rejects (stored
OAuth masked by `GLAB_IS_OAUTH2=false`) or failure for one it supports
(explicit `GITLAB_TOKEN` treated as OAuth because the stored config says
`is_oauth2: true`). A hand-built curl would additionally bypass
`validate_forge_authority` (a crafted MR URL like
`https://good.host@attacker.invalid/…` would send the token to the
attacker's host) and `glab_config_get` (ambient `OAUTH_TOKEN` /
`GITLAB_ACCESS_TOKEN` shadowing the host's PAT). `--preflight-only` runs
the same authoritative preflight the loop itself uses — token resolution
(env-isolated, host-scoped, rejecting OAuth-backed glab sessions with
instructions to set a `GITLAB_TOKEN` PAT) plus the MR fetch — and dies
with the same clear messages on any failure.

Bail if either CLI is missing or `--preflight-only` fails: "invalid forge
host", "MR is not open", "GitLab auth failed", "no GitLab token", and
"OAuth-backed" are the failure messages to report to the user.

### 3. Confirm before posting

With `--local` there is less to confirm but it still ends in a push: say
that no comments will be posted, that the review lands as **one commit**
pushed through the checkout's git credential, and (on a PR/MR) that the
title/description may be refreshed once afterwards. With `--local --base`
and no PR/MR, no forge identity is involved at all — confirm the checkout,
the branch, and the base instead. `--no-push` means nothing leaves the
machine; say so.

The loop writes to a live PR/MR: it posts comments under the user's forge
API identity (gh PAT on GitHub, GitLab token on GitLab), and (via Claude)
pushes commits through the checkout's git credential. Always tell the
user the exact **comment/API identity** (GitHub: from `gh auth status`;
GitLab: the `identity:` line of `--preflight-only`) and the PR/MR URL,
noting that **pushes use the checkout's git credential (SSH key or
credential helper), which may belong to a different account** — then ask
for confirmation **unless they already authorized the run explicitly** in
the same conversation (e.g. "start the review", "kick it off", "go", a
previous run in this session). When in doubt, ask.

### 4. Launch in the background

```bash
"$RUN_SH" <PR_NUMBER> --repo <REPO_SLUG> --max <N> --converge <N>
# or, when the user gave a URL (works for GitHub and GitLab):
"$RUN_SH" <PR_OR_MR_URL> --max <N> --converge <N>
```

Append any context the user supplied, e.g.
`--context-url <url> --context "<note>" --context-file <path>` (repeatable;
shared by both agents). On a re-run to grant more iterations, omit them —
stored context is reused automatically.

Use the Bash tool with `run_in_background: true`. Note the returned task
ID and output file path — you'll need both for the monitor.

Each iteration can take 2–15 minutes depending on repo size and whether
the per-agent session is being resumed (cold codex run = slow; resumed =
fast). Don't poll synchronously; rely on the monitor.

A killed run resumes itself — when the supervisor is running. `run.sh`
starts a supervisor in its own session and tails its log, so the
background task's output is unchanged. If the task is reaped
(SIGTERM/SIGHUP), the supervisor keeps the review going and the loop
restarts from the PR's high-water mark — the background task ends, but
the review does not. Watch for `auto-resume:` lines to see restarts, and
read the final state from the PR thread or
`state/<ident>/pr-<N>/supervisor.log` when the task file stops growing. To
end such a run, call `run.sh <pr> --repo <slug> --stop`.

**Check the launch output for `auto-resume: disabled`.** On a host without
`setsid -f` (util-linux) or `perl` (no detached, reparented session), or
without `flock`/`perl` (no single-supervisor lock), `run.sh` prints that
warning and runs the loop inline in the background task itself. There is no supervisor: a reaped
task ENDS the review, and nothing restarts it. Treat task death as review
death in that case — re-run the same command to resume from the PR's
high-water mark.

### 5. Stream progress with a Monitor

Arm a persistent Monitor that tails the bg output file and emits one
event per high-signal line:

```bash
tail -F <BG_OUTPUT_FILE> 2>/dev/null \
  | grep -E --line-buffered \
      "Iteration |codex:|claude:|VERDICT|ISSUES|CLAUDE_TURN|convergence|approved|finished|ERROR|failed|exit |auto-resume"
```

Set `persistent: true` and a `timeout_ms` covering the expected run (e.g.
1 hour for a long loop). One event per iter boundary / verdict / issue
count / completion. Stop the monitor with TaskStop after the bg task
finishes.

**Relay each round's report as it lands.** Every turn ends by logging its
own summary — the reviewer's findings, the implementer's responses — and
saving it to `iter-NN/codex-report.md` / `iter-NN/claude-report.md`. The
announcement line

```
codex: iter 1 report (27 lines) -> …/iter-01/codex-report.md
```

fires one monitor event; the body follows it in the log between
`----- BEGIN … -----` / `----- END … -----`, deliberately untagged so it
does not flood the monitor. On that event, read the report and give the
user the substance of the round — findings and severities for a codex
turn, what was fixed and what was pushed back on for a claude turn. Do not
hand-fetch the PR comments for this; the loop already captured it. Say
plainly that the findings are the agent's, and that you have not verified
them yourself unless you actually did.

### 6. Report the final state

When the background `run.sh` completes, summarize:

- Final status: `approved`, `converged_no_major`, `review_posted` (only
  with `--review-only`), `max_iterations_reached`, `codex_error`,
  `claude_error`, or `finalize_error` (only with `--local`: the squash or
  the push failed; the rounds are still in the checkout).
- Iter count + last codex `BLOCKER=… MAJOR=… NIT=…` counts.
- Wall time per iter (read from the timestamps in the log).
- PR URL so the user can audit.
- With `--local`: the pushed commit's sha and subject (the `finalize:`
  lines in the log), or — when nothing was pushed — where the rounds are
  and what to run next.

Artifacts for each iteration live at
`$AI_PR_LOOP_HOME/state/<owner>__<name>/pr-<N>/iter-NN/`
(GitLab repos: `state/<host>__<slug...>/pr-<N>/iter-NN/`; prompts, agent
stdout/stderr, fetched thread, codex verdict file, `ci-status.md`, and each
turn's `codex-report.md` / `claude-report.md`).

Both agents see the head's CI status each turn. A check the loop's own
commits broke is a blocker the implementer fixes in the round it appears; a
check already red on the base is named as pre-existing and left alone. So
do not hand-fix CI for them mid-run, and do not treat a red check as a
reason to stop the loop — report it and let the next round address it.

## Resumability

The loop is fully resumable across invocations. If a prior run hit `--max`
or died mid-iteration, just re-run the same `run.sh` command — the
orchestrator inspects the PR's existing AI comments (with `--local`: the
review files under the state dir) and continues from the high-water mark.
A `--local` re-run also restores the earlier rounds' commits, which exist
only in the checkout — so re-run with the **same** `--dir`. Per-PR session ids for both agents are persisted in
`state/<owner>__<name>/pr-<N>/{claude.session.uuid,codex.session.id}`, so
agents keep their internal memory across re-runs too.

The auto-resume supervisor does that re-run for you (budget 10 by
default): an externally killed run, or a turn that errored, comes back on
its own. The supervisor stops for good on an end state
(`approved`, `converged_no_major`, `review_posted`,
`max_iterations_reached`), on a run that never got past
config/preflight, when the restart budget runs out, and on a deliberate
Ctrl-C or `--stop`. Granting more iterations after `max_iterations_reached`
is a manual re-run.

**Re-reviewing after approval.** If codex previously APPROVED and new
commits then land on the PR, a plain re-run short-circuits ("codex
already APPROVED at iter K — nothing to do"). Pass `--restart` to force
a new round on the new HEAD; the agents' sessions are still reused, so
they remember the prior discussion.

## Do not

- Edit, delete, or flip the resolved state on any PR comment. Humans
  audit; the bots only post.
- Run on PRs the user didn't intend the bots to act on under their PAT.
- Default to `--max 0` without warning the user. Uncapped runs can post
  many commits and many comments before reaching convergence.
- Try to "help" by editing the prompts in `prompts/codex.md` /
  `prompts/claude.md` / `prompts/finalize.md` mid-run. Re-tune them
  between runs, not during.
- Force-push, rebase, or "fix up" a `--local` run's rounds by hand. If the
  push was refused because the branch moved, report it and let the user
  decide.
