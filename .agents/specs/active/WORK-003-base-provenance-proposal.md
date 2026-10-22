# WORK-003: base-provenance protocol (proposal)

Status: proposed for design review only. Revised 2026-10-22 after the owner's decisions on the
security review's P1-P3. The Guard protocol below is **not approved for implementation or
enablement**. No Guard, hook, settings, certification or readiness change is made by this
document. Until a later design is approved and built, readiness reports
`BASE PROVENANCE: UNVERIFIED` and `READY: NO` on every path, and no other certification path
exists.

## Goal and non-goals
Readiness should report `BASE PROVENANCE: VERIFIED` only when evidence that an agent cannot
produce shows all of:
1. the owner approved starting this increment from one exact base commit, for this repository and
   work item;
2. the increment's recorded base, branch and history agree with that approval.

Non-goals: proving that the human read what they approved (blind approval is the G1 problem in
ADR-0004); tamper-proof local files.

## Owner decisions this revision applies (2026-10-22)
- **Records are telemetry.** Agent-forgeable local JSONL records (guard log lines, hook records)
  are diagnostic and correlation data only. They are never authoritative evidence of human
  approval. Agent forgery of them is **not** accepted as a residual for certification.
- **Necessary, not sufficient.** The uniqueness, chronology, exact base-SHA and execution-binding
  checks below stay as necessary conditions. Passing them never verifies provenance by itself.
- **Remote identity (P1).** Any remote identity is pinned in owner-reviewed configuration
  committed at the base. A remote URL from mutable local Git configuration is never trusted. Any
  remote verification neutralises repository, user and system Git configuration and restricts
  transports and helpers. Whether network verification is needed at all is assessed below.
- **Authenticated evidence (P2).** Human approval is established only by an owner-signed or
  otherwise independently authenticated record, consistent with ADR-0004.
- **Permission sources (P3).** Every effective permission source is accounted for. A command
  having run is not proof that a human approved it.
- **Permission modes.** Until V1-V3 are verified, no permission mode counts as authenticated human
  approval. Permission-mode experiments need separate approval.

## Why a hook-only protocol cannot establish human approval
The earlier revision bound a guard `ask`, a `PermissionRequest` record, a `PostToolUse` record and
an `ls-remote` record. The security review (P1-P3) and the documentation show that no such chain
proves a human approved anything:
- **The records are writable by the agent (P2).** The coordinating agent has Bash. A guard rule
  denying writes to `guard-log.jsonl` stops only the direct forms. An interpreter, a script it
  wrote, `cp`/`mv` over the log or a link writes it anyway. The agent can therefore append a
  complete, well-ordered chain.
- **A `PermissionRequest` record doesn't mean a human was asked (P3).** The hook documentation says
  these hooks also run "when it would otherwise auto-deny a call that can't prompt", and in
  sessions that can't show a prompt. It also says a `--permission-prompt-tool` or the Agent SDK's
  `canUseTool` callback runs alongside them, and "whichever decides first applies".
- **Many sources can approve without a human (P3).**
  - Allow rules come from managed, user, project, local (`.claude/settings.local.json`) and
    command-line settings, plus "Yes, and don't ask again", which saves an allow rule to
    `.claude/settings.local.json`.
  - `PermissionRequest` hooks can come from any settings level or a plugin. Hooks from all sources
    merge and run together.
  - A permission-prompt tool or `canUseTool` host can approve.
  - An installed mod handling `tool.check` can, in some setups, approve a call that an ask rule or
    a `PreToolUse` hook would prompt for.
  - Sandboxed Bash with `autoAllowBashIfSandboxed` runs without prompting despite a bare `Bash` ask
    rule (content-scoped ask rules still prompt).
  - `bypassPermissions` skips prompts.

  The agent can write several of these sources, including `settings.local.json`, user settings
  and the plugin cache.
