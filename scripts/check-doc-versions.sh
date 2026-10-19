#!/bin/bash
# Documentation version consistency: every pinned version reference in README.md and docs/**
# (`ai-engineering-system@vX.Y.Z` and `"ref": "vX.Y.Z"`) must name a version that has an
# entry in versions/CHANGELOG.md. Usage: check-doc-versions.sh [repository-root]
# Prints each offending file:line and the unknown version; exits 1 if any, 0 otherwise.
set -u
repository_root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
changelog="$repository_root/versions/CHANGELOG.md"
[ -f "$changelog" ] || { echo "missing changelog: $changelog"; exit 1; }

known_versions="$(awk '/^## / { print $2 }' "$changelog")"

reference_pattern='(ai-engineering-system@|"ref"[[:space:]]*:[[:space:]]*")v[0-9]+\.[0-9]+\.[0-9]+'
search_targets=()
[ -f "$repository_root/README.md" ] && search_targets+=("$repository_root/README.md")
[ -d "$repository_root/docs" ] && search_targets+=("$repository_root/docs")

unknown_count=0
reference_count=0
if [ "${#search_targets[@]}" -gt 0 ]; then
  while IFS=: read -r file line_number match; do
    [ -n "$file" ] || continue
    reference_count=$((reference_count + 1))
    referenced_version="${match##*v}"
    if ! grep -qxF "$referenced_version" <<<"$known_versions"; then
      echo "${file#"$repository_root"/}:$line_number: version $referenced_version has no entry in versions/CHANGELOG.md"
      unknown_count=$((unknown_count + 1))
    fi
  done < <(grep -rnoE "$reference_pattern" "${search_targets[@]}")
fi

if [ "$unknown_count" -gt 0 ]; then
  exit 1
fi
echo "$reference_count pinned version reference(s) all have changelog entries"
