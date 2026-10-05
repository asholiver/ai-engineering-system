#!/bin/bash
# PreToolUse hook for Write/Edit/NotebookEdit. The learning agent may only write inside
# the repository's .agents/ directory. Other callers are not affected.
set -u
learning_agent_type="ai-engineering:learning"

deny() {
  jq -n --arg reason "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
}

if ! command -v jq >/dev/null 2>&1; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"ai-engineering guard: jq is missing, so file writes cannot be checked."}}\n'
  exit 0
fi

hook_input="$(cat)"
agent_type="$(jq -r '.agent_type // empty' <<<"$hook_input")"
[ "$agent_type" = "$learning_agent_type" ] || exit 0

working_directory="$(jq -r '.cwd // empty' <<<"$hook_input")"
target_path="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$hook_input")"
[ -n "$target_path" ] || deny "ai-engineering guard: learning agent write without a file path."

repository_directory="$(git -C "${working_directory:-$PWD}" rev-parse --show-toplevel 2>/dev/null || echo "${working_directory:-$PWD}")"
repository_directory="$(cd "$repository_directory" 2>/dev/null && pwd -P)"
case "$target_path" in
  /*) ;;
  *) target_path="${working_directory:-$PWD}/$target_path" ;;
esac

case "$target_path" in
  */../* | */.. | */./* ) deny "ai-engineering guard: learning agent paths must not contain relative segments ($target_path)." ;;
esac

# Resolve the deepest existing ancestor physically so /tmp and /private/tmp style links compare equal.
existing_ancestor="$(dirname "$target_path")"
remainder="$(basename "$target_path")"
while [ ! -d "$existing_ancestor" ]; do
  remainder="$(basename "$existing_ancestor")/$remainder"
  existing_ancestor="$(dirname "$existing_ancestor")"
done
resolved_path="$(cd "$existing_ancestor" && pwd -P)/$remainder"

case "$resolved_path" in
  "$repository_directory/.agents/"*) exit 0 ;;
esac
deny "ai-engineering guard: the learning agent may only write inside .agents/ (attempted: $target_path). Shared guardrails change only through a reviewed PR to the ai-engineering system."
