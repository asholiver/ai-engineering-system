# WORK-003: base-provenance protocol (proposal)

Status: proposed for design review only (owner, 2026-10-22). Not implemented. No Guard, hook,
settings or readiness change is made by this document. Until it is approved and built, readiness
reports `BASE PROVENANCE: UNVERIFIED` and `READY: NO`, and no other certification path exists.

## Goal and non-goals
Readiness should report `BASE PROVENANCE: VERIFIED` only when local evidence shows all of:
1. the exact increment-start command (`git switch -c <branch> <recorded base>`) was asked by the
   guard and shown to a human in a permission prompt;
2. that same tool call then ran and succeeded;
3. at that moment the remote's default branch named the recorded base commit.

Non-goals: tamper-proof evidence against a process running as the same user (it can edit any
local file, including the log and the plugin); cryptographic provenance (signed releases are
WORK-004); proving that the human read the prompt.

## Hook facts this relies on
From Claude Code's hooks documentation (code.claude.com/docs/en/hooks, read 2026-10-22):
- Every hook input has `session_id`, `cwd`, `permission_mode` (`default`, `plan`, `acceptEdits`,
  `auto`, `dontAsk`, `bypassPermissions`) and `hook_event_name`.
- `PreToolUse` and `PostToolUse` inputs carry `tool_use_id`. `PostToolUse` also has
  `tool_response`. `PostToolUseFailure` fires after a failed call, with `tool_use_id`, `error`
  and `is_interrupt`.
- `PermissionRequest` "runs when Claude Code is about to ask you for permission", carries
  `tool_name` and `tool_input` but no `tool_use_id`, and also runs (then denies) in sessions that
  can't show a prompt.
- A hook's `ask` "forces a permission prompt in auto mode".

To verify before implementation (not stated in the documentation read):
- V1: whether a `PreToolUse` `ask` shows a prompt under `bypassPermissions`, `dontAsk` and
  `acceptEdits`.
- V2: whether a `PreToolUse` `ask` triggers `PermissionRequest`, and in what order relative to
  other `PermissionRequest` hooks.
- V3: that `PostToolUse` never fires for a declined call.

Each is checked with a disposable session and recorded. The proposal treats every unverified
mode as not owner-approved.

## Threat model
| Actor | Can | In scope |
|---|---|---|
| The coordinating agent (mistaken or prompt-injected) | choose Bash commands and tool inputs, write files through tools, retry, pick a permission mode it was given | yes |
| Branch content (gate, scripts, configuration on the branch) | run as the user during the gate; edit local files | partly: readiness re-checks after the gate, as today |
| Project settings at the base commit | add hooks or allow rules | yes: read at the base commit, as the pin is today |
| User-level settings and hooks | auto-approve through a `PermissionRequest` hook or allow rules | detected where possible, otherwise residual |
| Another local process as the user | edit the log, the plugin, the tools | no (accepted residual A2) |
| A network attacker, or a compromised remote | answer `ls-remote` | no: the remote and its transport authentication are trusted |

Attacks considered:
- forged log lines written through Bash or Write;
- replaying an earlier increment's records;
- a start command that was declined, failed or interrupted;
- approval without a human (`bypassPermissions`, `dontAsk`, an auto-allowing hook);
- a base that is local only (planted `origin/<default>`);
- a remote URL redirected through `url.<x>.insteadOf`;
- records out of order;
- duplicate tool-use ids;
- a log rotated or replaced while it is read.

## Proposed changes (for review; none made)
1. **Guard log, `PreToolUse` (`guard-bash.sh`).** Decisions stay unchanged. Every logged
   `ask`/`deny` line gains `schemaVersion: 2`, `event`, `toolUseId` and `permissionMode`.
2. **New `PermissionRequest` hook (`record-prompt.sh`, matcher `Bash`).**
   - It returns no decision, so the permission flow is unchanged.
   - When the command matches the increment-start form, it appends a `prompted` line.
   - It runs under the same 2 s logging deadline as the guard.
