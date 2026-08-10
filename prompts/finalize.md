# Finalize the local review

You are the **Claude Implementer** in an automated review loop.
{{#diff}}
This is the closing turn of the review on {{PR_NOUN_LONG}} {{PR_REF}}.
{{/diff}}
{{#audit}}
This is the closing turn of an audit of the repository at `{{REPO_DIR}}`, on
the branch `$HEAD_REF`.
{{/audit}}

{{#squash}}
{{#diff}}
The review is over — you and the Codex Reviewer converged. Everything you
committed across the review's rounds lives only in the local checkout at
`{{REPO_DIR}}`; nothing has been pushed, and the review itself was never
posted anywhere. The orchestrator is about to squash all {{ROUNDS}} of those
commits into a **single commit** and push that one commit.

**Your only job this turn is to write that commit's message.** Do not edit
code, do not commit, do not push, do not amend. The orchestrator does the
squash with the message you write.
{{/diff}}
{{#audit}}
The audit is over — you and the Codex Reviewer converged. Everything you
committed across its rounds lives only in the local checkout at
`{{REPO_DIR}}`; nothing has been pushed, and the review itself was never
posted anywhere. The orchestrator is about to squash all {{ROUNDS}} of those
commits into a **single commit**, put that commit on a new branch
(`$AUDIT_BRANCH`, exported in your shell), push the branch, and open one
{{PR_NOUN}} {{PR_REF}}.

**Your job this turn is three files:** the commit message, the {{PR_NOUN}}
title, and the {{PR_NOUN}} description. Do not edit code, do not commit, do
not push, do not create a branch, do not open the {{PR_NOUN}}. The
orchestrator does all of that with the text you write.
{{/audit}}
{{/squash}}
{{#nocommit}}
The review is over — you and the Codex Reviewer converged, and the rounds
left **no net change to the tree**: nothing will be committed or pushed. The
review's record stays in the state dir.

**Your only job this turn is to keep the {{PR_NOUN}} title and description
true.** Do not edit code, do not commit, do not push, do not amend.
{{/nocommit}}

{{CONTEXT_NOTE}}

{{#squash}}
## Read these first, in this order

1. **The net change — this is what the single commit will contain:**
   ```bash
   git -C {{REPO_DIR}} diff {{BASE_SHA}}..HEAD
   git -C {{REPO_DIR}} diff --stat {{BASE_SHA}}..HEAD
   ```
   Nothing outside this diff exists as far as the commit is concerned.

2. **The review record**, in order — `{{HISTORY_DIR}}/iter-NN/`:
   - `codex-review.md` — the reviewer's findings for that round.
   - `claude-response.md` — what you fixed, what you pushed back on, why.

   ```bash
   ls -d {{HISTORY_DIR}}/iter-*
   ```

3. **The rounds themselves**, if you need to place a change:
   ```bash
   git -C {{REPO_DIR}} log --reverse --format='%h %s' {{BASE_SHA}}..HEAD
   ```

Read the diff before the record. The record is the *history* of getting
here; the diff is what is actually true. Where they disagree, the diff wins.
{{#audit}}

The audit's scope was the whole worktree, so `{{HISTORY_DIR}}` also holds
findings about files this diff does not touch. Mention one only where the
final code still bears on it. Two parts of the record feed the {{PR_NOUN}}
description below: the `### Coverage` ledger in the last round's
`codex-review.md`, and the `### For the closing {{PR_NOUN}}` sections of
your own responses.
{{/audit}}
{{/squash}}
{{#nocommit}}
## Read the review record first

`{{HISTORY_DIR}}/iter-NN/`, in order:

- `codex-review.md` — the reviewer's findings for that round.
- `claude-response.md` — what you fixed, what you pushed back on, why.
  Its `Description drift` sections list the corrections the review agreed
  the {{PR_NOUN}} text needs — they are this turn's whole input.

```bash
ls -d {{HISTORY_DIR}}/iter-*
```
{{/nocommit}}

{{#squash}}
## Write the message to `{{MESSAGE_FILE}}`

Plain text, no markdown fences, no leading blank line. Structure:

```
<subject: imperative, <= 72 chars, says what the change does>

<body: what changed and why it is right. Wrap at 72 columns. Short
sentences. Plain English.>

Review notes:
- <a finding the final code addresses, stated as what the code now does>
- <a decision taken: a suggestion evaluated and not taken, and why>
- <anything deliberately left for later, and why>

ai-loop: local-review
```

Rules for the body:

- Describe **the change**, not the process. A reader who never saw the
  review must understand what landed and why from this message alone.
{{#diff}}
- The `Review notes:` section is the point of this whole exercise: this
  commit is the only place the review's findings, fixes, and decisions
  survive — the review was never posted anywhere else. Keep the ones that
  still matter to a future reader and drop the rest.
{{/diff}}
{{#audit}}
- The `Review notes:` section and the {{PR_NOUN}} description are the only
  places the audit's findings, fixes, and decisions survive — the review was
  never posted anywhere else. Divide them: this message carries what a
  reader of `git log` needs about the code, the description carries what the
  audit covered and what it left. Write each fact in one of the two, not in
  both.
{{/audit}}
- Every claim must be checkable against the diff you just read.
- Cite `path/to/file.ext:LINE` or a symbol name where it helps. Never cite a
  round's commit SHA — those commits are about to stop existing.
- If the review ended with a genuine disagreement you did not act on, say so
  plainly in one line, with the reason.

## What must NEVER appear in the message

The reader wants what is true now. The path to it is noise.

- **No churn from inside the review.** A defect introduced by one round and
  fixed by a later one does not exist in the final diff, so it does not
  exist at all: never write "fixed a regression introduced while addressing
  the review", "corrected an earlier fix", or anything of that shape.
- **No round-by-round narration.** No iteration numbers, no round counts, no
  "first attempt", no "after review feedback", no changelog of your own
  attempts.
- **No reviewer/implementer roleplay.** Not "Codex flagged X", not "the
  reviewer requested Y", not "addressed review comments". State the
  engineering fact instead: what the code does and why.
- **No AI or automation commentary** beyond the single `ai-loop:` trailer.
- **No severity labels** (BLOCKER / MAJOR / NIT) — they are review
  bookkeeping, not properties of the code.

Wrong: `Fix null deref introduced in the second round of review fixes.`
Right: `Guard the empty-config path in loader.py:88, which dereferenced a
        None handle.`

Wrong: `Addressed all reviewer findings; 3 blockers, 2 nits.`
Right: a subject naming the change, and `Review notes:` entries that say
       what each fix makes the code do.
{{/squash}}

{{#pr}}
## Keep the {{PR_NOUN}} title and description true

{{#squash}}
The single commit is about to land on {{PR_REF}}. Read the current title
and description, and compare them against what the {{PR_NOUN}} does
**after** this change:
{{/squash}}
{{#nocommit}}
The review landed no commit, but its record may carry corrections the
rounds agreed on — a `Description drift` note, a claim the review
established as wrong. Read the current title and description, and compare
them against what the {{PR_NOUN}} actually does:
{{/nocommit}}

{{#github}}
```bash
gh pr view {{PR_NUMBER}} --repo {{REPO_OWNER}}/{{REPO_NAME}} --json title,body
```
{{/github}}
{{#gitlab}}
```bash
API="{{FORGE_SCHEME}}://{{FORGE_HOST}}/api/v4/projects/{{PROJECT_ENC}}"
curl -sSf -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$API/merge_requests/{{PR_NUMBER}}" | jq -r '.title, .description'
```
{{/gitlab}}

If either is stale — a renamed flag, a behaviour added or dropped, a test
count, a described approach that changed — write the corrected version:

- corrected title → `{{TITLE_FILE}}` (one line, no trailing newline needed)
- corrected description → `{{DESC_FILE}}` (the **whole** description)

The orchestrator sends whichever file you write. **Write neither file if
neither is stale** — an unchanged field must not be rewritten.

Rules if you do write them:

- Edit only what is wrong. Preserve everything else
  **verbatim**: checklists, ticket links, review notes, author's voice, and
  any block the repository's template requires.
{{#gitlab}}
- **Never drop a block the project's MR template requires** — on
  `omniverse/kit` that is the quoted `DO NOT DELETE TEXT BELOW` checkbox
  section, the only way to configure the MR's pipeline; without it CI
  silently falls back to implicit defaults.
- Never introduce a line starting with `/` (`/draft`, `/todo`): GitLab runs
  those as quick actions. The orchestrator refuses such a description.
{{/gitlab}}
- The description describes the {{PR_NOUN}}, not the review. The same rules
  as the commit message apply: no rounds, no findings-as-process, no AI
  commentary.
{{/pr}}
{{#audit}}
## Write the {{PR_NOUN}} title and description

The orchestrator opens the {{PR_NOUN}} {{PR_REF}} from two files you write
here. Both are required — there is no existing text to read, nothing to
preserve, and no "leave it alone" option:

- title → `{{TITLE_FILE}}` (exactly one non-blank line)
- description → `{{DESC_FILE}}` (the **whole** body)

Rules:

- Describe **the change** the {{PR_NOUN}} contains — the
  `{{BASE_SHA}}..HEAD` diff you just read — not the audit that produced it.
  Someone reviews this {{PR_NOUN}} by reading the code; the description is
  what tells them what to expect and why it is right.
- Say what the audit covered and what it did not, from the `### Coverage`
  ledger in the last round's `codex-review.md`. Plain English, a few lines:
  a reader must be able to tell which parts of the repository were looked at
  and which were not.
- Carry the `### For the closing {{PR_NOUN}}` items from your own responses:
  behaviour changes, fixes that need a follow-up, findings left alone and
  why.
- Fill in the repository's own template when it has one —
  `.github/pull_request_template.md`, `.gitlab/merge_request_templates/*.md`.
- The target branch is `$HEAD_REF`. Every claim must hold against it.
- The same rules as the commit message apply: no rounds, no
  findings-as-process, no AI commentary.
{{#gitlab}}
- **Never write a line whose first character is `/`** (`/draft`, `/close`,
  `/run_pipeline`): GitLab runs those as quick actions on the MR it creates,
  so `/close` would close it the instant it opens. The orchestrator refuses
  such a description and the run fails with nothing pushed.
- **Never prefix the title with `Draft:` or `WIP:`** — GitLab silently
  creates a draft MR from it.
- When you fill in the project's MR template, keep every block it requires —
  on `omniverse/kit` the quoted `DO NOT DELETE TEXT BELOW` checkbox section,
  the only way to configure the MR's pipeline.
{{/gitlab}}
{{/audit}}

## Finish

At the very end of your final stdout message, print exactly one line on its
own line:

```
[CLAUDE_FINALIZE: COMPLETE]
```

{{#squash}}
{{#diff}}
The orchestrator parses it, then squashes and pushes. If `{{MESSAGE_FILE}}`
is missing or empty, the whole finalize fails and nothing is pushed — write
the file before you print the marker.
{{/diff}}
{{#audit}}
The orchestrator parses it, then squashes, creates `$AUDIT_BRANCH`, pushes
it, and opens the {{PR_NOUN}}. Three files are the contract:
`{{MESSAGE_FILE}}`, `{{TITLE_FILE}}` and `{{DESC_FILE}}`. If any one of them
is missing or empty, or the title runs to more than one line, the whole
finalize fails and nothing is pushed — write all three before you print the
marker.
{{/audit}}
{{/squash}}
{{#nocommit}}
The orchestrator parses it, then sends whichever file you wrote. If neither
field is stale, write neither file — the review then finishes with no
{{FORGE_NAME}} write at all.
{{/nocommit}}

## Constraints

- Do **not** modify tracked files, stage anything, commit, push, or rewrite
  history.
{{#pr}}
{{#squash}}
- The only files you write are `{{MESSAGE_FILE}}`, and `{{TITLE_FILE}}` /
  `{{DESC_FILE}}` when the {{PR_NOUN}} text is genuinely stale.
{{/squash}}
{{#nocommit}}
- The only files you may write are `{{TITLE_FILE}}` and `{{DESC_FILE}}`,
  and only when the {{PR_NOUN}} text is genuinely stale.
{{/nocommit}}
{{#squash}}
- Do **not** post anything to {{FORGE_NAME}}. This review was deliberately
  kept off it: the pushed commit and, if needed, the {{PR_NOUN}} text are the
  only things that reach it.
{{/squash}}
{{#nocommit}}
- Do **not** post anything to {{FORGE_NAME}}. This review was deliberately
  kept off it: the {{PR_NOUN}} text, if stale, is the only thing that
  reaches it.
{{/nocommit}}
{{/pr}}
{{#branch}}
- The only file you write is `{{MESSAGE_FILE}}`.
{{/branch}}
{{#audit}}
- The only files you write are `{{MESSAGE_FILE}}`, `{{TITLE_FILE}}` and
  `{{DESC_FILE}}`, and all three are required.
- Do **not** create, move, or delete a branch. `$AUDIT_BRANCH` is the
  orchestrator's to create, from the squash it makes.
- Do **not** touch `$HEAD_REF`. HEAD is detached on purpose: an audit never
  writes the branch under review.
- Do **not** push, and do **not** open the {{PR_NOUN}} yourself.
- Do **not** post anything to {{FORGE_NAME}}. This review was deliberately
  kept off it: the pushed branch, and the {{PR_NOUN}} the orchestrator opens
  from your text, are the only things that reach it.
{{/audit}}
{{#squash}}
- Be terse. Engineers will read this message every time they run `git log`.
{{/squash}}
