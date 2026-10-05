# Consuming Project Structure

`/ai-engineering:setup` creates this layout in an application repository:

```text
my-application/
├── CLAUDE.md                 # contains only "@AGENTS.md"
├── AGENTS.md                 # project-specific facts, commands, boundaries
├── .claude/
│   └── settings.json         # registers the marketplace, enables the plugin
├── .agents/
│   ├── gates.json            # fast / full / externalReview commands
│   ├── project/              # system overview, architecture, domains, data, design
│   ├── decisions/            # ADRs
│   ├── specs/
│   │   ├── active/           # planning sessions and work specs in progress
│   │   └── archive/
│   ├── learnings/
│   ├── failures/
│   └── regressions/
├── src/
└── tests/
```

- Project context = how the application works.
- Work spec = what this body of work changes.
- ADR = why an important decision was made.
- Learning = what was discovered.
- Regression = executable memory of a failure or required behaviour.

## Why CLAUDE.md only imports AGENTS.md
Claude Code reads `AGENTS.md` only when no `CLAUDE.md` or `CLAUDE.local.md` exists in the directory tree. A `CLAUDE.md` containing `@AGENTS.md` keeps it loading even after someone adds a personal `CLAUDE.local.md`, while other tools keep reading `AGENTS.md` directly.

## What does not belong here
Global engineering standards come from the plugin. Do not copy them into `AGENTS.md`; there must be one authoritative version of each rule.

## Team rollout
`.claude/settings.json` declares `extraKnownMarketplaces` (pinned to a release tag, `autoUpdate: false`) and `enabledPlugins`. After a teammate trusts the folder, Claude Code registers the marketplace and, because the marketplace lists the plugin by relative path, loads the plugin from it. Untrusted folders and `claude -p` runs in folders never trusted interactively ignore the marketplace entry.

## Updating
The project should not silently receive changed hooks. The plugin pins `version`, so Claude Code keeps the cached copy until the version string changes, and auto-update is off. To upgrade deliberately:
1. Read the release notes and the diff of `plugins/ai-engineering/hooks/` and `scripts/` between the two tags.
2. Change the `ref` in `.claude/settings.json` to the new tag and commit it.
3. Each developer runs `claude plugin update ai-engineering@ai-engineering-system` (or `/plugin`) and `/reload-plugins`.

Limits: a marketplace `ref` can be a branch or tag but not a commit SHA, and tags can be moved, so this is not tamper-proof. A developer who already registered the marketplace under the same name keeps their existing registration; check with `/plugin`.

## Parallel worktrees
`/setup` asks before adding `"worktree": {"baseRef": "head"}`. Without it, `/ai-engineering:deliver` runs tasks sequentially, because Claude Code's default worktree base is the remote default branch.

## gates.json
```json
{
  "fast": "npm run lint && npm run typecheck && npm test",
  "full": "npm run check",
  "externalReview": null
}
```
`fast` runs whenever an implementation agent finishes, so keep it to seconds. `full` runs before review. The main session runs gates through the Bash tool with `bash -c` from the repository root, so your permission rules and sandbox apply. Gates use the committed file (uncommitted edits are ignored and reported); during review the full gate is read from the base ref. Commands containing high-impact operations are refused. See [external-review.md](external-review.md) for `externalReview`.

Every gate executes the project's code with the privileges of whoever runs it; see the [trust boundary](architecture.md#trust-boundary-for-project-code).

### Optional: hook-run fast gate
Setting `AI_ENGINEERING_HOOK_GATES=1` in the environment that launches Claude Code makes a `SubagentStop` hook run the fast gate inside each implementation agent's run, giving it up to 2 automatic fix attempts. Hooks run **outside** Claude Code's permission checks, auto-mode classifier and sandbox, so this executes the agent's working tree, including uncommitted edits, unprompted with your full credentials and network access. Use it only where the host is itself isolated or the code is trusted. Set it in your own environment, not in committed project settings.
