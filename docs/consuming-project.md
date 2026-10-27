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

## Installing versus certifying
Installing the plugin and running `/ai-engineering:setup` gives a project the standards, specialist agents, lifecycle commands and command guards. Using readiness as a certification gate is a separate matter, and in v0.3.0 it is not available:
- Readiness never reports `READY: YES` (see below). Treat the `READINESS` block as a structured report: `NOT CERTIFIABLE` reasons and failed checks are real problems to fix, but a run without them still ends `READY: NO`.
- Readiness is evaluated in the repository where the increment was started and delivered. It needs that repository's increment-branch reflog and local guard log, so run from a fresh clone or a CI checkout it is `NOT CERTIFIABLE`. Don't make it a CI merge check. (Readiness itself runs the gate and the external review in temporary fresh clones of `HEAD`; that is a different thing.)
- Your own CI checks, your review and your merge remain the controls that decide whether a change ships.

## Readiness and the version pin
Readiness (`/ai-engineering:review`, and the end of each delivered increment) is certifiable only when all of these hold:
- the session runs the plugin install that Claude Code records for the project;
- that install matches the version pinned in the project's committed `.claude/settings.json`. The pin must be a marketplace source of the form `{source, repo, ref: "v<version>"}`, as a GitHub source is;
- it matches that version's release tag.

Without a pin, from a `--plugin-dir` checkout, or with any mismatch, readiness reports `NOT CERTIFIABLE` and `READY: NO`.

It also reads the guard log under the Git directory, so each increment must start with the exact command `/ai-engineering:deliver` uses: `git switch -c <work-branch> <commit>`, naming the full `origin/<default>` commit. The base is recorded when the increment starts and never changes. An increment that became active before v0.3.0 has no recorded base and is `NOT CERTIFIABLE`; start a new increment.

**`READY: YES` is not reachable in v0.3.0.** The guard log records only that the start command was asked, not that you approved it or that it ran, and readiness doesn't contact the remote. So readiness can't verify where the base came from: the block says `BASE PROVENANCE: UNVERIFIED`, and READY is NO for that reason. Every other check still runs and is reported. Closing this needs a separately approved base-provenance design. One [proposal](../.agents/specs/active/WORK-003-base-provenance-proposal.md), an owner-signed increment-start approval that depends on WORK-004's signed approvals and G1, is under design review; none is approved or implemented.

Practical requirements and limits:
- **Tools.** Readiness finds `jq` and `git` only in `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin` or `/home/linuxbrew/.linuxbrew/bin`, never through your `PATH`, and needs Git 2.40 or later. Otherwise it exits 2 with no block. Your gate and reviewer commands still run with your `PATH`.
- **`origin/HEAD` must be set.** Repositories created with `git init` and `git remote add` don't set it. Run `git remote set-head origin -a` once.
- **Don't move `origin/<default>` during an increment.** That means no `git fetch`, `git pull` or IDE auto-fetch (some IDEs fetch in the background by default) until it is merged. A moved default-branch ref makes the increment `NOT CERTIFIABLE`, and v0.3.0 has no way to re-anchor it. The way forward is a new increment started from the current default branch, carrying the work over deliberately.
- **Keep reflogs.** Readiness reads the increment branch's oldest reflog entry. An increment older than `gc.reflogExpire` (90 days by default), a repository with `core.logAllRefUpdates=false`, or a branch created any other way is `NOT CERTIFIABLE`.
- **Clone compatibility.** The fresh clones don't fetch, so these are `NOT CERTIFIABLE` or fail the gate:
  - partial or blobless clones;
  - repositories using alternates;
  - sparse checkouts (skip-worktree flags);
  - submodules, unless the gate initialises them;
  - Git LFS content, unless the gate fetches it.
- **Diff configuration.** Readiness neutralises most user-level diff settings in its clones, such as an attributes file, the big-file threshold, diff prefixes and submodule ignore settings. When an external reviewer is configured, or the tier is 1 or 2, some it cannot neutralise make readiness `NOT CERTIFIABLE`:
  - `diff.external`, set in your user or system configuration (for example for a structural diff tool);
  - a changed text file with `-diff`, `binary`, or a diff driver that has `textconv`, `command` or `binary` configured;
  - a changed file with a configured filter driver;
  - a changed path that the reviewer's own `git diff` doesn't show.

  At tier 0 with `"externalReview": null` committed, none of these apply.
- **Binary files.** Reviewers see a binary change only as `Binary files differ`, so a changed binary file is `NOT CERTIFIABLE` unless it is an image or font asset (`png`, `jpg`, `jpeg`, `gif`, `webp`, `ico`, `avif`, `woff`, `woff2`, `ttf`, `otf`, non-executable, with matching leading bytes) under a directory listed in `binaryAssets` in the base commit's `.agents/gates.json`, for example `"binaryAssets": ["public/images/", "src/assets/fonts/"]`. Entries are relative directories ending in `/`. Change the list in its own pull request: a branch that changes it is `NOT CERTIFIABLE`. Each changed binary is listed with its size and SHA-256.
- **File names and links.** A tracked path that starts with `"` or contains a carriage return or newline, and a symbolic link that points outside the repository (or to an absolute path, or into a directory that does not exist in the checkout), are `NOT CERTIFIABLE`.
- **Tools and temporary directory.** Readiness takes its own `git`, `jq` and other tools only from the directories listed under Tools above, not from your `PATH`. That stops `PATH` substitution only: the Homebrew and `/usr/local` directories are usually writable by you, so anything running as your user can replace those tools. Your `full` gate and reviewer commands still get your `PATH`, `HOME`, locale, library paths and Perl settings. Readiness drops `BASH_ENV`, `ENV`, `SHELLOPTS`, `BASHOPTS`, exported shell functions, preload and audit libraries, `GCONV_PATH`, `GREP_OPTIONS`, `GREP_COLOR`, `GREP_COLORS`, `POSIXLY_CORRECT`, the classifier's cap overrides and every `GIT_*` variable for everything it runs, and library-path and Perl variables for everything except those commands. Other environment variables still pass through. `TMPDIR` must be outside the repository, its worktrees and any superproject. A `TMPDIR` inside some other, unrelated repository is allowed (an accepted limitation): readiness leaves that repository unchanged, but a Git command your gate runs from its temporary directory there would find it.
- **Time.** A readiness run can take up to 50 minutes: the gate is limited to 30, the external review to 15. A timeout is `READY: NO`.
- **Reviewer commands** run in a clone with no remote, so use `REVIEW_BASE_REF` and `REVIEW_HEAD_REF` rather than `origin/...` or `gh pr diff`.

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
`fast` runs whenever an implementation agent finishes, so keep it to seconds. `full` runs before review. The main session runs gates through the Bash tool with `bash -c` from the repository root, so your permission rules and sandbox apply. Gates use the file committed at `HEAD` (uncommitted edits are ignored and reported). Until it is committed, gates are `NOT CONFIGURED` and print a `NOTE`, so commit it. During review the full gate is read only from the increment's base commit, with no fallback, and runs in a fresh clone of `HEAD`. Commands containing high-impact operations are refused. See [external-review.md](external-review.md) for `externalReview`.

Every gate executes the project's code with the privileges of whoever runs it; see the [trust boundary](architecture.md#trust-boundary-for-project-code).
