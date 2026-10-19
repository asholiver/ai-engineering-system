#!/bin/bash
# workstate.sh: the supported transition interface for work-item state (WORK-002, ADR-0004).
#
# Manages .agents/specs/active/WORK-NNN.state.json next to the spec WORK-NNN.md.
#
# IMPORTANT: state is a WORKFLOW RECORD, NOT SECURITY AUTHORITY. The --owner-command marker is
# a flag passed by the human-only /ai-engineering:approve and /ai-engineering:deliver commands.
# An agent can pass the same flag, and anyone can edit the state file directly, so a state record
# never proves owner intent. No guard or hook reads state, and no protected operation (deploy,
# merge, publish, default-branch push) depends on it: every one still asks as before.
#
# Usage:  workstate.sh [--dir <specs-directory>] <command> <WORK-ID> [arguments] [options]
# The default directory is <repository root>/.agents/specs/active. Commands never take a state
# file path; they derive it from the work ID.
#
# Exit codes:
#   0  success
#   1  environment or internal error (missing jq or hashing tool, lock timeout, write failure)
#   2  usage error (unknown command or option, missing or malformed argument)
#   3  invalid transition (wrong status for the command, unknown record, rule not met)
#   4  missing owner command (owner-only transition requested without the matching marker)
#   5  schema error (state missing, unreadable, corrupt or invalid; never repaired)
#   6  spec-hash mismatch (spec changed since approval; the item is returned to proposed)
#   7  delivery policy rejected (deployment fields, production entries, unknown or invalid fields)
#   8  import refused (Status line is not a recognisable v0.2 Draft or Approved status)
#
# Commands (A = owner-only, needs --owner-command <approve|deliver>; C = coordinator, no marker):
#   create          C  -> proposed (the spec must exist) [--title <text>]
#   approve <sub>   A  marker "approve"; sub-actions, one per owner-only transition:
#                        spec                     proposed -> approved (hash, commit, policy checked)
#                        accept <finding-id>      accept or waive a finding's risk
#                        defer <finding-id>       defer a finding to later work
#                        tier <increment-id> <n>  lower an increment's tier to n (0|1|2)
#                        revoke                   any live status -> proposed
#                      accept, defer and tier accept [--decision <id>] to resolve an open trigger-3
#                      decision, and [--note <text>].
#   deliver         A  marker "deliver": approved -> authorised -> delivering, or resume a paused
#                      item, or resume a blocked item whose blocking decision is trigger 3 and
#                      was answered by an approve sub-action. Refused for any other status.
#   block           C  delivering -> blocked: --trigger <1-5> --question <text> [--options a,b]
#   propose         C  record an open, non-blocking trigger-1 scope proposal while delivering
#                      (status unchanged): --question <text> [--options a,b]. For a request that
#                      would add scope without changing the approved work, which continues.
#   answer          C  blocked -> delivering: --decision <id> [--answer <text>] [--by <name>].
#                      Only the decision that caused the current block resumes it.
#                      Conversation answers are recorded as source "conversation". A trigger-3
#                      decision must already have been answered through an approve sub-action.
#                      Answering an open proposal records the owner's choice only and leaves the
#                      status as is: accepted scope is never delivered under the current approval
#                      (it needs a spec change and approve spec, or a separate work item).
#   decision        C  record a non-blocking conversation decision (triggers 1, 2, 4, 5):
#                      --trigger <n> --question <text> --answer <text>
#   pause           C  authorised|delivering|blocked -> paused [--actor owner|coordinator]
#   done            C  delivering -> done, when every increment is merged (and at least one exists)
#   archive         C  done -> archived
#   check           C  the spec-hash transition check on its own (exit 6 and revert on mismatch)
#   increment-add, increment-set, increment-recovery, raise-tier, evidence,
#   finding-add, finding-fixed, finding-invalid, owner-action-add, owner-action-done   C  records
#   import          C  create state from a v0.2 spec Status line (Draft or Approved), never
#                      authorised or delivering. Idempotent. [--merged "id|title|pr|mergeSha[|tier]"]
#   show            read-only: the full state as JSON
#   status          read-only: a compact JSON summary, including whether the spec hash still matches
#   readiness       read-only: JSON listing for the readiness report [--inc <id>]: high or critical
#                   findings and dispositions, owner-command risk and tier decisions (time, spec
#                   hash), conversation decisions, open decisions and proposals, open findings,
#                   pending owner actions
#
# Spec-hash check: every mutating command except create, import and approve spec first compares
# the SHA-256 of the spec file with the approved hash. A difference returns the item to proposed
# (history records it) and exits 6, so delivery stops at its next transition check.
#
# Delivery policy: read from the spec's "## Delivery policy" section, lines of the form
# "key: value" (optionally bulleted, backticks allowed). Blank lines and HTML comments are
# allowed; any other line that is not a recognised key: value entry is rejected, and any line
# naming production, deploy, environment, release or publish is rejected. Fields:
#   pushWorkBranch: true|false          (default true)
#   openPullRequest: true|false|draft|ready   (default true; true means ready; never merges)
# Deployment fields (ephemeralDeploy, persistentEnvironments) and any production, deploy,
# release or publish entry are rejected with a pointer to WORK-004. No section means defaults.
#
# Writes are atomic: a temp file in the same directory is validated against the schema, then
# renamed over the state file. A corrupt or invalid state file stops the command (exit 5) and is
# never repaired.

# shellcheck disable=SC2016 # jq programs are single-quoted on purpose: $name is a jq variable, not a shell expansion
set -u

EXIT_ENVIRONMENT=1
EXIT_USAGE=2
EXIT_INVALID_TRANSITION=3
EXIT_MISSING_OWNER_COMMAND=4
EXIT_SCHEMA=5
EXIT_SPEC_HASH=6
EXIT_POLICY=7
EXIT_IMPORT=8

SCHEMA_VERSION=1
MAX_TEXT_LENGTH=2000
workflow_notice="owner-command records are a workflow record, not security authority"

fail() {
  local code="$1"
  shift
  printf 'workstate: %s\n' "$*" >&2
  exit "$code"
}

command -v jq >/dev/null 2>&1 || fail "$EXIT_ENVIRONMENT" "jq is required"

