# Entry point for guard-bash.sh. Reads the PreToolUse hook JSON and emits four lines:
#   decision (none | ask | deny | fallback), parse mode, classes (comma separated),
#   and the hook output JSON ("" when there is no decision).
# "fallback" asks the wrapper to apply the v0.2 keyword rules (parse not confident).
# Named arguments: --arg branch (current Git branch, "" when unknown).
include "classify";
include "policy";

def hook_output($decision; $reason):
  {hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $decision, permissionDecisionReason: $reason}} | tojson;

def parse_budget_characters: 262144;

. as $input
| ($input.tool_input.command // "") as $command
| ($command | if type == "string" then . else "" end) as $text
| (if $text == "" then {decision: "none", parseMode: "none", classes: [], output: ""}
   elif ($text | length) > parse_budget_characters then {decision: "fallback", parseMode: "fallback", classes: [], output: ""}
   else
     (try parse_script($text; 0; $branch) catch {uncertain: true, units: []}) as $parsed
     | if $parsed.uncertain then {decision: "fallback", parseMode: "fallback", classes: [], output: ""}
       else
         decide($parsed; {agentType: ($input.agent_type // null)}) as $verdict
         | {decision: $verdict.decision, parseMode: "parsed", classes: $verdict.classes,
            output: (if $verdict.decision == "none" then "" else hook_output($verdict.decision; $verdict.reason) end)}
       end
   end)
| .decision, .parseMode, (.classes | join(",")), .output
