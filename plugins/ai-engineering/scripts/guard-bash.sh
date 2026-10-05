#!/bin/bash
# PreToolUse hook for Bash. Requires explicit human approval ("ask") for high-impact
# operations, classified by intent rather than by exact command strings.
#
# This is a guardrail, not a security sandbox: it only sees the command text Claude
# submits. Indirection (scripts, aliases, variables, encoded strings) can evade it.
# It errs towards asking: a false positive costs one confirmation.
set -u

ask() {
  local reason="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg reason "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $reason}}'
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$reason"
  fi
  exit 0
}

if ! command -v jq >/dev/null 2>&1; then
  ask "ai-engineering guard: jq is missing, so this command cannot be inspected. Approve only if it is not a high-impact operation."
fi

hook_input="$(cat)"
command_text="$(jq -r '.tool_input.command // empty' <<<"$hook_input" | tr '\n\t' '  ')"
working_directory="$(jq -r '.cwd // empty' <<<"$hook_input")"
[ -n "$command_text" ] || exit 0

# Token boundaries. A word starts after start-of-text or a non-word character and ends
# before a non-word character or end-of-text. "Argument" boundaries require whitespace,
# so flags such as "-destroy" or "--delete" are not mistaken for subcommands.
word_start='(^|[^[:alnum:]_-])'
word_end='([^[:alnum:]_-]|$)'
argument_start='(^|[[:space:]])'
# A tool name followed, possibly after other arguments, by the given argument.
then_argument='[[:space:]]+(.*[[:space:]]+)?'

matched_intents=()
matches() { grep -Eiq -- "$1" <<<"$command_text"; }
flag() { matched_intents+=("$1"); }

# Provision, change or destroy infrastructure.
matches "${word_start}(terraform|tofu|terragrunt)${then_argument}(apply|destroy)${word_end}" && flag "infrastructure apply/destroy"
matches "${word_start}pulumi${then_argument}(up|destroy)${word_end}" && flag "infrastructure apply/destroy (pulumi)"
matches "${word_start}(cdk|cdktf|aws-cdk)${then_argument}(deploy|destroy)${word_end}" && flag "infrastructure deploy/destroy (cdk)"
matches "${word_start}(serverless|sls|sam)${then_argument}(deploy|remove|delete)${word_end}" && flag "serverless deploy/remove"

# Delete workloads or cloud resources.
matches "${word_start}(kubectl|oc)${then_argument}(delete|drain)${word_end}" && flag "kubernetes delete/drain"
matches "${word_start}helm${then_argument}(uninstall|delete)${word_end}" && flag "helm uninstall"
matches "${word_start}(aws|gcloud|az|gsutil)${then_argument}(rm|rb|[[:alnum:]-]*(delete|terminate|destroy|purge|remove|deregister)[[:alnum:]-]*)${word_end}" && flag "destructive cloud operation"
matches "${word_start}aws${then_argument}sync${word_end}.*--delete" && flag "destructive cloud sync (--delete)"

# Destroy data.
matches "${word_start}drop[[:space:]]+(table|database|schema|view|index|user|role|function|procedure)${word_end}" && flag "SQL DROP"
matches "${word_start}truncate${word_end}" && flag "SQL TRUNCATE / truncate"

# Rewrite or delete shared history, or push directly to protected branches.
if matches "${word_start}git${then_argument}push${word_end}"; then
  matches "${argument_start}(--force|--force-with-lease(=[^[:space:]]*)?|--mirror|--delete|-[[:alpha:]]*[fd][[:alpha:]]*)${word_end}" && flag "git force push / remote delete"
  matches "${argument_start}(\+|:)[^[:space:]]+" && flag "git force push / remote delete (refspec)"
  matches "${argument_start}([^[:space:]]*:)?(refs/heads/)?(main|master)${word_end}" && flag "push to main/master"
  matches "${argument_start}(--tags|[^[:space:]]*refs/tags/[^[:space:]]*)${word_end}" && flag "tag push (release trigger)"
  current_branch="$(git -C "${working_directory:-$PWD}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  case "$current_branch" in
    main | master) flag "push while on $current_branch" ;;
  esac
fi

# Merge pull requests, create releases, publish packages or images.
matches "${word_start}gh${then_argument}pr[[:space:]]+merge${word_end}" && flag "PR merge"
matches "${word_start}glab${then_argument}mr[[:space:]]+merge${word_end}" && flag "MR merge"
matches "${word_start}gh${then_argument}api${word_end}.*pulls/[0-9]+/merge" && flag "PR merge (API)"
matches "${word_start}(gh|glab)${then_argument}release[[:space:]]+create${word_end}" && flag "release creation"
matches "${word_start}(npm|pnpm|yarn|bun)${then_argument}publish${word_end}" && flag "package publish"
matches "${word_start}(cargo|poetry|flit|hatch)${then_argument}publish${word_end}" && flag "package publish"
matches "${word_start}twine${then_argument}upload${word_end}" && flag "package publish"
matches "${word_start}(gem|nuget)${then_argument}push${word_end}" && flag "package publish"
matches "${word_start}(docker|podman)${then_argument}push${word_end}" && flag "image publish"

# Deployment or release intent hidden behind task runners and scripts.
risky_task='[^[:space:]]*(deploy|release|publish|destroy|teardown)[^[:space:]]*'
matches "${word_start}(npm|pnpm|yarn|bun)${then_argument}${risky_task}" && flag "deploy/release task"
matches "${word_start}(make|just|task|mage)${then_argument}${risky_task}" && flag "deploy/release task"
matches "${argument_start}[^[:space:]]*/[^[:space:]/]*(deploy|release|publish|destroy|teardown)[^[:space:]/]*" && flag "deploy/release script"

[ "${#matched_intents[@]}" -gt 0 ] || exit 0

intent_list="$(printf '%s, ' "${matched_intents[@]}")"
ask "ai-engineering guard: high-impact operation needs explicit human approval (${intent_list%, }). Hooks are guardrails, not a sandbox."
