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

# A flag takes the next word as its value: listed in $value_flags, or a cluster of short flags
# whose last letter is one (`sudo -iu root`, `xargs -0n 1`).
def consumes_value($word; $value_flags):
  has_word($value_flags; $word)
  or (($word | test("^-[A-Za-z]{2,}$")) and has_word($value_flags; "-" + $word[-1:]));

# Index of the first non-flag word; flags in $value_flags consume the next word.
def skip_flags_s($words; $value_flags):
  {i: 0, done: false}
  | until(.done or .i >= ($words | length);
      $words[.i] as $word
      | if $word == "--" then .i += 1 | .done = true
        elif ($word | startswith("-")) and ($word | length) > 1 then
          (if consumes_value($word; $value_flags) then .i += 2 else .i += 1 end)
        else .done = true end)
  | .i;

def skip_flags($words; $value_flags): skip_flags_s($words | map(.l); $value_flags);

# The flag words and the first non-flag word of a command's words, flag values left out: the
# words that can decide which operation runs.
def prefix_words($words; $value_flags):
  {i: 0, done: false, out: []}
  | until(.done or .i >= ($words | length);
      $words[.i] as $word
      | if $word.l == "--" then .done = true
        elif ($word.l | startswith("-")) and ($word.l | length) > 1 then
          .out += [$word] | (if consumes_value($word.l; $value_flags) then .i += 2 else .i += 1 end)
        else .out += [$word] | .done = true end)
  | .out;

# Non-flag words, skipping the values of flags that take one.
def positionals_skipping($value_flags):
  . as $words
  | {i: 0, out: []}
  | until(.i >= ($words | length);
      $words[.i] as $word
      | if $word == "--" then .i += 1
        elif $word | startswith("-") then (if consumes_value($word; $value_flags) then .i += 2 else .i += 1 end)
        else .out += [$word] | .i += 1 end)
  | .out;

# Flag words, leaving out the values of flags that take one.
def flags_skipping($value_flags):
  . as $words
  | {i: 0, out: []}
  | until(.i >= ($words | length);
      $words[.i] as $word
      | if $word == "--" then .i += 1
        elif $word | startswith("-") then .out += [$word] | (if consumes_value($word; $value_flags) then .i += 2 else .i += 1 end)
        else .i += 1 end)
  | .out;

def shell_quote: "'" + gsub("'"; "'\\''") + "'";

def before_double_dash: (index("--")) as $at | if $at == null then . else .[0:$at] end;

