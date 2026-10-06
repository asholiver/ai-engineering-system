# Work Specification
## Status
Approved (by Ashley Oliver, 2026-10-06), in principle, with owner decisions D1–D6 incorporated as recorded in `WORK-001-planning.md`. Delivery is not authorised; it may start only after the gate-bootstrap PR (D5) is merged and the owner explicitly authorises it.
## Work ID
WORK-003: Risk-tiered assurance, gate trust and review evidence (v0.3 PR C)
## Objective
Make assurance depth follow approved, deterministically floored risk. Make gate trust explicit through its lifecycle. Make review evidence exact to commit ranges, so tier-0 work is fast, nothing is re-reviewed without change, and tier-1/2 assurance is never weaker than v0.2. Every layer that caught a real defect in Landra F0 stays.

Decision record: [ADR-0005](../../../docs/decisions/ADR-0005-risk-tiered-assurance-and-gate-trust.md). Programme context: [WORK-001-planning.md](WORK-001-planning.md).
## Scope
Included:
1. **Change classifier.** `classify-change.sh <base> <head>` (name left to the implementer) prints JSON: floor tier, reasons per path, and the unclassified paths.
   - Inputs: the diff (paths including both sides of renames, deletions, binary flags and added lines), the plugin's built-in defaults, and the project's `riskPaths` and `copyPaths` read from `.agents/gates.json` **at the base ref**.
   - **Tier 2 defaults:**
     - auth/session/permission paths;
     - migrations and `*.sql`;
     - destructive SQL statements in added lines;
     - CI workflows (`.github/workflows/**` and equivalents);
     - IaC and deploy configuration;
     - secrets/env templates;
     - dependency manifests and lockfiles;
     - `.agents/gates.json` and every `definedBy` path;
     - plugin, hook and Claude configuration (`.claude/**`, `**/.claude-plugin/**`, `hooks/**`).
   - **Tier 1:** every other path.
   - **Tier 0:** only when every changed path is on the allow-list:
     - Markdown outside `.agents/`;
     - `docs/**`;
     - project `copyPaths`.

   - **Instruction-bearing files are never tier 0 (D4)**, even when they are Markdown. They are classified by what they can influence:
     - **Tier 2:**
       - `.claude/**` (settings, permissions, hooks, agents, commands, skills);
       - plugin manifests, hooks and agent definitions (`**/.claude-plugin/**`, `**/hooks/**`, `**/agents/*.md` under a plugin root);
       - `.github/workflows/**`, `.github/CODEOWNERS`;
       - any standards, security or reviewer instruction that a project lists in its tier-2 `riskPaths`.
     - **Tier 1 at least:**
       - `AGENTS.md`, `CLAUDE*.md` (any directory);
       - any `SKILL.md`;
       - plugin skill and command definitions;
       - all other `.github/**`.
     - These rules apply wherever the files appear, and take precedence over `docs/**` and `copyPaths`.
   - The active work item's own `WORK-NNN.state.json` and `WORK-NNN.log.md` are bookkeeping, and don't change the floor. No other `.agents/**` path, including other items' state, is ignored.
   - Anything that can't be classified (binary, unreadable diff, classifier error, symlink, submodule) raises the tier: tier 1 at least, and tier 2 on a classifier error.
2. **Effective tier** = max(approved tier, classifier floor, action floor).
   - The action floor is tier 2 when guard-log events of a reserved class occurred during the increment, or when a new dependency or external service was recorded.
   - The coordinator recomputes it after each task commit and in readiness.
   - When it rises, the reason is recorded in state without interrupting the owner (unless the cause is itself an escalation trigger).
   - Only the owner lowers a tier, through the WORK-002 token transition. An owner-lowered tier is still floored by the classifier unless the owner explicitly records an override for named paths, which the readiness report shows.
3. **Gate configuration v2.** `.agents/gates.json` stays backward compatible with v0.2:
   - `fast` and `full` accept a string (as in v0.2) or an array of explicit steps.
   - Optional `prelude`: deterministic toolchain activation run in the same shell before each step, for example sourcing a Node version manager and selecting the pinned version.
   - Optional `definedBy`: globs for files that define gate behaviour, such as package manifests whose scripts the steps call, and test, lint and build configs.
   - Optional `riskPaths`: `{ "2": [...], "1": [...] }`.
   - Optional `copyPaths`.
   - `externalReview`: a string (the v0.2 command) or an adapter object (item 9).
