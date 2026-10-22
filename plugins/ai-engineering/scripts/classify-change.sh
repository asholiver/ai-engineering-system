#!/bin/bash
# Deterministic change classifier: computes the lowest assurance tier a diff may take.
#
# Usage: classify-change.sh [--active WORK-NNN] <base> <head> [directory]
#        classify-change.sh --glob-match <glob> <path>      (matcher check, exit 0 match, 1 no match)
#        classify-change.sh --git-version-check "<git --version text>"   (exit 0 if git >= 2.40)
#
# base and head are Git refs, resolved to commits. The diff is "git diff <base> <head>"
# (two-dot, so a base that moved ahead of the branch point only makes the result stricter).
# directory defaults to $PWD and is used to find the repository root.
#
# Output: exactly one JSON object on stdout:
#   {"floorTier": 0|1|2, "base": "<sha>", "head": "<sha>",
#    "paths": [{"path", "side": "old"|"new"|"both", "status": "<git status letter>",
#               "tier": 0|1|2|null, "reasons": ["..."]}],
#    "unclassified": ["path", ...], "error": null|"message"}
# floorTier is the maximum tier over all paths. Renames and copies list both sides. An empty
# diff is floor 0 with no paths. tier null (reason "active-item bookkeeping") marks the active
# work item's own state and log files, which never change the floor.
#
# Exit codes: 0 classified (including a cap-exceeded result, floor 2); 2 usage error, message
# on stderr and no JSON; 3 classifier error. On a classifier error (unresolvable ref, failed
# git command, malformed or wrongly typed .agents/gates.json at base, jq failure, reserved
# control bytes in a path) the JSON still prints with floorTier 2 and "error" set, so callers
# that only read the JSON fail safe.
#
# Reason identifiers (stable):
#   tier2:auth tier2:migration tier2:sql tier2:destructive-sql tier2:ci tier2:iac
#   tier2:secrets tier2:lockfile tier2:dependency tier2:gates tier2:definedBy
#   tier2:plugin-config tier2:plugin-code tier2:case-collision tier2:hook-target
#   tier1:executable      (a mode change that makes a file executable, any path)
#   instruction:claude-config instruction:agent-definition instruction:workflow
#   instruction:codeowners instruction:agents-md instruction:claude-md instruction:skill
#   instruction:skill-or-command instruction:github      (never tier 0)
#   tier1:agents tier1:default riskPaths:2 riskPaths:1
#   tier0:markdown tier0:docs tier0:copyPaths            (only when nothing else matched)
#   unclassified:binary unclassified:symlink unclassified:submodule unclassified:status
#   active-item bookkeeping
#   cap:exceeded    synthetic path "(cap exceeded)", status "!", tier 2
#
# Caps (above either: floor 2 with reason cap:exceeded, not an error exit):
#   changed paths   5000     AI_ENGINEERING_CLASSIFY_MAX_PATHS can only lower it
#   diff bytes read 50 MiB   AI_ENGINEERING_CLASSIFY_MAX_BYTES can only lower it
# The byte cap counts every line of the -U0 patch read while scanning added lines for
# destructive SQL; the scan streams and stops at the cap.
#
# Project configuration (riskPaths, copyPaths, definedBy) comes only from
# .agents/gates.json at the base commit; values changed on the branch are ignored. A missing
# file means the plugin defaults only.
#
# Hook command targets (tier2:hook-target): every repository-relative file path named in a hook
# "command" of .claude/settings.json at the base commit is tier 2, because hooks run in every
# session. Paths are taken from the command's words after removing quotes and a leading
# $CLAUDE_PROJECT_DIR/ or ./; words with other variables, globs or absolute paths are not
# resolved, and files those scripts call are not followed. An unreadable, oversized or malformed
# .claude/settings.json at base is a classifier error (floor 2).
#
# Glob semantics (one matcher for defaults and project globs): paths are repository-relative
# with "/"; "**/" matches zero or more directories, a trailing "/**" matches everything below,
# "*" matches within one segment, "?" one non-"/" character. Every built-in rule is
# case-insensitive. Under docs/, tier 0 applies only to recognised documentation and asset
# types (md mdx markdown rst adoc txt png jpg jpeg gif svg webp ico pdf drawio mmd puml);
# any other file there is at least tier 1. Project globs are used as written and are case-sensitive (a bare "package.json" matches only
# the root; write "**/package.json" for any directory). Built-in globs without "/" are written
# with a "**/" prefix so they apply in any directory. A changed path that, folded to lower case,
# collides with another head path or directory prefix differing only in case is tier 2
# (tier2:case-collision): case-insensitive checkouts would conflate them.
#
# Plugin roots: a directory holding .claude-plugin/plugin.json in the base or head tree. Under
# one, every non-Markdown file (including scripts and templates under skills/ and commands/),
# everything in output-styles/ and .mcp.json is tier 2 (tier2:plugin-code), so scripts, jq
# programs and hook targets are covered. Markdown there keeps its instruction-file tier.
#
# Safety: repository content is data. Nothing from the repository is executed or sourced, and
# external diff drivers, textconv and diff-affecting config are disabled. Every git call runs
# with replace objects and lazy fetch off, the global attributes file disabled and GIT_*
# repository-redirecting variables unset. Attributes can change what counts as binary, so the
# classifier reads attributes from the empty tree, and fails closed (error, floor 2) when
# $GIT_DIR/info/attributes exists and has content, because git offers no switch to ignore it.
# Known limits: the
# destructive-SQL check is a per-line heuristic over statement shapes (a statement split across
# lines, or built from string pieces, is not seen). It scans the whole new-side content of
# renamed and copied files. Shapes, case-insensitive, on added lines of any file:
# DROP <TABLE|DATABASE|SCHEMA|VIEW|MATERIALIZED VIEW|INDEX|COLUMN|USER|ROLE|SEQUENCE|FUNCTION|
# PROCEDURE|TRIGGER|TYPE|EXTENSION|TEMPORARY TABLE|TEMP TABLE>; ALTER TABLE ... DROP;
# TRUNCATE TABLE, or TRUNCATE [ONLY] <identifier> followed by end of line, ";", a quote, ")",
# "," or CASCADE/RESTRICT/RESTART/CONTINUE; DELETE FROM <identifier>. GRANT and REVOKE are not
# matched (privilege paths are caught by the auth/permission path rules). Prose such as
# "truncate long lines" does not match, though a two-word line like "truncate lines" does.
set -u

default_max_paths=5000
default_max_bytes=52428800
raw_output_limit=67108864
gates_size_limit=1048576

