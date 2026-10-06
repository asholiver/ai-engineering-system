# ADR-0005: Risk-tiered assurance, gate trust lifecycle and review evidence
## Status
Accepted (by Ashley Oliver, 2026-10-06) as part of the v0.3 architecture. Implemented by work spec `WORK-003`. Takes effect on release of v0.3.0. Amends [ADR-0002](ADR-0002-gate-execution-trust-boundary.md): the opt-in hook-run fast gate and the working-tree fallback for gate configuration are removed.
## Context
v0.2 applied the same assurance depth to every change.

- **Gate trust.** It was one string at one ref:
  - nothing distinguished a newly created gate from a trusted one;
  - gate behaviour could be redefined through package scripts or tool configuration that the change itself edited;
  - verdicts could come from uncommitted trees;
  - reruns after a failure weren't labelled.
- **External review.** The contract accepted only a command, so pull-request review evidence (CodeRabbit in Landra) couldn't count.
- **Repeat reviews.** Seven Opus security reviews ran in F0, several over code that hadn't changed since the last review.
- **Real defects were still caught** by the assurance layers:
  - QA found a fail-open sign-out;
  - the final security review found F1 and F3;
  - a history secret scan;
  - external review.

  They must not be weakened.
## Decision
- **Risk tiers 0, 1 and 2.**
  - The owner approves each increment's initial tier in the spec.
  - A deterministic classifier computes a floor from the changed paths and diff content, and an action floor from guard events and new dependencies or services. It uses built-in defaults plus the project's `riskPaths` read from the trusted base ref.
  - The effective tier is the maximum of the approved tier and the floors.
  - Anything that can't be classified raises the tier. Agents can raise a tier; only the owner can lower one.
- **Tier 0 is narrow.** It covers Markdown outside `.agents/`, `docs/**`, and copy paths the project declares at the base ref.
  - Instruction-bearing Markdown and configuration are never tier 0, even when they are Markdown (owner decision D4). They are classified by what they can influence:
    - **tier 2** for `.claude/**`, plugin manifests, hooks and agent definitions, CI workflows and `CODEOWNERS`;
    - **tier 1 at least** for `AGENTS.md`, `CLAUDE*.md`, any `SKILL.md`, plugin skill and command definitions, and the rest of `.github/**`.
- **Depth by tier.**

  | | Tier 0 | Tier 1 | Tier 2 |
  | :- | :- | :- | :- |
  | Full gate | trusted full gate (or trusted CI evidence of it) at head | yes | yes |
  | QA | spot check against intent | full | full, including negative and failure-path tests |
  | Internal security review | none | only when the classifier flags a security category | adversarial review of the delta since the last review |
  | External review from another provider | optional | required at head | required at head |

- **Gate trust lifecycle:** `absent → provisional → trusted → proposed-change → trusted`.
  - Certifying gates are read only from the base ref.
  - Provisional gates guide fix loops but never certify.
  - A change never certifies its own gate definitions. That includes the files listed in `definedBy`, whose changes put the increment in tier 2 and are shown verbatim.
  - If any `definedBy` file differs from base, certify mode returns an explicit `NOT CERTIFIABLE` verdict, never `PASSED`. The increment then follows the gate-change route: structural evidence, safe canaries or the review fallback, external review, and owner acceptance at merge.
  - Only when nothing in `definedBy` changed does the base gate definition certify the change.
  - **Bootstrap trust** requires all of:
    - structural verification;
    - safe deterministic canaries, where the gate type supports a controlled failure without touching real data, infrastructure, credentials or external resources (otherwise structural verification plus explicit review evidence);
    - external review;
    - the owner's acceptance at merge.
- **Certification needs a committed, clean tree.** An optional `prelude` activates the toolchain deterministically.
  - A local gate ledger records each run: head, config hash, whether the tree was clean, and the verdict.
  - A rerun at the same head after a failure is labelled and needs a recorded cause.
- **Review evidence is a ledger tied to exact commit ranges.**
  - External evidence comes through provider-neutral adapters configured at the base ref. The v0.2 reviewer-command contract remains as one adapter.
  - A reusable GitHub PR-review adapter ships with the plugin (owner decision D6).
    - Its reviewer identity is configuration; CodeRabbit is the example.
    - It accepts evidence only for the exact head (or incremental reviewed ranges reaching it) with no unresolved actionable findings, never merely because a reviewer posted.
  - Coverage is computed. Unchanged code is never re-reviewed.
- **One readiness procedure** decides when an increment is ready. Delivery and `/review` both use it.
- **Removed:**
  - `gate-fast.sh`;
  - the `SubagentStop` gate hook;
  - `AI_ENGINEERING_HOOK_GATES`;
  - the working-tree fallback for gate configuration.
## Why
Uniform depth spent the expensive layers on low-risk changes while trusting new gate definitions too readily. Deriving depth from approved metadata plus deterministic floors keeps the agent from declaring its own work low-risk. A trust lifecycle and an evidence ledger let assurance be exact about what was checked, at which commit, by whom.
## Alternatives considered
### Severity-based or agent-declared risk
Rejected. An implementing agent must not be able to lower its own assurance.
### Allowing a bootstrap increment to certify its own gates
Rejected. That is self-certification, so the trust boundary stays external.
### Breaking real resources to prove a gate fails
Rejected (owner decision). Canaries must be safe and controlled.
## Consequences
- Tier-0 changes are faster. Tier-1 and tier-2 changes keep at least v0.2 depth, now keyed to commit ranges.
- Projects whose gate commands go through package scripts list those manifests in `definedBy`.
- The gate ledger and evidence records are local evidence, not proof. Readiness re-runs the trusted full gate itself, or relies on adapter-verified CI evidence for the exact head.
