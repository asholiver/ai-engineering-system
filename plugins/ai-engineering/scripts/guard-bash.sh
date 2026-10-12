#!/bin/bash
# PreToolUse hook for Bash. Classifies parsed actions (not command text) and requires
# explicit human approval ("ask") for reserved operations, or denies a reserved operation
# bundled with other commands so each approval covers exactly one operation.
#
# Structure: this script is the hook wrapper. guard/lexer.jq parses, guard/classify.jq and
# guard/tables.jq classify, guard/policy.jq decides, all in one jq run (guard/main.jq).
# Safety floor: the v0.2 keyword rules always run over the command text minus proven data
# spans (guard/tables.jq lists them), so classification can raise a decision but never drop
# it below ask. When the parse is not confident (unbalanced quotes, a dynamic program name, an
# error, a timeout or an oversized command) the keyword rules run over the whole command
# instead, and ask. Their one deny (RR3-3 owner ruling) is a git-restricted agent's Git write that
# guard/fallback.jq establishes independently of the failed parse; unparseable alone never denies.
# The guard never returns "allow".
#
# Hook-time Git is limited to lookups (branch, root and common directory) through
# guard/hook-git.sh; it reads no objects, trees or index (Option B and F5-3, owner
# decision 2026-10-12). State-changing Git commands ask instead (guard/policy.jq git_state_policy).
# A lookup that a decision depends on and that fails, or that the hook environment redirects,
# turns no decision into ask (NF-3).
#
# This is a guardrail, not a security sandbox: it only sees the command text Claude
# submits. Indirection (scripts, aliases, variables, encoded strings) can evade it.
set -u

parse_time_budget_seconds=3
log_max_bytes=1048576
guardrail_note="Hooks are guardrails, not a sandbox."

# Prints an ask decision without needing jq (reasons here contain no quotes or backslashes).
ask() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

if ! command -v jq >/dev/null 2>&1; then
  ask "ai-engineering guard: jq is missing, so this command cannot be inspected. Approve only if it is not a high-impact operation. $guardrail_note"
fi

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guard_directory="$script_directory/guard"
# The only Git this hook runs (RR3-1): hardened plumbing, one deadline for every call.
# shellcheck source=guard/hook-git.sh
source "$guard_directory/hook-git.sh"

hook_input="$(cat)"
classifier_output_file="$(mktemp "${TMPDIR:-/tmp}/ai-engineering-guard.XXXXXX" 2>/dev/null)" || classifier_output_file=""
cleanup() { [ -z "$classifier_output_file" ] || rm -f "$classifier_output_file" "$classifier_output_file.git" "$classifier_output_file.fallback"; }
trap cleanup EXIT
[ -z "$classifier_output_file" ] || hook_git_output_file="$classifier_output_file.git"
working_directory=""
working_directory_loaded=""
directory_for_git() {
  if [ -z "$working_directory_loaded" ]; then
    working_directory="$(jq -r '.cwd // empty' <<<"$hook_input" 2>/dev/null)"
    working_directory_loaded=1
  fi
  printf '%s' "${working_directory:-$PWD}"
}

# NF-3: set when a lookup a decision depends on cannot be trusted, so that no decision becomes ask.
# Untrusted means the hook environment sets Git variables that redirect Git (the hook's Git runs
# without them, the command with them), or the lookup failed although the working directory is in
# a Git work tree (guard/hook-git.sh hook_git_in_work_tree). Outside any work tree a failed lookup
# is expected and changes nothing.
git_lookup_failed=""
note_git_lookup() {
  if hook_git_environment_overrides || { [ "$1" -ne 0 ] && hook_git_in_work_tree "$(directory_for_git)"; }; then
    git_lookup_failed=1
  fi
  return 0
}

# ---------------------------------------------------------------- guard log
# One JSON line per ask or deny in <git-common-dir>/ai-engineering/guard-log.jsonl:
# time, session id, agent type, decision, classes, parse mode and the SHA-256 of the command.
# Never the command text. Rotated at 1 MiB (one previous file kept). A failure here never
# changes the decision.
command_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    jq -j '.tool_input.command // ""' <<<"$hook_input" 2>/dev/null | shasum -a 256 | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    jq -j '.tool_input.command // ""' <<<"$hook_input" 2>/dev/null | sha256sum | cut -d' ' -f1
  fi
}

