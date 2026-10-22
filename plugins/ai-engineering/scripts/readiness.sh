#!/bin/bash -p
# readiness.sh: the one deterministic readiness procedure for a work-item increment
# (WORK-003 C2, ADR-0005). The review skill runs it; /ai-engineering:deliver reaches it
# through the review skill at the end of each increment.
#
# Usage: readiness.sh <WORK-ID> --inc <increment-id> [directory]
# Exit codes: 0 READY: YES (not reachable until base provenance can be verified, below);
#             1 READY: NO (certifiable); 3 NOT CERTIFIABLE (READY: NO);
#             2 usage or environment error (bad arguments, not a Git repository, jq or git
#             not in a trusted directory, Git older than 2.40, no usable temporary directory, an
#             environment that cannot be cleared): no READINESS block;
#             4 stopped by a signal (INT, TERM, HUP): no READINESS block, never READY.
#
# Environment: readiness starts in bash privileged mode (-p: no BASH_ENV or ENV file, no
# imported shell functions, SHELLOPTS or BASHOPTS) and, when the environment carries any of
# those, exported functions, a preload or audit library (LD_PRELOAD, LD_AUDIT,
# DYLD_INSERT_LIBRARIES), GCONV_PATH, a library path, a Perl setting, grep's option variables
# (GREP_OPTIONS, GREP_COLOR, GREP_COLORS) or POSIXLY_CORRECT, starts itself again once without
# them, so nothing it runs inherits them. Its own tools come only from fixed directories
# (trusted_tool_path: /opt/homebrew/bin, /usr/local/bin, /usr/bin, /bin, /usr/sbin, /sbin,
# /home/linuxbrew/.linuxbrew/bin), never from the caller's PATH; jq and git elsewhere (nix, mise,
# ~/.local/bin) are exit 2. Every inherited GIT_* variable is removed; it parses with LC_ALL=C;
# jq and its helper scripts run with an empty HOME (no ~/.jq). The plugin scripts that run the
# gate and the external review (run-gate.sh, external-review.sh) get the same controlled
# environment; only their configured command gets the caller's PATH, HOME, locale, library paths
# and Perl settings back. This is invoked directly (the skill runs the script, not
# "bash readiness.sh"); a caller that starts it through another shell defeats it. The fixed
# directories stop a caller's PATH from substituting tools; they are not protected locations.
# /opt/homebrew/bin, /usr/local/bin and /home/linuxbrew/.linuxbrew/bin are usually writable by
# the user, so any process running as that user can replace git, jq or another tool there (and
# so change any result); only /usr/bin, /bin, /usr/sbin and /sbin are system-owned. The removal is a list of named variables, not an empty environment:
# other variables a tool reads (PERL_UNICODE for shasum, CLICOLOR_FORCE for ls, TZ, MALLOC_*)
# still reach readiness's tools and the children. None of them is known to change a result
# readiness relies on; a complete allow-list environment is a separate, deferred design.
# AI_ENGINEERING_CLASSIFY_MAX_PATHS and _MAX_BYTES are removed: readiness always classifies with
# the built-in caps.
# Progress lines go to standard error; the block goes to standard output. Readiness can take
# up to its overall limit (50 minutes), so callers run it in the background and wait for it.
#
# It prints one READINESS block. NOT CERTIFIABLE means the evidence needed to certify is
# missing, ambiguous, malformed or untrusted: the effective tier is then 2 and READY is NO.
# It is reported separately from a valid tier-2 classification.
#
# Effective tier = max(state tier, trusted classifier floor, action floor). Nothing lowers it.
#
# Base: the increment's recorded baseSha. workstate.sh records it only when the increment moves
# from planned to active, as the full commit id refs/remotes/origin/<default> names at that
# moment, and never changes it. The start command names that exact commit
# ("git switch -c <branch> <base>"), and readiness requires the guard-log anchor to be that exact
# command. The base must still equal the local origin/<default> (origin/HEAD names the default
# branch), be an ancestor of HEAD, and be the commit the increment branch was created from (the
# oldest entry of the branch's reflog). A default-branch ref that moved after the increment
# began, to HEAD or to a newer commit, is NOT CERTIFIABLE: a newer ref is never accepted
# automatically, and re-anchoring an increment is not available.
# Base provenance: the anchor is an "ask" event. It shows the exact start command was asked; it
# does not show the owner approved it or that it ran, and it does not authenticate the base. The
# ref and the reflog are local records, and remote authenticity is not verified (no ls-remote).
# Owner-approved base provenance is therefore UNVERIFIED for every increment, the block says so
# (BASE PROVENANCE), and READY is NO for that reason alone until a separately approved guard
# change records approval, execution and the remote's commit. No workflow reaches READY: YES
# meanwhile; everything else is still checked and reported.
#
# Work-item records: the spec and state are copied once at the start and workstate.sh reads
# only that snapshot (show, status, readiness). Any read failure is NOT CERTIFIABLE, never an
# empty record. The live spec and state are hashed again at the end; a change is NOT CERTIFIABLE.
#
# Working tree: git status (with fsmonitor off) must succeed and show nothing but the active
# item's state and log, and no tracked file may be marked assume-unchanged or skip-worktree.
# Replace refs, a grafts file and a non-empty .git/info/attributes are NOT CERTIFIABLE.
# Readiness parses with LC_ALL=C. Its ancestry checks ignore commit-graph files. The temporary
# directory (TMPDIR, default /tmp) is resolved to its real path and must lie outside the
# repository, every worktree of it (main and linked) and the working trees of the superprojects it
# is a submodule of, compared by device and inode, not by name (exit 2 otherwise). Other
# worktrees of a superproject are not checked. Accepted residual: a TMPDIR inside an unrelated
# repository's working tree (a nested checkout that is not a submodule) is allowed. Readiness
# creates and removes only its own roots there and runs no Git command from them; a Git command
# the gate or the reviewer runs from its TMPDIR or HOME there would find that repository.
#
# Tracked files at HEAD: a path that starts with a double quote or holds a carriage return or
# newline, or a symbolic link whose target is absolute, leaves the repository, has ".." after a
# name (so another link could take it elsewhere), holds a control character or cannot be read
# exactly, is NOT CERTIFIABLE (the byte-for-byte verification below could not name it exactly, or
# the gate could write through it outside its clone). Paths and targets are split on "/" without
# pattern expansion, so a directory named "*" or "[ab]" is one literal name. In each fresh clone,
# every link is then followed on the real files (directories resolved physically, at most 40
# links) and must end inside the clone, with an existing directory; otherwise that clone fails.
#
# Changed binary files (Git's own rule: a NUL byte in the first 8000 bytes, or larger than the
# clones' 512 MiB big-file threshold, on either side): a diff shows only "Binary files differ",
# so a binary change is allowed only for a non-executable image or font asset under a directory
# listed in "binaryAssets" of .agents/gates.json at the base commit (relative directory prefixes
# ending in "/", no "..", no hidden segment). The file at HEAD must be mode 100644 with an
# allowed extension (png jpg jpeg gif webp ico avif woff woff2 ttf otf) and that format's
# leading bytes. Each changed binary is reported with its status, size and SHA-256. Any other
# changed binary, an unsafe entry, or a branch that changes binaryAssets is NOT CERTIFIABLE, as
# are more than 200 changed binaries (counted before any is read) and reaching the overall time
# limit while they are checked. Deleted binaries are reported and allowed. The leading-byte check
# identifies the format; it does not validate the whole file.
#
# Trust (local consistency, not cryptographic provenance; signed releases are WORK-004). These
# checks compare local records with each other (registry, marketplace clone, tag, installed
# files); none is authenticated, so they show the install is internally consistent, not that it
# came from the publisher. Base provenance (below) is likewise UNVERIFIED until authenticated
# evidence exists:
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
#   anchor and exclusion 1: "git switch -c <increment branch> <recorded base commit>" (ask)
#   exclusion 2:            "git switch <increment branch>" (ask; resuming the increment)
#   exclusion 3:            "git merge --no-edit <recorded worktree branch>" (ask; only for
#                           branches recorded with workstate.sh increment-worktree)
# Each is matched by the SHA-256 of the exact command text, as the guard logs it; a deny is
# never excluded. The anchor is the first such ask no later than the increment's activeAt.
# Malformed lines before the anchor are ignored; after it they make the result NOT CERTIFIABLE.
# A missing, unreadable or linked log, a missing anchor, a log near the size at which the guard
# drops lines, a log rotated or replaced while it is read, or hashes that cannot be computed is
# NOT CERTIFIABLE. Residual: a guard-log
# write the guard's deadline kills is lost silently, a command run in another repository or
# outside Git is logged elsewhere or not at all, and a local process can edit lines; the log is
# a workflow record, not complete or tamper-proof.
#
# Order: trust, classifier, action floor, evidence and records, then the external review, then
# the full gate last, then revalidation of everything the gate could change. When readiness is
# already NOT CERTIFIABLE, the external review and the gate are not run.
#
# Fresh clones: the external review and the gate each run in their own fresh clone of this
# repository at exactly HEAD, in temporary roots separate from readiness's own files, checked out
# on the clone's own branch ai-engineering-readiness-gate. The clone transfers only the increment
# branch through Git's transport (--no-local, so objects are copied and every received object is
# checked with transfer.fsckObjects; no hard links, alternates or commit-graph are shared), then
# removes the remote, every other branch and every replace ref; hooks are off. Clone and
# checkout use controlled Git: no user, system or XDG configuration, no attributes (committed
# ones included), no template, so no filter or conversion applies; the checkout is then verified
# byte for byte (every tracked blob and mode, nothing untracked or ignored). A clone that fails
# is reported with Git's last message. The clone's local configuration neutralises user-level
# diff settings (attributes file, big-file threshold, path prefixes, relative or
# submodule-hiding diffs, and each submodule's own ignore setting). Both children run without the
# GIT_NO_REPLACE_OBJECTS and GIT_NO_LAZY_FETCH protections readiness uses for its own reads (the
# guard would refuse every gate command with them set), and their configured command gets the
# caller's PATH, HOME, locale, library paths and Perl settings.
#
# External review: external-review.sh with configuration from the base commit and the explicit
# base and HEAD commits, limited to 15 minutes. When .agents/gates.json at the base commit is a
# valid object whose externalReview is explicitly null and the effective tier is 0, no review
# clone is made (NOT CONFIGURED, optional at tier 0); a missing file or key does not skip it, and
# a malformed or oversized file is NOT CERTIFIABLE. Otherwise it is NOT CERTIFIABLE, not run, when
# its own diff could not show the change as it is: an effective diff.external (it cannot be
# neutralised), a changed path missing from the reviewer's own "git diff --name-only" (for
# example a submodule bump hidden by an ignore setting), a changed text file with -diff, binary,
# or a diff driver with textconv, command or binary configured, or any changed file with a
# configured filter driver. PASSED is required at tiers 1 and 2. At tier 0 NOT CONFIGURED is
# allowed, but a configured reviewer's BLOCKING FINDINGS or ERROR (including a timeout) is
# READY: NO at every tier.
#
# Full gate: run-gate.sh full with its configuration from the base commit, limited to 30
# minutes. It never runs in, falls back to, or links anything from the development checkout, so
# the project's gate must be self-contained (installing its own dependencies). The verdict
# counts only with run-gate.sh's exit status; a timeout or a missing verdict fails. Running the
# project's gate is not a security sandbox: the gate runs with the user's privileges and can
# reach user-level resources and absolute paths unless separately isolated. Afterwards readiness
# checks again the spec and state, HEAD, the checked-out branch, origin/<default>, replace refs,
# the installed plugin against its tag and the evidence statuses; any change is NOT CERTIFIABLE.
# That catches persistent or accidental changes, not a determined hostile gate.
#
# Time limits: 30 minutes for the gate, 15 for the external review, 50 overall (clones
# included). A caller can lower them with READINESS_GATE_TIMEOUT_SECONDS,
# READINESS_REVIEW_TIMEOUT_SECONDS and READINESS_TOTAL_TIMEOUT_SECONDS, never raise them. Each
# child runs in its own process group together with its watchdog, so every signal the watchdog
# or readiness sends targets a group that still has a live member (its process-group id cannot
# have been reused). The group is stopped on timeout, when the child ends, and on INT, TERM or
# HUP (further signals are then ignored until the cleanup ends); temporary files and clones are
# removed on every exit readiness handles. Before the block is printed every temporary root is
# removed and checked; one that cannot be removed (the gate made a file immutable, say) is NOT
# CERTIFIABLE and left on disk. Readiness reads at most the last MiB of a child's
# output (run-gate.sh and external-review.sh bound what they print themselves, 400 characters a
# line); the child's whole output is written to readiness's temporary directory first, which is
# not size-limited (the gate could fill the disk in other ways too). A process the gate moves
# into another process group, or that kills the watchdog, escapes this, as does SIGKILL of
# readiness itself (the watchdog then stops the child at its limit); it is not protection
# against a hostile gate. A signal ignored when readiness starts (a background job of a
# non-interactive shell ignores INT) cannot be trapped: TERM and HUP are then still handled, and
# the watchdogs still apply.
#
# Output: every line of the READINESS block has its control characters (newlines included) and
# every byte outside ASCII shown as "?" (so no Unicode line separator or bidirectional control
# either), and the gate's output is quoted with a "  | " prefix, so nothing readiness reports can
# start a line of its own. Children's output (the gate, the reviewer, Git during clones) goes to
# files, never to readiness's own output; cleanup messages are discarded. Cleanup completes
# before the block, and after the final "READY:" line nothing is printed (signals are ignored
# from the start of the report). The verdict is that final line together with the exit status,
# never any other line; progress lines on standard error come only before the block.
#
# Tier-dependent depth (WORK-003 Scope item 11): QA evidence always; security review and a
# residual-risk list at tier 2. Review and residual-risk evidence count only when they pass and
# name a commit that covers HEAD (only the active item's state and log changed since); review
# evidence must also name its reviewer. Evidence is recorded by the coordinator, not proven.
set -u

