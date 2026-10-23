#!/bin/bash

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
