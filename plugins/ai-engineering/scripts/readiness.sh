#!/bin/bash
# readiness.sh: the one deterministic readiness procedure for a work-item increment
# (WORK-003 C2, ADR-0005). The review skill runs it; /ai-engineering:deliver reaches it
# through the review skill at the end of each increment.
#
# Usage: readiness.sh <WORK-ID> --inc <increment-id> [directory]
# Exit codes: 0 READY: YES; 1 READY: NO (certifiable); 3 NOT CERTIFIABLE (READY: NO);
#             2 usage or environment error (bad arguments, not a Git repository, jq or git
#             missing, no temporary directory): no READINESS block is printed.
#
# It prints one READINESS block. NOT CERTIFIABLE means the evidence needed to certify is
# missing, ambiguous, malformed or untrusted: the effective tier is then 2 and READY is NO.
# It is reported separately from a valid tier-2 classification.
#
# Effective tier = max(state tier, trusted classifier floor, action floor). Nothing lowers it.
#
# Base: the increment's recorded baseSha (workstate.sh increment-set --base-sha, recorded once
# when the increment begins). It must equal the local refs/remotes/origin/<default> (origin/HEAD
# names the default branch), be an ancestor of HEAD, and be the commit the increment branch was
# created from (the oldest entry of the branch's reflog). A default-branch ref that moved after
# the increment began, to HEAD or to a newer commit, is NOT CERTIFIABLE: a newer ref is never
# accepted automatically, and re-anchoring an increment is not available. The ref and the
# reflog are local records; remote authenticity is not verified (no ls-remote).
#
# Work-item records: the spec and state are copied once at the start and workstate.sh reads
# only that snapshot (show, status, readiness). Any read failure is NOT CERTIFIABLE, never an
# empty record. The live spec and state are hashed again at the end; a change is NOT CERTIFIABLE.
#
# Working tree: git status must succeed and show nothing but the active item's state and log,
# and no tracked file may be marked assume-unchanged or skip-worktree.
#
# Trust (local consistency, not cryptographic provenance; signed releases are WORK-004):
#   1. Claude Code's plugin registry ($CLAUDE_CONFIG_DIR, default ~/.claude, then
#      plugins/installed_plugins.json) has exactly one entry for ai-engineering@ai-engineering-system
#      at the most specific scope (local, then project, for this repository's main worktree,
#      then user). Every entry is strictly validated.
#   2. This script runs from that entry's installPath (real paths compared).
#   3. Its version is at least 0.3.0, equals the installed plugin.json version, and the
#      project's .claude/settings.json at the base commit pins the marketplace to ref
#      v<version> with a source of the form {source, repo, ref}. The marketplace source recorded
#      in known_marketplaces.json equals that pin.
#   4. Tag v<version> in that marketplace clone resolves to the registry's gitCommitSha, and
#      the whole installed plugin tree is byte- and mode-identical to the plugin directory at
#      that commit (no extra files, no links). The runtime .in_use/ directory and everything in
#      it is ignored.
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
# Each is matched by the SHA-256 of the exact command text, as the guard logs it; a deny is
# never excluded. The anchor is the first such ask no later than the increment's activeAt.
# Malformed lines before the anchor are ignored; after it they make the result NOT CERTIFIABLE.
# A missing, unreadable or linked log, a missing anchor, a log near the size at which the guard
# drops lines, or hashes that cannot be computed is NOT CERTIFIABLE. Residual: a guard-log
# write the guard's deadline kills is lost silently, a command run in another repository or
# outside Git is logged elsewhere or not at all, and a local process can edit lines; the log is
# a workflow record, not complete or tamper-proof.
#
# Full gate: run-gate.sh full with its configuration from the base commit, in a fresh local
# clone of this repository checked out at exactly HEAD on the clone's own branch
# ai-engineering-readiness-gate (objects copied, not linked; origin and every other branch
# removed; Git hooks off). The gate and the external review run without the
# GIT_NO_REPLACE_OBJECTS and GIT_NO_LAZY_FETCH protections readiness uses for its own reads; a
# repository with replace refs is NOT CERTIFIABLE. It never runs in, falls back to, or links anything from the
# development checkout, so the project's gate must be self-contained (installing its own
# dependencies). The verdict counts only with run-gate.sh's exit status. Running the project's
# gate is not a security sandbox: the gate runs with the user's privileges and can reach
# user-level resources and absolute paths unless separately isolated.
#
# External review: external-review.sh (configuration from the base commit), in this checkout.
# PASSED is required at tiers 1 and 2. At tier 0 NOT CONFIGURED is allowed, but a configured
# reviewer's BLOCKING FINDINGS or ERROR is READY: NO at every tier.
#
# Tier-dependent depth (WORK-003 Scope item 11): QA evidence always; security review and a
# residual-risk list at tier 2. Review and residual-risk evidence count only when they pass and
# name a commit that covers HEAD (only the active item's state and log changed since); review
# evidence must also name its reviewer. Evidence is recorded by the coordinator, not proven.
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
# The gate may leave read-only files in its checkout; make them removable first. Neither chmod
# -R nor rm -rf follows a symbolic link the gate planted, so nothing outside is touched.
remove_tree() { # directory inside the temporary directory
  case "$1" in "$temporary_directory" | "$temporary_directory"/*) ;; *) return 1 ;; esac
  [ -e "$1" ] || return 0
  chmod -R u+rwx "$1" 2>/dev/null
  rm -rf "$1"
}
trap 'remove_tree "$temporary_directory"' EXIT

sha256_text() { # text: prints the SHA-256 of the exact text (no trailing newline), or nothing
  local digest
  if command -v shasum >/dev/null 2>&1; then
    digest="$(printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -d' ' -f1)"
  else
    digest="$(printf '%s' "$1" | sha256sum 2>/dev/null | cut -d' ' -f1)"
  fi
  [[ $digest =~ ^[0-9a-f]{64}$ ]] && printf '%s' "$digest"
}

sha256_file() { # path: prints the SHA-256 of the file's bytes; fails when it cannot
  local digest
  if command -v shasum >/dev/null 2>&1; then
    digest="$(shasum -a 256 <"$1" 2>/dev/null | cut -d' ' -f1)"
  else
    digest="$(sha256sum <"$1" 2>/dev/null | cut -d' ' -f1)"
  fi
  [[ $digest =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$digest"
}

plain_branch() { # name: a branch name whose exact commands hash deterministically
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$ ]] && [[ $1 != *..* && $1 != *//* && $1 != */ && $1 != *.lock && $1 != */.* ]] \
    && git check-ref-format "refs/heads/$1" >/dev/null 2>&1
}