4. **Gate trust states**, computed per gate at run time:
   - `absent`: no gate at HEAD or at base.
   - `provisional`: defined at HEAD but not at base. Verdicts are labelled `PROVISIONAL`, drive fix loops, and never certify.
   - `trusted`: defined at base, and HEAD has the same definition and `definedBy` content.
   - `proposed-change`: base and HEAD differ in the gate definition or any `definedBy` file. The difference is printed verbatim in the readiness report, and the increment is tier 2. What happens next depends on which part changed:
     - **Only the gate definition in `.agents/gates.json` differs, and every `definedBy` file is identical to base:** the base definition certifies, because the change can't alter the command that checks it.
     - **Any `definedBy` file differs from base** (modified, added, deleted or renamed): certify mode produces the explicit non-certifying verdict `NOT CERTIFIABLE (definedBy changed: <paths>)`. It never reports `PASSED`, whatever the command's exit code, because the change has altered the implementation of the gate that would check it.
       - The gate may still run as a labelled non-certifying check to guide fixes.
       - Readiness follows the gate-change route in item 5: structural evidence, safe canaries or the review fallback, external review, and owner acceptance at merge. The change becomes trusted only after it is merged into the base.

   The v0.2 working-tree fallback and the `CLAUDE_PROJECT_DIR` lookup are removed. An uncommitted gate file is `absent`, with a hint to commit it.
5. **Bootstrap verification** for an increment whose gates are `provisional`, or that changes gate definitions:
   - **Structural checks** (deterministic script):
     - every step's exit status propagates: no `|| true`, `; true`, `set +e`, `exit 0` masking, and no unguarded pipes that mask failures;
     - a step calling a package or task script has that manifest in `definedBy`;
     - no step classified high-impact by the guard;
     - if a CI workflow exists, it invokes the same gate definition (a heuristic that reports, not one that blocks).
   - **Safe canaries:** for step types that support a controlled failure, run the step in a disposable worktree that contains a deliberately broken fixture. Examples:
     - a failing test file for test runners;
     - a lint violation;
     - a type error;
     - a syntax error for builds;
     - an obviously fake, scanner-recognised test secret for secret scanners.

     The step must fail. Canary worktrees are never committed to the work branch, pushed or left behind.
   - **No canary** for steps that touch databases, infrastructure, credentials, networks or external resources. Those get structural verification plus explicit review evidence. Real data or resources are never mutated to make a gate fail.
   - Evidence (step, fixture description, exit code, worktree base SHA) is recorded in the ledger.
   - The same route applies to an increment that changes any `definedBy` file of a trusted gate.
   - Readiness for a bootstrap or gate-change increment is `READY FOR BOOTSTRAP ACCEPTANCE` only with structural, canary-or-fallback and external evidence, and it names owner acceptance at merge as the trust boundary. The gates become `trusted` only once merged to the base.
6. **Certification.**
   - Certifying runs need a committed, clean tree (no modified, staged or untracked non-ignored files) with HEAD equal to the head being certified. Otherwise the verdict is `NOT CERTIFIABLE (dirty tree)` and never `PASSED`.
   - `prelude` runs first.
   - Unconfigured gates are `NOT CONFIGURED`, never passed.
7. **Gate ledger:** `<git-common-dir>/ai-engineering/gate-log.jsonl`, one line per run, recording:
   - time;
   - gate;
   - trust state;
   - head SHA;
   - config ref and its SHA-256;
   - whether the tree was clean;
   - verdict;
   - exit code;
   - duration.

   A run of the same gate at the same head after a `FAILED` result prints `RERUN-AFTER-FAILURE`, and readiness requires a cause recorded through the transition script. Diagnosing the cause is autonomous. The ledger is bounded, and a logging failure never changes a verdict.
