---
name: ai-pr-review
description: Orchestrate the two-agent ai-pr-loop on a GitHub pull request or a GitLab merge request (gitlab.com or self-hosted). Use when the user asks to "review PR X", "review MR X", "run AI review on <PR/MR URL>", "kick off the review bots", or similar — the user wants Codex (reviewer) + Claude (implementer) to iterate on a PR/MR autonomously until convergence or approval. Posts comments and pushes commits under the user's forge identity (gh PAT / GitLab token).
argument-hint: "[pr-number or pr/mr-url] [--forge github|gitlab] [--host HOST] [--max N] [--converge N] [--restart] [--review-only] [--context-url URL] [--context TEXT] [--context-file FILE] [--claude-model MODEL] [--claude-effort LEVEL] [--claude-perms MODE] [--codex-model MODEL] [--codex-effort LEVEL] [--codex-tier TIER]"
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
# env -u matters: a raw `glab auth status` would send an ambient
# OAUTH_TOKEN / GITLAB_ACCESS_TOKEN to the host as its credential and
# report it as "logged in" — clear glab's token env overrides so the
# status reflects the host-scoped config the loop will actually use
# (an explicit GITLAB_TOKEN is fine to leave: it IS the supported path).
env -u OAUTH_TOKEN -u GITLAB_ACCESS_TOKEN -u GLAB_TOKEN \
  glab auth status --hostname <HOST> 2>&1 | head -3
command -v codex && codex --version 2>&1 | head -1
command -v claude && claude --version 2>&1 | head -1
# Validate and resolve the target through the orchestrator itself — this
# rejects malformed or hostile inputs (e.g. userinfo smuggled into the MR
# URL's authority) before any credential is used anywhere:
"$RUN_SH" <PR_OR_MR_URL or IID --repo SLUG --host HOST> --print-config
```

**Never build your own PAT-bearing curl (or raw `glab config get token`
lookup) in this preflight.** Hand-rolling the request would bypass the
orchestrator's safeguards: `validate_forge_authority` (a crafted MR URL
like `https://good.host@attacker.invalid/…` would send the token to the
attacker's host) and `glab_config_get` (an ambient `OAUTH_TOKEN` /
`GITLAB_ACCESS_TOKEN` in the environment would shadow the host's
configured PAT). `run.sh` performs the full validated preflight itself the
moment it starts — token resolution (env-isolated, host-scoped, rejecting
OAuth-backed glab sessions with instructions to set a `GITLAB_TOKEN` PAT)
and the MR fetch — and dies immediately with a clear message on any
failure, which the monitor in step 5 surfaces.

Bail if forge auth is bad, either CLI is missing, or `--print-config`
rejects the target. MR state (must be `opened`) is enforced by `run.sh`
itself at launch — treat an immediate exit with "MR is not open" /
"GitLab auth failed" / "OAuth-backed" as the preflight failure to report.

### 3. Confirm before posting

The loop writes to a live PR/MR: it will post comments and (via Claude)
push commits using the user's forge identity (gh PAT on GitHub, GitLab
token on GitLab). Always tell the user the exact identity and the PR/MR
URL, then ask for confirmation **unless they already authorized the run
explicitly** in the same conversation (e.g. "start the review", "kick it
off", "go", a previous run in this session). When in doubt, ask.

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

- Final status: `approved`, `converged_no_major`, `review_posted` (only
  with `--review-only`), `max_iterations_reached`, `codex_error`, or
  `claude_error`.
- Iter count + last codex `BLOCKER=… MAJOR=… NIT=…` counts.
- Wall time per iter (read from the timestamps in the log).
- PR URL so the user can audit.

Artifacts for each iteration live at
`$AI_PR_LOOP_HOME/state/<owner>__<name>/pr-<N>/iter-NN/`
(GitLab repos: `state/<host>__<slug...>/pr-<N>/iter-NN/`; prompts, agent
stdout/stderr, fetched thread, codex verdict file).

## Resumability

The loop is fully resumable across invocations. If a prior run hit `--max`
or died mid-iteration, just re-run the same `run.sh` command — the
orchestrator inspects the PR's existing AI comments and continues from
the high-water mark. Per-PR session ids for both agents are persisted in
`state/<owner>__<name>/pr-<N>/{claude.session.uuid,codex.session.id}`, so
agents keep their internal memory across re-runs too.

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
  `prompts/claude.md` mid-run. Re-tune them between runs, not during.