- **The remote check is self-referential (P1).** The previous rule compared the URL Git reports
  for `origin` with itself. A planted URL, an `insteadOf` rewrite, a local `file://` remote, an
  `ext::` transport or a configured `core.sshCommand` would satisfy it, or run a program the agent
  chose.

## Proposed design (for review; nothing implemented)

### D1. Authenticated evidence: an owner-signed increment-start approval
This reuses ADR-0004's proposed signed-approval mechanism (WORK-004). It is not a new trust
anchor.
- **What the owner signs.** At increment start the owner signs an exact record:
  `{schemaVersion, kind: "increment-start", repository, workItem, increment, branch, baseSha,
  remoteIdentity, specCommit, specSha256, nonce, issuedAt, expiresAt}`.
- **How.** The signature uses the user-presence key through the trusted approval path (G1,
  provisionally the separate approver account G1-b). It is verified against the root-owned trust
  anchor outside the agent's write reach.
- **Readiness checks, all of them:**
  - the signature against the anchor (no network);
  - `repository` and `remoteIdentity` against the base-committed pin (D2);
  - `workItem`, `increment`, `branch` and `baseSha` equal to the increment's recorded values;
  - `baseSha` an ancestor of HEAD, and the branch's first reflog entry equal to `baseSha` (both
    as today);
  - the signature issued no later than the increment's `activeAt`;
  - the nonce not seen in another start approval in this repository.
- **Dependency.** This is only as strong as G1. While G1 is OPEN, D1 cannot be implemented as
  authority, and provenance stays UNVERIFIED.
- **Inherited limits.** ADR-0004's replay and revocation limitations apply. Nonce consumption in
  agent-writable state is not rollback-resistant: a replayed start approval re-applies only the
  same signed base, for the same branch and work item.

### D2. Remote identity (P1)
- **The pin.** The repository's remote identity is a pin in owner-reviewed configuration committed
  at the base: for example `.agents/gates.json` `provenance.remote: {host, path}`, or alongside the
  existing marketplace pin in `.claude/settings.json`. It is read with `git show <base>:<file>`,
  exactly as the plugin pin is today.
- **What is never read.** The local `remote.origin.url`, `insteadOf` and `pushInsteadOf` rules are
  never read for provenance.
- **The signed record.** D1's `remoteIdentity` must equal the pin. The owner's signature then
  covers which remote the base came from.
- **Is network verification needed? Recommendation: no.** The claimed property is "the owner
  approved this exact base". D1 establishes it offline.
  - An `ls-remote` would add only "the remote said X at time T". That rests on the remote and its
    transport authentication, not on the owner.
  - It also brings new attack surface: config-driven transports and helpers.
  - It is not needed to certify, so the recommendation is to leave it out of the certification
    path entirely.
- **If the owner wants a diagnostic remote check anyway.** It must never be a certification
  input, and must run as:
  - `git ls-remote <pinned URL> refs/heads/<default>`, with no repository (run outside any work
    tree);
  - `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`, and `HOME` and `XDG_CONFIG_HOME` set to
    an empty directory;
  - `-c protocol.allow=never -c protocol.https.allow=always`, plus `ssh` only if the pin names it;
  - `-c credential.helper=`, `-c core.askPass=` and `GIT_TERMINAL_PROMPT=0`;
  - for an SSH remote, `-c core.sshCommand='ssh -F /dev/null'` and `GIT_SSH_COMMAND` unset, so
    OpenSSH reads no user or system `ssh_config` (it finds `~/.ssh/config` through the password
    database whatever `HOME` is, so a `ProxyCommand` there could otherwise run);
  - every other `GIT_*` variable removed, and a bounded deadline.
  - A mismatch is reported only, never used to verify.

