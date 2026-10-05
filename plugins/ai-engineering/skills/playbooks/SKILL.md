---
name: playbooks
description: Engineering playbooks giving the ordered steps and gates for each type of change - feature, bug fix, refactor, release, infrastructure, security change, architecture change. Use when planning or delivering a change to pick and follow the right process.
user-invocable: false
---
# Playbooks

Pick the playbook that matches the change and read only that file. Stages may be skipped only deliberately, with the reason stated.

| Change | Playbook |
| :- | :- |
| New or extended behaviour | [feature.md](feature.md) |
| Defect | [bug-fix.md](bug-fix.md) |
| Behaviour-preserving restructuring | [refactor.md](refactor.md) |
| Shipping a version | [release.md](release.md) |
| Cloud, network, CI/CD or deployment infrastructure | [infrastructure.md](infrastructure.md) |
| Authentication, authorisation, secrets or other trust boundaries | [security-change.md](security-change.md) |
| Significant architectural direction | [architecture-change.md](architecture-change.md) |

Lifecycle: Discuss, Decide, Specify, Implement, Prove, Independent Review, Human Acceptance, Deploy, Observe, Learn.