8. **Review ledger** (state fields under `increments[]`):
   - `gates[]`: references to gate-log entries;
   - `reviews[]`: `{kind: security|qa|external, provider, rangeBase, reviewedHead, verdict, findingIds[], at, historical}`;
   - findings join WORK-002's `findings[]` and dispositions.

   Internal reviews are briefed with the range since the last reviewed head and cover only that delta, unless the classifier reports a tier increase that needs a wider look.
9. **External evidence adapters** (provider-neutral). The adapter configuration is read from the base ref.
   - **Invocation:** the adapter receives base SHA, head SHA, optional PR number and spec path.
   - **Output:** one strict JSON object, validated against the schema and treated as untrusted data.
     - Schema notation (explanatory only, not JSON; `a|b` lists the allowed values):
       ```text
       { provider, status: complete|pending|none|error,
         reviewedRanges: [{base, head}],
         findings: [{id, severity, actionable, resolved, path, line, summary, url}] }
       ```
     - Valid JSON example of complete evidence with one unresolved actionable finding (illustrative values):
       ```json
       {
         "provider": "coderabbit",
         "status": "complete",
         "reviewedRanges": [
           { "base": "1111111111111111111111111111111111111111", "head": "2222222222222222222222222222222222222222" }
         ],
         "findings": [
           {
             "id": "thread-1",
             "severity": "minor",
             "actionable": true,
             "resolved": false,
             "path": "src/example.ts",
             "line": 42,
             "summary": "Example finding text",
             "url": "https://github.com/example/repo/pull/1#discussion_r1"
           }
         ]
       }
       ```
     - The implementation adds a fixture test proving that this example parses and validates.
   - **Legacy command:** the v0.2 `externalReview` command string is kept unchanged as the `command` adapter. Exit 0 or 1 maps to complete evidence for the exact head, with no findings or with one blocking finding carrying the truncated text. Other exit codes are `error`, and the old environment variables are still provided.
   - **`provider`** must differ from the implementation provider. Claude reviewing Claude never counts, and internal reviews never satisfy the external requirement.
   - **Reusable adapter** `github-pr-reviews` (D6), shipped with the plugin:
     - The reviewer identity (one or more account logins) is configuration at the base ref, never hard-coded. CodeRabbit (`coderabbitai[bot]`) is the documented example configuration.
     - Uses authenticated `gh` only.
     - Evidence counts only when **both** hold:
       - a submitted review by a configured reviewer has a `commit_id` equal to the head being certified, or reviewed ranges that reach it;
       - every review thread from a configured reviewer marked actionable on that range is resolved or outdated by a later reviewed commit.
     - Merely detecting that a reviewer posted something (a summary comment, a review at an older commit, a "review in progress" status) is `pending` or `none`, never `complete`.
     - How a provider marks findings as actionable or non-actionable (for example nitpicks) is adapter configuration with a conservative default: unknown means actionable.
     - Tested only against recorded fixtures.
10. **Coverage.** External review is satisfied when the evidence covers head. Otherwise every commit after the last reviewed head must be either tier-0-only, the active item's own bookkeeping, or inside the provider's reviewed incremental ranges. Unresolved actionable findings block.
11. **Tier-dependent depth.**

    | | Tier 0 | Tier 1 | Tier 2 |
    | :- | :- | :- | :- |
    | Full gate (or adapter-verified CI evidence of the trusted gate) at head | yes | yes | yes |
    | QA | spot check against intent | full acceptance-criteria check | full, including negative and failure-path tests |
    | Internal security review (Opus, delta) | none | only when the classifier flags a security category | yes |
    | External review | optional | required at head | required at head |
    | Explicit residual-risk list | no | no | yes |

12. **One readiness procedure.** A deterministic script evaluates an increment and prints a `READINESS` block. The `review` skill runs it, dispatches the missing assurance, records results and re-runs it. `deliver` uses the same skill at the end of each increment (WORK-002), and there is no separate Prove procedure. The block contains:
    - tier, with its reasons;
    - each gate verdict, with trust state and rerun labels;
    - QA;
    - security review;
    - external coverage;
    - findings and their dispositions;
    - HIGH-or-above fixes;
    - decisions recorded from conversation;
    - planned owner actions still open;
    - the residual-risk list (tier 2);
    - bootstrap notes;
    - `READY: YES | NO - reasons`.
