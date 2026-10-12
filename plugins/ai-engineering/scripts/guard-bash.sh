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
# Hook-time Git (state checks, branch, root and common-directory lookups, the shell-edit hint) goes
# only through the hardened plumbing in guard/hook-git.sh, which never runs repository- or
# environment-controlled programs (RR3-1).
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
  hook_git_common_directory "$directory" || return 0
  common_directory="$hook_git_output"
  [ -n "$common_directory" ] || return 0
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
# "check" with redirection targets; a redirection counts only when it overwrites a tracked file.
emit_shell_edit_hint() {
  local target tracked=""
  if [ "$hint_state" = "check" ]; then
    while IFS= read -r target; do
      [ -n "$target" ] || continue
      if hook_git_is_tracked "$(directory_for_git)" "$target" && [ -n "$hook_git_output" ]; then tracked=1; break; fi
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
  current_branch=""
  if hook_git_current_branch "$(directory_for_git)"; then current_branch="$hook_git_output"; fi
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
  *tokens*) common_directory="$(resolve_common_directory)" ;;
esac

# The repository root matters only for whole-tree writers (recursive copy, archive extraction,
# ref restores, index plumbing, git rm and clean). Look it up only when the command mentions one;
# otherwise the classifier uses the working directory in its place, which only over-asks.
root_cdup="" root_known="0"
case "$hook_input" in
  *cp* | *rsync* | *ditto* | *tar* | *zip* | *cpio* | *pax* | *7z* | *checkout* | *restore* | *reset* | *read-tree* | *rm* | *clean* | *index* | *hash-object*)
    if hook_git_show_cdup "$(directory_for_git)"; then root_cdup="$hook_git_output" root_known="1"; fi
    ;;
esac
shopt -u nocasematch

decision="fallback" parse_mode="fallback" classes="" hook_output="" hint_state="none" hint_targets="[]" need_branch="0" floor_text="" state_checks="[]"

# ---------------------------------------------------------------- state checks (N6(a))
# The classifier found a branch switch, merge, rebase, cherry-pick, stash or no-ref whole-tree
# restore with a literal ref (guard/policy.jq git_state_policy). At hook time, ask only if the
# .agents/specs state files differ between HEAD (or the base) and the ref, the ref cannot be
# resolved unambiguously, or uncommitted, untracked or ignored state would be discarded. Only the
# hardened plumbing in guard/hook-git.sh is used (RR3-1), under one deadline for the whole hook
# (RR3-13). Any failure, timeout, unexpected output or unsupported state asks, never none.
# Whether state files are tracked, untracked or ignored is not fixed until WORK-002, so all three
# are covered (RR3-7): committed (the ref diff), staged and modified (index and work tree against
# the index, compared by raw hash with no filter), untracked and, for stash -a or clean -x, ignored.
state_reason=""
max_tracked_state_files=64

# Exit status 0 when the raw diff (hook_git_tree_changes) touches the store: a *.state.json path under
# .agents/specs, a symbolic link or submodule anywhere under it, or .agents or .agents/specs itself
# as a non-directory entry (the store replaced by a link or a file). A quoted (unusual) path or a
# line of another shape counts as a change. Other .agents changes (specs, learnings) do not ask.
state_diff_touches_store() {
  printf '%s\n' "$hook_git_output" | LC_ALL=C awk '
    BEGIN { found = 0 }
    $0 == "" { next }
    {
      tab = index($0, "\t")
      if (substr($0, 1, 1) != ":" || tab == 0) { found = 1; exit }
      path = tolower(substr($0, tab + 1))
      split(substr($0, 2, tab - 2), meta, " ")
      if (substr(path, 1, 1) == "\"") { found = 1; exit }
      if (path == ".agents" || path == ".agents/specs") { found = 1; exit }
      if (index(path, ".agents/specs/") == 1) {
        if (path ~ /\.state\.json$/) { found = 1; exit }
        if (meta[1] == "120000" || meta[2] == "120000" || meta[1] == "160000" || meta[2] == "160000") { found = 1; exit }
      }
    }
    END { exit found ? 0 : 1 }'
}

