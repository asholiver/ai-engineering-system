# Entry point for guard-bash.sh. Reads the PreToolUse hook JSON and emits eight lines:
#   decision (none | ask | deny | fallback | floor), parse mode, classes (comma separated),
#   the hook output JSON ("" when there is no decision), the shell-edit hint state
#   (none | hint | check), a JSON array of redirection targets for "check", needBranch ("1"
#   when a push was found and the branch was not looked up) and the floor text (one line).
# "fallback" asks the wrapper to apply the v0.2 keyword rules to the whole command (parse not
# confident). "floor" means the parse found no decision but its floor text was too large to scan
# here: the wrapper applies the same keyword rules to the floor text (linear grep) and asks on a hit.
# Named arguments: --arg branch (current Git branch, "" when unknown), --arg branchLoaded
# ("1" when the branch was looked up), --arg commonDir (resolved Git common directory,
# "" when not looked up), --arg rootCdup and --arg rootKnown (git rev-parse --show-cdup from
# the working directory, and "1" when it was looked up; otherwise the working directory stands
# in for the repository root, which only over-asks for whole-tree writers).
# Only policy.jq is included: it includes classify.jq (and through it lexer.jq and tables.jq) and
# exposes the entry points used here, so each module is compiled once per run.
include "policy";

def hook_output($decision; $reason):
  {hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $decision, permissionDecisionReason: $reason}} | tojson;

def parse_budget_bytes: 262144;
# Floor text scanned here; above this the wrapper scans it (the regexes backtrack on long text).
def floor_budget_bytes: 16384;

. as $input
| ($input.tool_input.command // "") as $command
| ($command | if type == "string" then . else "" end) as $text
| (if $text == "" then {decision: "none", parseMode: "none", classes: [], output: ""}
   # The budget is in bytes: multi-byte text must not slip under a character count.
   elif ($text | utf8bytelength) > parse_budget_bytes then {decision: "fallback", parseMode: "fallback", classes: [], output: ""}
   else
     (try guard_parse($text; $branch) catch {uncertain: true, units: []}) as $parsed
     | if $parsed.uncertain then {decision: "fallback", parseMode: "fallback", classes: [], output: "", hint: "none", targets: []}
       else
         guard_floor_text($parsed) as $floor_text
         | (($floor_text | utf8bytelength) > floor_budget_bytes) as $floor_deferred
         | (if $floor_deferred then [] else floor_classes($floor_text; $branch) end) as $floor
         # The repository root, spelled from the working directory (git rev-parse --show-cdup), or "" when unknown.
         | (if $rootKnown == "1" then ($rootCdup | normalize_path($input.cwd // "")) else "" end) as $root
         | decide($parsed; {agentType: ($input.agent_type // null), cwd: ($input.cwd // ""), commonDir: $commonDir, floor: $floor, root: $root}) as $verdict
         # The current branch matters only for pushes. When it was not looked up and the parse or the
         # floor text found a push (however it was spelled), the wrapper looks it up and runs this again.
         | (($branchLoaded != "1")
            and (any($parsed.units[].cmds[]; .prog == "git" and .sub == "push")
                 or (if $floor_deferred then guard_push_mentioned($floor_text)
                     else floor_mentions_push($floor_text) end))) as $needBranch
         # Soft uncertainty (classify.jq): the parse is sound, so a decision it reaches stands; with no
         # decision, something it would run is unknown and the fallback reads the whole command.
         | if ($parsed.soft // false) and $verdict.decision == "none" then
             {decision: "fallback", parseMode: "fallback", classes: [], output: "", hint: "none", targets: [], needBranch: $needBranch}
           else
             {decision: (if $floor_deferred and $verdict.decision == "none" then "floor" else $verdict.decision end),
              parseMode: "parsed", classes: $verdict.classes,
              output: (if $verdict.decision == "none" then "" else hook_output($verdict.decision; $verdict.reason) end),
              hint: $verdict.hint, targets: $verdict.hintTargets, needBranch: $needBranch,
              floorText: (if $floor_deferred and $verdict.decision == "none" then $floor_text else "" end)}
           end
       end
   end)
| .decision, .parseMode, (.classes | join(",")), .output, (.hint // "none"), ((.targets // []) | tojson), (if .needBranch then "1" else "0" end),
  (.floorText // "")
