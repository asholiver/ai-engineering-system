#!/bin/bash
# Runs the provider-neutral external independent review configured as "externalReview"
# in .agents/gates.json. See docs/external-review.md for the contract.
# The command is read from .agents/gates.json as committed at the BASE ref, so the change
# under review can never choose or alter its own reviewer.
# Usage: external-review.sh <base-ref> <head-ref> [spec-path]
# Exit codes: 0 passed, 1 blocking findings, 2 reviewer error (including a refused
# high-impact command), 3 not configured, 4 usage error.
set -u
script_directory="$(cd "$(dirname "$0")" && pwd)"
source "$script_directory/lib.sh"
output_line_limit="${REVIEW_OUTPUT_LINES:-400}"

if [ $# -lt 2 ]; then
  echo "usage: external-review.sh <base-ref> <head-ref> [spec-path]" >&2
  exit 4
fi
require_jq || exit 4

base_ref="$1"
repository_directory="$(repository_root "$PWD")"
load_gates "$PWD" HEAD no
head_review_command="$(read_gate_command externalReview)"
load_gates "$PWD" "$base_ref" no
review_command="$(read_gate_command externalReview)"

if [ -z "$review_command" ]; then
  echo "EXTERNAL REVIEW: NOT CONFIGURED"
  echo "No \"externalReview\" command in .agents/gates.json as committed at base ref $base_ref. The work must not be marked ready for final human acceptance."
  exit 3
fi
if [ "$head_review_command" != "$review_command" ]; then
  echo "NOTE: this change modifies externalReview; the command from base ref $base_ref was used."
fi
if is_high_impact_command "$review_command" "$repository_directory"; then
  echo "EXTERNAL REVIEW: ERROR (refused: the configured command contains a high-impact operation)"
  exit 2
fi
output_file="$(mktemp "${TMPDIR:-/tmp}/ai-engineering-review.XXXXXX")"
trap 'rm -f "$output_file"' EXIT

(
  cd "$repository_directory" &&
  REVIEW_BASE_REF="$1" REVIEW_HEAD_REF="$2" REVIEW_SPEC_PATH="${3:-}" bash -c "$review_command"
) >"$output_file" 2>&1
exit_code=$?

head -n "$output_line_limit" "$output_file"
total_lines=$(wc -l <"$output_file" | tr -d ' ')
if [ "$total_lines" -gt "$output_line_limit" ]; then
  echo "[... $((total_lines - output_line_limit)) further lines omitted ...]"
fi

case "$exit_code" in
  0) echo "EXTERNAL REVIEW: PASSED"; exit 0 ;;
  1) echo "EXTERNAL REVIEW: BLOCKING FINDINGS"; exit 1 ;;
  *) echo "EXTERNAL REVIEW: ERROR (reviewer exit $exit_code)"; exit 2 ;;
esac