# ------------------------------------------------------------------ schema validator (jq)
# Prints an array of error messages; an empty array means the state is valid.
schema_validator='
def text: type == "string";
def textOrNull: . == null or text;
def sha: text and test("^[0-9a-f]{64}$");
def one_of($set): . as $value | (($set | index($value)) != null);
def need($ok; $message): if $ok then empty else $message end;
def each_of($name; check):
  (.[$name] // null) | if type == "array" then (.[] | check) else "\($name) must be an array" end;
def tier: type == "number" and . == floor and . >= 0 and . <= 2;
[
  if type != "object" then "state must be a JSON object" else
    need(.schemaVersion == 1; "schemaVersion must be 1"),
    need(.id | text and test("^WORK-[0-9]+$"); "id must look like WORK-NNN"),
    need(.title | text; "title must be a string"),
    need(.status | one_of(["proposed","approved","authorised","delivering","blocked","paused","done","archived"]); "status is not a known lifecycle status"),
    need(.pausedFrom | (. == null or one_of(["authorised","delivering","blocked"])); "pausedFrom must be null or authorised, delivering or blocked"),
    need((.status == "paused") == (.pausedFrom != null); "pausedFrom must be set exactly when status is paused"),
    need(.createdAt | text; "createdAt must be a string"),
    need(.updatedAt | text; "updatedAt must be a string"),
    need(.spec | (type == "object" and (.path | text) and (.contentSha256 | sha) and (.approvedCommit | textOrNull)); "spec must have path, contentSha256 and approvedCommit"),
    need(.approval | (. == null or (type == "object" and (.by | text) and (.at | text) and (.specSha256 | sha) and (.source | one_of(["owner-command","imported"])))); "approval is invalid"),
    need(.delivery | (. == null or (type == "object" and (.by | text) and (.at | text) and (.specSha256 | sha) and (.policy | type == "object"))); "delivery is invalid"),
    need((.status == "proposed") == (.approval == null); "approval must be null exactly when status is proposed"),
    need((.delivery != null) == (.status | one_of(["proposed","approved"]) | not); "delivery must be set exactly when the status is past approved"),
    each_of("ownerActions"; need(type == "object" and (.id | text) and (.description | text) and (.increment | textOrNull) and (.status | one_of(["requested","done"])) and (.requestedAt | text) and (.doneAt | textOrNull); "ownerActions entry is invalid")),
    each_of("decisions"; need(type == "object" and (.id | text) and (.trigger | (type == "number" and . >= 1 and . <= 5 and . == floor)) and (.question | text) and (.options | type == "array") and (.askedAt | text) and (.answeredAt | textOrNull) and (.answer | textOrNull) and (.source | (. == null or one_of(["owner-command","conversation"]))) and (.by | textOrNull) and (.blocking | (. == null or type == "boolean")); "decisions entry is invalid")),
    each_of("increments"; need(type == "object" and (.id | text) and (.title | text) and (.status | one_of(["planned","active","ready","merged"])) and (.proposedTier | tier) and (.tier | tier) and (.branch | textOrNull) and (.pr | textOrNull) and (.baseSha | textOrNull) and (.headSha | textOrNull) and (.mergeSha | textOrNull) and (.recoveries | (type == "number" and . >= 0 and . == floor)) and (.activeAt | textOrNull) and (.readyAt | textOrNull) and (.mergedAt | textOrNull) and (.evidence | type == "array"); "increments entry is invalid")),
    each_of("findings"; need(type == "object" and (.id | text) and (.source | text) and (.severity | one_of(["critical","high","medium","low","info"])) and (.security | type == "boolean") and (.summary | text) and (.disposition | (type == "object" and (.state | one_of(["open","fixed","invalid","owner"])) and ((.state != "fixed") or (.sha | text)) and ((.state != "invalid") or ((.evidence | text) and (.confirmedBy | textOrNull))) and ((.state != "owner") or ((.decisionId | text) and (.action | one_of(["accept","defer","tier"])))))); "findings entry is invalid")),
    each_of("history"; need(type == "object" and (.at | text) and (.transition | text) and (.actor | text); "history entry is invalid"))
  end
]'

validate_state_json() { # json text; prints one error per line
  jq -r "$schema_validator | .[]" <<<"$1" 2>/dev/null
}

# ------------------------------------------------------------------ environment
specs_directory=""
state_file=""
spec_file=""
lock_directory=""
temporary_file=""
state_json=""
now=""
id=""
status=""

cleanup() {
  [ -n "$temporary_file" ] && rm -f "$temporary_file"
  [ -n "$spec_snapshot" ] && rm -f "$spec_snapshot"
  if [ -n "$lock_directory" ] && [ "$(cat "$lock_directory/pid" 2>/dev/null || true)" = "$$" ]; then
    rm -rf "$lock_directory"
  fi
}
trap cleanup EXIT

sha256_of() { # file
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    fail "$EXIT_ENVIRONMENT" "neither shasum nor sha256sum is available"
  fi
}

# ------------------------------------------------------------------ option parsing
opt_owner_command="" opt_by="" opt_title="" opt_trigger="" opt_question="" opt_options=""
opt_answer="" opt_decision="" opt_finding="" opt_inc="" opt_status="" opt_branch="" opt_pr=""
opt_base_sha="" opt_head_sha="" opt_merge_sha="" opt_tier="" opt_kind="" opt_result=""
opt_note="" opt_evidence="" opt_sha="" opt_severity="" opt_summary="" opt_security="no"
opt_confirmed_by="" opt_action_id="" opt_description="" opt_actor="" opt_source=""
opt_increment=""
merged_specs=()
positional=()

parse_options() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --security) opt_security="yes"; shift; continue ;;
      --*) [ $# -ge 2 ] || fail "$EXIT_USAGE" "option $1 needs a value" ;;
    esac
    case "$1" in
      --owner-command) opt_owner_command="$2" ;;
      --by) opt_by="$2" ;;
      --title) opt_title="$2" ;;
      --trigger) opt_trigger="$2" ;;
      --question) opt_question="$2" ;;
      --options) opt_options="$2" ;;
      --answer) opt_answer="$2" ;;
      --decision) opt_decision="$2" ;;
      --finding) opt_finding="$2" ;;
      --inc) opt_inc="$2" ;;
      --status) opt_status="$2" ;;
      --branch) opt_branch="$2" ;;
      --pr) opt_pr="$2" ;;
      --base-sha) opt_base_sha="$2" ;;
      --head-sha) opt_head_sha="$2" ;;
      --merge-sha) opt_merge_sha="$2" ;;
      --tier) opt_tier="$2" ;;
      --kind) opt_kind="$2" ;;
      --result) opt_result="$2" ;;
      --note) opt_note="$2" ;;
      --evidence) opt_evidence="$2" ;;
      --sha) opt_sha="$2" ;;
      --severity) opt_severity="$2" ;;
      --summary) opt_summary="$2" ;;
      --confirmed-by) opt_confirmed_by="$2" ;;
      --action-id) opt_action_id="$2" ;;
      --description) opt_description="$2" ;;
      --actor) opt_actor="$2" ;;
      --source) opt_source="$2" ;;
      --increment) opt_increment="$2" ;;
      --merged) merged_specs+=("$2") ;;
      --*) fail "$EXIT_USAGE" "unknown option $1" ;;
      *) positional+=("$1"); shift; continue ;;
    esac
    shift 2
  done
}

check_text() { # option-name value: bounded, no control characters
  local length=${#2}
  [ "$length" -le "$MAX_TEXT_LENGTH" ] || fail "$EXIT_USAGE" "$1 is longer than $MAX_TEXT_LENGTH characters"
  case "$2" in *[[:cntrl:]]*) fail "$EXIT_USAGE" "$1 must not contain control characters" ;; esac
}

need_text() { # option-name value
  [ -n "$2" ] || fail "$EXIT_USAGE" "$1 is required"
  check_text "$1" "$2"
}

