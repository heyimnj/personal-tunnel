#!/usr/bin/env bash
# SHA256 of a framework directory: every file (with its path), in a fixed order.
# The same sum whatever the file times; any changed byte changes it.
# Usage: scripts/framework-hash.sh AppCore.xcframework
set -euo pipefail
cd "$1"
find . \( -type f -o -type l \) -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' path; do
  if [ -L "$path" ]; then
    printf '%s  link:%s\n' "$path" "$(readlink "$path")"
  else
    printf '%s  %s\n' "$path" "$(shasum -a 256 "$path" | cut -c1-64)"
  fi
done | shasum -a 256 | cut -c1-64
