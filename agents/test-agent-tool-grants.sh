#!/bin/bash
# Guards agent tool grants. Run directly: ./test-agent-tool-grants.sh
#
# A subagent's frontmatter `tools:` line is a STRICT allowlist — a tool the body
# instructs the agent to call but the allowlist omits is silently unavailable at
# runtime, so the instruction dies at the harness with nothing logged. v0.18.0
# shipped `create_issue` prose for Holmes and Watson without granting the tool;
# this catches that whole class. For every agents/*.md, each mcp__ tool cited in
# the body must appear in that file's frontmatter `tools:` list.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0

for file in "$DIR"/*.md; do
  agent="$(basename "$file" .md)"

  # Frontmatter = lines between the first two `---` fences; body = everything after.
  frontmatter="$(awk 'NR==1 && $0=="---"{f=1;next} f && $0=="---"{exit} f{print}' "$file")"
  body="$(awk 'b{print} $0=="---"{n++; if(n==2)b=1}' "$file")"

  # Granted: the mcp__ tools on the frontmatter `tools:` line, one per line.
  granted="$(printf '%s\n' "$frontmatter" | grep -E '^tools:' \
    | sed 's/^tools://' | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -E '^mcp__' || true)"

  # Referenced: mcp__ tool tokens the body cites (server may hold hyphens; tool is snake_case).
  referenced="$(printf '%s\n' "$body" \
    | grep -oE 'mcp__[A-Za-z0-9_-]+__[A-Za-z0-9_]+' | sort -u || true)"

  missing=""
  while IFS= read -r tool; do
    [ -z "$tool" ] && continue
    if ! printf '%s\n' "$granted" | grep -Fqx "$tool"; then
      missing="$missing $tool"
    fi
  done <<EOF
$referenced
EOF

  count="$(printf '%s\n' "$referenced" | grep -c . || true)"
  if [ -z "$missing" ]; then
    PASS=$((PASS + 1))
    echo "  ✅ $agent — all $count referenced index tools granted"
  else
    FAIL=$((FAIL + 1))
    echo "  ❌ $agent — body calls tools absent from frontmatter tools:"
    for m in $missing; do echo "       • $m"; done
  fi
done

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