# POSIX mode (POSIXLY_CORRECT in the environment) rejects the process substitution main uses when
# bash parses it, before any check could run, so readiness starts again without it first.
if [ -n "${POSIXLY_CORRECT+set}" ]; then
  exec /usr/bin/env -u POSIXLY_CORRECT /bin/bash -p "$0" "$@"
fi

# The whole procedure is one function, which bash parses completely before it runs (the call is
# the last line). A gate that rewrites this file while it runs therefore cannot change the checks
# that follow it; the trust check after the gate then finds the changed file. This is defence in
# depth, not protection against a determined hostile gate, which runs with readiness's privileges.
# The body is deliberately not indented, to keep it readable as a script.
main() {

# ---------------------------------------------------------------- environment
# Privileged mode (the -p on the first line) already ignored BASH_ENV, ENV, exported functions,
# SHELLOPTS and BASHOPTS for this shell; they would still reach every program it starts (and
# bash re-exports an inherited SHELLOPTS), so readiness starts itself once more without them and
# without the preload, library-path, Perl and gconv variables, grep's option variables (BSD grep
# applies GREP_OPTIONS to every call) and POSIXLY_CORRECT. The library-path and Perl values
# go along under AI_ENGINEERING_COMMAND_SAVED_<name>, which only run-gate.sh and
# external-review.sh read, to restore them for the configured command alone. A second pass that
# still finds any of them stops: the environment cannot be cleared.
saved_names="LD_LIBRARY_PATH DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_FRAMEWORK_PATH DYLD_FALLBACK_FRAMEWORK_PATH PERL5LIB PERLLIB PERL5OPT"
removed_names="BASH_ENV ENV SHELLOPTS BASHOPTS LD_PRELOAD LD_AUDIT DYLD_INSERT_LIBRARIES GCONV_PATH GREP_OPTIONS GREP_COLOR GREP_COLORS POSIXLY_CORRECT $saved_names"
injected_variables=()
saved_assignments=()
while IFS= read -r environment_line; do
  environment_name="${environment_line%%=*}"
  case "$environment_name" in
    BASH_FUNC_*) injected_variables+=(-u "$environment_name") ;;
    *)
      case " $removed_names " in
        *" $environment_name "*)
          injected_variables+=(-u "$environment_name")
          case " $saved_names " in
            *" $environment_name "*) saved_assignments+=("AI_ENGINEERING_COMMAND_SAVED_$environment_line") ;;
          esac
          ;;
      esac
      ;;
  esac
done < <(/usr/bin/env)
if [ "${#injected_variables[@]}" -gt 0 ]; then
  if [ -n "${AI_ENGINEERING_READINESS_RESTARTED+set}" ]; then
    echo "readiness.sh: the environment still carries exported shell functions or BASH_ENV, ENV, SHELLOPTS, BASHOPTS, preload, library-path, Perl, gconv, grep or POSIX-mode variables" >&2
    exit 2
  fi
  exec /usr/bin/env "${injected_variables[@]}" AI_ENGINEERING_READINESS_RESTARTED=1 \
    "${saved_assignments[@]+"${saved_assignments[@]}"}" /bin/bash -p "$0" "$@"
fi
unset AI_ENGINEERING_READINESS_RESTARTED CDPATH GLOBIGNORE
# The classifier's caps can only be lowered, but a lowered cap changes what it reports: readiness
# always classifies with the built-in caps.
unset AI_ENGINEERING_CLASSIFY_MAX_PATHS AI_ENGINEERING_CLASSIFY_MAX_BYTES
IFS=$' \t\n'

# Readiness's own tools come only from fixed directories (Homebrew first, as on most macOS PATHs;
# the Homebrew and /usr/local directories are usually user-writable, see the header). The caller's PATH, HOME and locale are kept for the gate's and the external
# reviewer's configured commands only (plugin_child), with the saved library-path and Perl values.
trusted_tool_path="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/home/linuxbrew/.linuxbrew/bin"
command_locale_assignment=(-u AI_ENGINEERING_COMMAND_SAVED_LC_ALL)
[ -z "${LC_ALL+set}" ] || command_locale_assignment=("AI_ENGINEERING_COMMAND_SAVED_LC_ALL=$LC_ALL")
child_command_path="${PATH-}"
child_command_home="${HOME-}"
export PATH="$trusted_tool_path"
hash -r
# Readiness and its plugin scripts parse with a fixed locale (pattern ranges such as [a-z] follow
# collation in some locales). The configured commands get the caller's locale back.
export LC_ALL=C

