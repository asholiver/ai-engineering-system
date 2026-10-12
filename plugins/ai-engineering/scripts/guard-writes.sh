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
# The only Git this hook runs (RR3-1): the hardened plumbing in guard/hook-git.sh.
# shellcheck source=guard/hook-git.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/guard/hook-git.sh"
hook_git_output_file="$(mktemp "${TMPDIR:-/tmp}/ai-engineering-guard-writes.XXXXXX" 2>/dev/null)" || hook_git_output_file=""
trap '[ -z "$hook_git_output_file" ] || rm -f "$hook_git_output_file"' EXIT
# Prints the output of one hardened Git lookup (nothing when it fails).
git_lookup() { "$@" && printf '%s' "$hook_git_output"; }
# NF-3: a store check whose Git lookup failed inside a work tree, or that the hook environment
# redirects (GIT_DIR and similar), asks instead of passing.
ask_unverified() {
  jq -n --arg reason "ai-engineering guard: this write could not be checked against the authority store because a Git lookup failed or the hook environment sets Git variables (attempted: $1). It needs explicit human approval." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $reason}}'
  exit 0
}
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
# Compared in lower case: a case-insensitive file system resolves .STATE.JSON and .Agents/Specs.
lowered_path="$(printf '%s' "$resolved_path" | tr '[:upper:]' '[:lower:]')"
case "$lowered_path" in
  */.agents/specs/*.state.json) deny "$authority_store_reason" ;;
  */.git/ai-engineering/tokens | */.git/ai-engineering/tokens/*) deny "$authority_store_reason" ;;
  */ai-engineering/tokens | */ai-engineering/tokens/*)
    # A common directory not named .git (separate git dir, bare repository): ask Git for it.
    common_directory="$(git_lookup hook_git_common_directory "$working_directory")"
    if [ -n "$common_directory" ]; then
      case "$common_directory" in /*) ;; *) common_directory="$working_directory/$common_directory" ;; esac
      common_directory="$(cd -P "$common_directory" 2>/dev/null && pwd -P | tr '[:upper:]' '[:lower:]')"
      case "$lowered_path" in
        "$common_directory/ai-engineering/tokens" | "$common_directory/ai-engineering/tokens/"*) deny "$authority_store_reason" ;;
      esac
    fi
    if hook_git_environment_overrides || { [ -z "$common_directory" ] && hook_git_in_work_tree "$working_directory"; }; then
      ask_unverified "$target_path"
    fi
    ;;
esac

# ---------------------------------------------------------------- hard links (N5)
# A hard link to a store file is that file under another name. Deny a write to an existing file
# with more than one link when a file in this repository's store is the same file.
repository_top="$(git_lookup hook_git_top_level "$working_directory")"
store_common_directory="$(git_lookup hook_git_common_directory "$working_directory")"
if [ -n "$store_common_directory" ]; then
  case "$store_common_directory" in /*) ;; *) store_common_directory="$working_directory/$store_common_directory" ;; esac
fi
link_count() { stat -c %h "$1" 2>/dev/null || stat -f %l "$1" 2>/dev/null; }
if [ -f "$resolved_path" ] && [ "$(link_count "$resolved_path")" -gt 1 ] 2>/dev/null; then
  if hook_git_environment_overrides || { { [ -z "$repository_top" ] || [ -z "$store_common_directory" ]; } && hook_git_in_work_tree "$working_directory"; }; then
    ask_unverified "$target_path"
  fi
  for store_directory in "${repository_top:+$repository_top/.agents/specs}" "${store_common_directory:+$store_common_directory/ai-engineering/tokens}"; do
    [ -n "$store_directory" ] && [ -d "$store_directory" ] || continue
    if [ -n "$(find "$store_directory" -maxdepth 8 -type f -samefile "$resolved_path" -print 2>/dev/null | head -n 1)" ]; then
      deny "$authority_store_reason (the target is a hard link to a store file)"
    fi
  done
fi

# ---------------------------------------------------------------- look-alike names (N6)
# APFS folds case with full Unicode case folding, so U+017F (long s) opens "s", U+212A (Kelvin
# sign) opens "k" and ligatures open "st" or "fi". A target with any non-ASCII character is
# checked with each such character as a wildcard: denied when its components could be
# .agents/specs/.../*.state.json or ai-engineering/tokens (and, for subagents, Git's own files).
component_matches() { [[ "$1" == $2 ]]; }
could_end_with() {
  local pattern="$1" suffix="$2" tail
  case "$pattern" in
    *'*'*) tail="${pattern##*\*}"; [[ "$suffix" == *"$tail" ]] || [[ "$tail" == *"$suffix" ]] ;;
    *) [[ "$pattern" == *"$suffix" ]] ;;
  esac
}
look_alike_reaches() {
  local pattern="$1" restricted="$2" old_ifs="$IFS" index count
  local -a parts
  IFS=/
  read -r -a parts <<<"$pattern"
  IFS="$old_ifs"
  count="${#parts[@]}"
  for ((index = 0; index + 1 < count; index++)); do
    if component_matches .agents "${parts[index]}" && component_matches specs "${parts[index + 1]}" && could_end_with "${parts[count - 1]}" .state.json; then return 0; fi
    if component_matches ai-engineering "${parts[index]}" && component_matches tokens "${parts[index + 1]}"; then return 0; fi
    if [ "$restricted" = 1 ] && component_matches .git "${parts[index]}"; then
      case "${parts[index + 1]}" in *'*'* | hooks | info | config) return 0 ;; esac
    fi
  done
  return 1
}
if [ -n "$(printf '%s' "$target_path$resolved_path" | LC_ALL=C tr -d '\000-\177')" ]; then
  restricted_writer=0
  case "$agent_type" in ai-engineering:frontend | ai-engineering:backend | ai-engineering:platform | ai-engineering:qa | ai-engineering:security-reviewer | ai-engineering:learning) restricted_writer=1 ;; esac
  for candidate in "$resolved_path" "$target_path"; do
    look_alike="$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]' | LC_ALL=C tr '\200-\377' '*')"
    if look_alike_reaches "$look_alike" "$restricted_writer"; then
      deny "ai-engineering guard: the path has non-ASCII characters that the file system may fold into the authority store (.agents/specs/**/*.state.json, the token store) or, for subagents, Git's own files; use the plain ASCII name (attempted: $target_path)."
    fi
  done
fi

# ---------------------------------------------------------------- Git's own files
# Subagents may not write Git hooks, configuration or info files (they run code or change how
# the coordinator's Git behaves). The coordinator and other callers are not affected.
case "$agent_type" in
  ai-engineering:frontend | ai-engineering:backend | ai-engineering:platform | ai-engineering:qa | ai-engineering:security-reviewer | ai-engineering:learning)
    case "$lowered_path" in
      */.git/hooks | */.git/hooks/* | */.git/info | */.git/info/* | */.git/config)
        deny "ai-engineering guard: subagents may not write Git hooks, configuration or info files; the coordinator owns Git (attempted: $target_path)."
        ;;
    esac
    ;;
esac

# ---------------------------------------------------------------- learning agent
[ "$agent_type" = "$learning_agent_type" ] || exit 0

repository_directory="$(git_lookup hook_git_top_level "$working_directory" || echo "$working_directory")"
repository_directory="$(cd "$repository_directory" 2>/dev/null && pwd -P)"
case "$resolved_path" in
  "$repository_directory/.agents/"*) exit 0 ;;
esac
deny "ai-engineering guard: the learning agent may only write inside .agents/ (attempted: $target_path). Shared guardrails change only through a reviewed PR to the ai-engineering system."
