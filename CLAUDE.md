@AGENTS.md

# Claude Code

`AGENTS.md` is the canonical shared project brief for all coding agents in this repository. Keep architecture, build/test commands, decoder policy, CAS behavior, frontend contracts, and scan/fingerprint rules there first. This file should stay small and contain only Claude Code-specific routing.

## Configuration model

- Shared Claude Code configuration lives in `.claude/settings.json` and `.claude/agents/`.
- Personal machine/project permissions belong in `.claude/settings.local.json`; do not commit that file.
- Use `/memory` for machine-local discoveries that are useful across sessions but should not become team policy.
- If a fact should be known by Codex, Claude Code, and other repository agents, update `AGENTS.md` rather than duplicating it here.

## Recommended Claude Code workflows

- Use the default main conversation for implementation work that needs continuous project context.
- Use project subagents from `.claude/agents/` for bounded research/review/verification tasks that would otherwise pollute the main context.
- When delegating to a subagent, include the concrete goal, changed files if known, and the validation command to run. Subagents start with isolated context and should not assume they saw the parent conversation.
- Prefer read-only or verification subagents before broad refactors. Let the main agent make final code changes unless the user explicitly asks for parallel implementation.

## Project subagents

- `orz-architect` — architecture review, migration planning, and cross-platform SDK boundaries.
- `orz-decoder-auditor` — decoder, scan, CAS, audio fingerprint, and playback-strategy audits.
- `orz-frontend-reviewer` — UI/player interaction review, accessibility, keyboard controls, and browser-side regressions.
- `orz-verifier` — focused test/build/check execution and result summarization.

## Safety notes

- Do not copy local absolute permissions from `.claude/settings.local.json` into shared settings.
- Avoid broad shared allow rules such as unrestricted `Bash(swift run *)`, `Bash(curl *)`, or destructive database commands.
- Use `FORCE_ALL_FORMATS=1` for `make audit-fingerprints` only when deliberately testing the slow all-format failure path.
