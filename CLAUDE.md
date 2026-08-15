# Repository instructions for Claude Code

Claude Code loads this file automatically. Codex loads `AGENTS.md`. Both
files exist so neither agent can miss the controller contract, and the
contract itself is written once, in `AGENTS.md`.

## Mandatory AI PR loop workflow

For any request to start, restart, continue, monitor, inspect, or stop an
`ai-pr-loop` review:

1. Before the first shell command, API call, plan, or status claim, read
   `AGENTS.md` and then `.agents/skills/ai-pr-review/SKILL.md`, both
   completely. Do not rely on a prior summary or memory of either file.
2. Invoke the `ai-pr-review` skill. Reading the skill files by hand instead
   of invoking the skill is not an acceptable substitute: the skill is the
   entry point the loop's own guards and defaults assume.
3. The controller contract in `AGENTS.md` is mandatory. User instructions
   override its defaults, but skipping the procedure is not an acceptable
   interpretation of a user request.

`.claude/skills/ai-pr-review/SKILL.md` gives Claude Code the skill's
metadata for selection. It is a pointer, not the procedure. This file is
what makes the procedure mandatory.
