#!/bin/bash
# PreToolUse hook for Bash. Classifies parsed actions (not command text) and requires
# explicit human approval ("ask") for reserved operations, or denies a reserved operation
# bundled with other commands so each approval covers exactly one operation.
#
# Structure: this script is the hook wrapper. guard/lexer.jq parses, guard/classify.jq and
# guard/tables.jq classify, guard/policy.jq decides, all in one jq run (guard/main.jq).
# When the parse is not confident (unbalanced quotes, a dynamic program name, an error, a
# timeout or an oversized command) it falls back to v0.2-style keyword rules, which only
# ever ask. The guard never returns "allow".
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

hook_input="$(cat)"
working_directory=""
working_directory_loaded=""
directory_for_git() {
  if [ -z "$working_directory_loaded" ]; then
    working_directory="$(jq -r '.cwd // empty' <<<"$hook_input" 2>/dev/null)"
    working_directory_loaded=1
  fi
  printf '%s' "${working_directory:-$PWD}"
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

# Prints the absolute Git common directory of the working directory (nothing when unknown).
resolve_common_directory() {
  local directory common_directory
  directory="$(directory_for_git)"
  common_directory="$(git -C "$directory" rev-parse --git-common-dir 2>/dev/null)" || return 0
  [ -n "$common_directory" ] || return 0
  case "$common_directory" in /*) ;; *) common_directory="$directory/$common_directory" ;; esac
  printf '%s' "$common_directory"
}

# Rotation under a mkdir lock, so two hooks do not rotate at once. Best effort: when another
# hook holds the lock this one skips rotating and never waits. A lock older than a minute is stale.
rotate_guard_log() {
  local log_directory="$1" log_file="$2" lock size
  lock="$log_directory/.rotate.lock"
  if [ -d "$lock" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir "$lock" 2>/dev/null; fi
  mkdir "$lock" 2>/dev/null || return 0
  size="$(wc -c <"$log_file" 2>/dev/null | tr -d ' ')"
  if [ "${size:-0}" -gt "$log_max_bytes" ]; then mv -f "$log_file" "$log_file.1" 2>/dev/null; fi
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
# v0.2-style keyword rules, used only when the parse is not confident. They only ever ask.
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

keyword_fallback() {
  local branch="$1"
  local word_start='(^|[^[:alnum:]_-])' word_end='([^[:alnum:]_-]|$)'
  local argument_start='(^|[[:space:]])'
  local gap='([^[:alnum:]_-].*)?[^[:alnum:]_-]'
  local risky_task='[^[:space:]]*(deploy|release|publish|destroy|teardown)[^[:space:]]*'
  fallback_command_text="$(jq -r '.tool_input.command // empty' <<<"$hook_input" 2>/dev/null | tr '\n\t' '  ')"
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
    fallback_matches "${argument_start}(--tags|[^[:space:]]*refs/tags/[^[:space:]]*)${word_end}" && fallback_flag git-tag-push
    case "$branch" in main | master) fallback_flag git-main-push ;; esac
  fi

  fallback_matches "${word_start}gh${gap}pr[[:space:]]+merge${word_end}" && fallback_flag pr-merge
  fallback_matches "${word_start}glab${gap}mr[[:space:]]+merge${word_end}" && fallback_flag pr-merge
  fallback_matches "${word_start}gh${gap}api${word_end}.*pulls/[0-9]+/merge" && fallback_flag pr-merge
  fallback_matches "${word_start}(gh|glab)${gap}release[[:space:]]+(create|delete|edit)${word_end}" && fallback_flag release-create
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

  # The authority store cannot be proven untouched when the parse is not confident, so a
  # command that names it asks (the parsed path denies writes outright).
  fallback_matches "(\.state\.json|ai-engineering/tokens)" && fallback_flag authority-store-write

  # HTTP clients and gh against reserved endpoints (the parsed path classifies these by method).
  fallback_matches "${word_start}(curl|wget|https?|xhs?|gh|glab)${gap}releases${word_end}" && fallback_flag release-create
  fallback_matches "${word_start}(curl|wget|https?|xhs?|gh|glab)${gap}(deployments|deploys)${word_end}" && fallback_flag unclassified-deploy
  fallback_matches "${word_start}(curl|wget|https?|xhs?|gh|glab)${gap}(merge|merges)${word_end}" && fallback_flag pr-merge
  fallback_matches "${word_start}(curl|wget|https?|xhs?|gh|glab)${gap}git/refs" && fallback_flag git-force-push
  fallback_matches "${word_start}(npx|pnpm|yarn|bunx|bun)${gap}netlify-cli" && fallback_flag unclassified-deploy

  # A restricted agent (the allow-list for Git): a git word with a subcommand that is not a
  # read-only one, a git word whose subcommand cannot be read, or a dynamic program name.
  if restricted_agent && [ "$(jq -rn --arg text "$fallback_command_text" '
        ["status","diff","log","show","blame","grep","ls-files","ls-tree","cat-file","rev-parse","rev-list","merge-base","describe","shortlog","fetch","version","help","branch","tag","stash","worktree","remote","config"] as $reads
        | [ $text | scan("(?i)(?:^|[^A-Za-z0-9_-])git(?:[^A-Za-z0-9_-]|$)") ] | length as $git_words
        | [ $text | scan("(?i)(?:^|[^A-Za-z0-9_-])git(?:\\s+(?:-[Cc]\\s+\\S+|--[A-Za-z-]+(?:=\\S+)?|-[A-Za-z]))*\\s+([A-Za-z][A-Za-z0-9-]*)") | .[0] | ascii_downcase ] as $subcommands
        | if ($subcommands | map(select(IN($reads[]) | not)) | length) > 0 or $git_words > ($subcommands | length)
             or ([ $text | scan("(?:^|[;&|(]\\s*)[$`]") ] | length) > 0 then "unsafe" else "ok" end' 2>/dev/null)" != "ok" ]; then
    fallback_flag git-write-by-subagent
  fi
  return 0
}

# ---------------------------------------------------------------- shell-edit hint
# For implementation agents that edit a file through the shell, PreToolUse context with NO
# permission decision (never asked, denied or logged). The classifier says "hint" outright, or
# "check" with redirection targets; a redirection counts only when it overwrites a tracked file.
emit_shell_edit_hint() {
  local target tracked=""
  if [ "$hint_state" = "check" ]; then
    while IFS= read -r target; do
      [ -n "$target" ] || continue
      if [ -n "$(git --literal-pathspecs -C "$(directory_for_git)" ls-files -- "$target" 2>/dev/null)" ]; then tracked=1; break; fi
    done < <(jq -r '.[]' <<<"$hint_targets" 2>/dev/null)
    [ -n "$tracked" ] && hint_state="hint"
  fi
  [ "$hint_state" = "hint" ] || return 0
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"Use Edit/Write for file changes."}}'
}

# ---------------------------------------------------------------- decision
current_branch=""
branch_loaded="0"
load_current_branch() {
  current_branch="$(git -C "$(directory_for_git)" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  branch_loaded="1"
}
# A cheap guess saves a second pass; a push spelled so the text does not contain "push"
# (p''ush) is found by the parser, which asks for the branch afterwards (need_branch).
case "$hook_input" in
  *push*) load_current_branch ;;
esac

# The token store lives under the Git common directory, which jq cannot resolve. Look it up
# only when the command mentions the store, so ordinary commands pay for no extra git call.
common_directory=""
case "$hook_input" in
  *tokens*) common_directory="$(resolve_common_directory)" ;;
esac

classifier_output_file="$(mktemp "${TMPDIR:-/tmp}/ai-engineering-guard.XXXXXX" 2>/dev/null)" || classifier_output_file=""
cleanup() { [ -z "$classifier_output_file" ] || rm -f "$classifier_output_file"; }
trap cleanup EXIT

decision="fallback" parse_mode="fallback" classes="" hook_output="" hint_state="none" hint_targets="[]" need_branch="0"

# Runs the classifier once. Past the time budget it is stopped and the fallback rules apply.
run_classifier() {
  decision="fallback" parse_mode="fallback" classes="" hook_output="" hint_state="none" hint_targets="[]" need_branch="0"
  jq -r -L "$guard_directory" --arg branch "$current_branch" --arg branchLoaded "$branch_loaded" --arg commonDir "$common_directory" \
    -f "$guard_directory/main.jq" >"$classifier_output_file" 2>/dev/null <<<"$hook_input" &
  local classifier_pid=$! watchdog_pid
  ( sleep "$parse_time_budget_seconds"; kill "$classifier_pid" 2>/dev/null ) >/dev/null 2>&1 &
  watchdog_pid=$!
  if wait "$classifier_pid" 2>/dev/null; then
    {
      read -r decision
      read -r parse_mode
      read -r classes
      read -r hook_output
      read -r hint_state
      read -r hint_targets
      read -r need_branch
    } <"$classifier_output_file"
  fi
  kill "$watchdog_pid" 2>/dev/null
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
    if [ -n "$classify_only" ]; then printf 'none\n\n'; exit 0; fi
    emit_shell_edit_hint
    exit 0
    ;;
  ask | deny)
    if [ -n "$classify_only" ]; then printf '%s\n%s\n' "$decision" "$classes"; exit 0; fi
    printf '%s\n' "$hook_output"
    log_decision "$decision" "$classes" "$parse_mode"
    exit 0
    ;;
esac

# Fallback: the parse was not confident (or the classifier failed).
if [ "$branch_loaded" = "0" ]; then
  case "$hook_input" in *git*) load_current_branch ;; esac
fi
keyword_fallback "$current_branch"
if [ "${#fallback_intents[@]}" -eq 0 ]; then
  [ -z "$classify_only" ] || printf 'none\n\n'
  exit 0
fi
classes="$(IFS=,; printf '%s' "${fallback_intents[*]}")"
if [ -n "$classify_only" ]; then printf 'ask\n%s\n' "$classes"; exit 0; fi
log_decision ask "$classes" fallback
ask "ai-engineering guard: this command could not be fully analysed, so keyword rules were applied. It needs explicit human approval (class: ${classes//,/, }). $guardrail_note"
