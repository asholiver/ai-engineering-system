#!/bin/bash
# SessionStart hook: adds the authoritative engineering standards (the body of the
# engineering-standards skill, without frontmatter) to the main session's context.
set -u
plugin_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
standards_file="$plugin_root/skills/engineering-standards/SKILL.md"

if [ ! -f "$standards_file" ]; then
  echo "ai-engineering: engineering standards file not found at $standards_file" >&2
  exit 0
fi

plugin_version="$(jq -r '.version // "unknown"' "$plugin_root/.claude-plugin/plugin.json" 2>/dev/null)" || plugin_version=unknown
echo "ai-engineering $plugin_version, plugin root $plugin_root"
echo "ai-engineering plugin active. The following engineering standards apply to all work in this session."
echo "Project facts live in AGENTS.md and .agents/. Lifecycle skills: /ai-engineering:plan, :approve, :deliver, :review, :learn, :setup."
echo
awk 'BEGIN { in_frontmatter = 0; done = 0 }
     NR == 1 && $0 == "---" { in_frontmatter = 1; next }
     in_frontmatter && $0 == "---" { in_frontmatter = 0; next }
     !in_frontmatter { print }' "$standards_file"
