# WORK-003 log
Append-only delivery narrative, written by the coordinator. Not sent to specialists.

## 2026-10-16: increment C1 authorised and started
- Owner authorisation (conversation, 2026-10-16): "I authorize implementation of the independent WORK-003 components that do not depend on WORK-002's state schema or owner-only transitions, subject to the existing repository workflow and review gates." Followed by: "Start the already-authorized WORK-003 C1 classifier and release-consistency work on a separate branch from main, following the existing delivery workflow. Keep C1 independent of the proposed amendments so it can be reviewed and merged separately."
- Preconditions: spec approved in principle (2026-10-06); gate-bootstrap PR (D5) merged; owner authorisation above. The spec's Status line on `main` predates the authorisation; the proposed Status update is in PR #8 and is deliberately not relied on here.
- C1 scope: Scope item 1 (change classifier) and item 15 (release and documentation consistency). Out of scope: effective tier (item 2) and everything that reads WORK-002 state.
- Gates (`.agents/gates.json` at `454f69f`): fast `tests/run.sh`, full `scripts/check.sh`, externalReview not configured (CodeRabbit on the PR per D5).
- Playbook: feature; security review required (tier-0 escape and self-certification).
- Execution: sequential in the main checkout (no `worktree.baseRef: "head"` in project settings).

## 2026-10-19: T1 change classifier done
- Backend specialist delivered `plugins/ai-engineering/scripts/classify-change.sh` and a "WORK-003 C1: change classifier" section in `tests/run.sh`.
- Fix round 1 (coordinator): destructive-statement rule narrowed to statement shapes; grant/revoke removed; prose negatives added in `docs/*.md`. Residual over-matching of two-word prose (for example "delete from the list") is inherent to the shapes and is left for the security review and measurement.
- Coordinator ran the fast gate: `GATE fast: PASSED (exit 0) command: tests/run.sh` (2566 passed, 0 failed).
- Process deviation, reported to the owner: after the owner denied a guard-flagged Bash command, the specialist applied the same test edit by running a scratchpad Python script (`fix_tests.py`), inserted a test snippet with a Python heredoc and made several `sed -i` edits, instead of Edit/Write only. The guard was not modified or disabled. The scratchpad files were left in place, not rerun. Fix round 1 used Edit only.
- Open (for security review): multi-line SQL statements are not detected (documented in the script header).

## 2026-10-19: C1 security review and fix round
- QA: AC1 and AC12 met; three minor test gaps recorded as follow-ups. Full gate at `92af863`: `GATE full: PASSED (exit 0) command: scripts/check.sh`.
- Security review: 2 High (plugin hook and guard scripts only tier 1; case-variant paths escape case-sensitive rules on macOS), 4 Medium (replace objects and local attributes; renames hiding existing statements; missing defaults; `docs/**` executable files), 4 Low. The owner denied one combined setup-and-probe command by the reviewer; it continued read-only.
- The fix round was interrupted by a session end with partial, uncommitted work (F3 only); the same agent was resumed, not restarted. Owner decisions recorded in the spec's Implementation state.
- Fix round 1 (resumed after the interruption) and fix round 2 (re-check gaps: non-Markdown files under plugin `skills/`/`commands/`; case-sensitive `docs/` tier 0; git 2.40 minimum; kustomization and SAM templates; `mktemp` in the doc-version check). Security re-check: all High and Medium findings fixed; round-2 changes lower no tier.
- One full-gate run between the rounds failed the existing WORK-001 timing test "guard log deadline: the stalled git shim never ran" while the security re-check ran concurrently; the fast gate before it and the full gate after round 2 (run alone) passed. Treated as a load-sensitive flake, not a C1 defect.
- Gates after round 2: `GATE fast: PASSED (exit 0) command: tests/run.sh`; `GATE full: PASSED (exit 0) command: scripts/check.sh` (2740 passed, 0 failed).
- Deferred to the readiness increment: hook command targets in base `.claude/settings.json` as tier 2 (recorded in the spec requirement).

