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
  case "$tool" in
    ''|list_scheduled_tasks|create_scheduled_task|update_scheduled_task) ;;
    *) hits+=("$tool") ;;
  esac
done < <(printf '%s\n' "$steps" \
  | grep -o -E 'mcp__scheduled-tasks__[A-Za-z0-9_]+|[A-Za-z0-9]+_scheduled_tasks?' \
  | sed 's/^mcp__scheduled-tasks__//' | sort -u)
while IFS= read -r line; do
  [ -n "$line" ] && hits+=("passes enabled: $line")
done < <(printf '%s\n' "$steps" | grep -n -E '`?"?enabled"?`?[[:space:]]*[:=]')
report "setup's steps name no scheduled-tasks tool but list, create and update, and pass no enabled" ${hits[@]+"${hits[@]}"}

cases=()
description="$(awk 'NR==1 && $0=="---"{f=1; next} f && $0=="---"{exit} f && /^description:/' "$SETUP")"
printf '%s' "$description" | grep -Fq 'workbench-dev-team-dispatch scheduled task' \
  || cases+=("the frontmatter description does not name the workbench-dev-team-dispatch scheduled task")
for tool in list_scheduled_tasks create_scheduled_task update_scheduled_task; do
  printf '%s' "$steps" | grep -Fq "mcp__scheduled-tasks__$tool\`" \
    || cases+=("setup's steps never call mcp__scheduled-tasks__$tool")
done
for pair in found:update_scheduled_task missing:create_scheduled_task; do
  state=${pair%%:*}; tool=${pair#*:}
  bullet=$(printf '%s\n' "$steps" | awk -v head="- **When \`DISPATCH_TASK\` is \`$state\`**" 'index($0, head) == 1 {f=1; print; next} f && (/^- / || /^$/) {exit} f')
  case "$bullet" in
    *"mcp__scheduled-tasks__$tool\`"*) ;;
    *) cases+=("Step 7e's $state bullet does not call mcp__scheduled-tasks__$tool") ;;
  esac
done
printf '%s' "$steps" | tr '\n' ' ' | grep -Fq 'Setup never deletes this task and never disables it.' \
  || cases+=("setup no longer forbids deleting or disabling the Dispatch task")
report "setup names Dispatch as the scheduled task, and forbids deleting or disabling it" ${cases[@]+"${cases[@]}"}

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
