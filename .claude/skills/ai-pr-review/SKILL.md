---
name: ai-pr-review
description: Orchestrate the two-agent ai-pr-loop on a GitHub pull request or a GitLab merge request (gitlab.com or self-hosted), or locally on a branch. Use when the user asks to "review PR X", "review MR X", "run AI review on <PR/MR URL>", "kick off the review bots", "review this branch locally", or similar — the user wants Codex (reviewer) + Claude (implementer) to iterate autonomously until convergence or approval. Posts comments under the user's forge API identity (gh PAT / GitLab token); pushes commits through the checkout's git credential, which may be a different account. With --local it posts nothing and lands the whole review as one squashed commit.
argument-hint: "[pr-number or pr/mr-url] [--forge github|gitlab] [--host HOST] [--max N] [--converge N] [--restart] [--review-only] [--local] [--base REF] [--no-push] [--context-url URL] [--context TEXT] [--context-file FILE] [--claude-bin EXECUTABLE] [--claude-model MODEL] [--claude-context-window TOKENS|auto] [--claude-effort LEVEL] [--claude-perms MODE] [--codex-bin EXECUTABLE] [--codex-model MODEL] [--codex-context-window TOKENS|auto] [--codex-effort LEVEL] [--codex-tier TIER] [--auto-resume N] [--no-auto-resume] [--stop]"
allowed-tools: Bash, Read, Monitor
---

# AI PR Review

The canonical, cross-agent instructions are in the `ai-pr-loop` checkout, at:

`.agents/skills/ai-pr-review/SKILL.md`

Relative to this file that is `../../../.agents/skills/ai-pr-review/SKILL.md`.
This file is normally reached through a symlink from `~/.claude/skills`, so
resolve the path against the checkout, not against the link: try
`$AI_PR_LOOP_HOME`, then `~/ai-pr-loop`, then wherever the user says the
checkout is.

Read that file completely before taking any action. Do not launch, resume,
monitor, stop, or report an AI PR loop from this pointer alone. If the
canonical file cannot be read, stop and report the setup failure instead of
reconstructing the workflow from memory.