gate_branch="ai-engineering-readiness-gate" # the gate clone's own branch (see the full gate)

work_branch() { # name: a plain local work branch, never the default branch or another ref's name
  plain_branch "$1" || return 1
  case "$1" in HEAD | origin/* | refs/* | remotes/* | heads/* | tags/* | "$gate_branch") return 1 ;; esac
  [ -z "$default_branch" ] || [ "$1" != "$default_branch" ]
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
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_REPLACE_REF_BASE GIT_NAMESPACE
# Readiness's own Git reads never use replace objects or fetch lazily. The gate and the external
# review run without these two variables (child_without_git_protections): the guard's
# classification treats GIT_NO_REPLACE_OBJECTS as a variable that changes what Git sees and
# would refuse every gate. They still read the same repository and commits: both get explicit
# paths and commit ids, GIT_DIR and friends are unset above, the gate's clone holds no replace
# refs, and a repository with replace refs is NOT CERTIFIABLE (below).
export GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1
child_without_git_protections() { env -u GIT_NO_REPLACE_OBJECTS -u GIT_NO_LAZY_FETCH "$@"; }

# ---------------------------------------------------------------- repository, head and default branch
repository_root="$(git -C "$start_directory" rev-parse --show-toplevel 2>/dev/null)" || {
  echo "readiness.sh: not inside a Git repository: $start_directory" >&2
  exit 2
}
cd "$repository_root" || exit 2
specs_directory="$repository_root/.agents/specs/active"
spec_path=".agents/specs/active/$work_id.md"
bookkeeping_paths=(".agents/specs/active/$work_id.state.json" ".agents/specs/active/$work_id.log.md")

default_branch=""
base_sha=""
head_sha="$(git rev-parse --verify HEAD 2>/dev/null)" || head_sha=""
[ -n "$head_sha" ] || not_certifiable "HEAD does not resolve to a commit"
origin_head="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)" || origin_head=""
if [ -z "$origin_head" ]; then
  not_certifiable "origin/HEAD is not set, so the default branch is unknown"
else
  default_branch="${origin_head#refs/remotes/origin/}"
  if ! plain_branch "$default_branch"; then
    not_certifiable "the default branch name is not a plain branch name"
    default_branch=""
  fi
fi
current_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || {
  current_branch=""
  not_certifiable "HEAD is detached; the increment branch must be checked out"
}

# ---------------------------------------------------------------- working tree
# Uncommitted changes, apart from the active item's own state and log, make HEAD not the
# certified content. A status that cannot be read, or a tracked file whose changes Git is told
# to hide, means the working tree cannot be shown to match HEAD.
if git status --porcelain=v1 -z --untracked-files=all >"$temporary_directory/status" 2>/dev/null; then
  while IFS= read -r -d '' status_entry; do
    status_code="${status_entry:0:2}"
    changed_paths=("${status_entry:3}")
    case "$status_code" in
      *R* | *C*)
        IFS= read -r -d '' original_path && changed_paths+=("$original_path")
        ;;
    esac
    unexpected_path=""
    for changed_path in "${changed_paths[@]}"; do
      [ "$changed_path" = "${bookkeeping_paths[0]}" ] || [ "$changed_path" = "${bookkeeping_paths[1]}" ] || unexpected_path="$changed_path"
    done
    if [ -n "$unexpected_path" ]; then
      not_certifiable "uncommitted changes in the working tree ($unexpected_path)"
      break
    fi
  done <"$temporary_directory/status"
else
  not_certifiable "git status failed, so the working tree cannot be checked against HEAD"
fi
if git ls-files -v -z >"$temporary_directory/index-flags" 2>/dev/null; then
  while IFS= read -r -d '' index_entry; do
    case "${index_entry:0:1}" in
      [[:lower:]] | S) # lower case: assume-unchanged ([a-z] would also match capitals in some locales)
        not_certifiable "tracked file ${index_entry:2} is marked assume-unchanged or skip-worktree, so its working-tree copy can differ from HEAD unseen"
        break
        ;;
    esac
  done <"$temporary_directory/index-flags"
else
  not_certifiable "git ls-files failed, so hidden working-tree changes cannot be ruled out"
fi
# The external review runs here without GIT_NO_REPLACE_OBJECTS, so a replace ref could show it
# different objects than readiness sees.
if replace_refs="$(git for-each-ref --count=1 --format='%(refname)' refs/replace/ 2>/dev/null)"; then
  [ -z "$replace_refs" ] || not_certifiable "the repository has replace refs ($replace_refs), which could substitute the commits under review"
else
  not_certifiable "the repository's replace refs cannot be listed"
fi

# ---------------------------------------------------------------- work-item state (one snapshot)
# workstate.sh reads only this copy, so the tier, evidence, decisions and findings all come from
# the same records. The live files are compared with it again at the end.
live_state="$specs_directory/$work_id.state.json"
live_spec="$specs_directory/$work_id.md"
snapshot_directory="$temporary_directory/specs"
state_fingerprint=""
spec_fingerprint=""
state_json=""
status_json=""
records_json=""
increment_json="null"
state_tier=2
increment_branch=""
active_at=""
worktree_branches=()
snapshot_workstate() { "$scripts/workstate.sh" --dir "$snapshot_directory" "$@" 2>/dev/null; }
take_snapshot() {
  regular_file "$live_state" && regular_file "$live_spec" || return 1
  state_fingerprint="$(sha256_file "$live_state")" && spec_fingerprint="$(sha256_file "$live_spec")" || return 1
  mkdir "$snapshot_directory" && cp "$live_state" "$live_spec" "$snapshot_directory/" || return 1
  # The copy must be the bytes that were fingerprinted (a rename between the two is caught).
  [ "$(sha256_file "$snapshot_directory/$work_id.state.json")" = "$state_fingerprint" ] \
    && [ "$(sha256_file "$snapshot_directory/$work_id.md")" = "$spec_fingerprint" ] || return 1
  state_json="$(snapshot_workstate show "$work_id")" && jq -e 'type == "object" and (.increments | type == "array") and (.decisions | type == "array")' >/dev/null 2>&1 <<<"$state_json" || return 1
  status_json="$(snapshot_workstate status "$work_id")" && jq -e '.specMatchesApproval | type == "boolean"' >/dev/null 2>&1 <<<"$status_json" || return 1
  records_json="$(snapshot_workstate readiness "$work_id" --inc "$increment_id")" \
    && jq -e 'type == "object" and ([.highFindings, .ownerDecisions, .conversationDecisions, .openDecisions, .openFindings, .pendingOwnerActions] | all(type == "array"))' >/dev/null 2>&1 <<<"$records_json" \
    || return 1
}
if [ ! -e "$live_state" ] && [ ! -L "$live_state" ]; then
  not_certifiable "no valid work-item state for $work_id"
elif ! take_snapshot; then
  state_json=""
  not_certifiable "the work-item records for $work_id could not be read and validated (state, spec or workstate.sh)"
fi
if [ -n "$state_json" ]; then
  [ "$(jq -r '.specMatchesApproval' <<<"$status_json")" = "true" ] \
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
    if ! work_branch "$increment_branch"; then
      not_certifiable "increment $increment_id has no recorded work branch (a plain local branch other than the default branch)"
      increment_branch=""
    elif [ "$increment_branch" != "$current_branch" ]; then
      not_certifiable "the checked-out branch is not increment $increment_id's recorded branch"
    fi
    [[ $active_at =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
      || not_certifiable "increment $increment_id has no recorded activeAt time"
    if jq -e '(.worktreeBranches // []) | type == "array" and all(.[]; type == "string")' >/dev/null 2>&1 <<<"$increment_json"; then
      while IFS= read -r worktree_branch; do
        [ -n "$worktree_branch" ] || continue
        if work_branch "$worktree_branch"; then
          worktree_branches+=("$worktree_branch")
        else
          not_certifiable "recorded worktree branch $worktree_branch is not a plain local work branch (or is the default branch)"
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
fi
[[ $state_tier =~ ^[012]$ ]] || state_tier=2

# ---------------------------------------------------------------- base commit
# The recorded base, never whatever the local default-branch ref says now: a ref moved to HEAD
# would empty the diff and let the branch supply its own gate, pin and reviewer configuration.
default_ref_commit=""
check_base() {
  local recorded_base creation
  [ "$increment_json" != null ] || return 0
  recorded_base="$(jq -r '.baseSha // ""' <<<"$increment_json" | tr 'A-F' 'a-f')"
  if ! [[ $recorded_base =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
    not_certifiable "increment $increment_id has no recorded base commit (record origin/<default> with increment-set --base-sha when the increment begins)"
    return
  fi
  git cat-file -e "$recorded_base^{commit}" 2>/dev/null || { not_certifiable "the recorded base ${recorded_base:0:12} is not a commit in this repository"; return; }
  [ -n "$default_branch" ] || return 0
  default_ref_commit="$(git rev-parse --verify --quiet "refs/remotes/origin/$default_branch^{commit}" 2>/dev/null)" || default_ref_commit=""
  if [ "$default_ref_commit" != "$recorded_base" ]; then
    not_certifiable "origin/$default_branch is at ${default_ref_commit:0:12}, not the increment's recorded base ${recorded_base:0:12}: the default-branch ref changed after the increment began (a newer ref is never accepted automatically; re-anchoring needs a separate owner workflow)"
    return
  fi
  git merge-base --is-ancestor "$recorded_base" HEAD 2>/dev/null || { not_certifiable "the recorded base ${recorded_base:0:12} is not an ancestor of HEAD"; return; }
  if [ -n "$increment_branch" ]; then
    creation="$(git reflog show --no-abbrev --format=%H "refs/heads/$increment_branch" -- 2>/dev/null | tail -n 1)"
    [ "$creation" = "$recorded_base" ] || { not_certifiable "the reflog of $increment_branch does not show it created from the recorded base ${recorded_base:0:12}"; return; }
  fi
  base_sha="$recorded_base"
  [ "$base_sha" != "$head_sha" ] || not_ready "the increment has no commits after its base"
}
check_base

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
if [ "$trusted" = yes ] && [ -n "$base_sha" ] && [ -n "$head_sha" ]; then
  classifier_output="$("$scripts/classify-change.sh" --active "$work_id" "$base_sha" "$head_sha" "$repository_root" 2>/dev/null)"
  classifier_status=$?
  if [ "$classifier_status" -eq 0 ] && jq -e '(.floorTier | IN(0, 1, 2)) and .error == null' >/dev/null 2>&1 <<<"$classifier_output"; then
    classifier_floor="$(jq -r '.floorTier' <<<"$classifier_output")"
    classifier_summary="$classifier_floor ($(jq -r '[.paths[].reasons[]] | unique | join(", ") | if . == "" then "no changed paths" else . end' <<<"$classifier_output"))"
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
  local common_directory log_directory current previous current_size previous_size start_hash resume_hash merge_hash merge_hashes="[]" branch result
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
  # An empty hash would match every logged ask, so a hash that cannot be computed is fatal.
  start_hash="$(sha256_text "git switch -c $increment_branch origin/$default_branch")"
  resume_hash="$(sha256_text "git switch $increment_branch")"
  if [ -z "$start_hash" ] || [ -z "$resume_hash" ]; then
    action_certifiable=no
    not_certifiable "guard log: the exact-command hashes could not be computed (no working shasum or sha256sum)"
    return
  fi
  for branch in "${worktree_branches[@]+"${worktree_branches[@]}"}"; do
    merge_hash="$(sha256_text "git merge --no-edit $branch")"
    if [ -z "$merge_hash" ]; then
      action_certifiable=no
      not_certifiable "guard log: the exact-command hashes could not be computed (no working shasum or sha256sum)"
      return
    fi
    merge_hashes="$(jq -c --arg h "$merge_hash" '. + [$h]' <<<"$merge_hashes")"
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
      and (.commandSha256 | type == "string" and test("^[0-9a-f]{64}$"));
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

# ---------------------------------------------------------------- full gate (fresh clone at HEAD; never trusted from records)
# The clone is checked out on a branch of its own (gate_branch), never detached and never named
# like the increment branch: the guard's current-branch lookup succeeds there, and nothing in
# the clone carries the increment's identity. Its directory name is neutral, but nothing depends
# on that: the guard classifies the gate command the same way wherever the clone lives.
gate_checkout="$temporary_directory/gate-tree"
prepare_gate_checkout() {
  local local_ref
  git -c core.hooksPath=/dev/null clone --quiet --no-checkout --no-hardlinks -- "$repository_root" "$gate_checkout" >/dev/null 2>&1 || return 1
  # Without a remote, nothing in the gate can push or fetch back into the development repository.
  git -C "$gate_checkout" remote remove origin >/dev/null 2>&1 || return 1
  git -C "$gate_checkout" -c core.hooksPath=/dev/null checkout --quiet -B "$gate_branch" "$head_sha" >/dev/null 2>&1 || return 1
  # Every other local branch goes, including the copy of the increment branch.
  git -C "$gate_checkout" for-each-ref --format='%(refname)' refs/heads/ >"$temporary_directory/gate-branches" 2>/dev/null || return 1
  while IFS= read -r local_ref; do
    [ "$local_ref" = "refs/heads/$gate_branch" ] || git -C "$gate_checkout" update-ref -d "$local_ref" >/dev/null 2>&1 || return 1
  done <"$temporary_directory/gate-branches"
  [ "$(git -C "$gate_checkout" symbolic-ref --quiet HEAD 2>/dev/null)" = "refs/heads/$gate_branch" ] || return 1
  [ "$(git -C "$gate_checkout" rev-parse --verify HEAD 2>/dev/null)" = "$head_sha" ] || return 1
  [ "$(git -C "$gate_checkout" for-each-ref --format='%(refname)' refs/heads/ refs/remotes/ refs/replace/ 2>/dev/null)" = "refs/heads/$gate_branch" ] || return 1
  [ -z "$(git -C "$gate_checkout" remote 2>/dev/null)" ] || return 1
  git -C "$gate_checkout" status --porcelain=v1 --untracked-files=all >"$temporary_directory/gate-status" 2>/dev/null || return 1
  [ ! -s "$temporary_directory/gate-status" ]
}
gate_line="GATE full: NOT RUN (no base commit)"
gate_exit=""
if [ -n "$base_sha" ] && [ -n "$head_sha" ]; then
  if prepare_gate_checkout; then
    child_without_git_protections "$scripts/run-gate.sh" full "$gate_checkout" "$base_sha" >"$temporary_directory/gate.out" 2>&1
    gate_exit=$?
    gate_last_line="$(tail -n 1 "$temporary_directory/gate.out")"
    case "$gate_exit:$gate_last_line" in
      "0:GATE full: PASSED"*) gate_line="$gate_last_line" ;;
      "0:"*) gate_line="GATE full: NO VERDICT (run-gate.sh exit 0 without a PASSED verdict)" ;;
      *":GATE full: PASSED"*) gate_line="GATE full: NO VERDICT (run-gate.sh exit $gate_exit after a PASSED line)" ;;
      *":GATE full: "*) gate_line="$gate_last_line" ;;
      *) gate_line="GATE full: NO VERDICT (run-gate.sh exit $gate_exit)" ;;
    esac
  else
    gate_line="GATE full: NOT RUN (a fresh checkout of HEAD could not be created)"
    not_certifiable "the full gate could not run: a fresh checkout of HEAD could not be created"
  fi
  remove_tree "$gate_checkout"
fi
case "$gate_line" in
  "GATE full: PASSED"*"MODIFIES"*) not_ready "the change modifies the full gate (owner review needed)" ;;
  "GATE full: PASSED"*) ;;
  *) not_ready "the full gate did not pass" ;;
esac

# ---------------------------------------------------------------- external review
external_line="EXTERNAL REVIEW: NOT RUN (no base commit)"
external_result=error
if [ -n "$base_sha" ] && [ -n "$head_sha" ]; then
  child_without_git_protections "$scripts/external-review.sh" "$base_sha" "$head_sha" "$spec_path" >"$temporary_directory/external.out" 2>&1
  external_exit=$?
  external_first_line="$(head -n 1 "$temporary_directory/external.out")"
  external_last_line="$(tail -n 1 "$temporary_directory/external.out")"
  # A verdict counts only when the exit status and the verdict line agree.
  case "$external_exit:$external_last_line:$external_first_line" in
    "0:EXTERNAL REVIEW: PASSED:"*) external_result=passed external_line="$external_last_line" ;;
    "1:EXTERNAL REVIEW: BLOCKING FINDINGS:"*) external_result=blocking external_line="$external_last_line" ;;
    "3:"*":EXTERNAL REVIEW: NOT CONFIGURED") external_result=not-configured external_line="$external_first_line" ;;
    "2:EXTERNAL REVIEW: ERROR"*) external_line="$external_last_line" ;;
    *) external_line="EXTERNAL REVIEW: ERROR (no consistent verdict; external-review.sh exit $external_exit)" ;;
  esac
fi
if [ "$effective_tier" -ge 1 ]; then
  external_requirement="required at tier $effective_tier"
  [ "$external_result" = passed ] || not_ready "external review is required at tier $effective_tier and did not pass (${external_line#EXTERNAL REVIEW: })"
else
  external_requirement="optional at tier 0"
  case "$external_result" in
    passed | not-configured) ;;
    *) not_ready "the configured external review did not pass (${external_line#EXTERNAL REVIEW: })" ;;
  esac
fi

# ---------------------------------------------------------------- recorded evidence and records
covers_head() { # sha: a commit on HEAD's history after which only the active item's bookkeeping changed
  local sha="$1" changed_path
  [[ $sha =~ ^[0-9a-f]{7,64}$ ]] || return 1
  sha="$(git rev-parse --verify --quiet "$sha^{commit}" 2>/dev/null)" || return 1
  git merge-base --is-ancestor "$sha" HEAD 2>/dev/null || return 1
  # No rename detection: a deletion hidden as a rename into a bookkeeping path still counts.
  git diff --no-renames --no-ext-diff --name-only -z "$sha" HEAD -- >"$temporary_directory/covered" 2>/dev/null || return 1
  while IFS= read -r -d '' changed_path; do
    [ "$changed_path" = "${bookkeeping_paths[0]}" ] || [ "$changed_path" = "${bookkeeping_paths[1]}" ] || return 1
  done <"$temporary_directory/covered"
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
security_status="NOT REQUIRED at tier $effective_tier"
residual_status="NOT REQUIRED at tier $effective_tier"
if [ "$effective_tier" -eq 2 ]; then
  security_status="$(evidence_status security)"
  [ "$security_status" = MET ] || not_ready "security review evidence covering HEAD is $security_status"
  residual_status="$(evidence_status residual-risks)"
  [ "$residual_status" = MET ] || not_ready "the residual-risk list covering HEAD is $residual_status"
fi

record_list() { # jq filter over the records snapshot: comma-separated ids, or "none"
  if [ -n "$records_json" ]; then
    jq -r "[$1] | if length == 0 then \"none\" else join(\", \") end" <<<"$records_json"
  else
    echo "unknown (no records)"
  fi
}
open_findings="unknown (no records)"
if [ -n "$records_json" ]; then
  open_findings="$(jq -r '.openFindings | length' <<<"$records_json")"
  [ "$open_findings" = 0 ] || not_ready "$open_findings open finding(s)"
  open_blocking="$(jq -r '[.openDecisions[] | select(.blocking)] | length' <<<"$records_json")"
  [ "$open_blocking" = 0 ] || not_ready "$open_blocking open blocking decision(s)"
fi

# ---------------------------------------------------------------- nothing moved while readiness ran
if [ -n "$state_fingerprint" ]; then
  { regular_file "$live_state" && regular_file "$live_spec" \
      && [ "$(sha256_file "$live_state")" = "$state_fingerprint" ] && [ "$(sha256_file "$live_spec")" = "$spec_fingerprint" ]; } \
    || not_certifiable "the work-item state or spec changed while readiness ran"
fi
[ -z "$head_sha" ] || [ "$(git rev-parse --verify HEAD 2>/dev/null)" = "$head_sha" ] || not_certifiable "HEAD moved while readiness ran"
if [ -n "$base_sha" ] && [ "$(git rev-parse --verify --quiet "refs/remotes/origin/$default_branch^{commit}" 2>/dev/null)" != "$base_sha" ]; then
  not_certifiable "origin/$default_branch moved while readiness ran"
fi

# ---------------------------------------------------------------- report
certifiable=yes
[ "${#not_certifiable_reasons[@]}" -eq 0 ] || certifiable=no
if [ "$certifiable" = yes ]; then
  tier_label="$effective_tier (classified)"
else
  effective_tier=2
  tier_label="2 (NOT CERTIFIABLE)"
  not_ready "not certifiable"
fi

echo "READINESS - $work_id increment $increment_id"
echo "BASE: ${base_sha:-unknown} (recorded increment base; origin/${default_branch:-?} at ${default_ref_commit:-unknown})  HEAD: ${head_sha:-unknown}"
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
echo "HIGH-OR-ABOVE FIXES: $(record_list '.highFindings[] | select(.disposition.state == "fixed") | .id')"
echo "OWNER-COMMAND RISK DECISIONS: $(record_list '.ownerDecisions[] | .id')"
echo "CONVERSATION DECISIONS: $(record_list '.conversationDecisions[] | .id')"
echo "OPEN DECISIONS AND PROPOSALS: $(record_list '.openDecisions[] | "\(.id)\(if .blocking then "" else " (proposal)" end)"')"
echo "OPEN FINDINGS: $open_findings"
echo "PENDING OWNER ACTIONS: $(record_list '.pendingOwnerActions[] | .id')"
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