13. **Historical evidence import** for merged increments: external evidence recorded with `historical: true`, for example Landra's CodeRabbit review at `64fbb11`. Historical entries never satisfy a new increment.
14. **Metrics report.** One script summarises a work item from state, the gate ledger and the guard log:
    - authorisation-to-readiness time per increment;
    - owner-wait proportion (decisions only; planned owner actions shown separately);
    - interruptions by trigger;
    - guard asks and denies by class;
    - review runs, and re-reviews of unchanged ranges (target 0);
    - recoveries;
    - dirty-tree refusals, and reruns with and without a recorded cause;
    - findings by layer (pre-PR internal, external, escaped).

    Escaped defects are recorded as findings with `source: escaped`. Counting "continue" prompts stays a documented transcript analysis method.
15. **Release and documentation consistency.**
    - `scripts/check.sh` asserts that every pinned version reference in `README.md` and `docs/**` (for example `ai-engineering-system@vX.Y.Z`, `"ref": "vX.Y.Z"`) names a version present in `versions/CHANGELOG.md`.
    - The existing plugin.json/CHANGELOG check stays.
    - `CONTRIBUTING.md` "Releasing" gains a short checklist: tag, release notes, and upgrade verification through the session banner.
16. **Removals:**
    - `scripts/gate-fast.sh`;
    - the `SubagentStop` entry in `hooks/hooks.json`;
    - `AI_ENGINEERING_HOOK_GATES` everywhere (docs, tests, `model-policy.md`, `consuming-project.md` "Optional: hook-run fast gate");
    - the working-tree gate fallback in `lib.sh`.

    Tests for removed behaviour are replaced by tests asserting the removal.

Excluded (non-goals):
- Lifecycle and authority (WORK-002) and parsing (WORK-001).
- Sandboxing untrusted code (ADR-0002 still applies).
- Making the gate ledger tamper-proof.
- Adapters for providers other than the generic command and GitHub PR reviews.
- Changing Landra's gates.
## Requirements
- bash + jq, and table-driven tests in `tests/run.sh` with fixtures. No network in tests.
- Every verdict line keeps v0.2's vocabulary (`PASSED`, `FAILED`, `NOT CONFIGURED`, `REFUSED`) and adds the trust state and rerun labels. Unrun checks are never reported as passed.
- Readiness re-runs the trusted full gate itself, or uses adapter-verified CI evidence for the exact head. A ledger entry alone is never proof.
## Business rules
Invariants:
- Trusted certifying gates come only from the base ref.
- Provisional or new gates never certify themselves.
- A change never certifies its own gate definitions.
- Unrun checks are never reported as passed.
- A failed trusted gate is evidence.
- Controls, tests and gates are never weakened to pass.
- Reviewers can't edit files.
- Tier 1/2 work needs independent review from another provider.
- Learnings are never promoted automatically.
- Agents only raise tiers.
## Architecture
Affected areas:
- `plugins/ai-engineering/scripts/`:
  - `lib.sh` (gate loading, trust state);
  - `run-gate.sh` (certify mode, prelude, ledger, labels);
  - `external-review.sh` (folded into the adapter mechanism; the name may stay as the entry point);
  - new classifier, structural verifier, readiness, metrics and reference adapter scripts;
  - `gate-fast.sh` removed.
- `hooks/hooks.json`.
- `skills/review` (rewritten around readiness), `skills/deliver` (references only), `skills/setup` (gates template v2, `definedBy` prompt).
- `agents/qa.md` and `agents/security-reviewer.md` (range-scoped briefs, tier depth).
- `scripts/check.sh`, `tests/run.sh`, `docs/`.

