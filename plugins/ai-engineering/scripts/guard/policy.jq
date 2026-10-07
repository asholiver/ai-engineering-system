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
include "classify";

def guardrail_note: "Hooks are guardrails, not a sandbox.";

def describe_op: .l + " [" + (.c | join(", ")) + "]";

def compound_policy($result):
  ([ $result.units[].ops[] ]) as $ops
  # Effectful commands that carry no operation of their own (context setup does not count).
  | ([ $result.units[].others ] | add // 0) as $other_commands
  # Commands of programs the tables do not know whose words look like a reserved operation (ask only).
  | ([ $result.units[].net[] ] | unique) as $net
  | if ($ops | length) == 0 then
      if ($net | length) > 0 then
        {decision: "ask", classes: $net, ops: [{operation: "unrecognised command", classes: $net}],
         reason: ("ai-engineering guard: this command runs a program the guard does not know, and its words look like a reserved operation (class: "
                  + ($net | join(", ")) + "). It needs explicit human approval. " + guardrail_note)}
      else {decision: "none", reason: "", classes: [], ops: []} end
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

# Git subcommands a restricted agent may run (an allow-list: everything else is denied).
# branch, tag, stash, worktree, remote and config are allowed in their pure read forms only
# (see git_read_form). version and help change nothing.
def git_read_subcommands: ["status", "diff", "log", "show", "blame", "grep", "ls-files", "ls-tree", "cat-file", "rev-parse", "rev-list",
                           "merge-base", "describe", "shortlog", "fetch", "version", "help"];
# Git configuration keys that make Git run a command; a restricted agent may not set them with -c.
def git_exec_config_regex: "^(core\\.(pager|editor|sshcommand|fsmonitor|hookspath|askpass|gitproxy)|alias\\..*|credential\\..*|diff\\.external|gpg\\.program|sequence\\.editor|pager\\..*|merge\\..*\\.driver|filter\\..*\\.(clean|smudge|process))$";
# Flags that take a separate value in branch and tag listings.
def git_listing_value_flags: ["--contains", "--no-contains", "--merged", "--no-merged", "--points-at", "--sort", "--format"];
def git_branch_write_flags: "^(--(delete|move|copy|force|set-upstream-to|unset-upstream|edit-description|track|no-track)(=.*)?|-[A-Za-z]*[dDmMcCufqt][A-Za-z]*)$";
def git_tag_write_flags: "^(--(delete|force|annotate|sign|message|file|local-user)(=.*)?|-[A-Za-z]*[dfasmFu][A-Za-z]*)$";
def git_list_flag: "^(-l|--list)$";
def git_config_read_flag: "^(--get|--get-all|--get-regexp|--get-urlmatch|--list|-l)$";
def git_config_write_flag: "^(--add|--unset|--unset-all|--replace-all|--edit|-e|--rename-section|--remove-section|--global|--system|--file|-f|--worktree)$";

# Programs that can write a file given its path as an argument.
def store_interpreters_regex: "^(python[0-9.]*|pypy3?|node|nodejs|deno|bun|ruby|perl|php|lua|Rscript|tsx|ts-node|awk|gawk|mawk|osascript|patch)$";
# Hint heuristic, deliberately simple: inline code or a heredoc given to an interpreter that
# contains a file-writing call. Script files are not read, and stdout writes are excluded.
def code_writes_file_regex:
  "write_text|write_bytes|writeFileSync|writeFile|appendFileSync|appendFile|File\\.(write|binwrite)|file_put_contents|fs\\.createWriteStream|(?<!stdout)(?<!stderr)\\.write\\(|open\\([^)]*['\"][wax][+bt]*['\"]|open\\([^)]*['\"]>";
def in_place_sed_regex: "^(-[nErsz]*i.*|--in-place(=.*)?)$";
def in_place_perl_regex: "^-[pnalwsE]*i";

def policy_positionals: map(select(startswith("-") | not));

# ---------------------------------------------------------------- Git by subagents
# True when a Git command is on the read-only list. $git is {sub, args, globals}.
def git_read_form:
  .sub as $sub | .args as $args | ($args | policy_positionals) as $positional
  | if $sub == null then true
    elif ($sub | IN(git_read_subcommands[])) then true
    elif $sub == "remote" then (($positional | length) == 0 or ($positional[0] | IN("show", "get-url")))
    elif $sub == "config" then (any($args[]; test(git_config_read_flag)) and (any($args[]; test(git_config_write_flag)) | not))
    elif $sub == "branch" then
      (any(($args | flags_skipping(git_listing_value_flags))[]; test(git_branch_write_flags)) | not)
      and (any($args[]; test(git_list_flag)) or (($args | positionals_skipping(git_listing_value_flags)) | length) == 0)
    elif $sub == "tag" then
      (any(($args | flags_skipping(git_listing_value_flags))[]; test(git_tag_write_flags)) | not)
      and (any($args[]; test("^(-l|--list|-v|--verify|--contains|--no-contains|--points-at|--merged|--no-merged|-n[0-9]*)$"))
           or (($args | positionals_skipping(git_listing_value_flags)) | length) == 0)
    elif $sub == "stash" then (($positional | first) // "") | IN("list", "show")
    elif $sub == "worktree" then (($positional | first) // "") == "list"
    else false end;

# A -c or --config-env that sets a key which makes Git run a command.
def git_exec_config:
  .globals as $globals
  | [ range(0; $globals | length) as $i
      | if ($globals[$i] | IN("-c", "--config-env")) then ($globals[$i + 1] // "")
        elif ($globals[$i] | startswith("--config-env=")) then ($globals[$i] | sub("^[^=]*="; ""))
        else empty end
      | select(sub("=.*$"; "") | test(git_exec_config_regex; "i")) ] | first;

def git_denied_label:
  if git_exec_config != null then "git -c " + (git_exec_config | sub("=.*$"; ""))
  elif git_read_form then null
  else "git " + .sub end;

def git_write_policy($cmds):
  ([ $cmds[] | select(.prog == "git") | git_denied_label | select(. != null) ] | unique) as $labels
  | if ($labels | length) == 0 then null
    else {classes: ["git-write-by-subagent"], operations: $labels,
          reason: ("ai-engineering guard: denied. " + ($labels | join(", "))
                   + " is not on the read-only Git list for this agent: the coordinator owns Git. Do not run Git commands that change the repository or its configuration; leave the changes in the working tree and say in your report what should be committed. "
                   + guardrail_note)} end;

# ---------------------------------------------------------------- authority store
# Lexical normalisation: relative paths are taken from the working directory; ., .. and // collapse.
def normalize_path($cwd):
  (if startswith("/") then . else (($cwd // "") + "/" + .) end)
  | split("/")
  | reduce .[] as $segment ([]; if $segment == "" or $segment == "." then . elif $segment == ".." then .[0:-1] else . + [$segment] end)
  | "/" + join("/");

# The store is matched by its tail, not only by its repository-relative path, and without regard
# to case (a case-insensitive file system resolves .STATE.JSON and .Agents/Specs). Paths here are lower case.
def under_token_store($path; $common):
  ($path + "/") as $dir
  | ($dir | contains("/ai-engineering/tokens/")) or ($common != "" and ($dir | startswith($common + "/ai-engineering/tokens/")));
def is_state_file($path): $path | endswith(".state.json");
# The directories that hold the store; removing, moving or replacing them replaces the store.
#   git     .git and .git/ai-engineering (the token store's parents)
#   all     also .agents, .agents/specs and the directories directly under it (no extension)
def is_store_ancestor($path; $common; $level):
  ($level == "git" or $level == "all")
  and (($path | test("(^|/)\\.git(/ai-engineering)?$")) or ($common != "" and ($path == $common or $path == $common + "/ai-engineering"))
       or ($level == "all" and ($path | test("(^|/)\\.agents(/specs(/[^/.]+)*)?$"))));
# A glob, bracket or brace in a write target near the store cannot be resolved: it is refused.
def glob_near_store($path):
  ($path | test("[*?\\[{]")) and ($path | test("(^|/)\\.(agents|git)(/|$)|\\.state|/ai-engineering/tokens"));

# The text when it names the authority store, else null. $level: none | git | all (see is_store_ancestor).
def store_path_hit($text; $context; $level):
  ($text | normalize_path($context.cwd) | ascii_downcase) as $path
  | (($context.commonDir // "") | ascii_downcase) as $common
  | if is_state_file($path) or under_token_store($path; $common) then $text
    elif is_store_ancestor($path; $common; $level) then $text
    elif glob_near_store($path) then $text
    else null end;

# Git's own files that run code or change what Git does: restricted agents may not write them.
def git_protected_hit($text; $context):
  ($text | normalize_path($context.cwd) | ascii_downcase) as $path
  | if ($path | test("(^|/)\\.git/(hooks|info)(/|$)|(^|/)\\.git/config$|(^|/)\\.git$")) then $text else null end;

def write_redirect_targets:
  [ .redirs[] | select(.op | IN(">", ">>", ">|", "&>", "&>>", "<>", ">&"))
    | select((.op == ">&" and (.t | test("^[0-9-]+$"))) | not) | .t ];

def option_values($args; $short; $long):
  [ range(0; $args | length) as $i
    | if $args[$i] == $short or $args[$i] == $long then ($args[$i + 1] // empty)
      elif ($args[$i] | startswith($long + "=")) then ($args[$i] | sub("^[^=]*="; ""))
      else empty end ];

def url_basename: sub("[?#].*$"; "") | split("/") | last;
def under_directory($directory): if $directory == "" then . else $directory + "/" + . end;

# Working directory after each command: cd and pushd with a literal target move it (a cd inside
# a subshell is treated as moving it for the rest, which only over-matches).
def with_directories($commands; $cwd):
  (reduce $commands[] as $command ({dir: $cwd, out: []};
     .dir as $current
     | .out += [$command + {dir: $current}]
     | if ($command.prog | IN("cd", "pushd")) then
         (($command.args | policy_positionals | first) // null) as $target
         | (if $target == null or $target == "-" then . else .dir = ($target | normalize_path($current)) end)
       elif $command.prog == "popd" then .dir = $cwd
       else . end)).out;

# Paths a command writes: {t: path text, level: none | git | all}. Reads (cat, jq, grep, less,
# cp sources) are not listed.
def command_write_targets:
  .prog as $prog | .args as $args | .sub as $sub | ($args | policy_positionals) as $positional
  | [ (write_redirect_targets[] | {t: ., level: "git"}),
      (if $prog == "tee" or $prog == "truncate" or $prog == "touch" or $prog == "shred" or $prog == "ln" or $prog == "mkdir" or $prog == "sponge"
       then $positional[] | {t: ., level: "git"}
       elif $prog == "rm" or $prog == "unlink" or $prog == "mv" then $positional[] | {t: ., level: "all"}
       elif $prog | IN("cp", "install", "rsync") then
         ((($positional | last) // empty), option_values($args; "-t"; "--target-directory")[]) | {t: ., level: "all"}
       elif $prog == "dd" then $args[] | select(startswith("of=")) | {t: .[3:], level: "git"}
       elif $prog == "sed" and any($args[]; test(in_place_sed_regex)) then $positional[] | {t: ., level: "git"}
       elif $prog == "perl" and any($args[]; test(in_place_perl_regex)) then $positional[] | {t: ., level: "git"}
       elif $prog == "tar" and any($args[]; test("^(-[A-Za-z]*x[A-Za-z]*|x[A-Za-z]*|--extract|--get)$")) then
         option_values($args; "-C"; "--directory")[] | {t: ., level: "all"}
       elif $prog == "unzip" then option_values($args; "-d"; "--directory")[] | {t: ., level: "all"}
       elif $prog == "patch" then ($positional[], option_values($args; "-d"; "--directory")[], option_values($args; "-o"; "--output")[]) | {t: ., level: "all"}
       elif $prog == "curl" then
         (option_values($args; "--output-dir"; "--output-dir")[0] // "") as $directory
         | (option_values($args; "-o"; "--output")[] | select(. != "-") | under_directory($directory)),
           (if any($args[]; test("^(-[A-Za-z]*O|--remote-name)$")) then ([ curl_request($args).urls[] | url_basename | select(length > 0) ] | .[] | under_directory($directory)) else empty end)
         | {t: ., level: "git"}
       elif $prog == "wget" then
         (option_values($args; "-P"; "--directory-prefix")[0] // "") as $directory
         | (option_values($args; "-O"; "--output-document")[] | select(. != "-") | under_directory($directory)),
           (option_values($args; "-o"; "--output-file")[]),
           (if (option_values($args; "-O"; "--output-document") | length) == 0 then ([ wget_request($args).urls[] | url_basename | select(length > 0) ] | .[] | under_directory($directory)) else empty end)
         | {t: ., level: "git"}
       elif $prog == "git" and ($sub | IN("diff", "log", "show", "format-patch")) then option_values($args; "--output"; "--output")[] | {t: ., level: "git"}
       elif $prog == "git" and $sub == "checkout" then
         ([ range(0; $args | length) as $i | select($args[$i] == "--") | $i ] | first) as $dashes
         | (if $dashes == null then empty else $args[$dashes + 1:][] end) | {t: ., level: "all"}
       elif $prog == "git" and $sub == "restore" then ($args | positionals_skipping(["-s", "--source"]))[] | {t: ., level: "all"}
       else empty end) ];

# A program that can write the store in ways no parser can follow, given the store in its
# arguments or heredoc (inline code, a patch): refused (this also refuses reads through it).
def interpreter_mentions_store:
  ((.prog != null and (.prog | test(store_interpreters_regex)))
   or (.prog == "git" and (.sub | IN("apply", "am"))))
  and (([ .args[], .stdin[] ] | join("\n")) | test("\\.state\\.json|ai-engineering/tokens"; "i"));

def authority_store_policy($cmds; $context):
  ([ $cmds[] | . as $command
     | ($context + {cwd: $command.dir}) as $where
     | ((command_write_targets[] | store_path_hit(.t; $where; .level) | select(. != null)),
        (if ($command | interpreter_mentions_store) then ($command.prog + " given the authority store") else empty end)) ]) as $hits
  | if ($hits | length) == 0 then null
    else {classes: ["authority-store-write"], operations: [$hits[0]],
          reason: ("ai-engineering guard: denied. Writing to " + $hits[0]
                   + " is not allowed: the authority store (.agents/specs/**/*.state.json and the token store under the Git common directory) is written only by the plugin's transition script. "
                   + guardrail_note)} end;

# Restricted agents may not write Git's hooks, configuration or info files through the shell.
def git_protected_policy($cmds; $context):
  ([ $cmds[] | . as $command
     | ($context + {cwd: $command.dir}) as $where
     | command_write_targets[] | git_protected_hit(.t; $where) | select(. != null) ]) as $hits
  | if ($hits | length) == 0 then null
    else {classes: ["git-write-by-subagent"], operations: [$hits[0]],
          reason: ("ai-engineering guard: denied. Writing to " + $hits[0]
                   + " would change what Git runs or how it behaves. The coordinator owns Git and its configuration. " + guardrail_note)} end;

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
  | with_directories([ $result.units[].cmds[] ]; $context.cwd) as $cmds
  | ($context.agentType // "") as $agent
  | ($agent | IN(git_restricted_agents[])) as $restricted
  | ([ authority_store_policy($cmds; $context),
       (if $restricted then git_write_policy($cmds) else null end),
       (if $restricted then git_protected_policy($cmds; $context) else null end) ] | map(select(. != null))) as $denials
  | if ($denials | length) > 0 then
      {decision: "deny", reason: ($denials | map(.reason) | join(" ")),
       classes: ([ $denials[].classes[] ] + $compound.classes | unique),
       ops: ($compound.ops + [ $denials[].operations[] | {operation: ., classes: []} ]), hint: "none", hintTargets: []}
    elif $compound.decision == "none" and ($agent | IN(implementation_agents[])) then
      shell_edit_hint($cmds) as $edit
      | $compound + {hint: $edit.hint, hintTargets: $edit.targets}
    else $compound + {hint: "none", hintTargets: []} end;
