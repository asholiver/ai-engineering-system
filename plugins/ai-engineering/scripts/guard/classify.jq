# Guard v2 classifier: turns parsed commands into operations with classes, using the tables
# in tables.jq. It decides nothing. policy.jq turns the result into ask, deny or no decision.
#
# Result of parse_script: {units: [{kind, ops, cmds, others, floor}], uncertain}
#   unit   one pipeline (a command list joined by |), plus the units of any shell text it
#          runs (bash -c, eval, ssh, git -x, awk system(), an alias call) appended after it
#   kind   "eff" (does something), "ctx" (only sets up the environment) or "none"
#   ops    [{l: operation text, c: [classes]}], at most one per command
#   cmds   [{prog, sub, args, redirs, stdin, chdir}] for every command (see command_facts), so
#          policy can reason about programs, arguments, redirections and working directories
#   others effectful commands that carry no operation (bundling)
#   floor  the unit's command text minus proven data spans (see proven_data): the keyword
#          floor runs over all of it, so classification can only add to the v0.2 rules
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

# Values of the given options in a list of argument strings: `--opt V`, `--opt=V`, `-x V`, `-xV`.
def option_texts($args; $flags):
  [ range(0; $args | length) as $i
    | $args[$i] as $arg
    | if has_word($flags; $arg) then ($args[$i + 1] // empty)
      elif ($arg | test("^--[A-Za-z-]+=")) and has_word($flags; ($arg | sub("=.*$"; ""))) then ($arg | sub("^[^=]*="; ""))
      elif ($arg | length) > 2 and ($arg | test("^-[A-Za-z]")) and has_word($flags; $arg[0:2]) then $arg[2:]
      else empty end ];

# {name, path, dynamic} for a command word. A path with a dynamic directory part
# ("$PLUGIN/scripts/run.sh") is a script call, not a dynamic program name.
# The name is lower case (a case-insensitive file system runs `GIT` and `Terraform`), loses a
# package version (`vercel@latest`) and maps package names to binaries (`netlify-cli`).
# NR-2: a name with any non-ASCII character is dynamic (APFS folds look-alikes such as the Kelvin
# sign into ASCII letters), so the parse is not confident and the fallback reads the folded text.
def program_of:
  . as $word
  | ($word.l | contains("/")) as $has_path
  | (if $has_path then ($word.l | split("/") | last) else $word.l end) as $raw_base
  | ($raw_base | ascii_downcase | if test("^[^@]+@[^@/]*$") then sub("@[^@/]*$"; "") else . end) as $lowered
  | (program_aliases[$lowered] // $lowered) as $base
  | {name: $base, path: $has_path,
     dynamic: ((if ($word.l | IN("[", "[[")) then false
                elif $has_path then ($base | test("[$`*?\\[]"))
                else $word.d end) or $base == "" or ($base | test("[^\\x01-\\x7f]")))};

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

# The replacement string of an xargs (-I R, -IR, --replace=R, -i, --replace), or null.
def xargs_replace($flags):
  [ range(0; $flags | length) as $i
    | $flags[$i].l as $word
    | if $word == "-I" then ($flags[$i + 1].l // empty)
      elif ($word | test("^-I.")) then $word[2:]
      elif $word == "--replace" or $word == "-i" then "{}"
      elif ($word | startswith("--replace=")) then $word[10:]
      elif ($word | test("^-i.")) then $word[2:]
      else empty end
    | select(length > 0) ] | first // null;

# Also returns dirs (working directories set by env -C / sudo -D, in order), xargs
# ({replace}: the wrapped command reads its arguments from standard input) and assigns (the
# NAME=value words env and sudo set for the wrapped command, H5).
def unwrap($words):
  {ws: $words, lookup: false, n: 0, stop: false, texts: [], names: [], unc: false, dirs: [], xargs: null, assigns: []}
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
          | (skip_flags($rest; $spec.vf // [])) as $flags_end
          | (if wrapper_chdir_flags[$program.name] != null then .dirs += flag_texts($rest[0:$flags_end]; wrapper_chdir_flags[$program.name]) else . end)
          | (if $program.name == "xargs" then .xargs = {replace: xargs_replace($rest[0:$flags_end])} else . end)
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
                  # `kubectl run|debug ... -- CMD`: only the words after -- are a command.
                  | if has_word($spec.sub_dashdash // []; $subcommand) then
                      (if $dashes != null then .ws = $after[$dashes + 1:] else .stop = true end)
                    elif ($spec.dashdash or $spec.dashdash_optional) and $dashes != null then .ws = $after[$dashes + 1:]
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
                  | .assigns += [ $after[0:(($after | length) - ($stripped | length))][].l ]
                  | .ws = (if $spec.skip != null then $stripped[$spec.skip:] else $stripped end)
                end
            end
        end);

# ---------------------------------------------------------------- context commands
# An alias definition only sets up the shell; a later call of the alias is classified (see analyse).
def is_context($program; $args):
  ($program | IN(context_programs[])) or $program == "alias"
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
        # NR-1: Git splits an alias on ASCII whitespace only; other spaces leave the split unknown.
        elif $hit.unknown or ($hit.value | test(odd_space_regex)) then .unc = true | .done = true
        elif ($hit.value | startswith("!")) then
          .text = ($hit.value[1:] + (if ($git.rest | length) > 0 then " " + ($git.rest | map(shell_quote) | join(" ")) else "" end))
          | .done = true
        else .args = ([ $hit.value | scan("[^ \\t\\n]+") ] + $git.rest) end)
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
# A line comment needs ASCII space or tab around `--` (NR-1): a Unicode space after `--` is not a
# comment for MySQL, so removing the rest of the line could hide a statement.
def strip_sql_comments: gsub("/\\*[\\s\\S]*?\\*/"; " ") | gsub("(^|[ \\t\\n])--[ \\t][^\\n]*"; " ");

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
  # gcloud compute ssh runs --command (or the words after --) on the remote host, like ssh.
  elif $program == "gcloud" and has_word(($args | positionals); "ssh") then
    (option_texts($args; ["--command"])
     + (($args | index("--")) as $at | if $at == null then [] else [ $args[$at + 1:] | join(" ") ] end)
     | map(select(length > 0))) as $texts
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

# Every program classify_invocation can classify (besides interpreters, matched by regex, and
# programs run by path). Derived from the same tables, computed once per submission (parse_script):
# for any other program each part of classify_invocation returns nothing, so it is skipped.
def classified_programs:
  [ rules[].p[] ] + ["git", "gh", "glab", "curl", "wget", "http", "https", "xh", "xhs", "vercel", "vc", "netlify", "ntl", "turso", "prisma"]
  + task_runners_packages + task_runners_other + script_runners + sql_clients | unique;

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
# after the program (after the Git subcommand for Git), redirections (heredoc bodies left out),
# the text fed to it on standard input (heredoc bodies and here-strings) and chdir: the
# directories it runs in, in order (an enclosing env -C or sudo -D, then git -C).
def redirect_facts($command): [ $command.r[] | {op: .op, t: .t, d: (.d // false)} ];

def git_directory_options($globals): [ range(0; $globals | length) as $i | select($globals[$i] == "-C") | ($globals[$i + 1] // empty) ];

def command_facts($command; $program; $args; $git; $chdir):
  ($program | ascii_downcase) as $name
  | [{prog: $name, sub: (if $name == "git" then $git.sub else null end),
      args: (if $name == "git" then $git.rest else $args end),
      globals: (if $name == "git" then $git.globals else [] end),
      redirs: redirect_facts($command), stdin: own_stdin($command),
      chdir: ($chdir + (if $name == "git" then git_directory_options($git.globals) else [] end))}];

# A command with no program of its own (only redirections, or only a lookup) still carries its redirections.
def redirect_only_facts($command; $chdir):
  if ($command.r | length) > 0 then [{prog: null, sub: null, args: [], globals: [], redirs: redirect_facts($command), stdin: [], chdir: $chdir}] else [] end;

# Programs that cannot write or run anything: a substitution made of these is not another
# effectful command (`export V=$(git describe)`).
def readonly_programs: ["echo", "printf", "cat", "grep", "egrep", "fgrep", "rg", "ag", "ack", "jq", "yq", "head", "tail", "wc", "sort",
                        "uniq", "cut", "tr", "diff", "cmp", "ls", "tree", "stat", "file", "du", "df", "basename", "dirname", "realpath",
                        "readlink", "pwd", "date", "which", "type", "whoami", "id", "uname", "hostname", "test", "[", "[[", "shasum",
                        "sha256sum", "md5", "md5sum", "base64", "xxd", "printenv"];

# Text the earlier commands of a pipeline feed to a shell: echo and printf output, and a bare
# `cat` with a heredoc or here-string. Anything else is unknown input, and so is a pipeline head
# inside a process substitution (ph) that reads its standard input: that is the outer stream.
def producer_input($before):
  reduce $before[] as $producer ({texts: [], unknown: false};
    ([ $producer.w[].l ]) as $words
    | if ($words | length) == 0 then .
      elif ($words[0] | IN("echo", "printf")) then .texts += echoed_texts([$producer])
      elif $words[0] == "cat" and ([ $words[1:][] | select(startswith("-") | not) ] | length) == 0
           and (($producer.ph // false) | not) then .texts += own_stdin($producer)
      else .unknown = true end);

# ---------------------------------------------------------------- what the submission sets up
# For commands that depend on earlier ones: the files this submission writes with known text
# (`cat > f <<EOF ... EOF`, then `psql -f f` or `sh f`), the Git environment it exports (H5) and
# its working directory. Aliases are tracked in order instead (see parse_script_in).
#
# NR-3c paths are keyed lexically and relative to the submission's starting directory, as moved
# by cd and pushd: "" is that directory, null an unknown one (cd to a variable, cd -, popd).
def lexical_path:
  startswith("/") as $absolute
  | (split("/") | reduce .[] as $segment ([];
       if $segment == "" or $segment == "." then .
       elif $segment == ".." then (if length > 0 and .[-1] != ".." then .[0:-1] elif $absolute then . else . + [".."] end)
       else . + [$segment] end) | join("/"))
  | if $absolute then "/" + . else . end;

# The key of $path used in directory $dir, or null when it cannot be known.
def path_key($dir; $path):
  if $dir == null or $path == null or $path == "" or ($path | test("[$`*?\\[{]|^~")) then null
  elif ($path | startswith("/")) or $dir == "" then $path | lexical_path
  else ($dir + "/" + $path) | lexical_path end;

# Each top-level command gets dir: the directory it runs in. A cd inside a subshell is treated as
# lasting; when that guesses wrong, the exposure rule in collect_context keeps the written text
# in the keyword floor.
def annotate_directories($start):
  .units |= (reduce .[] as $unit ({dir: $start, out: []};
    (reduce $unit[] as $command ({dir: .dir, cmds: []};
       .cmds += [$command + {dir: .dir}]
       | ($command.w[0].l // "") as $head
       | if $head == "cd" or $head == "pushd" then
           ([ $command.w[1:][] | select(.l | startswith("-") | not) ] | first) as $target
           | .dir = (if $target == null or $target.d then null else path_key(.dir; $target.l) end)
         elif $head == "popd" then .dir = null
         else . end)) as $result
    | .dir = $result.dir | .out += [$result.cmds]) | .out);

def leading_count($words; $regex):
  ([ range(0; $words | length) as $i | select($words[$i] | test($regex) | not) | $i ] | first) // ($words | length);

# The text an echo or printf writes is known exactly: no expansion, no escape, no option after
# the text, and a printf format that is plain text, %s\n, or %s with one argument.
def echo_exact($command):
  ([ $command.w[].l ]) as $words
  | ($words[1 + leading_count($words[1:]; "^-[neE]+$"):]) as $operands
  | (any($command.w[1:][]; .d) | not)
    and (any($operands[]; startswith("-")) | not)
    and (if $words[0] == "printf" then
           (($operands[0] // "") as $format
            | (any($operands[1:][]; contains("\\")) | not)
              and (($format | IN("%s\\n", "%s\n")) or ($format == "%s" and ($operands | length) == 2)
                   or (($format | test("[%\\\\]")) | not)))
         else (any($operands[]; contains("\\")) | not) end);

# Heredoc bodies and here-strings are known exactly (quoted delimiter, or no expansion or escape).
def stdin_exact($command):
  all($command.r[]; if .op == "<<" then ((.q // false) or ((.body | test("[$`\\\\]")) | not))
                    elif .op == "<<<" then ((.d // false) | not) else true end);

# What a command reads on standard input, when that is known: its heredoc or here-string, else
# the output of the earlier commands of its pipeline (echo, printf, cat of a heredoc). {texts, known}.
def stdin_content($command; $before):
  own_stdin($command) as $own
  | if ($own | length) > 0 then {texts: $own, known: stdin_exact($command)}
    else
      producer_input($before) as $fed
      | {texts: $fed.texts,
         known: (($before | length) > 0 and ($fed.unknown | not)
                 and all($before[]; if (.w[0].l | IN("echo", "printf")) then echo_exact(.)
                                    else ((own_stdin(.) | length) > 0 and stdin_exact(.)) end))}
    end;

# What a command writes to its redirections and tee targets: {texts, known}. Only echo, printf,
# a bare cat and tee have known text; cat and tee pass on their heredoc or their pipeline input.
def written_content($command; $before):
  ([ $command.w[].l ]) as $words
  | ($words[0] // "") as $head
  | if ($head | IN("echo", "printf")) then {texts: echoed_texts([$command]), known: echo_exact($command)}
    elif ($head == "cat" and ($words | length) == 1) or $head == "tee" then stdin_content($command; $before)
    else {texts: [], known: false} end;

# Programs (first word) that can write a file with text from this submission in ways not recorded
# above: copy, fetch, extract and patch tools, in-place editors, interpreters and shells (their
# code is parsed or proven data, not followed into files), and the generic wrappers.
def file_writer_programs:
  ["cp", "mv", "install", "ln", "curl", "wget", "tar", "gtar", "bsdtar", "unzip", "dd", "rsync", "ditto", "patch", "cpio", "pax",
   "7z", "7za", "7zz", "sponge", "split", "csplit", "openssl", "gzip", "gunzip", "bzip2", "bunzip2", "xz", "unxz", "zstd",
   "uudecode", "sed", "perl", "awk", "gawk", "mawk", "nawk", "eval", "find", "make", "gmake",
   "sudo", "doas", "env", "time", "nice", "ionice", "nohup", "setsid", "exec", "builtin", "command", "stdbuf", "timeout", "xargs",
   "caffeinate", "chronic", "unbuffer", "chrt", "taskset", "flock", "script", "su", "nix-shell", "watch", "parallel", "coproc"]
  + shells;
def raw_head($command): (($command.w[0].l // "") | split("/") | last // "") | ascii_downcase;
def is_file_writer($command):
  raw_head($command) as $head
  | has_word(file_writer_programs; $head) or ($head | test(interpreters_regex))
    or ($head == "git" and any($command.w[]; .l | IN("apply", "am")));
def task_runner_programs: task_runners_packages + task_runners_other;

# Context fields: files {key: {t: text, k: known}}, opaque (a write whose target is unknown),
# writers (commands that can write files some other way), files_exposed (written text is not
# proven data: a written file's name is used again by a command that can run it, or a task
# runner runs), exports (Git-relevant NAME=value words set for the rest of the submission), dir.
def all_raw_commands_of($raw): [ $raw.units[][] | recurse(.n[]?) ];

def collect_context($raw; $outer):
  reduce ($raw.units[] | . as $unit | range(0; length) as $i
          | ({c: $unit[$i], b: $unit[0:$i]}, ($unit[$i].dir as $dir | $unit[$i].n[]? | recurse(.n[]?) | {c: (. + {dir: $dir}), b: []}))) as $item ($outer;
    $item.c as $command
    | $command.dir as $dir
    | ([ $command.w[].l ]) as $words
    | raw_head($command) as $head
    | ([ $command.r[] | select(.op | IN(">", ">>", ">|", "&>", "&>>")) | {l: .t, d: (.d // false)} ]
       + (if $words[0] == "tee" then [ $command.w[1:][] | select(.l | startswith("-") | not) ] else [] end)) as $targets
    | (if ($targets | length) > 0 then written_content($command; $item.b) else null end) as $content
    | reduce $targets[] as $target (.;
        (if $target.d then null else path_key($dir; $target.l) end) as $key
        | if $key == null then .opaque = true
          else .files[$key] = {t: ((.files[$key].t // "") + ($content.texts | join("\n")) + "\n"),
                               k: ((.files[$key].k // true) and $content.known)} end)
    # runs: the submission may run a script (sh f, source f, . f, ./f, /abs/f, also through a
    # wrapper), so the writers below are counted.
    | (if ($head | IN("source", ".")) or has_word(shells; $head) or (($words[0] // "") | contains("/")) or wrappers[$head] != null
       then .runs = true else . end)
    # H5: exported (or plainly assigned, which updates an exported name) Git-relevant variables.
    | .exports += [ (if ($words | length) == 0 then $command.a[].l
                     elif $head | IN("export", "declare", "typeset", "readonly", "local") then ($words[1:][] | select(startswith("-") | not))
                     else empty end)
                    | select(sub("=.*$"; "") | test(git_env_tracked_regex)) ])
  # Counted only when a script may run: the count matters only for a script's unknown text.
  | (if .runs then .writers += ([ all_raw_commands_of($raw)[] | select(is_file_writer(.)) ] | length) else . end)
  | if (.files | length) == 0 then .
    else
      ([ .files | keys[] | split("/") | last ]) as $names
      | .files_exposed = (.files_exposed or any(all_raw_commands_of($raw)[];
          raw_head(.) as $head
          | has_word(task_runner_programs; $head)
            or (($head != "tee") and (has_word(readonly_programs; $head) | not)
                and any(.w[]; (.l | split("/") | last) as $base | has_word($names; $base)))))
    end;

# A redirection that writes a file (not /dev/null, a terminal or a file descriptor duplicate).
def writes_files($command):
  any($command.r[]; (.op | IN(">", ">>", ">|", "&>", "&>>", "<>", ">&")) and ((.t | test("^(/dev/(null|stdout|stderr|tty)|-|[0-9]+-?)$")) | not));

# Programs that have classification of their own (so unknown dynamic words in them decide).
def decisive_programs:
  ([ rules[].p[] ] + ["vercel", "vc", "netlify", "ntl", "curl", "wget", "http", "https", "xh", "xhs"] + task_runners_packages + task_runners_other) | unique;

# ---------------------------------------------------------------- git read forms
# Git subcommands a restricted agent may run (an allow-list: everything else is denied), also the
# read-only test for bundling. branch, tag, stash, worktree, remote and config are allowed in
# their pure read forms only. version and help change nothing.
def git_read_subcommands: ["status", "diff", "log", "show", "blame", "grep", "ls-files", "ls-tree", "cat-file", "rev-parse", "rev-list",
                           "merge-base", "describe", "shortlog", "fetch", "version", "help"];
# Flags that take a separate value in branch and tag listings.
def git_listing_value_flags: ["--contains", "--no-contains", "--merged", "--no-merged", "--points-at", "--sort", "--format"];
def git_branch_write_flags: "^(--(delete|move|copy|force|set-upstream-to|unset-upstream|edit-description|track|no-track)(=.*)?|-[A-Za-z]*[dDmMcCufqt][A-Za-z]*)$";
def git_tag_write_flags: "^(--(delete|force|annotate|sign|message|file|local-user)(=.*)?|-[A-Za-z]*[dfasmFu][A-Za-z]*)$";
def git_list_flag: "^(-l|--list)$";
def git_config_read_flag: "^(--get|--get-all|--get-regexp|--get-urlmatch|--list|-l)$";
def git_config_write_flag: "^(--add|--unset|--unset-all|--replace-all|--edit|-e|--rename-section|--remove-section|--global|--system|--file|-f|--worktree)$";

# True when a Git command is on the read-only list. Input: {sub, args} (args after the subcommand).
def git_read_form:
  .sub as $sub | .args as $args | ($args | positionals) as $positional
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

# ---------------------------------------------------------------- executing constructs
# -c / --config-env settings before the Git subcommand: {key (lower case), value, env}.
def git_config_settings($globals):
  [ range(0; $globals | length) as $i
    | if $globals[$i] == "-c" then {setting: ($globals[$i + 1] // ""), env: false}
      elif $globals[$i] == "--config-env" then {setting: ($globals[$i + 1] // ""), env: true}
      elif ($globals[$i] | startswith("--config-env=")) then {setting: ($globals[$i] | sub("^[^=]*="; "")), env: true}
      else empty end
    | . + {key: (.setting | sub("=.*$"; "") | ascii_downcase), value: (if (.setting | contains("=")) then (.setting | sub("^[^=]*="; "")) else "" end)} ];

# Options that make Git run a program: --exec-path, executing options, git grep -O, ext:: transport.
def git_exec_options($git):
  [ ($git.globals[] | select(startswith("--exec-path"))),
    ($git.rest[] | select(test(git_exec_flag_regex))),
    (if $git.sub == "grep" then ($git.rest[] | select(test(git_grep_pager_regex))) else empty end),
    (($git.globals + $git.rest)[] | select(test("ext::"; "i"))) ];

# True when a Git command can run a program it was given (so none of its words are proven data):
# any -c outside the safe list, an executing option, or a subcommand that runs commands
# (foreach, bisect run, filter-branch, difftool, rebase -x).
def git_exec_construct($git):
  ($git.sub // "") as $sub
  | any(git_config_settings($git.globals)[]; .key | test(git_safe_config_key_regex; "i") | not)
    or (git_exec_options($git) | length) > 0
    or ($sub | IN(git_exec_subcommands[]))
    or ($sub == "submodule" and has_word($git.rest; "foreach"))
    or ($sub == "bisect" and has_word($git.rest; "run"))
    or (($sub | IN("rebase", "difftool")) and has_word($git.rest; "-x"))
    or (($sub | IN("clone", "ls-remote", "archive")) and has_word($git.rest; "-u"));

# Shell text Git runs because of an executing construct, parsed like bash -c text. The values of
# --upload-pack and --receive-pack are left to the floor (they end in Git's own helper program).
def git_exec_texts($git):
  ($git.sub // "") as $sub | $git.rest as $rest
  | [ (git_config_settings($git.globals)[]
       | select((.env | not) and (.key | test(git_command_config_regex)) and (.key | startswith("alias.") | not)) | .value | sub("^!"; "")),
      option_texts($rest; ["--open-files-in-pager", "--exec", "--extcmd"])[],
      (if $sub == "grep" then ($rest[] | select(test("^-O.")) | .[2:]) else empty end),
      (if ($sub | IN("rebase", "difftool")) then option_texts($rest; ["-x"])[] else empty end),
      option_texts($rest; [ $rest[] | select(test("^--[A-Za-z-]+-filter(=|$)")) | sub("=.*$"; "") ])[],
      (if $sub == "submodule" then
         (($rest | index("foreach")) as $at
          | if $at == null then empty else ($rest[$at + 1:] | map(select(test("^(--recursive|-q|--quiet)$") | not)) | join(" ")) end)
       else empty end),
      (if $sub == "bisect" then
         (($rest | index("run")) as $at | if $at == null then empty else ($rest[$at + 1:] | map(shell_quote) | join(" ")) end)
       else empty end) ]
  | map(select(length > 0));

# Commands an awk program runs: string literals given to system(), piped to or read with getline.
def awk_texts($args):
  if any($args[]; test("^(--file(=.*)?|-[A-Za-z]*f)$")) then []
  else
    ((($args | positionals_skipping(["-F", "-v", "--field-separator", "--assign"])) | first) // "") as $program
    | [ ($program | [match("system\\s*\\(\\s*\"((?:\\\\.|[^\"\\\\])*)\""; "g") | .captures[0].string][]),
        ($program | [match("\\|&?\\s*\"((?:\\\\.|[^\"\\\\])*)\""; "g") | .captures[0].string][]),
        ($program | [match("\"((?:\\\\.|[^\"\\\\])*)\"\\s*\\|&?\\s*getline"; "g") | .captures[0].string][]) ]
    | map(gsub("\\\\(?<c>[\"\\\\])"; .c))
  end;

# Recipe lines of make --eval text (`x: ; cmd` and tab-indented lines).
def make_recipes:
  [ split("\n")[]
    | if startswith("\t") then .[1:]
      elif test("^[^=#\\t][^=#]*:([^=]|$)") and contains(";") then sub("^[^;]*;"; "")
      else empty end
    | sub("^\\s*[@+-]*"; "") | select(length > 0) ] | join("\n");

# Shell text a program runs because of an executing construct: {texts, unc}. Unlike bash -c,
# the program does something itself as well (see own_op in analyse). A --config-env value comes
# from the environment (documented residual): its words are floor-scanned and restricted agents
# are denied it, so it does not make the parse uncertain.
def carrier_texts($program; $args; $git):
  if $program == "git" and $git != null then {texts: git_exec_texts($git), unc: false}
  elif has_word(awk_programs; $program) then {texts: awk_texts($args), unc: false}
  elif exec_value_flags[$program] != null then
    (option_texts($args; exec_value_flags[$program]) + [ $args[] | select(startswith("--checkpoint-action=exec=")) | .[25:] ]) as $values
    | {texts: (if ($program | IN("make", "gmake")) then [ $values[] | make_recipes ] else $values end), unc: false}
  else {texts: [], unc: false} end;

# A shell with -c and no script argument (xargs supplies it).
def shell_without_script($args):
  skip_flags_s($args; ["-o", "-O", "--rcfile", "--init-file"]) as $at
  | ($args[0:$at] | any(.[]; test("^-[A-Za-z]*c[A-Za-z]*$"))) and ($args[$at] == null);

# ---------------------------------------------------------------- proven data spans
# The only spans the keyword floor leaves out (tables.jq lists them). Each function returns
# indexes into the arguments after the program.
def message_value_indexes($args):
  [ range(0; $args | length) as $i
    | $args[$i] as $arg
    | if ($arg | test("^(--message|--file|-[A-Za-z]*[mF])$")) then ($i + 1)
      elif ($arg | test("^(--message=|--file=|-[mF].)")) then $i
      else empty end
    | select(. < ($args | length)) ];

def git_message_from_stdin($args):
  any(range(0; $args | length) as $i
      | ((($args[$i] | test("^(--file|-[A-Za-z]*F)$")) and $args[$i + 1] == "-") or ($args[$i] | IN("--file=-", "-F-"))); .);

def pickaxe_indexes($args):
  [ range(0; $args | length) as $i
    | $args[$i] as $arg
    | if ($arg | test("^-[SG]$")) then ($i + 1) elif ($arg | test("^-[SG].")) then $i else empty end ];

# Git: {rest: indexes into the arguments after the subcommand, stdin: the heredoc is a message}.
def git_proven_data($git):
  if git_exec_construct($git) then {rest: [], stdin: false}
  else
    ($git.rest | length) as $count
    | ($git.sub // "") as $sub
    | {rest: ([ (if $sub == "grep" then range(0; $count) else empty end),
                (if ($sub | IN(git_operand_data_subcommands[])) then (range(0; $count) as $i | select($git.rest[$i] | startswith("-") | not) | $i) else empty end),
                (if $sub == "log" then pickaxe_indexes($git.rest)[] else empty end),
                (if ($sub | IN(git_message_subcommands[])) then message_value_indexes($git.rest)[] else empty end) ] | unique),
       stdin: (($sub | IN(git_message_subcommands[])) and git_message_from_stdin($git.rest))}
  end;

# URL operands of a read-only (GET or HEAD) request.
def http_url_indexes($program; $args):
  http_request($program; $args) as $request
  | if $request == null or (($request.method | IN("GET", "HEAD")) | not) then []
    else [ range(0; $args | length) as $i
           | select((($args[$i] | startswith("-") | not) and ($args[$i] | IN($request.urls[])))
                    or (($args[$i] | startswith("--url=")) and (($args[$i] | sub("^--url="; "")) | IN($request.urls[]))))
           | $i ] end;

def inline_code_indexes($program; $args):
  ($args | length) as $count
  | [ (range(1; $count) as $j | select($args[$j - 1] | test("^(-[A-Za-z]*[cepr]|--eval|--print|--command)$")) | $j),
      (range(0; $count) as $j | select($args[$j] | test("^--(eval|print|command)=")) | $j),
      (if ($program | IN("deno", "bun")) and (($args | positionals | first) == "eval") then range(($args | index("eval")) + 1; $count) else empty end) ];

# A sed script (the first operand, or every -e value) made only of s commands with no e or w flag.
def sed_script_indexes($args):
  ($args | length) as $count
  | if any($args[]; test("^(--file(=.*)?|-[A-Za-z]*f)$")) then []
    else
      [ (range(1; $count) as $j | select($args[$j - 1] | test("^(-[A-Za-z]*e|--expression)$")) | $j),
        (range(0; $count) as $j | select($args[$j] | test("^--expression=")) | $j) ] as $expressions
      | (if ($expressions | length) > 0 then $expressions
         else
           skip_flags_s($args; ["-l", "--line-length"]) as $at
           # BSD sed: `-i ''` takes the (empty) backup suffix as a separate word.
           | (if ($args[$at] // null) == "" and $at > 0 and ($args[$at - 1] | test("^-[A-Za-z]*i$")) then [$at + 1] else [$at] end)
           | map(select(. < $count))
         end) as $scripts
      | if ($scripts | length) > 0 and all($scripts[]; ($args[.] | sub("^--expression="; "") | test(sed_substitutions_regex))) then $scripts else [] end
    end;

# Package names given to a package manager's own non-task commands (`pnpm add release-it`).
def package_operand_indexes($program; $args):
  if has_word(task_runners_packages; $program) then
    skip_flags_s($args; ["-C", "--dir", "--filter", "-F", "--cwd", "--prefix", "-w", "--workspace"]) as $at
    | if (($args[$at] // "") | IN(package_non_task_subcommands[])) then [ range($at + 1; $args | length) ] else [] end
  else [] end;

def gh_release_read_indexes($program; $args):
  if ($program | IN("gh", "glab")) then
    ($args | positionals_skipping(gh_value_flags)) as $words
    | if ($words[0] // "") == "release" and (($words[1] // "") | IN(gh_release_read_subcommands[])) then
        ([ range(0; $args | length) as $i | select($args[$i] == $words[1]) | $i ] | first) as $at
        | [ range($at + 1; $args | length) ]
      else [] end
  else [] end;

# {args: indexes of argument words that are proven data, stdin: heredoc bodies and here-strings
# are proven data}. $exposed: the command's output is captured or read by a program that is not
# a data sink, so echo, printf, cat and tee are not data. $git: git_parts plus offset (index of
# the first argument after the subcommand), or null when an inline alias was expanded.
def proven_data($program; $args; $git; $exposed):
  ($args | length) as $count
  | if ($program | IN("echo", "printf")) then
      (if $exposed then {args: [], stdin: false} else {args: [range(0; $count)], stdin: true} end)
    elif $program == "cat" then
      (if $exposed then {args: [], stdin: false} else {args: [range(0; $count) as $i | select($args[$i] | startswith("-") | not) | $i], stdin: true} end)
    elif $program == "tee" then {args: [], stdin: ($exposed | not)}
    elif has_word(search_programs; $program) then
      (if any($args[]; startswith("--pre") or startswith("--hostname-bin") or startswith("--pager"))
       then {args: [], stdin: false} else {args: [range(0; $count)], stdin: false} end)
    elif $program == "git" then
      (if $git == null then {args: [], stdin: false} else (git_proven_data($git) | {args: [ .rest[] + $git.offset ], stdin: .stdin}) end)
    elif ($program | test(interpreters_regex)) then {args: inline_code_indexes($program; $args), stdin: true}
    elif $program == "sed" then {args: sed_script_indexes($args), stdin: false}
    else {args: ((http_url_indexes($program; $args) + package_operand_indexes($program; $args) + gh_release_read_indexes($program; $args)) | unique), stdin: false} end;

# A process substitution among the command's words or redirection targets (NR-3a): what the
# command reads or writes may go to a program, so neither its own text nor its input is data.
def has_procsub($command): any($command.w[]; .ps != null) or any($command.r[]; .p // false);

# A data sink given an option that runs a program (sort --compress-program, NR-3b).
def sink_runs_program($head; $command):
  (data_sink_exec_regex[$head] // null) as $regex
  | $regex != null and any($command.w[1:][]; .l | test($regex));

# Every later command of the pipeline is a data sink, or a reader whose input is parsed or scanned.
def downstream_ok($after):
  all($after[]; . as $command
      | (has_procsub($command) | not)
        and (((.w | length) == 0)
             or ((.w[0].l | split("/") | last | ascii_downcase) as $head
                 | (has_word(data_sinks; $head) and (sink_runs_program($head; $command) | not))
                   or has_word(shells; $head) or has_word(sql_clients; $head) or $head == "xargs"
                   or ($head | test(interpreters_regex)))));

# The floor text of one command: assignments, the words that are not proven data, loop and case
# header words, redirection targets, the standard input unless it is proven data, and $fed (text
# a producer pipes into a SQL client).
def command_floor($command; $words; $data; $stdin_data; $fed):
  [ ($command.a[] | .l),
    ([ range(0; $words | length) as $index | select(has_word($data; $index) | not) | $words[$index].l ] | join(" ")),
    ($command.fw // [])[],
    ($command.r[] | if .op == "<<" then (if $stdin_data then empty else .body end)
                    elif .op == "<<<" then (if $stdin_data then empty else .t end)
                    else .t end),
    $fed[] ]
  | map(select(length > 0));

# A file this submission wrote: {t: text, k: known exactly}, or null.
def file_entry($ctx; $dir; $path):
  path_key($dir; $path) as $key | if $key == null then null else ($ctx.files[$key] // null) end;

# Analyses one parsed command. Substitution commands it contains are analysed too and
# their operations belong to it. Shell text it runs is parsed into extra units.
# $outer carries what the enclosing submission wrote to files and which aliases it defined.
#
# Two kinds of uncertainty: unc (the parse itself is not confident: the fallback replaces it) and
# soft (the parse is sound but something it runs is unknown: a script this submission may have
# written, a shell reading a process substitution's stream). With soft and no decision, main.jq
# applies the fallback; a decision the parse reached (ask or deny) stands.
def parse_script_in($text; $depth; $branch; $outer):
  def parse_texts($texts; $ctx):
    reduce $texts[] as $inner_text ({units: [], uncertain: false, soft: false};
      parse_script_in($inner_text; $depth + 1; $branch; $ctx) as $result
      | .units += $result.units | .uncertain = (.uncertain or $result.uncertain) | .soft = (.soft or $result.soft));

  # $before / $after: the other commands of the same pipeline. $ctx: files (written by this
  # submission), aliases (defined earlier: name -> {value, dynamic}), captured (the output is
  # used as words, so echo and friends are not data), chdir (directories set by wrappers) and dir
  # (the directory a top-level command runs in, see annotate_directories).
  def analyse($command; $before; $after; $ctx_in):
    (if ($command | has("dir")) then $ctx_in + {dir: $command.dir} else $ctx_in end) as $ctx
    | ($ctx.captured or (downstream_ok($after) | not) or has_procsub($command) or ($ctx.files_exposed // false)) as $exposed
    | ( if ($command.w | length) == 0 then
          {kind: (if $command.hdr == "loop" then "eff"
                  elif ($command.a | length) > 0 and ($command.r | length) == 0 then "ctx"
                  elif ($command.r | length) > 0 then "eff"
                  else "none" end),
           ops: [], extra: [], cmds: redirect_only_facts($command; $ctx.chdir), unc: false, soft: false, own_op: false, consumer: false, readonly: false,
           data_words: [], defines: {}, floor: command_floor($command; []; []; false; [])}
        else
          unwrap($command.w) as $unwrapped
          | ($ctx + {chdir: ($ctx.chdir + $unwrapped.dirs), captured: $exposed}) as $wrapped_ctx
          | parse_texts([ $unwrapped.texts[] | select(length > 0) ]; $wrapped_ctx) as $wrapped
          | if $unwrapped.lookup or ($unwrapped.ws | length) == 0 then
              {kind: "none", ops: [], extra: $wrapped.units, cmds: redirect_only_facts($command; $ctx.chdir), unc: ($unwrapped.unc or $wrapped.uncertain),
               soft: $wrapped.soft, own_op: false, consumer: false, readonly: false, data_words: [], defines: {}, floor: command_floor($command; $command.w; []; false; [])}
            elif ($unwrapped.ws[0] | program_of).dynamic then
              {kind: "eff", ops: [], extra: $wrapped.units, cmds: [], unc: true, soft: false, own_op: false, consumer: false, readonly: false,
               data_words: [], defines: {}, floor: command_floor($command; $command.w; []; false; [])}
            else
                  # xargs: the producer's text becomes arguments (appended, or in place of the -I string).
                  # xargs splits on ASCII blanks and newlines only (NR-1); other spaces leave the arguments unknown.
                  (if $unwrapped.xargs != null then producer_input($before) else {texts: [], unknown: true} end) as $xargs_input
                  | ($xargs_input.texts | join("\n")) as $fed_text
                  | ($unwrapped.xargs != null and ($fed_text | test(odd_space_regex))) as $xargs_odd
                  | (if $unwrapped.xargs == null or $xargs_input.unknown or $fed_text == "" or $xargs_odd then $unwrapped.ws
                     elif $unwrapped.xargs.replace != null then [ $unwrapped.ws[] | .l |= (split($unwrapped.xargs.replace) | join($fed_text)) ]
                     elif has_word(shells; ($unwrapped.ws[0] | program_of).name) and shell_without_script($unwrapped.ws[1:] | map(.l)) then
                       $unwrapped.ws + [{l: $fed_text, d: false, s: []}]
                     else $unwrapped.ws + [ $fed_text | [scan("[^ \\t\\n]+")][] | {l: ., d: false, s: []} ] end) as $ws
                  # The directory the program runs in (cd tracking plus env -C / sudo -D), for files it reads.
                  | (reduce $unwrapped.dirs[] as $directory ($ctx.dir; path_key(.; $directory))) as $run_dir
                  | ($command.w[0:(($command.w | length) - ($unwrapped.ws | length))] + $ws) as $all_words
                  | (($all_words | length) - ($ws | length) + 1) as $first_argument
                  | ($ws[0] | program_of) as $program
                  | ($ws[1:]) as $words
                  | ($words | map(.l)) as $raw_args
                  | (if $program.name == "git" then git_resolved($raw_args) else {args: $raw_args, text: null, unc: false} end) as $git
                  | $git.args as $args
                  | (if $program.name == "git" then git_parts($args) else null end) as $git_parts
                  # N1: an alias defined earlier in this submission runs its value with these arguments.
                  | ($ctx.aliases[$program.name] // null) as $alias
                  | (if $alias == null or $alias.dynamic then [] else [ ([$alias.value] + ($raw_args | map(shell_quote))) | join(" ") ] end) as $alias_texts
                  | own_stdin($command) as $own_input
                  | is_sql_program($program.name; $args) as $is_sql
                  # Files a SQL program reads: scanned when this submission wrote them, otherwise unknown.
                  | (if $is_sql then
                       ([ sql_file_arguments($args)[], ([ $command.r[] | select(.op == "<") | .t ][]),
                          ([ $before[] | select(.w[0].l == "cat") | .w[1:][].l | select(startswith("-") | not) ][]) ]) as $refs
                       | [ $refs[] | file_entry($ctx; $run_dir; .) ] as $entries
                       | {texts: [ $entries[] | select(. != null) | .t ],
                          unknown: (([ $entries[] | select(. == null) ] | length) > 0)}
                     else {texts: [], unknown: false} end) as $sql_files
                  | ($own_input + producer_texts($before) + $sql_files.texts) as $stdin
                  | (if $program.path or has_word($ctx.classified // classified_programs; $program.name) or ($program.name | test(interpreters_regex))
                     then classify_invocation($program.name; $program.path; $args; $stdin; $branch) else null end) as $direct_op
                  # pnpm and yarn run a binary when the word is not one of their own commands.
                  | (if has_word(binary_runners; $program.name) then
                       skip_flags_s($args; ["-C", "--dir", "--filter", "-F", "--cwd"]) as $at
                       | ($args[$at] // null) as $binary
                       | if $binary != null and ($binary | startswith("-") | not) and ($binary | IN(runner_builtins[]) | not) then
                           ({l: $binary, d: false} | program_of) as $inner_program
                           | classify_invocation($inner_program.name; $inner_program.path; $args[$at + 1:]; $stdin; $branch)
                         else null end
                     else null end) as $runner_op
                  | ([ $direct_op, $runner_op ] | map(select(. != null)) | merge_ops) as $classified_op
                  | (shell_run($program.name; $args) // {}) as $run
                  | (if $run.stdin == true then producer_input($before) else {texts: [], unknown: false} end) as $fed
                  | (if $run.stdin == true then
                       [ $command.r[] | select(.op == "<") | file_entry($ctx; $run_dir; .t) ] as $entries
                       | {texts: [ $entries[] | select(. != null) | .t ], unknown: (([ $entries[] | select(. == null) ] | length) > 0)}
                     else {texts: [], unknown: false} end) as $redirected_input
                  # NR-3c: a script run by a shell, source or `.`, or a program run by its path. The text
                  # this submission wrote to it is parsed; when the submission writes files and the
                  # script's text is not known exactly, the parse is soft-uncertain.
                  | (if $run.file != null then $run.file elif $program.path then $ws[0].l else null end) as $script_path
                  | (if $script_path == null then null else file_entry($ctx; $run_dir; $script_path) end) as $script_entry
                  | ($script_path != null
                     and ($script_entry == null or ($script_entry.k | not) or ($ctx.opaque // false))
                     and ((($ctx.files // {}) | length) > 0 or ($ctx.opaque // false)
                          or (($ctx.writers // 0) - (if is_file_writer($command) then 1 else 0 end)) > 0)) as $script_unknown
                  | (if $run.procsub != null then
                       parse_raw($run.procsub; $depth + 1) as $inner_raw
                       | producer_input([ $inner_raw.units[][] ]) + {unknown_parse: $inner_raw.uncertain}
                     else {texts: [], unknown: false, unknown_parse: false} end) as $procsub
                  | ([ ($run.texts // [])[],
                       (if $run.stdin == true then (($own_input + $fed.texts + $redirected_input.texts) | join("\n")) else empty end),
                       (if $run.procsub != null then ($procsub.texts | join("\n")) else empty end),
                       (if $script_entry != null then $script_entry.t else empty end),
                       (if $git.text != null then $git.text else empty end) ]
                     | map(select(. != ""))) as $shell_texts
                  | ($ctx.chdir + $unwrapped.dirs) as $chdir
                  | ($ctx + {chdir: ($chdir + (if $git_parts != null then git_directory_options($git_parts.globals) else [] end)), captured: $exposed, dir: $run_dir}) as $run_ctx
                  | parse_texts($shell_texts; $run_ctx) as $shell_run
                  # Bash does not expand an alias again inside its own expansion.
                  | parse_texts($alias_texts; $run_ctx | .aliases |= del(.[$program.name])) as $expansion
                  | ($shell_texts + $alias_texts) as $inner_texts
                  | {units: ($shell_run.units + $expansion.units), uncertain: ($shell_run.uncertain or $expansion.uncertain),
                     soft: ($shell_run.soft or $expansion.soft)} as $inner
                  # Executing constructs of other programs (git -x, awk system(), tar --to-command, ...).
                  | carrier_texts($program.name; $args; $git_parts) as $carrier
                  | parse_texts([ $carrier.texts[] | select(length > 0) ]; $run_ctx) as $carried
                  # An alias call is classified as written and as its expansion; one operation found both ways counts once.
                  | (if $classified_op != null and ($alias_texts | length) > 0 and any($inner.units[].ops[]; .l == $classified_op.l)
                     then null else $classified_op end) as $op
                  # H3: a dynamic word where it can decide which operation runs makes the parse not confident.
                  | (if $classified_op != null then false
                     elif $program.name == "git" then
                       (any(prefix_words($words; git_value_flags)[]; .d) or (($git_parts.sub == "push") and any($words[]; .d)))
                     else
                       http_dynamic($program.name; $words; $args)
                       or (has_word(decisive_programs; $program.name) and (http_request($program.name; $args) == null) and any($words[]; .d))
                     end) as $dynamic_decides
                  # Proven data spans: left out of the keyword floor. None inside a captured substitution.
                  | (if $ctx.captured then {args: [], stdin: false}
                     else proven_data($program.name; $args;
                                      (if $git_parts != null and $git.args == $raw_args then $git_parts + {offset: (skip_flags_s($args; git_value_flags) + 1)} else null end);
                                      $exposed) end) as $proven
                  | ([ $proven.args[] | . + $first_argument ]) as $data_words
                  # N6(b): the patch a patch, git apply or git am reads: files this submission wrote with
                  # known text, its heredoc, or its pipeline input; anything else is unknown.
                  | (if $program.name == "patch" or ($git_parts != null and (($git_parts.sub // "") | IN("apply", "am"))) then
                       (if $program.name == "patch" then option_texts($args; ["-i", "--input"]) + (($args | positionals_skipping(patch_value_flags))[1:2])
                        else ($git_parts.rest | positionals_skipping(git_patch_value_flags)) end) as $patch_files
                       | ($patch_files + [ $command.r[] | select(.op == "<") | .t ]) as $sources
                       | if ($sources | length) > 0 then
                           [ $sources[] | file_entry($ctx; $run_dir; .) ] as $entries
                           | {texts: [ $entries[] | select(. != null) | .t ],
                              known: (all($entries[]; . != null and .k) and (($ctx.opaque // false) | not))}
                         else stdin_content($command; $before) end
                     else null end) as $patch
                  | {kind: (if ($inner_texts | length) > 0 then "none"
                            elif is_context($program.name; $args) and $op == null then "ctx" else "eff" end),
                     ops: (if $op == null then [] else [$op] end),
                     extra: ($wrapped.units + $inner.units + $carried.units),
                     # H5: the environment a Git command runs with (prefix assignments, env/sudo
                     # assignments and Git-relevant exports earlier in the submission).
                     cmds: (command_facts($command; $program.name; $args; $git_parts; $chdir)
                            | if $program.name == "git" then map(.env = ([ $command.a[].l ] + $unwrapped.assigns + ($ctx.exports // []))) else . end
                            | if $patch != null then map(.patch = $patch) else . end),
                     unc: ($unwrapped.unc or $wrapped.uncertain or $inner.uncertain or $carried.uncertain or $carrier.unc or $dynamic_decides or $git.unc
                           or ($alias != null and $alias.dynamic)
                           or ($sql_files.unknown and $op == null) or $fed.unknown or $procsub.unknown or ($procsub.unknown_parse // false)),
                     # NR-3a: a shell, SQL client or xargs heading a process substitution reads the
                     # outer command's stream, which no producer here accounts for.
                     soft: ($wrapped.soft or $inner.soft or $carried.soft or $script_unknown or $xargs_odd
                            or (($command.ph // false) and (($run.stdin == true) or $is_sql or (($unwrapped.names | index("xargs")) != null)))),
                     # A program that runs the operation through an executing construct carries it (`git rebase -x 'op'`).
                     own_op: ($op != null or any($carried.units[]; (.ops | length) > 0)),
                     consumer: ((($unwrapped.names | index("xargs")) != null) or $is_sql or ($run.stdin == true)),
                     # Read-only: cannot change anything (Git read forms with no executing construct), and writes no file.
                     readonly: ((has_word(readonly_programs; $program.name)
                                 or ($git_parts != null and ({sub: $git_parts.sub, args: $git_parts.rest} | git_read_form) and (git_exec_construct($git_parts) | not))
                                 or (($program.name | IN("kubectl", "oc"))
                                     and (((($args | positionals_skipping(wrappers.kubectl.vf)) | first) // "") | IN(kubernetes_read_subcommands[]))))
                                and (writes_files($command) | not) and (($carrier.texts | length) == 0)),
                     data_words: $data_words,
                     defines: (if $program.name == "alias" then
                                 reduce ($words[] | select(.l | contains("="))) as $definition ({};
                                   .[($definition.l | sub("=.*$"; "") | ascii_downcase)] = {value: ($definition.l | sub("^[^=]*="; "")), dynamic: $definition.d})
                               else {} end),
                     floor: command_floor($command; $all_words; $data_words; $proven.stdin; (if $is_sql then producer_texts($before) else [] end))}
            end
        end ) as $own
    # Commands in substitutions. One in a proven-data word feeds that data; any other is captured.
    | (reduce range(0; $command.n | length) as $i ({ops: [], extra: [], cmds: [], unc: false, soft: false, floor: [], nested_others: 0, effectful_inner: false};
         $command.n[$i] as $nested_command
         | (if has_word($own.data_words; ($nested_command.o // -1)) then $ctx else $ctx + {captured: true} end) as $nested_ctx
         | analyse($nested_command; $command.n[0:$i]; $command.n[$i + 1:]; $nested_ctx) as $inner
         | .ops += $inner.ops | .extra += $inner.extra | .cmds += $inner.cmds | .floor += $inner.floor
         | .unc = (.unc or $inner.unc) | .soft = (.soft or $inner.soft)
         # N4: a substitution that runs something other than a read-only command is another effectful command,
         # except the SQL statement a destructive-SQL operation was classified from (node -e "sql`DROP ...`").
         | (any($own.ops[]; has_word(.c; "destructive-sql"))
            and (([ $nested_command.w[].l ] | join(" ") | strip_sql_comments) | test(sql_destructive_regex; "i"))) as $operation_sql
         | ($inner.kind == "eff" and ($inner.own_op | not) and ($inner.readonly | not) and ($operation_sql | not)) as $effectful
         | .nested_others += $inner.nested_others + (if $effectful then 1 else 0 end)
         | .effectful_inner = (.effectful_inner or $effectful))) as $nested
    | {kind: (if $own.kind == "ctx" and $nested.effectful_inner then "eff" else $own.kind end),
       ops: ($own.ops + $nested.ops), extra: ($own.extra + $nested.extra),
       cmds: ($own.cmds + $nested.cmds), unc: ($own.unc or $nested.unc), soft: ($own.soft or $nested.soft),
       # A read-only command that only hosts a substitution holding the operation (`echo $(op)`) is not another command.
       own_op: ($own.own_op or ($own.readonly and ($nested.ops | length) > 0)), consumer: $own.consumer,
       readonly: $own.readonly, floor: ($own.floor + $nested.floor), nested_others: $nested.nested_others, defines: $own.defines};

  if $depth >= 6 then {units: [], uncertain: true, soft: false}
  else
    (parse_raw($text; $depth) | annotate_directories($outer.dir)) as $raw
    | collect_context($raw; $outer) as $ctx
    | reduce $raw.units[] as $unit ({units: [], uncertain: $raw.uncertain, soft: false, aliases: $ctx.aliases};
        (reduce range(0; $unit | length) as $i ({ops: [], extra: [], cmds: [], items: [], unc: false, soft: false, floor: [], nested_others: 0, aliases: .aliases};
           analyse($unit[$i]; $unit[0:$i]; $unit[$i + 1:]; $ctx + {aliases: .aliases}) as $result
           | .ops += $result.ops | .extra += $result.extra | .cmds += $result.cmds | .floor += $result.floor
           | .nested_others += $result.nested_others
           | .aliases += $result.defines
           | .items += [{kind: $result.kind, own_op: $result.own_op, readonly: $result.readonly}]
           | .unc = (.unc or $result.unc) | .soft = (.soft or $result.soft))) as $unit_result
        | .aliases = $unit_result.aliases
        | .soft = (.soft or $unit_result.soft)
        | ([ $unit_result.items[] | .kind ]) as $kinds
        | (if has_word($kinds; "eff") then "eff" elif has_word($kinds; "ctx") then "ctx" else "none" end) as $kind
        # Effectful commands that carry no operation of their own, plus effectful substitutions (N4).
        # A read-only command inside a pipeline (`op | tail -5`, `echo sql | psql`) does not count;
        # any other producer feeding a SQL client, shell or xargs does (`rm -rf y | psql`).
        | ($unit_result.items | length) as $pipeline_size
        | (([ $unit_result.items[] | select(.kind == "eff" and (.own_op | not) and (($pipeline_size > 1 and .readonly) | not)) ] | length)
           + $unit_result.nested_others) as $others
        | .uncertain = (.uncertain or $unit_result.unc)
        | .units += (if $kind == "none" and ($unit_result.ops | length) == 0 and ($unit_result.cmds | length) == 0 and ($unit_result.floor | length) == 0 then []
                     else [{kind: $kind, ops: $unit_result.ops, cmds: $unit_result.cmds, others: $others, floor: $unit_result.floor}] end)
        | .units += $unit_result.extra)
    | {units: .units, uncertain: .uncertain, soft: .soft}
  end;

def parse_script($text; $depth; $branch):
  parse_script_in($text; $depth; $branch; {files: {}, aliases: {}, captured: false, chdir: [], dir: "", opaque: false, writers: 0, runs: false, files_exposed: false, exports: [], classified: classified_programs});

# The keyword floor text of a parse: every unit's floor fragments, in order, on one line.
def floor_text($parsed): [ $parsed.units[].floor[] ] | join(" ") | gsub("[\\n\\t]"; " ");
