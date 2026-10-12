#!/bin/bash
# Hook-time Git for the guard hooks (guard-bash.sh, guard-writes.sh). Source this file; do not run it.
#
# Trust boundary (RR3-1, owner ruling): a hook runs before any approval and outside the sandbox, so
# the Git it runs must never execute repository- or environment-controlled code. These functions
# are the ONLY Git the guard hooks run, and each is one fixed plumbing invocation. Every call goes
# through hook_git_run, which:
#   - starts from an empty environment (env -i) with only PATH, HOME and LC_ALL=C: every inherited
#     GIT_* variable (GIT_CONFIG_*, GIT_CONFIG_PARAMETERS, GIT_EXTERNAL_DIFF, GIT_DIR, ...) is gone;
#     GIT_NO_LAZY_FETCH=1 is the only Git variable, set here, and it only disables fetching;
#   - forces the extension points off on the command line, which wins over every configuration
#     file (include.path and includeIf included): core.fsmonitor=false (no fsmonitor hook or
#     daemon), core.hooksPath=/dev/null (no hook can be found), core.untrackedCache=false and
#     core.splitIndex=false (no index rewrite), diff.external= and core.pager=cat, --no-pager,
#     protocol.allow=never (no transport, so no lazy fetch from a promisor remote), and
#     --no-optional-locks (no opportunistic index refresh or write, so no post-index-change hook);
#   - reads nothing from standard input and keeps standard error out of the decision;
#   - runs in its own process group under one deadline shared by every call of this hook
#     (hook_git_deadline_seconds); a call past the deadline is killed with its children.
# A non-zero exit, a timeout or output of the wrong shape is reported to the caller, which asks.
# None of the invocations below reads work-tree file contents through a filter, runs a diff
# driver, textconv or external diff, writes the index or refs, or contacts a remote.
#
# Invocations (the whole interface; add nothing here without the same safety argument):
#   hook_git_common_directory DIR   rev-parse --git-common-dir     reads .git discovery only
#   hook_git_top_level DIR          rev-parse --show-toplevel      reads .git discovery only
#   hook_git_show_cdup DIR          rev-parse --show-cdup          reads .git discovery only
#   hook_git_current_branch DIR     rev-parse --abbrev-ref HEAD    reads HEAD only
#   hook_git_resolve_commit DIR REF rev-parse --verify --quiet --end-of-options REF^{commit}
#                                   reads refs and objects; REF cannot be an option
#   hook_git_matching_refs DIR NAME for-each-ref --format=%(refname) -- <5 full names>
#                                   reads refs; no signature or contents atoms
#   hook_git_tree_changes DIR A B   diff-tree -r --raw --no-ext-diff --no-textconv --no-renames A B
#                                   -- :(top,icase).agents   compares two commits' trees (objects
#                                   only, never the work tree); --raw prints modes and object names
#   hook_git_staged_state DIR       diff-index --cached --quiet --no-ext-diff HEAD -- <state glob>
#                                   compares the index with HEAD; --cached never reads the work tree
#   hook_git_tracked_state DIR      ls-files -s -z -- <state glob>   lists index entries; no refresh
#   hook_git_hash_file DIR PATH     hash-object --no-filters -- PATH  hashes raw bytes: no clean
#                                   filter, no attributes, nothing written
#   hook_git_untracked_state DIR    ls-files --others --exclude-standard -- <state glob>
#                                   walks directories and reads ignore files; no untracked cache
#   hook_git_is_tracked DIR PATH    --literal-pathspecs ls-files -- PATH   lists index entries
#
# Residual (documented): the git found on PATH is trusted, as are jq and the other tools this
# hook runs; a hostile PATH controls every program the hook starts, not only Git.
hook_git_deadline_seconds=5
hook_git_started_at=$SECONDS
hook_git_output=""
# The caller sets this to a private temporary file before the first call.
hook_git_output_file=""