usage_error() {
  echo "classify-change.sh: $1" >&2
  echo "usage: classify-change.sh [--active WORK-NNN] <base> <head> [directory]" >&2
  echo "       classify-change.sh --glob-match <glob> <path>" >&2
  exit 2
}

work_directory=""
cleanup() { [ -n "$work_directory" ] && rm -rf "$work_directory"; }
trap cleanup EXIT

# Writes the shared awk library: the one glob-to-regex translation.
write_awk_library() {
  cat >"$1" <<'AWK_LIBRARY'
# Translates a glob into an anchored extended regular expression.
function glob_to_regex(glob,    length_of_glob, position, character, output, run_end, run, at_segment_start) {
  length_of_glob = length(glob)
  output = "^"
  position = 1
  while (position <= length_of_glob) {
    character = substr(glob, position, 1)
    if (character == "*") {
      run_end = position
      while (substr(glob, run_end, 1) == "*") run_end++
      run = run_end - position
      at_segment_start = (position == 1 || substr(glob, position - 1, 1) == "/")
      if (run >= 2 && at_segment_start && substr(glob, run_end, 1) == "/") {
        output = output "(.*/)?"
        position = run_end + 1
      } else if (run >= 2 && at_segment_start && run_end > length_of_glob) {
        output = output ".+"
        position = run_end
      } else {
        output = output "[^/]*"
        position = run_end
      }
      continue
    }
    if (character == "?") output = output "[^/]"
    else if (character == "\\") output = output "\\\\"
    else if (character == "^") output = output "\\^"
    else if (index(".()+{}|$[]", character) > 0) output = output "[" character "]"
    else output = output character
    position++
  }
  return output "$"
}
AWK_LIBRARY
}

# True when the "git --version" text names git 2.40 or later (GIT_ATTR_SOURCE needs 2.40).
# Anything unparsable is unsupported.
git_version_is_supported() {
  local version_text="$1" major minor
  [[ "$version_text" =~ ^git\ version\ ([0-9]+)\.([0-9]+) ]] || return 1
  major=$((10#${BASH_REMATCH[1]}))
  minor=$((10#${BASH_REMATCH[2]}))
  [ "$major" -gt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -ge 40 ]; }
}

# ---------------------------------------------------------------- arguments
active_item=""
if [ "${1:-}" = "--git-version-check" ]; then
  [ $# -eq 2 ] || usage_error "--git-version-check needs a version string"
  git_version_is_supported "$2"
  exit $?
fi
if [ "${1:-}" = "--glob-match" ]; then
  [ $# -eq 3 ] || usage_error "--glob-match needs a glob and a path"
  work_directory="$(mktemp -d "${TMPDIR:-/tmp}/classify-change.XXXXXX")" || exit 3
  write_awk_library "$work_directory/library.awk" || exit 3
  printf '%s\n' 'BEGIN { exit !(ENVIRON["PATH_UNDER_TEST"] ~ glob_to_regex(ENVIRON["GLOB_UNDER_TEST"])) }' >"$work_directory/match.awk" || exit 3
  GLOB_UNDER_TEST="$2" PATH_UNDER_TEST="$3" LC_ALL=C awk -f "$work_directory/library.awk" -f "$work_directory/match.awk"
  exit $?
fi
if [ "${1:-}" = "--active" ]; then
  [ $# -ge 2 ] || usage_error "--active needs a work item id"
  active_item="$2"
  case "$active_item" in
    WORK-[0-9]*) ;;
    *) usage_error "--active must look like WORK-NNN" ;;
  esac
  case "${active_item#WORK-}" in
    *[!0-9]*) usage_error "--active must look like WORK-NNN" ;;
  esac
  shift 2
fi
case "${1:-}" in --*) usage_error "unknown option $1" ;; esac
[ $# -ge 2 ] && [ $# -le 3 ] || usage_error "expected <base> <head> [directory]"
base_reference="$1"
head_reference="$2"
start_directory="${3:-$PWD}"

# Positive integer environment overrides may only lower a cap.
lowered_cap() {
  local default_value="$1" requested="$2"
  case "$requested" in
    '' | *[!0-9]* | 0*) printf '%s\n' "$default_value" ;;
    *) if [ "${#requested}" -le 9 ] && [ "$requested" -lt "$default_value" ]; then printf '%s\n' "$requested"; else printf '%s\n' "$default_value"; fi ;;
  esac
}
max_paths="$(lowered_cap "$default_max_paths" "${AI_ENGINEERING_CLASSIFY_MAX_PATHS:-}")"
max_bytes="$(lowered_cap "$default_max_bytes" "${AI_ENGINEERING_CLASSIFY_MAX_BYTES:-}")"

base_sha="" head_sha=""
fail_closed() {
  local message="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg base "$base_sha" --arg head "$head_sha" --arg error "$message" \
      '{floorTier: 2, base: $base, head: $head, paths: [], unclassified: [], error: $error}'
  else
    printf '%s\n' '{"floorTier":2,"base":"","head":"","paths":[],"unclassified":[],"error":"jq is not available"}'
  fi
  exit 3
}

# Sets measured_size to the file's size in bytes. A wc that fails or prints something other than
# a number fails closed: an empty size would otherwise compare as neither large nor small.
measure_size() { # file description
  measured_size="$(wc -c <"$1")" || fail_closed "cannot measure $2"
  measured_size="${measured_size//[[:space:]]/}"
  case "$measured_size" in '' | *[!0-9]*) fail_closed "cannot measure $2" ;; esac
}

# A configuration file must hold exactly one JSON object. jq reads whitespace alone as no input
# and several documents as several configurations, so either would silently drop or split rules.
require_one_json_object() { # file description
  jq -e -s 'length == 1 and (.[0] | type == "object")' "$1" >/dev/null 2>&1 || fail_closed "$2 must be exactly one JSON object"
}

# The repository comes from the directory argument only: inherited variables that redirect
# git to another repository, index, object store or configuration are removed before any git
# command runs (git --version included). grep's option variables go too (BSD grep reads
# GREP_OPTIONS), although no result here depends on grep.
unset GIT_EXTERNAL_DIFF GIT_PAGER GIT_DIFF_OPTS GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT \
  GIT_COMMON_DIR GIT_REPLACE_REF_BASE GIT_ATTR_SOURCE GREP_OPTIONS GREP_COLOR GREP_COLORS
# Replace refs could swap the commits or trees being classified; a lazy fetch could run a
# remote program or change the object set.
export GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1