# Resolves a literal ref in a directory into resolved_commit. Returns 0 when resolved, 1 when it
# cannot be resolved, 2 when its name is ambiguous (RR3-5: a tag and a branch, or any two of the
# names Git tries, ask). With prefer_branch (checkout and switch) refs/heads/<name> wins, as in Git.
resolved_commit=""
resolve_state_ref() {
  local directory="$1" ref="$2" prefer_branch="$3" name matches=0 has_branch="" line
  resolved_commit=""
  name="${ref%%[~^@:]*}"
  if [ -n "$name" ]; then
    case "$name" in -* | *[![:alnum:]._/-]*) return 1 ;; esac
    hook_git_matching_refs "$directory" "$name" || return 1
    while IFS= read -r line; do
      case "$line" in
        "refs/$name" | "refs/tags/$name" | "refs/remotes/$name" | "refs/remotes/$name/HEAD") matches=$((matches + 1)) ;;
        "refs/heads/$name") matches=$((matches + 1)) has_branch=1 ;;
      esac
    done <<<"$hook_git_output"
    [ "$matches" -le 1 ] || return 2
    # An all-capitals name (HEAD, FETCH_HEAD, ...) is also tried as a root ref first.
    case "$name" in *[![:upper:]_]*) ;; *) [ "$matches" -eq 0 ] || return 2 ;; esac
    if [ -n "$prefer_branch" ] && [ -n "$has_branch" ] && [ "$ref" = "$name" ]; then ref="refs/heads/$name"; fi
  fi
  hook_git_resolve_commit "$directory" "$ref" || return 1
  resolved_commit="$hook_git_output"
  return 0
}

