# Repository agent instructions

## Mandatory AI PR loop workflow

For any request to start, restart, continue, monitor, inspect, or stop an
`ai-pr-loop` review:

1. Before the first shell command, API call, plan, or status claim, read
   `.agents/skills/ai-pr-review/SKILL.md` completely. Do not rely on a prior
   summary or memory of the skill.
2. Treat that skill as the authoritative controller procedure. User
   instructions override its defaults, but skipping the procedure is not an
   acceptable interpretation of a user request.
3. Never send a final response while a review is active unless the user
   explicitly asks to detach, pause, or stop monitoring. Keep the same
   assistant turn open until a terminal loop status is observed.
4. Relay every Codex report, Claude report, commit, verdict, failure,
   auto-resume event, and terminal status when it lands. Suppress no-change
   polls; do not suppress completed turn reports.
5. If a persistent monitor tool is unavailable, use the skill's guarded
   polling fallback. Poll at least once every 60 seconds and keep the
   conversation turn open. A user request for fewer updates changes message
   frequency for no-change polls, not the requirement to relay completed
   reports.
6. If the user adds or changes a constraint during a running turn, follow the
   skill's stop/update/restart procedure before allowing either model to
   continue under stale instructions.
7. Do not improvise around a failed controller step. Diagnose the actual
   failure, preserve the checkout and state, and resume only after the
   controller contract is restored.

The repository's Claude-facing skill entry is a pointer to the same canonical
skill. Keep the controller procedure in `.agents/skills/ai-pr-review/SKILL.md`
so Codex and Claude cannot silently drift to different workflows.
