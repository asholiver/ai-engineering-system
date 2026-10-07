# Guard v2 lexer and raw command parser (jq, no dependencies beyond jq itself).
#
# Turns a Bash command string into units (a unit is one pipeline) of simple commands:
#   {w: [word], a: [assignment word], r: [redirect], n: [nested command], hdr: "loop"?}
# where a word is {l: literal text with quotes removed, d: true when it expands at run time,
# s: [command substitution text]}. Nothing here decides anything; classify.jq does that.
#
# Anything the parser is not sure about sets `uncertain`, and the caller falls back to the
# v0.2 keyword rules (which only ever ask). Written for jq 1.6+ (Oniguruma, Perl_NT syntax).

# ---------------------------------------------------------------- regex building blocks
# Balanced constructs use named groups with subexpression calls (\g<name>), so quotes and
# nested $( ) are matched as units. Every repetition is atomic, so a failed match is linear.
#   dq: "(?>[^"\\$`]+|\\.|\$(?![({])|\$\g<pa>|\$\g<br>|\g<bt>)*"
def re_dq: "(?<dq>\"(?>[^\"\\\\$`]+|\\\\[\\s\\S]|\\$(?![({])|\\$\\g<pa>|\\$\\g<br>|\\g<bt>)*\")";
#   pa: parentheses body, nested, quote-aware
def re_pa: "(?<pa>\\((?>[^()'\"`\\\\]+|\\\\[\\s\\S]|'[^']*'|\\g<dq>|\\g<bt>|\\g<pa>)*\\))";
#   br: braces body, nested, quote-aware
def re_br: "(?<br>\\{(?>[^{}'\"`\\\\]+|\\\\[\\s\\S]|'[^']*'|\\g<dq>|\\g<bt>|\\g<br>)*\\})";
#   bt: backquote command substitution
def re_bt: "(?<bt>`(?>[^`\\\\]+|\\\\[\\s\\S])*`)";

# One piece of a shell word: quoted string, substitution, escape or plain run.
def re_atom:
  "(?>'[^']*'"
  + "|\\$'(?>[^'\\\\]+|\\\\[\\s\\S])*'"
  + "|" + re_dq
  + "|\\$" + re_pa
  + "|\\$" + re_br
  + "|" + re_bt
  + "|[<>]\\g<pa>"
  + "|\\\\[\\s\\S]"
  + "|\\$(?<sus>(?=[({]))"
  + "|\\$"
  + "|[^\\s;&|()<>'\"`\\\\$]+)";

# Tokens: newline | comment | redirection | control operator | word | any other character.
def re_token:
  "\\n"
  + "|#[^\\n]*"
  + "|[0-9]*(?:<<<|<<-?|>>|>&|<&|>\\||&>>|&>|<>|>|<)(?!\\()"
  + "|&&|\\|\\||\\|&|;;&?|;&|[;&|()]"
  + "|(?>" + re_atom + "+)"
  + "|[^\\s]";

# Text inside double quotes, heredoc bodies and ${...}: finds $( ) and backquote substitutions.
# The dq group is defined (never matched) because pa and br call it.
def re_expansion_scan:
  "(?>\\\\[\\s\\S]|\\$" + re_pa + "|\\$" + re_br + "|" + re_bt + "|(?!)" + re_dq
  + "|\\$(?<sus>(?=[({]))|[^\\\\$`]+|\\$|`)";

# ---------------------------------------------------------------- windowed scanning
# jq computes each global match's offset by walking the string from its start, so scanning a
# large text in one go is quadratic. Scanning bounded windows and restarting at the last
# complete match keeps it linear. A construct that fails to close inside a partial window is
# flagged ("suspect"), and the window then grows; in the final window a suspect match means
# the construct really is unbalanced.
def suspect_match($m):
  ($m.string | IN("'", "\"", "`", "\\"))
  or (($m.string | contains("$")) and any($m.captures[]; .name == "sus" and .offset >= 0));

