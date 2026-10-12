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
# The restricted-agent keyword fallback (fallback.jq, RR3-3).
def guard_fallback_git($command): fallback_git_check($command);

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
# Program names are lower case here (classify.jq program_of), so Rscript is spelled rscript.
def store_interpreters_regex: "^(python[0-9.]*|pypy3?|node|nodejs|deno|bun|ruby|perl|php|lua|rscript|tsx|ts-node|awk|gawk|mawk|osascript|patch)$";
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
# A `..` never cancels a component that is not literal (a variable, substitution, glob, tilde or
# masked character could be several directories), so the path stays unresolved (RR3-8).
def unresolved_segment_regex: "[$`*?\\[{\u0001]|^~";
def normalize_path($cwd):
  (if startswith("/") then . else (($cwd // "") + "/" + .) end)
  | split("/")
  | reduce .[] as $segment ([];
      if $segment == "" or $segment == "." then .
      elif $segment == ".." then (if length > 0 and (.[-1] | test(unresolved_segment_regex) or . == "..") then . + [$segment] else .[0:-1] end)
      else . + [$segment] end)
  | "/" + join("/");

# RR3-8: a directory the shell resolves at run time that this guard cannot (a leading ~, ~+, ~-,
# ~user, cd -, a bare cd, popd, pushd with no directory or a stack index). It is absolute and
# unresolved, so every path rule treats what is under it as a pattern.
def unresolved_directory: "/${UNRESOLVED_DIRECTORY}";
def resolve_directory($base):
  if startswith("~") then unresolved_directory + (if contains("/") then "/" + sub("^[^/]*/"; "") else "" end) | normalize_path("/")
  else normalize_path($base) end;

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
# So is a leading tilde (RR3-8): ~, ~+, ~- and ~user are directories this guard does not resolve.
def is_pattern_target: test("[*?\\[{$`]|[^\\x01-\\x7f]|^[:~]");
def masked_expansions:
  gsub("^~[^/]*|\\$\\{[^}]*\\}|\\$\\([^)]*\\)|\\$[A-Za-z_][A-Za-z0-9_]*|\\$[0-9@*#?$!-]|`[^`]*`|[$`]|[^\\x01-\\x7f]"; "\u0001")
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

# Values of a program's output options (tables.jq output_option_flags): `-o V`, `--output=V`, `-oV`,
# and a short cluster ending in the option (`-uo V`).
def output_option_values($prog; $args):
  (output_option_flags[$prog // ""] // []) as $flags
  | [ range(0; $args | length) as $i
      | $args[$i] as $arg
      | if ($arg | IN($flags[])) then ($args[$i + 1] // empty)
        elif ($arg | test("^--[A-Za-z-]+=")) and (($arg | sub("=.*$"; "")) | IN($flags[])) then ($arg | sub("^[^=]*="; ""))
        elif ($arg | test("^-[A-Za-z]{2,}$")) and (("-" + $arg[-1:]) | IN($flags[])) then ($args[$i + 1] // empty)
        elif ($arg | test("^-[A-Za-z].")) and (($arg[0:2]) | IN($flags[])) then $arg[2:]
        else empty end ];

# The archive a tar in create, append or update mode writes: -f V, -cfV, --file[=]V, or the word
# after an old-style first argument holding f (`tar czf out.tgz src`). "-" is standard output.
def tar_archive_values($args):
  [ range(0; $args | length) as $i
    | $args[$i] as $arg
    | if $arg == "--file" then ($args[$i + 1] // empty)
      elif ($arg | startswith("--file=")) then $arg[7:]
      elif ($arg | test("^-[A-Za-z]*f$")) or ($i == 0 and ($arg | test("^[A-Za-z]*f[A-Za-z]*$"))) then ($args[$i + 1] // empty)
      elif ($arg | test("^-[A-Za-z]*f.")) then ($arg | sub("^-[A-Za-z]*?f"; ""))
      else empty end
    | select(. != "-") ];

def url_basename: sub("[?#].*$"; "") | split("/") | last;
def under_directory($directory): if $directory == "" then . else $directory + "/" + . end;

# Working directory of each command: cd and pushd with a literal target move it for the rest (a cd
# inside a subshell is treated as moving it for the rest, which only over-matches), and a
# command's own chdir (env -C, sudo -D, git -C) applies to it alone. RR3-8: cd -, a bare cd, popd,
# pushd with no directory or a stack index (+N, -N) and any tilde make it unresolved.
def with_directories($commands; $cwd):
  (reduce $commands[] as $command ({dir: $cwd, out: []};
     .dir as $current
     | (reduce (($command.chdir // [])[]) as $directory ($current; . as $base | $directory | resolve_directory($base))) as $here
     | .out += [$command + {dir: $here}]
     | if ($command.prog | IN("cd", "pushd")) then
         (($command.args | map(select(test("^-[A-Za-z@]+$") | not)) | first) // null) as $target
         | (if $target == null or $target == "-" or ($target | test("^[+-][0-9]+$")) then .dir = unresolved_directory
            else .dir = ($target | resolve_directory($here)) end)
       elif $command.prog == "popd" then .dir = unresolved_directory
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
       elif $prog == "patch" then ($positional[], option_values($args; "-d"; "--directory")[], output_option_values($prog; $args)[]) | {t: ., level: "all"}
       # RR3-10: more programs that write a named file.
       elif output_option_flags[$prog // ""] != null then output_option_values($prog; $args)[] | {t: ., level: "git"}
       elif $prog == "yq" and any($args[]; test("^(-[A-Za-z]*i[A-Za-z]*|--inplace)$")) then $positional[] | {t: ., level: "git"}
       elif $prog == "uniq" then ($args | positionals_skipping(["-f", "-s", "--skip-fields", "--skip-chars", "-w", "--check-chars"]))[1:2][] | {t: ., level: "git"}
       elif $prog == "xxd" then
         ($args | positionals_skipping(["-c", "-cols", "-g", "-groupsize", "-l", "-len", "-o", "-offset", "-s", "-seek", "-n", "-name"]))[1:2][] | {t: ., level: "git"}
       elif $prog | IN(file_editors[]) then $positional[] | {t: ., level: "git"}
       elif ($prog | IN("tar", "gtar", "bsdtar"))
            and (any($args[]; test("^(-[A-Za-z]*[cruA][A-Za-z]*|--(create|append|update|concatenate|catenate))$"))
                 or (($args[0] // "") | test("^[A-Za-z]*[cruA][A-Za-z]*$"))) then
         tar_archive_values($args)[] | {t: ., level: "git"}
       # zip writes its archive (the first operand) or, with -O, a new archive at that path.
       elif $prog == "zip" then
         ((($args | positionals_skipping(["-b", "-n", "-t", "-tt", "-O", "--output-file", "-TT", "-P"]) | first) // empty),
          option_values($args; "-O"; "--output-file")[]) | {t: ., level: "git"}
       elif $prog | IN(in_place_compressors[]) then
         (if any($args[]; test("^(-[A-Za-z0-9]*[clt][A-Za-z0-9]*|--(stdout|to-stdout|list|test))$")) then empty
          else ($positional[] | ., sub("(\\.(gz|z|bz2|xz|zst|tgz)|-gz)$"; "")) end) | {t: ., level: "git"}
       elif $prog == "split" then
         (($args | positionals_skipping(["-a", "-b", "-l", "-n", "-p", "-C", "--suffix-length", "--bytes", "--line-bytes", "--lines", "--number", "--additional-suffix", "--filter"]))[1] // "x") as $prefix
         | ($prefix + "*" + ((option_values($args; "--additional-suffix"; "--additional-suffix") | last) // "")) | {t: ., level: "git"}
       elif $prog == "csplit" then
         (((option_values($args; "-f"; "--prefix") | last) // "xx") + "*" + ((option_values($args; "-b"; "--suffix-format") | last) // "")) | {t: ., level: "git"}
       elif $prog == "mktemp" then
         ((option_values($args; "--suffix"; "--suffix") | last) // "") as $suffix
         | ($args | positionals_skipping(["-p", "--tmpdir", "-t", "--suffix"]))[] | (sub("X+$"; "*") + $suffix) | {t: ., level: "git"}
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
# P-1: Git accepts a long option abbreviated to any unambiguous prefix (`--har`), and a value joined
# with `=` (`--orphan=x`). An argument matches one of $names (full long options) when, without its
# `=value`, it is `--` plus at least one letter and a prefix of the name. Used only where a match adds
# an ask, never for an exemption; matching a prefix that Git would reject as ambiguous can only add an ask.
def git_long_option($names):
  sub("=.*$"; "") as $given | ($given | test("^--[a-z]")) and any($names[]; startswith($given));
# N6-1: git_expand_value_options($names) spells out an abbreviation that is a prefix of exactly one
# of $names, the subcommand's long options that take a value (keeping any `=value`), so value
# skipping and option tests see the full name. Callers judge both the original and the expanded
# arguments and keep the union, so a wrong expansion can only add an ask.
def git_expand_value_options($names):
  map(if test("^--[a-z][a-z-]*(=|$)") then
        capture("^(?<name>--[^=]*)(?<value>=.*)?$") as $parts
        | [ $names[] | select(startswith($parts.name)) ] as $hits
        | if ($hits | length) == 1 then $hits[0] + ($parts.value // "") else . end
      else . end);
# NR-4: --pathspec-from-file names paths this guard cannot read; as a destination it is a pattern.
# N6-1: abbreviated (`--pathspec-fr`) and `=`-joined spellings count too.
def git_pathspec_file($args):
  if any($args[]; git_long_option(["--pathspec-from-file"])) then [":(pathspec-from-file)"] else [] end;
# Seam (owner decision pending, WORK-001 fix round 3): branch switches (checkout <branch>, switch),
# merge, pull, rebase, cherry-pick, stash, no-ref whole-tree index restores (checkout -- ., restore .,
# reset --hard with no ref) and patch / git apply / git am from a file of unknown content keep their
# earlier behaviour: nothing below adds a decision for them. Add their rule here once decided.
# N6-1: judged on the original and the expanded arguments (git_expand_value_options); union.
def git_tree_ref_restore_one:
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
      # RR3-7: any clean removes untracked files inside tracked directories, so with no path it
      # reaches everything under its directory (the root asks), and so does `.`.
      ($args | positionals_skipping(["-e", "--exclude"])) as $paths
      | (if any($args[]; test("^-[A-Za-z]*[xXd][A-Za-z]*$")) then "git clean -x/-X/-d" else "git clean" end) as $label
      | if any($args[]; test(git_dry_run_regex)) then []
        else [ $paths[] | select(startswith(":")) | {op: "git clean <pathspec>", dest: .} ]
             + [ (if ($paths | length) > 0 then $paths[] else "." end) | {op: $label, dest: .} ] end
    elif .sub == "checkout-index" then
      (if any($args[]; test("^(-a|--all|--stdin|-[A-Za-z]*a[A-Za-z]*)$")) then
         [{op: "git checkout-index (all or from standard input)", dest: ((option_values($args; "--prefix"; "--prefix") | last) // ".")}]
       else [] end)
    elif .sub == "update-index" then
      (if any($args[]; test("^--(index-info|stdin)$")) then [{op: "git update-index (paths from standard input)", dest: "."}] else [] end)
    elif .sub == "hash-object" then
      (if any($args[]; test("^-[A-Za-z]*w[A-Za-z]*$")) and any($args[]; . == "--stdin-paths") then [{op: "git hash-object -w --stdin-paths", dest: "."}] else [] end)
    else [] end;
def git_tree_ref_restore:
  [ ., (.args |= git_expand_value_options(["--source", "--pathspec-from-file", "--conflict", "--orphan"])) ]
  | map(git_tree_ref_restore_one) | add | unique;
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
  # RR3-8: a tilde is never narrowed.
  | (($dest | test("[$`{]|[^\\x01-\\x7f]|^[:~]")) | not)
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
# RR3-9: Git and GNU patch quote unusual names C-style ("a/x\056y", \", \\, \t, \n). Escapes are
# decoded; an escaped byte outside ASCII becomes U+FFFD, which every path rule treats as a pattern
# character (it could be any look-alike), so the name is judged as unknown rather than skipped.
def c_unquote:
  if startswith("\"") and endswith("\"") and length >= 2 then
    .[1:-1]
    | gsub("\\\\(?<e>[0-7]{1,3}|.)";
        .e as $e
        | if ($e | test("^[0-7]+$")) then
            ($e | explode | reduce .[] as $digit (0; . * 8 + $digit - 48)) as $code
            | if $code > 0 and $code < 128 then ([$code] | implode) else "�" end
          elif $e == "t" then "\t" elif $e == "n" then "\n" elif $e == "r" then "\r"
          elif $e == "a" then "\u0007" elif $e == "b" then "\b" elif $e == "f" then "\f" elif $e == "v" then "\u000b"
          else $e end)
  else . end;
# A header name: a quoted C string, or text up to a tab (timestamps follow a tab).
def patch_header_name: if startswith("\"") then (capture("^(?<q>\"(?:[^\"\\\\]|\\\\.)*\")") | .q | c_unquote) else sub("\t.*$"; "") end;
def patch_paths:
  [ split("\n")[]
    | ((capture("^(?:\\+\\+\\+|---|\\*\\*\\*) (?<p>.+)$") | .p | patch_header_name),
       (capture("^diff --git (?<a>\"(?:[^\"\\\\]|\\\\.)*\"|[^ ]+) (?<b>\"(?:[^\"\\\\]|\\\\.)*\"|[^ ]+)") | (.a, .b) | c_unquote),
       (capture("^(?:rename|copy) (?:from|to) (?<p>.+)$") | .p | c_unquote),
       (capture("^Index: (?<p>.+)$") | .p))
    | select(. != "/dev/null" and length > 0) | ., sub("^[ab]/"; "") ] | unique;
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

# ---------------------------------------------------------------- state-changing Git (N6(a), Option B)
# Branch switches, merge, pull, rebase, cherry-pick, revert, stash and no-ref whole-tree restores
# replace tracked files, the authority store's .agents/specs state files among them. The guard does
# not inspect Git state at hook time (owner decision 2026-10-12, Option B, after re-review 4 NF-1),
# so it cannot show that the state is unaffected: each of these asks, from every caller. Forms that
# cannot replace tracked files get no item: checkout -b and switch -c from HEAD, restore and
# checkout of paths that cannot reach a protected path, reset without --hard, stash list or show.
# Ref restores of paths are judged by protected_tree_policy. Each item: {op, why}.
# RR3-4: options that take a value, per subcommand (-x and -s are flags of cherry-pick and revert,
# -m a flag of checkout, switch and rebase, and the mainline number of cherry-pick and revert).
def git_state_value_flags($sub):
  {"checkout": ["-b", "-B", "--orphan", "--conflict", "--pathspec-from-file"],
   "switch": ["-c", "-C", "--create", "--force-create", "--orphan", "--conflict"],
   "merge": ["-m", "-F", "--file", "-s", "--strategy", "-X", "--strategy-option", "--into-name"],
   "rebase": ["--onto", "-s", "--strategy", "-X", "--strategy-option", "-x", "--exec"],
   "cherry-pick": ["-m", "--mainline", "-X", "--strategy-option", "--strategy"],
   "revert": ["-m", "--mainline", "-X", "--strategy-option", "--strategy"],
   "stash": ["-m", "--message", "--pathspec-from-file"],
   "restore": ["-s", "--source", "--pathspec-from-file", "--conflict"],
   "reset": ["--pathspec-from-file"]}[$sub // ""] // [];
def git_state_items_one($context; $root):
  .sub as $sub | .args as $args
  # NF-2: a bare `-` is the previous branch (@{-1}), an operand, not an option.
  | ($args | map(if . == "-" then "@{-1}" else . end) | positionals_skipping(git_state_value_flags($sub))) as $operands
  | ([ range(0; $args | length) as $i | select($args[$i] == "--") | $i ] | first) as $dashes
  | ($context + {cwd: .dir, base: $context.cwd}) as $where
  | def reaches($dests): any($dests[]; protected_reach(.; $where; $root) != null);
    def has_long($names): any($args[]; git_long_option($names));
    def item($op): [{op: $op, why: "the guard does not inspect Git state, so it cannot show that the .agents/specs state files are unaffected"}];
    if $sub == "pull" then item("git pull")
    elif $sub == "checkout" then
      # With `--`, the paths decide, whatever ref comes before them.
      (if $dashes != null then (if reaches($args[$dashes + 1:]) then item("git checkout -- <paths>") else [] end)
       # N6-1: a pathspec file names paths the guard cannot read (with or without a ref).
       elif (git_pathspec_file($args) | length) > 0 then item("git checkout --pathspec-from-file")
       elif has_long(["--orphan"]) then item("git checkout --orphan")
       elif any($args[]; test("^(-b|-B)$")) then (if ($operands | length) > 0 then item("git checkout -b <start point>") else [] end)
       # One operand is a branch or a path; the guard cannot tell which, so it asks.
       elif ($operands | length) == 1 then item("git checkout <branch>")
       # RR3-7: checkout -f with no ref discards every local change.
       elif ($operands | length) == 0 and (any($args[]; . == "-f") or has_long(["--force"])) then item("git checkout -f")
       else [] end)
    elif $sub == "switch" then
      (if has_long(["--orphan"]) then item("git switch --orphan")
       elif ($operands | length) == 0 then []
       elif any($args[]; test("^(-c|-C)$")) or has_long(["--create", "--force-create"]) then item("git switch -c <start point>")
       else item("git switch") end)
    # merge and rebase with no operand use the upstream; --abort and --continue change files too.
    elif $sub == "merge" or $sub == "rebase" then item("git " + $sub)
    elif $sub == "cherry-pick" or $sub == "revert" then
      (if ($operands | length) > 0 or has_long(["--abort", "--quit", "--continue", "--skip"]) then item("git " + $sub) else [] end)
    elif $sub == "stash" then
      # P-2: the action is the first operand before `--` (`git stash -- <paths>` is a push). Only the
      # actions that leave the working tree alone get no item.
      ((($args[0:($dashes // ($args | length))] | positionals_skipping(git_state_value_flags($sub)) | first) // "push") as $action
       | if $action | IN("list", "show", "drop", "clear", "create", "store") then []
         else item("git stash " + (if $action | IN("pop", "apply", "branch", "save") then $action else "push" end)) end)
    elif $sub == "restore" then
      # Only the index (--staged without --worktree) leaves files alone; with or without --source,
      # paths that can reach a protected path ask.
      # The exemption needs the exact spelling: prefix matching only ever adds an ask.
      (if any($args[]; . == "-S" or . == "--staged") and ((any($args[]; . == "-W") or has_long(["--worktree"])) | not) then []
       elif reaches([ ($args | positionals_skipping(["--pathspec-from-file"]))[], git_pathspec_file($args)[] ]) then item("git restore <paths>")
       else [] end)
    # F5-1: a hard, merge or keep reset replaces tracked files whatever it resets to (`-` included).
    elif $sub == "reset" then
      (if has_long(["--hard", "--merge", "--keep"]) then item("git reset --hard") else [] end)
    else [] end;
# N6-1: judged on the original and the expanded arguments (git_expand_value_options); union.
def git_state_items($context; $root):
  ([ git_state_value_flags(.sub)[] | select(startswith("--")) ] + ["--source"]) as $names
  | [ ., (.args |= git_expand_value_options($names)) ] | map(git_state_items_one($context; $root)) | add | unique_by(.op);

# Every state-changing Git command in the submission, in order: [{op, why}].
def git_state_policy($cmds; $context; $root):
  [ $cmds[] | select(.prog == "git") | git_state_items($context; $root)[] ];

# ---------------------------------------------------------------- shell-edit hint
# "hint" (certain), "check" (redirection targets the wrapper tests for existence: a redirection
# counts only when it overwrites an existing regular file; no Git is run) or "none".
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
    elif ($state | length) > 0 then protected_ask($state[0].op; $state[0].why)
    elif $agent | IN(implementation_agents[]) then
      shell_edit_hint($cmds) as $edit
      | $compound + {hint: $edit.hint, hintTargets: $edit.targets}
    else $compound + {hint: "none", hintTargets: []} end;
