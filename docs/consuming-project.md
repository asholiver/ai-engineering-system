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

4. Verify the upgrade took effect: start a new session and read the session banner (`ai-engineering <version>, plugin root <path>`). If it shows the old version or an unexpected root, an existing registration is still active; check with `/plugin`.

Limits: a marketplace `ref` can be a branch or tag but not a commit SHA, and tags can be moved, so this is not tamper-proof. A developer who already registered the marketplace under the same name keeps their existing registration; check with `/plugin`, which is why the banner check matters.

## Importing v0.2 work items
v0.2 specs have no state file. Run `/ai-engineering:setup` and use its import step: it runs `workstate.sh import` for each spec, reading the Status line (Draft or Approved). Import never produces an `authorised` or `delivering` item and never rewrites the spec; approve and deliver again through `/ai-engineering:approve` and `/ai-engineering:deliver`. It is safe to repeat. Historical merged increments are added only when you confirm them. Imported records are workflow records, not security authority; see [work items](architecture.md#work-items-state-and-authority).

## Parallel worktrees
`/setup` writes `"worktree": {"baseRef": "head"}` by default and tells you the effect: your own `claude --worktree` sessions then branch from the current HEAD instead of the remote default branch. To opt out, delete the `worktree` key from `.claude/settings.json`. `/ai-engineering:deliver` runs tasks sequentially in one checkout by default; parallel worktrees are opt-in per delivery and need this setting, because Claude Code's default worktree base would not contain the work branch.

## Readiness and the version pin
Readiness (`/ai-engineering:review`, and the end of each delivered increment) is certifiable only when all of these hold:
- the session runs the plugin install that Claude Code records for the project;
- that install matches the version pinned in the project's committed `.claude/settings.json`. The pin must be a marketplace source of the form `{source, repo, ref: "v<version>"}`, as a GitHub source is;
- it matches that version's release tag.

Without a pin, from a `--plugin-dir` checkout, or with any mismatch, readiness reports `NOT CERTIFIABLE` and `READY: NO`.

It also reads the guard log under the Git directory, so each increment must start with the exact command `/ai-engineering:deliver` uses: `git switch -c <work-branch> <commit>`, naming the full `origin/<default>` commit. That command's confirmation shows you the base commit. Seeing it does not prove it is the remote's commit; readiness doesn't contact the remote. The base is recorded when the increment starts and never changes.

Practical requirements and limits:
- **`origin/HEAD` must be set.** Repositories created with `git init` and `git remote add` don't set it. Run `git remote set-head origin -a` once.
- **Don't move `origin/<default>` during an increment.** That means no `git fetch`, `git pull` or IDE auto-fetch (some IDEs fetch in the background by default) until it is merged. A moved default-branch ref makes the increment `NOT CERTIFIABLE`, and v0.3.0 has no way to re-anchor it.
- **Keep reflogs.** Readiness reads the increment branch's oldest reflog entry. An increment older than `gc.reflogExpire` (90 days by default), a repository with `core.logAllRefUpdates=false`, or a branch created any other way is `NOT CERTIFIABLE`.
- **Clone compatibility.** The fresh clones don't fetch, so these are `NOT CERTIFIABLE` or fail the gate:
  - partial or blobless clones;
  - repositories using alternates;
  - sparse checkouts (skip-worktree flags);
  - submodules, unless the gate initialises them;
  - Git LFS content, unless the gate fetches it.
- **Diff configuration.** `diff.external`, `diff.<driver>.textconv`, `diff.<driver>.command` or `core.attributesFile` in any Git configuration scope, or a non-empty `.git/info/attributes`, is `NOT CERTIFIABLE`.

Readiness runs the `full` gate in a fresh clone of `HEAD`, never in your checkout. **Make the `full` gate self-contained:** install dependencies inside it (for example `pnpm install --frozen-lockfile && …`), and don't rely on `node_modules`, `.env` or other untracked files. A gate that fails there is `READY: NO`. The gate still runs with your privileges and is not a sandbox. See [readiness](architecture.md#readiness-work-003-c2).

## GitHub authentication
Delivery waits for CI checks and for your merge through authenticated `gh` (`scripts/wait-github.sh`). Run `gh auth login` first. Without it the wait reports `NOT AUTHENTICATED`, which delivery records as an action for you; it never polls unauthenticated.

## gates.json
```json
{
  "fast": "npm run lint && npm run typecheck && npm test",
  "full": "npm run check",
  "externalReview": null
}
```
`fast` runs whenever an implementation agent finishes, so keep it to seconds. `full` runs before review. The main session runs gates through the Bash tool with `bash -c` from the repository root, so your permission rules and sandbox apply. Gates use the file committed at `HEAD` (uncommitted edits are ignored and reported). Until it is committed, implementation checks fall back to the working-tree file and print a `NOTE`, so commit it. During review the full gate is read only from the increment's base commit, with no fallback, and runs in a fresh clone of `HEAD`. Commands containing high-impact operations are refused. See [external-review.md](external-review.md) for `externalReview`.

Every gate executes the project's code with the privileges of whoever runs it; see the [trust boundary](architecture.md#trust-boundary-for-project-code).

### Optional: hook-run fast gate
Setting `AI_ENGINEERING_HOOK_GATES=1` in the environment that launches Claude Code makes a `SubagentStop` hook run the fast gate inside each implementation agent's run, giving it up to 2 automatic fix attempts. Hooks run **outside** Claude Code's permission checks, auto-mode classifier and sandbox, so this executes the agent's working tree, including uncommitted edits, unprompted with your full credentials and network access. Use it only where the host is itself isolated or the code is trusted. Set it in your own environment, not in committed project settings.
