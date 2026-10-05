#!/bin/bash
# Runs a named quality gate (for example "fast" or "full") from .agents/gates.json
# in the repository root and prints a one-line verdict after bounded output.
# Gate commands come from the committed .agents/gates.json (see load_gates in lib.sh).
# Exit codes: 0 passed, 1 failed, 3 not configured, 4 usage or environment error,
# 5 refused because the command is a high-impact operation.
set -u
script_directory="$(cd "$(dirname "$0")" && pwd)"
source "$script_directory/lib.sh"

gate_name="${1:-}"
working_directory="${2:-$PWD}"
output_line_limit="${GATE_OUTPUT_LINES:-80}"

if [ -z "$gate_name" ]; then
  echo "usage: run-gate.sh <gate-name> [working-directory]" >&2
  exit 4
fi
require_jq || exit 4

load_gates "$working_directory" HEAD yes
[ -z "$gates_note" ] || echo "NOTE: $gates_note"
gate_command="$(read_gate_command "$gate_name")"
if [ -z "$gate_command" ]; then
  echo "GATE $gate_name: NOT CONFIGURED (no \"$gate_name\" command in .agents/gates.json)"
  exit 3
fi

repository_directory="$(repository_root "$working_directory")"
if is_high_impact_command "$gate_command" "$repository_directory"; then
  echo "GATE $gate_name: REFUSED (the configured command contains a high-impact operation that needs human approval; run it manually) command: $gate_command"
  exit 5
fi
output_file="$(mktemp "${TMPDIR:-/tmp}/ai-engineering-gate.XXXXXX")"
trap 'rm -f "$output_file"' EXIT

(cd "$repository_directory" && bash -c "$gate_command") >"$output_file" 2>&1
exit_code=$?

total_lines=$(wc -l <"$output_file" | tr -d ' ')
if [ "$total_lines" -gt "$output_line_limit" ]; then
  echo "[... $((total_lines - output_line_limit)) earlier lines omitted ...]"
fi
tail -n "$output_line_limit" "$output_file" | cut -c1-400

if [ "$exit_code" -eq 0 ]; then
  echo "GATE $gate_name: PASSED (exit 0) command: $gate_command"
  exit 0
fi
echo "GATE $gate_name: FAILED (exit $exit_code) command: $gate_command"
exit 1