Script boundaries are left to the implementer.
## Data
- State additions under `increments[]`: `tier {approved, effective, reasons[], loweredBy?, overrides?}`, `gates[]`, `reviews[]`.
- Gate-log line as in Scope item 7.
- Adapter evidence schema as in Scope item 9.
## API
- **`run-gate.sh`:** gains a certify mode. Exit codes stay as in v0.2 (0, 1, 3, 4, 5), plus distinct codes for `NOT CERTIFIABLE` and `PROVISIONAL`.
- **Classifier, readiness and adapter scripts:** each has documented exit codes and JSON output.
- **External-review contract:** documented in `docs/external-review.md`.
## UI
None beyond the readiness and verdict text.
## Security
- **Self-certification:** gate definitions, `definedBy`, `riskPaths`, `copyPaths` and adapter configuration are all read from the base ref. Changes to them are tier 2 and shown verbatim.
- **Tier-0 abuse:**
  - narrow allow-list;
  - instruction-bearing files excluded (D4);
  - `.agents/**` never tier 0;
  - mixed changes take the highest tier;
  - renames are classified on both sides.
- **Adapter output** is untrusted data. It is schema-validated and never executed or followed as instructions. Commands come from the base ref and are guard-checked (`ask` or `deny` means refused).
- **Canaries** run only in disposable worktrees with controlled fixtures. Steps that touch external systems never get a canary.
- **Dirty-tree certification** is refused, so secret scans see what will be published.
- **Ledger forgery** can't produce readiness on its own: readiness re-runs gates or verifies CI evidence through the adapter.
## Scalability and reliability
- The classifier and readiness scripts are bounded on large diffs: they stream, and above a cap the classification goes to tier 2.
- Adapter calls time out with bounded retries. `pending` is a wait state, not an error.
## Observability
The metrics report (Scope item 14) supports every dogfood success criterion.
## Testing
Deterministic cases in `tests/run.sh`:
- **Tier-0 regressions:**
  - `docs/a.md` → 0;
  - `README.md` → 0;
  - `.agents/learnings/x.md` → ≥1;
  - `.agents/specs/active/OTHER.state.json` → ≥1;
  - `.agents/gates.json` → 2;
  - `AGENTS.md`, `CLAUDE.md`, `CLAUDE.local.md`, `docs/CLAUDE.md`, `packages/x/AGENTS.md` → ≥1;
  - `.claude/agents/x.md`, `.claude/commands/x.md`, `.claude/skills/s/SKILL.md`, `.claude/settings.json` → 2;
  - `plugins/p/skills/s/SKILL.md`, `plugins/p/commands/c.md` → ≥1;
  - `plugins/p/agents/a.md`, `plugins/p/hooks/hooks.json`, `plugins/p/.claude-plugin/plugin.json` → 2;
  - `docs/skills/SKILL.md` → ≥1 (the exclusion beats `docs/**`);
  - a `copyPaths` entry that matches `AGENTS.md` → still ≥1;
  - `.github/pull_request_template.md` → ≥1;
  - `.github/workflows/ci.yml`, `.github/CODEOWNERS` → 2;
  - rename of `docs/a.md` to `src/a.ts` → ≥1;
  - `docs/a.md` plus `src/b.ts` → 1;
  - the active item's own state and log only → unchanged floor.
- **Tier-2 defaults:** migrations, a lockfile, a workflow, `.env.example`, `definedBy` files, and an added `DROP TABLE` line in a test file each → 2.
- **Unknown and error:** binary → ≥1; classifier failure → 2.
- **`riskPaths` and `copyPaths`:** read from base; values changed on the branch are ignored for this increment's classification.
- **Effective tier:** max rule; an owner-lowered tier is still floored; an agent attempt to lower is refused.
- **Gate states:** absent, provisional, trusted and proposed-change, each with the correct verdict label. Provisional never yields a certifying `PASSED`. A `definedBy` change gives proposed-change and tier 2, and the diff is shown.
- **`definedBy` self-certification regression** (hermetic temporary repository, no external effects):
  - Base `gates.json` has `"full": "./gate-check.sh"` with `"definedBy": ["gate-check.sh"]`. The base `gate-check.sh` exits 1.
  - The change replaces `gate-check.sh` with `true` (exit 0) and is committed on a clean tree.
  - Certify mode against base → `NOT CERTIFIABLE (definedBy changed: gate-check.sh)`, never `PASSED`, with a non-zero exit, and readiness is `NO`.
  - The same for a deleted, renamed or newly added `definedBy` file.
  - **Controls:**
    - a change that touches no `definedBy` file and passes → certifying `PASSED`;
    - a change that edits only the `gates.json` command while `definedBy` files are unchanged → the base command is used and the change is shown;
    - a non-certifying run in implementation mode is labelled and never recorded as certifying in the ledger.
