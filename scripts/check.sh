#!/bin/bash
# Quality gate for this repository: plugin/marketplace validation, script syntax,
# hook tests, context budgets and a routing summary. Exits non-zero on any failure.
set -u
repository_directory="$(cd "$(dirname "$0")/.." && pwd)"
plugin_directory="$repository_directory/plugins/ai-engineering"
cd "$repository_directory" || exit 1

# Context budgets in bytes (roughly 4 bytes per token).
core_standards_budget=4000
always_loaded_budget=7000

failures=0
step() { printf '\n== %s\n' "$1"; }
check_failed() { echo "FAILED: $1"; failures=$((failures + 1)); }

step "Plugin and marketplace validation"
claude plugin validate --strict "$plugin_directory" || check_failed "plugin validation"
claude plugin validate --strict "$repository_directory" || check_failed "marketplace validation"

step "Script syntax"
for script in "$plugin_directory"/scripts/*.sh tests/run.sh scripts/check.sh; do
  bash -n "$script" || check_failed "syntax: $script"
done
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "$plugin_directory"/scripts/*.sh tests/run.sh scripts/check.sh || check_failed "shellcheck"
else
  echo "shellcheck not installed; skipped"
fi

step "Hook tests"
tests/run.sh || check_failed "hook tests"

step "Template names"
# A file named AGENTS.md or CLAUDE.md inside the plugin would load as live instructions
# when someone reads files in that directory, so templates must use other names.
unexpected_instruction_files="$(find "$plugin_directory" \( -name AGENTS.md -o -name CLAUDE.md \) -print)"
if [ -n "$unexpected_instruction_files" ]; then
  check_failed "instruction-named files inside plugin: $unexpected_instruction_files"
else
  echo "ok"
fi

step "Version consistency"
plugin_version="$(jq -r '.version' "$plugin_directory/.claude-plugin/plugin.json")"
changelog_version="$(awk '/^## / { print $2; exit }' versions/CHANGELOG.md)"
if [ "$plugin_version" = "$changelog_version" ]; then
  echo "plugin.json $plugin_version matches the latest changelog entry"
else
  check_failed "plugin.json version $plugin_version does not match latest changelog entry $changelog_version"
fi

step "Context budget"
frontmatter_value() { awk -v key="$2" 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { exit } inside && index($0, key ": ") == 1 { print substr($0, length(key) + 3) }' "$1"; }
injected_bytes=$(CLAUDE_PLUGIN_ROOT="$plugin_directory" "$plugin_directory/scripts/inject-standards.sh" | wc -c | tr -d ' ')
standards_bytes=$(awk 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { inside = 0; next } !inside' "$plugin_directory/skills/engineering-standards/SKILL.md" | wc -c | tr -d ' ')
agent_description_bytes=0
for agent_file in "$plugin_directory"/agents/*.md; do
  agent_description_bytes=$((agent_description_bytes + $(frontmatter_value "$agent_file" description | wc -c)))
done
skill_description_bytes=0
for skill_file in "$plugin_directory"/skills/*/SKILL.md; do
  [ "$(frontmatter_value "$skill_file" disable-model-invocation)" = "true" ] && continue
  skill_description_bytes=$((skill_description_bytes + $(frontmatter_value "$skill_file" description | wc -c)))
done
always_loaded_bytes=$((injected_bytes + agent_description_bytes + skill_description_bytes))
printf 'core standards body: %s bytes (budget %s)\n' "$standards_bytes" "$core_standards_budget"
printf 'session-start injection: %s bytes\n' "$injected_bytes"
printf 'agent descriptions: %s bytes\n' "$agent_description_bytes"
printf 'model-invocable skill descriptions: %s bytes\n' "$skill_description_bytes"
printf 'always loaded (main session): %s bytes, about %s tokens (budget %s bytes)\n' "$always_loaded_bytes" "$((always_loaded_bytes / 4))" "$always_loaded_budget"
[ "$standards_bytes" -le "$core_standards_budget" ] || check_failed "core standards exceed budget"
[ "$always_loaded_bytes" -le "$always_loaded_budget" ] || check_failed "always-loaded context exceeds budget"

step "Model routing (authoritative: agent frontmatter)"
for agent_file in "$plugin_directory"/agents/*.md; do
  printf '%-20s %s\n' "$(frontmatter_value "$agent_file" name)" "$(frontmatter_value "$agent_file" model)"
done

echo
if [ "$failures" -eq 0 ]; then
  echo "CHECK: PASSED"
  exit 0
fi
echo "CHECK: FAILED ($failures)"
exit 1
