#!/bin/bash
# readiness.sh: the one deterministic readiness procedure for a work-item increment
# (WORK-003 C2, ADR-0005). The review skill runs it; /ai-engineering:deliver reaches it
# through the review skill at the end of each increment.
#
# Usage: readiness.sh <WORK-ID> --inc <increment-id> [directory]
# Exit codes: 0 READY: YES; 1 READY: NO (certifiable); 3 NOT CERTIFIABLE (READY: NO);
#             2 usage error.
#
# It prints one READINESS block. NOT CERTIFIABLE means the evidence needed to certify is
# missing, ambiguous, malformed or untrusted: the effective tier is then 2 and READY is NO.
# It is reported separately from a valid tier-2 classification.
#
# Effective tier = max(state tier, trusted classifier floor, action floor). Nothing lowers it.
#
# Trust (local consistency, not cryptographic provenance; signed releases are WORK-004):
#   1. Claude Code's plugin registry ($CLAUDE_CONFIG_DIR, default ~/.claude, then
#      plugins/installed_plugins.json) has exactly one entry for ai-engineering@ai-engineering-system
#      at the most specific scope (local, then project, for this repository's main worktree,
#      then user). Every entry is strictly validated.
#   2. This script runs from that entry's installPath (real paths compared).
#   3. Its version is at least 0.3.0, equals the installed plugin.json version, and the
#      project's .claude/settings.json at the base commit pins the marketplace to ref
#      v<version>. The marketplace source recorded in known_marketplaces.json equals the pin.
#   4. Tag v<version> in that marketplace clone resolves to the registry's gitCommitSha, and
#      the whole installed plugin tree is byte- and mode-identical to the plugin directory at
#      that commit (only the runtime .in_use/ directory is ignored; no extra files, no links).
#   A deliberately altered script or a local process that forges these records defeats this.
#
# Action floor: tier 2 when the increment has a trigger-2 decision, or when the guard log has
# any ask or deny after the increment-start anchor, from any session, apart from three exact
# exclusions. Events are ordered by their line order in guard-log.jsonl.1 then guard-log.jsonl,
# never by their one-second timestamps.
#   anchor and exclusion 1: "git switch -c <increment branch> origin/<default>" (ask)
#   exclusion 2:            "git switch <increment branch>" (ask; resuming the increment)
#   exclusion 3:            "git merge --no-edit <recorded worktree branch>" (ask; only for
#                           branches recorded with workstate.sh increment-worktree)
# Each is matched by the SHA-256 of the exact command text, as the guard logs it. The anchor is
# the first such ask no later than the increment's activeAt. Malformed lines before the anchor
# are ignored; after it they make the result NOT CERTIFIABLE. A missing, unreadable or linked
# log, a missing anchor, or a log near the size at which the guard drops lines is NOT
# CERTIFIABLE. Residual: a guard-log write the guard's deadline kills is lost silently, and a
# local process can edit lines; the log is a workflow record, not complete or tamper-proof.
#
# Readiness runs the full gate itself (run-gate.sh full, configuration from the base commit)
# and the external review (external-review.sh). Recorded gate results are never trusted.
#
# Tier-dependent depth (WORK-003 Scope item 11): QA evidence always; security review at tier 2,
# or at tier 1 when the classifier flags a security category; a residual-risk list at tier 2;
# external review PASSED at tiers 1 and 2 (optional at tier 0). Review evidence counts only
# when it names its reviewer and a commit that covers HEAD (only the active item's state and
# log changed since). Evidence is recorded by the coordinator, not proven.
set -u

self_root="$(cd "$(dirname "$0")/.." && pwd -P)"
scripts="$self_root/scripts"
guard_log_cap=1048576 # must equal log_max_bytes in guard-bash.sh
guard_log_line_margin=4096
json_size_limit=1048576
marketplace_name="ai-engineering-system"
plugin_name="ai-engineering"
plugin_key="$plugin_name@$marketplace_name"
minimum_version="0.3.0"

usage() {
  echo "usage: readiness.sh <WORK-ID> --inc <increment-id> [directory]" >&2
  exit 2
}

work_id="${1:-}"
[[ $work_id =~ ^WORK-[0-9]{1,9}$ ]] || usage
shift
increment_id=""
start_directory="$PWD"
while [ $# -gt 0 ]; do
  case "$1" in
    --inc)
      [ $# -ge 2 ] || usage
      increment_id="$2"
      shift 2
      ;;
    -*) usage ;;
    *)
      start_directory="$1"
      shift
      ;;
  esac