# True when the caller is a subagent that may only run read-only Git (see guard/policy.jq).
restricted_agent() {
  case "$(jq -r '.agent_type // empty' <<<"$hook_input" 2>/dev/null)" in
    ai-engineering:frontend | ai-engineering:backend | ai-engineering:platform | ai-engineering:qa | ai-engineering:security-reviewer | ai-engineering:learning) return 0 ;;
  esac
  return 1
}

# Prints the absolute Git common directory of the working directory (nothing, and status 1, when unknown).
resolve_common_directory() {
  local directory common_directory
  directory="$(directory_for_git)"
  hook_git_common_directory "$directory" || return 1
  common_directory="$hook_git_output"
  [ -n "$common_directory" ] || return 1
  case "$common_directory" in /*) ;; *) common_directory="$directory/$common_directory" ;; esac
  printf '%s' "$common_directory"
}

# Rotation under a mkdir lock, so two hooks do not rotate at once. Best effort: when another
# hook holds the lock this one skips rotating and never waits. A lock older than a minute is stale.
# A symbolic link planted as the previous log is removed first (mv onto a link to a directory
# would move the log into that directory); anything else there that is not a regular file
# stops the rotation.
rotate_guard_log() {
  local log_directory="$1" log_file="$2" lock size
  lock="$log_directory/.rotate.lock"
  if [ -d "$lock" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir "$lock" 2>/dev/null; fi
  mkdir "$lock" 2>/dev/null || return 0
  size="$(wc -c <"$log_file" 2>/dev/null | tr -d ' ')"
  if [ "${size:-0}" -gt "$log_max_bytes" ]; then
    if [ -L "$log_file.1" ]; then rm -f "$log_file.1" 2>/dev/null; fi
    if [ ! -e "$log_file.1" ] || { [ -f "$log_file.1" ] && [ ! -L "$log_file.1" ]; }; then
      mv -f "$log_file" "$log_file.1" 2>/dev/null
    fi
  fi
  rmdir "$lock" 2>/dev/null
  return 0
}

write_guard_log() {
  local decision="$1" classes="$2" parse_mode="$3"
  local common_directory log_directory log_file size digest
  common_directory="$(resolve_common_directory)"
  [ -n "$common_directory" ] || return 0
  log_directory="$common_directory/ai-engineering"
  log_file="$log_directory/guard-log.jsonl"
  # Never follow a symbolic link planted where the log lives (it could redirect the append).
  [ ! -L "$log_directory" ] || return 0
  (umask 077 && mkdir -p "$log_directory") 2>/dev/null || return 0
  [ ! -L "$log_directory" ] && [ ! -L "$log_file" ] || return 0
  if [ -f "$log_file" ]; then
    size="$(wc -c <"$log_file" 2>/dev/null | tr -d ' ')"
    if [ "${size:-0}" -gt "$log_max_bytes" ]; then rotate_guard_log "$log_directory" "$log_file"; fi
    # Still over the cap (rotation refused or skipped): stay bounded and drop this line.
    size="$(wc -c <"$log_file" 2>/dev/null | tr -d ' ')"
    [ "${size:-0}" -le $((log_max_bytes * 2)) ] || return 0
  fi
  digest="$(command_sha256)"
  jq -c --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg decision "$decision" --arg classes "$classes" \
    --arg mode "$parse_mode" --arg digest "$digest" \
    '{time: $time, sessionId: (.session_id // null), agentType: (.agent_type // null), decision: $decision,
      classes: ($classes | split(",") | map(select(length > 0))), parseMode: $mode, commandSha256: $digest}' \
    <<<"$hook_input" >>"$log_file" 2>/dev/null
}

# Classify-only mode (explicit --classify-only argument, used by lib.sh): prints the
# decision and the comma-separated classes on two lines instead of hook output, and never
# writes a guard-log entry, so a classification query cannot be mistaken for a tool call.
# Deliberately an argument, not an environment variable: the hook is invoked with no
# arguments, and the environment (settings env blocks, exports) must not change its output.
classify_only=""
[ "${1:-}" = "--classify-only" ] && classify_only=1
log_decision() {
  [ -z "$classify_only" ] || return 0
  write_guard_log "$@" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- keyword fallback
# v0.2-style keyword rules (the same rules as keyword_net in guard/tables.jq). Mode "fallback":
# the parse is not confident, so they run over the whole command, with a few extra rules. Mode
# "floor": the parse found nothing to decide but its floor text (the command minus proven data)
# was too large to scan in jq, so the same rules run over that text here (grep is linear).
# They only ever ask.
# Word boundaries: a keyword starts after start-of-text or a non-word character and ends
# before a non-word character or end-of-text. Arguments may follow the tool name after any
# separator, so `$(echo terraform) apply` and `which kubectl` in backquotes are caught.
fallback_intents=()
fallback_command_text=""
fallback_flag() {
  local intent
  for intent in ${fallback_intents[@]+"${fallback_intents[@]}"}; do [ "$intent" = "$1" ] && return 0; done
  fallback_intents+=("$1")
}
fallback_matches() { grep -Eiq -- "$1" <<<"$fallback_command_text"; }

# The text the keyword rules read, as one line per variant (NR-1, NR-2; same as
# keyword_text_variants in guard/tables.jq). Newline, tab, CR, FF, VT and the Unicode spaces are
# separators. Text with non-ASCII characters is read twice: with the APFS look-alikes folded
# (U+017F long s, U+212A Kelvin sign, the ff/fi/fl/ffi/ffl/st ligatures) and with every other
# non-ASCII byte removed. Byte-wise sed and tr (LC_ALL=C), so it is linear and locale-independent.
keyword_text() {
  local text spaced odd_space_sed look_alike_sed
  text="$(tr '\n\t\r\f\v' '     ')"
  if [ -z "$(printf '%s' "$text" | LC_ALL=C tr -d '\001-\177')" ]; then
    printf '%s\n' "$text"
    return 0
  fi
  odd_space_sed="$(printf 's/\xc2[\x85\xa0]/ /g;s/\xe1\x9a\x80/ /g;s/\xe1\xa0\x8e/ /g;s/\xe2\x80[\x80-\x8d\xa8\xa9\xaf]/ /g;s/\xe2\x81[\x9f\xa0]/ /g;s/\xe3\x80\x80/ /g;s/\xef\xbb\xbf/ /g')"
  look_alike_sed="$(printf 's/\xc5\xbf/s/g;s/\xe2\x84\xaa/k/g;s/\xef\xac\x80/ff/g;s/\xef\xac\x81/fi/g;s/\xef\xac\x82/fl/g;s/\xef\xac\x83/ffi/g;s/\xef\xac\x84/ffl/g;s/\xef\xac[\x85\x86]/st/g')"
  spaced="$(printf '%s' "$text" | LC_ALL=C sed -e "$odd_space_sed")"
  printf '%s\n' "$(printf '%s' "$spaced" | LC_ALL=C sed -e "$look_alike_sed")"
  printf '%s\n' "$(printf '%s' "$spaced" | LC_ALL=C tr -d '\200-\377')"
}

keyword_fallback() {
  local branch="$1" mode="${2:-fallback}"
  local word_start='(^|[^[:alnum:]_-])' word_end='([^[:alnum:]_-]|$)'
  local argument_start='(^|[[:space:]])'
  local gap='([^[:alnum:]_-].*)?[^[:alnum:]_-]'
  local risky_task='[^[:space:]]*(deploy|release|publish|destroy|teardown)[^[:space:]]*'
  if [ "$mode" = "floor" ]; then
    fallback_command_text="$(printf '%s' "$floor_text" | keyword_text)"
  else
    fallback_command_text="$(jq -r '.tool_input.command // empty' <<<"$hook_input" 2>/dev/null | keyword_text)"
  fi
  [ -n "$fallback_command_text" ] || return 0

  fallback_matches "${word_start}(terraform|tofu|terragrunt)${gap}(apply|destroy)${word_end}" && fallback_flag infrastructure-apply
  fallback_matches "${word_start}pulumi${gap}(up|destroy)${word_end}" && fallback_flag infrastructure-apply
  fallback_matches "${word_start}(cdk|cdktf|aws-cdk)${gap}(deploy|destroy)${word_end}" && fallback_flag infrastructure-apply
  fallback_matches "${word_start}(serverless|sls|sam)${gap}(deploy|remove|delete)${word_end}" && fallback_flag infrastructure-apply

  fallback_matches "${word_start}(kubectl|oc)${gap}(delete|drain)${word_end}" && fallback_flag kubernetes-delete
  fallback_matches "${word_start}helm${gap}(uninstall|delete)${word_end}" && fallback_flag kubernetes-delete
  fallback_matches "${word_start}(aws|gcloud|az|gsutil)${gap}(rm|rb|[[:alnum:]-]*(delete|terminate|destroy|purge|remove|deregister)[[:alnum:]-]*)${word_end}" && fallback_flag cloud-destructive
  fallback_matches "${word_start}aws${gap}sync${word_end}.*--delete" && fallback_flag cloud-destructive

  fallback_matches "${word_start}drop[[:space:]]+(table|database|schema|view|index|user|role|function|procedure)${word_end}" && fallback_flag destructive-sql
  fallback_matches "${word_start}truncate${word_end}" && fallback_flag destructive-sql

  if fallback_matches "${word_start}git${gap}push${word_end}"; then
    # The flag may follow any separator (`${FLAG:---force}`, `$(echo --force)`), not only a space.
    fallback_matches "(^|[^[:alnum:]_])(--force|--force-with-lease(=[^[:space:]]*)?|--mirror|--delete|-[[:alpha:]]*[fd][[:alpha:]]*)${word_end}" && fallback_flag git-force-push
    fallback_matches "${argument_start}(\+|:)[^[:space:]]+" && fallback_flag git-force-push
    fallback_matches "${argument_start}([^[:space:]]*:)?(refs/heads/)?(main|master)${word_end}" && fallback_flag git-main-push
    fallback_matches "${argument_start}(--tags|--follow-tags|[^[:space:]]*refs/tags/[^[:space:]]*)${word_end}" && fallback_flag git-tag-push
    case "$branch" in main | master) fallback_flag git-main-push ;; esac
  fi

  fallback_matches "${word_start}gh${gap}pr[[:space:]]+merge${word_end}" && fallback_flag pr-merge
  fallback_matches "${word_start}glab${gap}mr[[:space:]]+merge${word_end}" && fallback_flag pr-merge
  fallback_matches "${word_start}gh${gap}api${word_end}.*pulls/[0-9]+/merge" && fallback_flag pr-merge
  fallback_matches "${word_start}(gh|glab)${gap}release[[:space:]]+(create|delete|edit|upload)${word_end}" && fallback_flag release-create
  fallback_matches "${word_start}(npm|pnpm|yarn|bun)${gap}publish${word_end}" && fallback_flag package-publish
  fallback_matches "${word_start}(cargo|poetry|flit|hatch)${gap}publish${word_end}" && fallback_flag package-publish
  fallback_matches "${word_start}twine${gap}upload${word_end}" && fallback_flag package-publish
  fallback_matches "${word_start}(gem|nuget)${gap}push${word_end}" && fallback_flag package-publish
  fallback_matches "${word_start}(docker|podman)${gap}push${word_end}" && fallback_flag image-publish

  fallback_matches "${word_start}(neon|neonctl)${gap}(branches?|projects?|databases?|roles?)${gap}(delete|rm)${word_end}" && fallback_flag platform-destructive
  fallback_matches "${word_start}(vercel|vc)${gap}(remove|rm)${word_end}" && fallback_flag platform-destructive
  fallback_matches "${word_start}(vercel|vc)${gap}(promote|rollback)${word_end}" && fallback_flag production-deploy
  fallback_matches "${word_start}(vercel|vc)${gap}--prod(uction)?${word_end}" && fallback_flag production-deploy
  fallback_matches "${word_start}(vercel|vc|netlify|ntl)${gap}deploy${word_end}" && fallback_flag unclassified-deploy

  fallback_matches "${word_start}(npm|pnpm|yarn|bun)${gap}${risky_task}" && fallback_flag unclassified-deploy
  fallback_matches "${word_start}(make|just|task|mage)${gap}${risky_task}" && fallback_flag unclassified-deploy
  fallback_matches "${argument_start}[^[:space:]]*/[^[:space:]/]*(deploy|release|publish|destroy|teardown)[^[:space:]/]*" && fallback_flag unclassified-deploy

  # The floor needs only the rules above: the parsed policy has already judged the store,
  # HTTP endpoints and Git by subagents.
  [ "$mode" = "floor" ] && return 0

  # The authority store cannot be proven untouched when the parse is not confident, so a
  # command that names it asks (the parsed path denies writes outright).
  fallback_matches "(\.state\.json|ai-engineering/tokens)" && fallback_flag authority-store-write

  # HTTP clients and gh against reserved endpoints (the parsed path classifies these by method).
  fallback_matches "${word_start}(curl|wget|https?|xhs?|gh|glab)${gap}releases${word_end}" && fallback_flag release-create
  fallback_matches "${word_start}(curl|wget|https?|xhs?|gh|glab)${gap}(deployments|deploys)${word_end}" && fallback_flag unclassified-deploy
  fallback_matches "${word_start}(curl|wget|https?|xhs?|gh|glab)${gap}(merge|merges)${word_end}" && fallback_flag pr-merge
  fallback_matches "${word_start}(curl|wget|https?|xhs?|gh|glab)${gap}git/refs" && fallback_flag git-force-push
  fallback_matches "${word_start}(npx|pnpm|yarn|bunx|bun)${gap}netlify-cli" && fallback_flag unclassified-deploy

  # RR3-2: the classes the parsed policy decides at hook time or by destination (N6(a) Git state,
  # N6(b) patches, NR-4 Git index and tree writers, whole-tree copy, sync and extraction) cannot be
  # judged without the parse, so their words ask. Over-asking here is accepted.
  fallback_matches "${word_start}git${gap}(checkout|switch|merge|pull|rebase|cherry-pick|revert|stash|restore|reset|rm|mv|clean|apply|am|read-tree|checkout-index|update-index|hash-object)${word_end}" && fallback_flag protected-tree-overwrite
  fallback_matches "${word_start}patch${word_end}" && fallback_flag protected-tree-overwrite
  fallback_matches "${word_start}cp${gap}(-[[:alpha:]]*[rRa][[:alpha:]]*|--recursive|--archive)${word_end}" && fallback_flag protected-tree-overwrite
  fallback_matches "${word_start}(rsync|ditto|unzip)${word_end}" && fallback_flag protected-tree-overwrite
  fallback_matches "${word_start}(tar|gtar|bsdtar)${gap}(-?[[:alpha:]]*x[[:alpha:]]*|--extract|--get)${word_end}" && fallback_flag protected-tree-overwrite
  fallback_matches "${word_start}cpio${gap}(-[[:alpha:]]*[ip][[:alpha:]]*|--extract|--pass-through)${word_end}" && fallback_flag protected-tree-overwrite
  fallback_matches "${word_start}pax${gap}-[[:alpha:]]*r[[:alpha:]]*${word_end}" && fallback_flag protected-tree-overwrite
  fallback_matches "${word_start}7z[az]?${gap}[xe]${word_end}" && fallback_flag protected-tree-overwrite

  # A restricted agent (the allow-list for Git). RR3-3 owner ruling: "unparseable => deny" is
  # forbidden; "unparseable + an independently established prohibited operation => deny" is
  # allowed. guard/fallback.jq establishes a Git write only where it is certain: a literal `git`
  # in command position (outside quotes, substitutions, heredocs and comments, read with Bash's
  # own word splitting) with a literal write subcommand or a non-read form of stash, branch, tag,
  # worktree, remote or config. That denies, so degraded parsing cannot erase the fact. Anything
  # it cannot establish (a dynamic Git program or subcommand, git as data, an unknown subcommand,
  # a Git-relevant variable assignment, an error or timeout) asks.
  if restricted_agent; then
    run_fallback_git_check
    case "$fallback_git_verdict" in
      deny) restricted_git_write="$fallback_git_label"; fallback_flag git-write-by-subagent ;;
      ok) ;;
      *) fallback_flag git-write-by-subagent ;;
    esac
  fi
  return 0
}

