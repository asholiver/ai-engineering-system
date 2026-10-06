# Guard v2 classifier: turns parsed commands into operations with classes, using the tables
# in tables.jq. It decides nothing. policy.jq turns the result into ask, deny or no decision.
#
# Result of parse_script: {units: [{kind, ops, cmds}], uncertain}
#   unit   one pipeline (a command list joined by |), plus the units of any shell text it
#          runs (bash -c, eval, ssh) appended after it
#   kind   "eff" (does something), "ctx" (only sets up the environment) or "none"
#   ops    [{l: operation text, c: [classes]}], at most one per command
#   cmds   [{prog, sub, args, redirs, stdin}] for every command (see command_facts), so policy
#          can reason about programs, arguments and redirections
include "lexer";
include "tables";

# ---------------------------------------------------------------- argument helpers
def positionals: map(select(startswith("-") | not));
def has_word($words; $word): ($words | index($word)) != null;

# Index of the first non-flag word; flags in $value_flags consume the next word.
def skip_flags_s($words; $value_flags):
  {i: 0, done: false}
  | until(.done or .i >= ($words | length);
      $words[.i] as $word
      | if $word == "--" then .i += 1 | .done = true
        elif ($word | startswith("-")) and ($word | length) > 1 then
          (if has_word($value_flags; $word) then .i += 2 else .i += 1 end)
        else .done = true end)
  | .i;

def skip_flags($words; $value_flags): skip_flags_s($words | map(.l); $value_flags);

def before_double_dash: (index("--")) as $at | if $at == null then . else .[0:$at] end;

# {name, path, dynamic} for a command word. A path with a dynamic directory part
# ("$PLUGIN/scripts/run.sh") is a script call, not a dynamic program name.
def program_of:
  . as $word
  | ($word.l | contains("/")) as $has_path
  | (if $has_path then ($word.l | split("/") | last) else $word.l end) as $base
  | {name: $base, path: $has_path,
     dynamic: ((if ($word.l | IN("[", "[[")) then false
                elif $has_path then ($base | test("[$`*?\\[]"))
                else $word.d end) or $base == "")};

# ---------------------------------------------------------------- wrappers
def drop_assignments:
  . as $words
  | ({i: 0, done: false}
     | until(.done or .i >= ($words | length);
         if ($words[.i].l | test("^[A-Za-z_][A-Za-z0-9_]*=")) then .i += 1 else .done = true end)
     | .i) as $count
  | $words[$count:];