# Emits {ms: [{o: offset, s: string}], bad: boolean} for a global scan of `.`.
def scan_windows($regex):
  . as $text
  | ($text | length) as $length
  | {pos: 0, width: 2048, out: [], bad: false}
  | until(.pos >= $length;
      . as $state
      | ($state.pos + $state.width >= $length) as $final
      | [ $text[$state.pos:$state.pos + $state.width] | match($regex; "g") ] as $found
      | ([ $found[] | select(suspect_match(.)) ] | length > 0) as $suspect
      | if $final then
          .out += [ $found[] | {o: (.offset + $state.pos), s: .string} ]
          | .bad = $suspect | .pos = $length
        elif $suspect or ($found | length) < 2 then .width *= 2
        else
          .out += [ $found[0:-1][] | {o: (.offset + $state.pos), s: .string} ]
          | .pos += $found[-1].offset | .width = 2048
        end)
  | {ms: .out, bad: .bad};

# ---------------------------------------------------------------- words
def unescape_double_quoted:
  if contains("\\") then gsub("\\\\(?<c>[$`\"\\\\])"; .c) | gsub("\\\\\n"; "") else . end;

def unescape_backquote:
  if contains("\\") then gsub("\\\\(?<c>[`$\\\\])"; .c) else . end;

# Command substitutions inside expandable text (not inside single quotes).
def expansion_substitutions:
  if test("[$`]") | not then []
  else
    [ scan_windows(re_expansion_scan).ms[].s
      | if startswith("$(") then .[2:-1]
        elif startswith("`") and length > 1 then (.[1:-1] | unescape_backquote)
        elif startswith("${") then (.[2:-1] | expansion_substitutions[])
        else empty end ]
  end;

# Analyse one raw word token into {l, d, s}.
def word_info:
  . as $raw
  | if test("['\"\\\\$`<>]") | not then {l: $raw, d: test("[*?\\[]|\\{[^}]*,"), s: []}
    elif test("^'[^']*'$") then {l: .[1:-1], d: false, s: []}
    elif test("^\"(?>[^\"\\\\$`]+|\\\\[\\s\\S])*\"$") then {l: (.[1:-1] | unescape_double_quoted), d: false, s: []}
    else
      reduce (match(re_atom; "g") | .string) as $atom ({l: "", d: false, s: []};
        $atom[0:1] as $first
        | if $first == "'" then .l += $atom[1:-1]
          elif $first == "\"" then
            ($atom[1:-1]) as $inner
            | .l += ($inner | unescape_double_quoted)
            | if ($inner | test("[$`]")) then .d = true | .s += ($inner | expansion_substitutions) else . end
          elif $first == "\\" then .l += (if $atom == "\\\n" then "" else $atom[1:] end)
          elif $first == "`" then .d = true | .l += $atom | .s += [$atom[1:-1] | unescape_backquote]
          elif $first == "$" then
            $atom[1:2] as $next
            | if $next == "(" then .d = true | .l += $atom | .s += [$atom[2:-1]]
              elif $next == "{" then .d = true | .l += $atom | .s += ($atom[2:-1] | expansion_substitutions)
              elif $next == "'" then .l += $atom[2:-1] | if ($atom | contains("\\")) then .d = true else . end
              else .d = true | .l += $atom end
          elif $first == "<" or $first == ">" then .d = true | .l += $atom | .s += [$atom[2:-1]]
          else
            .l += $atom
            | if ($atom | test("[*?\\[]|\\{[^}]*,")) then .d = true else . end
          end)
  end;

# ---------------------------------------------------------------- lexer
# Returns {t: tokens, bad: boolean}. Newline tokens are their offset (a number) so heredoc
# bodies can be located; every other token is its text. bad: an unclosed quote or $( ${.
def tokenize($text):
  $text | scan_windows(re_token)
  | {t: [ .ms[] | if .s == "\n" then .o else .s end ], bad: .bad};

# Finds the first newline that follows pending heredoc operators:
#   {i: token index, off: newline offset, ops: [{strip, word}]} or null.
def pending_heredocs($tokens):
  (reduce range(0; $tokens | length) as $i ({pending: [], expect: null, hit: null};
      if .hit != null then .
      else
        $tokens[$i] as $token
        | if ($token | type) == "number" then
            (if (.pending | length) > 0 then .hit = {i: $i, off: $token, ops: .pending} else . end)
          elif .expect != null then .pending += [{strip: .expect, word: $token}] | .expect = null
          elif ($token | test("^[0-9]*<<-?$")) then .expect = ($token | endswith("-"))
          else . end
      end)).hit;