need_identifier() { # option-name value
  [ -n "$2" ] || fail "$EXIT_USAGE" "$1 is required"
  [[ $2 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || fail "$EXIT_USAGE" "$1 must be 1-64 letters, digits, dot, dash or underscore"
}

need_sha() { # option-name value (optional: empty allowed)
  [ -z "$2" ] || [[ $2 =~ ^[0-9a-fA-F]{7,64}$ ]] || fail "$EXIT_USAGE" "$1 must be a hexadecimal commit id"
}

actor_name() { printf '%s' "${opt_by:-${USER:-unknown}}"; }

# ------------------------------------------------------------------ state access
# The hash and the delivery policy of one transition come from the same snapshot of the spec
# (taken by snapshot_spec), so a concurrent edit cannot make them disagree.
spec_snapshot=""
spec_hash() { sha256_of "${spec_snapshot:-$spec_file}"; }
snapshot_spec() {
  [ -f "$spec_file" ] || return 0
  spec_snapshot="$(mktemp "$specs_directory/.$id.spec.XXXXXX")" || fail "$EXIT_ENVIRONMENT" "cannot snapshot the spec"
  cp "$spec_file" "$spec_snapshot" || fail "$EXIT_ENVIRONMENT" "cannot snapshot the spec"
}

# The lock is removed on exit only by the process that created it.
acquire_lock() {
  local attempts=0 holder
  local candidate="$specs_directory/.$id.lock"
  until mkdir "$candidate" 2>/dev/null; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 100 ]; then
      holder="$(cat "$candidate/pid" 2>/dev/null || true)"
      fail "$EXIT_ENVIRONMENT" "another transition holds the lock for $id (pid ${holder:-unknown}); if no workstate process is running, remove $candidate"
    fi
    sleep 0.1
  done
  lock_directory="$candidate"
  printf '%s\n' "$$" >"$lock_directory/pid"
}

load_state() {
  [ -e "$state_file" ] || fail "$EXIT_SCHEMA" "no state for $id; use create (new work) or import (v0.2 spec)"
  [ -r "$state_file" ] || fail "$EXIT_SCHEMA" "state for $id is unreadable; not modified"
  state_json="$(cat "$state_file")" || fail "$EXIT_SCHEMA" "state for $id could not be read; not modified"
  jq -e . >/dev/null 2>&1 <<<"$state_json" || fail "$EXIT_SCHEMA" "state for $id is not valid JSON; it was not modified or repaired. Restore it from Git or recreate it deliberately."
  local errors
  errors="$(validate_state_json "$state_json")"
  [ -z "$errors" ] || fail "$EXIT_SCHEMA" "state for $id fails schema validation and was not modified or repaired: $(printf '%s' "$errors" | tr '\n' ';')"
  [ "$(jq -r '.id' <<<"$state_json")" = "$id" ] || fail "$EXIT_SCHEMA" "state file for $id names a different work item; not modified"
  status="$(jq -r '.status' <<<"$state_json")"
}

commit_state() { # new state JSON
  local errors
  temporary_file="$(mktemp "$specs_directory/.$id.XXXXXX")" || fail "$EXIT_ENVIRONMENT" "cannot create a temporary file in $specs_directory"
  printf '%s\n' "$1" >"$temporary_file" || fail "$EXIT_ENVIRONMENT" "cannot write the temporary state file"
  jq -e . >/dev/null 2>&1 <"$temporary_file" || fail "$EXIT_SCHEMA" "refusing to write: the new state is not valid JSON"
  errors="$(validate_state_json "$(cat "$temporary_file")")"
  [ -z "$errors" ] || fail "$EXIT_SCHEMA" "refusing to write: the new state fails schema validation: $(printf '%s' "$errors" | tr '\n' ';')"
  chmod 644 "$temporary_file"
  mv -f "$temporary_file" "$state_file" || fail "$EXIT_ENVIRONMENT" "cannot replace the state file"
  temporary_file=""
}

# mutate <transition> <actor> <jq filter> [jq args...]: applies the filter, appends a history
# entry, refreshes updatedAt and writes atomically.
mutate() {
  local transition="$1" actor="$2" filter="$3" updated
  shift 3
  updated="$(jq "$@" --arg now "$now" --arg transition "$transition" --arg actor "$actor" \
    "($filter) | .updatedAt = \$now | .history += [{at: \$now, transition: \$transition, actor: \$actor}]" <<<"$state_json")" \
    || fail "$EXIT_ENVIRONMENT" "internal error building the state update"
  commit_state "$updated"
  state_json="$updated"
  status="$(jq -r '.status' <<<"$state_json")"
}

query() { jq -r "$@" <<<"$state_json"; }
holds() { jq -e "$@" <<<"$state_json" >/dev/null 2>&1; }

require_status() { # command, allowed statuses...
  local command_name="$1" allowed
  shift
  for allowed in "$@"; do [ "$status" = "$allowed" ] && return 0; done
  fail "$EXIT_INVALID_TRANSITION" "$command_name is not allowed while $id is $status (allowed: $*)"
}

require_owner_command() { # expected marker
  if [ -z "$opt_owner_command" ]; then
    fail "$EXIT_MISSING_OWNER_COMMAND" "this transition needs the owner command marker (--owner-command $1) from the human-only /ai-engineering:$1 command; state unchanged. Note: $workflow_notice."
  fi
  if [ "$opt_owner_command" != "$1" ]; then
    fail "$EXIT_MISSING_OWNER_COMMAND" "the '$opt_owner_command' owner command cannot perform this transition; it needs '$1'. State unchanged. Note: $workflow_notice."
  fi
}

# Loads state for a mutating command, taking the lock first.
open_for_update() {
  acquire_lock
  load_state
}

# The spec-hash transition check. Statuses with an approval return to proposed on a change.
transition_check() {
  local current approved
  case "$status" in approved | authorised | delivering | blocked | paused) ;; *) return 0 ;; esac
  [ -f "$spec_file" ] || fail "$EXIT_SPEC_HASH" "the spec file for $id is missing; delivery stops. State unchanged."
  current="$(spec_hash)"
  approved="$(query '.approval.specSha256')"
  [ "$current" = "$approved" ] && return 0
  local previous_status="$status"
  mutate "$previous_status->proposed (spec changed)" "workstate" \
    '.status = "proposed" | .pausedFrom = null | .approval = null | .delivery = null | .spec.contentSha256 = $hash' \
    --arg hash "$current"
  fail "$EXIT_SPEC_HASH" "the spec for $id changed since it was approved; the item is back to proposed and delivery stops. The owner must approve the new spec."
}