command -v jq >/dev/null 2>&1 || fail_closed "jq is not available"
command -v git >/dev/null 2>&1 || fail_closed "git is not available"
git_version_is_supported "$(git --version 2>/dev/null)" || fail_closed "git is older than 2.40 or its version cannot be parsed"

work_directory="$(mktemp -d "${TMPDIR:-/tmp}/classify-change.XXXXXX")" || fail_closed "cannot create a temporary directory"
write_awk_library "$work_directory/library.awk" || fail_closed "cannot write the awk library"

# ---------------------------------------------------------------- repository and refs

# Neutralise configuration that could hide or reshape changes or run programs.
run_git() {
  git -C "$repository_root" -c core.quotepath=off -c core.fsmonitor=false -c diff.external= \
    -c diff.noprefix=false -c diff.mnemonicPrefix=false -c diff.ignoreSubmodules=none \
    -c diff.relative=false -c color.ui=false -c core.attributesFile=/dev/null "$@"
}
repository_root="$(git -C "$start_directory" -c core.attributesFile=/dev/null rev-parse --show-toplevel 2>/dev/null)" || fail_closed "not inside a Git repository: $start_directory"

base_sha="$(run_git rev-parse --verify --end-of-options "$base_reference^{commit}" 2>/dev/null)" || {
  base_sha=""
  fail_closed "cannot resolve base ref"
}
head_sha="$(run_git rev-parse --verify --end-of-options "$head_reference^{commit}" 2>/dev/null)" || {
  head_sha=""
  fail_closed "cannot resolve head ref"
}

