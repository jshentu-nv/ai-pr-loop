# AI PR loop

Two-agent autonomous PR review loop, designed to be driven by an AI agent.
Codex reviews; Claude responds (fix code or push back); they iterate until
Codex approves or the loop converges on NIT-only findings.

By default the review happens **on the PR** — comments, replies, and one
commit per round. With `--local` it happens **entirely on disk** and lands
as a **single commit** carrying the review's findings and decisions; see
[Local review mode](#local-review-mode).

Works on **GitHub pull requests** and **GitLab merge requests** (gitlab.com
or self-hosted) — see [GitLab support](#gitlab-support).

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

- For GitHub repos: `gh` CLI authenticated (`gh auth login` or
  `GH_TOKEN`/`GITHUB_TOKEN` with `repo` scope on the target repo).
- For GitLab repos: `glab` CLI + `curl`, with `GITLAB_TOKEN` set or a
  PAT-backed `glab auth login --hostname <host>` done for the target host
  (the token needs `api` scope; OAuth web/device glab sessions are
  rejected — see [GitLab support](#gitlab-support)).
- Codex CLI installed and logged in (executable `codex` by default; select
  another name/path with `--codex-bin` or `CODEX_BIN`).
- Claude CLI installed and logged in (executable `claude` by default; select
  another name/path with `--claude-bin` or `CLAUDE_BIN`).
- `git`, `jq`, and either `setsid` or `perl` available on `$PATH`. The latter
  contains each metadata-control subprocess and its descendants so a killed
  or restarted turn cannot leave a CLI running in the checkout.

No NVIDIA / org-specific config — works on any GitHub/GitLab repo the
authenticated user can comment on and push to.

## Use it (the intended way)

In Claude Code, just ask:

> Review https://github.com/owner/repo/pull/42

> Review https://gitlab-master.example.com/group/project/-/merge_requests/17

> Run the AI review on PR 17 of owner/repo, don't stop until they agree.

> Kick off the review bots on this PR, max 4 iterations.

The `ai-pr-review` skill kicks in, parses the PR, preflights auth,
confirms before posting, launches the loop in the background, and streams
per-iteration progress (verdicts, issue counts, errors) back into the
conversation. When the loop terminates it reports the final verdict, the
per-iter wall time, and a link to the PR.

The agent only acts on the PR/MR you named, posting comments under your
forge API identity (gh PAT on GitHub, GitLab token on GitLab) and pushing
commits through the checkout's git credential (which may be a different
account), and will ask you to confirm the first time it's about to post.

### Controller safety for coding agents

The canonical controller skill is
`.agents/skills/ai-pr-review/SKILL.md`, so Codex discovers it from the
repository. Claude's `.claude/skills/ai-pr-review/SKILL.md` is a pointer to
that same procedure, and the root `AGENTS.md` makes reading it mandatory
before any loop action.

A coding agent must keep its conversation turn open until the review reaches
a terminal state and relay every completed Codex/Claude report. When its host
does not provide a persistent monitor tool, it uses:

- `agent_status.sh` to consume only new high-signal events and print complete
  saved turn reports; and
- `agent_guard.sh` to stop the review if the controlling conversation stops
  renewing its monitoring heartbeat.

This fail-closed path prevents a detached coding-agent turn from leaving an
expensive review running silently. It does not affect normal direct `run.sh`
usage by a human.

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

Under `--local` the same two agents do the same work, but the review is
written to files instead of comments, the implementer commits without
pushing, and a final turn composes one commit message for the whole review
— see [Local review mode](#local-review-mode).

## GitLab support

The loop runs on GitLab merge requests — gitlab.com or self-hosted — with
the same two agents, markers, verdicts, and resume behavior. Point it at an
MR URL and everything (forge, host, project, iid) is derived from the link:

```bash
~/ai-pr-loop/run.sh https://gitlab.com/group/subgroup/project/-/merge_requests/42

# Self-hosted:
~/ai-pr-loop/run.sh https://gitlab-master.example.com/omniverse/kit/-/merge_requests/123

# Or spell it out (numeric iid + project path + host):
~/ai-pr-loop/run.sh 123 --repo omniverse/kit --host gitlab-master.example.com
```

- `--forge gitlab` / `--host HOST` select the forge explicitly; a non-github
  `--host` implies GitLab on its own. Defaults: `github` / `gitlab.com`.
- `--repo` takes the **full project path**, subgroups included
  (`group/subgroup/project`).
- Auth: `GITLAB_TOKEN` env var wins; otherwise the token is read from the
  glab config for that host (`glab auth login --hostname <host>`,
  authenticated **with a personal access token** — OAuth web/device glab
  sessions are rejected at preflight, because their tokens are only valid
  as a `Bearer` header and expire mid-loop while everything here sends
  `PRIVATE-TOKEN`). The token needs `api` scope, plus push access to the
  MR's source branch. `GITLAB_TOKEN` is the **only** environment credential
  honored: glab's other token env vars (`GITLAB_ACCESS_TOKEN`,
  `OAUTH_TOKEN`, `GLAB_TOKEN`) and its config-override vars for the keys
  the loop reads (`GLAB_IS_OAUTH2`, `GITLAB_IS_OAUTH2`) are explicitly
  cleared when reading the glab config, so an ambient token minted for some
  other host can't masquerade as this host's PAT and an ambient override
  can't mask an OAuth session.
- All GitLab REST calls — the orchestrator's and the agents' — go through
  `curl` with a `PRIVATE-TOKEN` header, **not** `glab api`: `glab api`
  silently drops `position[...]` payloads when posting inline (line-anchored)
  MR discussions (the comment lands as a general note with HTTP 200) and
  rejects `--input` JSON bodies. `glab` is used only for token resolution,
  the initial clone, and read-only `mr view`.
- Inline findings post as positioned discussions
  (`POST /projects/:id/merge_requests/:iid/discussions` with
  `diff_refs`-based positions); replies thread via
  `POST .../discussions/:discussion_id/notes`. The bots never flip a
  thread's resolved state — a `Resolved.` reply is the signal, humans
  resolve.
- Pushes go to `origin/<source_branch>` of the same project; **cross-fork
  MRs are not supported** (the loop refuses them at startup).
- Clones use `glab repo clone`, which follows your glab `git_protocol`
  (ssh or https). Make sure a non-interactive push path exists for that
  host — ssh keys or a git credential helper — since the Claude implementer
  pushes headlessly.
- The GitLab token is exported into both agents' environments as
  `GITLAB_TOKEN` (they post their own comments with it), same trust model
  as `GH_TOKEN` on the GitHub path.
- HTTP-only self-hosts work: the scheme of the MR URL (or of
  `--host http://gitlab.lab`) is preserved through every orchestrator API
  call and both agents' prompts; the default is https. Pass the URL (or the
  scheme-qualified `--host`) on re-runs too — the scheme isn't persisted.
  First-use managed clones of an HTTP-only host use plain
  `git clone http://…` (glab can't be steered to HTTP), so a private repo
  needs ambient git credentials for that host — the same requirement as
  the loop's headless pushes. For HTTP(S) origins the checkout guard
  matches the **full endpoint** (`scheme://host:port`, default ports
  collapsed — `http://gl.example` and `https://gl.example` are different
  endpoints), and it validates **every fetch and push URL** of `origin`
  (a divergent `remote.origin.pushurl` would otherwise deliver the
  implementer's commits elsewhere). A `--dir` clone whose origin uses a
  different name for the same instance (e.g. a search-domain short name
  like `http://gitlab/…`) is rejected — point the remote at the canonical
  authority the MR URL uses. The scheme is part of the stored per-PR
  identity marker too. A glab `api_host`/`api_protocol` config
  pointing the API at a *different* host than the web UI is not supported;
  the API is always `<scheme>://<MR host>/api/v4`.

Terminology mapping, everywhere in state paths and logs: PR == MR, the PR
number == the MR iid. State lives at
`state/<host>__<group>__<subgroup>__<project>/pr-<iid>/` and managed clones
at `checkouts/<host>__<group>__<subgroup>__<project>/` — GitLab identities
are namespaced by host so a same-slug repo on another forge/host can never
share a checkout, state, or agent sessions (GitHub keeps the legacy
`<owner>__<name>` layout).

## Additional context and review constraints

Both agents review the diff against the PR description and the repo's own
conventions. You can hand them **extra reference material or constraints** —
a design doc, an RFC, a related issue, an API reference, a style guide, a
scope limit, or a comment-writing rule — and it is shared by *both* the Codex
Reviewer and the Claude Implementer:

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

The prompts treat these constraints as part of the review contract. In
particular, the agents must distinguish broad inspection from narrow edit
scope: a touched file is not, by itself, permission to fix a pre-existing
problem in that file.

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

## Agent executables, models, context & reasoning effort

The executable names are configurable independently of the model knobs:

- `--claude-bin EXECUTABLE` / `CLAUDE_BIN` selects the Claude CLI.
- `--codex-bin EXECUTABLE` / `CODEX_BIN` selects the Codex CLI.

The flag wins over its environment variable; defaults are `claude` and
`codex`. `EXECUTABLE` may be an external program name on `PATH` or a path;
the selected file is resolved once to an absolute path before the loop enters
the reviewed checkout. Shell functions and builtins are not accepted. It is
always treated as exactly one executable—not split or evaluated as shell—so
use a wrapper script if the command needs fixed extra arguments. A bare name
beginning with `-` must be spelled as a path (for example,
`/opt/bin/-claude`). Alternate executables must implement the corresponding
Claude Code or Codex CLI/session interface, including Claude's stream-json
control requests or Codex's app-server/config and active-model-catalog
commands when runtime signatures are enabled. A Codex wrapper may add a global
flag that Codex allows only for runtime commands — `--profile` is one — which
makes those two commands unusable. The loop then starts one `codex exec`
session whose provider is a closed loopback port: Codex records the resolved
model, effort, and effective window before its first request, so the request
fails at once and no prompt reaches a provider. That session file is removed
again. Note that this reports a fresh session, so a resumed thread pinned to
another model is covered only while the loop passes its own model every turn.

Both agents run on a pinned model at high reasoning effort by default; you
can dial each one. Every knob is passed explicitly on every turn (fresh and
resumed), so the loop doesn't silently depend on the host's global `claude`
settings or `~/.codex/config.toml` — with one deliberate exception: the
codex reasoning effort is pinned only when the loop knows the model's
ceiling (gpt-5.6-sol/-terra, or an explicit `--codex-effort`); for other
models no level is forced, so the host codex config / model default applies.

**Claude Implementer** — `claude -p` turns default to model **`fable`**
(Claude Fable 5; the alias resolves to the latest model in the claude CLI)
at effort **`ultracode`**: `xhigh` reasoning plus dynamic-workflow
orchestration (passed via `--settings '{"ultracode": true}'`, the documented
headless mechanism; it degrades to plain `xhigh` where orchestration doesn't
apply in `-p` mode). Dial with:

- `--claude-model MODEL` — passed as `--model`. Default `fable`; `off`
  leaves the CLI/settings default untouched.
- `--claude-context-window TOKENS|auto` — context-window size reported in
  Claude's forge-comment signature. `auto` (default) runs a control-only
  stream-json handshake with the exact executable, session, model, effort,
  permission, and settings arguments for that turn. `get_settings` supplies
  the applied model, effort, and ultracode state; `get_context_usage` supplies
  the effective window. This includes aliases, host defaults, and resumed
  sessions, sends no user message, and starts no model request. An explicit
  token count skips only the context query for wrapper/custom CLIs that still
  implement `get_settings`; it is a display override and does not change
  Claude's context allocation.
- `--claude-effort LEVEL` — one of `ultracode` (default), `low`, `medium`,
  `high`, `xhigh`, `max`, or `off`.
- `--claude-perms MODE` — permission handling for the headless turns. `auto`
  (default): `--permission-mode auto`, every action gated by the Claude Code
  auto-mode classifier — headless-safe approvals that also work on hosts
  where bypass is policy-disabled. Auto mode isn't available on every
  account/provider (Pro and Bedrock/Vertex/Foundry are excluded;
  Team/Enterprise needs admin enablement), and ineligible hosts silently
  downgrade it to default mode. The same control-only runtime handshake reads
  the CLI-reported effective mode before every turn and switches to the
  settings safety net `bypass` uses when auto does not stick. A CLI that
  hard-rejects the flag is queried once more without auto before the real turn
  starts, so fallback never duplicates model work.
  `bypass`: `--dangerously-skip-permissions`
  plus a settings safety net (auto-accepted edits + allowed
  Bash/WebFetch/WebSearch) for hosts that silently downgrade bypass (managed
  no-bypass policies, nested launches from inside another Claude Code
  session). `off`: leave the host default untouched. In every mode the
  per-PR state dir is mounted as a second working dir so the turn can read
  the codex review files.

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
- `--codex-context-window TOKENS|auto` — context-window size reported in
  Codex's forge-comment signature. `auto` (default) asks Codex app-server for
  effective layered config plus the default model/effort. For a resumed CLI
  session it issues the same control-only `thread/resume` shape as `codex exec
  resume` and reads the response's actual model and effort, rather than stale
  rollout metadata. It then looks up that actual model in `codex debug models`
  without `--bundled`. This honors the active provider/catalog and configured
  context override before applying the effective-window percentage. These
  metadata calls start no turn or inference request; probing a resume only
  loads the existing thread in the short-lived app-server. An executable that
  refuses those two commands is read from a `codex exec` session start
  instead, described above. An explicit token count is labeled `configured`
  and remains display-only. If the CLI cannot report the effective model,
  effort, or a catalog/context size, the forge turn fails before posting a
  guessed signature.
- `--codex-effort LEVEL` — one of `low`, `medium`, `high`, `xhigh`, `max`,
  `ultra`, or `off`. The default adapts to the model: `ultra` when the codex
  model is gpt-5.6-sol/-terra (the only models that support it); for any
  other `--codex-model` no level is forced (same as `off`) — the host codex
  config / the model's own default applies, since effort ceilings vary per
  model (older gpt-5.x reject `ultra`/`max`, some models top out below
  `xhigh`). An explicit level is passed verbatim.
- `--codex-tier TIER` — passed as `-c service_tier=TIER`. Default `fast`;
  `off` leaves the host's codex config untouched.

```bash
~/ai-pr-loop/run.sh 42 --repo owner/repo --claude-effort xhigh   # implementer: reasoning only, no orchestration
~/ai-pr-loop/run.sh 42 --repo owner/repo --codex-effort high     # reviewer: dial reasoning down
~/ai-pr-loop/run.sh 42 --repo owner/repo --codex-model gpt-5.5  # older reviewer model (no effort forced — host/model default)
~/ai-pr-loop/run.sh 42 --repo owner/repo --claude-context-window 200000 --codex-context-window auto
~/ai-pr-loop/run.sh 42 --repo owner/repo \
  --claude-model off --claude-effort off --claude-perms off \
  --codex-model off --codex-effort off --codex-tier off   # both: CLI/config defaults
```

The heavier levels are more thorough but cost more tokens and wall time per
iteration. Beyond the effort knob, the Codex review prompt itself runs a
self-check-before-posting pass, a severity rubric, and targeted
security/concurrency, breaking-change, and test-gap passes to keep findings
high-signal.

## How agents are distinguished

Both bots post under the same human token (GitHub: whichever account the
local `gh` is logged in as, resolved at startup via `gh api user`; GitLab:
the `GITLAB_TOKEN`/glab account, resolved via `/api/v4/user`). The loop
distinguishes their forge comments with these signals:

| Signal | Codex Reviewer | Claude Implementer |
|---|---|---|
| Hidden HTML marker (orchestrator parses) | `<!-- ai-loop:codex-reviewer iter=N -->` | `<!-- ai-loop:claude-implementer iter=N -->` |
| Visible banner | `**[AI · Codex Reviewer · iter N]**` | `**[AI · Claude Implementer · iter N]**` |
| Runtime signature | `<sub>Model: <code>…</code> · Effort: <code>…</code> · Context window: <code>… tokens (source)</code></sub>` | Same fields, using the Claude turn's values |
| Git commit author (Claude only) | — | `claude-implementer (ai-bot) <claude-implementer+bot@users.noreply.github.com>` |

The runtime signature immediately follows each visible AI header in new
forge comments and replies. Window sources are explicit: `effective` for a
CLI-reported runtime value or `configured` for a numeric operator override.
A forge turn refuses to publish if model, effort, or window cannot be resolved,
and its post-turn completion check requires the exact signature on the summary.
Offline `--print-config` and local artifacts can still show `unknown`; an
offline Codex catalog-only size is labeled `catalog-estimate`. Local review
artifacts otherwise remain unchanged.
Summary detection deliberately still keys on the hidden marker and the
legacy alert/banner lines, so summaries posted by older versions remain
valid resume points.

`fetch_ai_thread` (in `lib/common.sh`) pulls both surfaces (GitHub:
`/issues/N/comments` + `/pulls/N/comments`; GitLab: the MR `/discussions`
endpoint, where a DiffNote is inline and anything else is top-level) and
emits NDJSON tagged with `surface=issue|inline` plus `id`, `discussion_id`
(GitLab thread id, null on GitHub), `path`, `line`, `in_reply_to_id`.
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
- In `--local` mode, the squash or the push fails (status `finalize_error`)
  → exit 1. The local rounds are left in the checkout.

## Local review mode

`--local` keeps the whole review off the forge. The two agents exchange it
through files under the state dir, the implementer commits **without
pushing**, and when they agree every round is squashed into **one commit**
that carries the review's findings, fixes, and decisions in its message.
That single commit is the only thing pushed.

Use it when the review's back-and-forth would clutter the PR/MR: no bot
comments, no chain of "address review" commits — just the change, plus a
message a future reader can act on.

```bash
# On a PR/MR: read its metadata, review locally, push one commit.
~/ai-pr-loop/run.sh 42 --repo owner/repo --local

# With no PR/MR at all: review the branch this checkout has out, against main.
cd ~/src/myproject
~/ai-pr-loop/run.sh --local --base main

# Create the squashed commit but hold it back for inspection.
~/ai-pr-loop/run.sh 42 --repo owner/repo --local --no-push
```

### What lands

One commit, authored by `claude-implementer (ai-bot)`, on top of the
commits that were already on the branch — the human's own commits are never
rewritten. Its message states what the change does, then a `Review notes:`
section: findings the final code addresses, decisions taken (including
suggestions evaluated and rejected, and why), and anything deliberately
deferred.

A review that ends in agreement without changing the tree — every finding
answered by pushback, or rounds whose edits cancel out — lands no commit
and pushes nothing. The exchange itself (findings, responses, decisions)
stays in the state dir below, which is the review's only record in that
case. On a PR/MR, the title and description are still checked and
refreshed if the review agreed they were stale — that update is then the
run's only external write. An update replaces the whole field, so it is
delivered only when the PR/MR text is unchanged since the proposal was
composed — a human edit made in between wins, and the run reassesses; a
failed delivery keeps the run retryable.

What the message must never contain is churn from inside the review — a
defect introduced by one round and fixed by a later one isn't in the final
diff, so it isn't in the message either. No iteration numbers, no round
counts, no "addressed review comments".

### Where the review lives

```
state/<repo-ident>/<target>/
  iter-01/codex-review.md      # the reviewer's findings, citing path:line
  iter-01/claude-response.md   # fixes, pushback, verification
  iter-01/review-scope.md      # original change vs review-created paths
  iter-02/...
  local/base.sha               # the commit the run started from
  local/target-base.sha        # target base pinned when the review started
  local/review-scope.md        # final scope report, kept after completion
  local/tip.sha                # where the last committed round left HEAD
  local/commit-message.txt     # the composed message for the squash
  local/completed.sha          # terminal marker: the review's final commit
```

Each file is that turn's completion contract, exactly as the summary
comment is in forge mode: a turn whose file is missing or empty fails and
is re-run at the same iteration. There is no inline-comment surface —
findings cite `path:line` in the review file.

### Two scopes

| Invocation | Scope | Forge use |
|---|---|---|
| `--local` with a PR/MR number or URL | `pr` | Read-only API/CLI use for metadata and human comments. At the end, at most two writes: the `git push` of the squashed commit, plus one title/description update when the review left them stale. |
| `--local --base REF`, no positional | `branch` | No forge API, CLI, or token. Reviews the branch `--dir` has checked out (default: the current directory) against `REF`. The end-of-review push still happens: a plain fast-forward `git push` to `origin`, unless `--no-push` is given or the checkout has no `origin`. |

In `branch` scope the loop commits onto that branch and pushes it at the
end if the checkout has an `origin`; without one, the squashed commit on
the branch is the review's result and the run is complete. `--base` takes
any committish git resolves — `main`, `origin/main`, a tag, a SHA.

### Pushing

- The push happens only when the review ends in agreement (`APPROVED`, or
  the `--converge` streak). Hitting the iteration cap or erroring pushes
  nothing: the rounds stay in the checkout and the next invocation
  continues them.
- It is always a fast-forward. If the branch moved on the remote while the
  review ran, the push is refused and the squashed commit is left in the
  checkout for you to reconcile — the loop never force-pushes.
- `--no-push` stops after creating the squashed commit. Re-running without
  the flag pushes it without composing the message again.
- Once the commit is pushed — or landed locally with no `origin` to push
  to — the review is complete and terminal: re-running the same command
  exits without doing anything. Pass `--restart` to review the target as
  it now stands, from a new base; commits made after completion (yours or
  the bot's) are part of that new base and are never rewritten.

### Interruptions

The rounds live only in the checkout, so the loop keeps them on a ref of
its own (`refs/ai-pr-loop/local/pr-<N>`; in `branch` scope, the branch
itself), records the expected tip in `local/tip.sha` after every committed
round, and restores them on the next invocation. Three things fail closed
rather than guess:

- The recorded rounds are missing from the checkout (it was recreated or
  pruned) — that work is unrecoverable, so the run stops and tells you to
  clear `local/` to start over.
- The PR/MR head moved past the commit the rounds are stacked on — the
  squash could never be pushed as a fast-forward, so the run stops before
  spending more agent turns.
- The branch (or the loop's tip ref) no longer matches the recorded tip —
  it was reset or advanced outside the loop mid-review, so resuming would
  lose rounds or adopt commits no turn produced. The run stops and says
  how to reconcile.

An errored turn and a killed run are both restarted by the auto-resume
supervisor (below) until it reaches one of the exit-0 states or spends its
budget.

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

Only each bot's **summary** comment counts toward the high-water mark,
identified **structurally**: the hidden marker must be the entire first
line and the alert opener + banner line the first visible content. Neither
the marker alone nor a banner *quoted in prose* counts — a tagged general
note (e.g. an inline finding that lost its diff position, or a restatement
that cites the banner text) is not a summary. The summary is a turn's
completion contract (posted last, after every inline comment, and
re-verified by the orchestrator after each turn), so a turn that died
after inline-only posts — or whose summary POST failed — is re-run at the
same iteration instead of being skipped past.

In `--local` mode the same table applies, read from the review files under
the state dir instead of the PR's comments: a round counts once its
`codex-review.md` / `claude-response.md` exists and is non-empty.

Per-PR session ids for both agents are stored under
`state/<owner>__<name>/pr-<N>/{claude.session.uuid,codex.session.id}`
(GitLab: `state/<host>__<slug...>/...`), so resumed runs also restore the
agents' internal memory.

## Auto-resume

A killed run restarts itself. `run.sh` starts a supervisor in its own
session and then tails its log in the foreground, so what you see is the
same as before. When the loop dies without finishing, the supervisor
launches it again; each relaunch picks up at the PR's high-water mark
above.

On by default, budget 10 restarts. One supervisor per PR: the supervisor
holds a kernel lock (`supervisor.lock`) for its lifetime, so simultaneous
starts elect exactly one supervisor. A start that loses the race either
refuses, or — when the winner's record is already on disk — attaches to
the winning run as an observer: it tails the same log, its own flags are
ignored (the winner's invocation governs), and Ctrl-C from it stops the
shared run, exactly like `--stop`. A sequential second start always
refuses. `supervisor.pid` records the pid together with its start time,
so a recycled pid is neither signalled by `--stop` nor blocks a new run;
`worker.pid` records the live worker the same way, so `--stop` can still
tear down a worker orphaned by a SIGKILLed supervisor. Auto-resume needs
`setsid` with `-f` support (util-linux) or `perl` for the detached,
reparented session, and `flock` or `perl` for the lock; missing either,
the loop runs inline, with a warning.

| After a run ends | Auto-resume |
|---|---|
| `approved`, `converged_no_major`, `review_posted`, `max_iterations_reached` | Stops — the loop reached an end state. |
| `codex_error` / `claude_error` | Restarts; the failed turn runs again. |
| Died with no final status (external `SIGTERM`/`SIGHUP`, OOM kill) | Restarts. |
| Died before it started (bad flags, failed preflight, closed PR) | Stops — relaunching would loop on the same error. |
| Stop sentinel present, or the budget is spent | Stops. |

Backoff between restarts is 10s, doubling to a 300s cap, back to 10s
after a run that lasted more than ten minutes.

`--max` and `--converge` span relaunches: a relaunched loop keeps the
invocation's remaining iteration budget and convergence streak
(`worker.progress`) instead of starting a fresh count, and reconciles both
with what already landed on the PR — an iteration or qualifying review
posted right before a crash still counts. Once a worker lands the context
snapshot (`context.applied`), relaunches drop the `--context*` flags and
reuse the persisted `context.md` — the original paths may be temporary;
until then they replay the flags, so a failed replacement is retried
rather than papered over with stale stored context. `--restart` replays
safely: a relaunch that finds a codex iteration without its claude reply
resumes that half-step — unless the persisted verdict marks that
iteration APPROVED (claude never answers an approval): a prior approval
starts a fresh round, and an approval earned by this invocation's own
forced round ends the run as approved.

The supervisor is an ordinary process on the host, so a reboot ends the
review along with it — there is no boot-time hook. Re-run the same
command afterwards; it continues from the PR's high-water mark.

**Stopping it.** Ctrl-C on the foreground command is a deliberate stop: it
writes the stop sentinel and takes the supervisor and the running turn
down with it. Nothing resumes. An external `SIGTERM`/`SIGHUP` — a task
runner reaping the shell, a closed terminal — kills only the foreground
command: the supervisor runs in its own session AND outside the launching
shell's process tree (it is reparented at spawn), so neither a group kill
nor a tree-walking reaper finds it. A stray `TERM`/`HUP` that reaches the
supervisor directly is ignored unless the stop sentinel exists — only
`--stop` and Ctrl-C mean stop. To stop such a run from elsewhere:

```bash
~/ai-pr-loop/run.sh 42 --repo owner/repo --stop
# GitLab: add --forge gitlab --host <host>
```

`--stop` runs no preflight and clones nothing. The next ordinary run
clears the sentinel.

**Where it logs.** `state/<owner>__<name>/pr-<N>/supervisor.log` (GitLab:
`state/<host>__<slug...>/...`), appended across invocations. Restart lines
carry the word `auto-resume`. The same directory holds `supervisor.lock`,
`supervisor.pid` and `worker.pid` while a run is live, plus
`worker.started` / `worker.status` / `worker.progress` — the files the
restart decision, `--stop`, and the relaunch budget read.

Pass `--no-auto-resume` to run the loop in the invoking process with
nothing supervising it, or `--auto-resume N` to change the budget (`0`
disables). `--print-config` and `--preflight-only` never start a
supervisor.

## Direct CLI (advanced)

The skill is just a wrapper around `run.sh`. You can drive it directly:

```bash
# Minimal: PR number + repo slug. The loop manages its own clone at
# ~/ai-pr-loop/checkouts/<owner>__<name>/ (created on first use).
~/ai-pr-loop/run.sh 42 --repo owner/repo

# Or hand it the PR/MR URL — forge, host, repo, and number all derived:
~/ai-pr-loop/run.sh https://github.com/owner/repo/pull/42
~/ai-pr-loop/run.sh https://gitlab.com/group/sub/proj/-/merge_requests/7

# Uncapped, with convergence on 3 consecutive NIT-only iters:
~/ai-pr-loop/run.sh 42 --repo owner/repo --max 0 --converge 3

# Point at an existing local clone instead of letting the loop manage one:
~/ai-pr-loop/run.sh 42 --repo owner/repo --dir ~/src/some-checkout

# New commits landed after a prior APPROVED verdict — re-review them:
~/ai-pr-loop/run.sh 42 --repo owner/repo --restart

# Just post a review, don't auto-fix anything:
~/ai-pr-loop/run.sh 42 --repo owner/repo --review-only

# Keep the review off the forge; land one squashed commit when they agree:
~/ai-pr-loop/run.sh 42 --repo owner/repo --local
~/ai-pr-loop/run.sh 42 --repo owner/repo --local --no-push   # hold it locally

# No PR/MR at all — review this checkout's branch against main:
~/ai-pr-loop/run.sh --local --base main --dir ~/src/some-checkout

# Attach reference material (web links / notes / a local file) for both agents:
~/ai-pr-loop/run.sh 42 --repo owner/repo \
  --context-url https://example.com/design-doc \
  --context "Must stay backward-compatible with the v1 API." \
  --context-file ./docs/spec.md

# Dial models / reasoning effort (defaults: implementer fable @ ultracode,
# reviewer gpt-5.6-sol @ ultra on the fast tier):
~/ai-pr-loop/run.sh 42 --repo owner/repo --claude-effort xhigh --codex-effort high
~/ai-pr-loop/run.sh 42 --repo owner/repo --codex-model gpt-5.5 --codex-tier off

# Use alternate compatible CLI executables (names on PATH or paths):
~/ai-pr-loop/run.sh 42 --repo owner/repo \
  --claude-bin claude-enterprise --codex-bin /opt/codex/bin/codex

# Auto-resume (on by default, budget 10): change the budget, turn it off,
# or stop a supervisor that is running elsewhere:
~/ai-pr-loop/run.sh 42 --repo owner/repo --auto-resume 3
~/ai-pr-loop/run.sh 42 --repo owner/repo --no-auto-resume
~/ai-pr-loop/run.sh 42 --repo owner/repo --stop
```

Iteration artifacts (prompts, full stdout/stderr, fetched thread, codex
verdict, per-iter session captures) are kept under
`state/<owner>__<name>/pr-<N>/iter-NN/` so you can replay any decision
after the fact.

## Round reports

Each turn ends by printing its own summary — the reviewer's findings, the
implementer's responses — to the loop's log, and saving it next to the rest
of that iteration's artifacts:

```
iter-01/codex-report.md      # the review posted for iteration 1
iter-01/claude-report.md     # the response posted for iteration 1
```

So the round's substance reaches whoever is driving the loop through the
stream they are already watching:

```
[ai-loop 14:49:49] codex: iter 1 report (27 lines) -> …/iter-01/codex-report.md
[ai-loop 14:49:49] ----- BEGIN codex report (iter 1) -----
[ai-loop 14:49:49]   ### Summary
[ai-loop 14:49:49]   …
[ai-loop 14:49:49] ----- END codex report (iter 1) -----
```

The announcement line is the only one carrying the bot tag, so a log
monitor keyed on `codex:`/`claude:` fires once per report rather than once
per line. `AI_REPORT_LOG_MAX_LINES` (default 200) caps how much body
reaches the log; the report file always holds all of it. A value that is
not a non-negative integer warns and uses the default; a value past nine
digits warns and uses 1,000,000, which logs any real report whole.

In local mode the report is the review/response file the turn wrote. A turn
whose summary never landed fails on its own contract and reports nothing. A
summary that landed just before the CLI died (or lost its stdout marker) is
reported before the turn exits. In forge mode resume then advances past that
iteration on the landed artifact, so the failing turn is the report's only
chance; in local mode the failed round's commits are rolled back and its
response is discarded with them, so resume reruns the round. And a report
that cannot be captured logs a warning without failing a turn whose review
already landed.

## Testing

`tests/run_tests.sh` runs the loop's regression tests — no network, no real
`claude`/`codex`/`gh`: the turn scripts execute against PATH stubs that
record their argv, and assertions check the recorded vectors (model /
effort / tier mapping, `off` omission, the adaptive Codex effort default,
explicit-level precedence, executable overrides, fresh-vs-resumed session
flags) plus `run.sh`'s flag validation. The auto-resume cases start real
supervisors against the same stubs; most die before an agent turn, and the
terminal-status cases drive the Codex stub through an approved run to prove
the supervisor stops on an end state. Local review mode is covered against real git: the
per-round file contracts, resume high-water, squash-into-one-commit, the
fast-forward-only push, and the single post-push title/description write.

```bash
~/ai-pr-loop/tests/run_tests.sh
```

## Notes

- The authenticated user's token (gh PAT on GitHub, `GITLAB_TOKEN`/glab on
  GitLab) is used for all API mutations (comments). Pushes go through the
  checkout's own git credential — SSH key or credential helper — which may
  belong to a different account. Don't run on PRs/MRs you don't intend the
  bots to act on under those identities.
- Claude never force-pushes, amends, or rebases — only adds new commits
  to the PR head ref. Under `--local` it does not push at all; the
  orchestrator squashes the rounds and pushes that one commit.
- Managed checkouts live at `~/ai-pr-loop/checkouts/<owner>__<name>/`
  (one clone per repo, shared across PRs). For concurrent loops on the
  same repo, pass `--dir` to point each loop at its own clone.
- All AI comments are preserved on the PR for human audit; the bots do
  not delete or flip resolved state.
