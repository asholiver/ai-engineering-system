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
#     protocol.allow=never, and --no-optional-locks (no opportunistic index refresh or write, so no
#     post-index-change hook);
#   - reads nothing from standard input and keeps standard error out of the decision;
#   - runs in its own process group under one deadline shared by every call of this hook
#     (hook_git_deadline_seconds); a call past the deadline is killed with its children.
# A non-zero exit, a timeout or output of the wrong shape is reported to the caller.
#
# No invocation below reads an object or a tree (Option B, owner decision 2026-10-12): re-review 4
# (NF-1) showed that reading a missing object in a partial clone fetches it lazily, which runs the
# promisor remote's transport (an ext:: command, for example). protocol.allow=never does not stop
# that, because a repository's protocol.<name>.allow overrides it; GIT_NO_LAZY_FETCH=1 does, but
# only on Git releases that know it. So the guard no longer inspects Git state at hook time; the
# interface is limited to repository discovery and HEAD's name. The index is not read either
# (F5-3, re-review 5: expanding a sparse index reads trees). None of these reads work-tree file
# contents, the index or objects, runs a filter, diff driver, textconv or external diff, writes
# anything, or contacts a remote.
#
# Invocations (the whole interface; add nothing here without the same safety argument):
#   hook_git_common_directory DIR   rev-parse --git-common-dir     reads .git discovery only
#   hook_git_top_level DIR          rev-parse --show-toplevel      reads .git discovery only
#   hook_git_show_cdup DIR          rev-parse --show-cdup          reads .git discovery only
#   hook_git_current_branch DIR     rev-parse --abbrev-ref HEAD    reads HEAD only (its name, not the commit)
#
# Residual (documented): the git found on PATH is trusted, as are jq and the other tools this
# hook runs; a hostile PATH controls every program the hook starts, not only Git.
hook_git_deadline_seconds=5
hook_git_started_at=$SECONDS
hook_git_output=""
# The caller sets this to a private temporary file before the first call.
hook_git_output_file=""

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


# True when DIR or an ancestor has a .git entry. Runs no Git: it tells a lookup that failed inside a
# work tree (which must not count as "no repository") from one outside any repository (NF-3).
hook_git_in_work_tree() {
  local directory="$1"
  while [ -n "$directory" ] && [ "$directory" != "." ]; do
    [ ! -e "$directory/.git" ] || return 0
    [ "$directory" != "/" ] || return 1
    directory="$(dirname "$directory")"
  done
  return 1
}

# True when the hook's own environment sets a variable that changes which repository, index,
# objects or configuration Git uses. The hook's Git runs without them, so it cannot establish what
# the submitted command (which inherits them) will see: callers treat their lookups as failed (NF-3).
hook_git_environment_overrides() {
  local name
  for name in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
    GIT_NAMESPACE GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_NO_REPLACE_OBJECTS GIT_REPLACE_REF_BASE \
    GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM; do
    if [ -n "${!name+set}" ]; then return 0; fi
  done
  return 1
}