# Attributes decide what git calls binary (a "diff" attribute makes a binary look like text),
# so they must not come from the working tree or from $GIT_DIR/info/attributes. The first is
# redirected to the empty tree. git has no switch for the second, so a non-empty file there is
# a classifier error (floor 2) rather than a silent downgrade.
empty_tree="$(run_git hash-object -t tree /dev/null 2>/dev/null)" || fail_closed "cannot compute the empty tree"
export GIT_ATTR_SOURCE="$empty_tree"
info_attributes="$(run_git rev-parse --git-path info/attributes 2>/dev/null)" || fail_closed "cannot locate info/attributes"
case "$info_attributes" in /*) ;; *) info_attributes="$repository_root/$info_attributes" ;; esac
if [ -s "$info_attributes" ]; then
  fail_closed "$info_attributes has content and cannot be ignored; remove it to classify"
fi

diff_options=(--no-ext-diff --no-textconv --no-color --ignore-submodules=none -M -C -l400 --src-prefix=a/ --dst-prefix=b/)
# The destructive-statement scan reads the whole new side of renamed and copied files.
patch_options=(--no-ext-diff --no-textconv --no-color --ignore-submodules=none --no-renames --src-prefix=a/ --dst-prefix=b/)

# ---------------------------------------------------------------- project configuration (base only)
config_rules="$work_directory/config-rules.tsv"
: >"$config_rules"
if run_git cat-file -e "$base_sha:.agents/gates.json" 2>/dev/null; then
  gates_file="$work_directory/gates.json"
  run_git show "$base_sha:.agents/gates.json" 2>/dev/null | head -c $((gates_size_limit + 1)) >"$gates_file"
  read_status=("${PIPESTATUS[@]}")
  measure_size "$gates_file" ".agents/gates.json at base"
  # head stops at the limit (git may then be stopped by the closed pipe), so git's status is
  # excused only for an oversized file; head itself must succeed. An empty file is never valid
  # JSON, and jq would read it as no configuration.
  [ "${read_status[1]}" -eq 0 ] || fail_closed "cannot read .agents/gates.json at base"
  [ "${read_status[0]}" -eq 0 ] || [ "$measured_size" -gt "$gates_size_limit" ] || fail_closed "cannot read .agents/gates.json at base"
  [ "$measured_size" -le "$gates_size_limit" ] || fail_closed ".agents/gates.json at base is too large"
  [ "$measured_size" -gt 0 ] || fail_closed ".agents/gates.json at base is empty"
  require_one_json_object "$gates_file" ".agents/gates.json at base"
  config_program="$work_directory/config.jq"
  cat >"$config_program" <<'JQ' || fail_closed "cannot write the configuration program"
def valid_globs: type == "array" and all(.[]; type == "string" and length > 0 and length <= 512 and (test("[\\x00-\\x1f\\x7f]") | not));
def rule($tier; $reason; $glob): "\($tier)\t\($reason)\tglob\t\($glob)";
(if type == "object" then . else error("gates.json must be a JSON object") end) as $config
| (if $config | has("riskPaths") then $config.riskPaths else {} end) as $risk
| (if ($risk | type) == "object" and (($risk | keys) - ["1", "2"] | length) == 0 and all($risk[]; valid_globs) then $risk else error("riskPaths must be an object with arrays of globs under \"1\" and \"2\"") end) as $risk
| (if $config | has("copyPaths") then $config.copyPaths else [] end) as $copy
| (if $copy | valid_globs then $copy else error("copyPaths must be an array of globs") end) as $copy
| ([$config | to_entries[] | select(.key == "definedBy" or (.value | type) == "object") | if .key == "definedBy" then .value else (.value | if has("definedBy") then .definedBy else [] end) end]) as $defined_lists
| (if all($defined_lists[]; valid_globs) then $defined_lists else error("definedBy must be an array of globs") end) as $defined_lists
| (($risk["2"] // []) | map(rule(2; "riskPaths:2"; .))) as $risk_two
| (($risk["1"] // []) | map(rule(1; "riskPaths:1"; .))) as $risk_one
| ($defined_lists | add // [] | map(rule(2; "tier2:definedBy"; .))) as $defined
| ($copy | map(rule(0; "tier0:copyPaths"; .))) as $copies
| ($risk_two + $risk_one + $defined + $copies) as $all
| if ($all | length) > 1000 then error("too many configured globs") else $all[] end
JQ
  jq -r -f "$config_program" "$gates_file" >"$config_rules" 2>"$work_directory/config-error.txt" ||
    fail_closed "invalid .agents/gates.json at base: $(head -n 1 "$work_directory/config-error.txt" | cut -c 1-200)"
fi

# ---------------------------------------------------------------- hook command targets (base only)
if run_git cat-file -e "$base_sha:.claude/settings.json" 2>/dev/null; then
  settings_file="$work_directory/settings.json"
  run_git show "$base_sha:.claude/settings.json" 2>/dev/null | head -c $((gates_size_limit + 1)) >"$settings_file"
  read_status=("${PIPESTATUS[@]}")
  measure_size "$settings_file" ".claude/settings.json at base"
  [ "${read_status[1]}" -eq 0 ] || fail_closed "cannot read .claude/settings.json at base"
  [ "${read_status[0]}" -eq 0 ] || [ "$measured_size" -gt "$gates_size_limit" ] || fail_closed "cannot read .claude/settings.json at base"
  [ "$measured_size" -le "$gates_size_limit" ] || fail_closed ".claude/settings.json at base is too large"
  [ "$measured_size" -gt 0 ] || fail_closed ".claude/settings.json at base is empty"
  require_one_json_object "$settings_file" ".claude/settings.json at base"
  hook_program="$work_directory/hooks.jq"
  cat >"$hook_program" <<'JQ' || fail_closed "cannot write the hook program"
def project_relative: sub("^(\\$CLAUDE_PROJECT_DIR|\\$\\{CLAUDE_PROJECT_DIR\\})/"; "") | sub("^(\\./)+"; "");
(if type == "object" then . else error("settings must be a JSON object") end)
| (if has("hooks") then .hooks else {} end) as $hooks
| (if ($hooks | type) == "object" then $hooks else error("hooks must be an object") end)
| [$hooks | .. | objects | select(has("command")) | .command
   | if type == "string" then . else error("a hook command must be a string") end
   | gsub("[\"']"; "") | gsub("[`;&|()<>\t]"; " ") | split(" ")[] | select(length > 0) | project_relative
   | select(test("^[A-Za-z0-9._@+][A-Za-z0-9._/@+-]*$") and test("[/.]") and . != "." and . != "..")]
| unique
| if length > 1000 then error("too many hook command paths") else .[] end
| "2\ttier2:hook-target\tci\t\(.)"
JQ
  jq -r -f "$hook_program" "$settings_file" >>"$config_rules" 2>"$work_directory/hooks-error.txt" ||
    fail_closed "invalid .claude/settings.json at base: $(head -n 1 "$work_directory/hooks-error.txt" | cut -c 1-200)"
fi

# ---------------------------------------------------------------- built-in rules
default_rules="$work_directory/default-rules.tsv"
add_rules() { # tier reason kind glob...
  local tier="$1" reason="$2" kind="$3" glob
  shift 3
  for glob in "$@"; do printf '%s\t%s\t%s\t%s\n' "$tier" "$reason" "$kind" "$glob"; done
}
{
  add_rules 2 tier2:auth tokens '-'
  add_rules 2 tier2:migration segs '-'
  # Every built-in rule is "ci": the glob and the path are both folded to lower case.
  add_rules 2 tier2:sql ci '**/*.sql'
  add_rules 2 tier2:ci ci '.github/workflows/**' '.gitlab-ci.yml' '.gitlab/**' '.circleci/**' '**/azure-pipelines.yml' '**/Jenkinsfile' '.buildkite/**' '**/bitbucket-pipelines.yml'
  add_rules 2 tier2:iac ci '**/*.tf' '**/*.tfvars' '**/*.hcl' '**/Pulumi*.yaml' '**/cdk.json' '**/k8s/**' '**/kubernetes/**' '**/helm/**' '**/Chart.yaml' '**/charts/**' '**/Dockerfile*' '**/docker-compose*.y*ml' '**/compose*.y*ml' '**/vercel.json' '**/netlify.toml' '**/fly.toml' '**/serverless.y*ml' '**/app.yaml' '**/Procfile' '**/infra/**' '**/terraform/**' '**/wrangler.toml' '**/render.yaml'
  add_rules 2 tier2:iac ci '**/*.tf.json'
  add_rules 2 tier2:iac ci '**/*.tfvars.json'
  add_rules 2 tier2:iac ci '**/Containerfile*'
  add_rules 2 tier2:iac ci '**/*.bicep'
  add_rules 2 tier2:iac ci '**/kustomization.yaml'
  add_rules 2 tier2:iac ci '**/kustomization.yml'
  add_rules 2 tier2:iac ci 'template.yaml'
  add_rules 2 tier2:iac ci 'template.yml'
  add_rules 2 tier2:secrets ci '**/.env*' '**/*.env' '**/secrets/**' '**/*.pem' '**/*.key' '**/*.p12' '**/*.pfx'
  add_rules 2 tier2:lockfile ci '**/package-lock.json' '**/npm-shrinkwrap.json' '**/yarn.lock' '**/pnpm-lock.yaml' '**/bun.lockb' '**/bun.lock' '**/Pipfile.lock' '**/poetry.lock' '**/uv.lock' '**/Gemfile.lock' '**/go.sum' '**/Cargo.lock' '**/composer.lock' '**/gradle.lockfile' '**/packages.lock.json' '**/Package.resolved' '**/mix.lock'
  add_rules 2 tier2:lockfile ci '**/flake.lock'
  add_rules 2 tier2:lockfile ci '**/Podfile.lock'
  add_rules 2 tier2:lockfile ci '**/pubspec.lock'
  add_rules 2 tier2:dependency ci '**/package.json' '**/pnpm-workspace.yaml' '**/.npmrc' '**/.yarnrc' '**/.yarnrc.yml' '**/requirements*.txt' '**/Pipfile' '**/pyproject.toml' '**/setup.py' '**/setup.cfg' '**/Gemfile' '**/go.mod' '**/Cargo.toml' '**/composer.json' '**/pom.xml' '**/build.gradle*' '**/settings.gradle*' '**/*.csproj' '**/Package.swift' '**/mix.exs'
  add_rules 2 tier2:dependency ci '**/pubspec.yaml'
  add_rules 2 tier2:dependency ci '**/.pnpmfile.cjs'
  add_rules 2 tier2:dependency ci '**/.yarn/releases/**'
  add_rules 2 tier2:dependency ci '**/gradle/wrapper/**'
  add_rules 2 tier2:dependency ci '**/.mvn/wrapper/**'
  add_rules 2 tier2:dependency ci '**/gradle/libs.versions.toml'
  add_rules 2 tier2:dependency ci '**/Directory.Packages.props'
  add_rules 2 tier2:dependency ci '**/*.gemspec'
  add_rules 2 tier2:dependency ci '**/.gitmodules'
  add_rules 2 tier2:migration ci '**/alembic/versions/**'
  add_rules 2 tier2:migration ci '**/*.prisma'
  add_rules 2 tier2:gates ci '.agents/gates.json'
  add_rules 2 tier2:plugin-config ci '.claude/**' '**/.claude/**' '**/.claude-plugin/**' 'hooks/**' '**/hooks/**' '**/.mcp.json'
  add_rules 2 instruction:claude-config ci '.claude/**' '**/.claude-plugin/**' '**/hooks/**'
  add_rules 2 instruction:agent-definition ci '**/agents/**/*.md' '**/agents/**/*.markdown'
  add_rules 2 instruction:workflow ci '.github/workflows/**'
  add_rules 2 instruction:codeowners ci '.github/CODEOWNERS'
  add_rules 1 instruction:agents-md ci '**/AGENTS.md'
  add_rules 1 instruction:claude-md ci '**/CLAUDE*.md'
  add_rules 1 instruction:skill ci '**/SKILL.md'
  add_rules 1 instruction:skill-or-command ci '**/skills/**/*.md' '**/skills/**/*.markdown' '**/commands/**/*.md' '**/commands/**/*.markdown'
  add_rules 1 instruction:github ci '.github/**'
  add_rules 1 tier1:agents ci '.agents/**'
  add_rules 0 tier0:markdown ci '**/*.md' '**/*.markdown'
  # Under docs/, tier 0 is limited to recognised documentation and asset file types; any other
  # file there (docs/conf.py, docs/.vitepress/config.ts) falls to the tier 1 default.
  # The directory must be exactly "docs/" (tier 0 never folds case); the extension is folded.
  add_rules 0 tier0:docs docs 'docs/**/*.md' 'docs/**/*.mdx' 'docs/**/*.markdown' 'docs/**/*.rst' 'docs/**/*.adoc' 'docs/**/*.txt' 'docs/**/*.png' 'docs/**/*.jpg' 'docs/**/*.jpeg' 'docs/**/*.gif' 'docs/**/*.svg' 'docs/**/*.webp' 'docs/**/*.ico' 'docs/**/*.pdf' 'docs/**/*.drawio' 'docs/**/*.mmd' 'docs/**/*.puml'
} >"$default_rules" || fail_closed "cannot write the built-in rules"
cat "$default_rules" "$config_rules" >"$work_directory/rules.tsv" || fail_closed "cannot assemble the classification rules"