### D3. Permission sources (P3)
Because D1 does not depend on how the start command was approved, P3 no longer decides
certification. It still matters for the diagnostics and for the action floor:
- **The full inventory.** The diagnostics list every source that could approve the start command
  without a prompt:
  - the managed, user, project and local settings: allow rules, `PermissionRequest` hooks,
    `defaultMode`, `disableBypassPermissionsMode` and sandbox auto-allow;
  - command-line flags and arguments for the session: `--allowedTools`, `--permission-mode`
    (including `bypassPermissions`), `--dangerously-skip-permissions`, `--settings` and
    `--permission-prompt-tool`;
  - prompt-tool and embedding hosts: a `--permission-prompt-tool` MCP tool, the Agent SDK's
    `canUseTool` callback, and SDK-supplied managed settings;
  - plugin hooks;
  - installed mods.
  - Each is labelled with its source.
- **Never human approval.** No record of a command having run, and no `prompted` record, is
  treated as human approval.
- **Write protection (proposed, not approved).** Guard write protection for
  `.claude/settings*.json` and `~/.claude/settings*.json` is proposed as defence in depth only. It
  is not an authority boundary, because indirect writes remain possible.

### D4. Diagnostic and correlation records (optional; not approved for implementation)
The `PreToolUse` guard-log fields (`schemaVersion`, `event`, `toolUseId`, `permissionMode`,
`commandSha256`) and the `PermissionRequest`, `PostToolUse` and `PostToolUseFailure` records
(`prompted`, `executed`, `failed`) may stay in the design as correlation data. Readiness may
report them, and may use them only to make a result worse, never better:
- a contradiction becomes NOT CERTIFIABLE;
- a missing record becomes UNVERIFIED.

They never establish approval.

## Necessary conditions (retained; never sufficient)
Every one must hold before D1's signature is even considered. A failure gives UNVERIFIED unless
stated.
1. **Exact base.** The recorded `baseSha` is a full SHA, is a commit, is an ancestor of HEAD, and
   is the first reflog entry of the increment branch.
2. **Chronology.** The start (signature `issuedAt`, and the anchor ask if logged) is no later than
   `activeAt`. Diagnostic records are in log order: ask, then prompt, then executed.
3. **Execution binding.** Where records exist, exactly one `executed` for the anchor's tool-use id,
   with the same session and hash, and no `failed` or interrupt for it.
4. **Uniqueness.**
   - A tool-use id appears in no other ask, executed or failed record; a duplicate is
     NOT CERTIFIABLE.
   - The signed nonce appears in no other start approval.
5. **Pins.** The remote identity pin and the plugin pin are read from the base commit, never from
   the branch or local configuration.

## Failure behaviour
| Condition | Result |
|---|---|
| no signed start approval, or G1 still OPEN | `BASE PROVENANCE: UNVERIFIED`, `READY: NO` (certifiable) |
| signature invalid, anchor missing or unreadable, or the record's fields differ from the recorded increment or the pin | `UNVERIFIED` |
| a necessary condition fails | `UNVERIFIED` |
| a duplicate tool-use id or nonce, or a malformed or contradictory diagnostic record after the anchor | `NOT CERTIFIABLE` |
| a log rotated or replaced during the read, or a linked log directory | `NOT CERTIFIABLE`, as today |
| the diagnostic remote check (if adopted) fails, times out or disagrees | reported only; it never verifies, and a disagreement is `UNVERIFIED` |
| any hook fails or misses its deadline | its record is missing, giving `UNVERIFIED`; the guard's decision never changes |

## Open verifications (V1-V3)
Investigated by reading the documentation only (code.claude.com/docs/en/hooks and
/docs/en/permissions, read 2026-10-22). No permission-mode experiment was run.