# Runs guard/fallback.jq once under a watchdog (process group killed on timeout). Sets
# fallback_git_verdict (deny | ask | ok; anything else, including a failure, is treated as ask)
# and fallback_git_label (git <subcommand>, only for deny).
fallback_git_budget_seconds=3
restricted_git_write=""
fallback_git_verdict="" fallback_git_label=""
run_fallback_git_check() {
  local pid watchdog
  fallback_git_verdict="ask" fallback_git_label=""
  [ -n "$classifier_output_file" ] || return 0
  set -m
  jq -r -L "$guard_directory" -f "$guard_directory/fallback.jq" <<<"$hook_input" >"$classifier_output_file.fallback" 2>/dev/null &
  pid=$!
  (sleep "$fallback_git_budget_seconds"; kill -KILL -- "-$pid") </dev/null >/dev/null 2>&1 &
  watchdog=$!
  set +m
  if wait "$pid" 2>/dev/null; then
    { read -r fallback_git_verdict; read -r fallback_git_label; } <"$classifier_output_file.fallback"
  else
    fallback_git_verdict="ask"
  fi
  kill -KILL -- "-$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  # The label goes into the reason unquoted: only `git <subcommand>` in lower-case letters is used.
  case "$fallback_git_label" in
    git\ [[:lower:]]*) case "${fallback_git_label#git }" in *[![:lower:][:digit:]-]*) fallback_git_verdict="ask" fallback_git_label="" ;; esac ;;
    *) [ "$fallback_git_verdict" != deny ] || fallback_git_verdict="ask"; fallback_git_label="" ;;
  esac
  return 0
}