# ---------------------------------------------------------------- changed paths (raw, NUL separated)
raw_file="$work_directory/raw.bin"
run_git diff --raw -z "${diff_options[@]}" "$base_sha" "$head_sha" -- 2>"$work_directory/git-error.txt" | head -c $((raw_output_limit + 1)) >"$raw_file"
raw_read_status=("${PIPESTATUS[@]}")
raw_git_status="${raw_read_status[0]}"
# A failed head leaves an empty or short file, which would read as fewer (or no) changes.
[ "${raw_read_status[1]}" -eq 0 ] || fail_closed "cannot read the git diff output"
measure_size "$raw_file" "the git diff output"
raw_size="$measured_size"
path_cap_exceeded=0
byte_cap_exceeded=0
if [ "$raw_size" -gt "$raw_output_limit" ]; then
  path_cap_exceeded=1
elif [ "$raw_git_status" -ne 0 ]; then
  fail_closed "git diff failed: $(head -n 1 "$work_directory/git-error.txt" | cut -c 1-200)"
fi

encode_stream() { LC_ALL=C tr '\000\n\t' '\001\002\003'; }
# git's -z output ends every record with NUL; output that does not end with one was cut short.
ends_with_nul() { [ "$(tail -c 1 "$1" | od -An -tx1 | tr -d ' \n')" = 00 ]; }
# The awk scanners report through their exit status, never through marker lines in their output:
# 0 complete, 10 a cap was reached, 11 malformed input. Any other status (awk's own errors, a
# killed process) is a scanner failure, and every status is checked: nothing is inferred from
# what the output does or does not contain.
scanner_cap_status=10
scanner_malformed_status=11

entries_file="$work_directory/entries.tsv"
: >"$entries_file"
if [ "$path_cap_exceeded" -eq 0 ] && [ "$raw_size" -gt 0 ]; then
  LC_ALL=C tr -dc '\001\002\003' <"$raw_file" >"$work_directory/reserved.bin" ||
    fail_closed "cannot check the changed paths for reserved control bytes"
  measure_size "$work_directory/reserved.bin" "the reserved control bytes"
  [ "$measured_size" -eq 0 ] || fail_closed "a changed path contains a reserved control byte"
  ends_with_nul "$raw_file" || fail_closed "unexpected git diff output"
  raw_program="$work_directory/raw.awk"
  cat >"$raw_program" <<'AWK_RAW' || fail_closed "cannot write the changed path scanner"
function flags_for(mode) {
  if (mode == "120000") return "symlink"
  if (mode == "160000") return "submodule"
  return ""
}
function note_entry() {
  entry_count++
  if (entry_count > max_paths) { capped = 1; exit }
}
BEGIN { RS = "\001"; state = 0; entry_count = 0; capped = 0 }
{
  if (state == 0) {
    if ($0 == "") next
    field_count = split($0, meta, " ")
    if (field_count != 5 || substr(meta[1], 1, 1) != ":") { malformed = 1; exit }
    old_mode = substr(meta[1], 2); new_mode = meta[2]; status = substr(meta[5], 1, 1)
    expected = (status == "R" || status == "C") ? 2 : 1
    received = 0; state = 1
    next
  }
  received++
  paths[received] = $0
  if (received < expected) next
  state = 0
  old_flags = flags_for(old_mode); new_flags = flags_for(new_mode)
  if (status !~ /^[ACDMRT]$/) { old_flags = old_flags " status"; new_flags = new_flags " status" }
  made_executable = (new_mode == "100755" && old_mode != "100755")
  if (expected == 2) {
    if (made_executable) new_flags = new_flags " executable"
    note_entry(); print status "\told\t" paths[1] "\t" old_flags
    note_entry(); print status "\tnew\t" paths[2] "\t" new_flags
  } else {
    note_entry()
    both_flags = old_flags
    if (new_flags != "" && index(both_flags, new_flags) == 0) both_flags = both_flags " " new_flags
    if (made_executable) both_flags = both_flags " executable"
    print status "\tboth\t" paths[1] "\t" both_flags
  }
}
END {
  if (capped) exit 10
  if (malformed || state != 0) exit 11
  exit 0
}
AWK_RAW
  encode_stream <"$raw_file" | LC_ALL=C awk -v max_paths="$max_paths" -f "$raw_program" >"$entries_file"
  raw_scan_status=("${PIPESTATUS[@]}")
  case "${raw_scan_status[1]}" in
    0)
      [ "${raw_scan_status[0]}" -eq 0 ] || fail_closed "cannot read the changed path list"
      # git listed something, so an empty result is malformed output, never an empty diff.
      [ -s "$entries_file" ] || fail_closed "unexpected git diff output"
      ;;
    "$scanner_cap_status")
      path_cap_exceeded=1
      : >"$entries_file"
      ;;
    "$scanner_malformed_status") fail_closed "unexpected git diff output" ;;
    *) fail_closed "cannot parse the changed path list" ;;
  esac
