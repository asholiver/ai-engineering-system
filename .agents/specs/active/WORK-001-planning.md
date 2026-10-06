# Planning Session: ai-engineering-system v0.3.0 (WORK-001, WORK-002, WORK-003)
This is the canonical planning record for the whole v0.3 programme. The three work specs reference it instead of repeating it.
## Objective
Fix the measured problems from the Landra v0.2 dogfood while keeping the safeguards that caught real defects. Governing principle: agents have autonomy over implementation, not authority over intent.

| Spec | PR | Scope | Decision record |
| :- | :- | :- | :- |
| [WORK-001](WORK-001.md) | A | Guard v2: structured action classification | [ADR-0003](../../../docs/decisions/ADR-0003-structured-action-guard.md) |
| [WORK-002](WORK-002.md) | B | Work lifecycle and authority | [ADR-0004](../../../docs/decisions/ADR-0004-work-authority-and-lifecycle.md) |
| [WORK-003](WORK-003.md) | C | Risk-tiered assurance, gate trust, review evidence | [ADR-0005](../../../docs/decisions/ADR-0005-risk-tiered-assurance-and-gate-trust.md) |

All three ship together as v0.3.0.
## Decisions
DECIDED by Ashley Oliver, approved on 2026-10-06 with the refined architecture:
- **Work-branch pushes** are autonomous once delivery of an approved scope is authorised. Default-branch pushes, merges, releases, publishing, production deployment and other reserved operations remain human.
- **Remediation** depends on whether resolving a finding means fixing it or accepting risk, not on severity. Risk is never accepted silently.
- **No pre-authorisation write hook** initially. Boundary crossings are measured instead.
- **No universal external review** for trivial tier-0 changes. Risk comes from approved metadata plus a deterministic floor, and agents can't declare work low-risk.
- **Bootstrap trust** comes from the reviewed bootstrap merge, external review and owner acceptance. No self-certification.
- **PRs:** one independently reviewable PR per meaningful increment by default. This is not an invariant.
- **Landra:** release v0.3.0, upgrade Landra, migrate WORK-001, and use the next F0 increment to measure.
- **Grouping:** A, B and C. A is isolated because it is security-sensitive. C depends on B.
- **Command-token mechanism:** silent and non-blocking (event: D1).
- **Tier 0:** Markdown outside `.agents/`, `docs/**`, and project-declared copy paths from base-ref configuration. `.agents/**` is never tier 0 (instruction-file exclusions: D4).
- **Parallel worktrees** by default with an opt-out. The coordinator owns Git, and specialists never write to it.
- **Deployment:**
  - production is always owner-authorised;
  - persistent or shared environments need owner authority unless the approved delivery policy pre-authorises them;
  - ephemeral preview deployment is autonomous inside an authorised increment, when the resources and credentials already exist and no owner-level decision is needed;
  - creating or changing accounts, credentials or consequential resources is owner-only.
- **Bootstrap canaries:** safe and controlled only. Where no safe canary exists, structural verification plus explicit review evidence.
- **Governance:** v0.2.0 (installed) governs development of v0.3.0. Unreleased source is exercised only in scratch projects.
DECIDED by Ashley Oliver on 2026-10-06 (planning decisions D1–D6):
- **D1:** authority tokens are minted from `UserPromptExpansion`, never `UserPromptSubmit`. The authority signal must be an explicit slash command typed by the owner, not background, scheduled or cross-session text.
- **D2:** the human-only `/ai-engineering:approve` command handles spec approval, finding or risk acceptance, tier lowering and revocation. Approval and delivery authorisation stay distinct.
- **D3:** no main-session or coordinator model requirement. The user chooses the main-session model, and model routing stays in agent definitions. Opus is still required where the risk policy calls for the Opus security reviewer.
- **D4:** instruction-bearing Markdown and configuration never qualify as tier 0, and are classified by what they can influence (tier 1 or 2). At minimum this covers `AGENTS.md`, `CLAUDE*.md`, `.claude/**`, `SKILL.md`, plugin agent, skill and command definitions, and `.github/**`. Regression coverage is required.
- **D5:** a separate, minimal gate-bootstrap PR is merged before A, B or C are implemented. See "Gate bootstrap (D5)" below.
- **D6:** a reusable GitHub PR-review evidence adapter ships with the plugin.
  - Reviewer identity is configuration, with CodeRabbit as the example.
  - It validates evidence against the exact head and unresolved actionable findings, not merely that a reviewer posted.
