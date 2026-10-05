#!/bin/bash
# SubagentStop hook for implementation agents. Runs the project's fast gate in the
# agent's working directory (which follows it into a worktree). On failure it keeps the
# agent working, up to a bounded number of fix attempts, then instructs it to report
# GATE FAILED so the main session escalates.
set -u
script_directory="$(cd "$(dirname "$0")" && pwd)"
source "$script_directory/lib.sh"
maximum_fix_attempts=2

if ! require_jq; then
  # Cannot read hook input: let the agent stop, but tell the user the gate did not run.
  printf '{"systemMessage":"ai-engineering: fast gate did not run because jq is missing."}\n'
  exit 0
fi

tell_user() { jq -n --arg message "ai-engineering: $1" '{systemMessage: $message}'; }

hook_input="$(cat)"
agent_id="$(jq -r '.agent_id // "unknown"' <<<"$hook_input" | tr -c 'A-Za-z0-9_-' '_')"
agent_type="$(jq -r '.agent_type // "agent"' <<<"$hook_input")"
working_directory="$(jq -r '.cwd // empty' <<<"$hook_input")"
working_directory="${working_directory:-$PWD}"

state_directory="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}/ai-engineering}/gate-attempts"
mkdir -p "$state_directory"
attempt_file="$state_directory/$agent_id"
failures_so_far="$(cat "$attempt_file" 2>/dev/null || true)"
case "$failures_so_far" in '' | *[!0-9]*) failures_so_far=0 ;; esac

if [ "$failures_so_far" -gt "$maximum_fix_attempts" ]; then
  tell_user "fast gate still failing for $agent_type; escalation reported to the main session."
  exit 0
fi

gate_output="$("$script_directory/run-gate.sh" fast "$working_directory" 2>&1)"
gate_exit_code=$?

case "$gate_exit_code" in
  0)
    rm -f "$attempt_file"
    exit 0
    ;;
  3)
    tell_user "fast gate NOT CONFIGURED (.agents/gates.json); $agent_type finished without an automatic gate."
    exit 0
    ;;
  5)
    tell_user "fast gate REFUSED for $agent_type: the configured command contains a high-impact operation."
    exit 0
    ;;
  1) ;;
  *)
    tell_user "fast gate could not run (exit $gate_exit_code) for $agent_type."
    exit 0
    ;;
esac

failures_so_far=$((failures_so_far + 1))
echo "$failures_so_far" >"$attempt_file"

if [ "$failures_so_far" -le "$maximum_fix_attempts" ]; then
  {
    echo "The project's fast gate failed (fix attempt $failures_so_far of $maximum_fix_attempts). Fix the underlying cause; do not weaken tests or checks. Then finish again."
    echo "$gate_output" | tail -n 60
  } >&2
  exit 2
fi

{
  echo "The fast gate is still failing after $maximum_fix_attempts fix attempts. Stop fixing now."
  echo "End your final reply with the line: GATE FAILED: fast gate - <one-line cause>"
  echo "and summarise what remains so the main session can escalate."
  echo "$gate_output" | tail -n 30
} >&2
exit 2