| Item | What the documentation says | Status |
|---|---|---|
| V1: does a `PreToolUse` `ask` prompt in each mode? | "A hook's `ask` also forces a permission prompt in auto mode: the classifier can still deny the tool call, but it can't approve the call silently." `bypassPermissions` "skips permission prompts, except for the actions no mode auto-approves". `dontAsk` "auto-denies every call that would otherwise prompt". In some setups a mod can approve a call an ask rule or `PreToolUse` hook would prompt for. Nothing says how a hook `ask` behaves in `bypassPermissions`, `acceptEdits` or `plan`. | Auto mode documented; the other modes unresolved. |
| V2: does a `PreToolUse` `ask` trigger `PermissionRequest`, and in what order? | "PermissionRequest hooks run only when Claude Code is about to ask you for permission, or when it would otherwise auto-deny a call that can't prompt." They also run, then deny, in sessions that can't prompt. With a permission-prompt tool or `canUseTool` host, "whichever decides first applies". No ordering between several `PermissionRequest` hooks is documented. | Unresolved, and it no longer decides certification: a `PermissionRequest` record proves no human was asked. |
| V3: does `PostToolUse` never fire for a declined call? | `PostToolUse` "runs immediately after a tool completes successfully". `PostToolUseFailure` "doesn't fire for ... a permission denial". `PermissionDenied` "doesn't run when you manually deny a permission dialog". | Documented by implication. An experiment would confirm it. |

Under the owner's decision, no mode counts as authenticated human approval. With D1, certification
doesn't depend on any mode. If the owner still wants V1-V3 confirmed for the diagnostics, the
minimum experiment is:
- a disposable repository with no remote;
- one fixture `PreToolUse` hook returning `ask` for `echo provenance-probe`, plus logging
  `PermissionRequest`, `PostToolUse` and `PostToolUseFailure` hooks;
- the hooks configured only in that repository's `.claude/settings.local.json`;
- one session per mode, with the owner declining once and accepting once.

It needs separate approval and is not proposed for PR C.

## Regression tests (to write with any later implementation)
- **Signature:** a valid signed start approval, with every necessary condition met, reports
  `VERIFIED`. This is the only path to `VERIFIED`.
- **Each field:** a wrong repository, work item, increment, branch, base, remote identity, spec
  hash, expiry or nonce reports `UNVERIFIED`.
- **No signature:** with no signature, a complete and well-ordered forged JSONL chain appended by a
  script reports `UNVERIFIED`.
- **Duplicates and contradictions:** a duplicate tool-use id or nonce reports `NOT CERTIFIABLE`. A
  contradictory diagnostic record after a valid signature reports `NOT CERTIFIABLE`.
- **Remote:** the pin is read at the base only. A branch change to the pin, or a local
  `remote.origin.url` or `insteadOf` change, never changes the result.
- **Diagnostic remote check (if adopted):**
  - `file://`, `ext::`, a configured `core.sshCommand`, a credential helper, and a URL from local
    configuration are each refused or ignored;
  - a stalled stand-in reaches the deadline with a single bounded run (no stress test);
  - the check never verifies.
- **Permission sources:** an allow rule or a `PermissionRequest` hook in `settings.local.json`,
  user settings or a plugin is listed in the diagnostics and never verifies.
- **G1 still OPEN:** with G1 OPEN, readiness reports `UNVERIFIED` and `READY: NO` whatever else is
  present.

## Residuals
- D1 inherits ADR-0004's open items: G1 (blind approval through the trusted path), the trust
  anchor installation (O3), and the replay and revocation limitations.
- A same-user process can still edit local files. D1 does not rely on any of them for authority:
  the key and the anchor are outside the agent's write reach by design (G1-b), which is unproven
  until its proof of concept passes.
- Without the network check, readiness does not confirm that the remote ever held `baseSha`. The
  owner's signature is the attestation of which base was approved.

## Owner decisions needed
1. Approve, change or reject D1, the owner-signed start approval, as the only path to
   `VERIFIED`. It depends on WORK-004 and G1.
2. Choose where the remote identity pin lives (D2), and whether the diagnostic remote check is
   wanted at all. The recommendation is no.
3. Whether the D4 diagnostic records and the D3 settings write protection should be built, and
   when. Both are currently not approved.
4. Whether the V1-V3 experiment above should be designed for approval.

Until these are decided and implemented, nothing changes and `READY: YES` stays unreachable.
