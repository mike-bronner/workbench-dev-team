#!/bin/bash

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP="$DIR/setup.md"
README="$DIR/../README.md"
PASS=0
FAIL=0

report() {
  local label="$1"; shift
  if [ "$#" -eq 0 ]; then
    PASS=$((PASS + 1)); echo "  ✅ $label"
  else
    FAIL=$((FAIL + 1)); echo "  ❌ $label"; for m in "$@"; do echo "       • $m"; done
  fi
}

[ -f "$SETUP" ] || { echo "  ❌ no setup.md beside this linter"; exit 1; }
[ -f "$README" ] || { echo "  ❌ no README.md in the plugin root"; exit 1; }

steps="$(awk '/^## Notes/{exit} {print}' "$SETUP")"

hits=()
while IFS= read -r line; do
  [ -n "$line" ] && hits+=("setup.md step: $line")
done < <(printf '%s\n' "$steps" | grep -n -i -E 'launchd|launchctl|LaunchAgents|\.plist')
while IFS= read -r line; do
  [ -n "$line" ] && hits+=("README.md: $line")
done < <(grep -n -E 'launchctl|LaunchAgents|\.plist' "$README")
report "no setup step and no README line installs or loads a launchd job" ${hits[@]+"${hits[@]}"}

hits=()
while IFS= read -r tool; do
  [ -n "$tool" ] && [ "$tool" != list_scheduled_tasks ] && hits+=("$tool")
done < <(printf '%s\n' "$steps" \
  | grep -o -E 'mcp__scheduled-tasks__[A-Za-z0-9_]+|[A-Za-z0-9]+_scheduled_tasks?' \
  | sed 's/^mcp__scheduled-tasks__//' | sort -u)
report "setup's steps name no scheduled-tasks tool but the list tool" ${hits[@]+"${hits[@]}"}

cases=()
description="$(awk 'NR==1 && $0=="---"{f=1; next} f && $0=="---"{exit} f && /^description:/' "$SETUP")"
printf '%s' "$description" | grep -Fq 'workbench-dev-team-dispatch scheduled task' \
  || cases+=("the frontmatter description does not name the workbench-dev-team-dispatch scheduled task")
printf '%s' "$steps" | tr '\n' ' ' | grep -Fq 'Never create, update, or delete this task, and never disable it.' \
  || cases+=("setup no longer forbids writing or disabling the Dispatch task")
report "setup names Dispatch as the scheduled task, and forbids writing it" ${cases[@]+"${cases[@]}"}

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