- **Removed fallback:** an uncommitted `gates.json` → `absent`/`NOT CONFIGURED`, with a hint.
- **Structural verifier:** `|| true`, `set +e`, a masked pipe, and a package script without its manifest in `definedBy` are each flagged. A clean explicit gate passes.
- **Canaries:** a fixture project with a test-runner gate fails on the canary and passes without it. The canary worktree is removed afterwards, and the work branch and remotes are untouched. A step marked as external gets no canary and requires the review-evidence fallback.
- **Certification:** an untracked file, a staged change or a modified file → `NOT CERTIFIABLE`.
- **Prelude:** runs before each step, and a prelude failure fails the gate.
- **Ledger:** a rerun after failure is labelled, and readiness is blocked without a recorded cause and unblocked with one.
- **Adapters:**
  - the legacy command string with exits 0, 1 and 2 behaves as v0.2;
  - `github-pr-reviews` against fixtures:
    - a review at the exact head with no unresolved actionable threads → complete;
    - incremental reviewed ranges reaching head → complete;
    - review only at an older head → not complete;
    - a review at head with one unresolved actionable thread → blocking;
    - a thread outdated by a later reviewed commit → not blocking;
    - only a summary or "in progress" comment → pending or none;
    - a review at head by a login that isn't configured → ignored;
    - a reviewer login changed on the branch → the base configuration is used;
    - unknown actionability → treated as actionable;
    - malformed JSON → error;
    - a provider equal to the implementation provider → rejected;
  - adapter configuration changed on the branch → the base configuration is used.
- **Coverage:** evidence at an earlier head with later tier-0-only commits → covered; with a later `src` commit → not covered; with the active item's own bookkeeping commits → covered.
- **Readiness matrix:** each tier's requirements, plus the bootstrap case.
- **Historical evidence** doesn't satisfy a new increment.
- **Metrics report** on a fixture state, gate ledger and guard log produces the expected numbers.
- **Removals:** no `SubagentStop` hook; `gate-fast.sh` absent; `AI_ENGINEERING_HOOK_GATES` absent from the repository.
- **`check.sh`:** a fixture README referencing an unknown version fails the consistency check.

