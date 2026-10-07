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

# Entry points for main.jq, which includes only this module: jq includes are not transitive, and
# including classify.jq from main.jq as well compiled it (and lexer.jq, tables.jq) twice per run.
def guard_parse($text; $branch): parse_script($text; 0; $branch);
def guard_floor_text($parsed): floor_text($parsed);
def guard_push_mentioned($text): any($text | keyword_text_variants[]; test("push"; "i"));

# The keyword floor over a floor text (main.jq calls these, so it needs no extra include).
def floor_classes($text; $branch): keyword_net($text; $branch);
def floor_mentions_push($text): any($text | keyword_text_variants[]; test(kw_ws + "git" + kw_gap + "push" + kw_we; "i"));

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
# H5: Git run with an environment variable outside the safe list (tables.jq git_env_safe), set
# for this command (prefix, env or sudo) or exported earlier in the submission, is denied too.
def git_denied_label:
  {sub: .sub, rest: .args, globals: .globals} as $git
  | ([ git_config_settings($git.globals)[] | select(.key | test(git_safe_config_key_regex; "i") | not) | .key ] | first) as $setting
  | (git_exec_options($git) | first) as $option
  | ([ (.env // [])[] | select(git_env_safe | not) | sub("=.*$"; "") ] | first) as $variable
  | if $variable != null then "git with " + $variable + " set"
    elif $setting != null then "git -c " + $setting
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
# A Git magic pathspec (`:/`, `:(top)x`, `:!x`, ...) is a pattern too (NR-4): it can name any path.
def is_pattern_target: test("[*?\\[{$`]|[^\\x01-\\x7f]|^:");
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

# git rm, mv and clean (and read-tree) with -n / --dry-run change nothing.
def git_dry_run_regex: "^(--dry-run|-[A-Za-z]*n[A-Za-z]*)$";

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
       # NR-4: Git subcommands that remove, move or replace tracked files or their index entries.
       elif $prog == "git" and ($sub | IN("rm", "mv", "clean")) and (any($args[]; test(git_dry_run_regex)) | not) then
         ($args | positionals_skipping(["--pathspec-from-file", "-e", "--exclude"]))[] | {t: ., level: "all"}
       elif $prog == "git" and $sub == "update-index" then
         ($positional[] | if contains(",") then (split(",") | last) else . end) | {t: ., level: "all"}
       elif $prog == "git" and $sub == "checkout-index" then
         ((option_values($args; "--prefix"; "--prefix") | last) // "") as $prefix
         | ($positional[] | $prefix + .), (if $prefix != "" then $prefix else empty end) | {t: ., level: "all"}
       elif $prog == "git" and $sub == "hash-object" and any($args[]; test("^-[A-Za-z]*w[A-Za-z]*$")) then
         option_values($args; "--path"; "--path")[] | {t: ., level: "all"}
       elif $prog == "git" and $sub == "read-tree" then option_values($args; "--prefix"; "--prefix")[] | {t: ., level: "all"}
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
# NR-4: --pathspec-from-file names paths this guard cannot read; as a destination it is a pattern.
def git_pathspec_file($args):
  if any($args[]; test("^--pathspec-from-file(=|$)")) then [":(pathspec-from-file)"] else [] end;
# Seam (owner decision pending, WORK-001 fix round 3): branch switches (checkout <branch>, switch),
# merge, pull, rebase, cherry-pick, stash, no-ref whole-tree index restores (checkout -- ., restore .,
# reset --hard with no ref) and patch / git apply / git am from a file of unknown content keep their
# earlier behaviour: nothing below adds a decision for them. Add their rule here once decided.
def git_tree_ref_restore:
  .args as $args | ($args | policy_positionals) as $positional
  | ([ range(0; $args | length) as $i | select($args[$i] == "--") | $i ] | first) as $dashes
  | ($args | positionals_skipping(["--pathspec-from-file"])) as $operands
  | if .sub == "checkout" then
      (if $dashes != null then
         (($args[0:$dashes] | positionals_skipping(["--pathspec-from-file"]) | length) > 0) as $has_ref
         | (if $has_ref then [ ($args[$dashes + 1:][], git_pathspec_file($args)[]) | {op: "git checkout <ref> --", dest: .} ] else [] end)
       elif ($operands | length) >= 2 then [ ($operands[1:][], git_pathspec_file($args)[]) | {op: "git checkout <ref>", dest: .} ]
       elif ($operands | length) == 1 then [ git_pathspec_file($args)[] | {op: "git checkout <ref>", dest: .} ]
       else [] end)
    elif .sub == "restore" then
      (any($args[]; test("^(-s|--source)(=.*)?$|^-s.")) and ((any($args[]; test("^(--staged|-S)$")) and (any($args[]; test("^(--worktree|-W)$")) | not)) | not)) as $from_ref
      | if $from_ref then [ (($args | positionals_skipping(["-s", "--source", "--pathspec-from-file"]))[], git_pathspec_file($args)[]) | {op: "git restore --source", dest: .} ] else [] end
    elif .sub == "reset" then
      (if any($args[]; test("^--(hard|merge|keep)$")) and (($args | policy_positionals | length) > 0) then [{op: "git reset --hard <ref>", dest: "."}] else [] end)
      # A magic pathspec or a pathspec file: the entries it resets cannot be resolved.
      + [ ($operands[] | select(startswith(":"))), git_pathspec_file($args)[] | {op: "git reset <pathspec>", dest: .} ]
    elif .sub == "read-tree" then
      # read-tree replaces the whole index (and the files with -u), or everything under --prefix.
      (if any($args[]; test(git_dry_run_regex)) then []
       else [{op: (if any($args[]; test("^(-u|-[A-Za-z]*u[A-Za-z]*)$")) then "git read-tree -u" else "git read-tree" end),
              dest: ((option_values($args; "--prefix"; "--prefix") | last) // ".")}] end)
    elif .sub == "rm" then
      (if any($args[]; test(git_dry_run_regex)) then []
       else [ ($operands[] | select(startswith(":"))), git_pathspec_file($args)[] | {op: "git rm <pathspec>", dest: .} ]
            + (if any($args[]; test("^(-r|-[A-Za-z]*r[A-Za-z]*)$")) then [ $operands[] | {op: "git rm -r", dest: .} ] else [] end) end)
    elif .sub == "clean" then
      # -x/-X remove ignored files (the authority store is ignored state), -d whole directories.
      ($args | positionals_skipping(["-e", "--exclude"])) as $paths
      | if any($args[]; test(git_dry_run_regex)) then []
        else [ $paths[] | select(startswith(":")) | {op: "git clean <pathspec>", dest: .} ]
             + (if any($args[]; test("^-[A-Za-z]*[xXd][A-Za-z]*$")) then [ (if ($paths | length) > 0 then $paths[] else "." end) | {op: "git clean -x/-X/-d", dest: .} ] else [] end) end
    elif .sub == "checkout-index" then
      (if any($args[]; test("^(-a|--all|--stdin|-[A-Za-z]*a[A-Za-z]*)$")) then
         [{op: "git checkout-index (all or from standard input)", dest: ((option_values($args; "--prefix"; "--prefix") | last) // ".")}]
       else [] end)
    elif .sub == "update-index" then
      (if any($args[]; test("^--(index-info|stdin)$")) then [{op: "git update-index (paths from standard input)", dest: "."}] else [] end)
    elif .sub == "hash-object" then
      (if any($args[]; test("^-[A-Za-z]*w[A-Za-z]*$")) and any($args[]; . == "--stdin-paths") then [{op: "git hash-object -w --stdin-paths", dest: "."}] else [] end)
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

# N6(c) owner ruling: a destination whose only unresolved components are globs (* ? [ ]), under a
# literal subdirectory that is not the repository root (or an ancestor), .agents or .git, with no
# `..` anywhere, cannot reach protected state. A variable, substitution, brace, magic pathspec or
# non-ASCII character still counts as unresolved.
def glob_under_literal_subdirectory($dest; $context; $root):
  ($dest | split("/") | map(select(. != "" and . != "."))) as $parts
  | ([ range(0; $parts | length) as $i | select($parts[$i] | test("[*?\\[]")) | $i ] | first) as $at
  | ((if ($dest | startswith("/")) then "/" else "" end) + ($parts[0:($at // 0)] | join("/"))) as $prefix
  | ($prefix | normalize_path($context.cwd) | ascii_downcase) as $prefix_path
  | (($dest | test("[$`{]|[^\\x01-\\x7f]|^:")) | not)
    and ((directory_suffix($context) | is_pattern_target) | not)
    and (any($parts[]; . == "..") | not)
    and $at != null and $at > 0
    and $prefix_path != $root and $prefix_path != "/" and (($root | startswith($prefix_path + "/")) | not)
    and ((($prefix_path + "/") | test("(^|/)\\.(git|agents)/")) | not);

# What a destination can overwrite, or null. $root: the repository root (lower case, normalised).
def protected_reach($dest; $context; $root):
  if pattern_write($dest; $context) then
    (if glob_under_literal_subdirectory($dest; $context; $root) then null else "a protected path (the destination cannot be resolved)" end)
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

# ---------------------------------------------------------------- patches (N6(b) owner ruling)
# patch, git apply and git am ask when their patch is not text this submission wrote (or gave them
# as a heredoc or pipeline). With known text, the paths it touches are judged like any write: a
# store path denies (for every caller), Git's own files deny for restricted agents, anything else
# is no decision. --directory and --include values are judged as paths too (--exclude only narrows).
def patch_paths:
  [ split("\n")[]
    | ((capture("^(?:\\+\\+\\+|---) \"?(?<p>[^\\t\"]+)") | .p),
       (capture("^diff --git \"?(?<a>[^ \"]+)\"? \"?(?<b>[^ \"]+)") | .a, .b),
       (capture("^(?:rename|copy) (?:from|to) (?<p>.+)$") | .p),
       (capture("^Index: (?<p>.+)$") | .p))
    | select(. != "/dev/null") | ., sub("^[ab]/"; "") ] | unique;
def patch_dry_run:
  if .prog == "patch" then any(.args[]; test("^(--dry-run|-C|--check)$"))
  elif .sub == "apply" then any(.args[]; test("^--(check|stat|numstat|summary)$")) and (any(.args[]; . == "--apply") | not)
  else false end;
def patch_label: if .prog == "patch" then "patch" else "git " + .sub end;
# {ask: [labels], deny: [paths]} over the commands that apply a patch.
def patch_findings($cmds; $context; $restricted):
  reduce ($cmds[] | select(.patch != null and (patch_dry_run | not))) as $command ({ask: [], store: [], git: []};
    ($context + {cwd: $command.dir, base: $context.cwd}) as $where
    | ([ ($command.args | option_values(.; "--directory"; "--directory")[]),
         (if $command.prog == "patch" then option_values($command.args; "-d"; "--directory")[] else empty end) ] | last) as $directory
    | ([ option_values($command.args; "--include"; "--include")[] ] + (if $directory != null then [$directory] else [] end)) as $path_options
    | if ($command.patch.known | not) then .ask += [($command | patch_label)]
      else
        ([ ($command.patch.texts | join("\n") | patch_paths)[] | if $directory != null then $directory + "/" + . else . end ] + $path_options) as $paths
        | .store += [ $paths[] | select(store_path_hit(.; $where; "all") != null) ]
        | .git += [ $paths[] | select($restricted and git_protected_hit(.; $where) != null) ]
      end);

# ---------------------------------------------------------------- state-changing Git (N6(a) owner ruling)
# Branch switches, merge, pull, rebase, cherry-pick, stash and no-ref whole-tree restores replace
# tracked files, the authority store's .agents/specs state files among them. They ask only when
# the state can change: pull always; a dynamic ref, an earlier ref- or index-changing command in
# the submission, another repository (git -C, --git-dir, --work-tree) or an operation in progress
# (--continue, --skip, a range) ask now; otherwise the wrapper checks at hook time whether the state
# files differ between HEAD and the ref (or base and ref) and whether uncommitted state changes
# would be discarded, and asks only if so. Each item: {op, ref, base, discard, path, now}.
def git_state_value_flags: ["-b", "-B", "--orphan", "-c", "-C", "--create", "--force-create", "-m", "-F", "--file", "-s", "--strategy",
                            "-X", "--strategy-option", "--onto", "-x", "--exec", "--into-name", "--conflict", "--pathspec-from-file"];
def literal_ref: test("[$`*?\\[]") | not;
def git_state_items($context; $root):
  .sub as $sub | .args as $args
  | ($args | positionals_skipping(git_state_value_flags)) as $operands
  | any($args[]; test("^(-f|--force|--discard-changes)$")) as $force
  | any($args[]; test("^--(abort|quit)$")) as $abort
  | any($args[]; test("^--(continue|skip)$")) as $resume
  | ([ range(0; $args | length) as $i | select($args[$i] == "--") | $i ] | first) as $dashes
  | ($context + {cwd: .dir, base: $context.cwd}) as $where
  | def reaches($dests): any($dests[]; protected_reach(.; $where; $root) != null);
    def switch_ref: if . == "-" then "@{-1}" else . end;
    if $sub == "pull" then [{op: "git pull", now: "it fetches and merges commits whose state is not known here"}]
    elif $sub == "checkout" then
      (if $dashes != null then
         (if ($args[0:$dashes] | positionals_skipping(git_state_value_flags) | length) == 0 and reaches($args[$dashes + 1:])
          then [{op: "git checkout -- <paths>", discard: true}] else [] end)
       elif any($args[]; test("^(-b|-B|--orphan)$")) then
         (if any($args[]; . == "--orphan") then [{op: "git checkout --orphan", now: "it starts a branch with no files"}]
          elif ($operands | length) > 0 then [{op: "git checkout -b", ref: ($operands[0] | switch_ref), discard: $force}] else [] end)
       elif ($operands | length) == 1 then [{op: "git checkout <branch>", ref: ($operands[0] | switch_ref), path: true, discard: $force}]
       else [] end)
    elif $sub == "switch" then
      (if any($args[]; . == "--orphan") then [{op: "git switch --orphan", now: "it starts a branch with no files"}]
       elif any($args[]; test("^(-c|-C|--create|--force-create)$")) then
         (if ($operands | length) > 0 then [{op: "git switch -c", ref: ($operands[0] | switch_ref), discard: $force}] else [] end)
       elif ($operands | length) > 0 then [{op: "git switch", ref: ($operands[0] | switch_ref), discard: $force}]
       else [] end)
    elif $sub == "merge" or $sub == "rebase" or $sub == "cherry-pick" or $sub == "revert" then
      (if $abort then [{op: ("git " + $sub + " --abort"), discard: true}]
       elif $resume then [{op: ("git " + $sub + " --continue"), now: "it continues an operation in progress"}]
       elif $sub == "rebase" and any($args[]; test("^(--root|-i|--interactive)$")) then [{op: "git rebase", now: "it rewrites history interactively or from the root"}]
       elif $sub == "cherry-pick" or $sub == "revert" then
         (if ($operands | length) == 0 then []
          elif any($operands[]; contains("..")) then [{op: ("git " + $sub), now: "it applies a range of commits"}]
          else [ $operands[] | {op: ("git " + $sub), ref: ., base: (. + "^")} ] end)
       else [ (if ($operands | length) > 0 then $operands[] else "@{upstream}" end), option_values($args; "--onto"; "--onto")[]
              | {op: ("git " + $sub), ref: .} ] end)
    elif $sub == "stash" then
      ((($operands | first) // "push") as $action
       | if $action | IN("push", "save") then [{op: "git stash", discard: true}]
         elif $action | IN("pop", "apply") then [{op: ("git stash " + $action), ref: ($operands[1] // "stash@{0}")}]
         elif $action == "branch" then [{op: "git stash branch", now: "it checks out a branch from a stash"}]
         else [] end)
    elif $sub == "restore" then
      (if any($args[]; test("^(-s|--source)(=.*)?$|^-s.")) or (any($args[]; test("^(--staged|-S)$")) and (any($args[]; test("^(--worktree|-W)$")) | not)) then []
       elif reaches([ ($args | positionals_skipping(["--pathspec-from-file"]))[], git_pathspec_file($args)[] ]) then [{op: "git restore <paths>", discard: true}]
       else [] end)
    elif $sub == "reset" then
      (if any($args[]; test("^--(hard|merge|keep)$")) and ($operands | length) == 0 then [{op: "git reset --hard", discard: true}] else [] end)
    else [] end;

# {now: [{op, why}], checks: [{op, ref, base, discard, path}]} over the commands in order.
def git_state_policy($cmds; $context; $root):
  reduce range(0; $cmds | length) as $i ({now: [], checks: [], changed: false};
    $cmds[$i] as $command
    | if $command.prog != "git" then .
      else
        ($command | git_state_items($context; $root)) as $items
        | (([ $command.globals[] | select(test("^--(git-dir|work-tree)")) ] | length) > 0 or (($command.chdir // []) | length) > 0) as $elsewhere
        | reduce $items[] as $item (.;
            if $item.now != null then .now += [{op: $item.op, why: $item.now}]
            elif $elsewhere then .now += [{op: $item.op, why: "it runs in another directory or repository"}]
            elif .changed then .now += [{op: $item.op, why: "an earlier command in this submission changes refs or the index"}]
            elif $item.ref != null and ($item.ref | literal_ref | not) then .now += [{op: $item.op, why: "its ref is not literal"}]
            else .checks += [$item] end)
        # Anything but a read (fetch included: it moves remote-tracking refs) makes later checks stale.
        | .changed = (.changed or ($items | length) > 0 or ({sub: $command.sub, args: $command.args} | git_read_form | not) or $command.sub == "fetch")
      end)
  | {now: .now, checks: .checks[0:8], over: ((.checks | length) > 8)};

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
def protected_ask($op; $why):
  {decision: "ask", classes: ["protected-tree-overwrite"], ops: [{operation: $op, classes: ["protected-tree-overwrite"]}],
   reason: ("ai-engineering guard: " + $op + " can replace protected state (.agents/specs state files, the authority store): " + $why
            + ". It needs explicit human approval. " + guardrail_note), hint: "none", hintTargets: []};

# stateChecks (on a verdict with no decision): the hook-time Git checks for the wrapper (N6(a)).
def decide($result; $context):
  compound_policy($result; ($context.floor // [])) as $compound
  | with_directories([ $result.units[].cmds[] ]; $context.cwd) as $cmds
  | ($context.agentType // "") as $agent
  | ($agent | IN(git_restricted_agents[])) as $restricted
  | ((if ($context.root // "") != "" then $context.root else $context.cwd end) | normalize_path("/") | ascii_downcase) as $root
  | patch_findings($cmds; $context; $restricted) as $patches
  | ([ authority_store_policy($cmds; $context),
       (if ($patches.store | length) > 0 then
          {classes: ["authority-store-write"], operations: [$patches.store[0]],
           reason: ("ai-engineering guard: denied. A patch in this command writes " + $patches.store[0]
                    + ", which is in the authority store (.agents/specs/**/*.state.json and the token store); it is written only by the plugin's transition script. " + guardrail_note)}
        else null end),
       (if ($patches.git | length) > 0 then
          {classes: ["git-write-by-subagent"], operations: [$patches.git[0]],
           reason: ("ai-engineering guard: denied. A patch in this command writes " + $patches.git[0]
                    + ", which would change what Git runs or how it behaves. The coordinator owns Git and its configuration. " + guardrail_note)}
        else null end),
       (if $restricted then git_write_policy($cmds) else null end),
       (if $restricted then git_protected_policy($cmds; $context) else null end) ] | map(select(. != null))) as $denials
  | (if $compound.decision == "none" then protected_tree_policy($cmds; $context) else null end) as $tree
  | (if $compound.decision == "none" and $tree == null and ($denials | length) == 0 then git_state_policy($cmds; $context; $root) else null end) as $state
  | if ($denials | length) > 0 then
      {decision: "deny", reason: ($denials | map(.reason) | join(" ")),
       classes: ([ $denials[].classes[] ] + $compound.classes | unique),
       ops: ($compound.ops + [ $denials[].operations[] | {operation: ., classes: []} ]), hint: "none", hintTargets: []}
    elif $tree != null then $tree + {hint: "none", hintTargets: []}
    elif $compound.decision != "none" then $compound + {hint: "none", hintTargets: []}
    elif ($patches.ask | length) > 0 then protected_ask($patches.ask[0]; "its patch is not text written in this submission, so the files it changes are unknown")
    elif ($state.now | length) > 0 then protected_ask($state.now[0].op; $state.now[0].why)
    elif $state.over then protected_ask($state.checks[0].op; "too many state-changing Git commands to check")
    elif $agent | IN(implementation_agents[]) then
      shell_edit_hint($cmds) as $edit
      | $compound + {hint: $edit.hint, hintTargets: $edit.targets, stateChecks: $state.checks}
    else $compound + {hint: "none", hintTargets: [], stateChecks: $state.checks} end;
