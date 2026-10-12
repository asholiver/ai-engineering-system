# Entry point for guard-bash.sh run_fallback_git_check: the keyword fallback for git-restricted
# agents (RR3-3 owner ruling; the rules are fallback_git_check in classify.jq). Input: the
# PreToolUse hook JSON. Output: two lines, the verdict (deny | ask | ok) and, for deny only, the
# label "git <subcommand>". It never decides for any other caller.
include "policy";

(.tool_input.command // "" | if type == "string" then . else "" end) as $command
| guard_fallback_git($command) as $result
| $result.verdict, ($result.label // "")