# ------------------------------------------------------------------ delivery policy
policy_json=""
read_policy() {
  local section result errors
  section="$(awk '/^## /{ in_section = ($0 ~ /^##[[:space:]]+[Dd]elivery [Pp]olicy[[:space:]]*$/); next } in_section { print }' "${spec_snapshot:-$spec_file}")"
  # Every non-blank, non-comment line must be a recognised "key: value" entry. Lines naming
  # production, deploy, environment, release or publish are rejected whatever their form.
  result="$(jq -Rn --arg text "$section" '
    ($text | gsub("(?s)<!--.*?-->"; "") | split("\n")
      | map(sub("^\\s*[-*]\\s+"; "") | gsub("`"; "") | sub("^\\s+"; "") | sub("\\s+$"; ""))
      | map(select(. != ""))
      | map({raw: ., parsed: ([capture("^(?<key>[A-Za-z][A-Za-z0-9]*)\\s*:\\s*(?<value>\\S.*)$")] | first)})) as $lines
    | ($lines | map(select(.parsed != null) | .parsed)) as $entries
    | ($entries | map(.key)) as $keys
    | ([ $lines[]
        | (.raw | gsub("[[:cntrl:]]"; "") | .[0:80]) as $shown
        | if (.parsed != null and (.parsed.key | IN("ephemeralDeploy", "persistentEnvironments"))) then
            "\(.parsed.key) is a deployment field: deployment policy is not available until WORK-004, and every deploy still asks in v0.3.0"
          elif (.raw | test("prod|deploy|environment|release|publish"; "i")) then
            "\($shown): production, deploy, environment, release and publish entries cannot be expressed in delivery policy (see WORK-004); they always need the owner"
          elif .parsed == null then
            "unrecognised line in the delivery policy section (expected key: value): \($shown)"
          else .parsed as $entry | ($entry |
          if (.key | IN("pushWorkBranch", "openPullRequest") | not) then
            "unknown delivery policy field \(.key); only pushWorkBranch and openPullRequest exist in v0.3.0 (deployment fields are WORK-004)"
          elif (.key == "pushWorkBranch" and (.value | ascii_downcase | IN("true", "false") | not)) then
            "pushWorkBranch must be true or false"
          elif (.key == "openPullRequest" and (.value | ascii_downcase | IN("true", "false", "draft", "ready") | not)) then
            "openPullRequest must be true, false, draft or ready"
          else empty end) end ]
      + (if ($keys | length) != ($keys | unique | length) then ["a delivery policy field is declared twice"] else [] end)) as $errors
    | ([$entries[] | select(.key == "pushWorkBranch") | .value | ascii_downcase] | first // "true") as $push
    | ([$entries[] | select(.key == "openPullRequest") | .value | ascii_downcase] | first // "true") as $pull_request
    | { errors: ($errors + (if $push == "false" and ($pull_request != "false") then ["openPullRequest requires pushWorkBranch: true"] else [] end)),
        policy: { pushWorkBranch: ($push == "true"),
                  openPullRequest: ($pull_request != "false"),
                  pullRequestMode: (if $pull_request == "false" then null elif $pull_request == "draft" then "draft" else "ready" end) } }')" \
    || fail "$EXIT_ENVIRONMENT" "internal error reading the delivery policy"
  errors="$(jq -r '.errors[]' <<<"$result")"
  if [ -n "$errors" ]; then
    printf 'workstate: delivery policy rejected for %s:\n' "$id" >&2
    printf '  - %s\n' "$errors" >&2
    exit "$EXIT_POLICY"
  fi
  policy_json="$(jq -c '.policy' <<<"$result")"
}

# ------------------------------------------------------------------ commands
cmd_create() {
  [ -f "$spec_file" ] || fail "$EXIT_INVALID_TRANSITION" "cannot create state: spec $spec_file does not exist"
  acquire_lock
  [ ! -e "$state_file" ] || fail "$EXIT_INVALID_TRANSITION" "state for $id already exists"
  local title="${opt_title:-}" hash path
  [ -n "$title" ] || title="$(sed -n 's/^# *//p' "$spec_file" | head -n 1)"
  [ -n "$title" ] || title="$id"
  check_text "--title" "$title"
  hash="$(spec_hash)"
  path="$(spec_path_for_record)"
  commit_state "$(jq -n --arg id "$id" --arg title "$title" --arg path "$path" --arg hash "$hash" --arg now "$now" --argjson version "$SCHEMA_VERSION" '
    { schemaVersion: $version, id: $id, title: $title, status: "proposed", pausedFrom: null,
      createdAt: $now, updatedAt: $now,
      spec: { path: $path, contentSha256: $hash, approvedCommit: null },
      approval: null, delivery: null, ownerActions: [], decisions: [], increments: [], findings: [],
      history: [{ at: $now, transition: "create->proposed", actor: "coordinator" }] }')"
  echo "created $id (proposed)"
}

spec_path_for_record() {
  local prefix
  prefix="$(git -C "$specs_directory" rev-parse --show-prefix 2>/dev/null)" || prefix=""
  if [ -n "$prefix" ]; then printf '%s%s.md' "$prefix" "$id"; else printf '%s' "$spec_file"; fi
}

cmd_approve() {
  require_owner_command approve
  local sub="${positional[1]:-}"
  [ -n "$sub" ] || fail "$EXIT_USAGE" "approve needs a sub-action: spec | accept <finding> | defer <finding> | tier <increment> <0|1|2> | revoke"
  open_for_update
  [ "$sub" != spec ] || snapshot_spec
  transition_check
  local actor="owner-command:approve" owner_by
  owner_by="$(actor_name)"
  check_text "--by" "$owner_by"
  check_text "--note" "$opt_note"
  case "$sub" in
    spec)
      local transition_label="proposed->approved"
      if [ "$status" = approved ] && [ "$(query '.approval.source')" = imported ]; then
        transition_label="approved->approved (imported approval replaced by an owner command)"
      else
        require_status "approve spec" proposed
      fi
      [ -f "$spec_file" ] || fail "$EXIT_INVALID_TRANSITION" "the spec file for $id does not exist"
      read_policy
      local hash commit
      hash="$(spec_hash)"
      commit="$(git -C "$specs_directory" rev-parse HEAD 2>/dev/null || true)"
      mutate "$transition_label" "$actor" \
        '.status = "approved" | .spec.contentSha256 = $hash | .spec.approvedCommit = (if $commit == "" then null else $commit end)
         | .approval = {by: $by, at: $now, specSha256: $hash, source: "owner-command", command: "approve"}' \
        --arg hash "$hash" --arg commit "$commit" --arg by "$owner_by"
      echo "$id approved (owner-command; a workflow record, not security authority)"
      ;;
    accept | defer)
      require_status "approve $sub" delivering blocked paused
      local finding="${positional[2]:-}"
      need_identifier "finding id" "$finding"
      holds --arg f "$finding" '.findings | any(.id == $f and .disposition.state == "open")' || fail "$EXIT_INVALID_TRANSITION" "finding $finding does not exist or is not open"
      record_owner_decision "$sub" "$finding" "" "$actor" "$owner_by"
      ;;
    tier)
      require_status "approve tier" delivering blocked paused
      local increment="${positional[2]:-}" new_tier="${positional[3]:-}"
      need_identifier "increment id" "$increment"
      [[ $new_tier =~ ^[012]$ ]] || fail "$EXIT_USAGE" "tier must be 0, 1 or 2"
      holds --arg i "$increment" '.increments | any(.id == $i)' || fail "$EXIT_INVALID_TRANSITION" "increment $increment does not exist"
      holds --arg i "$increment" --argjson t "$new_tier" '.increments | any(.id == $i and .tier > $t)' || fail "$EXIT_INVALID_TRANSITION" "approve tier only lowers a tier; raising is a coordinator record (raise-tier)"
      record_owner_decision "tier" "" "$increment:$new_tier" "$actor" "$owner_by"
      ;;
    revoke)
      require_status "approve revoke" approved authorised delivering blocked paused
      mutate "$status->proposed (revoked)" "$actor" '.status = "proposed" | .pausedFrom = null | .approval = null | .delivery = null'
      echo "$id approval revoked (proposed); this changes workflow state only"
      ;;
    *) fail "$EXIT_USAGE" "unknown approve sub-action '$sub'" ;;
  esac
}

# Records an owner-command decision for accept, defer or tier, resolving an open trigger-3
# decision when --decision is given.
record_owner_decision() { # kind finding tier-spec actor by
  local kind="$1" finding="$2" tier_spec="$3" actor="$4" owner_by="$5" decision_id question answer
  local increment_id="" new_tier_value=0
  if [ -n "$tier_spec" ]; then
    increment_id="${tier_spec%%:*}"
    new_tier_value="${tier_spec##*:}"
  fi
  answer="${opt_note:-$kind}"
  case "$kind" in
    accept) question="accept or waive the risk of finding $finding" ;;
    defer) question="defer finding $finding to later work" ;;
    *) question="lower the tier of increment ${tier_spec%%:*} to ${tier_spec##*:}" ;;
  esac
  if [ -n "$opt_decision" ]; then
    holds --arg d "$opt_decision" '.decisions | any(.id == $d and .trigger == 3 and .answeredAt == null)' || fail "$EXIT_INVALID_TRANSITION" "decision $opt_decision does not exist, is not trigger 3, or is already answered"
    decision_id="$opt_decision"
  else
    decision_id="D$(( $(query '.decisions | length') + 1 ))"
  fi
  mutate "$kind (owner decision $decision_id)" "$actor" '
      (if $existing == "yes" then
         .decisions |= map(if .id == $decision then .answer = $answer | .answeredAt = $now | .source = "owner-command" | .by = $by | .specSha256 = $spec_hash else . end)
       else
         .decisions += [{id: $decision, trigger: 3, question: $question, options: [], askedAt: $now, answeredAt: $now, answer: $answer, source: "owner-command", by: $by, specSha256: $spec_hash}]
       end)
      | if $finding != "" then .findings |= map(if .id == $finding then .disposition = {state: "owner", decisionId: $decision, action: $kind} else . end) else . end
      | if $kind == "tier" then .increments |= map(if .id == $increment then .tier = $new_tier else . end) else . end' \
    --arg decision "$decision_id" --arg existing "$([ -n "$opt_decision" ] && echo yes || echo no)" \
    --arg answer "$answer" --arg question "$question" --arg by "$owner_by" --arg finding "$finding" --arg kind "$kind" \
    --arg increment "$increment_id" --argjson new_tier "$new_tier_value" --arg spec_hash "$(query '.approval.specSha256')"
  echo "$id: $kind recorded as decision $decision_id (owner-command; a workflow record, not security authority)"
}