self_root="$(cd "$(dirname "$0")/.." && pwd -P)"
scripts="$self_root/scripts"
guard_log_cap=1048576 # must equal log_max_bytes in guard-bash.sh
guard_log_line_margin=4096
json_size_limit=1048576
marketplace_name="ai-engineering-system"
plugin_name="ai-engineering"
plugin_key="$plugin_name@$marketplace_name"
minimum_version="0.3.0"
# Time limits (seconds). A caller may lower them (READINESS_*_TIMEOUT_SECONDS), never raise them.
gate_limit_seconds=1800
review_limit_seconds=900
total_limit_seconds=3000
lower_limit() { # current-limit override: prints the smaller, ignoring an invalid override
  if [[ ${2:-} =~ ^[1-9][0-9]{0,6}$ ]] && [ "$2" -lt "$1" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi
}
gate_limit_seconds="$(lower_limit "$gate_limit_seconds" "${READINESS_GATE_TIMEOUT_SECONDS:-}")"
review_limit_seconds="$(lower_limit "$review_limit_seconds" "${READINESS_REVIEW_TIMEOUT_SECONDS:-}")"
total_limit_seconds="$(lower_limit "$total_limit_seconds" "${READINESS_TOTAL_TIMEOUT_SECONDS:-}")"
remaining_seconds() { printf '%s' $((total_limit_seconds - SECONDS)); }
progress() { printf 'readiness: [%02d:%02d] %s\n' $((SECONDS / 60)) $((SECONDS % 60)) "$1" >&2; }

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

# Three separate temporary roots (created once the repository is known): readiness's own
# working files, the gate's clone and the external review's clone. The gate's working directory
# is never inside readiness's files.
temporary_directory=""
gate_root=""
review_root=""
# The gate may leave read-only files in its checkout; make them removable first. Neither chmod
# -R nor rm -rf follows a symbolic link the gate planted, so nothing outside is touched. Their
# messages are discarded (a file name the gate chose could otherwise print a line of its own);
# whether anything is left is checked instead.
remove_tree() { # a directory inside one of readiness's temporary roots: fails when it is not gone
  local root inside=no
  for root in "$temporary_directory" "$gate_root" "$review_root"; do
    [ -n "$root" ] || continue
    case "$1" in "$root" | "$root"/*) inside=yes ;; esac
  done
  [ "$inside" = yes ] || return 1
  if [ -L "$1" ]; then
    rm -f "$1" 2>/dev/null
  elif [ -e "$1" ]; then
    chmod -R u+rwx "$1" 2>/dev/null
    rm -rf "$1" 2>/dev/null
  fi
  [ ! -e "$1" ] && [ ! -L "$1" ]
}
# shellcheck disable=SC2329 # invoked by the EXIT trap below
remove_temporary_roots() {
  stop_active_child
  [ -z "$temporary_directory" ] || remove_tree "$temporary_directory"
  [ -z "$gate_root" ] || remove_tree "$gate_root"
  [ -z "$review_root" ] || remove_tree "$review_root"
}
# A bounded child runs in its own process group together with its watchdog (run_bounded).
active_child_group=""
active_child_markers=""
group_signal() { # signal group marker-prefix: signals the group only while its watchdog is alive
  # The watchdog is a member of the group and stays alive until it has written the .final marker
  # (its last step, the KILL of the whole group, follows that). Without the marker the group
  # therefore still has a live member, so its id cannot belong to another process group.
  [ -e "$3.final" ] && return 0
  kill "-$1" -- "-$2" 2>/dev/null
}
# shellcheck disable=SC2329 # called from remove_temporary_roots (EXIT trap)
stop_active_child() {
  [ -n "$active_child_group" ] || return 0
  group_signal TERM "$active_child_group" "$active_child_markers"
  sleep 1
  group_signal KILL "$active_child_group" "$active_child_markers"
  active_child_group=""
}
# shellcheck disable=SC2329 # invoked by the signal traps below
terminated() { # signal name: stop the child, clean up (EXIT trap) and report; never READY
  # Further signals are ignored so the cleanup completes (only SIGKILL stops it; the watchdog
  # then stops the child at its limit).
  trap '' INT TERM HUP
  progress "stopped by SIG$1; no READINESS verdict"
  exit 4
}

# run_bounded limit output-file command...: runs the command in its own process group with its
# output in output-file, stops the whole group after limit seconds (TERM, then KILL as soon as
# the command itself has ended, or 5 s later),
# and sets bounded_status (the command's own exit status) and bounded_timed_out (yes or no).
# The watchdog runs inside the same group, ignoring TERM, so the group exists for as long as any
# signal can be sent to it: by the watchdog itself, by readiness when the command ends (every
# process left in the group, the watchdog included, is killed then) or by a handled signal.
bounded_status=""
bounded_timed_out=""
run_bounded() {
  local limit="$1" output="$2" pid markers
  shift 2
  markers="$temporary_directory/watchdog.$RANDOM$RANDOM"
  active_child_markers="$markers"
  set -m
  (
    set +m
    group="$(exec /bin/sh -c 'echo "$PPID"')"
    (
      trap '' TERM
      exec </dev/null >/dev/null 2>&1
      sleep "$limit"
      : >"$markers.timed-out"
      kill -TERM -- "-$group"
      sleep 5
      : >"$markers.final"
      kill -KILL -- "-$group"
    ) &
    "$@"
  ) >"$output" 2>&1 </dev/null &
  active_child_group=$!
  pid="$active_child_group"
  set +m
  wait "$pid"
  bounded_status=$?
  group_signal KILL "$pid" "$markers"
  active_child_group=""
  if [ -e "$markers.timed-out" ]; then bounded_timed_out=yes; else bounded_timed_out=no; fi
}

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

byte_count() { # path: prints the file's size in bytes; fails when wc fails or prints no number
  local size
  size="$(wc -c <"$1" 2>/dev/null)" || return 1
  size="${size//[[:space:]]/}"
  [[ $size =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$size"
}

bounded_json_file() { # path: a regular file of at most json_size_limit bytes holding exactly one JSON object
  local size
  regular_file "$1" || return 1
  size="$(byte_count "$1")" || return 1
  [ "$size" -le "$json_size_limit" ] || return 1
  # Whitespace alone (no document) and several documents are both refused: jq would read them as
  # no value or as several values.
  jq -e -s 'length == 1 and (.[0] | type == "object")' "$1" >/dev/null 2>&1
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

# Every inherited GIT_* variable is removed for readiness and every child it runs: they can
# redirect Git to another repository, index, object store, namespace, graft or shallow file or
# configuration, or reshape diffs (external diff, attribute sources, templates). This happens
# before the first git command (git --version included), so GIT_TRACE and the like never apply.
while IFS= read -r environment_line; do
  case "${environment_line%%=*}" in
    GIT_*) unset "${environment_line%%=*}" 2>/dev/null ;;
  esac
done < <(/usr/bin/env)
for required_tool in jq git; do
  case "$(command -v "$required_tool" 2>/dev/null)" in
    /*) ;;
    *) echo "readiness.sh: $required_tool is required in one of $trusted_tool_path (the caller's PATH is not used)" >&2; exit 2 ;;
  esac
done
# Git 2.40 or later: older Git ignores GIT_ATTR_SOURCE, so the controlled reads could not switch
# committed attributes off and every run would fail with a misleading reason.
git_version="$(git --version 2>/dev/null)"
if ! [[ $git_version =~ ^git\ version\ ([0-9]+)\.([0-9]+) ]] \
  || [ "${BASH_REMATCH[1]}" -lt 2 ] || { [ "${BASH_REMATCH[1]}" -eq 2 ] && [ "${BASH_REMATCH[2]}" -lt 40 ]; }; then
  echo "readiness.sh: Git 2.40 or later is required (found: ${git_version:-no version})" >&2
  exit 2
fi
# Readiness's own Git reads never use replace objects or fetch lazily. The gate and the external
# review run without these two variables (child_environment): the guard's classification treats
# GIT_NO_REPLACE_OBJECTS as a variable that changes what Git sees and would refuse every gate.
# They still read the intended repository and commits: each runs in its own fresh clone with
# explicit commit ids, the clones hold no replace refs, and a repository with replace refs is
# NOT CERTIFIABLE (below).
export GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1
# command...: runs a trusted tool without readiness's two Git protections, as the gate and the
# external review run (readiness's own environment otherwise).
child_environment() {
  env -u GIT_NO_REPLACE_OBJECTS -u GIT_NO_LAZY_FETCH "$@"
}
# root command...: runs a plugin script (run-gate.sh, external-review.sh) for a clone root. The
# script uses the trusted tools, the C locale, the root's private HOME and TMPDIR; its configured
# command gets the caller's PATH, HOME, locale, library paths and Perl settings back
# (AI_ENGINEERING_COMMAND_PATH, _HOME and _SAVED_<name>).
# shellcheck disable=SC2329 # passed to run_bounded as the command to run
plugin_child() {
  local root="$1"
  shift
  child_environment "${command_locale_assignment[@]}" TMPDIR="$root/tmp" HOME="$root/home" \
    AI_ENGINEERING_COMMAND_PATH="$child_command_path" AI_ENGINEERING_COMMAND_HOME="$child_command_home" "$@"
}

# ---------------------------------------------------------------- repository, head and default branch
repository_root="$(git -C "$start_directory" rev-parse --show-toplevel 2>/dev/null)" || {
  echo "readiness.sh: not inside a Git repository: $start_directory" >&2
  exit 2
}
cd "$repository_root" || exit 2
repository_real="$(pwd -P)"

# The temporary directory is resolved to its real path and must be outside the repository, every
# worktree of it (the main one and its siblings) and the working tree of any superproject it is a
# submodule of: a clone or a child's files there would be inside a development checkout, where
# any Git command a child runs would find that repository.
temporary_base="${TMPDIR:-/tmp}"
case "$temporary_base" in /*) ;; *) echo "readiness.sh: TMPDIR must be an absolute path" >&2; exit 2 ;; esac
temporary_base="$(cd "$temporary_base" 2>/dev/null && pwd -P)" || { echo "readiness.sh: TMPDIR is not a usable directory" >&2; exit 2; }
main_worktree_real=""
common_directory_path="$(git rev-parse --git-common-dir 2>/dev/null)" || common_directory_path=""
case "$common_directory_path" in "" | /*) ;; *) common_directory_path="$repository_root/$common_directory_path" ;; esac
[ -z "$common_directory_path" ] || main_worktree_real="$(cd "$common_directory_path/.." 2>/dev/null && pwd -P)" || main_worktree_real=""
protected_directories=("$repository_real")
[ -z "$main_worktree_real" ] || protected_directories+=("$main_worktree_real")
# Both stages are checked (a failed tr would drop the sibling worktrees), and Git always lists
# at least the main worktree, so an empty listing is a failure too.
worktree_listing="$(git worktree list --porcelain -z 2>/dev/null | tr '\0' '\001'; [ "${PIPESTATUS[0]}:${PIPESTATUS[1]}" = 0:0 ])" \
  && [ -n "$worktree_listing" ] || {
  echo "readiness.sh: the repository's worktrees cannot be listed, so TMPDIR cannot be checked" >&2
  exit 2
}
while [ -n "$worktree_listing" ]; do
  worktree_line="${worktree_listing%%$'\001'*}"
  if [ "$worktree_line" = "$worktree_listing" ]; then worktree_listing=""; else worktree_listing="${worktree_listing#*$'\001'}"; fi
  case "$worktree_line" in
    "worktree "*) worktree_real="$(real_directory "${worktree_line#worktree }")" && protected_directories+=("$worktree_real") ;;
  esac
done
superproject_directory="$repository_root"
for _ in 1 2 3 4 5 6 7 8; do
  superproject_directory="$(git -C "$superproject_directory" rev-parse --show-superproject-working-tree 2>/dev/null)" || break
  [ -n "$superproject_directory" ] || break
  superproject_real="$(real_directory "$superproject_directory")" && protected_directories+=("$superproject_real")
done
# Each directory from TMPDIR up to / is compared by device and inode (-ef), not by name: on a
# case-insensitive file system a differently cased path names the same directory.
containing_directory="$temporary_base"
while :; do
  for repository_directory in "${protected_directories[@]}"; do
    if [ "$containing_directory" -ef "$repository_directory" ]; then
      echo "readiness.sh: TMPDIR ($temporary_base) is inside the repository, one of its worktrees or a superproject; use a directory outside them" >&2
      exit 2
    fi
  done
  [ "$containing_directory" != / ] || break
  containing_directory="$(dirname "$containing_directory")"
done
temporary_directory="$(mktemp -d "$temporary_base/readiness.XXXXXX")" || {
  echo "readiness.sh: cannot create a temporary directory" >&2
  exit 2
}
trap remove_temporary_roots EXIT
trap 'terminated INT' INT
trap 'terminated TERM' TERM
trap 'terminated HUP' HUP

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
# An fsmonitor hook could report a changed file as unchanged, so it is switched off here.
if git -c core.fsmonitor=false -c core.untrackedCache=false status --porcelain=v1 -z --untracked-files=all --ignore-submodules=none >"$temporary_directory/status" 2>/dev/null; then
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
if git -c core.fsmonitor=false ls-files -v -z >"$temporary_directory/index-flags" 2>/dev/null; then
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
# Replace refs could substitute commits for anything that reads without GIT_NO_REPLACE_OBJECTS;
# a grafts file rewrites parents even with it; repository-local attributes (info/attributes)
# would decide which files Git treats as binary or filters.
check_replace_refs() { # [label suffix]
  local replace_refs
  if replace_refs="$(git for-each-ref --count=1 --format='%(refname)' refs/replace/ 2>/dev/null)"; then
    [ -z "$replace_refs" ] || not_certifiable "the repository has replace refs ($replace_refs), which could substitute the commits under review${1:-}"
  else
    not_certifiable "the repository's replace refs cannot be listed${1:-}"
  fi
  if [ -z "$common_directory_path" ]; then
    not_certifiable "the repository's Git directory cannot be found${1:-}"
  else
    { [ -e "$common_directory_path/info/grafts" ] || [ -L "$common_directory_path/info/grafts" ]; } \
      && not_certifiable "the repository has a grafts file (info/grafts), which rewrites commit parents${1:-}"
    { [ -s "$common_directory_path/info/attributes" ] || [ -L "$common_directory_path/info/attributes" ]; } \
      && not_certifiable "the repository has local attributes (info/attributes), which change how files are diffed${1:-}"
  fi
}
check_replace_refs
# Controlled Git for readiness's own clone, checkout and verification steps: no user, system or
# XDG configuration, no attributes (not even the committed .gitattributes: GIT_ATTR_SOURCE is
# the empty tree), no template and no hooks, so no filter, end-of-line conversion or template
# file can change what is checked out. These variables are never exported to the gate or the
# external review (the guard treats GIT_CONFIG_* as variables that change which configuration
# Git reads, and would refuse their commands); those run with the user's environment instead,
# against a clone whose local configuration neutralises diff-reshaping settings.
controlled_home="$temporary_directory/controlled-home"
mkdir -p "$controlled_home/config" "$controlled_home/template" || exit 2
empty_tree="$(git hash-object -t tree /dev/null 2>/dev/null)" || empty_tree=""
controlled_git() {
  env HOME="$controlled_home" XDG_CONFIG_HOME="$controlled_home/config" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_ATTR_NOSYSTEM=1 GIT_ATTR_SOURCE="$empty_tree" GIT_TEMPLATE_DIR="$controlled_home/template" \
    git -c core.attributesFile=/dev/null -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.autocrlf=false \
    -c core.commitGraph=false -c core.bigFileThreshold=512m "$@"
}
[ -n "$empty_tree" ] || not_certifiable "the empty tree id cannot be computed, so attributes cannot be controlled"
# jq and readiness's own helper scripts never read the caller's HOME (jq loads ~/.jq).
jq() { HOME="$controlled_home" command jq "$@"; }
own_helper() { HOME="$controlled_home" XDG_CONFIG_HOME="$controlled_home/config" "$@"; }
is_ancestor() { controlled_git merge-base --is-ancestor "$1" "$2" 2>/dev/null; } # no commit-graph

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
snapshot_workstate() { own_helper "$scripts/workstate.sh" --dir "$snapshot_directory" "$@" 2>/dev/null; }
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
    if [ -n "$recorded_head" ] && ! is_ancestor "$recorded_head" HEAD; then
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
recorded_base=""
check_base() {
  local creation
  [ "$increment_json" != null ] || return 0
  recorded_base="$(jq -r '.baseSha // ""' <<<"$increment_json" | tr 'A-F' 'a-f')"
  if ! [[ $recorded_base =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
    recorded_base=""
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
  is_ancestor "$recorded_base" HEAD || { not_certifiable "the recorded base ${recorded_base:0:12} is not an ancestor of HEAD"; return; }
  if [ -n "$increment_branch" ]; then
    creation="$(git reflog show --no-abbrev --format=%H "refs/heads/$increment_branch" -- 2>/dev/null | tail -n 1)"
    [ "$creation" = "$recorded_base" ] || { not_certifiable "the reflog of $increment_branch does not show it created from the recorded base ${recorded_base:0:12}"; return; }
  fi
  base_sha="$recorded_base"
  [ "$base_sha" != "$head_sha" ] || not_ready "the increment has no commits after its base"
}
check_base

# ---------------------------------------------------------------- base provenance
# Nothing local proves that the owner approved the increment's start, that it ran, or that the
# base is the remote's commit (see the header). READY: YES needs that, so READY is NO until the
# separate guard change exists; the other checks still run and are reported.
base_provenance="UNVERIFIED - the start record is a guard ask (not approval or execution) and origin/${default_branch:-?} is not authenticated against the remote; READY: YES needs the separate guard trust-boundary change"
not_ready "base provenance is unverified (owner-approved base provenance is required for READY: YES and is not yet available)"

# ---------------------------------------------------------------- trust
trusted=no
trust_summary=""
check_trust() {
  local config_directory registry known common_directory main_root entries candidates scope chosen=""
  local install_path install_real version commit pin_json known_json clone tag_commit plugin_path
  local installed_links
  local -a read_status
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
  read_status=("${PIPESTATUS[@]}")
  if [ "${read_status[0]}:${read_status[1]}" != 0:0 ] || ! bounded_json_file "$temporary_directory/settings.json"; then
    not_certifiable "trust: .claude/settings.json at base is unreadable, oversized or malformed"
    return
  fi
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
  read_status=("${PIPESTATUS[@]}")
  if [ "${read_status[0]}:${read_status[1]}" != 0:0 ] || ! bounded_json_file "$temporary_directory/marketplace.json"; then
    not_certifiable "trust: the marketplace manifest at the tag is unreadable or malformed"
    return
  fi
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
  # Every listing, filter and sort is checked: a failed find (an unreadable directory) or sort
  # would otherwise shorten both sides alike and let extra files or links pass.
  if ! (cd "$install_real" && find . -path ./.in_use -prune -o \( -type f -o -type l -o \! -type d \) -print) >"$temporary_directory/installed-files" \
    || ! sed 's|^\./||' "$temporary_directory/installed-files" >"$actual"; then
    not_certifiable "trust: the installed plugin's files cannot be listed"
    return
  fi
  if ! installed_links="$(cd "$install_real" && find . -path ./.in_use -prune -o -type l -print)"; then
    not_certifiable "trust: the installed plugin's links cannot be listed"
    return
  fi
  if [ -n "$installed_links" ]; then
    not_certifiable "trust: the installed plugin contains a symbolic link"
    return
  fi
  if ! LC_ALL=C sort "$expected" >"$expected.sorted" || ! LC_ALL=C sort "$actual" >"$actual.sorted" \
    || [ ! -s "$expected.sorted" ] || [ ! -s "$actual.sorted" ]; then
    not_certifiable "trust: the installed plugin's file lists cannot be compared"
    return
  fi
  cmp -s "$expected.sorted" "$actual.sorted" || { not_certifiable "trust: the installed plugin has files that are not in the tag"; return; }
  trusted=yes
  trust_summary="$plugin_name $version at ${commit:0:12} (local consistency check)"
}
check_trust

# ---------------------------------------------------------------- classifier floor
classifier_floor=2
classifier_summary="2 (NOT CERTIFIABLE: no trusted classifier)"
if [ "$trusted" = yes ] && [ -n "$base_sha" ] && [ -n "$head_sha" ]; then
  classifier_output="$(own_helper "$scripts/classify-change.sh" --active "$work_id" "$base_sha" "$head_sha" "$repository_root" 2>/dev/null)"
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
  # Counted, not looked up by id: a decision with an empty or odd id still raises the floor.
  if [ "$(jq '[.decisions[] | select(.trigger == 2)] | length' <<<"$state_json")" != 0 ]; then
    action_reasons+=("trigger-2 decision(s) $(jq -r '[.decisions[] | select(.trigger == 2) | (.id // "") | if . == "" then "(no id)" else . end] | join(", ")' <<<"$state_json")")
  fi
fi

file_identity() { # path: the file's inode number, "absent" or "unreadable"
  local identity
  if [ -e "$1" ] || [ -L "$1" ]; then
    # shellcheck disable=SC2012 # only the inode number of one fixed path is read (portable, unlike stat)
    identity="$(ls -di "$1" 2>/dev/null | awk '{print $1}'; [ "${PIPESTATUS[0]}:${PIPESTATUS[1]}" = 0:0 ])" || identity=""
    # Anything but a number is "unreadable", which never matches: two failed reads must not
    # compare as the same file.
    if [[ $identity =~ ^[0-9]+$ ]]; then printf '%s\n' "$identity"; else echo unreadable; fi
  else
    echo absent
  fi
}

evaluate_guard_log() {
  local common_directory log_directory current previous current_size previous_size start_hash resume_hash merge_hash merge_hashes="[]" branch result
  local current_identity previous_identity
  if [ -z "$increment_branch" ] || [ -z "$recorded_base" ] || [ -z "$active_at" ]; then
    action_certifiable=no
    not_certifiable "guard log: no increment branch, recorded base or activeAt to anchor on"
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
  current_size="$(byte_count "$current")" || current_size=""
  previous_size=0
  if regular_file "$previous"; then previous_size="$(byte_count "$previous")" || previous_size=""; fi
  if [ -z "$current_size" ] || [ -z "$previous_size" ]; then
    action_certifiable=no
    not_certifiable "guard log: the log size cannot be measured"
    return
  fi
  if [ "$current_size" -gt $((guard_log_cap * 2 - guard_log_line_margin)) ] || [ "$previous_size" -gt $((guard_log_cap * 2)) ]; then
    action_certifiable=no
    not_certifiable "guard log: the log is near the size at which the guard drops lines"
    return
  fi
  # An empty hash would match every logged ask, so a hash that cannot be computed is fatal.
  # The start command names the full base commit, so its ask record is tied to that commit (the
  # record shows it was asked, not that it was approved or ran).
  start_hash="$(sha256_text "git switch -c $increment_branch $recorded_base")"
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
  # Copy the newer file first, then the rotated one, and require both to be the same files
  # afterwards: a rotation between the two reads would otherwise drop lines from view.
  current_identity="$(file_identity "$current")"
  previous_identity="$(file_identity "$previous")"
  cat "$current" >"$temporary_directory/current.log" 2>/dev/null || current_identity="unreadable"
  : >"$temporary_directory/previous.log"
  if regular_file "$previous"; then
    cat "$previous" >"$temporary_directory/previous.log" 2>/dev/null || previous_identity="unreadable"
  fi
  if [ "$current_identity" = unreadable ] || [ "$previous_identity" = unreadable ] \
    || [ "$(file_identity "$current")" != "$current_identity" ] || [ "$(file_identity "$previous")" != "$previous_identity" ]; then
    action_certifiable=no
    not_certifiable "guard log: the log was rotated or replaced while it was being read"
    return
  fi
  result="$(jq -n -c \
    --rawfile previous "$temporary_directory/previous.log" --rawfile current "$temporary_directory/current.log" \
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
      guard_log_summary="anchor at $(jq -r '.anchorTime' <<<"$result"); $(jq -r '.raising | length' <<<"$result") raising event(s), $(jq -r '.excluded' <<<"$result") excluded start/resume/merge ask(s)"
      if [ "$(jq -r '.raising | length' <<<"$result")" -gt 0 ]; then
        action_reasons+=("$(jq -r '"guard log: " + (.raising | map("\(.decision) [\(.classes | join(","))] session \(.sessionId // "?")") | unique | join("; "))' <<<"$result")")
      fi
      ;;
    no-anchor)
      action_certifiable=no
      not_certifiable "guard log: no increment-start anchor (git switch -c $increment_branch $recorded_base) at or before activeAt"
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

# ---------------------------------------------------------------- recorded evidence and records
covers_head() { # sha: a commit on HEAD's history after which only the active item's bookkeeping changed
  local sha="$1" changed_path
  [[ $sha =~ ^[0-9a-f]{7,64}$ ]] || return 1
  sha="$(git rev-parse --verify --quiet "$sha^{commit}" 2>/dev/null)" || return 1
  is_ancestor "$sha" HEAD || return 1
  # No rename detection: a deletion hidden as a rename into a bookkeeping path still counts. A
  # submodule bump counts whatever ignore setting the configuration or .gitmodules holds.
  controlled_git diff --no-renames --no-ext-diff --no-textconv --ignore-submodules=none --name-only -z "$sha" HEAD -- \
    >"$temporary_directory/covered" 2>/dev/null || return 1
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
evidence_summary() { # one line of every evidence status, for the comparison after the gate
  printf 'qa=%s security=%s residual=%s' "$(evidence_status qa)" "$(evidence_status security)" "$(evidence_status residual-risks)"
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
evidence_before="$(evidence_summary)"

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

# ---------------------------------------------------------------- gates configuration at the base commit
# Read once with controlled Git. Missing: base_gates_json stays empty (no binary allowlist, the
# external review is not skipped). Malformed or oversized: NOT CERTIFIABLE.
base_gates_json=""
base_gates_state=missing
read_gates_at() { # commit output-file: missing | valid | malformed
  if ! controlled_git cat-file -e "$1:.agents/gates.json" 2>/dev/null; then
    echo missing
  else
    # git and head are both checked: a failed head leaves a short file that could still parse.
    controlled_git show "$1:.agents/gates.json" 2>/dev/null | head -c $((json_size_limit + 1)) >"$2"
    if [ "${PIPESTATUS[0]}:${PIPESTATUS[1]}" = 0:0 ] && bounded_json_file "$2" && jq -e 'type == "object"' "$2" >/dev/null 2>&1; then
      echo valid
    else
      echo malformed
    fi
  fi
}
if [ -n "$base_sha" ]; then
  base_gates_state="$(read_gates_at "$base_sha" "$temporary_directory/base-gates.json")"
  case "$base_gates_state" in
    valid) base_gates_json="$(jq -c . "$temporary_directory/base-gates.json")" ;;
    malformed) not_certifiable ".agents/gates.json at the base commit is malformed or oversized" ;;
  esac
fi

# ---------------------------------------------------------------- tracked files at HEAD
# Names the byte-for-byte verification could not name exactly, and links the gate could follow
# out of its clone, are refused before any clone is made.
# A ".." after a name is refused too: that name may itself be a link (to "..", say), so the
# target's real location would differ from its text. With ".." only at the start, every link
# resolves inside the repository when its text does (the link's own directory is real).
# Paths and targets are split with read, never with an unquoted expansion: a segment such as "*"
# or "[ab]" would otherwise be expanded as a pattern against the current directory. A target
# holding a control character (a newline would end read early) is refused.
link_leaves_repository() { # link-path target: succeeds when the target is absolute, climbs out or has a later ".."
  local link_path="$1" target="$2" depth=0 segment named=no
  local segments=()
  case "$target" in "" | /* | *[[:cntrl:]]*) return 0 ;; esac
  if [ "$link_path" != "${link_path%/*}" ]; then # a link at the top level has no directory
    IFS=/ read -r -a segments <<<"${link_path%/*}"
    for segment in "${segments[@]+"${segments[@]}"}"; do
      case "$segment" in "" | .) ;; *) depth=$((depth + 1)) ;; esac
    done
  fi
  segments=()
  IFS=/ read -r -a segments <<<"$target"
  for segment in "${segments[@]+"${segments[@]}"}"; do
    case "$segment" in
      "" | .) ;;
      ..)
        [ "$named" = no ] || return 0
        depth=$((depth - 1))
        [ "$depth" -ge 0 ] || return 0
        ;;
      *)
        named=yes
        depth=$((depth + 1))
        ;;
    esac
  done
  return 1
}
check_tracked_files() {
  local entry metadata tracked_path mode type object target target_size
  controlled_git ls-tree -r -z --full-tree "$head_sha" >"$temporary_directory/head-tree" 2>/dev/null \
    || { not_certifiable "the files at HEAD cannot be listed"; return; }
  while IFS= read -r -d '' entry; do
    metadata="${entry%%$'\t'*}"
    tracked_path="${entry#*$'\t'}"
    read -r mode type object <<<"$metadata"
    case "$tracked_path" in
      \"* | *$'\r'* | *$'\n'*)
        not_certifiable "a tracked path at HEAD starts with a double quote or holds a carriage return or newline, so it cannot be verified exactly"
        return
        ;;
    esac
    if [ "$mode" = 120000 ]; then
      target="$(controlled_git cat-file blob "$object" 2>/dev/null | head -c 4096)"
      # The target as read must be the whole blob: command substitution drops NUL bytes and
      # trailing newlines, which would make the text checked differ from the link written.
      target_size="$(controlled_git cat-file -s "$object" 2>/dev/null)" || target_size=""
      if [ "$target_size" != "${#target}" ]; then
        not_certifiable "tracked symbolic link $tracked_path has a target that cannot be read exactly"
        return
      fi
      if link_leaves_repository "$tracked_path" "$target"; then
        not_certifiable "tracked symbolic link $tracked_path points outside the repository, has \"..\" after a name or holds a control character ($target)"
        return
      fi
    fi
  done <"$temporary_directory/head-tree"
}
[ -z "$head_sha" ] || check_tracked_files

# ---------------------------------------------------------------- changed binary files
# A binary change shows only "Binary files differ" to every reviewer, so it is allowed only for
# an image or font asset under a directory the base commit allowlists (see the header).
binary_lines=()
binary_file_limit=200 # changed binary files checked and reported at most (each is hashed)
asset_signature_matches() { # extension leading-bytes-hex
  case "$1" in
    png) [ "${2:0:16}" = 89504e470d0a1a0a ] ;;
    jpg | jpeg) [ "${2:0:6}" = ffd8ff ] ;;
    gif) [ "${2:0:12}" = 474946383761 ] || [ "${2:0:12}" = 474946383961 ] ;;
    webp) [ "${2:0:8}" = 52494646 ] && [ "${2:16:8}" = 57454250 ] ;;
    ico) [ "${2:0:8}" = 00000100 ] ;;
    avif) [ "${2:8:16}" = 6674797061766966 ] || [ "${2:8:16}" = 6674797061766973 ] ;;
    woff) [ "${2:0:8}" = 774f4646 ] ;;
    woff2) [ "${2:0:8}" = 774f4632 ] ;;
    ttf) [ "${2:0:8}" = 00010000 ] || [ "${2:0:8}" = 74727565 ] ;;
    otf) [ "${2:0:8}" = 4f54544f ] ;;
    *) return 1 ;;
  esac
}
check_changed_binaries() {
  local entry added changed_path raw_entry raw_path status mode object size digest extension leading allowed prefix
  local base_allowlist head_allowlist allowlist_entries=() raw_file="$temporary_directory/changed-raw" binary_count=0
  if ! controlled_git diff --numstat -z --no-renames --no-ext-diff --no-textconv --ignore-submodules=none "$base_sha" "$head_sha" -- \
    >"$temporary_directory/changed-numstat" 2>/dev/null \
    || ! controlled_git diff --raw -z --no-abbrev --no-renames --ignore-submodules=none "$base_sha" "$head_sha" -- >"$raw_file" 2>/dev/null; then
    not_certifiable "the changed files cannot be listed to find binary changes"
    return
  fi
  # The allowlist comes from the base commit only; a branch that changes it is refused.
  if [ "$base_gates_state" = valid ]; then
    if ! jq -e '(.binaryAssets // []) | type == "array" and length <= 32 and all(.[]; type == "string")' >/dev/null 2>&1 <<<"$base_gates_json"; then
      not_certifiable "binaryAssets in .agents/gates.json at the base commit is not a list of at most 32 directory names"
      return
    fi
    while IFS= read -r prefix; do
      if [[ $prefix =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*/$ ]] && [ "${#prefix}" -le 200 ] && [[ $prefix != *..* ]]; then
        allowlist_entries+=("$prefix")
      else
        not_certifiable "binaryAssets entry \"$prefix\" at the base commit is not a plain relative directory ending in /"
        return
      fi
    done < <(jq -r '(.binaryAssets // [])[]' <<<"$base_gates_json")
  fi
  base_allowlist="[]"
  [ -z "$base_gates_json" ] || base_allowlist="$(jq -c '.binaryAssets // []' <<<"$base_gates_json")"
  case "$(read_gates_at "$head_sha" "$temporary_directory/head-gates.json")" in
    valid) head_allowlist="$(jq -c '.binaryAssets // []' "$temporary_directory/head-gates.json")" ;;
    missing) head_allowlist="[]" ;;
    *)
      not_certifiable ".agents/gates.json at HEAD cannot be read or is malformed, so its binaryAssets cannot be compared with the base"
      return
      ;;
  esac
  if [ "$base_allowlist" != "$head_allowlist" ]; then
    not_certifiable "this branch changes binaryAssets in .agents/gates.json; the allowlist can change only in a separate owner-reviewed change, never on the branch it would admit"
    return
  fi
  # Counted before any file is read (a name holding a newline can only raise the count).
  binary_count="$(set -o pipefail; tr '\0' '\n' <"$temporary_directory/changed-numstat" \
    | awk -F'\t' '$1 == "-" && $2 == "-" { count++ } END { print count + 0 }')" || binary_count=""
  if ! [[ $binary_count =~ ^[0-9]+$ ]]; then
    not_certifiable "the changed binary files cannot be counted"
    return
  fi
  if [ "$binary_count" -gt "$binary_file_limit" ]; then
    not_certifiable "more than $binary_file_limit changed binary files; they cannot all be checked and reported"
    return
  fi
  # --numstat and --raw list the same paths in the same order, so they are read side by side
  # (one pass; any disagreement is refused). --raw gives each path's status, mode and object.
  exec 7<"$raw_file"
  while IFS= read -r -d '' entry; do
    added="${entry%%$'\t'*}"
    changed_path="${entry#*$'\t'}"
    changed_path="${changed_path#*$'\t'}"
    if ! IFS= read -r -d '' raw_entry <&7 || ! IFS= read -r -d '' raw_path <&7 || [ "$raw_path" != "$changed_path" ]; then
      not_certifiable "the changed files cannot be listed consistently to find binary changes"
      break
    fi
    [ "$added" = - ] || continue
    if [ "$(remaining_seconds)" -le 60 ]; then
      not_certifiable "the readiness time limit of $total_limit_seconds s was reached while checking changed binary files"
      break
    fi
    # :old-mode new-mode old-object new-object status
    read -r _ mode _ object status <<<"$raw_entry"
    if [ "$status" = D ]; then
      binary_lines+=("D $changed_path (deleted; allowed)")
      continue
    fi
    size="$(controlled_git cat-file -s "$object" 2>/dev/null)" || size=""
    digest="$(controlled_git cat-file blob "$object" 2>/dev/null | { shasum -a 256 2>/dev/null || sha256sum; } | cut -d' ' -f1)"
    leading="$(controlled_git cat-file blob "$object" 2>/dev/null | head -c 16 | od -An -tx1 | tr -d ' \n')"
    extension="$(printf '%s' "${changed_path##*.}" | tr '[:upper:]' '[:lower:]')"
    [ "$changed_path" != "${changed_path%.*}" ] || extension=""
    binary_lines+=("${status:-?} $changed_path ${size:-?} bytes sha256 ${digest:-?}")
    allowed=no
    for prefix in "${allowlist_entries[@]+"${allowlist_entries[@]}"}"; do
      case "$changed_path" in "$prefix"*) allowed=yes ;; esac
    done
    if [ "$allowed" != yes ]; then
      not_certifiable "changed binary file $changed_path is not under a binaryAssets directory of the base commit (reviewers see only \"Binary files differ\")"
    elif [ "$mode" != 100644 ]; then
      not_certifiable "changed binary file $changed_path is not a plain non-executable file (mode ${mode:-unknown})"
    elif ! asset_signature_matches "$extension" "$leading"; then
      not_certifiable "changed binary file $changed_path is not an image or font asset of an allowed type (its extension or leading bytes do not match)"
    elif ! [[ $digest =~ ^[0-9a-f]{64}$ && $size =~ ^[0-9]+$ ]]; then
      not_certifiable "changed binary file $changed_path cannot be measured"
    fi
  done <"$temporary_directory/changed-numstat"
  exec 7<&-
}
[ -z "$base_sha" ] || [ -z "$head_sha" ] || check_changed_binaries

