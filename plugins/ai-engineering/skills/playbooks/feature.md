# Feature Playbook
1. Planning (`/ai-engineering:plan`) discusses intent/options/constraints/acceptance.
2. Record important architecture as ADRs.
3. Create the work spec; the human approves it.
4. `/ai-engineering:deliver` builds dependencies and assigns specialist agents.
5. Implement; use isolated worktrees only for parallel work streams.
6. Add meaningful tests.
7. Run applicable lint/format/typecheck/security/build/performance/accessibility/E2E/load gates.
8. `/ai-engineering:review`, including the independent external-provider review.
9. Human acceptance where required.
10. Deploy and verify health.
11. Distil durable lessons/regressions (`/ai-engineering:learn`).
12. Archive the work spec; preserve durable knowledge separately.