# The decision that caused the current block: the most recent decision created by block.
# Decisions without a blocking field (written before it existed) never count, so such an item
# cannot resume through answer or deliver.
current_block_id() { query '[.decisions[] | select(.blocking == true)] | last | .id // ""'; }

cmd_deliver() {
  require_owner_command deliver
  open_for_update
  case "$status" in
    approved | paused | blocked) ;;
    *) fail "$EXIT_INVALID_TRANSITION" "deliver is refused: $id is $status; deliver applies only to an approved item, a paused item, or a blocked item whose trigger-3 decision the owner has answered" ;;
  esac
  snapshot_spec
  transition_check
  if [ "$status" = blocked ]; then
    # Resume only when the decision that caused the block is a trigger-3 decision the owner has
    # answered through an approve sub-action. Other triggers are answered in conversation (answer).
    local block_id
    block_id="$(current_block_id)"
    holds --arg d "$block_id" '.decisions | any(.id == $d and .trigger == 3 and .source == "owner-command" and .answeredAt != null)' \
      || fail "$EXIT_INVALID_TRANSITION" "deliver is refused: $id is blocked on decision ${block_id:-?}, which is not a trigger-3 decision answered by the owner's approve command. Answer it first (trigger 3: /ai-engineering:approve <accept|defer|tier> ... --decision ${block_id:-<id>}; other triggers: in conversation)."
    mutate "blocked->delivering (resumed after owner decision $block_id)" "owner-command:deliver" '.status = "delivering"'
    echo "$id delivering again (decision $block_id answered by the owner; owner-command; a workflow record, not security authority)"
    return 0
  fi
  if [ "$status" = approved ] && [ "$(query '.approval.source')" = imported ]; then
    fail "$EXIT_INVALID_TRANSITION" "deliver is refused: the approval of $id was imported from a v0.2 Status line, and v0.2 authority is never v0.3 authority. Approve the current spec first with /ai-engineering:approve $id spec, then deliver."
  fi
  local actor="owner-command:deliver" owner_by
  owner_by="$(actor_name)"
  check_text "--by" "$owner_by"
  if [ "$status" = "paused" ]; then
    local resume_to
    resume_to="$(query '.pausedFrom')"
    mutate "paused->$resume_to (resumed)" "$actor" '.status = .pausedFrom | .pausedFrom = null'
    echo "$id resumed ($resume_to; owner-command; a workflow record, not security authority)"
    return 0
  fi
  read_policy
  # Two recorded steps in one atomic write: the filter adds approved->authorised, mutate adds
  # authorised->delivering.
  mutate "authorised->delivering" "$actor" \
    '.status = "delivering" | .delivery = {by: $by, at: $now, specSha256: .approval.specSha256, source: "owner-command", command: "deliver", policy: $policy}
     | .history += [{at: $now, transition: "approved->authorised", actor: "owner-command:deliver"}]' \
    --arg by "$owner_by" --argjson policy "$policy_json"
  echo "$id authorised and delivering (owner-command; a workflow record, not security authority)"
}

cmd_block() {
  open_for_update
  require_status block delivering
  transition_check
  [[ $opt_trigger =~ ^[1-5]$ ]] || fail "$EXIT_USAGE" "--trigger must be 1 to 5"
  need_text "--question" "$opt_question"
  check_text "--options" "$opt_options"
  mutate "delivering->blocked (trigger $opt_trigger)" "coordinator" '
      .status = "blocked"
      | .decisions += [{id: ("D" + ((.decisions | length) + 1 | tostring)), trigger: $trigger, question: $question,
                        options: (if $options == "" then [] else ($options | split(",")) end),
                        askedAt: $now, answeredAt: null, answer: null, source: null, by: null, blocking: true}]' \
    --argjson trigger "$opt_trigger" --arg question "$opt_question" --arg options "$opt_options"
  echo "$id blocked (trigger $opt_trigger): decision D$(query '.decisions | length')"
}

cmd_propose() {
  open_for_update
  require_status propose delivering
  transition_check
  [ -z "$opt_trigger" ] || [ "$opt_trigger" = 1 ] || fail "$EXIT_USAGE" "propose records trigger 1 (scope) only; other triggers block"
  need_text "--question" "$opt_question"
  check_text "--options" "$opt_options"
  mutate "scope proposal recorded (trigger 1, not blocking)" "coordinator" '
      .decisions += [{id: ("D" + ((.decisions | length) + 1 | tostring)), trigger: 1, question: $question,
                      options: (if $options == "" then [] else ($options | split(",")) end),
                      askedAt: $now, answeredAt: null, answer: null, source: null, by: null, blocking: false}]' \
    --arg question "$opt_question" --arg options "$opt_options"
  echo "$id still delivering: scope proposal D$(query '.decisions | length') recorded for the owner (trigger 1)"
}

cmd_answer() {
  open_for_update
  require_status answer blocked delivering paused
  transition_check
  need_identifier "--decision" "$opt_decision"
  holds --arg d "$opt_decision" '.decisions | any(.id == $d)' || fail "$EXIT_INVALID_TRANSITION" "decision $opt_decision does not exist"
  local trigger answered_by_owner proposal=no
  holds --arg d "$opt_decision" '.decisions | any(.id == $d and .blocking == false)' && proposal=yes
  [ "$proposal" = yes ] || [ "$status" = blocked ] \
    || fail "$EXIT_INVALID_TRANSITION" "answer is not allowed while $id is $status, except for an open scope proposal"
  if [ "$proposal" = no ]; then
    # Only the decision that caused the current block can resume it; an earlier answered
    # decision (for example an unrelated owner-command decision) never can.
    local block_id
    block_id="$(current_block_id)"
    [ "$opt_decision" = "$block_id" ] \
      || fail "$EXIT_INVALID_TRANSITION" "decision $opt_decision is not the decision that blocked $id (${block_id:-none recorded}); only that decision resumes delivery"
  fi
  trigger="$(query --arg d "$opt_decision" '.decisions[] | select(.id == $d) | .trigger')"
  if [ "$trigger" = "3" ]; then
    holds --arg d "$opt_decision" '.decisions | any(.id == $d and .source == "owner-command" and .answeredAt != null)' \
      || fail "$EXIT_MISSING_OWNER_COMMAND" "decision $opt_decision is trigger 3 (accepting, waiving, deferring or downgrading risk): it needs the owner's approve command (accept, defer or tier with --decision $opt_decision) before delivery resumes"
    answered_by_owner=yes
  else
    holds --arg d "$opt_decision" '.decisions | any(.id == $d and .answeredAt == null)' || fail "$EXIT_INVALID_TRANSITION" "decision $opt_decision is already answered"
    need_text "--answer" "$opt_answer"
    answered_by_owner=no
  fi
  local who="${opt_by:-owner}"
  check_text "--by" "$who"
  local transition="blocked->delivering (answer $opt_decision)"
  [ "$proposal" = no ] || transition="scope proposal $opt_decision answered ($status unchanged)"
  mutate "$transition" "coordinator" '
      (if $proposal == "no" then .status = "delivering" else . end)
      | if $owner == "no" then .decisions |= map(if .id == $d then .answer = $answer | .answeredAt = $now | .source = "conversation" | .by = $by else . end) else . end' \
    --arg d "$opt_decision" --arg answer "$opt_answer" --arg by "$who" --arg owner "$answered_by_owner" --arg proposal "$proposal"
  if [ "$proposal" = yes ]; then
    echo "$id still $status (scope proposal $opt_decision answered)"
  else
    echo "$id delivering again (decision $opt_decision answered)"
  fi
}

