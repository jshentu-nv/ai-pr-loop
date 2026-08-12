---
name: open-pr
description: Open one pull request (GitHub) or merge request (GitLab) for a branch that is already pushed, from a title and description prepared on disk, and record its URL. Use when the ai-pr-loop audit's closing step asks for the PR/MR to be opened. Adopts an existing PR/MR for the same branch pair instead of opening a second one.
---

# Open the PR/MR for a pushed branch

You are finishing an `ai-pr-loop` audit. The review is over, its fixes are one
commit on a branch, and that branch is already pushed. Your whole job is to
make sure exactly one PR/MR exists for it and to write down where it is.

## What you are given

| Variable | Meaning |
|---|---|
| `$OPEN_PR_HEAD` | the branch holding the squashed commit — the **head/source** |
| `$OPEN_PR_BASE` | the branch that was audited — the **base/target** |
| `$OPEN_PR_TITLE_FILE` | file holding the title — one line, use it verbatim |
| `$OPEN_PR_DESC_FILE` | file holding the description — use it verbatim |
| `$OPEN_PR_URL_FILE` | write the resulting URL here |

Which forge this is, and which project, you work out yourself from the
checkout's `origin` remote. Use the variables rather than typing a branch
name: a valid branch name can contain characters your shell would act on.

## Rules

- **Exactly one PR/MR.** Look for an existing one for this exact head→base pair
  **before** creating anything. If one exists — in any state — adopt it: write
  its URL and stop. This step is retried after a failure, and a duplicate PR is
  not something the loop can clean up for you.
- **If you cannot tell whether one exists, stop.** A lookup that fails because
  the forge is unreachable is not "there is none". Report the failure and write
  nothing. A later run retries; creating blind would open a second PR.
- **Do not push, commit, amend, or move any branch.** Both branches are already
  where they belong. `$OPEN_PR_BASE` in particular is the operator's own branch.
- **Do not edit the title or description.** They were composed against the final
  diff. Send them as they are.
- **Do not open it as a draft.** On GitLab a `Draft:` or `WIP:` title prefix
  silently creates a draft MR; the title file will not contain one, so do not
  add one.
- **GitLab only:** a description line whose first non-blank character starts a
  `/word` is run as a quick action on the MR you create — `/close` would close
  it the instant it opens. If the description has one, stop and report it
  rather than sending it.

## Doing it

Work out the right call for the forge yourself. The credential is already in
your environment: `$GH_TOKEN` for GitHub, `$GITLAB_TOKEN` for GitLab.

- **GitHub** — the `gh` CLI is authenticated and is the intended path.
- **GitLab** — use `curl` with a `PRIVATE-TOKEN` header against that host's
  REST API v4. Do **not** post through `glab api`: it silently drops structured
  payload fields and returns success. `glab` is fine for read-only views. The
  project id segment is the URL-encoded project path (`group/sub/proj` →
  `group%2Fsub%2Fproj`).

Check the result of every call. A REST call that returns an error body under a
200-shaped invocation has not created anything — never treat a failed mutation
as if it landed.

## Finishing

Write the PR/MR's URL — just the URL, nothing else — to `$OPEN_PR_URL_FILE`,
then print exactly this on its own line as the last line of your final message:

```
[OPEN_PR: COMPLETE]
```

The orchestrator reads that file. If it is missing, empty, or does not hold a
URL, the step failed whatever your message says, and it is retried.