- **Implementation reconciliations accepted:**
  - Guard v2 treats both `ask` and `deny` as high-impact where that matters;
  - preview deployment depends on the authorised delivery policy, with the guard as the enforcement point;
  - the active item's own state and log are narrowly treated as bookkeeping;
  - authority and state records are tamper-evident, not a sandbox;
  - runtime provenance proves the active plugin version and root;
  - package-script gate steps are acceptable when their manifest is in `definedBy`;
  - `/deliver` adds no approval prompt for policy already approved in the spec.
- The three specs are approved in principle with D1–D6 incorporated. Delivery is **not** authorised.
## Open questions
- None. All owner decisions are resolved.
## Gate bootstrap (D5)
- A separate PR adds only `.agents/gates.json`, which delegates to the existing `tests/run.sh` and `scripts/check.sh`. It contains no v0.3 machinery and no other changes. It doesn't touch the planning PR.
- **Before acceptance:**
  - run the existing checks directly;
  - independently review the full gate definition and the commands it delegates to;
  - get a CodeRabbit external review with no unresolved actionable findings;
  - present the exact definition and the evidence to the owner.
- **The configuration is not trusted because an agent created it or because it reports green.** The owner establishes the trust boundary by reviewing and merging the PR. After that merge, A, B and C treat the base-ref gates as trusted under the v0.2 model.
- **Limitation under v0.2,** which reviewers of A, B and C must cover: the gate *commands* come from the base ref, but the delegated scripts are run from the change. Every diff to `tests/run.sh` or `scripts/check.sh` in A, B or C is a mandatory review item, and a weakened or removed check is a blocking finding. v0.3 `definedBy` (WORK-003) closes this for later work.
- **External review for A, B and C while v0.2 governs:** CodeRabbit on each PR at its head SHA, with no unresolved actionable findings, recorded in that spec's Review state. v0.2 `/review` will still print `EXTERNAL REVIEW: NOT CONFIGURED`, because v0.2 can't consume PR reviews. The owner judges readiness with the CodeRabbit evidence.
## Assumptions
- `gh` is not installed on this machine (observed 2026-10-06). The v0.3 wait helper and reference adapter need authenticated `gh`. Installing and authenticating it is a **planned owner action** before the next dogfood run, and while developing WORK-002 and WORK-003 if their fixture tests aren't enough.
- The exact `command_name` that `UserPromptExpansion` reports for plugin skills is verified at the start of WORK-002.
## Specialist input
Security review is required on all three PRs, with emphasis on:
- **A:** guard evasion;
- **B:** the token, state and guard-policy commit;
- **C:** self-certification and tier-0 escape.
## Cross-work dependencies
- **A ∥ B:** A and B can be developed in parallel. B's guard-policy integration (WORK-002 Scope item 7) waits for A to merge.
- **C after B:** C needs B's state model to be merged, or at least stable. C uses A's classification interface.
- **Shared files:**
  - `agents/{frontend,backend,platform}.md`: A edits the Git and Edit/Write wording; B edits handoffs and decision reporting.
  - `guard-bash.sh`: A, plus B's policy commit.
  - `hooks/hooks.json`: B adds an event; C removes `SubagentStop`.
  - `docs/architecture.md`, `versions/CHANGELOG.md`: all three.

  Merge order A → B → C keeps conflicts small.