fi

binary_file="$work_directory/binary.txt"
sql_file="$work_directory/sql.txt"
: >"$binary_file"
: >"$sql_file"
tree_facts_file="$work_directory/tree-facts.tsv"
: >"$tree_facts_file"

if [ "$path_cap_exceeded" -eq 0 ] && [ -s "$entries_file" ]; then
  # ---------------------------------------------------------------- binary files (numstat "-  -")
  numstat_file="$work_directory/numstat.bin"
  run_git diff --numstat -z "${diff_options[@]}" "$base_sha" "$head_sha" -- 2>"$work_directory/git-error.txt" | head -c $((raw_output_limit + 1)) >"$numstat_file"
  numstat_read_status=("${PIPESTATUS[@]}")
  [ "${numstat_read_status[1]}" -eq 0 ] || fail_closed "cannot read the git diff --numstat output"
  measure_size "$numstat_file" "the git diff --numstat output"
  [ "$measured_size" -le "$raw_output_limit" ] && [ "${numstat_read_status[0]}" -eq 0 ] ||
    fail_closed "git diff --numstat failed: $(head -n 1 "$work_directory/git-error.txt" | cut -c 1-200)"
  ends_with_nul "$numstat_file" || fail_closed "unexpected git diff --numstat output"
  numstat_program="$work_directory/numstat.awk"
  cat >"$numstat_program" <<'AWK_NUMSTAT' || fail_closed "cannot write the numstat scanner"
BEGIN { RS = "\001"; pending = 0 }
{
  if (pending > 0) {
    if (binary) print $0
    pending--
    next
  }
  if ($0 == "") next
  if (match($0, /^[-0-9]+\003[-0-9]+\003/) == 0) { malformed = 1; exit }
  counts = substr($0, 1, RLENGTH); rest = substr($0, RLENGTH + 1)
  binary = (counts == "-\003-\003")
  if (rest == "") pending = 2
  else if (binary) print rest
}
END {
  if (malformed || pending > 0) exit 11
  exit 0
}
AWK_NUMSTAT
  encode_stream <"$numstat_file" | LC_ALL=C awk -f "$numstat_program" >"$binary_file"
  numstat_scan_status=("${PIPESTATUS[@]}")
  case "${numstat_scan_status[1]}:${numstat_scan_status[0]}" in
    0:0) ;;
    "$scanner_malformed_status":*) fail_closed "unexpected git diff --numstat output" ;;
    *) fail_closed "cannot parse numstat output" ;;
  esac

  # ---------------------------------------------------------------- destructive SQL in added lines
  sql_program="$work_directory/sql.awk"
  cat >"$sql_program" <<'AWK_SQL' || fail_closed "cannot write the destructive SQL scanner"
BEGIN {
  bytes_read = 0; in_header = 1; current_path = ""
  word_end = "([^a-z0-9_]|$)"
  word_start = "(^|[^a-z0-9_])"
  identifier = "[a-z0-9_.`\"]+"
  drop_pattern = word_start "drop[ \t]+(table|database|schema|view|materialized[ \t]+view|index|column|user|role|sequence|function|procedure|trigger|type|extension|(temporary|temp)[ \t]+table)" word_end
  alter_pattern = word_start "alter[ \t]+table[^;]*[ \t]drop" word_end
  delete_pattern = word_start "delete[ \t]+from[ \t]+" identifier
  truncate_table_pattern = word_start "truncate[ \t]+table" word_end
  truncate_bare_pattern = word_start "truncate[ \t]+(only[ \t]+)?" identifier "([ \t]*([;'\")),]|$)|[ \t]+(cascade|restrict|restart|continue)" word_end ")"
}
{
  bytes_read += length($0) + 1
  if (bytes_read > max_bytes) { capped = 1; exit }
  if (substr($0, 1, 11) == "diff --git ") { in_header = 1; current_path = ""; next }
  if (in_header) {
    if (substr($0, 1, 4) == "+++ ") {
      name = substr($0, 5)
      if (name == "/dev/null" || substr(name, 1, 1) == "\"") current_path = ""
      else { sub(/\t$/, "", name); current_path = substr(name, 3) }
    } else if (substr($0, 1, 2) == "@@") in_header = 0
    next
  }
  if (substr($0, 1, 1) != "+") next
  text = tolower(substr($0, 2))
  if (text ~ drop_pattern || text ~ alter_pattern || text ~ delete_pattern || text ~ truncate_table_pattern || text ~ truncate_bare_pattern) {
    if (!(current_path in reported)) { reported[current_path] = 1; print "SQL\t" current_path }
  }
}
END {
  if (capped) exit 10
  exit 0
}
AWK_SQL
  run_git diff -U0 --text "${patch_options[@]}" "$base_sha" "$head_sha" -- 2>"$work_directory/git-error.txt" |
    LC_ALL=C awk -v max_bytes="$max_bytes" -f "$sql_program" >"$sql_file"
  patch_status=("${PIPESTATUS[@]}")
  if [ "${patch_status[1]}" = "$scanner_cap_status" ]; then
    byte_cap_exceeded=1 # git may have been stopped by the closed pipe
  elif [ "${patch_status[1]}" -ne 0 ]; then
    fail_closed "cannot scan the patch for destructive SQL"
  elif [ "${patch_status[0]}" -ne 0 ]; then
    fail_closed "git diff -U0 failed: $(head -n 1 "$work_directory/git-error.txt" | cut -c 1-200)"
  fi

  # ---------------------------------------------------------------- tree facts: plugin roots, case collisions
  # One streaming pass per tree. ROOT lines name directories holding .claude-plugin/plugin.json
  # (base and head). COLLIDE lines name changed head-side paths that, folded to lower case,
  # match another head path or directory prefix spelled differently. Memory is bounded by the
  # changed paths, not by the tree.
  tree_program="$work_directory/tree.awk"
  cat >"$tree_program" <<'AWK_TREE' || fail_closed "cannot write the tree scanner"
