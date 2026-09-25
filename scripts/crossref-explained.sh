#!/usr/bin/env bash
# Usage: scripts/crossref-explained.sh vault/concepts/<sub>/<name>.md
# Adds the explained-version cross-reference to an original note (idempotent)
# and upgrades links in earlier explained notes to point at the new explained note.
set -euo pipefail
src="$1"; name=$(basename "$src" .md); ex="${name}-explained"
# 1. frontmatter field after status:
grep -q '^explained:' "$src" || sed -i "0,/^status:.*/s//&\nexplained: \"[[${ex}]]\"/" "$src"
# 2. banner under first H1
grep -qF "Plain-language version: [[${ex}]]" "$src" || \
  sed -i "0,/^# .*/s//&\n\n> 📘 Plain-language version: [[${ex}]]/" "$src"
# 3. upgrade links in other explained notes (skip each note's own original back-links)
find vault/explained -name '*.md' ! -name "${ex}.md" -print0 | while IFS= read -r -d '' f; do
  sed -i -E "/^(original:|> Plain-language companion|- Technical version:)/! { s/\[\[${name}\]\]/[[${ex}|${name}]]/g; s/\[\[${name}\|/[[${ex}|/g; }" "$f"
done
