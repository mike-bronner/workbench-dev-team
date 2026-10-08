#!/bin/bash
# The workbench-core files copied into tests/core/ must match their source.
# Run directly: bash tests/test-core-copies.sh [--update]
#
# The guard tests read core's shell reader (hooks/mods/shell.ts) and its
# hostile-input corpus (tests/commit-corpus.ts, tests/shell-cases.ts) from
# copies, because a test cannot import another repository. Core keeps adding
# lines to the corpus as its guard ports land and as reviewers find cases, so
# a copy goes stale silently. tests/core/SOURCE records the core commit the
# copies came from and the SHA-256 of each one.
#
# Two checks:
#   1. Each copy is unedited: its hash is the one SOURCE records.
#   2. Core has not moved on: each file on core's main branch has that hash.
#      Core is the checkout named by WORKBENCH_CORE_DIR, or ../workbench-core
#      beside this repository. With no checkout reachable, the check is skipped
#      and says why.
#
# --update copies each file from core's main branch and rewrites SOURCE. It
# reads core and never writes to it.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
COPIES="$HERE/core"
SOURCE="$COPIES/SOURCE"
CORE="${WORKBENCH_CORE_DIR:-$ROOT/../workbench-core}"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

sha() { shasum -a 256 | cut -d' ' -f1; }
has_core() { git -C "$CORE" rev-parse --verify --quiet main >/dev/null 2>&1; }

if [ "${1:-}" = --update ]; then
  has_core || { echo "no workbench-core checkout at $CORE (set WORKBENCH_CORE_DIR)"; exit 1; }
  paths=$(sed -n 's/^[0-9a-f]\{64\} //p' "$SOURCE")
  commit=$(git -C "$CORE" rev-parse --short main)
  {
    sed -n '/^#/p' "$SOURCE"
    echo "commit $commit"
    for path in $paths; do
      mkdir -p "$(dirname "$COPIES/$path")"
      git -C "$CORE" show "main:$path" > "$COPIES/$path"
      echo "$(sha < "$COPIES/$path") $path"
    done
  } > "$SOURCE.new"
  mv "$SOURCE.new" "$SOURCE"
  echo "tests/core/ now holds workbench-core $commit"
  exit 0
fi

echo "── the core copies in tests/core/ ──────────────────────────────────────"
commit=$(sed -n 's/^commit //p' "$SOURCE")
[ -n "$commit" ] && ok "SOURCE names the core commit the copies came from: $commit" \
  || bad "SOURCE names no core commit"
entries=0
while read -r hash path; do
  entries=$((entries + 1))
  copy="$COPIES/$path"
  if [ ! -f "$copy" ]; then
    bad "$path has no copy in tests/core/"
  elif [ "$(sha < "$copy")" = "$hash" ]; then
    ok "the copy of $path is unedited"
  else
    bad "the copy of $path was edited; copies are never edited, re-export them with: bash tests/test-core-copies.sh --update"
  fi
done < <(grep -E '^[0-9a-f]{64} ' "$SOURCE")
[ "$entries" -gt 0 ] && ok "$entries copies listed" || bad "SOURCE lists no copies"

if has_core; then
  main=$(git -C "$CORE" rev-parse --short main)
  while read -r hash path; do
    if ! git -C "$CORE" cat-file -e "main:$path" 2>/dev/null; then
      bad "$path is gone from core main ($main); re-export the copies with: bash tests/test-core-copies.sh --update"
    elif [ "$(git -C "$CORE" show "main:$path" | sha)" = "$hash" ]; then
      ok "$path matches core main ($main)"
    else
      bad "$path changed on core main ($main) since $commit; re-export the copies with: bash tests/test-core-copies.sh --update"
    fi
  done < <(grep -E '^[0-9a-f]{64} ' "$SOURCE")
else
  echo "  ⏭️  skipped the comparison with core: no workbench-core checkout at $CORE (set WORKBENCH_CORE_DIR to one)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
