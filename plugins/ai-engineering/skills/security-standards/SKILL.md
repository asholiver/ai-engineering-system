---
name: security-standards
description: Security engineering standards - threat areas to consider when designing, implementing or reviewing code and infrastructure, and how to verify them. Use for authentication, authorization, input handling, secrets, data exposure, dependencies, IAM or other security-sensitive work.
user-invocable: false
---
# Security Standards

Builds on the security baseline in `engineering-standards`.

## Consider
- Authentication versus authorization; IDOR/BOLA; privilege escalation.
- Input validation and injection (SQL, command, template, header); XSS; CSRF; SSRF; unsafe deserialization.
- Secrets and sensitive data: storage, transmission, logging, error messages, data leakage.
- Sessions, account recovery and token lifecycle.
- Abuse protection: rate limits, request and payload limits, resource exhaustion, race conditions.
- Supply chain: new or updated dependencies, install scripts, pinned versions.
- Infrastructure exposure: public endpoints, IAM scope, network rules, storage access.

## Verify
- Prefer machine-verifiable checks: dependency audit, secret scan, static analysis, container, IaC and policy scans. Use the project's existing tooling where it exists.
- Security-sensitive behavior needs negative tests that prove the forbidden path is refused.
- Findings state severity, preconditions, a realistic attack path, remediation and the regression test that would catch it.
- Never print, copy or exfiltrate secrets while investigating.
