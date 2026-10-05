---
name: setup
description: Set up the current repository to use the ai-engineering system - .agents/ knowledge layout, gates.json, project AGENTS.md and CLAUDE.md, and project plugin settings.
disable-model-invocation: true
---
# Setup

Prepare this repository for the ai-engineering system. Never overwrite an existing file without showing the change and getting the user's agreement. Never modify user-level or global Claude settings.

1. Confirm the current directory is the root of a git repository.
2. Create the knowledge layout, adding a `.gitkeep` to empty directories:
   `.agents/project/`, `.agents/decisions/`, `.agents/specs/active/`, `.agents/specs/archive/`, `.agents/learnings/`, `.agents/failures/`, `.agents/regressions/`.
3. Quality gates: inspect the project's build files (for example `package.json` scripts, `Makefile`) and propose `fast` (lint, typecheck, unit tests: seconds, not minutes) and `full` (everything required before review) commands. Confirm them with the user, then write `.agents/gates.json` from `${CLAUDE_SKILL_DIR}/templates/gates.json`. Leave `externalReview` as `null` unless the user provides a command; see the external review contract in the ai-engineering system docs.
4. `AGENTS.md`: if absent, create it from `${CLAUDE_SKILL_DIR}/templates/project-AGENTS.md`, filling in what you can verify from the repository. If present, propose additions only. Never copy the global engineering standards into it.
5. `CLAUDE.md`: if absent, create it from `${CLAUDE_SKILL_DIR}/templates/project-CLAUDE.md` so `AGENTS.md` keeps loading even if someone adds a `CLAUDE.local.md`. If present without `@AGENTS.md`, propose adding that import.
6. `.claude/settings.json`: merge in the keys from `${CLAUDE_SKILL_DIR}/templates/settings.json` without removing existing keys. Replace `{{PLUGIN_VERSION}}` with the `version` in `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json`, so the project is pinned to that release tag with auto-update off. Show the result before writing.
7. Ask whether the project wants parallel implementation in worktrees. Only if yes, add `"worktree": {"baseRef": "head"}` to `.claude/settings.json`, and explain that it also makes the user's own `claude --worktree` sessions branch from the current HEAD instead of the remote default branch.
8. Report what was created or changed. Remind the user to review and commit it: committed `.agents/gates.json` is what the gates use, and the external review command is read from the base branch.