# Returns 0 (and sets state_reason) when the state can change, or cannot be shown not to.
state_can_change() {
  local items op ref parent discard path directory untracked prefer_branch separator=$'\x1f'
  local session_directory session_top ref_commit base_commit base_label record mode object stage file_path
  local -a records
  [ "$state_checks" != "[]" ] && [ -n "$state_checks" ] || return 1
  if hook_git_environment_overrides; then
    state_reason="the hook environment sets Git variables that change which repository or configuration Git uses"
    return 0
  fi
  # One line per item; a control character in any field (it could split or truncate one) asks.
  items="$(jq -r '.[] | [.op, (.ref // ""), ((.parent // 1) | tostring), (if .discard then "1" else "0" end), (if .path then "1" else "0" end),
                        (.dir // ""), (if .untracked then "1" else "0" end), (if .branch then "1" else "0" end)]
                       | if any(.[]; test("[[:cntrl:]]")) then "invalid" else join("\u001f") end' <<<"$state_checks" 2>/dev/null)" \
    || { state_reason="the state checks could not be read"; return 0; }
  session_directory="$(directory_for_git)"
  session_top=""
  while IFS="$separator" read -r op ref parent discard path directory untracked prefer_branch; do
    [ -n "$op" ] || continue
    if [ "$op" = invalid ]; then state_reason="a state check has a control character"; return 0; fi
    case "$parent" in '' | *[!0-9]*) state_reason="$op: its parent number is not a number"; return 0 ;; esac
    # RR3-6: the check runs in the command's own directory, which must be in the session repository.
    [ -n "$directory" ] || directory="$session_directory"
    if [ "$directory" != "$session_directory" ]; then
      if [ -z "$session_top" ]; then
        hook_git_top_level "$session_directory" && [ -n "$hook_git_output" ] || { state_reason="$op: the session repository cannot be resolved"; return 0; }
        session_top="$hook_git_output"
      fi
      if ! hook_git_top_level "$directory" || [ "$hook_git_output" != "$session_top" ]; then
        state_reason="$op: it runs in a directory outside the session repository ($directory)"
        return 0
      fi
    fi
    if [ -n "$ref" ]; then
      resolve_state_ref "$directory" "$ref" "${prefer_branch#0}"
      case "$?" in
        0) ref_commit="$resolved_commit" ;;
        2) state_reason="$op: $ref is ambiguous (more than one ref has that name)"; return 0 ;;
        *)
          # `git checkout <name>` restores a path from the index when <name> is not a ref.
          if [ "$path" = 1 ] && [ -e "$directory/$ref" ]; then
            ref="" discard=1
          else
            state_reason="$op: $ref cannot be resolved here"
            return 0
          fi
          ;;
      esac
    fi
    if [ -n "$ref" ]; then
      # The base: HEAD, or the commit's parent for cherry-pick and revert (-m N picks parent N).
      base_label="HEAD"
      if [ "$op" = "git cherry-pick" ] || [ "$op" = "git revert" ]; then base_label="$ref^$parent"; fi
      if [ "$base_label" = HEAD ]; then
        hook_git_resolve_commit "$directory" HEAD || { state_reason="$op: HEAD cannot be resolved"; return 0; }
      else
        hook_git_resolve_commit "$directory" "$ref_commit^$parent" || { state_reason="$op: parent $parent of $ref cannot be resolved"; return 0; }
      fi
      base_commit="$hook_git_output"
      hook_git_tree_changes "$directory" "$base_commit" "$ref_commit" || { state_reason="$op: the .agents/specs state files could not be compared with $ref"; return 0; }
      if state_diff_touches_store; then
        state_reason="$op: the .agents/specs state files differ between $base_label and $ref"
        return 0
      fi
    fi
    if [ "$discard" = 1 ]; then
      hook_git_staged_state "$directory"
      case "$?" in
        0) ;;
        1) state_reason="$op: staged .agents/specs state changes would be discarded"; return 0 ;;
        *) state_reason="$op: the staged .agents/specs state files could not be checked"; return 0 ;;
      esac
      hook_git_tracked_state "$directory" || { state_reason="$op: the .agents/specs state files could not be listed"; return 0; }
      # Buffered first: each hash below reuses the output file.
      records=()
      while IFS= read -r -d '' record; do
        records+=("$record")
        [ "${#records[@]}" -le "$max_tracked_state_files" ] || { state_reason="$op: too many .agents/specs state files to check"; return 0; }
      done <"$hook_git_output_file"
      for record in ${records[@]+"${records[@]}"}; do
        file_path="${record#*$'\t'}" record="${record%%$'\t'*}"
        mode="${record%% *}" record="${record#* }"
        object="${record%% *}" stage="${record#* }"
        if [ "$mode" != 100644 ] && [ "$mode" != 100755 ] || [ "$stage" != 0 ]; then
          state_reason="$op: a .agents/specs state file is a link, a submodule or in conflict"
          return 0
        fi
        if ! hook_git_hash_file "$directory" "$file_path" || [ "$hook_git_output" != "$object" ]; then
          state_reason="$op: uncommitted .agents/specs state changes would be discarded"
          return 0
        fi
      done
      if [ "$untracked" = 1 ]; then
        hook_git_untracked_state "$directory" || { state_reason="$op: untracked .agents/specs state files could not be listed"; return 0; }
        [ -z "$hook_git_output" ] || { state_reason="$op: untracked .agents/specs state files would be overwritten or removed"; return 0; }
      fi
    fi
  done <<<"$items"
  return 1
}
# No decision from the classifier or the floor: ask if a state check says so, else the hint.
finish_without_decision() {
  if state_can_change; then
    if [ -n "$classify_only" ]; then printf 'ask\nprotected-tree-overwrite\n'; exit 0; fi
    log_decision ask protected-tree-overwrite parsed
    ask "ai-engineering guard: this command can replace protected state ($state_reason). It needs explicit human approval. $guardrail_note"
  fi
  if [ -n "$classify_only" ]; then printf 'none\n\n'; exit 0; fi
  emit_shell_edit_hint
  exit 0
}

# Runs the classifier once. Past the time budget it is stopped (its whole process group) and the
# fallback rules apply. RR3-13 worst case, well under Claude Code's 60 s hook timeout: two
# classifier runs (3 s each), every hook-time Git call together (5 s, guard/hook-git.sh), the
# restricted-agent fallback check (3 s) and linear keyword scans.
run_classifier() {
  decision="fallback" parse_mode="fallback" classes="" hook_output="" hint_state="none" hint_targets="[]" need_branch="0" floor_text="" state_checks="[]"
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
      read -r state_checks
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
  # Soft uncertainty (main.jq): the parse is sound, so the hook-time state checks it found still
  # run (degraded parsing must not erase an established fact). After hard uncertainty there are none.
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