def regex_escape: gsub("(?<c>[^A-Za-z0-9_])"; "\\\(.c)");

# Reads the heredoc bodies that start at offset $start of $rest.
def read_heredoc_bodies($rest; $start; $ops):
  reduce $ops[] as $op ({p: $start, bodies: [], unterminated: false};
    ($op.word | word_info) as $word
    | ($word.l | regex_escape) as $delimiter
    | ($rest[.p:]) as $tail
    | ([ $tail | match("(?:\\A|\\n)" + (if $op.strip then "\\t*" else "" end) + $delimiter + "(?:\\n|\\z)") ] | .[0]) as $end
    | ($op.word | test("['\"\\\\]")) as $quoted
    | if $end == null then
        .bodies += [{body: $tail, quoted: $quoted}] | .p = ($rest | length) | .unterminated = true
      else
        .bodies += [{body: $tail[0:$end.offset], quoted: $quoted}] | .p += $end.offset + $end.length
      end);

def append_tokens($tokens): .toks += [$tokens[] | if type == "number" then "\n" else . end];

# One lexing step. Heredoc bodies are cut out by offset before the rest is tokenised, so
# quotes inside a body can never confuse the tokeniser. Only the text up to the line that
# holds the next heredoc operator is tokenised in each step.
def lex_step:
  . as $state
  | $state.rest as $rest
  | ([ $rest | match("(?<!<)<<(?!<)") ] | .[0].offset) as $candidate
  | if $candidate == null then
      tokenize($rest) as $lexed
      | $state | append_tokens($lexed.t) | .bad = (.bad or $lexed.bad) | .rest = ""
    else
      ([ $rest[$candidate:] | match("\n") ] | .[0].offset) as $newline
      | (if $newline == null then ($rest | length) else $candidate + $newline + 1 end) as $end
      | tokenize($rest[0:$end]) as $first_try
      | (if $end < ($rest | length) and $first_try.bad
         then [tokenize($rest), ($rest | length)]
         else [$first_try, $end] end) as [$lexed, $length]
      | pending_heredocs($lexed.t) as $hit
      | if $hit == null then
          $state | append_tokens($lexed.t) | .bad = (.bad or $lexed.bad) | .rest = $rest[$length:]
        else
          read_heredoc_bodies($rest; $hit.off + 1; $hit.ops) as $read
          | tokenize($rest[0:$hit.off + 1]) as $line
          | $state
          | append_tokens($lexed.t[0:$hit.i + 1])
          | .bad = (.bad or $line.bad or $read.unterminated)
          | .hd += $read.bodies
          | .rest = $rest[$read.p:]
        end
    end
  | .steps += 1;

def lex($text):
  {rest: $text, toks: [], hd: [], bad: false, steps: 0}
  | until(.rest == "" or .steps >= 64; lex_step)
  | .bad = (.bad or .rest != "");

# ---------------------------------------------------------------- raw parser
def empty_command: {w: [], a: [], r: [], n: []};
def command_words_count: (.w | length) + (.a | length) + (.r | length) + (.n | length);

def finish_command:
  if .cur.skip then
    .cur = ({w: [], a: [], r: [], n: .cur.n} + (if .cur.hdr then {hdr: .cur.hdr} else {} end))
  else . end
  | if (.cur | command_words_count) > 0 or .cur.hdr == "loop"
    then .units[-1] += [.cur] | .cur = empty_command
    else .cur = empty_command end;

def new_unit: if (.units[-1] | length) > 0 then .units += [[]] else . end;

def reserved_heads: ["if", "then", "elif", "else", "fi", "while", "until", "do", "done", "esac", "}", "{", "!", "function"];

def is_redirect_token: test("^[0-9]*(<<<|<<-?|>>|>&|<&|>\\||&>>|&>|<>|>|<)$");