# ---------------------------------------------------------------- fresh clones at HEAD
# The external review and the gate each run in their own fresh local clone of this repository at
# exactly HEAD, in temporary roots separate from readiness's own files. Clone and checkout use
# controlled Git (above), so user, system or template configuration cannot filter, convert or add
# files; the checkout is then verified byte for byte against HEAD's index entries before anything
# runs there. A clone is checked out on a branch of its own (gate_branch), never detached and
# never named like the increment branch, so the guard's current-branch lookup succeeds there and
# nothing in the clone carries the increment's identity. The guard classifies a command the same
# way wherever the clone lives (directory names are neutral, not relied on). Only the increment
# branch is transferred, through Git's transport (--no-local: objects copied and checked with
# transfer.fsckObjects; no hard links, alternates or commit-graph shared); the clone's remote,
# every other branch and every replace ref are then removed; hooks are off. Its local
# configuration neutralises user-level settings that would reshape a diff (local configuration
# overrides user and system configuration), and each submodule's ignore setting from .gitmodules
# (which only local configuration overrides). A failure keeps Git's last message for the report.
clone_settings=(core.attributesFile=/dev/null core.bigFileThreshold=512m core.hooksPath=/dev/null core.fsmonitor=false
  diff.noprefix=false diff.mnemonicPrefix=false diff.srcPrefix=a/ diff.dstPrefix=b/ diff.relative=false
  diff.ignoreSubmodules=none)