done
[[ $increment_id =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || usage

not_certifiable_reasons=()
not_ready_reasons=()
not_certifiable() { not_certifiable_reasons+=("$1"); }
not_ready() { not_ready_reasons+=("$1"); }

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/readiness.XXXXXX")" || {
  echo "readiness.sh: cannot create a temporary directory" >&2
  exit 2
}
trap 'rm -rf "$temporary_directory"' EXIT

sha256_text() { # text: prints the SHA-256 of the exact text (no trailing newline)
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  else
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
  fi
}

plain_branch() { # name: a branch name whose exact commands hash deterministically
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$ ]] && [[ $1 != *..* && $1 != *//* && $1 != */ && $1 != *.lock && $1 != */.* ]]
}

regular_file() { # path: an existing, readable regular file that is not a symbolic link
  [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ]
}

bounded_json_file() { # path: a regular file of at most json_size_limit bytes holding valid JSON
  regular_file "$1" || return 1
  [ "$(wc -c <"$1" | tr -d ' ')" -le "$json_size_limit" ] || return 1
  jq -e . "$1" >/dev/null 2>&1
}

version_at_least() { # version minimum: both MAJOR.MINOR.PATCH
  local IFS=.
  # shellcheck disable=SC2206 # deliberate split of validated version strings on dots
  local left=($1) right=($2) index
  for index in 0 1 2; do
    [ "${left[$index]}" -gt "${right[$index]}" ] && return 0
    [ "${left[$index]}" -lt "${right[$index]}" ] && return 1
  done
  return 0
}

real_directory() { [ -d "$1" ] && (cd "$1" && pwd -P); }

command -v jq >/dev/null 2>&1 || { echo "readiness.sh: jq is required" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "readiness.sh: git is required" >&2; exit 2; }
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
export GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1

# ---------------------------------------------------------------- repository, base and head
repository_root="$(git -C "$start_directory" rev-parse --show-toplevel 2>/dev/null)" || {
  echo "readiness.sh: not inside a Git repository: $start_directory" >&2
  exit 2
}
cd "$repository_root" || exit 2
spec_path=".agents/specs/active/$work_id.md"
bookkeeping_paths=(".agents/specs/active/$work_id.state.json" ".agents/specs/active/$work_id.log.md")

default_branch=""
base_sha=""
head_sha="$(git rev-parse --verify HEAD 2>/dev/null)" || head_sha=""
origin_head="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)" || origin_head=""
if [ -z "$origin_head" ]; then
  not_certifiable "origin/HEAD is not set, so the default branch is unknown"
else
  default_branch="${origin_head#refs/remotes/origin/}"
  if ! plain_branch "$default_branch"; then
    not_certifiable "the default branch name is not a plain branch name"
    default_branch=""
  else
    base_sha="$(git merge-base HEAD "refs/remotes/origin/$default_branch" 2>/dev/null)" || {
      base_sha=""
      not_certifiable "no merge-base between HEAD and origin/$default_branch"
    }
  fi
fi
[ -n "$head_sha" ] || not_certifiable "HEAD does not resolve to a commit"
current_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || {
  current_branch=""
  not_certifiable "HEAD is detached; the increment branch must be checked out"
}

# Uncommitted changes, apart from the active item's own state and log, make HEAD not the
# certified content.
while IFS= read -r -d '' status_entry; do
  changed_path="${status_entry:3}"
  case "$changed_path" in
    "${bookkeeping_paths[0]}" | "${bookkeeping_paths[1]}") ;;
    *)
      not_certifiable "uncommitted changes in the working tree ($changed_path)"
      break
      ;;
  esac
done < <(git status --porcelain=v1 -z --untracked-files=all 2>/dev/null)