def parse_raw($text; $depth):
  lex($text) as $lexed
  | reduce $lexed.toks[] as $token (
      {units: [[]], cur: empty_command, pending: null, hd_index: 0, parens: 0,
       in_case_pattern: false, in_bracket: false, fn_name: false, bad: $lexed.bad};
      # Nested command text goes through the same parser; its commands join the current one.
      def add_word($word):
        reduce $word.s[] as $text (.;
          if $depth >= 6 or ($word.s | length) > 100 then .bad = true
          else
            parse_raw($text; $depth + 1) as $inner
            | .cur.n += [$inner.units[][]]
            | .bad = (.bad or $inner.uncertain)
          end);
      def word_in_command($raw):
        ($raw | word_info) as $word
        | if .in_case_pattern then
            (if $raw == "esac" then .in_case_pattern = false else add_word($word) end)
          elif .pending != null then
            .pending as $redirect
            | (if $redirect == "<<" or $redirect == "<<-" then
                 (.hd_index as $index
                  | if ($lexed.hd[$index] // null) == null then .bad = true | .cur.r += [{op: "<<", t: $word.l, body: ""}]
                    else
                      $lexed.hd[$index] as $heredoc
                      | .cur.r += [{op: "<<", t: $word.l, body: $heredoc.body}]
                      | .hd_index += 1
                      | if $heredoc.quoted or ($heredoc.body | test("[$`]") | not) then .
                        else add_word({s: ($heredoc.body | expansion_substitutions)}) end
                    end)
               else
                 .cur.r += [{op: $redirect, t: $word.l, d: $word.d}] | add_word($word)
               end)
            | .pending = null
          elif .in_bracket then
            .cur.w += [$word] | add_word($word) | if $raw == "]]" then .in_bracket = false else . end
          elif (.cur.w | length) == 0 and (.cur.skip | not) then
            # `function NAME { ...; }`: the word after `function` is the name, not a command.
            if .fn_name then .fn_name = false
            elif $raw == "function" then .fn_name = true
            elif ($raw | IN(reserved_heads[])) then .
            elif $raw == "for" or $raw == "select" then .cur.skip = true | .cur.hdr = "loop"
            elif $raw == "case" then .cur.skip = true | .in_case_pattern = true
            elif ($raw | test("^[A-Za-z_][A-Za-z0-9_]*\\+?=")) then .cur.a += [$word] | add_word($word)
            else
              .cur.w += [$word] | add_word($word)
              | if $raw == "[[" then .in_bracket = true else . end
            end
          else
            if .cur.skip then .cur.n += [] | add_word($word) else .cur.w += [$word] | add_word($word) end
          end;
      def operator($op):
        if .in_bracket and ($op | IN("&&", "||", "(", ")")) then .cur.w += [{l: $op, d: false, s: []}]
        elif $op == "|" or $op == "|&" then (if .in_case_pattern then . else finish_command end)
        elif $op == "(" and .in_case_pattern then .
        elif $op == "(" then finish_command | new_unit | .parens += 1
        elif $op == ")" then
          if .in_case_pattern then finish_command | .in_case_pattern = false
          elif .parens > 0 then finish_command | new_unit | .parens -= 1
          else finish_command | .bad = true end
        elif .in_case_pattern then .
        elif $op == ";;" or $op == ";&" or $op == ";;&" then finish_command | new_unit | .in_case_pattern = true
        else finish_command | new_unit | .in_bracket = false end;
      if ($token | startswith("#")) then .
      elif $token == "\n" then
        if .in_case_pattern then . else finish_command | new_unit | .in_bracket = false end
      elif ($token | IN("&&", "||", "|", "|&", ";", "&", ";;", ";&", ";;&", "(", ")")) then
        (if .pending != null then .bad = true | .pending = null else . end) | operator($token)
      elif ($token | is_redirect_token) then
        if .in_bracket then .cur.w += [{l: $token, d: false, s: []}]
        elif .in_case_pattern then .
        else (if .pending != null then .bad = true else . end) | .pending = ($token | sub("^[0-9]+"; "")) end
      else word_in_command($token) end)
  | finish_command
  | {units: [.units[] | select(length > 0)],
     uncertain: (.bad or .parens != 0 or .pending != null or .in_case_pattern)};