# shellcheck disable=SC2329 # passed to run_bounded as the command to run
in_directory() { # directory command...: runs the command there (used in a background subshell)
  local directory="$1"
  shift
  cd "$directory" || return 125
  "$@"
}
# Following a link, and every link it reaches (at most 40), from the clone must end inside the
# clone: defence in depth for the lexical rule, on the files actually checked out. Every directory
# on the way is resolved physically (cd -P), so a directory that is itself a link is followed too.
# A target whose directory does not exist cannot be placed and fails.
link_resolves_inside() { # clone-real-path link-path-relative-to-it
  local root="$1" path="$1/$2" hops=0 directory name real_directory target
  while [ "$hops" -le 40 ]; do
    directory="${path%/*}"
    [ -n "$directory" ] || directory=/
    name="${path##*/}"
    case "$name" in
      "" | . | ..)
        real_directory="$(cd -P -- "$path" 2>/dev/null && pwd -P)" || return 1
        case "$real_directory/" in "$root"/*) return 0 ;; *) return 1 ;; esac
        ;;
    esac
    real_directory="$(cd -P -- "$directory" 2>/dev/null && pwd -P)" || return 1
    case "$real_directory/" in "$root"/*) ;; *) return 1 ;; esac
    path="$real_directory/$name"
    [ -L "$path" ] || return 0
    target="$(readlink -- "$path" 2>/dev/null)" || return 1
    case "$target" in /*) path="$target" ;; *) path="$real_directory/$target" ;; esac
    hops=$((hops + 1))
  done
  return 1
}
escaping_link=""
verify_clone_contents() { # clone: 0 every tracked file is exactly HEAD's blob and mode and nothing else exists; 2 a link resolves outside
  local clone="$1" entry metadata tracked_path mode blob stage clone_real
  local listing="$temporary_directory/clone-index" paths="$temporary_directory/clone-paths"
  local expected="$temporary_directory/clone-expected" actual="$temporary_directory/clone-actual"
  clone_real="$(cd -P -- "$clone" 2>/dev/null && pwd -P)" || return 1
  controlled_git -C "$clone" ls-files -s -z >"$listing" 2>/dev/null || return 1
  : >"$paths"
  : >"$expected"
  while IFS= read -r -d '' entry; do
    metadata="${entry%%$'\t'*}"
    tracked_path="${entry#*$'\t'}"
    read -r mode blob stage <<<"$metadata"
    [ "$stage" = 0 ] || return 1
    case "$tracked_path" in \"* | *$'\r'* | *$'\n'*) return 1 ;; esac # --stdin-paths would misread it
    case "$mode" in
      100644 | 100755)
        [ -f "$clone/$tracked_path" ] && [ ! -L "$clone/$tracked_path" ] || return 1
        if [ -x "$clone/$tracked_path" ]; then [ "$mode" = 100755 ] || return 1; else [ "$mode" = 100644 ] || return 1; fi
        printf '%s\n' "$tracked_path" >>"$paths"
        printf '%s\n' "$blob" >>"$expected"
        ;;
      120000)
        [ -L "$clone/$tracked_path" ] || return 1
        [ "$(printf '%s' "$(readlink "$clone/$tracked_path")" | controlled_git -C "$clone" hash-object --stdin 2>/dev/null)" = "$blob" ] || return 1
        link_resolves_inside "$clone_real" "$tracked_path" || { escaping_link="$tracked_path"; return 2; }
        ;;
      160000) ;; # a submodule is not checked out (documented limit)
      *) return 1 ;;
    esac
  done <"$listing"
  (cd "$clone" && controlled_git hash-object --no-filters --stdin-paths <"$paths") >"$actual" 2>/dev/null || return 1
  cmp -s "$expected" "$actual" || return 1
  # Nothing untracked or ignored either (a filter or template could have added files).
  controlled_git -C "$clone" status --porcelain=v1 --untracked-files=all --ignored >"$temporary_directory/clone-status" 2>/dev/null || return 1
  [ ! -s "$temporary_directory/clone-status" ]
}
clone_failure=""
clone_failed() { # reason [output-file]: records why the clone failed (Git's last line, bounded)
  local detail=""
  [ -z "${2:-}" ] || detail="$(tail -c 2048 "$2" 2>/dev/null | tr -d '\r' | awk 'NF { line = $0 } END { print line }' | tr -c '[:print:]' ' ' | cut -c1-200)"
  clone_failure="$1${detail:+ (git: $detail)}"
  return 1
}
prepare_clone() { # directory
  local clone="$1" local_ref setting limit submodule_key
  clone_failure=""
  # The child's private TMPDIR and HOME, beside the clone: removed with its root, even when the
  # child is stopped before its own cleanup runs.
  mkdir -p "$(dirname "$clone")/tmp" "$(dirname "$clone")/home" || clone_failed "its temporary directories could not be created" || return 1
  limit="$(remaining_seconds)"
  [ "$limit" -gt 0 ] || clone_failed "the readiness time limit was reached" || return 1
  # safe.directory: readiness's own git status already ran in this repository under the user's
  # configuration, which controlled Git does not read.
  run_bounded "$limit" "$temporary_directory/clone.out" controlled_git -c safe.directory="$repository_root" -c safe.directory="$repository_real" \
    -c transfer.fsckObjects=true clone --quiet --no-checkout --no-local --single-branch --branch "$current_branch" --no-tags \
    --template="$controlled_home/template" --origin ai-engineering-source -- "$repository_root" "$clone"
  [ "$bounded_timed_out" = no ] || clone_failed "the clone timed out" || return 1
  [ "$bounded_status" = 0 ] || clone_failed "git clone failed" "$temporary_directory/clone.out" || return 1
  # Without a remote, nothing in the clone can push or fetch back into the development repository.
  controlled_git -C "$clone" remote remove ai-engineering-source >/dev/null 2>&1 || clone_failed "its remote could not be removed" || return 1
  [ ! -s "$clone/.git/objects/info/alternates" ] || clone_failed "it shares objects (alternates)" || return 1
  limit="$(remaining_seconds)"
  [ "$limit" -gt 0 ] || clone_failed "the readiness time limit was reached" || return 1
  run_bounded "$limit" "$temporary_directory/checkout.out" controlled_git -C "$clone" checkout --quiet -B "$gate_branch" "$head_sha"
  [ "$bounded_timed_out" = no ] || clone_failed "the checkout timed out" || return 1
  [ "$bounded_status" = 0 ] || clone_failed "the checkout failed" "$temporary_directory/checkout.out" || return 1
  controlled_git -C "$clone" for-each-ref --format='%(refname)' refs/heads/ >"$temporary_directory/clone-refs" 2>/dev/null || clone_failed "its branches cannot be listed" || return 1
  while IFS= read -r local_ref; do
    [ "$local_ref" = "refs/heads/$gate_branch" ] || controlled_git -C "$clone" update-ref -d "$local_ref" >/dev/null 2>&1 || clone_failed "branch $local_ref could not be removed" || return 1
  done <"$temporary_directory/clone-refs"
  { [ "$(controlled_git -C "$clone" symbolic-ref --quiet HEAD 2>/dev/null)" = "refs/heads/$gate_branch" ] \
    && [ "$(controlled_git -C "$clone" rev-parse --verify HEAD 2>/dev/null)" = "$head_sha" ] \
    && controlled_git -C "$clone" cat-file -e "$base_sha^{commit}" 2>/dev/null \
    && [ "$(controlled_git -C "$clone" for-each-ref --format='%(refname)' refs/heads/ refs/remotes/ refs/replace/ 2>/dev/null)" = "refs/heads/$gate_branch" ] \
    && [ -z "$(controlled_git -C "$clone" remote 2>/dev/null)" ]; } || clone_failed "its branch, HEAD, base commit or refs are not as expected" || return 1
  for setting in "${clone_settings[@]}"; do
    controlled_git -C "$clone" config --local "${setting%%=*}" "${setting#*=}" || clone_failed "its local configuration could not be written" || return 1
  done
  if [ -e "$clone/.gitmodules" ]; then
    controlled_git config --file "$clone/.gitmodules" -z --name-only --get-regexp '^submodule\.' >"$temporary_directory/clone-submodules" 2>/dev/null \
      || clone_failed ".gitmodules cannot be read" || return 1
    while IFS= read -r -d '' submodule_key; do
      controlled_git -C "$clone" config --local "${submodule_key%.*}.ignore" none || clone_failed "a submodule ignore setting could not be overridden" || return 1
    done <"$temporary_directory/clone-submodules"
  fi
  [ ! -s "$clone/.git/info/attributes" ] || clone_failed "it has local attributes" || return 1
  verify_clone_contents "$clone"
  case $? in
    0) ;;
    2) clone_failed "tracked symbolic link $escaping_link does not resolve to a location inside the clone" ;;
    *) clone_failed "its files do not match HEAD byte for byte" ;;
  esac
}
new_clone_root() { # prints a new temporary root, separate from readiness's own files
  mktemp -d "$temporary_base/readiness-clone.XXXXXX" 2>/dev/null
}

# Why the external reviewer's own `git diff` (run with the user's environment in the review clone)
# could not show the change as it is, or nothing. Fails when this cannot be determined.
review_diff_problem() { # clone
  local clone="$1" external entry added rest changed_path attribute value driver key found hidden_path
  local numstat="$temporary_directory/review-numstat" changed="$temporary_directory/review-changed"
  local text_path_list=$'\n' attributes="$temporary_directory/review-attributes"
  external="$(child_environment git -C "$clone" config --get diff.external 2>/dev/null)"
  if [ -n "$external" ]; then
    printf 'diff.external is set in the user or system Git configuration and cannot be neutralised'
    return 0
  fi
  # Which changed paths are text, judged by content alone (controlled Git: no attributes).
  controlled_git -C "$clone" diff --numstat -z --no-renames --no-ext-diff --no-textconv --ignore-submodules=none "$base_sha" "$head_sha" -- >"$numstat" 2>/dev/null || return 1
  controlled_git -C "$clone" diff --name-only -z --no-renames --no-ext-diff --ignore-submodules=none "$base_sha" "$head_sha" -- >"$changed" 2>/dev/null || return 1
  # Every changed path must appear in the reviewer's own default diff (an ignore setting, for
  # example, can hide a submodule bump). Paths hold no newline (checked at HEAD and below).
  child_environment git -C "$clone" diff --name-only -z --no-renames "$base_sha" "$head_sha" -- >"$temporary_directory/review-visible" 2>/dev/null || return 1
  # Each step is checked: a failed tr, sort or comm would empty a list and hide every path.
  tr '\0' '\n' <"$changed" >"$temporary_directory/review-expected" || return 1
  tr '\0' '\n' <"$temporary_directory/review-visible" >"$temporary_directory/review-visible-lines" || return 1
  sort -u "$temporary_directory/review-expected" >"$temporary_directory/review-expected-sorted" || return 1
  sort -u "$temporary_directory/review-visible-lines" >"$temporary_directory/review-visible-sorted" || return 1
  if [ -s "$changed" ] && [ ! -s "$temporary_directory/review-expected-sorted" ]; then return 1; fi
  if [ -s "$temporary_directory/review-visible" ] && [ ! -s "$temporary_directory/review-visible-sorted" ]; then return 1; fi
  comm -23 "$temporary_directory/review-expected-sorted" "$temporary_directory/review-visible-sorted" >"$temporary_directory/review-hidden" || return 1
  hidden_path="$(head -n 1 "$temporary_directory/review-hidden")" || return 1
  if [ -n "$hidden_path" ]; then
    printf "changed path %s does not appear in the reviewer's own diff (for example a submodule ignore setting)" "$hidden_path"
    return 0
  fi
  while IFS= read -r -d '' entry; do
    added="${entry%%$'\t'*}"
    rest="${entry#*$'\t'}"
    changed_path="${rest#*$'\t'}"
    case "$changed_path" in *$'\n'*) return 1 ;; esac
    [ "$added" = - ] || text_path_list+="$changed_path"$'\n'
  done <"$numstat"
  # The attributes the reviewer's Git applies to the changed paths (committed .gitattributes
  # and system attributes included; the user's attributes file is neutralised).
  child_environment git -C "$clone" check-attr -z --stdin diff binary filter <"$changed" >"$attributes" 2>/dev/null || return 1
  while IFS= read -r -d '' changed_path && IFS= read -r -d '' attribute && IFS= read -r -d '' value; do
    case "$attribute:$value" in
      *:unspecified | diff:set | binary:unset | filter:unset) continue ;;
    esac
    case "$attribute" in
      filter)
        # A filter driver does not change a diff between two commits, but any configured one is
        # refused: the reviewer may read files from the clone, which controlled Git checked out
        # without it.
        for key in clean smudge process; do
          [ -z "$(child_environment git -C "$clone" config --get "filter.$value.$key" 2>/dev/null)" ] \
            || { printf '%s has filter=%s, a configured filter driver' "$changed_path" "$value"; return 0; }
        done
        ;;
      *)
        # A text path? (newline-delimited list; the quoted name matches literally)
        case "$text_path_list" in *$'\n'"$changed_path"$'\n'*) ;; *) continue ;; esac
        case "$attribute:$value" in
          diff:unset) printf '%s (text) has the -diff attribute, so its change would not be shown' "$changed_path"; return 0 ;;
          binary:set) printf '%s (text) has the binary attribute, so its change would not be shown' "$changed_path"; return 0 ;;
          diff:*)
            driver="$value"
            for key in textconv command binary; do
              found="$(child_environment git -C "$clone" config --get "diff.$driver.$key" 2>/dev/null)" || found=""
              [ -z "$found" ] || [ "$key:$found" = binary:false ] \
                || { printf '%s uses diff driver %s with diff.%s.%s set' "$changed_path" "$driver" "$driver" "$key"; return 0; }
            done
            ;;
        esac
        ;;
    esac
  done <"$attributes"
}

# ---------------------------------------------------------------- external review (before the gate)
# Gate and external review are skipped when readiness is already NOT CERTIFIABLE: they cannot
# change that outcome. Neither runs past its time limit or the overall limit; a timeout or a
# missing verdict is a failure, never a pass.
external_line="EXTERNAL REVIEW: NOT RUN (no base commit)"
external_result=error
external_ran=no
if [ -z "$base_sha" ] || [ -z "$head_sha" ]; then
  :
elif [ "${#not_certifiable_reasons[@]}" -gt 0 ]; then
  external_line="EXTERNAL REVIEW: NOT RUN (not certifiable)"
elif [ "$(remaining_seconds)" -le 0 ]; then
  external_line="EXTERNAL REVIEW: NOT RUN (readiness time limit reached)"
  not_certifiable "the readiness time limit of $total_limit_seconds s was reached before the external review"
elif [ "$effective_tier" -eq 0 ] && [ "$base_gates_state" = valid ] \
  && jq -e 'has("externalReview") and .externalReview == null' >/dev/null 2>&1 <<<"$base_gates_json"; then
  # Tier 0 with no reviewer configured, explicitly, at the base commit: nothing would review.
  external_line="EXTERNAL REVIEW: NOT CONFIGURED (externalReview is null at the base commit; no review clone made)"
  external_result=not-configured
else
  progress "creating a fresh clone of HEAD for the external review"
  review_root="$(new_clone_root)" || review_root=""
  review_clone="$review_root/review-tree"
  if [ -n "$review_root" ] && prepare_clone "$review_clone"; then
    if review_problem="$(review_diff_problem "$review_clone")"; then
      review_limit="$review_limit_seconds"
      [ "$(remaining_seconds)" -ge "$review_limit" ] || review_limit="$(remaining_seconds)"
      if [ -n "$review_problem" ]; then
        external_line="EXTERNAL REVIEW: NOT RUN (the reviewer's diff cannot be trusted)"
        not_certifiable "the external review cannot be trusted here: $review_problem"
      elif [ "$review_limit" -le 0 ]; then
        external_line="EXTERNAL REVIEW: NOT RUN (readiness time limit reached)"
        not_certifiable "the readiness time limit of $total_limit_seconds s was reached before the external review"
      else
        progress "running the external review (limit $((review_limit / 60)) min $((review_limit % 60)) s)"
        run_bounded "$review_limit" "$temporary_directory/external.out" \
          in_directory "$review_clone" plugin_child "$review_root" "$scripts/external-review.sh" "$base_sha" "$head_sha" "$spec_path"
        external_ran=yes
        external_exit="$bounded_status"
        # Bounded reads: the verdict lines only, never the whole output.
        external_first_line="$(head -c 4096 "$temporary_directory/external.out" | head -n 1)"
        external_last_line="$(tail -c 4096 "$temporary_directory/external.out" | tail -n 1)"
        # A verdict counts only when the exit status and the verdict line agree.
        if [ "$bounded_timed_out" = yes ]; then
          external_line="EXTERNAL REVIEW: ERROR (timed out after $review_limit s; stopped, exit $external_exit)"
        else
          case "$external_exit:$external_last_line:$external_first_line" in
            "0:EXTERNAL REVIEW: PASSED:"*) external_result=passed external_line="$external_last_line" ;;
            "1:EXTERNAL REVIEW: BLOCKING FINDINGS:"*) external_result=blocking external_line="$external_last_line" ;;
            "3:"*":EXTERNAL REVIEW: NOT CONFIGURED") external_result=not-configured external_line="$external_first_line" ;;
            "2:EXTERNAL REVIEW: ERROR"*) external_line="$external_last_line" ;;
            *) external_line="EXTERNAL REVIEW: ERROR (no consistent verdict; external-review.sh exit $external_exit)" ;;
          esac
        fi
      fi
    else
      external_line="EXTERNAL REVIEW: NOT RUN (the reviewer's diff settings cannot be read)"
      not_certifiable "the external review's Git attributes or configuration cannot be read"
    fi
  else
    external_line="EXTERNAL REVIEW: NOT RUN (a fresh clone of HEAD could not be created and verified)"
    not_certifiable "the external review could not run: a fresh clone of HEAD could not be created and verified${clone_failure:+: $clone_failure}"
  fi
  [ -z "$review_root" ] || remove_tree "$review_root" || : # retried and reported before the report
fi
external_requirement="optional at tier 0"
[ "$effective_tier" -lt 1 ] || external_requirement="required at tier $effective_tier"
if [ "$external_ran" = yes ]; then
  if [ "$effective_tier" -ge 1 ]; then
    [ "$external_result" = passed ] || not_ready "external review is required at tier $effective_tier and did not pass (${external_line#EXTERNAL REVIEW: })"
  else
    case "$external_result" in
      passed | not-configured) ;;
      *) not_ready "the configured external review did not pass (${external_line#EXTERNAL REVIEW: })" ;;
    esac
  fi
fi

# ---------------------------------------------------------------- full gate (last; never trusted from records)
gate_line="GATE full: NOT RUN (no base commit)"
gate_output=""
gate_ran=no
if [ -z "$base_sha" ] || [ -z "$head_sha" ]; then
  :
elif [ "${#not_certifiable_reasons[@]}" -gt 0 ]; then
  gate_line="GATE full: NOT RUN (not certifiable)"
elif [ $(($(remaining_seconds) - 60)) -le 0 ]; then
  gate_line="GATE full: NOT RUN (readiness time limit reached)"
  not_certifiable "the readiness time limit of $total_limit_seconds s was reached before the full gate"
else
  progress "creating a fresh clone of HEAD for the full gate"
  gate_root="$(new_clone_root)" || gate_root=""
  gate_clone="$gate_root/gate-tree"
  if [ -n "$gate_root" ] && prepare_clone "$gate_clone"; then
    gate_limit="$gate_limit_seconds"
    # Keep a minute for the checks after the gate.
    [ $(($(remaining_seconds) - 60)) -ge "$gate_limit" ] || gate_limit=$(($(remaining_seconds) - 60))
    if [ "$gate_limit" -le 0 ]; then
      gate_line="GATE full: NOT RUN (readiness time limit reached)"
      not_certifiable "the readiness time limit of $total_limit_seconds s was reached before the full gate"
    else
      progress "running the full gate (limit $((gate_limit / 60)) min $((gate_limit % 60)) s)"
      run_bounded "$gate_limit" "$temporary_directory/gate.out" plugin_child "$gate_root" "$scripts/run-gate.sh" full "$gate_clone" "$base_sha"
      gate_ran=yes
      gate_exit="$bounded_status"
      # At most the last MiB is read (run-gate.sh prints only its last 80 lines and the verdict).
      gate_output="$(tail -c 1048576 "$temporary_directory/gate.out" 2>/dev/null)"
      gate_last_line="$(printf '%s\n' "$gate_output" | tail -n 1)"
      if [ "$bounded_timed_out" = yes ]; then
        gate_line="GATE full: TIMED OUT (after $gate_limit s; stopped, exit $gate_exit)"
      else
        case "$gate_exit:$gate_last_line" in
          "0:GATE full: PASSED"*) gate_line="$gate_last_line" ;;
          "0:"*) gate_line="GATE full: NO VERDICT (run-gate.sh exit 0 without a PASSED verdict)" ;;
          *":GATE full: PASSED"*) gate_line="GATE full: NO VERDICT (run-gate.sh exit $gate_exit after a PASSED line)" ;;
          *":GATE full: "*) gate_line="$gate_last_line" ;;
          *) gate_line="GATE full: NO VERDICT (run-gate.sh exit $gate_exit)" ;;
        esac
      fi
    fi
  else
    gate_line="GATE full: NOT RUN (a fresh clone of HEAD could not be created and verified)"
    not_certifiable "the full gate could not run: a fresh clone of HEAD could not be created and verified${clone_failure:+: $clone_failure}"
  fi
  [ -z "$gate_root" ] || remove_tree "$gate_root" || : # retried and reported before the report
fi
if [ "$gate_ran" = yes ]; then
  case "$gate_line" in
    "GATE full: PASSED"*"MODIFIES"*) not_ready "the change modifies the full gate (owner review needed)" ;;
    "GATE full: PASSED"*) ;;
    "GATE full: TIMED OUT"*) not_ready "the full gate timed out" ;;
    *) not_ready "the full gate did not pass" ;;
  esac
fi

# ---------------------------------------------------------------- revalidation after the gate
# The gate runs the change's own code with the user's privileges, so what readiness relied on is
# checked again. A changed or unreadable input is NOT CERTIFIABLE; no earlier result is reused.
# This is defence in depth: it catches persistent or accidental changes, not a determined hostile
# gate (which runs with the same privileges as readiness itself).
progress "checking again what the gate could have changed"
if [ -n "$state_fingerprint" ]; then
  { regular_file "$live_state" && regular_file "$live_spec" \
      && [ "$(sha256_file "$live_state")" = "$state_fingerprint" ] && [ "$(sha256_file "$live_spec")" = "$spec_fingerprint" ]; } \
    || not_certifiable "the work-item state or spec changed while readiness ran"
fi
[ -z "$head_sha" ] || [ "$(git rev-parse --verify HEAD 2>/dev/null)" = "$head_sha" ] || not_certifiable "HEAD moved while readiness ran"
if [ -n "$base_sha" ] && [ "$(git rev-parse --verify --quiet "refs/remotes/origin/$default_branch^{commit}" 2>/dev/null)" != "$base_sha" ]; then
  not_certifiable "origin/$default_branch moved while readiness ran"
fi
if [ -n "$increment_branch" ] && [ -n "$current_branch" ] && [ "$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" != "$current_branch" ]; then
  not_certifiable "the checked-out branch changed while readiness ran"
fi
check_replace_refs " (after the gate)"
if [ "$trusted" = yes ]; then
  trusted=no
  check_trust
  [ "$trusted" = yes ] || not_certifiable "the installed plugin no longer matches its release tag after the gate"
fi
[ "$(evidence_summary)" = "$evidence_before" ] || not_certifiable "the review evidence covering HEAD changed while readiness ran"

# ---------------------------------------------------------------- cleanup, then the report
# The records are read before cleanup (jq runs with readiness's private HOME). Every temporary
# root is then removed and checked before anything is printed: a root that is left is NOT
# CERTIFIABLE, and nothing runs after the final READY line (signals are ignored from here on,
# the EXIT trap has nothing left to do, and cleanup messages are discarded).
trap '' INT TERM HUP
high_fixes="$(record_list '.highFindings[] | select(.disposition.state == "fixed") | .id')"
owner_decisions="$(record_list '.ownerDecisions[] | .id')"
conversation_decisions="$(record_list '.conversationDecisions[] | .id')"
open_decisions="$(record_list '.openDecisions[] | "\(.id)\(if .blocking then "" else " (proposal)" end)"')"
pending_actions="$(record_list '.pendingOwnerActions[] | .id')"
stop_active_child
for leftover_root in "$review_root" "$gate_root" "$temporary_directory"; do
  [ -z "$leftover_root" ] || remove_tree "$leftover_root" || not_certifiable "temporary files under $leftover_root could not be removed"
done
review_root="" gate_root="" temporary_directory=""

# Every line of the block goes through block_line, which turns control characters (newlines and
# carriage returns included) and every byte outside ASCII into "?": a path, record id, guard-log
# value or reason cannot start a line of its own, and no Unicode line separator or bidirectional
# control reaches the reader. The gate's output is quoted with a "  | " prefix and the same
# replacement. Only the final "READY:" line, with the exit status, is the verdict.
block_line() { printf '%s\n' "$(printf '%s' "$1" | LC_ALL=C tr '\001-\037\177-\377' '?')"; }
certifiable=yes
[ "${#not_certifiable_reasons[@]}" -eq 0 ] || certifiable=no
if [ "$certifiable" = yes ]; then
  tier_label="$effective_tier (classified)"
else
  effective_tier=2
  tier_label="2 (NOT CERTIFIABLE)"
  not_ready "not certifiable"
fi

block_line "READINESS - $work_id increment $increment_id"
block_line "BASE: ${base_sha:-unknown} (recorded increment base; origin/${default_branch:-?} at ${default_ref_commit:-unknown})  HEAD: ${head_sha:-unknown}"
block_line "BASE PROVENANCE: $base_provenance"
if [ "$trusted" = yes ]; then block_line "TRUST: TRUSTED - $trust_summary"; else block_line "TRUST: NOT CERTIFIABLE"; fi
block_line "STATE TIER: $state_tier"
block_line "CLASSIFIER FLOOR: $classifier_summary"
block_line "ACTION FLOOR: $action_summary"
block_line "GUARD LOG: $guard_log_summary"
block_line "EFFECTIVE TIER: $tier_label"
block_line "$gate_line"
case "$gate_line" in
  "GATE full: PASSED"*) ;;
  *)
    if [ -n "$gate_output" ]; then
      block_line "GATE OUTPUT (last 20 lines, each prefixed with \"  | \"):"
      printf '%s\n' "$gate_output" | tail -n 20 | cut -c1-400 | LC_ALL=C tr '\001-\011\013-\037\177-\377' '?' | sed 's/^/  | /'
    fi
    ;;
esac
if [ "${#binary_lines[@]}" -eq 0 ]; then
  block_line "CHANGED BINARY FILES: none"
else
  block_line "CHANGED BINARY FILES: ${#binary_lines[@]}"
  for binary_line in "${binary_lines[@]:0:50}"; do block_line "  $binary_line"; done
  [ "${#binary_lines[@]}" -le 50 ] || block_line "  ... $((${#binary_lines[@]} - 50)) more"
fi
block_line "QA (internal): $qa_status"
block_line "SECURITY REVIEW (internal): $security_status"
block_line "$external_line ($external_requirement)"
block_line "RESIDUAL RISKS: $residual_status"
block_line "HIGH-OR-ABOVE FIXES: $high_fixes"
block_line "OWNER-COMMAND RISK DECISIONS: $owner_decisions"
block_line "CONVERSATION DECISIONS: $conversation_decisions"
block_line "OPEN DECISIONS AND PROPOSALS: $open_decisions"
block_line "OPEN FINDINGS: $open_findings"
block_line "PENDING OWNER ACTIONS: $pending_actions"
if [ "$certifiable" = yes ]; then
  block_line "CERTIFIABLE: YES"
else
  block_line "CERTIFIABLE: NOT CERTIFIABLE - $(printf '%s; ' "${not_certifiable_reasons[@]}" | sed 's/; $//')"
fi
if [ "${#not_ready_reasons[@]}" -eq 0 ]; then
  block_line "READY: YES"
  exit 0
fi
block_line "READY: NO - $(printf '%s; ' "${not_ready_reasons[@]}" | sed 's/; $//')"
[ "$certifiable" = yes ] && exit 1
exit 3
}
main "$@" # every path through main ends in exit
