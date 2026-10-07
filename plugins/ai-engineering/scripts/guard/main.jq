# Entry point for guard-bash.sh. Reads the PreToolUse hook JSON and emits seven lines:
#   decision (none | ask | deny | fallback), parse mode, classes (comma separated),
#   the hook output JSON ("" when there is no decision), the shell-edit hint state
#   (none | hint | check), a JSON array of redirection targets for "check", and
#   needBranch ("1" when a push was found and the branch was not looked up).
# "fallback" asks the wrapper to apply the v0.2 keyword rules (parse not confident).
# Named arguments: --arg branch (current Git branch, "" when unknown), --arg branchLoaded
# ("1" when the branch was looked up) and --arg commonDir (resolved Git common directory,
# "" when not looked up).
include "classify";
include "policy";

def hook_output($decision; $reason):
  {hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $decision, permissionDecisionReason: $reason}} | tojson;

def parse_budget_bytes: 262144;

. as $input
| ($input.tool_input.command // "") as $command
| ($command | if type == "string" then . else "" end) as $text
| (if $text == "" then {decision: "none", parseMode: "none", classes: [], output: ""}
   # The budget is in bytes: multi-byte text must not slip under a character count.
   elif ($text | utf8bytelength) > parse_budget_bytes then {decision: "fallback", parseMode: "fallback", classes: [], output: ""}
   else
     (try parse_script($text; 0; $branch) catch {uncertain: true, units: []}) as $parsed
     | if $parsed.uncertain then {decision: "fallback", parseMode: "fallback", classes: [], output: "", hint: "none", targets: []}
       else
         decide($parsed; {agentType: ($input.agent_type // null), cwd: ($input.cwd // ""), commonDir: $commonDir}) as $verdict
         # The current branch matters only for pushes. When it was not looked up and the parse found a
         # push (however it was spelled), the wrapper looks it up and runs this again.
         | (($branchLoaded != "1") and (any($parsed.units[].cmds[]; .prog == "git" and .sub == "push"))) as $needBranch
         | {decision: $verdict.decision, parseMode: "parsed", classes: $verdict.classes,
            output: (if $verdict.decision == "none" then "" else hook_output($verdict.decision; $verdict.reason) end),
            hint: $verdict.hint, targets: $verdict.hintTargets, needBranch: $needBranch}
       end
   end)
| .decision, .parseMode, (.classes | join(",")), .output, (.hint // "none"), ((.targets // []) | tojson), (if .needBranch then "1" else "0" end)
