# ADR-0003: Structured action classification for the Bash guard
## Status
Accepted (by Ashley Oliver, 2026-10-06) as part of the v0.3 architecture. Implemented by work spec `WORK-001`. Takes effect on release of v0.3.0.
## Context
`guard-bash.sh` (v0.2) classifies the whole Bash command text with regular expressions after collapsing newlines. In the Landra F0 dogfood it asked for approval 7 times: 5 false positives and 2 true positives.

- **False positives:** keywords in data, not in executed operations. These came from heredoc bodies, source text written through the shell, search patterns passed to `grep`, and URL paths passed to read-only `curl` GETs. The evidence is in Landra's `.agents/failures/2026-10-05-guard-bash-false-positive-on-document-content.md`.
- **True positives:** destructive SQL (`DROP DATABASE`) bundled inside large compound commands. The owner could only approve or reject the whole command, so safe steps and the dangerous one shared a single approval.
- A false positive in a compound command also blocked the quality gate bundled with it, and once left a verification step UNVERIFIED.
- Instructions alone did not stop agents editing files through the shell.

`lib.sh` reuses the guard to refuse high-impact gate and reviewer commands, so its classification is also part of the gate trust boundary.
## Decision
- **Parse, then classify.**
  - The guard splits a command into simple commands and pipelines.
  - It classifies each one by the executed program, its operation (subcommand or verb) and, for HTTP clients, the request method.
  - Data is not treated as an executed action: heredoc bodies, string arguments, comments and search patterns don't count. The exception is when the receiving program interprets that data as commands. Shells (`bash -c`, `sh -c`, `eval`) and SQL clients are such programs, and their input is classified as well.
- **Isolate reserved operations.**
  - A compound command containing a reserved or high-impact operation alongside other effectful commands is denied, with a reason telling the agent to resubmit that operation on its own.
  - A lone reserved operation, or one preceded only by context-setting commands (`cd`, environment assignment, toolchain activation), still asks the human.
  - The approval unit becomes one operation.
- **Fail safe on uncertainty.** If a command can't be parsed with confidence, the guard falls back to keyword detection and asks. It never denies just because the command couldn't be parsed, and never returns `allow`.
- **Same safety floor.** Every operation v0.2 correctly asked about still asks, unless this ADR or `WORK-001` explicitly reclassifies it.
- **Policy without work-item state lives in the guard:**
  - deny Git write operations from specialist and reviewer subagents (identified by `agent_type`);
  - deny direct shell or tool writes to the work-authority store;
  - give a non-blocking hint when an implementation agent edits files through the shell.
- **One classification interface.** `lib.sh` and the gate scripts use the same classifier, and treat both `ask` and `deny` as high-impact.
- **Local decision log** for measurement. It records the class, decision and a command hash, never the command text.
## Why
The false positives all had one root cause: matching text rather than actions. Fixing each regex individually would trade one false positive for another. Classifying parsed actions removes the whole category while keeping detection of the operations that matter. Denying compound commands that contain reserved operations makes every approval narrow, which was the lesson of both true positives.
## Alternatives considered
### Tune the v0.2 regular expressions
Rejected. Each tweak narrows one pattern without separating data from actions, and it can't make approvals narrow.
### Ignore all quoted text
Rejected. A destructive keyword can legitimately be an argument (`psql -c "DROP TABLE t"`).
### A general shell interpreter or external parser dependency
Rejected for now. The repository rule is bash + jq for hook scripts, and a full shell grammar isn't needed to separate simple commands, operators, quoting, heredocs and substitutions. The fail-safe fallback covers what the parser doesn't understand.
### Return `allow` for commands classified as safe
Rejected. The guard only adds friction for reserved operations. It must never bypass the user's own permission rules or sandbox.
## Consequences
- The guard remains a guardrail, not a sandbox. Indirection through scripts, variables or programs that call APIs directly can still evade it.
- Agents resubmit reserved operations alone. Each human approval is narrower, but it costs one extra tool call.
- The parser is security-sensitive code and is reviewed and released on its own (PR A of v0.3).
- Authority-store write protection is tamper-resistance for honest mistakes, not protection against a deliberately adversarial process with shell access ([ADR-0002](ADR-0002-gate-execution-trust-boundary.md) records the same limit for gate records).