3. **New `PostToolUse` and `PostToolUseFailure` hooks (`record-execution.sh`, matcher `Bash`).**
   - Only for the increment-start form, it appends `executed` (success) or `failed` (failure or
     interrupt).
   - After a success it runs one bounded `git ls-remote --exit-code origin
     refs/heads/<default>` (5 s budget, the same deadline mechanism as the guard's Git calls) and
     appends a `remote-head` line, whose status is `ok`, `timeout` or `error`.
   - It never blocks or alters output, and a failure only means a line is missing.
4. **Log protection (`guard-writes.sh`, guard policy).** Writes to `<git-common-dir>/ai-engineering/guard-log.jsonl*` through Write, Edit, NotebookEdit
   and Bash are denied from every caller, as the token store is today. Only the hooks append.
5. **Readiness.**
   - It evaluates the binding rules below and reports `BASE PROVENANCE: VERIFIED` only when every
     one holds; otherwise `UNVERIFIED` with the first failing rule.
   - `READY: YES` becomes reachable only through this path, and only after this proposal and its
     tests are approved; no other path is added.
6. **Settings check at the base commit.** A `PermissionRequest` hook or a Bash allow rule in the
   project's `.claude/settings.json` at the base commit that could approve the start command
   makes provenance `UNVERIFIED`.

## Evidence format
JSON Lines in the existing `guard-log.jsonl` (and `.1`), one object per line. It never holds
command text, only hashes. Hashes are SHA-256 of the exact command text as the guard logs it today.

```json
{"schemaVersion":2,"event":"ask","time":"…Z","sessionId":"…","agentType":null,"toolUseId":"toolu_…","permissionMode":"default","decision":"ask","classes":["…"],"parseMode":"parsed","commandSha256":"<64 hex>"}
{"schemaVersion":2,"event":"prompted","time":"…Z","sessionId":"…","permissionMode":"default","commandSha256":"<64 hex>"}
{"schemaVersion":2,"event":"executed","time":"…Z","sessionId":"…","toolUseId":"toolu_…","permissionMode":"default","commandSha256":"<64 hex>"}
{"schemaVersion":2,"event":"failed","time":"…Z","sessionId":"…","toolUseId":"toolu_…","permissionMode":"default","commandSha256":"<64 hex>","interrupt":false}
{"schemaVersion":2,"event":"remote-head","time":"…Z","sessionId":"…","toolUseId":"toolu_…","remoteUrlSha256":"<64 hex>","ref":"refs/heads/main","commit":"<40 hex>|null","status":"ok|timeout|error"}
```

`remoteUrlSha256` is the hash of the effective URL as `git ls-remote --get-url origin` reports it
(after `insteadOf` rewriting). Version-1 lines stay valid for the action floor and never verify
provenance.

## Approval and execution binding (all must hold, in log line order)
1. **Anchor.** Exactly one `ask` whose `commandSha256` is the hash of
   `git switch -c <increment branch> <recorded baseSha>`, with `toolUseId` T and session S. Its
   `permissionMode` must be in the human-prompt set: `default` and `acceptEdits`, plus `auto` once
   V1 confirms the prompt. `plan`, `dontAsk` and `bypassPermissions` never count.
2. **Prompt.** A `prompted` line after the anchor, with session S, the same hash and a mode in the
   same set, and no other `prompted` line for that hash in S between the anchor and the execution.
   This line has no tool-use id, so session, hash and order bind it.
3. **Execution.** Exactly one `executed` line with T, S and the same hash, after the prompt, and
   no `failed` line for T.
4. **Remote.** A `remote-head` line with T after the execution: status `ok`, `ref` =
   `refs/heads/<default branch>`, `commit` = the recorded `baseSha`, and `remoteUrlSha256` = the
   hash of the current effective `origin` URL.
5. **Time.** The execution line's time is no later than the increment's `activeAt`, and the anchor
   is the first matching ask no later than `activeAt`, as now.
6. **Uniqueness.** T appears in no other `ask`, `executed` or `failed` line. A duplicate is
   `NOT CERTIFIABLE`.

## Failure behaviour
| Condition | Result |
|---|---|
| any rule 1–5 missing or not met | `BASE PROVENANCE: UNVERIFIED`, `READY: NO` (certifiable) |
| a malformed or contradictory version-2 line after the anchor, or a duplicate tool-use id | `NOT CERTIFIABLE` |
| `ls-remote` timeout or error | `remote-head` status `timeout`/`error` → `UNVERIFIED` |
| a hook fails or misses its deadline | its line is missing → `UNVERIFIED`; the guard's decision never changes |
| a log rotated or replaced during the read, a missing log or a linked log directory | `NOT CERTIFIABLE`, as today |
| a version-1-only log (older plugin) | `UNVERIFIED` |
| the base commit's settings could auto-approve the start command | `UNVERIFIED` |

## Regression tests (to write with the implementation; real hooks fed JSON, as today)
- **Chain:** a full correct chain reports `VERIFIED`. Each single missing line reports
  `UNVERIFIED` and names the rule: prompted, executed, remote-head.
- **Mismatches:** a mismatched tool-use id, hash, session, ref, commit or remote URL hash reports
  `UNVERIFIED`.
- **Modes:** `bypassPermissions`, `dontAsk` and `plan` at the ask, the prompt or the execution
  report `UNVERIFIED`; `auto` only once V1 is recorded.
- **Ordering:** a prompt before the ask, an execution before the prompt, a remote record before
  the execution, or an execution after `activeAt` each report `UNVERIFIED`.
- **Failures:** a `failed` line for T, or `is_interrupt: true`, reports `UNVERIFIED`.
- **Replay:** records from an earlier increment, with the same branch and another base, report
  `UNVERIFIED`; a duplicate T reports `NOT CERTIFIABLE`; a malformed version-2 line after the
  anchor reports `NOT CERTIFIABLE`.
- **Hooks:**
  - the `PermissionRequest` hook outputs no decision;
  - the `PostToolUse` hooks never change output or block;
  - a stalled `ls-remote` stand-in hits the 5 s budget, using the bounded single-run design
    (no stress test);
  - a non-start command writes nothing.
- **Log protection:** Write, Edit and Bash writes to `guard-log.jsonl` and `.1` are denied from
  every caller; the existing guard parity tests are unchanged.
- **Settings:** a base-commit `PermissionRequest` hook or an allow rule for `git switch` reports
  `UNVERIFIED`.

## Residuals
- A2: a same-user process can edit the log, the plugin or the tools in user-writable
  directories.
- User-level hooks or allow mechanisms that approve without a human prompt can't be fully seen
  from a hook. Project settings at the base commit are checked; user settings are not
  authenticated.
- `ls-remote` trusts the remote, its transport authentication and user-level Git configuration
  (credential helpers). The URL hash binds only what Git reports.
- The prompt line shows a dialog was about to be shown, not that a human read it.

## Owner decisions needed
1. Approve, change or reject the evidence format and binding rules above.
2. Which permission modes count as owner-approved, after V1–V3 are checked.
3. Where the implementation lands (a separate PR after v0.3.0, or v0.3.0). Until approved,
   nothing changes and `READY: YES` stays unreachable.