- **Release:** v0.3.0 is released after all three merge (a human action, per `CONTRIBUTING.md`).
## Self-development and verification protocol
1. **Governing release.** Installed v0.2.0 (user scope) governs planning, delivery and review of WORK-001 to WORK-003. Never load unreleased source into the session that is developing it, and never into Landra.
2. **Primary verification** is deterministic: `tests/run.sh` and `scripts/check.sh` run the scripts from source directly. They don't depend on which plugin is loaded.
3. **End-to-end checks** happen only in disposable scratch projects outside this repository and Landra, each with a local bare Git remote: `claude --plugin-dir <checkout>/plugins/ai-engineering --debug`.
4. **Prove the active source before every end-to-end check.** Record all of these in the spec's log:
   - the debug log contains `Plugin "ai-engineering" from --plugin-dir overrides installed version`;
   - the session does **not** report `--plugin-dir copy of "ai-engineering" ignored: plugin is locked by managed settings`;
   - after WORK-002 lands, the session banner shows the checkout's plugin root;
   - before then, a behaviour probe unique to the unreleased change gives the new result. For example, `pnpm test && npm publish` is denied with "resubmit alone" where v0.2 asks.
5. **If managed settings lock the plugin**, stop end-to-end testing on that machine and report it. Never work around managed policy.
6. **After release:** upgrade, then confirm the banner shows v0.3.0 from the plugin cache before relying on it. An existing user-level marketplace registration can keep an older release active.
## Landra WORK-001 migration (later; Landra is not modified now)
1. Release v0.3.0.
2. **Owner:** bump Landra's `.claude/settings.json` marketplace ref, update the user-level install, and verify the banner.
3. **`/ai-engineering:setup` import:**
   - WORK-001 becomes `approved (imported)`;
   - F0-S0/S1 is recorded as merged (PR #1), with CodeRabbit evidence at `64fbb11` as historical;
   - no v0.2 authority is imported.
4. **Gates:** Landra's main-branch gates are trusted historically. `definedBy`, `riskPaths` and adapter configuration arrive as a tier-2 proposed-change, in their own PR or as the first commit of F0-S2.
5. **`/plan` amendment:**
   - adds F0-S2 (preview, tier 2) and F0-S3 (production, tier 2) with a delivery policy (work-branch push, PR, ephemeral preview deploys for F0-S2);
   - declares owner actions up front: separate Vercel scope, accounts, credentials, Neon resources, and `gh` authentication;
   - covers the remaining verification items: T3-L1/L2, T3-M1, A5 and the rollback runbook;
   - then the owner runs `approve` and `deliver`.
6. **Measure F0-S2**, keeping planned owner actions separate from interruptions. Treat the first F1 increment as the cleaner second data point. F0-S3 production deployment stays owner-run.
## Success criteria for the next dogfood run (baseline: v0.2.0 F0)

| Metric | Baseline | Target |
| :- | :- | :- |
| Owner-wait for decisions as a share of authorisation-to-readiness time | ~69% of an 18.9 h span | < 25%, with planned owner actions reported separately |
| Interruptions after authorisation | ~25 | Every one maps to a trigger; zero "continue", "approve fix" or "approve work-branch push" |
| Guard prompts, false / true positives | 5 / 2 | 0 known-category false positives; every reserved operation still caught, one operation per approval |
| Review cycles | 7 security runs, with repeats | No review of an unchanged range; external evidence recognised at head without workarounds |
| Recovery | 1 stall and 1 invalid poll, both handled by hand | Recovered without owner prompts; 0 invalid observations accepted |
| Defects by layer | — | None escaped that a v0.2 layer would have caught; every HIGH fix recorded and re-reviewed |
| Pre-authorisation boundary crossings | 1 | 0 (any crossing triggers the write-hook reconsideration) |
| Gate integrity | 1 dirty-tree pass, unlabelled reruns | 0 dirty-tree certifications; every rerun labelled with a cause |

Authorisation-to-readiness wall time is reported per increment.
## Result
The specs (approved in principle) and ADR-0003 to ADR-0005 incorporate D1–D6. **Next:** the gate-bootstrap PR (D5). Implementation of A, B and C is not authorised until that PR is merged and the owner explicitly authorises delivery.