# Strips wrappers (sudo, env, time, xargs, npx, pnpm exec, ...) and returns the words of the
# wrapped command; lookup is true for `command -v`, which executes nothing.
def unwrap($words):
  {ws: $words, lookup: false, n: 0, stop: false}
  | until(.stop or .n >= 8 or (.ws | length) == 0;
      .n += 1
      | (.ws[0] | program_of) as $program
      | (if $program.dynamic then null else wrappers[$program.name] end) as $spec
      | if $spec == null then .stop = true
        else
          (.ws[1:]) as $rest
          | if $spec.lookup != null and any($rest[]; .l | IN($spec.lookup[])) then .lookup = true | .ws = []
            elif $spec.sub != null then
              skip_flags($rest; $spec.vf // []) as $at
              | ($rest[$at].l // null) as $subcommand
              | if $subcommand != null and ($subcommand | IN($spec.sub[])) then
                  ($rest[$at + 1:]) as $after
                  | if $spec.dashdash then
                      ([ range(0; $after | length) as $j | select($after[$j].l == "--") | $j ] | first) as $dashes
                      | if $dashes == null then .stop = true else .ws = $after[$dashes + 1:] end
                    else .ws = $after[skip_flags($after; $spec.vf // []):] end
                else .stop = true end
            else
              skip_flags($rest; $spec.vf // []) as $at
              | ($rest[$at:]) as $after
              | (if $spec.assign then ($after | drop_assignments) else $after end) as $stripped
              | .ws = (if $spec.skip != null then $stripped[$spec.skip:] else $stripped end)
            end
        end);

# ---------------------------------------------------------------- context commands
def is_context($program; $args):
  ($program | IN(context_programs[]))
  or ($program == "nvm" and has_word($args; "use"))
  or ($program == "corepack" and has_word($args; "enable"))
  or (($program | IN("source", ".")) and ((($args | positionals | first) // "") | test(activation_script_regex)));

# ---------------------------------------------------------------- table rules
def sequence_match($words; $sequence):
  ($sequence | length) as $count
  | ([ range(0; ($words | length) - $count + 1) as $k
       | select(all(range(0; $count) as $j | ($words[$k + $j] | IN($sequence[$j][])); .))
       | $k ] | first) as $found
  | if $found == null then null else ($words[$found:$found + $count] | join(" ")) end;

# The matched verb text for a table rule, or null.
def rule_match($rule; $args):
  ($args | positionals) as $words
  | (if $rule.any != null then ([ $words[] | select(IN($rule.any[])) ] | first)
     elif $rule.seq != null then sequence_match($words; $rule.seq)
     elif $rule.re != null then ([ $words[] | select(test($rule.re)) ] | first)
     else null end) as $matched
  | if $matched != null and $rule.with != null
    then (if all($rule.with[]; . as $required | has_word($args; $required)) then $matched else null end)
    else $matched end;

def rule_ops($program; $args):
  [ rules[] | select(.p | index($program)) | . as $rule
    | rule_match($rule; $args) as $verb
    | select($verb != null)
    | {l: ($program + " " + $verb), c: $rule.c} ];

# ---------------------------------------------------------------- git
def git_parts($args):
  skip_flags_s($args; git_value_flags) as $at
  | {sub: ($args[$at] // null), rest: ($args[$at + 1:])};

def git_push_ops($rest; $branch):
  ($rest | positionals) as $words
  | (any($rest[]; test("^--(force|force-with-lease|force-if-includes|mirror|delete|prune)(=.*)?$") or test("^-[A-Za-z]*[fd][A-Za-z]*$"))
     or any($words[]; length > 1 and (startswith("+") or startswith(":")))) as $force
  | any($words[]; test("^([^:]*:)?(refs/heads/)?(main|master)$")) as $protected
  | (has_word($rest; "--tags") or any($words[]; contains("refs/tags/"))) as $tags
  | ($branch | IN("main", "master")) as $on_protected
  | ([ (if $force then "force or delete" else empty end),
       (if $protected then "main/master" else empty end),
       (if $tags then "tags" else empty end),
       (if $on_protected and ($protected | not) then "while on " + $branch else empty end) ]) as $why
  | if ($why | length) == 0 then []
    else [{l: ("git push (" + ($why | join(", ")) + ")"),
           c: ([ (if $force then "git-force-push" else empty end),
                 (if $protected or $on_protected then "git-main-push" else empty end),
                 (if $tags then "git-tag-push" else empty end) ])}] end;

def git_ops($args; $branch):
  git_parts($args) as $git
  | if $git.sub == "push" then git_push_ops($git.rest; $branch) else [] end;

# ---------------------------------------------------------------- HTTP
def short_cluster_value_index($letters):
  first(range(0; $letters | length) as $j | select(curl_value_letters | contains($letters[$j])) | $j) // null;

def curl_request($args):
  ($args | length) as $count
  | {i: 0, method: null, body: false, get: false, head: false, upload: false, urls: []}
  | until(.i >= $count;
      $args[.i] as $arg
      | if $arg == "--" then .urls += $args[.i + 1:] | .i = $count
        elif ($arg | startswith("--")) then
          ($arg | sub("=.*$"; "")) as $name
          | ($arg | contains("=")) as $attached
          | (if $attached then ($arg | sub("^[^=]*="; "")) else ($args[.i + 1] // "") end) as $value
          | (if $attached then 1 else 2 end) as $width
          | if $name == "--request" then .method = $value | .i += $width
            elif has_word(curl_body_long; $name) then .body = true | .i += $width
            elif $name == "--upload-file" then .upload = true | .i += $width
            elif $name == "--url" then .urls += [$value] | .i += $width
            elif $name == "--get" then .get = true | .i += 1
            elif $name == "--head" then .head = true | .i += 1
            elif has_word(curl_value_long; $name) then .i += $width
            else .i += 1 end
        elif ($arg | startswith("-")) and ($arg | length) > 1 then
          ($arg[1:] | explode | map([.] | implode)) as $letters
          | short_cluster_value_index($letters) as $at
          | (if $at == null then $letters else $letters[0:$at] end) as $plain
          | (if has_word($plain; "G") then .get = true else . end)
          | (if has_word($plain; "I") then .head = true else . end)
          | if $at == null then .i += 1
            else
              $letters[$at] as $letter
              | ($arg[$at + 2:]) as $attached
              | (if ($attached | length) > 0 then $attached else ($args[.i + 1] // "") end) as $value
              | (if ($attached | length) > 0 then 1 else 2 end) as $width
              | (if $letter == "X" then .method = $value
                 elif $letter == "d" or $letter == "F" then .body = true
                 elif $letter == "T" then .upload = true
                 else . end)
              | .i += $width
            end
        else .urls += [$arg] | .i += 1 end)
  | {method: (if .method != null then (.method | ascii_upcase)
              elif .head then "HEAD" elif .get then "GET" elif .upload then "PUT" elif .body then "POST" else "GET" end),
     urls: .urls};

def wget_request($args):
  ($args | length) as $count
  | {i: 0, method: null, body: false, urls: []}
  | until(.i >= $count;
      $args[.i] as $arg
      | if ($arg | startswith("-")) and ($arg | length) > 1 then
          ($arg | sub("=.*$"; "")) as $name
          | ($arg | contains("=")) as $attached
          | (if $attached then ($arg | sub("^[^=]*="; "")) else ($args[.i + 1] // "") end) as $value
          | (if $attached or (has_word(wget_value_flags; $name) | not) then 1 else 2 end) as $width
          | (if $name == "--method" then .method = $value
             elif $name | IN("--post-data", "--post-file", "--body-data", "--body-file") then .body = true
             else . end)
          | .i += $width
        else .urls += [$arg] | .i += 1 end)
  | {method: (if .method != null then (.method | ascii_upcase) elif .body then "POST" else "GET" end), urls: .urls};

# gh api / glab api: $args are the arguments after "api".
def gh_api_request($args):
  ($args | length) as $count
  | {i: 0, method: null, body: false, urls: []}
  | until(.i >= $count;
      $args[.i] as $arg
      | if ($arg | startswith("--")) then
          ($arg | sub("=.*$"; "")) as $name
          | ($arg | contains("=")) as $attached
          | (if $attached then ($arg | sub("^[^=]*="; "")) else ($args[.i + 1] // "") end) as $value
          | (if $attached or (has_word(gh_api_value_flags; $name) | not) then 1 else 2 end) as $width
          | (if $name == "--method" then .method = $value
             elif has_word(gh_api_body_flags; $name) then .body = true
             else . end)
          | .i += $width
        elif ($arg | startswith("-")) and ($arg | length) > 1 then
          ($arg[0:2]) as $flag
          | (if ($arg | length) > 2 then ($arg[2:]) else ($args[.i + 1] // "") end) as $value
          | (if ($arg | length) > 2 or (has_word(gh_api_value_flags; $flag) | not) then 1 else 2 end) as $width
          | (if $flag == "-X" then .method = $value
             elif has_word(gh_api_body_flags; $flag) then .body = true
             else . end)
          | .i += $width
        else (if (.urls | length) == 0 then .urls += [$arg] else . end) | .i += 1 end)
  | {method: (if .method != null then (.method | ascii_upcase) elif .body then "POST" else "GET" end), urls: .urls};

# httpie / xh: [METHOD] URL [items]. key=value and key:=json items make it a POST.
def httpie_request($args):
  ($args | length) as $count
  | {i: 0, words: []}
  | until(.i >= $count;
      $args[.i] as $arg
      | if ($arg | startswith("-")) and ($arg | length) > 1 then
          .i += (if has_word(httpie_value_flags; $arg) then 2 else 1 end)
        else .words += [$arg] | .i += 1 end)
  | .words as $words
  | (if ($words | length) > 0 and ($words[0] | ascii_upcase | IN(http_methods[])) then ($words[0] | ascii_upcase) else null end) as $method
  | (if $method == null then $words else $words[1:] end) as $rest
  | ($rest[1:] | any(.[]; test("^[A-Za-z0-9_.\\[\\]-]+(:=|=[^=]|=$|@)"))) as $body
  | {method: ($method // (if $body then "POST" else "GET" end)), urls: ($rest[0:1])};

def http_ops($program; $args):
  (if $program == "curl" then curl_request($args)
   elif $program == "wget" then wget_request($args)
   elif ($program | IN("http", "https", "xh", "xhs")) then httpie_request($args)
   elif ($program | IN("gh", "glab")) and (($args | positionals | first) == "api") then
     gh_api_request(($args | .[(index("api") + 1):]))
   else null end) as $request
  | if $request == null then []
    else
      ([ $request.urls[] | endpoint_classes($request.method; .)[] ] | unique) as $classes
      | if ($classes | length) == 0 then []
        else
          ($request.urls[0] | sub("^[a-zA-Z][a-zA-Z0-9+.-]*://[^/]*"; "") | sub("[?#].*$"; "") | .[0:80]) as $path
          | [{l: ($program + " " + $request.method + " " + $path), c: $classes}]
        end
    end;

# ---------------------------------------------------------------- deploy tasks and scripts
def production_flags($args):
  has_word($args; "--prod") or has_word($args; "--production") or has_word($args; "--target=production")
  or has_word($args; "--prodIfUnlocked") or has_word($args; "--prod-if-unlocked")
  or any(range(0; ($args | length) - 1) as $j | ($args[$j] == "--target" and $args[$j + 1] == "production"); .);

def vercel_ops($program; $args):
  skip_flags_s($args; vercel_value_flags) as $at
  | ($args[$at] // null) as $subcommand
  | if any($args[]; IN("--help", "-h", "--version", "-v")) then []
    elif $subcommand != null and ($subcommand | IN(vercel_non_deploy_subcommands[])) then []
    elif $subcommand == "promote" or $subcommand == "rollback" then [{l: ($program + " " + $subcommand), c: ["production-deploy"]}]
    elif production_flags($args) then [{l: ($program + " deploy --prod"), c: ["production-deploy"]}]
    else [{l: ($program + " deploy"), c: ["ephemeral-deploy"]}] end;

def netlify_ops($program; $args):
  skip_flags_s($args; netlify_value_flags) as $at
  | if ($args[$at] // null) == "deploy" then
      (if production_flags($args) or has_word($args; "-p")
       then [{l: ($program + " deploy --prod"), c: ["production-deploy"]}]
       else [{l: ($program + " deploy"), c: ["ephemeral-deploy"]}] end)
    else [] end;

def task_ops($program; $args):
  if (has_word(task_runners_packages; $program) or has_word(task_runners_other; $program)) then
    ($args | before_double_dash | positionals) as $words
    | if has_word(task_runners_packages; $program) and ((($words | first) // "") | IN(package_non_task_subcommands[])) then []
      else
        ([ $words[] | select(. != "publish" and test(deploy_word_regex + "|" + destroy_word_regex; "i")) ] | first) as $hit
        | if $hit == null then []
          else [{l: ($program + " " + $hit),
                 c: (if ($hit | test(deploy_word_regex; "i")) then ["unclassified-deploy"] else ["destructive-task"] end)}] end
      end
  else [] end;

def script_ops($program; $path; $args):
  skip_flags_s($args; []) as $at
  | ($args[0:$at] | any(.[]; test("^-[A-Za-z]*[ce]$"))) as $inline_code
  | [ (if $path then $program else empty end),
      (if has_word(script_runners; $program) and ($inline_code | not) then
         (($args[$at:][0:1][] | select(contains("/")) | split("/") | last) // empty)
       else empty end) ] as $names
  | [ $names[] | select(test(deploy_word_regex + "|" + destroy_word_regex; "i")) ] as $hits
  | if ($hits | length) == 0 then []
    else [{l: (if $path and $hits[0] == $program then $program else $program + " " + $hits[0] end),
           c: [ (if ($hits[0] | test(deploy_word_regex; "i")) then "unclassified-deploy" else empty end),
                (if ($hits[0] | test(destroy_word_regex; "i")) then "destructive-task" else empty end) ]}] end;

# ---------------------------------------------------------------- data scanning
def sql_ops($program; $args; $stdin):
  if has_word(sql_clients; $program) or ($program == "turso" and has_word($args; "shell")) then
    ([ $args[], $stdin[] ] | join("\n")) as $text
    | if ($text | test(sql_destructive_regex; "i")) or ($program == "mongosh" and ($text | test(mongo_destructive_regex)))
      then [{l: ($program + " (destructive SQL)"), c: ["destructive-sql"]}] else [] end
  elif ($program | test(interpreters_regex)) then
    ($args | length) as $count
    | ([ range(0; $count) as $j | select($args[$j] | test("^(-[A-Za-z]*[cepr]|--eval|--print|--command)$")) | $args[$j + 1] // empty ]
       + [ $args[] | select(test("^--(eval|print|command)=")) | sub("^[^=]*="; "") ]
       + $stdin) as $code
    | if ($code | join("\n") | test(interpreter_sql_destructive_regex; "i"))
      then [{l: ($program + " inline code (destructive SQL)"), c: ["destructive-sql"]}] else [] end
  else [] end;

# Shell text this command runs: {text} (bash -c, eval, ssh), {stdin: true} (bash reading
# standard input) or null.
def shell_run($program; $args):
  if has_word(shells; $program) then
    skip_flags_s($args; []) as $at
    | if ($args[0:$at] | any(.[]; test("^-[A-Za-z]*c[A-Za-z]*$"))) then
        (if $args[$at] != null then {text: $args[$at]} else null end)
      elif $args[$at] == null then {stdin: true}
      else null end
  elif $program == "eval" then {text: ($args | join(" "))}
  elif $program == "ssh" then
    skip_flags_s($args; ssh_value_flags) as $at
    | if ($args | length) > $at + 1 then {text: ($args[$at + 1:] | join(" "))} else null end
  else null end;

def merge_ops:
  if length == 0 then null
  else {l: .[0].l, c: ([ .[].c[] ] | unique)} end;

def classify_invocation($program; $path; $args; $stdin; $branch):
  ( rule_ops($program; $args)
    + (if $program == "git" then git_ops($args; $branch) else [] end)
    + http_ops($program; $args)
    + (if ($program | IN("vercel", "vc")) then vercel_ops($program; $args) else [] end)
    + (if ($program | IN("netlify", "ntl")) then netlify_ops($program; $args) else [] end)
    + task_ops($program; $args)
    + script_ops($program; $path; $args)
    + sql_ops($program; $args; $stdin) ) | merge_ops;

# ---------------------------------------------------------------- command analysis
def own_stdin($command):
  [ $command.r[] | select(.op == "<<") | .body ] + [ $command.r[] | select(.op == "<<<") | .t ];

# Everything earlier commands in the same pipeline could feed in.
def producer_texts($before):
  [ $before[] | ([ .r[] | select(.op == "<<") | .body ] + [ ([ .w[].l ] | join(" ")) ])[] ];

# Text an echo or printf earlier in the pipeline would feed to a shell.
def echoed_texts($before):
  [ $before[] | select(.w[0].l | IN("echo", "printf"))
    | ([ .w[1:][].l ] | map(select(startswith("-") | not))) as $words
    | if .w[0].l == "printf" and ($words | length) > 0 and ($words[0] | contains("%")) then ($words[1:] | join("\n"))
      else ($words | join(" ")) end ];

# Facts about one command for policy.jq: program (lower case), Git subcommand, the arguments
# after the program (after the Git subcommand for Git), redirections (heredoc bodies left out)
# and the text fed to it on standard input (heredoc bodies and here-strings).
def redirect_facts($command): [ $command.r[] | {op: .op, t: .t, d: (.d // false)} ];

def command_facts($command; $program; $args; $git):
  [{prog: ($program | ascii_downcase), sub: (if ($program | ascii_downcase) == "git" then $git.sub else null end),
    args: (if ($program | ascii_downcase) == "git" then $git.rest else $args end),
    redirs: redirect_facts($command), stdin: own_stdin($command)}];

# A command with no program of its own (only redirections, or only a lookup) still carries its redirections.
def redirect_only_facts($command):
  if ($command.r | length) > 0 then [{prog: null, sub: null, args: [], redirs: redirect_facts($command), stdin: []}] else [] end;

# Analyses one parsed command. Substitution commands it contains are analysed too and
# their operations belong to it. Shell text it runs is parsed into extra units.
def parse_script($text; $depth; $branch):
  def analyse($command; $before):
    (reduce range(0; $command.n | length) as $i ({ops: [], extra: [], cmds: [], unc: false};
       analyse($command.n[$i]; $command.n[0:$i]) as $inner
       | .ops += $inner.ops | .extra += $inner.extra | .cmds += $inner.cmds | .unc = (.unc or $inner.unc))) as $nested
    | ( if ($command.w | length) == 0 then
          {kind: (if $command.hdr == "loop" then "eff"
                  elif ($command.a | length) > 0 and ($command.r | length) == 0 then "ctx"
                  elif ($command.r | length) > 0 then "eff"
                  else "none" end),
           ops: [], extra: [], cmds: redirect_only_facts($command), unc: false}
        else
          unwrap($command.w) as $unwrapped
          | if $unwrapped.lookup or ($unwrapped.ws | length) == 0 then {kind: "none", ops: [], extra: [], cmds: redirect_only_facts($command), unc: false}
            else
              ($unwrapped.ws[0] | program_of) as $program
              | if $program.dynamic then {kind: "eff", ops: [], extra: [], cmds: [], unc: true}
                else
                  ($unwrapped.ws[1:] | map(.l)) as $args
                  | (own_stdin($command) + producer_texts($before)) as $stdin
                  | classify_invocation($program.name; $program.path; $args; $stdin; $branch) as $op
                  | shell_run($program.name; $args) as $run
                  | (if $run == null then null
                     elif $run.text != null then $run.text
                     else (own_stdin($command) + echoed_texts($before)) | join("\n") end) as $inner_text
                  | (if $inner_text != null and $inner_text != "" then parse_script($inner_text; $depth + 1; $branch) else null end) as $inner
                  | {kind: (if $inner != null then
                              # Text piped in by echo/printf is the shell's input, not separate work.
                              (if $run.stdin == true and ([ $before[] | select((.w[0].l | IN("echo", "printf")) | not) ] | length) == 0 then "absorb" else "none" end)
                            elif is_context($program.name; $args) and $op == null then "ctx" else "eff" end),
                     ops: (if $op == null then [] else [$op] end),
                     extra: (if $inner != null then $inner.units else [] end),
                     cmds: command_facts($command; $program.name; $args; (if ($program.name | ascii_downcase) == "git" then git_parts($args) else null end)),
                     unc: ($inner != null and $inner.uncertain)}
                end
            end
        end ) as $own
    | {kind: $own.kind, ops: ($own.ops + $nested.ops), extra: ($own.extra + $nested.extra),
       cmds: ($own.cmds + $nested.cmds), unc: ($own.unc or $nested.unc)};

  if $depth >= 6 then {units: [], uncertain: true}
  else
    parse_raw($text; $depth) as $raw
    | reduce $raw.units[] as $unit ({units: [], uncertain: $raw.uncertain};
        (reduce range(0; $unit | length) as $i ({ops: [], extra: [], cmds: [], kinds: [], unc: false};
           analyse($unit[$i]; $unit[0:$i]) as $result
           | .ops += $result.ops | .extra += $result.extra | .cmds += $result.cmds
           | .kinds += [$result.kind] | .unc = (.unc or $result.unc))) as $unit_result
        | ((if has_word($unit_result.kinds; "absorb") then "none"
             elif has_word($unit_result.kinds; "eff") then "eff" elif has_word($unit_result.kinds; "ctx") then "ctx" else "none" end)) as $kind
        | .uncertain = (.uncertain or $unit_result.unc)
        | .units += (if $kind == "none" and ($unit_result.ops | length) == 0 and ($unit_result.cmds | length) == 0 then []
                     else [{kind: $kind, ops: $unit_result.ops, cmds: $unit_result.cmds}] end)
        | .units += $unit_result.extra)
  end;
