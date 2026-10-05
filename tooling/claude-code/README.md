# Claude Code Integration

Recommended pattern:
1. Keep a concise root `AGENTS.md` or provider-equivalent project instruction file.
2. Load specialist instructions only when needed.
3. Keep project knowledge under `.agents/`.
4. Use skills/commands/hooks for deterministic automation where supported.
5. Keep model routing centralised.
6. Use isolated worktrees/branches for concurrent implementation.
7. Never put credentials in instruction files.

Provider-specific integration can be added without changing the core model.