# ---------------------------------------------------------------- work-item state
state_json=""
increment_json="null"
state_tier=2
increment_branch=""
active_at=""
worktree_branches=()
if state_json="$("$scripts/workstate.sh" show "$work_id" 2>/dev/null)" && jq -e 'type == "object"' >/dev/null 2>&1 <<<"$state_json"; then
  status_json="$("$scripts/workstate.sh" status "$work_id" 2>/dev/null)" || status_json="{}"
  [ "$(jq -r '.specMatchesApproval' <<<"$status_json" 2>/dev/null)" = "true" ] \
    || not_certifiable "the spec does not match its approved hash"
  if [ "$(jq --arg i "$increment_id" '[.increments[] | select(.id == $i)] | length' <<<"$state_json")" = 1 ]; then
    increment_json="$(jq -c --arg i "$increment_id" '.increments[] | select(.id == $i)' <<<"$state_json")"
    state_tier="$(jq -r '.tier' <<<"$increment_json")"
    case "$(jq -r '.status' <<<"$increment_json")" in
      active | ready) ;;
      *) not_certifiable "increment $increment_id is $(jq -r '.status' <<<"$increment_json"), not active or ready" ;;
    esac
    increment_branch="$(jq -r '.branch // ""' <<<"$increment_json")"
    active_at="$(jq -r '.activeAt // ""' <<<"$increment_json")"
    if ! plain_branch "$increment_branch"; then
      not_certifiable "increment $increment_id has no plain recorded branch"
      increment_branch=""
    elif [ "$increment_branch" != "$current_branch" ]; then
      not_certifiable "the checked-out branch is not increment $increment_id's recorded branch"
    fi
    [[ $active_at =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
      || not_certifiable "increment $increment_id has no recorded activeAt time"
    if jq -e '(.worktreeBranches // []) | type == "array" and all(.[]; type == "string")' >/dev/null 2>&1 <<<"$increment_json"; then
      while IFS= read -r worktree_branch; do
        [ -n "$worktree_branch" ] || continue
        if plain_branch "$worktree_branch"; then
          worktree_branches+=("$worktree_branch")
        else
          not_certifiable "a recorded worktree branch is not a plain branch name"
        fi
      done < <(jq -r '(.worktreeBranches // [])[]' <<<"$increment_json")
    else
      not_certifiable "the recorded worktree branches are malformed"
    fi
    # Branch identity must be unambiguous across the item's increments and worktrees.
    jq -e '[.increments[] | .branch // empty, (.worktreeBranches // [])[]] | length == (unique | length)' >/dev/null 2>&1 <<<"$state_json" \
      || not_certifiable "a branch is recorded more than once in the work item"
    recorded_head="$(jq -r '.headSha // ""' <<<"$increment_json")"
    if [ -n "$recorded_head" ] && ! git merge-base --is-ancestor "$recorded_head" HEAD 2>/dev/null; then
      not_certifiable "the recorded head $recorded_head is not an ancestor of HEAD"
    fi
  else
    not_certifiable "increment $increment_id does not exist exactly once"
  fi
  [ "$(jq -r '.status' <<<"$state_json")" = delivering ] || not_ready "the work item is $(jq -r '.status' <<<"$state_json"), not delivering"
else
  state_json=""
  not_certifiable "no valid work-item state for $work_id"
fi
[[ $state_tier =~ ^[012]$ ]] || state_tier=2

# ---------------------------------------------------------------- trust
trusted=no
trust_summary=""
check_trust() {
  local config_directory registry known common_directory main_root entries candidates scope chosen=""
  local install_path install_real version commit pin_json known_json clone tag_commit plugin_path
  config_directory="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"
  registry="$config_directory/plugins/installed_plugins.json"
  known="$config_directory/plugins/known_marketplaces.json"
  bounded_json_file "$registry" || { not_certifiable "trust: the plugin registry is missing, unreadable or malformed"; return; }
  bounded_json_file "$known" || { not_certifiable "trust: the known-marketplaces record is missing, unreadable or malformed"; return; }

  common_directory="$(git rev-parse --git-common-dir 2>/dev/null)" || { not_certifiable "trust: no Git common directory"; return; }
  case "$common_directory" in /*) ;; *) common_directory="$repository_root/$common_directory" ;; esac
  [ "$(basename "$common_directory")" = .git ] || { not_certifiable "trust: cannot determine the main worktree"; return; }
  main_root="$(real_directory "$(dirname "$common_directory")")" || { not_certifiable "trust: cannot resolve the main worktree"; return; }

  entries="$(jq -c --arg key "$plugin_key" '.plugins[$key] // null' "$registry")"
  jq -e 'type == "array" and length > 0 and all(.[];
        type == "object"
        and (.scope | IN("user", "project", "local"))
        and (.installPath | type == "string" and startswith("/"))
        and (.version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
        and (.gitCommitSha | type == "string" and test("^[0-9a-f]{40}$"))
        and (if .scope == "user" then true else (.projectPath | type == "string" and startswith("/")) end))' \
    >/dev/null 2>&1 <<<"$entries" || { not_certifiable "trust: the registry has no valid $plugin_key entries"; return; }

  for scope in local project user; do
    candidates="$(jq -c --arg scope "$scope" '[.[] | select(.scope == $scope)]' <<<"$entries")"
    if [ "$scope" != user ]; then
      local matching="[]" candidate project_real
      while IFS= read -r candidate; do
        project_real="$(real_directory "$(jq -r '.projectPath' <<<"$candidate")")" || continue
        [ "$project_real" = "$main_root" ] && matching="$(jq -c --argjson c "$candidate" '. + [$c]' <<<"$matching")"
      done < <(jq -c '.[]' <<<"$candidates")
      candidates="$matching"
    fi
    case "$(jq 'length' <<<"$candidates")" in
      0) continue ;;
      1)
        chosen="$(jq -c '.[0]' <<<"$candidates")"
        break
        ;;
      *)
        not_certifiable "trust: more than one $scope-scope install of $plugin_key applies"
        return
        ;;
    esac
  done
  [ -n "$chosen" ] || { not_certifiable "trust: no installed $plugin_key applies to this repository"; return; }

  install_path="$(jq -r '.installPath' <<<"$chosen")"
  version="$(jq -r '.version' <<<"$chosen")"
  commit="$(jq -r '.gitCommitSha' <<<"$chosen")"
  install_real="$(real_directory "$install_path")" || { not_certifiable "trust: the installed plugin directory does not exist"; return; }
  [ "$install_real" = "$self_root" ] || { not_certifiable "trust: readiness is not running from the installed plugin ($install_real)"; return; }
  version_at_least "$version" "$minimum_version" || { not_certifiable "trust: installed version $version is older than $minimum_version"; return; }
  bounded_json_file "$install_real/.claude-plugin/plugin.json" \
    && [ "$(jq -r '.version' "$install_real/.claude-plugin/plugin.json")" = "$version" ] \
    || { not_certifiable "trust: the installed plugin.json does not report version $version"; return; }

  [ -n "$base_sha" ] || { not_certifiable "trust: no base commit to read the project pin from"; return; }
  git cat-file -e "$base_sha:.claude/settings.json" 2>/dev/null || { not_certifiable "trust: no .claude/settings.json at the base commit, so no pinned version"; return; }
  git show "$base_sha:.claude/settings.json" 2>/dev/null | head -c $((json_size_limit + 1)) >"$temporary_directory/settings.json"
  bounded_json_file "$temporary_directory/settings.json" || { not_certifiable "trust: .claude/settings.json at base is unreadable, oversized or malformed"; return; }
  pin_json="$(jq -c --arg m "$marketplace_name" '.extraKnownMarketplaces[$m].source // null' "$temporary_directory/settings.json" 2>/dev/null)" || pin_json="null"
  jq -e --arg ref "v$version" 'type == "object" and (.source | type == "string") and (.repo | type == "string") and .ref == $ref' >/dev/null 2>&1 <<<"$pin_json" \
    || { not_certifiable "trust: the base-commit pin does not name ref v$version for $marketplace_name"; return; }
  known_json="$(jq -c --arg m "$marketplace_name" '.[$m] // null' "$known")"
  jq -e --argjson pin "$pin_json" 'type == "object" and (.source | {source, repo, ref}) == ($pin | {source, repo, ref}) and (.installLocation | type == "string" and startswith("/"))' >/dev/null 2>&1 <<<"$known_json" \
    || { not_certifiable "trust: the known marketplace source does not equal the project pin"; return; }
  clone="$(real_directory "$(jq -r '.installLocation' <<<"$known_json")")" || { not_certifiable "trust: the marketplace clone does not exist"; return; }
  tag_commit="$(git -C "$clone" rev-parse --verify --quiet "refs/tags/v$version^{commit}" 2>/dev/null)" || tag_commit=""
  [ -n "$tag_commit" ] && [ "$tag_commit" = "$commit" ] || { not_certifiable "trust: tag v$version in the marketplace clone does not resolve to the recorded commit"; return; }

  git -C "$clone" show "$commit:.claude-plugin/marketplace.json" 2>/dev/null | head -c $((json_size_limit + 1)) >"$temporary_directory/marketplace.json"
  bounded_json_file "$temporary_directory/marketplace.json" || { not_certifiable "trust: the marketplace manifest at the tag is unreadable or malformed"; return; }
  plugin_path="$(jq -r --arg p "$plugin_name" '[.plugins[]? | select(.name == $p)] | if length == 1 and (.[0].source | type == "string") then .[0].source else "" end' "$temporary_directory/marketplace.json")"
  plugin_path="${plugin_path#./}"
  plugin_path="${plugin_path%/}"
  [[ $plugin_path =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && $plugin_path != *..* ]] || { not_certifiable "trust: the marketplace manifest does not name one plain plugin path"; return; }

  # Whole-tree comparison: every tag file present with identical bytes and mode, nothing else.
  local listing="$temporary_directory/tag-files" expected="$temporary_directory/expected-paths" actual="$temporary_directory/actual-paths"
  git -C "$clone" ls-tree -r -z "$commit" -- "$plugin_path/" >"$listing" 2>/dev/null || { not_certifiable "trust: cannot list the plugin tree at the tag"; return; }
  [ -s "$listing" ] || { not_certifiable "trust: the plugin tree at the tag is empty"; return; }
  : >"$expected"
  local entry metadata tree_path mode type blob relative file_mode
  while IFS= read -r -d '' entry; do
    metadata="${entry%%$'\t'*}"
    tree_path="${entry#*$'\t'}"
    read -r mode type blob <<<"$metadata"
    relative="${tree_path#"$plugin_path"/}"
    if [ "$type" != blob ] || { [ "$mode" != 100644 ] && [ "$mode" != 100755 ]; }; then
      not_certifiable "trust: the tag's plugin tree holds a link or submodule ($relative)"
      return
    fi
    regular_file "$install_real/$relative" || { not_certifiable "trust: installed file missing or not a regular file: $relative"; return; }
    [ "$(git -C "$clone" hash-object --no-filters -- "$install_real/$relative" 2>/dev/null)" = "$blob" ] || { not_certifiable "trust: installed file differs from the tag: $relative"; return; }
    if [ -x "$install_real/$relative" ]; then file_mode=100755; else file_mode=100644; fi
    [ "$file_mode" = "$mode" ] || { not_certifiable "trust: installed file mode differs from the tag: $relative"; return; }
    printf '%s\n' "$relative" >>"$expected"
  done <"$listing"
  (cd "$install_real" && find . -path ./.in_use -prune -o \( -type f -o -type l -o \! -type d \) -print) | sed 's|^\./||' >"$actual"
  if [ -n "$(cd "$install_real" && find . -path ./.in_use -prune -o -type l -print)" ]; then
    not_certifiable "trust: the installed plugin contains a symbolic link"
    return
  fi
  [ "$(LC_ALL=C sort "$expected")" = "$(LC_ALL=C sort "$actual")" ] || { not_certifiable "trust: the installed plugin has files that are not in the tag"; return; }
  trusted=yes
  trust_summary="$plugin_name $version at ${commit:0:12} (local consistency check)"
}
check_trust

# ---------------------------------------------------------------- classifier floor
classifier_floor=2
classifier_summary="2 (NOT CERTIFIABLE: no trusted classifier)"
security_category=no
if [ "$trusted" = yes ] && [ -n "$base_sha" ] && [ -n "$head_sha" ]; then
  classifier_output="$("$scripts/classify-change.sh" --active "$work_id" "$base_sha" "$head_sha" "$repository_root" 2>/dev/null)"
  classifier_status=$?
  if [ "$classifier_status" -eq 0 ] && jq -e '(.floorTier | IN(0, 1, 2)) and .error == null' >/dev/null 2>&1 <<<"$classifier_output"; then
    classifier_floor="$(jq -r '.floorTier' <<<"$classifier_output")"
    classifier_summary="$classifier_floor ($(jq -r '[.paths[].reasons[]] | unique | join(", ") | if . == "" then "no changed paths" else . end' <<<"$classifier_output"))"
    jq -e '[.paths[].reasons[]] | any(IN("tier2:auth", "tier2:secrets", "tier2:sql", "tier2:destructive-sql", "tier2:migration"))' >/dev/null 2>&1 <<<"$classifier_output" \
      && security_category=yes
  else
    not_certifiable "the classifier failed ($(jq -r '.error // "no valid output"' <<<"$classifier_output" 2>/dev/null || echo "no valid output"))"
    classifier_summary="2 (NOT CERTIFIABLE: classifier error)"
  fi
fi

# ---------------------------------------------------------------- action floor
action_floor=0
action_reasons=()
action_certifiable=yes
if [ -n "$state_json" ]; then
  while IFS= read -r decision_id; do
    [ -n "$decision_id" ] && action_reasons+=("trigger-2 decision $decision_id")
  done < <(jq -r '.decisions[] | select(.trigger == 2) | .id' <<<"$state_json")
fi

evaluate_guard_log() {
  local common_directory log_directory current previous current_size previous_size start_hash resume_hash merge_hashes="[]" branch result
  if [ -z "$increment_branch" ] || [ -z "$default_branch" ] || [ -z "$active_at" ]; then
    action_certifiable=no
    not_certifiable "guard log: no increment branch, default branch or activeAt to anchor on"
    return
  fi
  common_directory="$(git rev-parse --git-common-dir 2>/dev/null)" || common_directory=""
  case "$common_directory" in "" | /*) ;; *) common_directory="$repository_root/$common_directory" ;; esac
  log_directory="$common_directory/ai-engineering"
  current="$log_directory/guard-log.jsonl"
  previous="$current.1"
  if [ -z "$common_directory" ] || [ ! -d "$log_directory" ] || [ -L "$log_directory" ]; then
    action_certifiable=no
    not_certifiable "guard log: the log directory is missing or a link"
    return
  fi
  if ! regular_file "$current"; then
    action_certifiable=no
    not_certifiable "guard log: guard-log.jsonl is missing, unreadable or not a regular file"
    return
  fi
  if { [ -e "$previous" ] || [ -L "$previous" ]; } && ! regular_file "$previous"; then
    action_certifiable=no
    not_certifiable "guard log: guard-log.jsonl.1 is unreadable or not a regular file"
    return
  fi
  current_size="$(wc -c <"$current" | tr -d ' ')"
  previous_size=0
  regular_file "$previous" && previous_size="$(wc -c <"$previous" | tr -d ' ')"
  if [ "$current_size" -gt $((guard_log_cap * 2 - guard_log_line_margin)) ] || [ "$previous_size" -gt $((guard_log_cap * 2)) ]; then
    action_certifiable=no
    not_certifiable "guard log: the log is near the size at which the guard drops lines"
    return
  fi
  start_hash="$(sha256_text "git switch -c $increment_branch origin/$default_branch")"
  resume_hash="$(sha256_text "git switch $increment_branch")"
  for branch in "${worktree_branches[@]+"${worktree_branches[@]}"}"; do
    merge_hashes="$(jq -c --arg h "$(sha256_text "git merge --no-edit $branch")" '. + [$h]' <<<"$merge_hashes")"
  done
  : >"$temporary_directory/previous.log"
  regular_file "$previous" && cat "$previous" >"$temporary_directory/previous.log"
  result="$(jq -n -c \
    --rawfile previous "$temporary_directory/previous.log" --rawfile current "$current" \
    --arg start "$start_hash" --arg resume "$resume_hash" --argjson merges "$merge_hashes" --arg active "$active_at" '
    def lines_of($text): $text | split("\n") | if length > 0 and .[-1] == "" then .[:-1] else . end;
    def valid_event: type == "object"
      and (.time | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
      and (.decision | IN("ask", "deny"))
      and (.classes | type == "array")
      and (.commandSha256 | type == "string");
    [lines_of($previous)[], lines_of($current)[]]
    | to_entries
    | map(.key as $position | (.value | try fromjson catch null) as $event
          | {position: $position, ok: ($event != null and ($event | valid_event)), event: $event})
    | . as $events
    | ([$events[] | select(.ok and .event.decision == "ask" and .event.commandSha256 == $start and .event.time <= $active)] | first) as $anchor
    | if $anchor == null then {status: "no-anchor"}
      else [$events[] | select(.position > $anchor.position)] as $after
      | if any($after[]; .ok | not) then {status: "malformed-after-anchor"}
        else {status: "ok", anchorTime: $anchor.event.time,
              raising: [$after[].event | select((.decision == "ask" and (.commandSha256 | IN($start, $resume, $merges[]))) | not)
                        | {time, decision, classes, sessionId: (.sessionId // null)}],
              excluded: ([$after[].event | select(.decision == "ask" and (.commandSha256 | IN($start, $resume, $merges[])))] | length)}
        end
      end' 2>/dev/null)" || result='{"status": "unreadable"}'
  case "$(jq -r '.status' <<<"$result")" in
    ok)
      guard_log_summary="anchor at $(jq -r '.anchorTime' <<<"$result"); $(jq -r '.raising | length' <<<"$result") raising event(s), $(jq -r '.excluded' <<<"$result") excluded start/resume/merge confirmation(s)"
      if [ "$(jq -r '.raising | length' <<<"$result")" -gt 0 ]; then
        action_reasons+=("$(jq -r '"guard log: " + (.raising | map("\(.decision) [\(.classes | join(","))] session \(.sessionId // "?")") | unique | join("; "))' <<<"$result")")
      fi
      ;;
    no-anchor)
      action_certifiable=no
      not_certifiable "guard log: no increment-start anchor (git switch -c $increment_branch origin/$default_branch) at or before activeAt"
      ;;
    malformed-after-anchor)
      action_certifiable=no
      not_certifiable "guard log: a malformed line after the increment-start anchor"
      ;;
    *)
      action_certifiable=no
      not_certifiable "guard log: the log could not be read"
      ;;
  esac
}
guard_log_summary="not evaluated"
evaluate_guard_log
[ "${#action_reasons[@]}" -eq 0 ] || action_floor=2
if [ "$action_certifiable" = yes ]; then
  if [ "$action_floor" -eq 2 ]; then
    action_summary="2 ($(printf '%s; ' "${action_reasons[@]}" | sed 's/; $//'))"
  else
    action_summary="0"
  fi
else
  action_floor=2
  action_summary="2 (NOT CERTIFIABLE: guard-log evidence incomplete)"
fi

# ---------------------------------------------------------------- effective tier
effective_tier="$state_tier"
[ "$classifier_floor" -gt "$effective_tier" ] && effective_tier="$classifier_floor"
[ "$action_floor" -gt "$effective_tier" ] && effective_tier="$action_floor"
[ "${#not_certifiable_reasons[@]}" -eq 0 ] || effective_tier=2

# ---------------------------------------------------------------- full gate (run here, never trusted from records)
gate_line="GATE full: NOT RUN (no base commit)"
if [ -n "$base_sha" ]; then
  "$scripts/run-gate.sh" full "$repository_root" "$base_sha" >"$temporary_directory/gate.out" 2>&1
  gate_line="$(grep '^GATE full: ' "$temporary_directory/gate.out" | tail -n 1)"
  [ -n "$gate_line" ] || gate_line="GATE full: NO VERDICT"
fi
case "$gate_line" in
  "GATE full: PASSED"*"MODIFIES"*) not_ready "the change modifies the full gate (owner review needed)" ;;
  "GATE full: PASSED"*) ;;
  *) not_ready "the full gate did not pass" ;;
esac

# ---------------------------------------------------------------- external review
external_line="EXTERNAL REVIEW: NOT RUN (no base commit)"
if [ -n "$base_sha" ] && [ -n "$head_sha" ]; then
  "$scripts/external-review.sh" "$base_sha" "$head_sha" "$spec_path" >"$temporary_directory/external.out" 2>&1
  external_line="$(grep '^EXTERNAL REVIEW: ' "$temporary_directory/external.out" | tail -n 1)"
  [ -n "$external_line" ] || external_line="EXTERNAL REVIEW: ERROR (no verdict)"
fi
external_requirement="optional at tier 0"
if [ "$effective_tier" -ge 1 ]; then
  external_requirement="required at tier $effective_tier"
  case "$external_line" in
    "EXTERNAL REVIEW: PASSED"*) ;;
    *) not_ready "external review is required at tier $effective_tier and did not pass (${external_line#EXTERNAL REVIEW: })" ;;
  esac
fi

# ---------------------------------------------------------------- recorded evidence and records
covers_head() { # sha: a commit on HEAD's history after which only the active item's bookkeeping changed
  local sha="$1" changed
  [[ $sha =~ ^[0-9a-f]{7,64}$ ]] || return 1
  git merge-base --is-ancestor "$sha" HEAD 2>/dev/null || return 1
  changed="$(git diff --name-only "$sha" HEAD -- 2>/dev/null)" || return 1
  while IFS= read -r changed_path; do
    [ -z "$changed_path" ] && continue
    [ "$changed_path" = "${bookkeeping_paths[0]}" ] || [ "$changed_path" = "${bookkeeping_paths[1]}" ] || return 1
  done <<<"$changed"
  return 0
}
evidence_status() { # filter-name: MET | MISSING | STALE | FAILED for the latest matching evidence
  local latest result sha
  [ "$increment_json" != null ] || { echo MISSING; return; }
  latest="$(jq -c --arg which "$1" '[.evidence[] | select(if $which == "residual-risks" then .kind == "residual-risks" else (.kind == "review" and .reviewer == $which) end)] | last' <<<"$increment_json")"
  [ "$latest" != null ] || { echo MISSING; return; }
  result="$(jq -r '.result' <<<"$latest")"
  sha="$(jq -r '.sha // ""' <<<"$latest")"
  [ "$result" = pass ] || { echo FAILED; return; }
  covers_head "$sha" || { echo STALE; return; }
  echo MET
}
qa_status="$(evidence_status qa)"
[ "$qa_status" = MET ] || not_ready "QA evidence covering HEAD is $qa_status"
security_required=no
{ [ "$effective_tier" -eq 2 ] || { [ "$effective_tier" -eq 1 ] && [ "$security_category" = yes ]; }; } && security_required=yes
security_status="NOT REQUIRED at tier $effective_tier"
if [ "$security_required" = yes ]; then
  security_status="$(evidence_status security)"
  [ "$security_status" = MET ] || not_ready "security review evidence covering HEAD is $security_status"
fi
residual_status="NOT REQUIRED at tier $effective_tier"
if [ "$effective_tier" -eq 2 ]; then
  residual_status="$(evidence_status residual-risks)"
  [ "$residual_status" = MET ] || not_ready "the residual-risk list covering HEAD is $residual_status"
fi

records_json='{}'
if [ -n "$state_json" ]; then
  records_json="$("$scripts/workstate.sh" readiness "$work_id" --inc "$increment_id" 2>/dev/null)" || records_json='{}'
fi
open_findings="$(jq -r '(.openFindings // []) | length' <<<"$records_json")"
[ "$open_findings" = 0 ] || not_ready "$open_findings open finding(s)"
open_blocking="$(jq -r '[(.openDecisions // [])[] | select(.blocking)] | length' <<<"$records_json")"
[ "$open_blocking" = 0 ] || not_ready "$open_blocking open blocking decision(s)"

# ---------------------------------------------------------------- report
certifiable=yes
[ "${#not_certifiable_reasons[@]}" -eq 0 ] || certifiable=no
if [ "$certifiable" = yes ]; then
  tier_label="$effective_tier (classified)"
else
  tier_label="2 (NOT CERTIFIABLE)"
  not_ready "not certifiable"
fi

echo "READINESS - $work_id increment $increment_id"
echo "BASE: ${base_sha:-unknown} (merge-base with origin/${default_branch:-?})  HEAD: ${head_sha:-unknown}"
if [ "$trusted" = yes ]; then echo "TRUST: TRUSTED - $trust_summary"; else echo "TRUST: NOT CERTIFIABLE"; fi
echo "STATE TIER: $state_tier"
echo "CLASSIFIER FLOOR: $classifier_summary"
echo "ACTION FLOOR: $action_summary"
echo "GUARD LOG: $guard_log_summary"
echo "EFFECTIVE TIER: $tier_label"
echo "$gate_line"
case "$gate_line" in
  "GATE full: PASSED"*) ;;
  *) [ -s "$temporary_directory/gate.out" ] && { echo "GATE OUTPUT (last 20 lines):"; tail -n 20 "$temporary_directory/gate.out"; } ;;
esac
echo "QA (internal): $qa_status"
echo "SECURITY REVIEW (internal): $security_status"
echo "$external_line ($external_requirement)"
echo "RESIDUAL RISKS: $residual_status"
echo "HIGH-OR-ABOVE FIXES: $(jq -r '[(.highFindings // [])[] | select(.disposition.state == "fixed") | .id] | if length == 0 then "none" else join(", ") end' <<<"$records_json")"
echo "OWNER-COMMAND RISK DECISIONS: $(jq -r '[(.ownerDecisions // [])[] | .id] | if length == 0 then "none" else join(", ") end' <<<"$records_json")"
echo "CONVERSATION DECISIONS: $(jq -r '[(.conversationDecisions // [])[] | .id] | if length == 0 then "none" else join(", ") end' <<<"$records_json")"
echo "OPEN DECISIONS AND PROPOSALS: $(jq -r '[(.openDecisions // [])[] | "\(.id)\(if .blocking then "" else " (proposal)" end)"] | if length == 0 then "none" else join(", ") end' <<<"$records_json")"
echo "OPEN FINDINGS: $open_findings"
echo "PENDING OWNER ACTIONS: $(jq -r '[(.pendingOwnerActions // [])[] | .id] | if length == 0 then "none" else join(", ") end' <<<"$records_json")"
if [ "$certifiable" = yes ]; then
  echo "CERTIFIABLE: YES"
else
  echo "CERTIFIABLE: NOT CERTIFIABLE - $(printf '%s; ' "${not_certifiable_reasons[@]}" | sed 's/; $//')"
fi
if [ "${#not_ready_reasons[@]}" -eq 0 ]; then
  echo "READY: YES"
  exit 0
fi
echo "READY: NO - $(printf '%s; ' "${not_ready_reasons[@]}" | sed 's/; $//')"
[ "$certifiable" = yes ] && exit 1
exit 3
