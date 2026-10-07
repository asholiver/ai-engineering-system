# Guard v2 decision policy. Applied after classification, as a separate step, so policy that
# needs more context (agent_type, authority store, delivery policy for deploy classes) is
# added here without touching the parser or the tables.
#
# Input: the result of parse_script ({units, uncertain}) and a context object
# {agentType, cwd, commonDir, floor}. floor: the classes the keyword floor found in the
# command text outside proven data spans (main.jq). The floor never lets the decision drop
# below ask; classification and the policies below can only raise it (deny) or label it.
# Output: {decision: "none" | "ask" | "deny", reason, classes, ops: [{operation, classes}],
#          hint: "none" | "hint" | "check", hintTargets}.
# The guard never returns "allow".
include "tables";
include "classify";

# The keyword floor over a floor text (main.jq calls these, so it needs no extra include).
def floor_classes($text; $branch): keyword_net($text; $branch);
def floor_mentions_push($text): $text | test(kw_ws + "git" + kw_gap + "push" + kw_we; "i");

def policy_regex_escape: gsub("(?<c>[^A-Za-z0-9_])"; "\\\(.c)");

def guardrail_note: "Hooks are guardrails, not a sandbox.";

def describe_op: .l + " [" + (.c | join(", ")) + "]";

def compound_policy($result; $floor):
  ([ $result.units[].ops[] ]) as $ops
  # Effectful commands that carry no operation of their own (context setup does not count).
  | ([ $result.units[].others ] | add // 0) as $other_commands
  | if ($ops | length) == 0 then
      if ($floor | length) > 0 then
        {decision: "ask", classes: $floor, ops: [{operation: "keyword floor", classes: $floor}],
         reason: ("ai-engineering guard: words in this command look like a reserved operation and are not proven to be data (class: "
                  + ($floor | join(", ")) + "). It needs explicit human approval. " + guardrail_note)}
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
# The read-only list is git_read_form (classify.jq). On top of it a restricted agent may set no
# -c / --config-env outside the safe list (color.*, core.quotepath) and use no option that runs a
# program (--upload-pack, --receive-pack, git grep -O, --ext-diff, --textconv, ext:: URLs, ...),
# even with a read subcommand such as fetch, log or grep. Input: a command fact.
def git_denied_label:
  {sub: .sub, rest: .args, globals: .globals} as $git
  | ([ git_config_settings($git.globals)[] | select(.key | test(git_safe_config_key_regex; "i") | not) | .key ] | first) as $setting
  | (git_exec_options($git) | first) as $option
  | if $setting != null then "git -c " + $setting
    elif $option != null then "git " + (($git.sub // "") + " " + ($option | sub("=.*$"; "") | .[0:40]) | ltrimstr(" "))
    elif ({sub: .sub, args: .args} | git_read_form) then null
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
# The repository root and its ancestors are not denied here: a whole-tree writer aimed at them
# asks instead (protected_tree_policy, N6 owner ruling).
def is_store_ancestor($path; $common; $level):
  ($level == "git" or $level == "all")
  and (($path | test("(^|/)\\.git(/ai-engineering)?$")) or ($common != "" and ($path == $common or $path == $common + "/ai-engineering"))
       or ($level == "all" and ($path | test("(^|/)\\.agents(/specs(/[^/.]+)*)?$"))));

def literal_store_hit($path; $common; $level):
  is_state_file($path) or under_token_store($path; $common) or is_store_ancestor($path; $common; $level);

# ---- N5: targets whose expansion is unknown (one rule for the store and for Git's own files)
# A glob (* ? [ ]), brace, $ expansion, backquote or non-ASCII character in a write target is a
# pattern. Rule (conservative, documented): a pattern target is refused when, for any brace
# alternative, it is a literal hit, or some path component could match .git (and, for the
# store, .agents) as a glob (an expansion is a wildcard that cannot supply a leading dot), or
# (store only) its components could be ai-engineering/tokens, or it mentions ".state".
# Non-ASCII characters are wildcards because APFS folds look-alikes (U+017F long s opens "s",
# U+212A Kelvin sign opens "k", ligatures open "st" and "fi").
def is_pattern_target: test("[*?\\[{$`]|[^\\x01-\\x7f]");
def masked_expansions:
  gsub("\\$\\{[^}]*\\}|\\$\\([^)]*\\)|\\$[A-Za-z_][A-Za-z0-9_]*|\\$[0-9@*#?$!-]|`[^`]*`|[$`]|[^\\x01-\\x7f]"; "\u0001")
  | gsub("\\{[^{}]*\\.\\.[^{}]*\\}"; "*");
# Brace alternatives, innermost first, at most 64; braces left over become wildcards.
def brace_alternatives:
  [ . ]
  | until((any(.[]; test("\\{[^{}]*,[^{}]*\\}")) | not) or length > 64;
      map(if test("\\{[^{}]*,[^{}]*\\}") then
            (capture("^(?<pre>[\\s\\S]*?)\\{(?<body>[^{}]*,[^{}]*)\\}(?<post>[\\s\\S]*)$") as $part
             | ($part.body | split(","))[] | $part.pre + . + $part.post)
          else . end))
  | map(gsub("\\{[^{}]*\\}"; "*"));
def has_wildcard: test("[*?\\[\u0001]");
# One path component as an anchored regular expression.
def glob_component_regex:
  (if test("^[*?\\[\u0001]") then "(?!\\.)" else "" end)
  + ([ match("\\[!?\\]?[^\\]]*\\]|[*?\u0001]|[\\s\\S]"; "g") | .string
       | if . == "*" or . == "\u0001" then "[^/]*"
         elif . == "?" then "[^/]"
         elif startswith("[") and length > 2 then "[" + (.[1:-1] | sub("^!"; "^")) + "]"
         else policy_regex_escape end ] | join(""));
def component_could_match($name): ("^" + glob_component_regex + "$") as $regex | $name | test($regex; "i");
def components_could_match($path; $names):
  any(($path | split("/"))[]; length > 0 and (. as $component | any($names[]; . as $name | $component | component_could_match($name))));
# The token store's tail: a component with a literal character that could be ai-engineering,
# followed by one that could be tokens (a bare * could be either, but cannot point at the store).
def could_reach_token_store($path):
  ($path | split("/")) as $parts
  | any(range(0; $parts | length) as $i
        | ($parts[$i] | test("[^*?\u0001\\[\\]]")) and ($parts[$i] | component_could_match("ai-engineering"))
          and ($i == ($parts | length) - 1 or ($parts[$i + 1] | component_could_match("tokens"))); .);
# Normalised lower-case alternatives of a pattern target (the working directory is literal).
def pattern_alternatives($text; $context):
  [ $text | masked_expansions | brace_alternatives[] | normalize_path($context.cwd | masked_expansions) | ascii_downcase ];
# The part of a working directory that commands of this submission set (cd, env -C, git -C).
def directory_suffix($context):
  ($context.cwd // "") as $dir | ($context.base // "") as $base
  | if $base != "" and ($dir | startswith($base)) then $dir[($base | length):] else $dir end;
def pattern_write($text; $context): ($text | is_pattern_target) or (directory_suffix($context) | is_pattern_target);

# The text when it names the authority store, else null. $level: none | git | all (see is_store_ancestor).
def store_path_hit($text; $context; $level):
  (($context.commonDir // "") | ascii_downcase) as $common
  | if pattern_write($text; $context) then
      (if any(pattern_alternatives($text; $context)[];
              . as $path
              | (($path | has_wildcard | not) and literal_store_hit($path; $common; $level))
                or components_could_match($path; [".agents", ".git"])
                or could_reach_token_store($path)
                or ($path | contains(".state")))
       then $text else null end)
    else
      ($text | normalize_path($context.cwd) | ascii_downcase) as $path
      | if literal_store_hit($path; $common; $level) then $text else null end
    end;

# Git's own files that run code or change what Git does: restricted agents may not write them.
def git_protected_regex: "(^|/)\\.git/(hooks|info)(/|$)|(^|/)\\.git/config$|(^|/)\\.git$";
def git_protected_hit($text; $context):
  if pattern_write($text; $context) then
    (if any(pattern_alternatives($text; $context)[];
            . as $path | (($path | has_wildcard | not) and ($path | test(git_protected_regex))) or components_could_match($path; [".git"]))
     then $text else null end)
  else
    ($text | normalize_path($context.cwd) | ascii_downcase) as $path
    | if ($path | test(git_protected_regex)) then $text else null end
  end;

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

# Working directory of each command: cd and pushd with a literal target move it for the rest (a cd
# inside a subshell is treated as moving it for the rest, which only over-matches), and a
# command's own chdir (env -C, sudo -D, git -C) applies to it alone.
def with_directories($commands; $cwd):
  (reduce $commands[] as $command ({dir: $cwd, out: []};
     .dir as $current
     | (reduce (($command.chdir // [])[]) as $directory ($current; . as $base | $directory | normalize_path($base))) as $here
     | .out += [$command + {dir: $here}]
     | if ($command.prog | IN("cd", "pushd")) then
         (($command.args | policy_positionals | first) // null) as $target
         | (if $target == null or $target == "-" then . else .dir = ($target | normalize_path($here)) end)
       elif $command.prog == "popd" then .dir = $cwd
       else . end)).out;

# Paths a command writes: {t: path text, level: none | git | all}. Reads (cat, jq, grep, less,
# cp sources) are not listed, except hard-link sources (`cp -l`, `link`, `ln` without -s), which
# make the source writable through the new name.
def command_write_targets:
  .prog as $prog | .args as $args | .sub as $sub | ($args | policy_positionals) as $positional
  | [ (write_redirect_targets[] | {t: ., level: "git"}),
      (if $prog == "tee" or $prog == "truncate" or $prog == "touch" or $prog == "shred" or $prog == "ln" or $prog == "mkdir" or $prog == "sponge" or $prog == "link"
       then $positional[] | {t: ., level: "git"}
       elif $prog == "rm" or $prog == "unlink" or $prog == "mv" then $positional[] | {t: ., level: "all"}
       elif $prog == "cp" and any($args[]; test("^(--link|-[A-Za-z]*l[A-Za-z]*)$")) then $positional[] | {t: ., level: "all"}
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
     | ($context + {cwd: $command.dir, base: $context.cwd}) as $where
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
     | ($context + {cwd: $command.dir, base: $context.cwd}) as $where
     | command_write_targets[] | git_protected_hit(.t; $where) | select(. != null) ]) as $hits
  | if ($hits | length) == 0 then null
    else {classes: ["git-write-by-subagent"], operations: [$hits[0]],
          reason: ("ai-engineering guard: denied. Writing to " + $hits[0]
                   + " would change what Git runs or how it behaves. The coordinator owns Git and its configuration. " + guardrail_note)} end;

# ---------------------------------------------------------------- whole-tree writers (N6 owner ruling)
# Whole-directory restore, recursive copy or sync and archive extraction are legitimate. They ask
# (class protected-tree-overwrite) only when the effective destination can overwrite or replace
# a protected path: the repository root or one of its ancestors, anything inside .git, or
# .agents/specs. A destination that cannot be resolved (dynamic, glob) asks too. The source or
# archive is never inspected. Existing denies (store writes, Git by subagents) win; this ask
# only replaces what would otherwise be no decision, for every caller.
def recursive_copy_flag($prog):
  if $prog == "cp" then "^(--recursive|--archive|-[A-Za-z]*[Rra][A-Za-z]*)$"
  else "^(--recursive|--archive|-[A-Za-z]*[ra][A-Za-z]*)$" end;
def last_positional_or_target:
  ((option_values(.args; "-t"; "--target-directory") | last) // ((.args | policy_positionals | last) // null));
def git_tree_ref_restore:
  .args as $args | ($args | policy_positionals) as $positional
  | ([ range(0; $args | length) as $i | select($args[$i] == "--") | $i ] | first) as $dashes
  | if .sub == "checkout" then
      (if $dashes != null then
         (($args[0:$dashes] | policy_positionals | length) > 0) as $has_ref
         | (if $has_ref then [ $args[$dashes + 1:][] | {op: "git checkout <ref> --", dest: .} ] else [] end)
       elif ($positional | length) >= 2 then [ $positional[1:][] | {op: "git checkout <ref>", dest: .} ]
       else [] end)
    elif .sub == "restore" then
      (any($args[]; test("^(-s|--source)(=.*)?$|^-s.")) and ((any($args[]; test("^(--staged|-S)$")) and (any($args[]; test("^(--worktree|-W)$")) | not)) | not)) as $from_ref
      | if $from_ref then [ ($args | positionals_skipping(["-s", "--source"]))[] | {op: "git restore --source", dest: .} ] else [] end
    elif .sub == "reset" then
      (if any($args[]; test("^--(hard|merge|keep)$")) and (($args | policy_positionals | length) > 0) then [{op: "git reset --hard <ref>", dest: "."}] else [] end)
    elif .sub == "read-tree" then
      (if any($args[]; test("^(-u|-[A-Za-z]*u[A-Za-z]*)$")) then [{op: "git read-tree -u", dest: "."}] else [] end)
    else [] end;
def tree_writes:
  .prog as $prog | .args as $args
  | if $prog == null then []
    elif ($prog | IN("cp", "rsync")) and any($args[]; test(recursive_copy_flag($prog))) then
      [ {op: ($prog + " (recursive)"), dest: last_positional_or_target} | select(.dest != null) ]
    elif $prog == "ditto" then [ {op: "ditto", dest: last_positional_or_target} | select(.dest != null) ]
    elif ($prog | IN("tar", "gtar", "bsdtar")) and any($args[]; test("^(-[A-Za-z]*x[A-Za-z]*|x[A-Za-z]*|--extract|--get)$")) then
      [{op: ($prog + " -x"), dest: ((option_values($args; "-C"; "--directory") | last) // ".")}]
    elif $prog == "unzip" and (any($args[]; test("^-[A-Za-z]*[lZtpv]")) | not) then
      [{op: "unzip", dest: ((option_values($args; "-d"; "--directory") | last) // ".")}]
    elif $prog == "cpio" and any($args[]; test("^(-[A-Za-z]*i[A-Za-z]*|--extract)$")) then
      [{op: "cpio -i", dest: ((option_values($args; "-D"; "--directory") | last) // ".")}]
    elif $prog == "cpio" and any($args[]; test("^(-[A-Za-z]*p[A-Za-z]*|--pass-through)$")) then
      [ {op: "cpio -p", dest: ($args | policy_positionals | last)} | select(.dest != null) ]
    elif $prog == "pax" and any($args[]; test("^-[A-Za-z]*r[A-Za-z]*$")) then
      (if any($args[]; test("^-[A-Za-z]*w[A-Za-z]*$")) then [ {op: "pax -rw", dest: ($args | policy_positionals | last)} | select(.dest != null) ]
       else [{op: "pax -r", dest: "."}] end)
    elif ($prog | IN("7z", "7za", "7zz")) and ((($args | policy_positionals | first) // "") | IN("x", "e")) then
      [{op: ($prog + " x"), dest: (([ $args[] | select(startswith("-o")) | .[2:] ] | last) // ".")}]
    elif $prog == "git" then git_tree_ref_restore
    else [] end;

# What a destination can overwrite, or null. $root: the repository root (lower case, normalised).
def protected_reach($dest; $context; $root):
  if pattern_write($dest; $context) then "a protected path (the destination cannot be resolved)"
  else
    ($dest | normalize_path($context.cwd) | ascii_downcase) as $path
    | if $path == $root then "the repository root"
      elif $path == "/" or ($root | startswith($path + "/")) then "the repository root (an ancestor of it)"
      elif ($path + "/") | test("(^|/)\\.git/") then ".git"
      elif $path | test("(^|/)\\.agents(/specs(/.*)?)?$") then ".agents/specs"
      else null end
  end;

def protected_tree_policy($cmds; $context):
  ((if ($context.root // "") != "" then $context.root else $context.cwd end) | normalize_path("/") | ascii_downcase) as $root
  | ([ $cmds[] | . as $command
       | ($context + {cwd: $command.dir, base: $context.cwd}) as $where
       | tree_writes[] | . as $write
       | protected_reach($write.dest; $where; $root) | select(. != null)
       | {op: $write.op, dest: $write.dest, reach: .} ] | first) as $hit
  | if $hit == null then null
    else {decision: "ask", classes: ["protected-tree-overwrite"], ops: [{operation: $hit.op, classes: ["protected-tree-overwrite"]}],
          reason: ("ai-engineering guard: " + $hit.op + " into " + $hit.dest + " can overwrite or replace " + $hit.reach
                   + ", which holds protected state (.agents, the authority store, .git). It needs explicit human approval. " + guardrail_note)} end;

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
  compound_policy($result; ($context.floor // [])) as $compound
  | with_directories([ $result.units[].cmds[] ]; $context.cwd) as $cmds
  | ($context.agentType // "") as $agent
  | ($agent | IN(git_restricted_agents[])) as $restricted
  | ([ authority_store_policy($cmds; $context),
       (if $restricted then git_write_policy($cmds) else null end),
       (if $restricted then git_protected_policy($cmds; $context) else null end) ] | map(select(. != null))) as $denials
  | (if $compound.decision == "none" then protected_tree_policy($cmds; $context) else null end) as $tree
  | if ($denials | length) > 0 then
      {decision: "deny", reason: ($denials | map(.reason) | join(" ")),
       classes: ([ $denials[].classes[] ] + $compound.classes | unique),
       ops: ($compound.ops + [ $denials[].operations[] | {operation: ., classes: []} ]), hint: "none", hintTargets: []}
    elif $tree != null then $tree + {hint: "none", hintTargets: []}
    elif $compound.decision == "none" and ($agent | IN(implementation_agents[])) then
      shell_edit_hint($cmds) as $edit
      | $compound + {hint: $edit.hint, hintTargets: $edit.targets}
    else $compound + {hint: "none", hintTargets: []} end;
