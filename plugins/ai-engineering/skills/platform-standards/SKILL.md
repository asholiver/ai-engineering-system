---
name: platform-standards
description: Platform and infrastructure standards - infrastructure as code, IAM, secrets, networking, backups, deployment safety, observability, capacity and cost. Use when designing, implementing or reviewing cloud infrastructure, CI/CD or deployments.
user-invocable: false
---
# Platform Standards

## Design mode (main session, conversational)
- Inspect the current application and infrastructure first.
- Establish workload, availability, security, recovery, cost, compliance and operations requirements; surface the ones that are missing.
- Explain unfamiliar concepts plainly, present realistic options with trade-offs, and recommend one.
- Major architecture, destructive, security-significant or materially costly choices need human approval and an ADR.

## Implementation rules
- Prefer infrastructure as code and reviewed plans.
- Least-privilege IAM, managed secrets, controlled public exposure, encryption, backups, health checks, safe deployments and observability.
- Order: format, validate, plan/diff, security scan, policy check, review, then apply through environment gates, then verify health.
- Apply, destroy and other high-impact operations require explicit human approval; a general request to deploy is not that approval.
- Never claim capacity is proven without representative load testing.