cmd_decision() {
  open_for_update
  require_status decision delivering blocked paused
  transition_check
  [[ $opt_trigger =~ ^[1-5]$ ]] || fail "$EXIT_USAGE" "--trigger must be 1 to 5"
  need_text "--question" "$opt_question"
  need_text "--answer" "$opt_answer"
  [ "$opt_trigger" != "3" ] || fail "$EXIT_MISSING_OWNER_COMMAND" "a trigger-3 decision (risk) cannot be recorded from conversation; the owner uses the approve command"
  mutate "decision recorded (trigger $opt_trigger, conversation)" "coordinator" '
      .decisions += [{id: ("D" + ((.decisions | length) + 1 | tostring)), trigger: $trigger, question: $question, options: [],
                      askedAt: $now, answeredAt: $now, answer: $answer, source: "conversation", by: $by}]' \
    --argjson trigger "$opt_trigger" --arg question "$opt_question" --arg answer "$opt_answer" --arg by "${opt_by:-owner}"
  echo "decision D$(query '.decisions | length') recorded"
}

cmd_pause() {
  open_for_update
  require_status pause authorised delivering blocked
  transition_check
  local actor="${opt_actor:-coordinator}"
  case "$actor" in owner | coordinator) ;; *) fail "$EXIT_USAGE" "--actor must be owner or coordinator" ;; esac
  mutate "$status->paused" "$actor" '.pausedFrom = .status | .status = "paused"'
  echo "$id paused"
}

cmd_done() {
  open_for_update
  require_status "done" delivering
  transition_check
  holds '(.increments | length) > 0 and (.increments | all(.status == "merged"))' || fail "$EXIT_INVALID_TRANSITION" "done needs at least one increment and every increment merged"
  mutate "delivering->done" "coordinator" '.status = "done"'
  echo "$id done"
}

cmd_archive() {
  open_for_update
  require_status archive "done"
  mutate "done->archived" "coordinator" '.status = "archived"'
  echo "$id archived"
}

cmd_check() {
  open_for_update
  transition_check
  echo "$id: spec hash check passed ($status)"
}

active_statuses=(delivering blocked paused)

cmd_increment_add() {
  open_for_update
  require_status increment-add proposed
  need_identifier "--inc" "$opt_inc"
  need_text "--title" "$opt_title"
  [[ $opt_tier =~ ^[012]$ ]] || fail "$EXIT_USAGE" "--tier must be 0, 1 or 2"
  check_text "--branch" "$opt_branch"
  holds --arg i "$opt_inc" '.increments | any(.id == $i) | not' || fail "$EXIT_INVALID_TRANSITION" "increment $opt_inc already exists"
  mutate "increment $opt_inc added" "coordinator" '
      .increments += [{id: $i, title: $title, status: "planned", proposedTier: $tier, tier: $tier,
                       branch: (if $branch == "" then null else $branch end), pr: null, baseSha: null, headSha: null, mergeSha: null,
                       recoveries: 0, activeAt: null, readyAt: null, mergedAt: null, evidence: []}]' \
    --arg i "$opt_inc" --arg title "$opt_title" --argjson tier "$opt_tier" --arg branch "$opt_branch"
  echo "increment $opt_inc added"
}

require_increment() { holds --arg i "$opt_inc" '.increments | any(.id == $i)' || fail "$EXIT_INVALID_TRANSITION" "increment ${opt_inc:-?} does not exist"; }

cmd_increment_set() {
  open_for_update
  require_status increment-set "${active_statuses[@]}"
  transition_check
  need_identifier "--inc" "$opt_inc"
  require_increment
  need_sha "--base-sha" "$opt_base_sha"
  need_sha "--head-sha" "$opt_head_sha"
  need_sha "--merge-sha" "$opt_merge_sha"
  check_text "--branch" "$opt_branch"
  check_text "--pr" "$opt_pr"
  [ -n "$opt_status$opt_branch$opt_pr$opt_base_sha$opt_head_sha$opt_merge_sha" ] \
    || fail "$EXIT_USAGE" "increment-set needs --status or at least one of --branch, --pr, --base-sha, --head-sha, --merge-sha"
  local current
  current="$(query --arg i "$opt_inc" '.increments[] | select(.id == $i) | .status')"
  # Repeating the current status records fields only (for example a new head SHA while active);
  # it changes no status or timestamp. merged -> merged stays refused.
  if [ -n "$opt_status" ] && [ "$opt_status" = "$current" ] && [ "$current" != merged ]; then
    opt_status=""
  fi
  if [ -n "$opt_status" ]; then
    case "$current>$opt_status" in
      planned\>active | active\>ready | ready\>active | ready\>merged) ;;
      *) fail "$EXIT_INVALID_TRANSITION" "increment $opt_inc cannot move from $current to $opt_status (planned>active>ready>merged; ready may return to active)" ;;
    esac
    if [ "$opt_status" = "merged" ]; then
      [ -n "$opt_merge_sha" ] || holds --arg i "$opt_inc" '.increments[] | select(.id == $i) | .mergeSha != null' || fail "$EXIT_INVALID_TRANSITION" "merged needs --merge-sha"
    fi
  fi
  mutate "increment $opt_inc updated${opt_status:+ ($current->$opt_status)}" "coordinator" '
      .increments |= map(if .id == $i then
          (if $branch != "" then .branch = $branch else . end)
          | (if $pr != "" then .pr = $pr else . end)
          | (if $base != "" then .baseSha = $base else . end)
          | (if $head != "" then .headSha = $head else . end)
          | (if $merge != "" then .mergeSha = $merge else . end)
          | (if $new_status != "" then .status = $new_status else . end)
          | (if $new_status == "active" and .activeAt == null then .activeAt = $now else . end)
          | (if $new_status == "ready" then .readyAt = $now else . end)
          | (if $new_status == "merged" then .mergedAt = $now else . end)
        else . end)' \
    --arg i "$opt_inc" --arg branch "$opt_branch" --arg pr "$opt_pr" --arg base "$opt_base_sha" --arg head "$opt_head_sha" \
    --arg merge "$opt_merge_sha" --arg new_status "$opt_status"
  echo "increment $opt_inc updated"
}

cmd_increment_recovery() {
  open_for_update
  require_status increment-recovery "${active_statuses[@]}"
  transition_check
  need_identifier "--inc" "$opt_inc"
  require_increment
  mutate "recovery recorded for increment $opt_inc" "coordinator" '.increments |= map(if .id == $i then .recoveries += 1 else . end)' --arg i "$opt_inc"
  echo "recoveries for $opt_inc: $(query --arg i "$opt_inc" '.increments[] | select(.id == $i) | .recoveries')"
}

