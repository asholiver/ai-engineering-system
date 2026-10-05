#!/bin/bash
# Shared helpers for ai-engineering scripts. Source this file; do not execute it.

# Prints the repository root for a directory (falls back to the directory itself).
repository_root() {
  local directory="${1:-$PWD}"
  git -C "$directory" rev-parse --show-toplevel 2>/dev/null || (cd "$directory" 2>/dev/null && pwd -P)
}

# Loads .agents/gates.json for the repository containing a directory into gates_json and
# describes where it came from in gates_source; gates_note carries any warning.
#
# The committed version at the given ref (default HEAD) is preferred, so an agent cannot
# change the commands that check its own work by editing the file in the working tree.
# When allow_working_tree is "yes" and nothing is committed (for example right after
# setup, or outside git), the working-tree file is used and flagged as uncommitted.
load_gates() {
  local directory="${1:-$PWD}" ref="${2:-HEAD}" allow_working_tree="${3:-yes}"
  local root candidate
  gates_json="" gates_source="" gates_note=""
  root="$(repository_root "$directory")"

  if [ -n "$root" ] && gates_json="$(git -C "$root" show "$ref:.agents/gates.json" 2>/dev/null)"; then
    gates_source="committed at $ref"
    if [ -f "$root/.agents/gates.json" ] && ! git -C "$root" diff --quiet "$ref" -- .agents/gates.json 2>/dev/null; then
      gates_note="uncommitted changes to .agents/gates.json were ignored"
    fi
    return 0
  fi
  gates_json=""
  [ "$allow_working_tree" = "yes" ] || return 0

  for candidate in "$root" "${CLAUDE_PROJECT_DIR:-}"; do
    if [ -n "$candidate" ] && [ -f "$candidate/.agents/gates.json" ]; then
      gates_json="$(cat "$candidate/.agents/gates.json")"
      gates_source="uncommitted working-tree file"
      gates_note="using uncommitted .agents/gates.json; commit it so agents cannot alter their own gates"
      return 0
    fi
  done
}

# Prints the command configured under a key in the loaded gates_json, or nothing when unset/null.
read_gate_command() {
  [ -n "$gates_json" ] || return 0
  jq -r --arg key "$1" '.[$key] // empty | strings' <<<"$gates_json" 2>/dev/null
}

# Succeeds when the approval guard classifies a command as a high-impact operation.
# Configured commands are not individually checked by Claude Code's permission rules:
# the opt-in hook-run fast gate runs outside them, and gates or external review invoked
# through the Bash tool are checked only as the outer script call. Either way they run
# with the user's privileges and credentials and are not an isolation boundary, so they
# must never perform operations that would otherwise need human approval.
is_high_impact_command() {
  local command_text="$1" directory="$2" script_directory decision
  script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  decision="$(jq -n --arg command "$command_text" --arg cwd "$directory" '{tool_input: {command: $command}, cwd: $cwd}' |
    "$script_directory/guard-bash.sh" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)"
  [ "$decision" = "ask" ]
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "ai-engineering: jq is required but was not found on PATH." >&2
    return 1
  fi
}
