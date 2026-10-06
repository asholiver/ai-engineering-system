# Guard v2 decision policy. Applied after classification, as a separate step, so policy that
# needs more context (agent_type, authority store, delivery policy for deploy classes) is
# added here without touching the parser or the tables.
#
# Input: the result of parse_script ({units, uncertain}) and a context object
# {agentType, cwd, commonDir}.
# Output: {decision: "none" | "ask" | "deny", reason, classes, ops: [{operation, classes}],
#          hint: "none" | "hint" | "check", hintTargets}.
# The guard never returns "allow".
include "tables";

def guardrail_note: "Hooks are guardrails, not a sandbox.";

def describe_op: .l + " [" + (.c | join(", ")) + "]";

def compound_policy($result):
  ([ $result.units[].ops[] ]) as $ops
  # A unit with no operation of its own that does real work (anything but context setup).
  | ([ $result.units[] | select((.ops | length) == 0 and .kind == "eff") ] | length) as $other_commands
  | if ($ops | length) == 0 then {decision: "none", reason: "", classes: [], ops: []}
    else
      ([ $ops[].c[] ] | unique) as $classes
      | ($ops | map({operation: .l, classes: .c})) as $summary
      | if ($ops | length) > 1 then
          {decision: "deny", classes: $classes, ops: $summary,
           reason: ("ai-engineering guard: denied. This command contains several reserved operations ("
                    + ($ops | map(describe_op) | join("; "))
                    + "). Resubmit each one on its own, as a separate Bash call, so a human approves one operation at a time. "
                    + guardrail_note)}
        elif $other_commands > 0 then
          {decision: "deny", classes: $classes, ops: $summary,
           reason: ("ai-engineering guard: denied. " + ($ops[0] | describe_op)
                    + " was submitted together with other commands. Resubmit " + $ops[0].l
                    + " on its own, as a separate Bash call, so a human can approve that single operation. "
                    + guardrail_note)}
        else
          {decision: "ask", classes: $classes, ops: $summary,
           reason: ("ai-engineering guard: this operation needs explicit human approval: " + ($ops[0] | describe_op) + ". " + guardrail_note)}
        end
    end;

# ---------------------------------------------------------------- policy data
# Agents that never run Git write operations: the coordinator (main session) owns Git.
def git_restricted_agents: ["ai-engineering:frontend", "ai-engineering:backend", "ai-engineering:platform",
                            "ai-engineering:qa", "ai-engineering:security-reviewer", "ai-engineering:learning"];
# Agents that get the shell-edit hint.
def implementation_agents: ["ai-engineering:frontend", "ai-engineering:backend", "ai-engineering:platform"];

# Git subcommands that always write. pull, rm, mv and clean are additions to the spec list: they
# change history, the index or the working tree. checkout and switch are handled in git_write_label.
def git_write_subcommands: ["add", "commit", "push", "merge", "rebase", "reset", "restore", "cherry-pick", "revert", "am",
                            "apply", "update-ref", "gc", "prune", "pull", "rm", "mv", "clean"];
def git_worktree_writes: ["add", "remove", "move", "prune", "lock", "unlock", "repair"];
def git_branch_listing_flags: "^(--(list|contains|no-contains|merged|no-merged|points-at|sort|format|column|abbrev|show-current|all|remotes|verbose)(=.*)?|-[arlv]+)$";
def git_tag_listing_flags: "^(--(list|contains|no-contains|merged|no-merged|points-at|sort|format|column|verify)(=.*)?|-[lvn][0-9]*)$";
def git_branch_write_flags: "^(--(delete|move|copy|force|set-upstream-to|unset-upstream|edit-description|track|no-track)(=.*)?|-[A-Za-z]*[dDmMcCufqt][A-Za-z]*)$";

# Programs that can write a file given its path as an argument.
def store_interpreters_regex: "^(python[0-9.]*|pypy3?|node|nodejs|deno|bun|ruby|perl|php|lua|Rscript|tsx|ts-node|awk|gawk|mawk|osascript)$";
# Hint heuristic, deliberately simple: inline code or a heredoc given to an interpreter that
# contains a file-writing call. Script files are not read, and stdout writes are excluded.
def code_writes_file_regex:
  "write_text|write_bytes|writeFileSync|writeFile|appendFileSync|appendFile|File\\.(write|binwrite)|file_put_contents|fs\\.createWriteStream|(?<!stdout)(?<!stderr)\\.write\\(|open\\([^)]*['\"][wax][+bt]*['\"]|open\\([^)]*['\"]>";