cmd_raise_tier() {
  open_for_update
  require_status raise-tier "${active_statuses[@]}"
  transition_check
  need_identifier "--inc" "$opt_inc"
  require_increment
  [[ $opt_tier =~ ^[012]$ ]] || fail "$EXIT_USAGE" "--tier must be 0, 1 or 2"
  holds --arg i "$opt_inc" --argjson t "$opt_tier" '.increments | any(.id == $i and .tier < $t)' || fail "$EXIT_INVALID_TRANSITION" "raise-tier only raises: tier $opt_tier is not above the current tier of $opt_inc (lowering needs the owner's approve tier)"
  mutate "tier of $opt_inc raised to $opt_tier" "coordinator" '.increments |= map(if .id == $i then .tier = $t else . end)' --arg i "$opt_inc" --argjson t "$opt_tier"
  echo "tier of $opt_inc is now $opt_tier"
}

cmd_evidence() {
  open_for_update
  require_status evidence "${active_statuses[@]}"
  transition_check
  need_identifier "--inc" "$opt_inc"
  require_increment
  case "$opt_kind" in gate | review) ;; *) fail "$EXIT_USAGE" "--kind must be gate or review" ;; esac
  case "$opt_result" in pass | fail) ;; *) fail "$EXIT_USAGE" "--result must be pass or fail" ;; esac
  check_text "--note" "$opt_note"
  mutate "$opt_kind evidence ($opt_result) for $opt_inc" "coordinator" \
    '.increments |= map(if .id == $i then .evidence += [{kind: $kind, result: $result, at: $now, note: $note}] else . end)' \
    --arg i "$opt_inc" --arg kind "$opt_kind" --arg result "$opt_result" --arg note "$opt_note"
  echo "evidence recorded"
}

cmd_finding_add() {
  open_for_update
  require_status finding-add "${active_statuses[@]}"
  transition_check
  need_identifier "--finding" "$opt_finding"
  need_text "--summary" "$opt_summary"
  need_text "--source" "$opt_source"
  case "$opt_severity" in critical | high | medium | low | info) ;; *) fail "$EXIT_USAGE" "--severity must be critical, high, medium, low or info" ;; esac
  holds --arg f "$opt_finding" '.findings | any(.id == $f) | not' || fail "$EXIT_INVALID_TRANSITION" "finding $opt_finding already exists"
  mutate "finding $opt_finding added" "coordinator" '
      .findings += [{id: $f, source: $source, severity: $severity, security: ($security == "yes"), summary: $summary, disposition: {state: "open"}}]' \
    --arg f "$opt_finding" --arg source "$opt_source" --arg severity "$opt_severity" --arg security "$opt_security" --arg summary "$opt_summary"
  echo "finding $opt_finding added"
}

require_open_finding() {
  need_identifier "--finding" "$opt_finding"
  holds --arg f "$opt_finding" '.findings | any(.id == $f and .disposition.state == "open")' || fail "$EXIT_INVALID_TRANSITION" "finding ${opt_finding} does not exist or is not open"
}

cmd_finding_fixed() {
  open_for_update
  require_status finding-fixed "${active_statuses[@]}"
  transition_check
  require_open_finding
  [ -n "$opt_sha" ] || fail "$EXIT_USAGE" "--sha is required"
  need_sha "--sha" "$opt_sha"
  mutate "finding $opt_finding fixed" "coordinator" '.findings |= map(if .id == $f then .disposition = {state: "fixed", sha: $sha} else . end)' --arg f "$opt_finding" --arg sha "$opt_sha"
  echo "finding $opt_finding fixed($opt_sha)"
}

cmd_finding_invalid() {
  open_for_update
  require_status finding-invalid "${active_statuses[@]}"
  transition_check
  require_open_finding
  need_text "--evidence" "$opt_evidence"
  check_text "--confirmed-by" "$opt_confirmed_by"
  if holds --arg f "$opt_finding" '.findings | any(.id == $f and .security)' && [ -z "$opt_confirmed_by" ]; then
    fail "$EXIT_INVALID_TRANSITION" "finding $opt_finding is a security finding: it can be recorded invalid only with the raising reviewer's confirmation (--confirmed-by); otherwise this is escalation trigger 3"
  fi
  mutate "finding $opt_finding invalid" "coordinator" \
    '.findings |= map(if .id == $f then .disposition = {state: "invalid", evidence: $evidence, confirmedBy: (if $by == "" then null else $by end)} else . end)' \
    --arg f "$opt_finding" --arg evidence "$opt_evidence" --arg by "$opt_confirmed_by"
  echo "finding $opt_finding invalid"
}

cmd_owner_action_add() {
  open_for_update
  require_status owner-action-add proposed approved delivering blocked paused
  transition_check
  need_identifier "--action-id" "$opt_action_id"
  need_text "--description" "$opt_description"
  check_text "--increment" "$opt_increment"
  holds --arg a "$opt_action_id" '.ownerActions | any(.id == $a) | not' || fail "$EXIT_INVALID_TRANSITION" "owner action $opt_action_id already exists"
  mutate "owner action $opt_action_id requested" "coordinator" '
      .ownerActions += [{id: $a, description: $description, increment: (if $inc == "" then null else $inc end), status: "requested", requestedAt: $now, doneAt: null}]' \
    --arg a "$opt_action_id" --arg description "$opt_description" --arg inc "$opt_increment"
  echo "owner action $opt_action_id requested"
}

cmd_owner_action_done() {
  open_for_update
  require_status owner-action-done proposed approved delivering blocked paused
  transition_check
  need_identifier "--action-id" "$opt_action_id"
  holds --arg a "$opt_action_id" '.ownerActions | any(.id == $a and .status == "requested")' || fail "$EXIT_INVALID_TRANSITION" "owner action $opt_action_id does not exist or is already done"
  mutate "owner action $opt_action_id done" "coordinator" '.ownerActions |= map(if .id == $a then .status = "done" | .doneAt = $now else . end)' --arg a "$opt_action_id"
  echo "owner action $opt_action_id done"
}

cmd_show() {
  load_state
  jq . <<<"$state_json"
}

cmd_readiness() {
  load_state
  [ -z "$opt_inc" ] || need_identifier "--inc" "$opt_inc"
  jq --arg inc "$opt_inc" '
    . as $state
    | { id, status,
      highFindings: [.findings[] | select(.severity | IN("high", "critical"))
                     | {id, severity, security, summary, disposition}],
      ownerDecisions: [.decisions[] | select(.trigger == 3 and .source == "owner-command")
                       | {id, question, answer, at: .answeredAt, specSha256, by}],
      conversationDecisions: [.decisions[] | select(.source == "conversation")
                              | {id, trigger, question, answer, at: .answeredAt, by}],
      openDecisions: [.decisions[] | select(.answeredAt == null)
                      | {id, trigger, question, options, askedAt, blocking: (.blocking != false)}],
      openFindings: [.findings[] | select(.disposition.state == "open") | {id, severity, summary}],
      pendingOwnerActions: [.ownerActions[] | select(.status == "requested" and ($inc == "" or .increment == $inc))
                            | {id, description, increment, requestedAt}] }
    | if $inc != "" then .increment = ($state.increments | map(select(.id == $inc)) | first) else . end' <<<"$state_json"
}

