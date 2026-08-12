# Open the audit's PR/MR

You are the closing step of an automated audit of the repository at
`{{REPO_DIR}}`. The review is over, its fixes are one commit, and that commit
is on a branch that is **already pushed**. One thing is left: make sure the
PR/MR for it exists, and write down where it is.

**Read `{{SKILL_FILE}}` and follow it.** It states the rules that matter —
above all that exactly one PR/MR may exist for this branch pair, so you look
for an existing one before creating anything, and you stop rather than guess
if you cannot tell.

The values it refers to are exported in your environment: `$OPEN_PR_HEAD` (the
branch to open it from) and `$OPEN_PR_BASE` (the branch it targets). Which
forge and project this is, you read from the checkout's `origin`. Use the
variables rather than typing a branch name — a valid branch name can contain
characters your shell would act on.

The title and description are already composed. Send them verbatim:

- title — `{{TITLE_FILE}}` (one line)
- description — `{{DESC_FILE}}`

## Do not

- Do not push, commit, amend, rebase, or move any branch. Both branches are
  where they belong, and `$OPEN_PR_BASE` is the operator's own branch.
- Do not edit the title or the description.
- Do not review the code, fix anything, or open more than one PR/MR.

## Finish

Write the PR/MR's URL — the URL alone — to `{{PR_URL_FILE}}`, then print
exactly this as the last line of your final message:

```
[OPEN_PR: COMPLETE]
```

That file is the contract. If it is missing, empty, or does not hold a URL,
this step failed however the message reads, and it is retried on the next run.
