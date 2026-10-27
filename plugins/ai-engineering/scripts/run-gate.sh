#!/bin/bash
# Runs a named quality gate (for example "fast" or "full") from .agents/gates.json
# in the repository root and prints a one-line verdict after bounded output.
#
# Gate commands come from .agents/gates.json as committed at HEAD (see load_gates in
# lib.sh). With a config ref (for example the review's base ref), the command is read
# only from that ref, so a change under review cannot define the gate that certifies it.
#
# Running a gate executes the checked-out project code with the caller's privileges.
# The config ref protects the verdict's integrity, not the host.
#
# Usage: run-gate.sh <gate-name> [working-directory] [config-ref]
# Exit codes: 0 passed, 1 failed, 3 not configured, 4 usage or environment error,
# 5 refused because the command is a high-impact operation.
set -u
script_directory="$(cd "$(dirname "$0")" && pwd)"
source "$script_directory/lib.sh"

gate_name="${1:-}"
working_directory="${2:-$PWD}"
config_ref="${3:-}"
output_line_limit="${GATE_OUTPUT_LINES:-80}"

if [ -z "$gate_name" ]; then
  echo "usage: run-gate.sh <gate-name> [working-directory] [config-ref]" >&2
  exit 4
fi
require_jq || exit 4

config_suffix=""
if [ -n "$config_ref" ]; then
  if ! git -C "$working_directory" rev-parse --verify --quiet "$config_ref^{commit}" >/dev/null; then
    echo "GATE $gate_name: ERROR (config ref $config_ref is not a commit in this repository)"
    exit 4
  fi
  load_gates "$working_directory" HEAD
  head_gate_command="$(read_gate_command "$gate_name")"
  load_gates "$working_directory" "$config_ref"
  gate_command="$(read_gate_command "$gate_name")"
  config_suffix=" [gate config: committed at $config_ref]"
  if [ "$head_gate_command" != "$gate_command" ]; then
    config_suffix=" [gate config: committed at $config_ref; THIS CHANGE MODIFIES THE \"$gate_name\" GATE - review it: ${head_gate_command:-<removed>}]"
  fi
else
  load_gates "$working_directory" HEAD
  [ -z "$gates_note" ] || echo "NOTE: $gates_note"
  gate_command="$(read_gate_command "$gate_name")"
fi

if [ -z "$gate_command" ]; then
  echo "GATE $gate_name: NOT CONFIGURED (no \"$gate_name\" command in .agents/gates.json)$config_suffix"
  exit 3
fi

repository_directory="$(repository_root "$working_directory")"
if classify_command_impact "$gate_command" "$repository_directory"; then
  echo "GATE $gate_name: REFUSED (the configured command contains a high-impact operation that needs human approval; classified $impact_decision: ${impact_classes:-unclassified}; run it manually) command: $gate_command$config_suffix"
  exit 5
fi
output_file="$(mktemp "${TMPDIR:-/tmp}/ai-engineering-gate.XXXXXX")"
trap 'rm -f "$output_file"' EXIT

# Readiness runs this script with controlled tools, the C locale and a private HOME, and passes
# the caller's PATH, HOME, locale, library paths and Perl settings for the configured command
# only (AI_ENGINEERING_COMMAND_PATH, _HOME and _SAVED_<name>); unset when run directly.
command_environment=()
if [ -n "${AI_ENGINEERING_COMMAND_PATH+set}" ]; then
  for saved_name in LC_ALL LD_LIBRARY_PATH DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_FRAMEWORK_PATH \
    DYLD_FALLBACK_FRAMEWORK_PATH PERL5LIB PERLLIB PERL5OPT; do
    saved_variable="AI_ENGINEERING_COMMAND_SAVED_$saved_name"
    if [ -n "${!saved_variable+set}" ]; then
      command_environment+=("$saved_name=${!saved_variable}")
    else
      command_environment=(-u "$saved_name" "${command_environment[@]+"${command_environment[@]}"}")
    fi
  done
fi
(
  cd "$repository_directory" &&
  PATH="${AI_ENGINEERING_COMMAND_PATH:-$PATH}" HOME="${AI_ENGINEERING_COMMAND_HOME:-${HOME-}}" \
    /usr/bin/env "${command_environment[@]+"${command_environment[@]}"}" bash -c "$gate_command"
) >"$output_file" 2>&1
exit_code=$?

total_lines=$(wc -l <"$output_file" | tr -d ' ')
if [ "$total_lines" -gt "$output_line_limit" ]; then
  echo "[... $((total_lines - output_line_limit)) earlier lines omitted ...]"
fi
tail -n "$output_line_limit" "$output_file" | cut -c1-400

if [ "$exit_code" -eq 0 ]; then
  echo "GATE $gate_name: PASSED (exit 0) command: $gate_command$config_suffix"
  exit 0
fi
echo "GATE $gate_name: FAILED (exit $exit_code) command: $gate_command$config_suffix"
exit 1