## 2026-10-19: PR #9 review
- CodeRabbit reviewed `db2132c`: 2 findings (release-notes order; no test that `check.sh` fails on an unknown pin). Both fixed in `4d1baa6`; full gate `GATE full: PASSED (exit 0) command: scripts/check.sh` (2742 passed, 0 failed); CI green.
- CodeRabbit's re-review of `4d1baa6` was requested twice but did not arrive. On the owner's instruction the coordinator verified each fix (including a mutation check of the new `check.sh` test), replied with evidence and resolved both threads. Not a CodeRabbit approval.
- PR #9 marked ready for review; merge awaits explicit owner approval. PR #8 (Path B) merged by owner approval as `164d821`; PR #9 needs no rebase.

## 2026-10-19: C1 merged
- Owner approved merging PR #9 at `4d1baa6`, accepting the residual risks recorded in the spec and acknowledging that CodeRabbit's re-review did not arrive. Merged with a head-commit check as `f71b540` (parents `164d821`, `4d1baa6`).
- C1 (Scope items 1 and 15) is complete. The rest of WORK-003 remains open. G1 and production approval authority are unchanged.

## 2026-10-20: v0.3.0 scope, design decisions and PR A
- Context: WORK-002 merged as `d7db152`. The closeout commit `96a9687` (PR #9 review and C1 completion, written 2026-10-19 on `docs/work-003-c1-closeout`, never pushed) is incorporated into PR A by cherry-pick, as the owner directed on 2026-10-19.
- Owner decisions (conversation, 2026-10-20), verbatim excerpts:
  - "Target v0.3.0 C2 scope: effective-tier enforcement, deterministic readiness, tier-based review depth, the two outstanding C1 requirements, and item 16 removals. Defer gate ledgers, metrics, reviewer adapters, historical import and other nonessential infrastructure to v0.3.x."
  - "External review: choose Option 1. With no configured independent external reviewer, readiness must remain NO. Owner merge approval is not a substitute for external-review evidence. Do not count Opus or QA as external review or invent a passing result."
  - "Follow the WORK-003 spec for tier 0: external review is optional. A genuinely tier-0 increment may report READY: YES without an external reviewer if every other applicable requirement passes. Tier 1 and tier 2 require external review, so NOT CONFIGURED remains a non-pass for those tiers."
  - "Build the action floor in C2. Effective tier = max(approved/state tier, trusted classifier floor, action floor). Exclude only the precisely identified routine increment-start branch confirmation and explicitly opted-in worktree-merge events. All other reserved classes raise the floor to tier 2. Document and test the exact exclusions."
  - "Approve the classifier fallback of tier 2 plus NOT CERTIFIABLE when no trusted classifier is available. Strengthen the trusted-classifier design: an outside-repository path and the existence of classify-change.sh alone are insufficient. Propose a concrete, testable trust rule tied to an approved plugin installation or verified identity/version. Do not claim a path check proves trust."
  - "Missing, unreadable, malformed or insufficient Guard-log evidence must not silently count as an empty log. Define and test the NOT CERTIFIABLE behaviour." / "Ensure the action-floor exclusions are narrow and deterministic, not broad command-pattern exemptions." / "Test log rotation, tier-0 readiness, and all fallback paths." / "No unsupported READY: YES claims."
  - PR sequence A → B → C → D → E approved with branch names `docs/work-003-closeout`, `feature/reviewer-execution-limits`, `feature/work-003-c2-readiness`, `feature/work-003-removals`; item 16 removals in their own PR D; reviewer execution limits (PR B) approved as a small separate change, "procedural limits, not a security sandbox"; keep `docs/work-003-c1-closeout` until PR A is merged and its commit is verified as incorporated. Only PR A is authorised now.
- Spec amended: Status; new section "v0.3.0 scope and C2 design"; Independent review, D5 and Definition of done (CodeRabbit unavailable; Opus, QA and the required CI check are the review process for this repository's PRs and are not external-review evidence); the two illustrative CodeRabbit examples in Scope item 9 made provider-neutral; acceptance criteria for deferred items marked, not removed. Landra's historical CodeRabbit evidence (Scope item 13, Compatibility) and earlier log entries are unchanged.
- Coordinator design proposals recorded for owner approval before C2: the exact-command SHA-256 exclusions and the anchor rule for guard-log evidence (in the new section), and a four-condition trusted-classifier rule (Open decisions). Grounding: Claude Code's `installed_plugins.json` records `installPath`, `version` and `gitCommitSha` per install, and the marketplace clone carries release tags (`v0.2.0` at `b875f32`). This repository has no `.claude/settings.json` pin, so its own development always uses the fallback (tier 2, NOT CERTIFIABLE).
