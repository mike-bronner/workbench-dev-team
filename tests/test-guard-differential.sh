#!/bin/bash
# The guard ports against the bash guards they replaced. Run directly:
# bash tests/test-guard-differential.sh
#
# A wrapper, so the suite's test-*.sh discovery runs tests/differential.mjs,
# which holds the commit guard and the review guard (hooks/mods/) to the bash
# guards frozen in tests/oracle/, line by line. Read its header for the method.
# It needs node 22.18 or later, for type stripping, and fails without it rather
# than report green on a test that never ran.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

if ! command -v node >/dev/null 2>&1; then
  echo "  ❌ node is not on PATH, so the guard differential cannot run"
  exit 1
fi
if ! node -e 'const [a, b] = process.versions.node.split(".").map(Number); process.exit(a > 22 || (a === 22 && b >= 18) ? 0 : 1)'; then
  echo "  ❌ node $(node --version) cannot strip TypeScript types; the guard differential needs 22.18 or later"
  exit 1
fi
exec node "$HERE/differential.mjs"