# {name, path, dynamic} for a command word. A path with a dynamic directory part
# ("$PLUGIN/scripts/run.sh") is a script call, not a dynamic program name.
# The name is lower case (a case-insensitive file system runs `GIT` and `Terraform`), loses a
# package version (`vercel@latest`) and maps package names to binaries (`netlify-cli`).
def program_of:
  . as $word
  | ($word.l | contains("/")) as $has_path
  | (if $has_path then ($word.l | split("/") | last) else $word.l end) as $raw_base
  | ($raw_base | ascii_downcase | if test("^[^@]+@[^@/]*$") then sub("@[^@/]*$"; "") else . end) as $lowered
  | (program_aliases[$lowered] // $lowered) as $base
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
#
# Also returns: texts (shell text a wrapper runs: env -S, su -c, script -c, flock -c, nix-shell
# --run, watch, parallel templates), names (the wrappers passed through), unc (input unknown).
def flag_texts($words; $flags):
  [ range(0; $words | length) as $i
    | $words[$i].l as $word
    | if has_word($flags; $word) then ($words[$i + 1].l // empty)
      elif ($word | test("^--[A-Za-z-]+=")) and has_word($flags; ($word | sub("=.*$"; ""))) then ($word | sub("^[^=]*="; ""))
      elif ($word | test("^-[A-Za-z].")) and has_word($flags; $word[0:2]) then $word[2:]
      else empty end ];

def parallel_texts($after):
  ([ range(0; $after | length) as $j | select($after[$j].l | IN(":::", "::::")) | $j ] | first) as $at
  | (if $at == null then $after else $after[0:$at] end | map(.l)) as $template
  | (if $at == null then [] else $after[$at + 1:] | map(.l) end) as $arguments
  | if ($template | length) == 0 then {texts: [], unc: true}
    # `parallel {} ::: 'cmd'`: the arguments are the commands.
    else {texts: (if ($template[0] | test("^\\{.*\\}$")) then $arguments else [ ($template | map(shell_quote) | join(" ")) ] end), unc: false} end;

def unwrap($words):
  {ws: $words, lookup: false, n: 0, stop: false, texts: [], names: [], unc: false}
  | until(.stop or .n >= 8 or (.ws | length) == 0;
      .n += 1
      # `docker compose exec` is the docker-compose program.
      | (if (.ws | length) > 1 and ((.ws[0] | program_of).name == "docker") and .ws[1].l == "compose"
         then .ws = [(.ws[0] | .l = "docker-compose")] + .ws[2:] else . end)
      | (.ws[0] | program_of) as $program
      | (if $program.dynamic then null else wrappers[$program.name] end) as $spec
      | if $spec == null then .stop = true
        else
          (.ws[1:]) as $rest
          | .names += [$program.name]
          | if $spec.lookup != null and any($rest[]; .l | IN($spec.lookup[])) then .lookup = true | .ws = []
            elif $spec.coproc then
              # `coproc NAME { cmd; }` or `coproc cmd`
              .ws = (if ($rest | length) >= 2 and $rest[1].l == "{" then $rest[2:] else $rest end)
            elif $spec.joined then
              skip_flags($rest; $spec.vf // []) as $at
              | .texts += [ $rest[$at:] | map(.l) | join(" ") ] | .ws = []
            elif $spec.parallel then
              skip_flags($rest; $spec.vf // []) as $at
              | parallel_texts($rest[$at:]) as $found
              | .texts += $found.texts | .unc = (.unc or $found.unc) | .ws = []
            elif $spec.sub != null then
              skip_flags($rest; $spec.vf // []) as $at
              | ($rest[$at].l // null) as $subcommand
              | if $subcommand != null and ($subcommand | IN($spec.sub[])) then
                  ($rest[$at + 1:]) as $after
                  | ([ range(0; $after | length) as $j | select($after[$j].l == "--") | $j ] | first) as $dashes
                  | if ($spec.dashdash or $spec.dashdash_optional) and $dashes != null then .ws = $after[$dashes + 1:]
                    elif $spec.dashdash then .stop = true
                    else .ws = $after[(skip_flags($after; $spec.vf // []) + ($spec.subskip // 0)):] end
                else .stop = true end
            else
              skip_flags($rest; $spec.vf // []) as $at
              | ($rest[$at:]) as $after
              | (if $spec.tf != null then flag_texts($rest; $spec.tf) else [] end) as $found
              | if ($found | length) > 0 then .texts += $found | .ws = []
                elif $spec.noexec then .ws = []
                else
                  (if $spec.assign then ($after | drop_assignments) else $after end) as $stripped
                  | .ws = (if $spec.skip != null then $stripped[$spec.skip:] else $stripped end)
                end
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
  ($args | positionals_skipping($rule.vf // [])) as $words
  | (if $rule.always == true then ""
     elif $rule.any != null then ([ $words[] | select(IN($rule.any[])) ] | first)
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
    | {l: ([$program, $verb] | map(select(length > 0)) | join(" ")), c: $rule.c} ];

# ---------------------------------------------------------------- git
def git_parts($args):
  skip_flags_s($args; git_value_flags) as $at
  | {sub: ($args[$at] // null), rest: ($args[$at + 1:]), globals: ($args[0:$at])};

# Aliases defined by this very command: -c alias.NAME=VALUE (value known) and
# --config-env=alias.NAME=VAR (value comes from the environment, so unknown).
def git_inline_aliases($args):
  skip_flags_s($args; git_value_flags) as $at
  | [ range(0; $at) as $i
      | $args[$i] as $word
      | if $word == "-c" then ($args[$i + 1] // "" | select(test("^alias\\.[^=]+="; "i"))
                               | {name: (.[6:] | sub("=.*$"; "") | ascii_downcase), value: (sub("^[^=]*="; "")), unknown: false})
        elif $word == "--config-env" then ($args[$i + 1] // "" | select(test("^alias\\.[^=]+="; "i"))
                                           | {name: (.[6:] | sub("=.*$"; "") | ascii_downcase), value: "", unknown: true})
        elif ($word | startswith("--config-env=alias.")) then ($word[13:] | {name: (.[6:] | sub("=.*$"; "") | ascii_downcase), value: "", unknown: true})
        else empty end ];

# Follows inline aliases: {args: the arguments with the alias expanded, text: shell text of a
# `!` alias, unc: not resolvable (environment-defined alias, loop, or a word that is neither a
# Git command nor an inline alias, which may be an alias configured elsewhere)}.
def git_resolved($args):
  {args: $args, text: null, unc: false, n: 0, done: false}
  | until(.done or .n >= 4;
      .n += 1
      | git_parts(.args) as $git
      | ([ git_inline_aliases(.args)[] | select(.name == (($git.sub // "") | ascii_downcase)) ] | first) as $hit
      | if $hit == null then .done = true
        elif $hit.unknown then .unc = true | .done = true
        elif ($hit.value | startswith("!")) then
          .text = ($hit.value[1:] + (if ($git.rest | length) > 0 then " " + ($git.rest | map(shell_quote) | join(" ")) else "" end))
          | .done = true
        else .args = ([ $hit.value | scan("[^\\s]+") ] + $git.rest) end)
  | .unc = (.unc or (.done | not))
  | git_parts(.args) as $final
  | .unc = (.unc or (.text == null and $final.sub != null and ($final.sub | IN(git_commands[]) | not)))
  | {args: .args, text: .text, unc: .unc};

def git_push_ops($rest; $branch):
  ($rest | positionals) as $words
  | (any($rest[]; test("^--(force|force-with-lease|force-if-includes|mirror|delete|prune)(=.*)?$") or test("^-[A-Za-z]*[fd][A-Za-z]*$"))
     or any($words[]; length > 1 and (startswith("+") or startswith(":")))) as $force
  | any($words[]; test("^([^:]*:)?(refs/heads/)?(main|master)$")) as $protected
  | (has_word($rest; "--tags") or has_word($rest; "--follow-tags") or any($words[]; contains("refs/tags/"))) as $tags
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

def http_request($program; $args):
  if $program == "curl" then curl_request($args)
  elif $program == "wget" then wget_request($args)
  elif ($program | IN("http", "https", "xh", "xhs")) then httpie_request($args)
  elif ($program | IN("gh", "glab")) and (($args | positionals | first) == "api") then
    gh_api_request(($args | .[(index("api") + 1):]))
  else null end;

# A dynamic word in the method position, or anywhere in a request that writes, can decide the
# operation: the parse is not confident (the fallback applies).
def http_dynamic($program; $words; $args):
  http_request($program; $args) as $request
  | if $request == null then false
    else
      (any(range(0; $words | length) as $i
           | ($words[$i].l | IN("-X", "--request", "--method")) and ($words[$i + 1].d // false); .)
       or any($words[]; .d and (.l | test("^(-[A-Za-z]*X|--request=|--method=)"))))
      or (($request.method | IN("POST", "PUT", "PATCH", "DELETE")) and any($words[]; .d))
    end;

def http_ops($program; $args; $stdin):
  http_request($program; $args) as $request
  | if $request == null then []
    else
      # A GraphQL mutation that merges a pull request is a merge whatever the endpoint is called.
      ((if ($request.method | IN("POST", "PUT", "PATCH")) and (([ $args[], $stdin[] ] | join("\n")) | test("mergePullRequest"; "i")) then ["pr-merge"] else [] end)) as $graphql
      | ([ $request.urls[] | endpoint_classes($request.method; .)[] ] + $graphql | unique) as $classes
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
    # Setting an alias points a domain (possibly production) at a deployment; redeploy's target can be production.
    elif $subcommand == "alias" and ((($args[$at + 1:] | positionals | first) // "") == "set") then [{l: ($program + " alias set"), c: ["production-deploy"]}]
    elif $subcommand == "redeploy" then [{l: ($program + " redeploy"), c: ["unclassified-deploy"]}]
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
# SQL block comments (and `-- ` line comments) are removed before scanning, so DROP/**/TABLE is seen.
def strip_sql_comments: gsub("/\\*[\\s\\S]*?\\*/"; " ") | gsub("(^|\\s)--\\s[^\\n]*"; " ");

# Programs whose arguments and standard input are SQL: the clients, `turso ... shell`, and
# `prisma db execute`.
def is_sql_program($program; $args):
  has_word(sql_clients; $program) or ($program == "turso" and has_word($args; "shell"))
  or ($program == "prisma" and has_word($args; "db") and has_word($args; "execute"));

# Files a SQL program reads: -f/--file/-i/--input-file values, and `< file` redirections.
def sql_file_arguments($args):
  [ range(0; $args | length) as $i
    | if ($args[$i] | test("^(-[A-Za-z]*[fi]|--file|--input-file)$")) then ($args[$i + 1] // empty)
      elif ($args[$i] | test("^--(file|input-file)=")) then ($args[$i] | sub("^[^=]*="; ""))
      else empty end ];

# Inline code of an interpreter: -c/-e/-p/-r values, --eval/--print/--command values, and the
# code after `deno eval` / `bun eval`.
def inline_code($program; $args):
  ($args | length) as $count
  | [ range(0; $count) as $j | select($args[$j] | test("^(-[A-Za-z]*[cepr]|--eval|--print|--command)$")) | $args[$j + 1] // empty ]
    + [ $args[] | select(test("^--(eval|print|command)=")) | sub("^[^=]*="; "") ]
    + (if ($program | IN("deno", "bun")) and (($args | positionals | first) == "eval") then ($args | .[(index("eval") + 1):]) else [] end);

def sql_ops($program; $args; $stdin):
  if is_sql_program($program; $args) then
    ([ $args[], $stdin[] ] | join("\n") | strip_sql_comments) as $text
    | if ($text | test(sql_destructive_regex; "i")) or ($program == "mongosh" and ($text | test(mongo_destructive_regex)))
      then [{l: ($program + " (destructive SQL)"), c: ["destructive-sql"]}] else [] end
  elif ($program | test(interpreters_regex)) then
    (inline_code($program; $args) + $stdin) as $code
    | if ($code | join("\n") | strip_sql_comments | test(interpreter_sql_destructive_regex; "i"))
      then [{l: ($program + " inline code (destructive SQL)"), c: ["destructive-sql"]}] else [] end
  else [] end;

# Shell text this command runs: {text} (bash -c, eval, ssh), {stdin: true} (bash reading
# standard input) or null.
#
# Result: null, or {texts: [shell text], stdin: true when it reads standard input, procsub: the
# text of a `<(...)` it reads, file: the script file it runs}.
def script_input($word):
  if $word == null or $word == "-" or $word == "/dev/stdin" then {stdin: true}
  elif ($word | startswith("<(")) then {procsub: $word[2:-1]}
  elif ($word | startswith("/dev/fd/")) then {stdin: true}
  else {file: $word} end;

# The commands of every -exec/-execdir/-ok/-okdir of a find, each as shell text.
def find_exec_texts($args):
  reduce range(0; $args | length) as $i ({texts: [], current: null};
    if .current != null then
      (if $args[$i] == ";" or $args[$i] == "+" then .texts += [(.current | map(shell_quote) | join(" "))] | .current = null
       else .current += [$args[$i]] end)
    elif $args[$i] | IN("-exec", "-execdir", "-ok", "-okdir") then .current = []
    else . end)
  | (if .current != null and (.current | length) > 0 then .texts += [(.current | map(shell_quote) | join(" "))] else . end)
  | .texts;

def shell_run($program; $args):
  if has_word(shells; $program) then
    skip_flags_s($args; ["-o", "-O", "--rcfile", "--init-file"]) as $at
    | if ($args[0:$at] | any(.[]; test("^-[A-Za-z]*c[A-Za-z]*$"))) then
        (if $args[$at] != null then {texts: [$args[$at]]} else null end)
      else script_input($args[$at]) end
  elif ($program | IN("source", ".")) then
    (($args | positionals | first) // null) as $script
    | if $script == null then null else script_input($script) end
  elif $program == "eval" then {texts: [($args | join(" "))]}
  elif $program == "ssh" then
    skip_flags_s($args; ssh_value_flags) as $at
    | if ($args | length) > $at + 1 then {texts: [($args[$at + 1:] | join(" "))]} else null end
  elif $program == "find" then
    (find_exec_texts($args)) as $texts | if ($texts | length) > 0 then {texts: $texts} else null end
  elif $program == "alias" then
    ([ $args[] | select(contains("=")) | sub("^[^=]*="; "") ]) as $texts
    | if ($texts | length) > 0 then {texts: $texts} else null end
  else null end;

def merge_ops:
  if length == 0 then null
  else {l: .[0].l, c: ([ .[].c[] ] | unique)} end;

# `gh workflow run <workflow>` where the workflow name says deploy, release or publish.
def gh_workflow_ops($program; $args):
  if $program == "gh" then
    ($args | positionals_skipping(gh_value_flags)) as $words
    | if ($words[0] == "workflow") and ($words[1] == "run") and (($words[2] // "") | test(deploy_word_regex; "i"))
      then [{l: ("gh workflow run " + $words[2]), c: ["unclassified-deploy"]}] else [] end
  else [] end;

def classify_invocation($program; $path; $args; $stdin; $branch):
  ( rule_ops($program; $args)
    + (if $program == "git" then git_ops($args; $branch) else [] end)
    + gh_workflow_ops($program; $args)
    + http_ops($program; $args; $stdin)
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
    globals: (if ($program | ascii_downcase) == "git" then $git.globals else [] end),
    redirs: redirect_facts($command), stdin: own_stdin($command)}];

# A command with no program of its own (only redirections, or only a lookup) still carries its redirections.
def redirect_only_facts($command):
  if ($command.r | length) > 0 then [{prog: null, sub: null, args: [], redirs: redirect_facts($command), stdin: []}] else [] end;

# What the whole submission sets up, for commands that depend on it: the text written to files
# by heredocs, here-strings, echo and printf (`cat > f <<EOF ... EOF`, then `psql -f f`), and the
# alias names it defines (an alias invocation is not another command: its text is counted).
def file_key: sub("^\\./"; "");

def all_raw_commands($raw): [ $raw.units[][] | recurse(.n[]?) ];

def collect_context($raw; $outer):
  reduce all_raw_commands($raw)[] as $command ($outer;
    ([ $command.w[].l ]) as $words
    | ($words[0] // "") as $head
    | ([ $command.r[] | select(.op | IN(">", ">>")) | .t ]
       + (if $head == "tee" then [ $words[1:][] | select(startswith("-") | not) ] else [] end)) as $targets
    | (own_stdin($command) + (if $head | IN("echo", "printf") then echoed_texts([$command]) else [] end)) as $content
    | (if $head == "alias" then .aliases += [ $words[1:][] | select(contains("=")) | sub("=.*$"; "") | ascii_downcase ] else . end)
    | reduce $targets[] as $target (.;
        .files[($target | file_key)] = ((.files[($target | file_key)] // "") + ($content | join("\n")) + "\n")));

# Text the earlier commands of a pipeline feed to a shell: echo and printf output, and a bare
# `cat` with a heredoc or here-string. Anything else is unknown input.
def producer_input($before):
  reduce $before[] as $producer ({texts: [], unknown: false};
    ([ $producer.w[].l ]) as $words
    | if ($words | length) == 0 then .
      elif ($words[0] | IN("echo", "printf")) then .texts += echoed_texts([$producer])
      elif $words[0] == "cat" and ([ $words[1:][] | select(startswith("-") | not) ] | length) == 0 then .texts += own_stdin($producer)
      else .unknown = true end);

# Programs that cannot write or run anything: a substitution made of these is not another
# effectful command (`export V=$(git describe)`).
def readonly_programs: ["echo", "printf", "cat", "grep", "egrep", "fgrep", "rg", "ag", "ack", "jq", "yq", "head", "tail", "wc", "sort",
                        "uniq", "cut", "tr", "diff", "cmp", "ls", "tree", "stat", "file", "du", "df", "basename", "dirname", "realpath",
                        "readlink", "pwd", "date", "which", "type", "whoami", "id", "uname", "hostname", "test", "[", "[[", "shasum",
                        "sha256sum", "md5", "md5sum", "base64", "xxd", "printenv"];
def readonly_git_subcommands: ["status", "diff", "log", "show", "blame", "grep", "ls-files", "ls-tree", "cat-file", "rev-parse", "rev-list",
                               "merge-base", "describe", "shortlog", "branch", "tag", "remote", "config", "name-rev", "for-each-ref", "show-ref"];

# Programs that have classification of their own (so unknown dynamic words in them decide), and
# programs the residual keyword net leaves alone.
def decisive_programs:
  ([ rules[].p[] ] + ["vercel", "vc", "netlify", "ntl", "curl", "wget", "http", "https", "xh", "xhs"] + task_runners_packages + task_runners_other) | unique;
def net_skipped($program):
  has_word(inert_programs; $program) or has_word(shells; $program) or has_word(decisive_programs; $program)
  or ($program | IN("eval", "ssh", "source", ".", "alias"));

# Interpreter words that are not inline code.
def without_inline_code($args):
  [ range(0; $args | length) as $j
    | select(($args[$j] | test("^--(eval|print|command)=")) | not)
    | select($j == 0 or (($args[$j - 1] | test("^(-[A-Za-z]*[cepr]|--eval|--print|--command)$")) | not))
    | $args[$j] ];

# Analyses one parsed command. Substitution commands it contains are analysed too and
# their operations belong to it. Shell text it runs is parsed into extra units.
# $outer carries what the enclosing submission wrote to files and which aliases it defined.
def parse_script_in($text; $depth; $branch; $outer):
  def parse_texts($texts; $ctx):
    reduce $texts[] as $inner_text ({units: [], uncertain: false};
      parse_script_in($inner_text; $depth + 1; $branch; $ctx) as $result
      | .units += $result.units | .uncertain = (.uncertain or $result.uncertain));

  def analyse($command; $before; $ctx):
    (reduce range(0; $command.n | length) as $i ({ops: [], extra: [], cmds: [], unc: false, net: [], effectful_inner: false};
       analyse($command.n[$i]; $command.n[0:$i]; $ctx) as $inner
       | .ops += $inner.ops | .extra += $inner.extra | .cmds += $inner.cmds | .net += $inner.net
       | .unc = (.unc or $inner.unc)
       # A substitution that runs something other than a read-only command makes the command effectful.
       | .effectful_inner = (.effectful_inner or ($inner.kind == "eff" and ($inner.own_op | not) and ($inner.readonly | not))))) as $nested
    | ( if ($command.w | length) == 0 then
          {kind: (if $command.hdr == "loop" then "eff"
                  elif ($command.a | length) > 0 and ($command.r | length) == 0 then "ctx"
                  elif ($command.r | length) > 0 then "eff"
                  else "none" end),
           ops: [], extra: [], cmds: redirect_only_facts($command), unc: false, own_op: false, consumer: false, readonly: false, net: []}
        else
          unwrap($command.w) as $unwrapped
          | parse_texts([ $unwrapped.texts[] | select(length > 0) ]; $ctx) as $wrapped
          | if $unwrapped.lookup or ($unwrapped.ws | length) == 0 then
              {kind: "none", ops: [], extra: $wrapped.units, cmds: redirect_only_facts($command), unc: ($unwrapped.unc or $wrapped.uncertain),
               own_op: false, consumer: false, readonly: false, net: []}
            else
              ($unwrapped.ws[0] | program_of) as $program
              | if $program.dynamic then {kind: "eff", ops: [], extra: $wrapped.units, cmds: [], unc: true, own_op: false, consumer: false, readonly: false, net: []}
                elif has_word($ctx.aliases; $program.name) then
                  {kind: "none", ops: [], extra: $wrapped.units, cmds: [], unc: $wrapped.uncertain, own_op: false, consumer: false, readonly: false, net: []}
                else
                  ($unwrapped.ws[1:]) as $words
                  | ($words | map(.l)) as $raw_args
                  | (if $program.name == "git" then git_resolved($raw_args) else {args: $raw_args, text: null, unc: false} end) as $git
                  | $git.args as $args
                  | own_stdin($command) as $own_input
                  | is_sql_program($program.name; $args) as $is_sql
                  # Files a SQL program reads: scanned when this submission wrote them, otherwise unknown.
                  | (if $is_sql then
                       ([ sql_file_arguments($args)[], ([ $command.r[] | select(.op == "<") | .t ][]),
                          ([ $before[] | select(.w[0].l == "cat") | .w[1:][].l | select(startswith("-") | not) ][]) ]) as $refs
                       | {texts: [ $refs[] | $ctx.files[file_key] | select(. != null) ],
                          unknown: (([ $refs[] | select($ctx.files[file_key] == null) ] | length) > 0)}
                     else {texts: [], unknown: false} end) as $sql_files
                  | ($own_input + producer_texts($before) + $sql_files.texts) as $stdin
                  | classify_invocation($program.name; $program.path; $args; $stdin; $branch) as $direct_op
                  # pnpm and yarn run a binary when the word is not one of their own commands.
                  | (if has_word(binary_runners; $program.name) then
                       skip_flags_s($args; ["-C", "--dir", "--filter", "-F", "--cwd"]) as $at
                       | ($args[$at] // null) as $binary
                       | if $binary != null and ($binary | startswith("-") | not) and ($binary | IN(runner_builtins[]) | not) then
                           ({l: $binary, d: false} | program_of) as $inner_program
                           | classify_invocation($inner_program.name; $inner_program.path; $args[$at + 1:]; $stdin; $branch)
                         else null end
                     else null end) as $runner_op
                  | ([ $direct_op, $runner_op ] | map(select(. != null)) | merge_ops) as $op
                  | (shell_run($program.name; $args) // {}) as $run
                  | (if $run.stdin == true then producer_input($before) else {texts: [], unknown: false} end) as $fed
                  | (if $run.stdin == true then
                       [ $command.r[] | select(.op == "<") | .t ] as $redirected
                       | {texts: [ $redirected[] | $ctx.files[file_key] | select(. != null) ], unknown: (([ $redirected[] | select($ctx.files[file_key] == null) ] | length) > 0)}
                     else {texts: [], unknown: false} end) as $redirected_input
                  | (if $run.procsub != null then
                       parse_raw($run.procsub; $depth + 1) as $inner_raw
                       | producer_input([ $inner_raw.units[][] ]) + {unknown_parse: $inner_raw.uncertain}
                     else {texts: [], unknown: false, unknown_parse: false} end) as $procsub
                  | ([ ($run.texts // [])[],
                       (if $run.stdin == true then (($own_input + $fed.texts + $redirected_input.texts) | join("\n")) else empty end),
                       (if $run.procsub != null then ($procsub.texts | join("\n")) else empty end),
                       (if $run.file != null then ($ctx.files[($run.file | file_key)] // empty) else empty end),
                       (if $git.text != null then $git.text else empty end) ]
                     | map(select(. != ""))) as $inner_texts
                  | parse_texts($inner_texts; $ctx) as $inner
                  # H3: a dynamic word where it can decide which operation runs makes the parse not confident.
                  | (if $op != null then false
                     elif $program.name == "git" then
                       (any(prefix_words($words; git_value_flags)[]; .d) or ((git_parts($args).sub == "push") and any($words[]; .d)))
                     else
                       http_dynamic($program.name; $words; $args)
                       or (has_word(decisive_programs; $program.name) and (http_request($program.name; $args) == null) and any($words[]; .d))
                     end) as $dynamic_decides
                  # Residual keyword net: the v0.2 keyword rules over commands the tables do not know.
                  | (if $op != null or net_skipped($program.name) then null
                     else (if ($program.name | test(interpreters_regex)) then (without_inline_code($args) | join(" ")) else ($unwrapped.ws | map(.l) | join(" ")) end)
                     end) as $net_text
                  | (if $net_text == null then [] elif ($net_text | length) > 8192 then [] else keyword_net($net_text; $branch) end) as $net_classes
                  | {kind: (if ($inner_texts | length) > 0 then "none"
                            elif is_context($program.name; $args) and $op == null then "ctx" else "eff" end),
                     ops: (if $op == null then [] else [$op] end),
                     extra: ($wrapped.units + $inner.units),
                     cmds: command_facts($command; $program.name; $args; (if $program.name == "git" then git_parts($args) else null end)),
                     unc: ($unwrapped.unc or $wrapped.uncertain or $inner.uncertain or $dynamic_decides or $git.unc
                           or ($sql_files.unknown and $op == null) or $fed.unknown or $procsub.unknown or ($procsub.unknown_parse // false)
                           or ($net_text != null and ($net_text | length) > 8192)),
                     own_op: ($op != null),
                     consumer: ((($unwrapped.names | index("xargs")) != null) or $is_sql or ($run.stdin == true)),
                     readonly: (has_word(readonly_programs; $program.name) or ($program.name == "git" and ((git_parts($args).sub // "") | IN(readonly_git_subcommands[])))),
                     net: $net_classes}
                end
            end
        end ) as $own
    | {kind: (if $own.kind == "ctx" and $nested.effectful_inner then "eff" else $own.kind end),
       ops: ($own.ops + $nested.ops), extra: ($own.extra + $nested.extra),
       cmds: ($own.cmds + $nested.cmds), unc: ($own.unc or $nested.unc),
       # A read-only command that only hosts a substitution holding the operation (`echo $(op)`) is not another command.
       own_op: ($own.own_op or ($own.readonly and ($nested.ops | length) > 0)), consumer: $own.consumer,
       readonly: $own.readonly, net: ($own.net + $nested.net)};

  if $depth >= 6 then {units: [], uncertain: true}
  else
    parse_raw($text; $depth) as $raw
    | collect_context($raw; $outer) as $ctx
    | reduce $raw.units[] as $unit ({units: [], uncertain: $raw.uncertain};
        (reduce range(0; $unit | length) as $i ({ops: [], extra: [], cmds: [], items: [], unc: false, net: []};
           analyse($unit[$i]; $unit[0:$i]; $ctx) as $result
           | .ops += $result.ops | .extra += $result.extra | .cmds += $result.cmds | .net += $result.net
           | .items += [{kind: $result.kind, own_op: $result.own_op, consumer: $result.consumer, readonly: $result.readonly}]
           | .unc = (.unc or $result.unc))) as $unit_result
        | ([ $unit_result.items[] | .kind ]) as $kinds
        | (if has_word($kinds; "eff") then "eff" elif has_word($kinds; "ctx") then "ctx" else "none" end) as $kind
        # Effectful commands that carry no operation of their own. Commands before the first
        # consumer of their output (a SQL client, a shell, xargs) only feed it and do not count.
        | ([ range(0; $unit_result.items | length) as $j | select($unit_result.items[$j].consumer) | $j ] | first // 0) as $first_consumer
        # A read-only filter inside a pipeline (`op | tail -5`) does not count either.
        | ($unit_result.items | length) as $pipeline_size
        | ([ range($first_consumer; $pipeline_size) as $j
             | $unit_result.items[$j] | select(.kind == "eff" and (.own_op | not) and (($pipeline_size > 1 and .readonly) | not)) ] | length) as $others
        | .uncertain = (.uncertain or $unit_result.unc)
        | .units += (if $kind == "none" and ($unit_result.ops | length) == 0 and ($unit_result.cmds | length) == 0 and ($unit_result.net | length) == 0 then []
                     else [{kind: $kind, ops: $unit_result.ops, cmds: $unit_result.cmds, others: $others, net: ($unit_result.net | unique)}] end)
        | .units += $unit_result.extra)
  end;

def parse_script($text; $depth; $branch): parse_script_in($text; $depth; $branch; {files: {}, aliases: []});