# ---------------------------------------------------------------- shell-edit hint
# For implementation agents that edit a file through the shell, PreToolUse context with NO
# permission decision (never asked, denied or logged). The classifier says "hint" outright, or
# "check" with redirection targets; a redirection counts when it overwrites an existing regular
# file. F5-3: no Git is run for this (an index read can expand a sparse index and read trees); an
# existing untracked file also gets the hint, which is harmless context.
emit_shell_edit_hint() {
  local target existing=""
  if [ "$hint_state" = "check" ]; then
    while IFS= read -r target; do
      [ -n "$target" ] || continue
      case "$target" in /*) ;; *) target="$(directory_for_git)/$target" ;; esac
      if [ -f "$target" ]; then existing=1; break; fi
    done < <(jq -r '.[]' <<<"$hint_targets" 2>/dev/null)
    [ -n "$existing" ] && hint_state="hint"
  fi
  [ "$hint_state" = "hint" ] || return 0
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"Use Edit/Write for file changes."}}'
}

# ---------------------------------------------------------------- decision
current_branch=""
branch_loaded="0"
load_current_branch() {
  local status
  current_branch=""
  hook_git_current_branch "$(directory_for_git)"
  status=$?
  [ "$status" -ne 0 ] || current_branch="$hook_git_output"
  note_git_lookup "$status"
  branch_loaded="1"
}
# Cheap guesses, matched without regard to case (NR-5: `git PUSH` and `GIT push` run a push on a
# case-insensitive file system, and a missed guess costs a second jq run). A push spelled so the
# text does not contain "push" (p''ush) is found by the parser, which asks for the branch
# afterwards (need_branch).
shopt -s nocasematch
case "$hook_input" in
  *push*) load_current_branch ;;
esac

# The token store lives under the Git common directory, which jq cannot resolve. Look it up
# only when the command mentions the store, so ordinary commands pay for no extra git call.
common_directory=""
case "$hook_input" in
  *tokens*)
    common_directory="$(resolve_common_directory)"
    note_git_lookup "$?"
    ;;
esac

# The repository root matters only for whole-tree writers (recursive copy, archive extraction,
# ref restores, index plumbing, git rm and clean). Look it up only when the command mentions one;
# otherwise the classifier uses the working directory in its place, which only over-asks.
root_cdup="" root_known="0"
case "$hook_input" in
  *cp* | *rsync* | *ditto* | *tar* | *zip* | *cpio* | *pax* | *7z* | *checkout* | *restore* | *reset* | *read-tree* | *rm* | *clean* | *index* | *hash-object*)
    hook_git_show_cdup "$(directory_for_git)"
    root_status=$?
    if [ "$root_status" -eq 0 ]; then root_cdup="$hook_git_output" root_known="1"; fi
    note_git_lookup "$root_status"
    ;;
esac
shopt -u nocasematch

decision="fallback" parse_mode="fallback" classes="" hook_output="" hint_state="none" hint_targets="[]" need_branch="0" floor_text=""

# No decision from the classifier or the floor: ask if a lookup the decision depended on failed
# (NF-3), else the hint.
finish_without_decision() {
  if [ -n "$git_lookup_failed" ]; then
    if [ -n "$classify_only" ]; then printf 'ask\ngit-lookup-failed\n'; exit 0; fi
    log_decision ask git-lookup-failed parsed
    ask "ai-engineering guard: a Git lookup this decision depends on (current branch, repository root or common directory) failed, or the hook environment sets Git variables that change which repository Git uses, so the guard cannot show this command is safe. It needs explicit human approval. $guardrail_note"
  fi
  if [ -n "$classify_only" ]; then printf 'none\n\n'; exit 0; fi
  emit_shell_edit_hint
  exit 0
}

# Runs the classifier once. Past the time budget it is stopped (its whole process group) and the
# fallback rules apply. RR3-13 worst case, well under Claude Code's 60 s hook timeout: two
# classifier runs (3 s each), every hook-time Git lookup together (5 s, guard/hook-git.sh), the
# restricted-agent fallback check (3 s) and linear keyword scans.
run_classifier() {
  decision="fallback" parse_mode="fallback" classes="" hook_output="" hint_state="none" hint_targets="[]" need_branch="0" floor_text=""
  set -m
  jq -r -L "$guard_directory" --arg branch "$current_branch" --arg branchLoaded "$branch_loaded" --arg commonDir "$common_directory" \
    --arg rootCdup "$root_cdup" --arg rootKnown "$root_known" \
    -f "$guard_directory/main.jq" >"$classifier_output_file" 2>/dev/null <<<"$hook_input" &
  local classifier_pid=$! watchdog_pid
  (sleep "$parse_time_budget_seconds"; kill -KILL -- "-$classifier_pid") </dev/null >/dev/null 2>&1 &
  watchdog_pid=$!
  set +m
  if wait "$classifier_pid" 2>/dev/null; then
    {
      read -r decision
      read -r parse_mode
      read -r classes
      read -r hook_output
      read -r hint_state
      read -r hint_targets
      read -r need_branch
      read -r floor_text
    } <"$classifier_output_file"
  fi
  kill -KILL -- "-$watchdog_pid" 2>/dev/null
  wait "$watchdog_pid" 2>/dev/null
  return 0
}

if [ -n "$classifier_output_file" ]; then
  run_classifier
  if [ "$need_branch" = "1" ] && [ "$branch_loaded" = "0" ]; then
    load_current_branch
    run_classifier
  fi
fi

case "$decision" in
  none)
    finish_without_decision
    ;;
  ask | deny)
    if [ -n "$classify_only" ]; then printf '%s\n%s\n' "$decision" "$classes"; exit 0; fi
    printf '%s\n' "$hook_output"
    log_decision "$decision" "$classes" "$parse_mode"
    exit 0
    ;;
  floor)
    # Parsed with no decision, but the floor text was too large to scan in jq: scan it here.
    if [ "$need_branch" = "1" ] && [ "$branch_loaded" = "0" ]; then load_current_branch; fi
    keyword_fallback "$current_branch" floor
    if [ "${#fallback_intents[@]}" -eq 0 ]; then
      finish_without_decision
    fi
    classes="$(IFS=,; printf '%s' "${fallback_intents[*]}")"
    if [ -n "$classify_only" ]; then printf 'ask\n%s\n' "$classes"; exit 0; fi
    log_decision ask "$classes" parsed
    ask "ai-engineering guard: words in this command look like a reserved operation and are not proven to be data (class: ${classes//,/, }). It needs explicit human approval. $guardrail_note"
    ;;
esac

# Fallback: the parse was not confident (or the classifier failed).
if [ "$branch_loaded" = "0" ]; then
  shopt -s nocasematch
  case "$hook_input" in *git*) load_current_branch ;; esac
  shopt -u nocasematch
fi
keyword_fallback "$current_branch"
if [ "${#fallback_intents[@]}" -eq 0 ]; then
  finish_without_decision
fi
classes="$(IFS=,; printf '%s' "${fallback_intents[*]}")"
if [ -n "$restricted_git_write" ]; then
  # RR3-3: a Git write established directly in the text (see keyword_fallback), not inferred
  # from the failed parse. Same reason as the parsed policy (guard/policy.jq git_write_policy).
  if [ -n "$classify_only" ]; then printf 'deny\n%s\n' "$classes"; exit 0; fi
  log_decision deny "$classes" fallback
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' \
    "ai-engineering guard: denied. $restricted_git_write is not on the read-only Git list for this agent: the coordinator owns Git. Do not run Git commands that change the repository or its configuration; leave the changes in the working tree and say in your report what should be committed. (The command could not be fully analysed; this Git write was identified directly.) $guardrail_note"
  exit 0
fi
if [ -n "$classify_only" ]; then printf 'ask\n%s\n' "$classes"; exit 0; fi
log_decision ask "$classes" fallback
ask "ai-engineering guard: this command could not be fully analysed, so keyword rules were applied. It needs explicit human approval (class: ${classes//,/, }). $guardrail_note"