# The .agents/specs state files (the authority store's committed half), in every spelling a
# case-insensitive file system resolves.
hook_git_state_pathspec=':(top,glob,icase).agents/specs/**/*.state.json'
hook_git_agents_pathspec=':(top,icase).agents'

# Private: runs one invocation above. Status: Git's own, 124 past the deadline, 125 no output file.
hook_git_run() {
  local directory="$1" remaining pid watchdog status
  shift
  hook_git_output=""
  [ -n "$hook_git_output_file" ] || return 125
  remaining=$((hook_git_deadline_seconds - (SECONDS - hook_git_started_at)))
  [ "$remaining" -gt 0 ] || return 124
  set -m
  env -i PATH="${PATH:-/usr/bin:/bin}" HOME="${HOME:-/nonexistent}" LC_ALL=C GIT_NO_LAZY_FETCH=1 \
    git --no-pager --no-optional-locks \
    -c core.fsmonitor=false -c core.hooksPath=/dev/null -c core.untrackedCache=false -c core.splitIndex=false \
    -c diff.external= -c core.pager=cat -c protocol.allow=never \
    -C "$directory" "$@" </dev/null >"$hook_git_output_file" 2>/dev/null &
  pid=$!
  (sleep "$remaining"; kill -KILL -- "-$pid") </dev/null >/dev/null 2>&1 &
  watchdog=$!
  set +m
  wait "$pid" 2>/dev/null
  status=$?
  kill -KILL -- "-$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  # Anything Git left behind in its process group goes too.
  kill -KILL -- "-$pid" 2>/dev/null
  hook_git_output="$(cat "$hook_git_output_file" 2>/dev/null)"
  return "$status"
}

hook_git_common_directory() { hook_git_run "$1" rev-parse --git-common-dir; }
hook_git_top_level() { hook_git_run "$1" rev-parse --show-toplevel; }
hook_git_show_cdup() { hook_git_run "$1" rev-parse --show-cdup; }
hook_git_current_branch() { hook_git_run "$1" rev-parse --abbrev-ref HEAD; }

# Succeeds only when the output is one object name.
hook_git_resolve_commit() {
  hook_git_run "$1" rev-parse --verify --quiet --end-of-options "$2^{commit}" || return 1
  case "$hook_git_output" in
    *[!0123456789abcdef]* | '') return 1 ;;
  esac
  [ "${#hook_git_output}" -eq 40 ] || [ "${#hook_git_output}" -eq 64 ]
}

hook_git_matching_refs() {
  hook_git_run "$1" for-each-ref '--format=%(refname)' -- "refs/$2" "refs/tags/$2" "refs/heads/$2" "refs/remotes/$2" "refs/remotes/$2/HEAD"
}

hook_git_tree_changes() {
  hook_git_run "$1" diff-tree -r --raw --no-ext-diff --no-textconv --no-renames "$2" "$3" -- "$hook_git_agents_pathspec"
}

hook_git_staged_state() {
  hook_git_run "$1" diff-index --cached --quiet --no-ext-diff HEAD -- "$hook_git_state_pathspec"
}

hook_git_tracked_state() { hook_git_run "$1" ls-files -s -z -- "$hook_git_state_pathspec"; }

hook_git_hash_file() { hook_git_run "$1" hash-object --no-filters -- "$2"; }

hook_git_untracked_state() { hook_git_run "$1" ls-files --others --exclude-standard -- "$hook_git_state_pathspec"; }

hook_git_is_tracked() { hook_git_run "$1" --literal-pathspecs ls-files -- "$2"; }

# True when the hook's own environment sets a variable that changes which repository, index,
# objects or configuration Git uses. The hook's Git runs without them, so it cannot establish what
# the submitted command (which inherits them) will see: state checks ask instead.
hook_git_environment_overrides() {
  local name
  for name in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
    GIT_NAMESPACE GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_NO_REPLACE_OBJECTS GIT_REPLACE_REF_BASE \
    GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM; do
    if [ -n "${!name+set}" ]; then return 0; fi
  done
  return 1
}