function note_wanted(path,    count, parts, position, prefix) {
  count = split(path, parts, "/")
  prefix = ""
  for (position = 1; position <= count; position++) {
    prefix = (position == 1) ? parts[1] : prefix "/" parts[position]
    wanted[tolower(prefix)] = 1
  }
}
function note_spelling(path,    count, parts, position, prefix, key) {
  count = split(path, parts, "/")
  prefix = ""
  for (position = 1; position <= count; position++) {
    prefix = (position == 1) ? parts[1] : prefix "/" parts[position]
    key = tolower(prefix)
    if (!(key in wanted)) continue
    if (!(key in spelling)) spelling[key] = prefix
    else if (spelling[key] != prefix) collided[key] = 1
  }
}
function has_collision(path,    count, parts, position, prefix) {
  count = split(path, parts, "/")
  prefix = ""
  for (position = 1; position <= count; position++) {
    prefix = (position == 1) ? parts[1] : prefix "/" parts[position]
    if (tolower(prefix) in collided) return 1
  }
  return 0
}
BEGIN { FS = "\t"; suffix = "/.claude-plugin/plugin.json"; suffix_length = length(suffix) }
FILENAME == entries_path {
  if (collisions == 1 && $2 != "old") { changed_count++; changed[changed_count] = $3; note_wanted($3) }
  next
}
{
  lowercase_path = tolower($0)
  if (lowercase_path == ".claude-plugin/plugin.json") roots["."] = 1
  else if (length(lowercase_path) > suffix_length && substr(lowercase_path, length(lowercase_path) - suffix_length + 1) == suffix) {
    roots[substr(lowercase_path, 1, length(lowercase_path) - suffix_length)] = 1
  }
  if (collisions == 1) note_spelling($0)
}
END {
  for (root in roots) print "ROOT\t" root
  for (position = 1; position <= changed_count; position++) if (has_collision(changed[position])) print "COLLIDE\t" changed[position]
}
AWK_TREE
  for tree_scan in "$base_sha:0" "$head_sha:1"; do
    run_git ls-tree -r -z --full-tree --name-only "${tree_scan%%:*}" 2>"$work_directory/git-error.txt" |
      LC_ALL=C tr '\000\n\t' '\n\002\003' |
      LC_ALL=C awk -v collisions="${tree_scan##*:}" -v entries_path="$entries_file" -f "$tree_program" "$entries_file" - >>"$tree_facts_file"
    tree_status=("${PIPESTATUS[@]}")
    if [ "${tree_status[0]}" -ne 0 ] || [ "${tree_status[1]}" -ne 0 ] || [ "${tree_status[2]}" -ne 0 ]; then
      fail_closed "cannot list the repository tree: $(head -n 1 "$work_directory/git-error.txt" | cut -c 1-200)"
    fi
  done
fi

# ---------------------------------------------------------------- classification
classified_file="$work_directory/classified.tsv"
: >"$classified_file"
if [ -s "$entries_file" ]; then
  classify_program="$work_directory/classify.awk"
  cat >"$classify_program" <<'AWK_CLASSIFY' || fail_closed "cannot write the classification program"
function is_upper(character) { return index("ABCDEFGHIJKLMNOPQRSTUVWXYZ", character) > 0 }
function is_lower(character) { return index("abcdefghijklmnopqrstuvwxyz", character) > 0 }
function is_digit(character) { return index("0123456789", character) > 0 }

function token_is_auth(token) {
  if (token in auth_words) return 1
  if (substr(token, 1, 4) == "auth" && token !~ /^author(s|ing|ed)?$/) return 1
  return 0
}

# Splits on non-alphanumerics and camelCase boundaries; true when any word part is auth-related.
function has_auth_word(original_path,    position, character, previous, next_character, token, length_of_path) {
  token = ""; previous = ""
  length_of_path = length(original_path)
  for (position = 1; position <= length_of_path; position++) {
    character = substr(original_path, position, 1)
    next_character = substr(original_path, position + 1, 1)
    if (!is_upper(character) && !is_lower(character) && !is_digit(character)) {
      if (token != "" && token_is_auth(tolower(token))) return 1
      token = ""; previous = ""; continue
    }
    if (token != "" && is_upper(character) &&
        (is_lower(previous) || is_digit(previous) || (is_upper(previous) && is_lower(next_character)))) {
      if (token_is_auth(tolower(token))) return 1
      token = ""
    }
    token = token character
    previous = character
  }
  return (token != "" && token_is_auth(tolower(token)))
}

function has_migration_segment(lowercase_path,    parts, count, index_of_part, stem, dot_position) {
  count = split(lowercase_path, parts, "/")
  for (index_of_part = 1; index_of_part <= count; index_of_part++) {
    stem = parts[index_of_part]
    dot_position = index(stem, ".")
    if (dot_position > 1) stem = substr(stem, 1, dot_position - 1)
    if (parts[index_of_part] in migration_words || stem in migration_words) return 1
  }
  return 0
}

