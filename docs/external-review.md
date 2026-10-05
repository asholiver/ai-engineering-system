# External Independent Review Contract

Independent review must come from a genuinely different provider than the implementation agents. The ai-engineering system stays provider-neutral: a project plugs any reviewer in through one command.

## Scope of the review
The external review covers correctness, security, maintainability, regressions, scalability, performance, accessibility, tests, unnecessary complexity and requirement gaps. It reports actionable findings and does not rewrite the implementation.

## Configuration
In the project's `.agents/gates.json`, committed to the base branch:

```json
{ "externalReview": "<command>" }
```

`null` or a missing key means not configured. The command is read from the file **as committed at the base ref**, so a change under review cannot select or alter its own reviewer; when a change modifies `externalReview`, the report notes that the base command was used. A command that the approval guard classifies as high-impact is refused (`ERROR`).

## Invocation
`/ai-engineering:review` runs `scripts/external-review.sh <base-ref> <head-ref> [spec-path]`, which executes the command with `bash -c` from the repository root and these environment variables:

| Variable | Meaning |
| :- | :- |
| `REVIEW_BASE_REF` | Base of the change, for example `main` |
| `REVIEW_HEAD_REF` | Head of the change, normally `HEAD` |
| `REVIEW_SPEC_PATH` | Work spec path relative to the repository root, or empty |

The command is trusted because it comes from the base ref, but it runs in the change's checkout: a reviewer that executes repository code (for example by running tests) executes the change's code. See the [trust boundary](architecture.md#trust-boundary-for-project-code).

Commit the change before review. The command computes the diff itself (for example `git diff "$REVIEW_BASE_REF...$REVIEW_HEAD_REF"`), sends it to the reviewer, and prints findings as text or Markdown on stdout. Output beyond 400 lines is truncated in the report.

## Exit codes
| Reviewer exit | Verdict printed | Wrapper exit |
| :- | :- | :- |
| 0 | `EXTERNAL REVIEW: PASSED` (no blocking findings) | 0 |
| 1 | `EXTERNAL REVIEW: BLOCKING FINDINGS` | 1 |
| any other | `EXTERNAL REVIEW: ERROR (reviewer exit N)` | 2 |
| not configured | `EXTERNAL REVIEW: NOT CONFIGURED` | 3 |

## Rules
- When not configured, the review report says `EXTERNAL REVIEW: NOT CONFIGURED` and the work is **not** marked ready for final human acceptance.
- Missing external review never blocks implementation, local testing, normal commits, draft PRs or other engineering work.
- Claude reviewing Claude (including the internal `security-reviewer` and `qa` agents) never substitutes for the external review.
- The reviewer command runs with the user's credentials. Keep provider API keys in the user's environment or secret store, never in `gates.json`.

The choice of provider and integration (local CLI, CI job, hosted service) is an open decision; see ADR-0001.