End-to-end scenario in a scratch project (self-development protocol, evidence in `WORK-003.log.md`):
- **E1.** Bootstrap gates: provisional verdicts, structural and canary evidence, and readiness says bootstrap acceptance.
- **E2.** After merge: gates trusted. A docs-only increment reaches readiness with no QA or security agents and no external review.
- **E3.** A `src` change requires external evidence. A fake adapter fixture shows evidence at an earlier head plus a later `src` commit → not ready, until evidence covers head.
## Risks
- **Over-classification** (too much tier 2) slowing work. Measured; `riskPaths` tunes it at the base ref.
- **The canary fixture approach** varies by toolchain. The structural-plus-evidence fallback always exists.
- **GitHub API shapes for review threads.** Isolated in the reference adapter and fixture-tested.
## Acceptance criteria
1. The classifier is deterministic, reads project configuration only from base, and raises on uncertainty. It never puts `.agents/**` (other than the active item's bookkeeping) in tier 0, and never puts instruction-bearing files in tier 0; they are tier 1 or 2 by what they can influence (D4 regression cases pass).
2. Effective tier follows the max rule. Agents can't lower it, and owner lowering is recorded and floored.
3. Gate trust states are computed and labelled correctly. Provisional and proposed-change definitions never certify themselves. When any `definedBy` file differs from base, certify mode returns `NOT CERTIFIABLE`, never `PASSED` (regression fixture above).
4. Bootstrap acceptance requires structural evidence, safe canaries (or the structural-plus-review fallback), external review and owner acceptance at merge. No real resource is touched.
5. Certification refuses dirty trees, and `prelude` is applied.
6. The gate ledger labels reruns after failure, and readiness requires a recorded cause.
7. The review ledger ties every review to an exact range. No review repeats on an unchanged range.
8. The legacy external-review command works unchanged as an adapter. The reusable GitHub PR-review adapter takes its reviewer identity from base-ref configuration. It accepts evidence only for the exact head (or incremental ranges reaching it) with no unresolved actionable findings, never merely because a reviewer posted.
9. One readiness procedure serves both `deliver` and `/review`, with tier-dependent depth as in the table.
10. Historical evidence is supported and never counts for new increments.
11. The metrics report covers every dogfood metric that isn't transcript-only.
12. The release and documentation consistency check is in `scripts/check.sh`.
13. `gate-fast.sh`, the `SubagentStop` gate, `AI_ENGINEERING_HOOK_GATES` and the working-tree fallback are removed.
14. `scripts/check.sh` passes.
## Definition of done
- Implementation complete; deterministic tests pass; E1–E3 evidence recorded
- `scripts/check.sh` passes
- Internal security review (Opus) of classifier, trust states, certification, adapters and coverage with no unresolved findings
- Independent external review passes
- Human acceptance complete
## Compatibility and migration
- **v0.2 `gates.json`:** works unchanged. String gates are single-step. A string `externalReview` is the command adapter. Missing optional keys use defaults.
- **Behaviour changes** (changelog):
  - no working-tree fallback;
  - no hook gate;
  - dirty-tree certification refused;
  - tier-dependent review depth.
- **Existing gates already on a project's base** are `trusted` (historical trust). They don't need bootstrap verification, but changes to them do.
- **Landra:**
  - its main-branch gates are trusted historically;
  - adding `definedBy`, `riskPaths` and any adapter configuration is a tier-2 proposed-change. It arrives as its own small PR or the first commit of F0-S2, and is reviewed externally;
  - CodeRabbit evidence for PR #1 is imported as historical.
## Documentation
- `docs/architecture.md`: Quality gates, Trust boundary (amended), tiers, readiness, ledgers.
- `docs/external-review.md`: the v2 contract with adapters and coverage; the legacy command section kept.
- `docs/consuming-project.md`: the `gates.json` v2 keys, and removal of the hook-gate section.
- `docs/model-policy.md`: retries without the hook gate.
- `CONTRIBUTING.md`: release checklist.
- `versions/CHANGELOG.md`.
- A note in ADR-0002 pointing to ADR-0005.
## Independent review
- **Internal review.** Opus security review with a brief on self-certification and tier-0 escape attempts.
- **External review.** CodeRabbit on the PR at its head SHA, with no unresolved actionable findings (D5 arrangement while v0.2.0 governs).
- **Gate scripts.** Under v0.2 the gate commands come from the base ref, but `tests/run.sh` and `scripts/check.sh` are executed from the change itself. Reviewers must check every diff to those two files, and a weakened or removed check is a blocking finding.
- **Owner acceptance.** The owner reviews the tier tables, tier-0 exclusions and readiness block text.
## Dependencies
- Requires WORK-002's state model, transition script and decision/finding records. Develop after WORK-002's state schema is merged, or at least stable.
- Uses WORK-001's classification interface for refusing high-impact configured commands and guard-log events.
- Ships together with WORK-001 and WORK-002 as v0.3.0.
## Settled owner decisions
- Risk derives from approved metadata plus a deterministic floor; agents can't self-declare low risk; only the owner lowers a tier.
- The tier-0 default allow-list.
- External review isn't required for trivial tier-0 work, but is for substantive and security-relevant work.
- Bootstrap trust boundary: reviewed bootstrap merge plus external review plus owner acceptance.
- Safe canaries only, with the structural-plus-review fallback.
- Removal of the hook-gate machinery and the working-tree fallback.
- D4: instruction-bearing Markdown and configuration are never tier 0, and are classified by what they can influence.
- D5: the gate-bootstrap PR is merged before this work starts, and CodeRabbit is the external reviewer for this PR.
- D6: the GitHub PR-review adapter is reusable, its reviewer identity is configuration, and it validates head coverage and unresolved actionable findings.
## Open decisions
- None. D1–D6 are resolved (see `WORK-001-planning.md`).
## Implementation state
<!-- v0.2 deliver records task status and verdict lines here. Keep entries to one line each; put detailed evidence in WORK-003.log.md. -->
-
## Review state
<!-- v0.2 review records its status block here. -->
-