# Inside a plugin root: every non-Markdown file (skills/ and commands/ included), everything
# in output-styles/, and .mcp.json is code that runs or configures the plugin.
function is_plugin_code_path(relative) {
  if (relative ~ /^output-styles\//) return 1
  if (relative == ".mcp.json") return 1
  if (relative ~ /\.(md|markdown)$/) return 0
  return 1
}
function has_plugin_code(lowercase_path,    count, parts, position, prefix) {
  if (("." in plugin_roots) && is_plugin_code_path(lowercase_path)) return 1
  count = split(lowercase_path, parts, "/")
  prefix = ""
  for (position = 1; position < count; position++) {
    prefix = (position == 1) ? parts[1] : prefix "/" parts[position]
    if ((prefix in plugin_roots) && is_plugin_code_path(substr(lowercase_path, length(prefix) + 2))) return 1
  }
  return 0
}

function add_reason(index_of_entry, reason, bucket) {
  if ((index_of_entry SUBSEP reason) in seen) return
  seen[index_of_entry SUBSEP reason] = 1
  if (bucket == "zero") zero_reasons[index_of_entry] = zero_reasons[index_of_entry] "," reason
  else high_reasons[index_of_entry] = high_reasons[index_of_entry] "," reason
}

BEGIN {
  FS = "\t"
  split("auth authn authz oauth oidc saml sso session sessions permission permissions rbac acl acls iam login password passwords token tokens credential credentials jwt csrf mfa otp totp passwd logins role roles policy policies", word_list, " ")
  for (word_index in word_list) auth_words[word_list[word_index]] = 1
  migration_words["migrations"] = 1; migration_words["migrate"] = 1; migration_words["migration"] = 1
  bookkeeping_state = ENVIRON["BOOKKEEPING_STATE"]; bookkeeping_log = ENVIRON["BOOKKEEPING_LOG"]
}

FILENAME == ENVIRON["RULES_FILE"] {
  rule_count++
  rule_tier[rule_count] = $1 + 0; rule_reason[rule_count] = $2; rule_kind[rule_count] = $3
  if ($3 == "ci" || $3 == "docs") rule_regex[rule_count] = glob_to_regex(tolower($4))
  else if ($3 == "glob") rule_regex[rule_count] = glob_to_regex($4)
  next
}
FILENAME == ENVIRON["FACTS_FILE"] {
  if ($1 == "ROOT") plugin_roots[$2] = 1
  else if ($1 == "COLLIDE") collided_paths[$2] = 1
  next
}
FILENAME == ENVIRON["BINARY_FILE"] { binary_paths[$0] = 1; next }
FILENAME == ENVIRON["SQL_FILE"] {
  if ($1 == "SQL") { if ($2 == "") sql_everywhere = 1; else sql_paths[$2] = 1 }
  next
}
FILENAME == ENVIRON["ENTRIES_FILE"] {
  entry_count++
  entry_status[entry_count] = $1; entry_side[entry_count] = $2; entry_path[entry_count] = $3; entry_flags[entry_count] = $4
  next
}

END {
  for (entry = 1; entry <= entry_count; entry++) {
    path = entry_path[entry]
    lowercase_path[entry] = tolower(path)
    if (path in binary_paths) entry_flags[entry] = entry_flags[entry] " binary"
    if (entry_flags[entry] ~ /^ *$/ && bookkeeping_state != "" && (path == bookkeeping_state || path == bookkeeping_log)) {
      is_bookkeeping[entry] = 1
      continue
    }
    has_auth[entry] = has_auth_word(path)
    has_migration[entry] = has_migration_segment(lowercase_path[entry])
  }
  for (rule = 1; rule <= rule_count; rule++) {
    kind = rule_kind[rule]; regex = rule_regex[rule]; rule_level = rule_tier[rule]
    for (entry = 1; entry <= entry_count; entry++) {
      if (is_bookkeeping[entry]) continue
      if (kind == "glob") matched = (entry_path[entry] ~ regex)
      else if (kind == "ci") matched = (lowercase_path[entry] ~ regex)
      else if (kind == "docs") matched = (substr(entry_path[entry], 1, 5) == "docs/" && lowercase_path[entry] ~ regex)
      else if (kind == "tokens") matched = has_auth[entry]
      else matched = has_migration[entry]
      if (!matched) continue
      if (rule_level == 0) { has_zero_rule[entry] = 1; add_reason(entry, rule_reason[rule], "zero") }
      else {
        if (rule_level > highest[entry]) highest[entry] = rule_level
        add_reason(entry, rule_reason[rule], "high")
      }
    }
  }
  for (entry = 1; entry <= entry_count; entry++) {
    if (is_bookkeeping[entry]) { print entry_status[entry] "\t" entry_side[entry] "\t" entry_path[entry] "\tnull\tactive-item bookkeeping"; continue }
    if (entry_side[entry] != "old" && (sql_everywhere || (entry_path[entry] in sql_paths))) {
      highest[entry] = 2; add_reason(entry, "tier2:destructive-sql", "high")
    }
    if (has_plugin_code(lowercase_path[entry])) {
      highest[entry] = 2; add_reason(entry, "tier2:plugin-code", "high")
    }
    if (entry_side[entry] != "old" && (entry_path[entry] in collided_paths)) {
      highest[entry] = 2; add_reason(entry, "tier2:case-collision", "high")
    }
    flag_count = split(entry_flags[entry], flag_list, " ")
    for (flag_index = 1; flag_index <= flag_count; flag_index++) {
      if (highest[entry] < 1) highest[entry] = 1
      if (flag_list[flag_index] == "executable") add_reason(entry, "tier1:executable", "high")
      else add_reason(entry, "unclassified:" flag_list[flag_index], "high")
    }
    if (highest[entry] > 0) { tier = highest[entry]; reasons = substr(high_reasons[entry], 2) }
    else if (has_zero_rule[entry]) { tier = 0; reasons = substr(zero_reasons[entry], 2) }
    else { tier = 1; reasons = "tier1:default" }
    print entry_status[entry] "\t" entry_side[entry] "\t" entry_path[entry] "\t" tier "\t" reasons
  }
}
AWK_CLASSIFY
  BOOKKEEPING_STATE="" BOOKKEEPING_LOG=""
  if [ -n "$active_item" ]; then
    BOOKKEEPING_STATE=".agents/specs/active/$active_item.state.json"
    BOOKKEEPING_LOG=".agents/specs/active/$active_item.log.md"
  fi
  RULES_FILE="$work_directory/rules.tsv" BINARY_FILE="$binary_file" SQL_FILE="$sql_file" ENTRIES_FILE="$entries_file" \
    FACTS_FILE="$tree_facts_file" \
    BOOKKEEPING_STATE="$BOOKKEEPING_STATE" BOOKKEEPING_LOG="$BOOKKEEPING_LOG" LC_ALL=C \
    awk -f "$work_directory/library.awk" -f "$classify_program" \
    "$work_directory/rules.tsv" "$tree_facts_file" "$binary_file" "$sql_file" "$entries_file" >"$classified_file" ||
    fail_closed "classification failed"
fi

# ---------------------------------------------------------------- JSON
cap_exceeded=false
{ [ "$path_cap_exceeded" -eq 1 ] || [ "$byte_cap_exceeded" -eq 1 ]; } && cap_exceeded=true
jq -R -n --arg base "$base_sha" --arg head "$head_sha" --argjson cap "$cap_exceeded" '
  [inputs | split("\t") | {
      path: (.[2] | gsub("\u0003"; "\t") | gsub("\u0002"; "\n")),
      side: .[1],
      status: .[0],
      tier: (if .[3] == "null" then null else (.[3] | tonumber) end),
      reasons: (.[4] | split(","))
    }] as $classified
  | ($classified + (if $cap then [{path: "(cap exceeded)", side: "both", status: "!", tier: 2, reasons: ["cap:exceeded"]}] else [] end)) as $paths
  | {
      floorTier: ([$paths[].tier | select(. != null)] | max // 0),
      base: $base,
      head: $head,
      paths: $paths,
      unclassified: ([$paths[] | select(.reasons | any(startswith("unclassified:"))) | .path] | unique),
      error: null
    }' "$classified_file" || fail_closed "cannot build the JSON result"
