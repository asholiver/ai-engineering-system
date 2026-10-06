#!/bin/bash
# PreToolUse hook for Write/Edit/NotebookEdit.
# 1. For every caller: deny writes to the authority store, which is written only by the
#    plugin's transition script: .agents/specs/**/*.state.json and the token store under the
#    Git common directory (<git-common-dir>/ai-engineering/tokens/).
# 2. The learning agent may only write inside the repository's .agents/ directory.
# Other callers are not otherwise affected.
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
working_directory="$(jq -r '.cwd // empty' <<<"$hook_input")"
working_directory="${working_directory:-$PWD}"
target_path="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$hook_input")"
if [ -z "$target_path" ]; then
  [ "$agent_type" = "$learning_agent_type" ] && deny "ai-engineering guard: learning agent write without a file path."
  exit 0
fi

case "$target_path" in
  /*) ;;
  *) target_path="$working_directory/$target_path" ;;
esac

if [ "$agent_type" = "$learning_agent_type" ]; then
  case "$target_path" in
    */../* | */.. | */./* ) deny "ai-engineering guard: learning agent paths must not contain relative segments ($target_path)." ;;
  esac
fi

# Collapses ., .. and // lexically (the existing part of a path is resolved physically before this).
collapse_path() {
  local segment result="" old_ifs="$IFS"
  IFS=/
  for segment in $1; do
    case "$segment" in
      "" | .) ;;
      ..) result="${result%/*}" ;;
      *) result="$result/$segment" ;;
    esac
  done
  IFS="$old_ifs"
  printf '%s' "${result:-/}"
}

# Follows a symbolic link at the end of the path (bounded), then resolves the deepest existing
# ancestor physically so linked ancestors (and /tmp vs /private/tmp) compare equal.
resolve_path() {
  local path="$1" hops=0 link
  while [ -L "$path" ] && [ "$hops" -lt 10 ]; do
    link="$(readlink "$path")" || break
    case "$link" in /*) path="$link" ;; *) path="$(dirname "$path")/$link" ;; esac
    hops=$((hops + 1))
  done
  local ancestor remainder
  ancestor="$(dirname "$path")"
  remainder="$(basename "$path")"
  while [ ! -d "$ancestor" ] && [ "$ancestor" != "/" ] && [ "$ancestor" != "." ]; do
    remainder="$(basename "$ancestor")/$remainder"
    ancestor="$(dirname "$ancestor")"
  done
  collapse_path "$(cd -P "$ancestor" 2>/dev/null && pwd -P)/$remainder"
}

resolved_path="$(resolve_path "$target_path")"

# ---------------------------------------------------------------- authority store
authority_store_reason="ai-engineering guard: writes to the authority store (.agents/specs/**/*.state.json and the token store under the Git common directory) are not allowed from any caller; it is written only by the plugin's transition script (attempted: $target_path)."
case "$resolved_path" in
  */.agents/specs/*.state.json) deny "$authority_store_reason" ;;
  */.git/ai-engineering/tokens | */.git/ai-engineering/tokens/*) deny "$authority_store_reason" ;;
  */ai-engineering/tokens | */ai-engineering/tokens/*)
    # A common directory not named .git (separate git dir, bare repository): ask Git for it.
    common_directory="$(git -C "$working_directory" rev-parse --git-common-dir 2>/dev/null)"
    if [ -n "$common_directory" ]; then
      case "$common_directory" in /*) ;; *) common_directory="$working_directory/$common_directory" ;; esac
      common_directory="$(cd -P "$common_directory" 2>/dev/null && pwd -P)"
      case "$resolved_path" in
        "$common_directory/ai-engineering/tokens" | "$common_directory/ai-engineering/tokens/"*) deny "$authority_store_reason" ;;
      esac
    fi
    ;;
esac

# ---------------------------------------------------------------- learning agent
[ "$agent_type" = "$learning_agent_type" ] || exit 0

repository_directory="$(git -C "$working_directory" rev-parse --show-toplevel 2>/dev/null || echo "$working_directory")"
repository_directory="$(cd "$repository_directory" 2>/dev/null && pwd -P)"
case "$resolved_path" in
  "$repository_directory/.agents/"*) exit 0 ;;
esac
deny "ai-engineering guard: the learning agent may only write inside .agents/ (attempted: $target_path). Shared guardrails change only through a reviewed PR to the ai-engineering system."
