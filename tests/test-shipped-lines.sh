#!/bin/bash
# Every shell block the agents and their references ship passes the commit
# guard in the lanes that run it, and every shell block dev-team ships names
# each command plainly, as workbench-core requires in every lane. Run directly:
# bash tests/test-shipped-lines.sh
#
# A wrapper, so the suite's test-*.sh discovery runs tests/shipped-lines.mjs.
# Read its header for what it checks. It needs node 22.18 or later, for type
# stripping, and fails without it rather than report green on a test that
# never ran.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

if ! command -v node >/dev/null 2>&1; then
  echo "  ❌ node is not on PATH, so the shipped-lines check cannot run"
  exit 1
fi
if ! node -e 'const [a, b] = process.versions.node.split(".").map(Number); process.exit(a > 22 || (a === 22 && b >= 18) ? 0 : 1)'; then
  echo "  ❌ node $(node --version) cannot strip TypeScript types; the shipped-lines check needs 22.18 or later"
  exit 1
fi
exec node "$HERE/shipped-lines.mjs"
