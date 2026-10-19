#!/bin/bash
# wait-github.sh: bounded wait for CI checks or a pull request merge, through authenticated gh.
# WORK-002 Scope item 14. Meant to run as a background command; prints exactly one verdict line.
#
# Usage:  wait-github.sh [--timeout <seconds>] [--interval <seconds>] [--max-interval <seconds>] checks <pr-number|commit-sha>
#         wait-github.sh [same options] merge <pr-number>
# Defaults: timeout 1800, interval 10 (doubling, capped by max-interval 60).
#
# Verdict lines and exit codes:
#   0  CHECKS PASSED | MERGED
#   1  CHECKS FAILED | PR CLOSED NOT MERGED
#   2  usage error
#   3  NOT AUTHENTICATED: gh is missing or not logged in; a planned owner action, never a poll
#   4  TIMEOUT: still pending when the time ran out
#   5  ERROR: repeated error payloads, rate limits or malformed responses
#
# It checks `gh auth status` first and makes no call when that fails. An error payload (rate
# limit, 404, anything that is not the expected shape) is never read as data: it is retried a
# bounded number of times with backoff, then reported as ERROR. Raw gh output is never printed,
# so tokens and error bodies cannot reach the log.
set -u

readonly MAX_CONSECUTIVE_ERRORS=3
timeout_seconds=1800
interval_seconds=10
max_interval_seconds=60

usage() {
  echo "usage: wait-github.sh [--timeout S] [--interval S] [--max-interval S] checks <pr|sha> | merge <pr>" >&2
  exit 2
}

verdict() { # exit-code text
  printf '%s\n' "$2"
  exit "$1"
}

is_number() { case "$1" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

while [ $# -gt 0 ]; do
  case "$1" in
    --timeout | --interval | --max-interval)
      if [ $# -lt 2 ] || ! is_number "$2"; then usage; fi
      case "$1" in
        --timeout) timeout_seconds="$2" ;;
        --interval) interval_seconds="$2" ;;
        --max-interval) max_interval_seconds="$2" ;;
      esac
      shift 2
      ;;
    --) shift; break ;;
    -*) usage ;;
    *) break ;;
  esac
done
[ $# -eq 2 ] || usage
mode="$1"
target="$2"

case "$mode" in
  checks)
    if is_number "$target" && [ "${#target}" -le 6 ]; then
      target_kind="pr"
    elif printf '%s' "$target" | grep -Eq '^[0-9a-fA-F]{7,40}$'; then
      target_kind="sha"
    else
      usage
    fi
    ;;
  merge)
    if ! is_number "$target" || [ "${#target}" -gt 6 ]; then usage; fi
    ;;
  *) usage ;;
esac

# Never poll without credentials: stop with a planned owner action.
unset GH_DEBUG GH_PROMPT_DISABLED
export GH_PROMPT_DISABLED=1
if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  verdict 3 "NOT AUTHENTICATED: gh or jq is not installed; owner action: install and run gh auth login, then re-run this wait"
fi
if ! gh auth status >/dev/null 2>&1; then
  verdict 3 "NOT AUTHENTICATED: owner action: run gh auth login, then re-run this wait"
fi

# Each fetcher prints one JSON document on success. Each classifier reads that document and prints
# "pass", "fail <names>", "pending" or "invalid"; anything of the wrong shape is "invalid".
fetch_checks() {
  if [ "$target_kind" = pr ]; then
    gh pr checks "$target" --json name,bucket 2>/dev/null
  else
    gh api "repos/{owner}/{repo}/commits/$target/check-runs?per_page=100" 2>/dev/null
  fi
}

classify_checks() {
  jq -r --arg kind "$target_kind" '
    def names: map(.name | tostring | gsub("[^[:print:]]"; "") | .[0:60]) | .[0:3] | join(", ");
    (if $kind == "pr" then
       (if type == "array" and all(.[]; type == "object" and (.name | type == "string") and (.bucket | type == "string"))
        then map({name: .name, state: (if (.bucket | IN("pass", "skipping")) then "pass"
                                       elif (.bucket | IN("fail", "cancel")) then "fail"
                                       elif .bucket == "pending" then "pending" else "invalid" end)})
        else null end)
     else
       (if type == "object" and (.check_runs | type == "array")
           and all(.check_runs[]; type == "object" and (.name | type == "string") and (.status | type == "string"))
        then .check_runs | map({name: .name, state: (if .status != "completed" then "pending"
                                       elif (.conclusion | IN("success", "neutral", "skipped")) then "pass"
                                       elif (.conclusion | IN("failure", "cancelled", "timed_out", "action_required", "startup_failure", "stale")) then "fail"
                                       else "invalid" end)})
        else null end)
     end) as $runs
    | if $runs == null or any($runs[]; .state == "invalid") then "invalid"
      elif any($runs[]; .state == "fail") then "fail " + ($runs | map(select(.state == "fail")) | names)
      elif ($runs | length) == 0 or any($runs[]; .state == "pending") then "pending"
      else "pass" end' 2>/dev/null
}

fetch_merge() { gh pr view "$target" --json state,mergeCommit 2>/dev/null; }

classify_merge() {
  jq -r '
    if type == "object" and (.state | type == "string") and (.state | IN("OPEN", "MERGED", "CLOSED"))
    then (if .state == "MERGED" then "pass" elif .state == "CLOSED" then "fail" else "pending" end)
    else "invalid" end' 2>/dev/null
}

consecutive_errors=0
current_interval="$interval_seconds"
started_at="$SECONDS"

while :; do
  if [ "$mode" = checks ]; then
    response="$(fetch_checks)"
    classification="$(printf '%s' "$response" | classify_checks)"
  else
    response="$(fetch_merge)"
    classification="$(printf '%s' "$response" | classify_merge)"
  fi
  [ -n "$classification" ] || classification=invalid

  case "$classification" in
    pass)
      [ "$mode" = checks ] && verdict 0 "CHECKS PASSED: $target"
      verdict 0 "MERGED: PR $target"
      ;;
    fail*)
      if [ "$mode" = checks ]; then
        failed_names="${classification#fail}"
        verdict 1 "CHECKS FAILED: $target${failed_names:+ (${failed_names# })}"
      fi
      verdict 1 "PR CLOSED NOT MERGED: PR $target"
      ;;
    invalid)
      consecutive_errors=$((consecutive_errors + 1))
      if [ "$consecutive_errors" -ge "$MAX_CONSECUTIVE_ERRORS" ]; then
        verdict 5 "ERROR: $consecutive_errors consecutive unusable responses from GitHub (error payload, rate limit or malformed data); not treated as a result"
      fi
      ;;
    *) consecutive_errors=0 ;;
  esac

  elapsed=$((SECONDS - started_at))
  if [ $((elapsed + current_interval)) -gt "$timeout_seconds" ]; then
    verdict 4 "TIMEOUT: still pending after ${elapsed}s (limit ${timeout_seconds}s): $mode $target"
  fi
  sleep "$current_interval"
  current_interval=$((current_interval * 2))
  [ "$current_interval" -le "$max_interval_seconds" ] || current_interval="$max_interval_seconds"
done