def in_place_sed_regex: "^(-[nErsz]*i.*|--in-place(=.*)?)$";
def in_place_perl_regex: "^-[pnalwsE]*i";

def policy_positionals: map(select(startswith("-") | not));

# ---------------------------------------------------------------- Git writes by subagents
# The operation name when this Git command writes, else null. checkout and switch always count
# when given arguments: they change branch (including -b) or discard files (checkout -- file).
def git_write_label:
  .sub as $sub | .args as $args | ($args | policy_positionals) as $positional
  | if $sub == null then null
    elif ($sub | IN("checkout", "switch")) then (if ($args | length) > 0 then "git " + $sub else null end)
    elif ($sub | IN(git_write_subcommands[])) then "git " + $sub
    elif $sub == "branch" then
      (if any($args[]; test(git_branch_write_flags)) then "git branch (create, delete or rename)"
       elif ($positional | length) > 0 and (any($args[]; test(git_branch_listing_flags)) | not) then "git branch (create)"
       else null end)
    elif $sub == "tag" then
      (if ($positional | length) > 0 and (any($args[]; test(git_tag_listing_flags)) | not) then "git tag" else null end)
    elif $sub == "stash" then (if (($positional | first) // "") | IN("list", "show") then null else "git stash" end)
    elif $sub == "worktree" then (if (($positional | first) // "") | IN(git_worktree_writes[]) then "git worktree " + $positional[0] else null end)
    else null end;

def git_write_policy($cmds):
  ([ $cmds[] | select(.prog == "git") | git_write_label | select(. != null) ] | unique) as $labels
  | if ($labels | length) == 0 then null
    else {classes: ["git-write-by-subagent"], operations: $labels,
          reason: ("ai-engineering guard: denied. " + ($labels | join(", "))
                   + " is a Git write operation and the coordinator owns Git. Do not run Git write commands; leave the changes in the working tree and say in your report what should be committed. "
                   + guardrail_note)} end;

# ---------------------------------------------------------------- authority store
# Lexical normalisation: relative paths are taken from the working directory; ., .. and // collapse.
def normalize_path($cwd):
  (if startswith("/") then . else (($cwd // "") + "/" + .) end)
  | split("/")
  | reduce .[] as $segment ([]; if $segment == "" or $segment == "." then . elif $segment == ".." then .[0:-1] else . + [$segment] end)
  | "/" + join("/");

# The store is matched by its tail, not only by its repository-relative path: a command can
# `cd` first, and the parser does not track the working directory. So any path ending
# .state.json and any path through ai-engineering/tokens/ counts (a deliberate over-match).
def under_token_store($path; $common):
  ($path + "/") as $dir
  | ($dir | contains("/ai-engineering/tokens/")) or ($common != "" and ($dir | startswith($common + "/ai-engineering/tokens/")));
def is_state_file($path): $path | endswith(".state.json");
# The directories that hold the store; removing or moving them removes the store.
def is_store_ancestor($path; $common):
  ($path | test("/\\.git(/ai-engineering)?$")) or ($common != "" and ($path == $common or $path == $common + "/ai-engineering"));

def glob_regex: gsub("(?<c>[^A-Za-z0-9_])"; "\\\(.c)") | gsub("\\\\\\*"; ".*") | gsub("\\\\\\?"; ".");
# A glob in the last segment that can match a state file or anything in the token store.
def glob_hits_store($path; $common):
  ($path | split("/")) as $parts
  | ($parts[-1]) as $segment
  | (($parts[0:-1] | join("/")) + "/") as $dir
  | if ($segment | test("[*?]")) | not then false
    elif under_token_store($dir + "x"; $common) then true
    elif ($dir | contains("/.agents/specs/")) or ($segment | contains("state")) then ("WORK-1.state.json" | test("^" + ($segment | glob_regex) + "$"))
    else false end;

# The text when it names the authority store, else null. strict also counts the directories
# that hold the token store (for rm and mv).
def store_path_hit($text; $context; $strict):
  ($text | normalize_path($context.cwd)) as $path
  | ($context.commonDir // "") as $common
  | if is_state_file($path) or under_token_store($path; $common) then $text
    elif $strict and is_store_ancestor($path; $common) then $text
    elif glob_hits_store($path; $common) then $text
    else null end;

def write_redirect_targets:
  [ .redirs[] | select(.op | IN(">", ">>", ">|", "&>", "&>>", "<>", ">&"))
    | select((.op == ">&" and (.t | test("^[0-9-]+$"))) | not) | .t ];

def option_values($args; $short; $long):
  [ range(0; $args | length) as $i
    | if $args[$i] == $short or $args[$i] == $long then ($args[$i + 1] // empty)
      elif ($args[$i] | startswith($long + "=")) then ($args[$i] | sub("^[^=]*="; ""))
      else empty end ];

# Paths a command writes: {t: path text, strict}. Reads (cat, jq, grep, less, cp sources) are not listed.
def command_write_targets:
  .prog as $prog | .args as $args | ($args | policy_positionals) as $positional
  | [ (write_redirect_targets[] | {t: ., strict: false}),
      (if $prog == "tee" or $prog == "truncate" or $prog == "touch" or $prog == "shred" or $prog == "ln" then $positional[] | {t: ., strict: false}
       elif $prog == "rm" or $prog == "unlink" or $prog == "mv" then $positional[] | {t: ., strict: true}
       elif $prog | IN("cp", "install", "rsync") then
         ((($positional | last) // empty), option_values($args; "-t"; "--target-directory")[]) | {t: ., strict: false}
       elif $prog == "dd" then $args[] | select(startswith("of=")) | {t: .[3:], strict: false}
       elif $prog == "sed" and any($args[]; test(in_place_sed_regex)) then $positional[] | {t: ., strict: false}
       elif $prog == "perl" and any($args[]; test(in_place_perl_regex)) then $positional[] | {t: ., strict: false}
       else empty end) ];

# An interpreter given the store in its arguments or heredoc can write there in ways no parser
# can follow, so it is refused (this also refuses reads through an interpreter).
def interpreter_mentions_store:
  (.prog != null and (.prog | test(store_interpreters_regex)))
  and (([ .args[], .stdin[] ] | join("\n")) | test("\\.state\\.json|ai-engineering/tokens"));

def authority_store_policy($cmds; $context):
  ([ $cmds[] | . as $command
     | ((command_write_targets[] | store_path_hit(.t; $context; .strict) | select(. != null)),
        (if ($command | interpreter_mentions_store) then ($command.prog + " given the authority store") else empty end)) ]) as $hits
  | if ($hits | length) == 0 then null
    else {classes: ["authority-store-write"], operations: [$hits[0]],
          reason: ("ai-engineering guard: denied. Writing to " + $hits[0]
                   + " is not allowed: the authority store (.agents/specs/**/*.state.json and the token store under the Git common directory) is written only by the plugin's transition script. "
                   + guardrail_note)} end;

# ---------------------------------------------------------------- shell-edit hint
# "hint" (certain), "check" (redirection targets the wrapper must test against `git ls-files`:
# a redirection counts only when it overwrites an existing tracked file) or "none".
def shell_edit_hint($cmds):
  ([ $cmds[]
     | select((.prog == "sed" and any(.args[]; test(in_place_sed_regex)))
              or (.prog == "perl" and any(.args[]; test(in_place_perl_regex)))
              or (.prog != null and (.prog | test(interpreters_regex)) and (([ .args[], .stdin[] ] | join("\n")) | test(code_writes_file_regex)))) ] | length) as $direct
  | if $direct > 0 then {hint: "hint", targets: []}
    else
      ([ $cmds[] | write_redirect_targets[] | select(test("^/dev/|^/tmp/|^/private/tmp/|^/var/folders/") | not) ] | unique) as $targets
      | if ($targets | length) > 0 then {hint: "check", targets: $targets[0:20]} else {hint: "none", targets: []} end
    end;

# ---------------------------------------------------------------- decision
# Deny from the agent and authority policies wins over the reserved-operation policy; a hint
# is added only when there is no decision at all.
def decide($result; $context):
  compound_policy($result) as $compound
  | ([ $result.units[].cmds[] ]) as $cmds
  | ($context.agentType // "") as $agent
  | ([ authority_store_policy($cmds; $context),
       (if $agent | IN(git_restricted_agents[]) then git_write_policy($cmds) else null end) ] | map(select(. != null))) as $denials
  | if ($denials | length) > 0 then
      {decision: "deny", reason: ($denials | map(.reason) | join(" ")),
       classes: ([ $denials[].classes[] ] + $compound.classes | unique),
       ops: ($compound.ops + [ $denials[].operations[] | {operation: ., classes: []} ]), hint: "none", hintTargets: []}
    elif $compound.decision == "none" and ($agent | IN(implementation_agents[])) then
      shell_edit_hint($cmds) as $edit
      | $compound + {hint: $edit.hint, hintTargets: $edit.targets}
    else $compound + {hint: "none", hintTargets: []} end;