cmd_status() {
  load_state
  local current="null"
  [ -f "$spec_file" ] && current="\"$(spec_hash)\""
  jq --argjson current "$current" '
    { id, title, status, pausedFrom,
      specSha256: $current,
      specMatchesApproval: (if .approval == null or $current == null then null else ($current == .approval.specSha256) end),
      approvalSource: (.approval.source // null),
      delivered: (.delivery != null),
      increments: (.increments | map({id, status, tier, recoveries})),
      openFindings: (.findings | map(select(.disposition.state == "open")) | length),
      openDecisions: (.decisions | map(select(.answeredAt == null)) | length),
      pendingOwnerActions: (.ownerActions | map(select(.status == "requested")) | length),
      updatedAt }' <<<"$state_json"
}

# ------------------------------------------------------------------ import
cmd_import() {
  [ -f "$spec_file" ] || fail "$EXIT_INVALID_TRANSITION" "cannot import: spec $spec_file does not exist"
  acquire_lock
  if [ -e "$state_file" ]; then
    load_state
    holds '.history[0].transition | startswith("import")' || fail "$EXIT_INVALID_TRANSITION" "state for $id already exists and was not imported; import does not touch it"
    add_imported_increments
    echo "$id already imported ($status); unchanged"
    return 0
  fi
  local status_line normalised word approver approval_date regex
  status_line="$(awk '/^## /{ if (seen) exit; seen = ($0 ~ /^##[[:space:]]+Status[[:space:]]*$/); next } seen && NF { print; exit }' "$spec_file")"
  [ -n "$status_line" ] || fail "$EXIT_IMPORT" "no Status line found in the spec; nothing imported"
  normalised="$(printf '%s' "$status_line" | sed -E 's/^[*_[:space:]]+//; s/^[Ss]tatus:?[*_[:space:]]*//')"
  word="$(printf '%s' "${normalised%%[^A-Za-z]*}" | tr '[:upper:]' '[:lower:]')"
  local title hash path
  title="${opt_title:-$(sed -n 's/^# *//p' "$spec_file" | head -n 1)}"
  [ -n "$title" ] || title="$id"
  check_text "--title" "$title"
  hash="$(spec_hash)"
  path="$(spec_path_for_record)"
  local new_status="proposed" approval_by="" approval_at=""
  case "$word" in
    draft) ;;
    approved)
      regex='\(by[[:space:]]+([^,)]+),[[:space:]]*([0-9]{4}-[0-9]{2}-[0-9]{2})'
      if [[ "$normalised" =~ $regex ]]; then
        approver="${BASH_REMATCH[1]}"
        approval_date="${BASH_REMATCH[2]}"
      else
        fail "$EXIT_IMPORT" "the Status line says Approved but names no approver and date in the form '(by <name>, YYYY-MM-DD)'; authority is never fabricated, so nothing was imported. Fix the Status line or approve under v0.3."
      fi
      new_status="approved"
      approval_by="$approver"
      approval_at="${approval_date}T00:00:00Z"
      ;;
    *) fail "$EXIT_IMPORT" "the Status line does not start with Draft or Approved ('${normalised:0:60}'); nothing imported" ;;
  esac
  check_text "approver" "$approval_by"
  commit_state "$(jq -n --arg id "$id" --arg title "$title" --arg path "$path" --arg hash "$hash" --arg now "$now" \
    --arg status "$new_status" --arg by "$approval_by" --arg at "$approval_at" --argjson version "$SCHEMA_VERSION" '
    { schemaVersion: $version, id: $id, title: $title, status: $status, pausedFrom: null,
      createdAt: $now, updatedAt: $now,
      spec: { path: $path, contentSha256: $hash, approvedCommit: null },
      approval: (if $status == "approved" then {by: $by, at: $at, specSha256: $hash, source: "imported", importedFrom: "v0.2 spec Status line"} else null end),
      delivery: null, ownerActions: [], decisions: [], increments: [], findings: [],
      history: [{ at: $now, transition: "import->\($status)", actor: "workstate-import" }] }')"
  load_state
  add_imported_increments
  echo "imported $id as $new_status (never authorised or delivering; the spec was not modified)"
}

add_imported_increments() {
  local entry increment_id title pull_request merge_sha tier_value rest
  for entry in ${merged_specs[@]+"${merged_specs[@]}"}; do
    increment_id="${entry%%|*}"
    rest="${entry#*|}"
    title="${rest%%|*}"
    rest="${rest#*|}"
    pull_request="${rest%%|*}"
    rest="${rest#*|}"
    merge_sha="${rest%%|*}"
    tier_value="2"
    case "$rest" in *"|"*) tier_value="${rest#*|}" ;; esac
    need_identifier "--merged increment id" "$increment_id"
    need_text "--merged title" "$title"
    check_text "--merged pr" "$pull_request"
    [ -n "$merge_sha" ] || fail "$EXIT_USAGE" "--merged needs id|title|pr|mergeSha"
    need_sha "--merged mergeSha" "$merge_sha"
    [[ $tier_value =~ ^[012]$ ]] || fail "$EXIT_USAGE" "--merged tier must be 0, 1 or 2 (default 2, unknown, treated as highest)"
    holds --arg i "$increment_id" '.increments | any(.id == $i)' && continue
    mutate "increment $increment_id imported as merged" "workstate-import" '
        .increments += [{id: $i, title: $title, status: "merged", proposedTier: $tier, tier: $tier, branch: null,
                         pr: (if $pr == "" then null else $pr end), baseSha: null, headSha: null, mergeSha: $merge,
                         recoveries: 0, activeAt: null, readyAt: null, mergedAt: null, evidence: []}]' \
      --arg i "$increment_id" --arg title "$title" --arg pr "$pull_request" --arg merge "$merge_sha" --argjson tier "$tier_value"
  done
}

# ------------------------------------------------------------------ main
usage() {
  sed -n '2,/^# shellcheck/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit "$EXIT_USAGE"
}

if [ "${1:-}" = "--dir" ]; then
  [ $# -ge 2 ] || fail "$EXIT_USAGE" "--dir needs a directory"
  specs_directory="$2"
  shift 2
fi
[ $# -ge 1 ] || usage
command_name="$1"
shift
case "$command_name" in -h | --help | help) usage ;; esac
[ $# -ge 1 ] || fail "$EXIT_USAGE" "$command_name needs a work id (WORK-NNN)"
id="$1"
shift
[[ $id =~ ^WORK-[0-9]{1,9}$ ]] || fail "$EXIT_USAGE" "work id must look like WORK-NNN"
positional=("$id")
parse_options "$@"

if [ -z "$specs_directory" ]; then
  repository="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "$EXIT_USAGE" "not in a Git repository; pass --dir <specs-directory>"
  specs_directory="$repository/.agents/specs/active"
fi
[ -d "$specs_directory" ] || fail "$EXIT_USAGE" "specs directory $specs_directory does not exist"
specs_directory="$(cd "$specs_directory" && pwd -P)"
spec_file="$specs_directory/$id.md"
state_file="$specs_directory/$id.state.json"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# The owner-command marker is only meaningful on owner-only commands.
case "$command_name" in
  approve | deliver) ;;
  *) [ -z "$opt_owner_command" ] || fail "$EXIT_USAGE" "--owner-command is only valid on approve and deliver" ;;
esac

case "$command_name" in
  create) cmd_create ;;
  approve) cmd_approve ;;
  deliver) cmd_deliver ;;
  block) cmd_block ;;
  propose) cmd_propose ;;
  answer) cmd_answer ;;
  decision) cmd_decision ;;
  pause) cmd_pause ;;
  done) cmd_done ;;
  archive) cmd_archive ;;
  check) cmd_check ;;
  increment-add) cmd_increment_add ;;
  increment-set) cmd_increment_set ;;
  increment-recovery) cmd_increment_recovery ;;
  raise-tier) cmd_raise_tier ;;
  evidence) cmd_evidence ;;
  finding-add) cmd_finding_add ;;
  finding-fixed) cmd_finding_fixed ;;
  finding-invalid) cmd_finding_invalid ;;
  owner-action-add) cmd_owner_action_add ;;
  owner-action-done) cmd_owner_action_done ;;
  import) cmd_import ;;
  show) cmd_show ;;
  status) cmd_status ;;
  readiness) cmd_readiness ;;
  *) fail "$EXIT_USAGE" "unknown command '$command_name'" ;;
esac
