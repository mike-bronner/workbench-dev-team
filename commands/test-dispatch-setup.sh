#!/usr/bin/env bash
# Test for setup's Dispatch install (Step 7, commands/setup.md): the
# dispatch-install transaction, the launchd-prove proof, the dispatch_restore
# rollback both share, and router-retire.
#
# It extracts the *real* blocks from between their sentinel markers and runs
# them against a throwaway HOME. launchctl, sleep and claude are stubs on PATH,
# so no job is ever loaded, no LaunchAgents folder outside the sandbox is
# touched, and no model runs. The stub launchctl records every call, which is
# how each case shows the stub, and never the real one, answered.
#
# The rule these cases hold: every check runs before anything is replaced, and
# every failure after the first replace restores what ran before, all or
# nothing. A re-run restores the proven set, which only a passed proof writes.
# A first install restores the bin.before snapshot.
#
# What no shell test reaches: the scheduled-task deletion in Step 7d, which is
# the model's own MCP call, and a real launchd load.
#
# Run: bash commands/test-dispatch-setup.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
SRC="$REPO/commands/setup.md"
WORK=$(mktemp -d)
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { echo "  ok   — $1"; pass=$((pass+1)); }
bad() { echo "  FAIL — $1"; fail=$((fail+1)); }
expect_eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }
expect_has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1: expected to contain [$2] in [$3]" ;; esac; }

for block in dispatch-install launchd-prove router-retire; do
  awk "/# >>> $block >>>/{f=1;next} /# <<< $block <<</{f=0} f" "$SRC" > "$WORK/$block.sh"
  [ -s "$WORK/$block.sh" ] || { echo "FAIL: could not extract the $block block from $SRC"; exit 1; }
done

# ── Stubs ────────────────────────────────────────────────────────────────────
STUB="$WORK/stub"; mkdir -p "$STUB"
cat > "$STUB/launchctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/launchctl.calls"
# What bin held at each call, so a test can read the order of unloads and
# replaces: the tag of each script, or - for one that is missing.
tags=""
for f in dispatch-agent.sh dispatch-tick.sh escalation-comment.md; do
  if [ -f "\$HOME/.claude-workbench/bin/\$f" ]; then tags="\$tags \$(cut -d' ' -f1 "\$HOME/.claude-workbench/bin/\$f")"; else tags="\$tags -"; fi
done
printf '%s%s\n' "\$1" "\$tags" >> "$WORK/launchctl.bin"
# A bootstrap fails with LAUNCHCTL_BOOT_RC, or only for a job file holding the
# text LAUNCHCTL_FAIL_IF. A kickstart appends KICK_LINES to TICK_LOG, as a
# tick would, and exits KICK_RC.
case "\$1" in
  bootstrap)
    if [ -n "\${LAUNCHCTL_FAIL_IF:-}" ] && grep -qF "\$LAUNCHCTL_FAIL_IF" "\$3"; then exit 5; fi
    exit "\${LAUNCHCTL_BOOT_RC:-0}" ;;
  print) exit "\${LAUNCHCTL_PRINT_RC:-0}" ;;
  kickstart)
    [ -n "\${KICK_LINES:-}" ] && printf '%s\n' "\$KICK_LINES" >> "\$TICK_LOG"
    exit "\${KICK_RC:-0}" ;;
esac
exit 0
EOF
# sleep returns at once, unless SLEEP_REAL is set, for the signal tests.
printf '#!/bin/sh\n[ -n "${SLEEP_REAL:-}" ] && exec /bin/sleep "$@"\nexit 0\n' > "$STUB/sleep"
printf '#!/bin/sh\nexit 0\n' > "$STUB/claude"
# install fails for a destination matching INSTALL_FAIL_ON, and is the real one
# otherwise: how a disk that fills partway through the replace looks.
REAL_INSTALL=$(command -v install)
cat > "$STUB/install" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do last="\$a"; done
case "\$last" in *"\${INSTALL_FAIL_ON:-/nowhere/}"*) exit 1 ;; esac
case "\$last" in *"\${INSTALL_SLOW_ON:-/nowhere/}"*) /bin/sleep 3 ;; esac
exec "$REAL_INSTALL" "\$@"
EOF
chmod +x "$STUB/"*

# The tools the block requires, without claude: a PATH for the case where
# claude cannot be found.
NOCLAUDE="$WORK/noclaude"; mkdir -p "$NOCLAUDE"
ln -s "$(command -v jq)" "$NOCLAUDE/jq"
ln -s "$(command -v curl)" "$NOCLAUDE/curl"
ln -s "$STUB/launchctl" "$NOCLAUDE/launchctl"
ln -s "$STUB/sleep" "$NOCLAUDE/sleep"

LABEL=dev.workbench.dev-team-dispatch
SCRIPTS="dispatch-agent.sh dispatch-tick.sh escalation-comment.md"

# fake_src <tag> [failing suite]: a plugin root whose scripts each say
# "<tag> <name>", with the real job template and manifest, and suites that pass
# except the one named.
fake_src() {
  local root="$WORK/src-$1" f
  [ -d "$root" ] && { printf '%s' "$root"; return; }
  mkdir -p "$root/bin" "$root/.claude-plugin"
  for f in $SCRIPTS; do printf '%s %s\n' "$1" "$f" > "$root/bin/$f"; done
  cp "$REPO/bin/dispatch-tick.plist" "$root/bin/"
  cp "$REPO/.claude-plugin/plugin.json" "$root/.claude-plugin/"
  for f in test-dispatch-agent.sh test-circuit-breaker.sh test-dispatch-tick.sh; do
    printf 'exit %s\n' "$([ "$f" = "${2:-}" ] && echo 1 || echo 0)" > "$root/bin/$f"
  done
  printf '%s' "$root"
}
# h <name>: a test's HOME.
h() { printf '%s' "$WORK/home-$1"; }
# install_run <name> <src> [settings JSON] [PATH]: the dispatch-install block.
install_run() {
  local home; home=$(h "$1")
  mkdir -p "$home/.claude"
  [ -z "${3:-}" ] || printf '%s' "$3" > "$home/.claude/settings.json"
  : > "$WORK/launchctl.calls"; : > "$WORK/launchctl.bin"
  ( HOME="$home" SRC_ROOT="$2" PATH="${4:-$STUB:/opt/fake-tools:$home/.claude/plugins/cache/x/1.0/bin:$PATH}" bash "$WORK/dispatch-install.sh" 2>&1 )
}
# prove_run <name> [PATH]: the launchd-prove block. KICK_LINES is the tick.
prove_run() {
  local home; home=$(h "$1")
  mkdir -p "$home/.claude-workbench/dev-team-logs"
  : > "$WORK/launchctl.calls"; : > "$WORK/launchctl.bin"
  ( HOME="$home" TICK_LOG="$home/.claude-workbench/dev-team-logs/dispatch-tick.log" PATH="${2:-$STUB:$PATH}" bash "$WORK/launchd-prove.sh" 2>&1 )
}
plist() { printf '%s' "$(h "$1")/Library/LaunchAgents/$LABEL.plist"; }
field() { python3 -c 'import plistlib,sys; p=plistlib.load(open(sys.argv[1],"rb")); print(eval(sys.argv[2]))' "$(plist "$1")" "$2" 2>&1; }
cadence() { jq -nc --argjson c "$1" '{pluginConfigs: {"workbench-dev-team@claude-workbench": {options: {dispatchCadenceMinutes: $c}}}}'; }
# ver <dir>: the tag each script in <dir> carries, as "a b c", or "-" for one
# that is missing.
ver() {
  local f out=""
  for f in $SCRIPTS; do
    if [ -f "$1/$f" ]; then out="$out $(cut -d' ' -f1 "$1/$f")"; else out="$out -"; fi
  done
  printf '%s' "${out# }"
}
bin_of() { ver "$(h "$1")/.claude-workbench/bin"; }
proven_of() { ver "$(h "$1")/.claude-workbench/bin.proven"; }
# state <name>: everything a check must leave alone, as one string.
mark_of() { cat "$(h "$1")/.claude-workbench/dispatch-install.state" 2>/dev/null; }
agents_of() { ls "$(h "$1")/Library/LaunchAgents" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
state() {
  local home; home=$(h "$1")
  printf 'bin=%s proven=%s job=%s provenjob=%s before=%s' "$(bin_of "$1")" "$(proven_of "$1")" \
    "$(cat "$(plist "$1")" 2>/dev/null | md5)" "$(cat "$home/.claude-workbench/bin.proven/dispatch-tick.plist" 2>/dev/null | md5)" \
    "$([ -e "$home/.claude-workbench/bin.before" ] && echo yes || echo no)"
}
# proven <name> <tag>: a home in the state a passed proof leaves: tag scripts
# in bin and in bin.proven, and a loaded job file, its proven copy beside them.
proven() {
  install_run "$1" "$(fake_src "$2")" >/dev/null
  KICK_LINES="tick ok 2026-10-08T07:00:00Z" prove_run "$1" >/dev/null
}
OKLINE='tick ok 2026-10-08T07:00:00Z'
FAILLINE='the-index unreachable — skipping this tick'

# ── dispatch-install: a first install ───────────────────────────────────────
echo "Testing setup's dispatch-install, a first install:"
out=$(install_run first "$(fake_src v1)"); rc=$?
expect_eq "exit 0" 0 "$rc"
expect_has "it says so" "the job loaded: $LABEL, every 20 minutes" "$out"
expect_eq "the scripts are installed" "v1 v1 v1" "$(bin_of first)"
expect_eq "scripts are executable, the template is not" "755 755 644" \
  "$(cd "$(h first)/.claude-workbench/bin" && stat -f %Lp dispatch-agent.sh dispatch-tick.sh escalation-comment.md 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
expect_eq "no proven set yet: only a passed proof writes one" "- - -" "$(proven_of first)"
expect_eq "the snapshot records that no script was there before" "" "$(cat "$(h first)/.claude-workbench/bin.before/manifest")"
expect_eq "the job file parses as a property list, with the label" "$LABEL" "$(field first 'p["Label"]')"
expect_eq "it runs the installed tick with /bin/bash" "['/bin/bash', '$(h first)/.claude-workbench/bin/dispatch-tick.sh']" "$(field first 'p["ProgramArguments"]')"
expect_eq "no cadence set: the row's default, 20 minutes" 1200 "$(field first 'p["StartInterval"]')"
expect_eq "it does not run at load" False "$(field first 'p["RunAtLoad"]')"
# launchd kills every process left in a finished job's process group unless
# this is true, and the agents a tick starts stay in the tick's group.
expect_eq "it abandons its process group, so the agents it starts outlive the tick" True "$(field first 'p.get("AbandonProcessGroup")')"
expect_eq "it runs as a Standard process, not under background limits" Standard "$(field first 'p.get("ProcessType")')"
expect_eq "its output goes to the tick log" "$(h first)/.claude-workbench/dev-team-logs/dispatch-tick.log" "$(field first 'p["StandardOutPath"]')"
JOBPATH=$(field first 'p["EnvironmentVariables"]["PATH"]')
expect_has "its PATH keeps this session's folders" ":/opt/fake-tools:" ":$JOBPATH:"
case ":$JOBPATH:" in *"/.claude/plugins/cache/"*) bad "a plugin-cache folder is on the job's PATH: $JOBPATH" ;; *) ok "no plugin-cache folder is on the job's PATH" ;; esac
expect_has "its PATH ends with the system folders" "/usr/bin:/bin:/usr/sbin:/sbin" "$JOBPATH"
case ":$JOBPATH:" in *:/tmp/*|*:/private/tmp/*|*:/var/folders/*) bad "a temporary folder is on the job's PATH: $JOBPATH" ;; *) ok "no temporary folder is on the job's PATH" ;; esac
expect_eq "each PATH folder appears once" "$(printf '%s\n' "$JOBPATH" | tr ':' '\n' | wc -l | tr -d ' ')" "$(printf '%s\n' "$JOBPATH" | tr ':' '\n' | sort -u | wc -l | tr -d ' ')"
expect_eq "launchctl: the old job out, the new one in, then checked" \
"bootout gui/$(id -u)/$LABEL
bootstrap gui/$(id -u) $(plist first)
print gui/$(id -u)/$LABEL" "$(cat "$WORK/launchctl.calls")"
out=$(install_run dupes "$(fake_src v1)" "" "/opt/fake-tools:$STUB:/opt/fake-tools:/usr/bin:$PATH")
expect_eq "a folder named twice on this session's PATH appears once" 1 "$(field dupes 'p["EnvironmentVariables"]["PATH"]' | tr ':' '\n' | grep -cx /opt/fake-tools)"
out=$(install_run amp "$(fake_src v1)" "" "/opt/a&b<c>d:$STUB:$PATH")
expect_has "a PATH folder with &, < and > is kept intact" ":/opt/a&b<c>d:" ":$(field amp 'p["EnvironmentVariables"]["PATH"]'):"
out=$(install_run tmp "$(fake_src v1)" "" "/private/tmp/claude-1/x:/tmp/y:/var/folders/z/bin:$STUB:$PATH")
case ":$(field tmp 'p["EnvironmentVariables"]["PATH"]'):" in *:/tmp/*|*:/private/tmp/*|*:/var/folders/*) bad "temporary folders reached the job's PATH" ;; *) ok "temporary folders on this session's PATH are left out" ;; esac
out=$(install_run thirty "$(fake_src v1)" "$(cadence 30)")
expect_eq "a cadence of 30 is 1800 seconds" 1800 "$(field thirty 'p["StartInterval"]')"

# ── dispatch-install: every check runs first, and changes nothing ───────────
echo "Testing that every check runs before anything is replaced:"
badsrc=$(fake_src v2-badplist)
sed 's#<key>RunAtLoad</key>#<key>RunAtLoad</broken>#' "$REPO/bin/dispatch-tick.plist" > "$badsrc/bin/dispatch-tick.plist"
missing=$(fake_src v2-missing); mv "$missing/bin/escalation-comment.md" "$missing/escalation-comment.md.away"
for case in \
  "cadence 3|$(fake_src v2)|$(cadence 3)||dispatchCadenceMinutes is '3'" \
  "cadence 121|$(fake_src v2)|$(cadence 121)||dispatchCadenceMinutes is '121'" \
  "cadence 20.5|$(fake_src v2)|$(cadence 20.5)||dispatchCadenceMinutes is '20.5'" \
  "cadence twenty|$(fake_src v2)|$(cadence '"twenty"')||dispatchCadenceMinutes is 'twenty'" \
  "no claude on PATH|$(fake_src v2)||$NOCLAUDE:/usr/bin:/bin:/usr/sbin:/sbin|claude is not on this session's PATH" \
  "a bad render|$badsrc|||is not a valid property list" \
  "a failing suite|$(fake_src v2-suite test-dispatch-tick.sh)|||bin/test-dispatch-tick.sh FAILED" \
  "a missing source file|$missing|||bin/escalation-comment.md is missing"
do
  IFS='|' read -r label src settings path needle <<< "$case"
  for kind in rerun first; do
    name="chk-$kind-$(printf '%s' "$label" | tr -dc 'a-z0-9')"
    if [ "$kind" = rerun ]; then proven "$name" v1; else mkdir -p "$(h "$name")/.claude-workbench/bin"; printf 'old dispatch-agent.sh\n' > "$(h "$name")/.claude-workbench/bin/dispatch-agent.sh"; fi
    before=$(state "$name")
    out=$(install_run "$name" "$src" "$settings" "${path:-}"); rc=$?
    expect_eq "$kind, $label: exit 1" 1 "$rc"
    expect_has "$kind, $label: names the cause, and says nothing changed" "$needle" "$out"
    expect_has "$kind, $label: says nothing changed" "Nothing changed." "$out"
    expect_eq "$kind, $label: bin, the proven set and the job file are unchanged" "$before" "$(state "$name")"
    expect_eq "$kind, $label: no launchctl call" "" "$(cat "$WORK/launchctl.calls")"
  done
done
proven partial v1
mv "$(h partial)/.claude-workbench/bin.proven/escalation-comment.md" "$(h partial)/away.md"
before=$(state partial)
out=$(install_run partial "$(fake_src v2)"); rc=$?
expect_eq "an incomplete proven set exits 1" 1 "$rc"
expect_has "and says a rollback could not restore it, and nothing changed" "is incomplete: it holds 3 of its 4 files" "$out"
expect_eq "and changes nothing" "$before" "$(state partial)"
proven roagents v1
before=$(state roagents)
chmod 555 "$(h roagents)/Library/LaunchAgents"
out=$(install_run roagents "$(fake_src v2)"); rc=$?
chmod 755 "$(h roagents)/Library/LaunchAgents"
expect_eq "a LaunchAgents folder that cannot be written exits 1" 1 "$rc"
expect_has "and says so, and that nothing changed" "cannot be written. Nothing changed." "$out"
expect_eq "and changes nothing" "$before" "$(state roagents)"

# ── dispatch-install: a failure after the replace restores, all or nothing ──
echo "Testing that a failure after the replace restores everything:"
proven rr2 v1
out=$(INSTALL_FAIL_ON=dispatch-tick.sh.new install_run rr2 "$(fake_src v2)"); rc=$?
expect_eq "a re-run whose second install fails exits 1" 1 "$rc"
expect_eq "every script is the proven one again, none left new" "v1 v1 v1" "$(bin_of rr2)"
expect_eq "the job file is the proven one" "$(cat "$(h rr2)/.claude-workbench/bin.proven/dispatch-tick.plist")" "$(cat "$(plist rr2)")"
expect_has "and it says Dispatch runs as before" "Could not install $(h rr2)/.claude-workbench/bin/dispatch-tick.sh. This is a re-run, so the proven scripts and job file are back and loaded, and Dispatch runs as it did before this setup." "$out"
expect_eq "the proven set is untouched" "v1 v1 v1" "$(proven_of rr2)"

mkdir -p "$(h fi2)/.claude-workbench/bin"; printf 'old dispatch-agent.sh\n' > "$(h fi2)/.claude-workbench/bin/dispatch-agent.sh"
out=$(INSTALL_FAIL_ON=dispatch-tick.sh.new install_run fi2 "$(fake_src v2)"); rc=$?
expect_eq "a first install whose second install fails exits 1" 1 "$rc"
expect_eq "the old router's dispatcher is back, and the new script is moved aside" "old - -" "$(bin_of fi2)"
expect_has "and it says the old scheduled task still runs, with the scripts as before" "This is a first install. The new job is unloaded, and there is no job file in LaunchAgents for launchd to load at the next login. The scripts in $(h fi2)/.claude-workbench/bin are as they were before this setup" "$out"

proven rrload v1
out=$(LAUNCHCTL_FAIL_IF='<integer>1800</integer>' install_run rrload "$(fake_src v2)" "$(cadence 30)"); rc=$?
expect_eq "a re-run whose new job will not load exits 1" 1 "$rc"
expect_eq "the proven scripts are back" "v1 v1 v1" "$(bin_of rrload)"
expect_eq "the proven job file is back, and loaded last" "1200" "$(field rrload 'p["StartInterval"]')"
expect_eq "the last calls load it and check it" "bootstrap gui/$(id -u) $(plist rrload)
print gui/$(id -u)/$LABEL" "$(tail -2 "$WORK/launchctl.calls")"
out=$(LAUNCHCTL_BOOT_RC=5 install_run rrload "$(fake_src v2)"); rc=$?
expect_has "when neither job loads, it says no Dispatch job runs, with the files back" "The proven scripts and job file are back on disk, but launchctl did not load the job, so no Dispatch job runs now" "$out"
expect_eq "with the proven scripts in bin" "v1 v1 v1" "$(bin_of rrload)"

mkdir -p "$(h fiload)/.claude-workbench/bin"
out=$(LAUNCHCTL_BOOT_RC=5 install_run fiload "$(fake_src v2)"); rc=$?
expect_eq "a first install whose job will not load exits 1" 1 "$rc"
expect_eq "its job file leaves LaunchAgents, so launchd does not load it at the next login" "" "$(ls "$(h fiload)/Library/LaunchAgents")"
expect_eq "it is kept on the shelf" "yes" "$([ -s "$(h fiload)/.claude-workbench/dispatch-tick.plist.unloaded" ] && echo yes)"
expect_eq "and the scripts that were not there before are moved aside" "- - -" "$(bin_of fiload)"
expect_eq "into bin.unproven, where nothing runs them" "v2 v2 v2" "$(ver "$(h fiload)/.claude-workbench/bin.unproven")"

proven rrwrite v1
mkdir -p "$(h rrwrite)/.claude-workbench/dispatch-tick.plist.new"
out=$(install_run rrwrite "$(fake_src v2)" "$(cadence 30)"); rc=$?
expect_eq "a re-run whose job file write fails exits 1" 1 "$rc"
expect_eq "the proven scripts are back" "v1 v1 v1" "$(bin_of rrwrite)"
expect_eq "the proven job file is in place" "1200" "$(field rrwrite 'p["StartInterval"]')"

# ── dispatch_restore: all or nothing ─────────────────────────────────────────
echo "Testing dispatch_restore, all or nothing:"
awk '/# >>> dispatch-restore >>>/{n++; f=1; next} /# <<< dispatch-restore <<</{f=0} f && n==1' "$SRC" > "$WORK/restore-1.sh"
awk '/# >>> dispatch-restore >>>/{n++; f=1; next} /# <<< dispatch-restore <<</{f=0} f && n==2' "$SRC" > "$WORK/restore-2.sh"
[ -s "$WORK/restore-1.sh" ] && cmp -s "$WORK/restore-1.sh" "$WORK/restore-2.sh" \
  && ok "7b and 7c carry the same dispatch_restore, so there is one restore path" || bad "the two copies of dispatch_restore differ"
restore() { ( HOME="$(h "$1")" PATH="$STUB:$PATH" bash -c '. "$1"; dispatch_restore "Test."' _ "$WORK/restore-1.sh" 2>&1 ); }
proven gone v1
install_run gone "$(fake_src v2)" >/dev/null
mv "$(h gone)/.claude-workbench/bin.proven/escalation-comment.md" "$(h gone)/away.md"
: > "$WORK/launchctl.calls"
out=$(restore gone); rc=$?
expect_eq "a re-run restore with a saved file missing exits 1" 1 "$rc"
expect_eq "and puts back no script at all" "v2 v2 v2" "$(bin_of gone)"
expect_has "and says bin may hold new or mixed scripts, the job is unloaded and moved aside, and no Dispatch job runs" "could not all be put back, so $(h gone)/.claude-workbench/bin may hold new or mixed scripts. The job is unloaded, its file is moved to" "$out"
expect_eq "and the job is unloaded, not loaded again" "bootout gui/$(id -u)/$LABEL" "$(cat "$WORK/launchctl.calls")"
expect_eq "LaunchAgents holds no job file for launchd to load at the next login" "" "$(agents_of gone)"
expect_eq "the job file is on the shelf" "yes" "$([ -s "$(h gone)/.claude-workbench/dispatch-tick.plist.unloaded" ] && echo yes)"
expect_eq "and the install stays marked, so the next run retries the restore" "installing" "$(mark_of gone)"
expect_has "and names the missing file" "The proven set is missing escalation-comment.md." "$out"
expect_has "and says a retry cannot fix it" "Running setup again cannot fix this. The install stays marked installing, so every run tries this restore first and fails the same way." "$out"
expect_has "and gives the way out: empty the mark, then run setup again" \
  "To get out, empty the mark with : > $(h gone)/.claude-workbench/dispatch-install.state, then run setup again." "$out"
out=$(install_run gone "$(fake_src v2)"); rc=$?
expect_eq "a setup run with the mark still set exits 1" 1 "$rc"
expect_has "and fails the same restore, naming the same file" "The proven set is missing escalation-comment.md." "$out"
: > "$(h gone)/.claude-workbench/dispatch-install.state"
out=$(install_run gone "$(fake_src v2)"); rc=$?
expect_eq "with the mark emptied, setup exits 1 at its checks" 1 "$rc"
expect_has "and reaches the proven-set check, which says to move the folder aside" \
  "is incomplete: it holds 3 of its 4 files, so a rollback could not restore it. Nothing changed. Put the missing files back, or move the folder aside to install as a first install." "$out"
proven gone2 v1
install_run gone2 "$(fake_src v2)" >/dev/null
mv "$(h gone2)/.claude-workbench/bin.proven/dispatch-agent.sh" "$(h gone2)/away-1.sh"
mv "$(h gone2)/.claude-workbench/bin.proven/escalation-comment.md" "$(h gone2)/away-2.md"
out=$(restore gone2)
expect_has "two missing files are both named" "The proven set is missing dispatch-agent.sh, escalation-comment.md." "$out"
# A copy that fails partway: the second script's staged name cannot be
# written. Every copy is staged before any rename, so nothing is renamed.
proven midcopy v1
install_run midcopy "$(fake_src v2)" >/dev/null
: > "$(h midcopy)/.claude-workbench/bin/dispatch-tick.sh.new"; chmod 444 "$(h midcopy)/.claude-workbench/bin/dispatch-tick.sh.new"
out=$(restore midcopy); rc=$?
chmod 644 "$(h midcopy)/.claude-workbench/bin/dispatch-tick.sh.new"
expect_eq "a restore whose second copy fails renames nothing, so bin is not a mix" "v2 v2 v2" "$(bin_of midcopy)"
expect_eq "and LaunchAgents holds no job file" "" "$(agents_of midcopy)"
mkdir -p "$(h fsnap)/.claude-workbench/bin"; printf 'old dispatch-agent.sh\n' > "$(h fsnap)/.claude-workbench/bin/dispatch-agent.sh"
install_run fsnap "$(fake_src v2)" >/dev/null
mv "$(h fsnap)/.claude-workbench/bin.before/dispatch-agent.sh" "$(h fsnap)/away.sh"
out=$(restore fsnap); rc=$?
expect_eq "a first-install restore with a snapshot file missing puts back nothing" "v2 v2 v2" "$(bin_of fsnap)"
expect_has "and says the scripts could not all be put back" "could not all be put back from" "$out"

# ── launchd-prove ────────────────────────────────────────────────────────────
echo "Testing setup's launchd-prove:"
# These cases hold the block's own logic: what it reads as proof, and how it
# rolls back. bin/test-dispatch-tick.sh runs the same block against the real
# tick's output on every failure path.
install_run pfirst "$(fake_src v1)" >/dev/null
out=$(KICK_LINES=$'── tick 2026-10-08T07:00:00Z ──\nidle — nothing to dispatch\n'"$OKLINE" prove_run pfirst); rc=$?
expect_eq "a clean tick proves the job" 0 "$rc"
expect_has "and says so" "Dispatch tick proven" "$out"
expect_eq "the job is started with kickstart, once, and nothing else" "kickstart gui/$(id -u)/$LABEL" "$(cat "$WORK/launchctl.calls")"
expect_eq "the scripts it ran become the proven set" "v1 v1 v1" "$(proven_of pfirst)"
expect_eq "with the job file that ran them" "$(cat "$(plist pfirst)")" "$(cat "$(h pfirst)/.claude-workbench/bin.proven/dispatch-tick.plist")"
install_run pfirst "$(fake_src v2)" >/dev/null
KICK_LINES="$OKLINE" prove_run pfirst >/dev/null
expect_eq "a later passed proof replaces the proven set whole" "v2 v2 v2" "$(proven_of pfirst)"
expect_eq "and keeps the set it replaced in the one replaced slot" "v1 v1 v1" "$(ver "$(h pfirst)/.claude-workbench/bin.proven.replaced")"
expect_eq "and the mark is cleared" "" "$(mark_of pfirst)"

for case in \
  "an idle line followed by a failure|"$'idle — nothing to dispatch\n'"$FAILLINE" \
  "a tick ok line with no start time|"$'idle — nothing to dispatch\ntick ok' \
  "a tick that writes nothing|"
do
  IFS='|' read -r label lines <<< "$case"
  name="pbad-$(printf '%s' "$label" | tr -dc 'a-z')"
  install_run "$name" "$(fake_src v1)" >/dev/null
  out=$(KICK_LINES="$lines" prove_run "$name"); rc=$?
  expect_eq "$label proves nothing" 1 "$rc"
done
install_run pstale "$(fake_src v1)" >/dev/null
printf '%s\n' "$OKLINE" >> "$(h pstale)/.claude-workbench/dev-team-logs/dispatch-tick.log"
out=$(prove_run pstale); rc=$?
expect_eq "a tick ok line from an earlier tick does not count" 1 "$rc"

echo "Testing setup's launchd-prove rollback:"
mkdir -p "$(h pfi)/.claude-workbench/bin"; printf 'old dispatch-agent.sh\n' > "$(h pfi)/.claude-workbench/bin/dispatch-agent.sh"
install_run pfi "$(fake_src v2)" >/dev/null
out=$(KICK_LINES="$FAILLINE" prove_run pfi); rc=$?
expect_eq "a first install whose tick fails exits 1" 1 "$rc"
expect_has "and says it is a first install, where the old task still runs" "This is a first install. The new job is unloaded, and its file is moved to" "$out"
expect_eq "the new job is unloaded" "kickstart gui/$(id -u)/$LABEL
bootout gui/$(id -u)/$LABEL" "$(cat "$WORK/launchctl.calls")"
expect_eq "its file leaves LaunchAgents" "" "$(ls "$(h pfi)/Library/LaunchAgents")"
expect_eq "the scripts are as before this setup" "old - -" "$(bin_of pfi)"
expect_eq "and no proven set is written" "- - -" "$(proven_of pfi)"

proven prr v1
install_run prr "$(fake_src v2)" "$(cadence 30)" >/dev/null
out=$(KICK_LINES="$FAILLINE" prove_run prr); rc=$?
expect_eq "a re-run whose tick fails exits 1" 1 "$rc"
expect_has "and says the proven scripts and job file are back and loaded" "This is a re-run, so the proven scripts and job file are back and loaded, and Dispatch runs as it did before this setup." "$out"
expect_eq "the proven scripts are back" "v1 v1 v1" "$(bin_of prr)"
expect_eq "the proven job file is back" "1200" "$(field prr 'p["StartInterval"]')"
expect_eq "the proven set is untouched by the failed tick" "v1 v1 v1" "$(proven_of prr)"
ran=$(python3 -c 'import plistlib, subprocess, sys; p = plistlib.load(open(sys.argv[1], "rb")); print(subprocess.run(["/bin/cat", p["ProgramArguments"][1]], capture_output=True, text=True).stdout.strip())' "$(plist prr)")
expect_eq "the restored job runs the proven tick script" "v1 dispatch-tick.sh" "$ran"

install_run prr "$(fake_src v2)" >/dev/null
out=$(KICK_RC=3 KICK_LINES="$OKLINE" prove_run prr); rc=$?
expect_eq "a kickstart that fails proves nothing" 1 "$rc"
expect_has "and says the job could not start, then rolls back" "launchctl could not start the job. This is a re-run" "$out"

# Two failed re-runs in a row: each restores the proven set, and neither
# writes to it, so the second restores the original, not the first's scripts.
echo "Testing two failed re-runs in a row:"
proven twice v1
out=$(LAUNCHCTL_FAIL_IF='<integer>1800</integer>' install_run twice "$(fake_src v2)" "$(cadence 30)"); rc=$?
expect_eq "the first re-run fails at its load" 1 "$rc"
expect_eq "after it, the proven scripts run" "v1 v1 v1" "$(bin_of twice)"
install_run twice "$(fake_src v3)" "$(cadence 45)" >/dev/null
expect_eq "the second re-run installs its scripts" "v3 v3 v3" "$(bin_of twice)"
out=$(KICK_LINES="$FAILLINE" prove_run twice); rc=$?
expect_eq "and its proof fails" 1 "$rc"
expect_eq "it ends with the original proven scripts back" "v1 v1 v1" "$(bin_of twice)"
expect_eq "and the original proven job file" "1200" "$(field twice 'p["StartInterval"]')"
expect_eq "and the proven set is still the original" "v1 v1 v1" "$(proven_of twice)"


# ── A 7c with no install waiting changes nothing ────────────────────────────
proven idle v1
before=$(state idle)
out=$(KICK_LINES="$OKLINE" prove_run idle); rc=$?
expect_eq "7c with no install waiting exits 1" 1 "$rc"
expect_has "and says to run 7b first" "No install is waiting for its proof" "$out"
expect_eq "and changes nothing, and starts no tick" "$before" "$(state idle)"
expect_eq "no launchctl call" "" "$(cat "$WORK/launchctl.calls")"

# ── The order of unloads and replaces ───────────────────────────────────────
echo "Testing that the job is unloaded before any script moves:"
proven order v1
out=$(install_run order "$(fake_src v2)"); rc=$?
expect_eq "a re-run's first launchctl call is a bootout, while bin still holds the proven scripts" "bootout v1 v1 v1" "$(head -1 "$WORK/launchctl.bin")"
expect_eq "and the new job loads only after every script is replaced" "bootstrap v2 v2 v2" "$(sed -n 2p "$WORK/launchctl.bin")"
proven order2 v1
out=$(LAUNCHCTL_BOOT_RC=5 install_run order2 "$(fake_src v2)"); rc=$?
expect_eq "a restore unloads the job before it copies anything back" "bootout v2 v2 v2" "$(grep '^bootout' "$WORK/launchctl.bin" | sed -n 2p)"
expect_eq "and loads the proven job only after every script is back" "bootstrap v1 v1 v1" "$(tail -1 "$WORK/launchctl.bin")"
proven order3 v1
install_run order3 "$(fake_src v2)" >/dev/null
out=$(KICK_LINES="$FAILLINE" prove_run order3); rc=$?
expect_eq "7c's restore unloads the job while bin still holds the new scripts" "bootout v2 v2 v2" "$(grep '^bootout' "$WORK/launchctl.bin" | head -1)"
expect_eq "and loads the proven job after the proven scripts are back" "bootstrap v1 v1 v1" "$(grep '^bootstrap' "$WORK/launchctl.bin" | tail -1)"

# ── A stopped shell restores ────────────────────────────────────────────────
echo "Testing that INT, TERM and HUP after the first replace restore:"
# spawn <out file> <block> <env...>: the block in the background, through a
# launcher that gives it default signal handling, as a session's shell has,
# since a background job of a script would otherwise start with INT ignored.
spawn() {
  local outf="$1" block="$2"; shift 2
  env "$@" python3 -c 'import os, signal, sys
for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP): signal.signal(s, signal.SIG_DFL)
out = os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
os.dup2(out, 1); os.dup2(out, 2)
os.execvp("bash", ["bash", sys.argv[1]])' "$block" "$outf" &
  SPAWNED=$!
}
# wait_for <seconds> <command…>: poll until the command succeeds.
wait_for() { local n=0; while ! "${@:2}" && [ "$n" -lt $(($1 * 10)) ]; do /bin/sleep 0.1; n=$((n + 1)); done; }
for sig in TERM INT HUP; do
  name="sig7b-$sig"
  proven "$name" v1
  home=$(h "$name"); : > "$WORK/launchctl.calls"
  spawn "$WORK/$name.out" "$WORK/dispatch-install.sh" HOME="$home" SRC_ROOT="$(fake_src v2)" INSTALL_SLOW_ON=dispatch-tick.sh.new PATH="$STUB:$PATH"
  wait_for 120 grep -q '^v2' "$home/.claude-workbench/bin/dispatch-agent.sh"
  kill -"$sig" "$SPAWNED"; wait "$SPAWNED"; rc=$?
  expect_eq "7b, $sig after the first replace: exits 1" 1 "$rc"
  expect_has "7b, $sig: says setup was stopped, and Dispatch runs as before" "Setup was stopped. This is a re-run, so the proven scripts and job file are back and loaded" "$(cat "$WORK/$name.out")"
  expect_eq "7b, $sig: every script is the proven one" "v1 v1 v1" "$(bin_of "$name")"
  expect_eq "7b, $sig: the mark is cleared" "" "$(mark_of "$name")"
done
for sig in TERM INT HUP; do
  name="sig7c-$sig"
  proven "$name" v1
  install_run "$name" "$(fake_src v2)" >/dev/null
  home=$(h "$name"); : > "$WORK/launchctl.calls"
  spawn "$WORK/$name.out" "$WORK/launchd-prove.sh" HOME="$home" SLEEP_REAL=1 TICK_LOG="$home/.claude-workbench/dev-team-logs/dispatch-tick.log" PATH="$STUB:$PATH"
  wait_for 50 grep -q '^kickstart' "$WORK/launchctl.calls"
  /bin/sleep 0.5
  kill -"$sig" "$SPAWNED"; wait "$SPAWNED"; rc=$?
  expect_eq "7c, $sig while it waits for the tick: exits 1" 1 "$rc"
  expect_has "7c, $sig: says setup was stopped, and Dispatch runs as before" "Setup was stopped before the tick was proven. This is a re-run, so the proven scripts and job file are back and loaded" "$(cat "$WORK/$name.out")"
  expect_eq "7c, $sig: every script is the proven one" "v1 v1 v1" "$(bin_of "$name")"
  expect_eq "7c, $sig: the proven set is untouched" "v1 v1 v1" "$(proven_of "$name")"
done

# ── The worst case stays inside the timeout setup asks for ──────────────────
echo "Testing that the worst case stays inside the stated timeout:"
asked=$(awk '/^### 7b\. /{f=1} /^### 7d\./{f=0} f' "$SRC" | grep -o "timeout\` set to [0-9]*" | grep -o '[0-9]*$' | sort -u)
expect_eq "7b and 7c each ask for the same timeout" "2 600000" "$(awk '/^### 7b\. /{f=1} /^### 7d\./{f=0} f' "$SRC" | grep -c "timeout\` set to 600000") $asked"
tries=$(sed -n 's/^LP_TRIES=\([0-9]*\)$/\1/p' "$WORK/launchd-prove.sh")
step=$(sed -n 's/^LP_STEP=\([0-9]*\)$/\1/p' "$WORK/launchd-prove.sh")
retries=$(grep -c 'for DR_TRY in 1 2 3 4 5; do' "$WORK/launchd-prove.sh")
worst=$(( tries * step + 5 * retries + 30 ))
[ -n "$tries" ] && [ -n "$step" ] && [ "$worst" -lt $(( ${asked:-0} / 1000 / 2 )) ] \
  && ok "7c's worst case, $worst s with a 30 s margin for the tick, is under half the $(( ${asked:-0} / 1000 )) s timeout" \
  || bad "7c's worst case is $worst s against a timeout of ${asked:-?} ms"
# 7b's worst case is its suites plus the same retries. Measured here, on the
# shipped suites, so the bound is not a guess.
start=$(date +%s)
for suite in test-dispatch-agent.sh test-circuit-breaker.sh test-dispatch-tick.sh; do bash "$REPO/bin/$suite" >/dev/null 2>&1; done
took=$(( $(date +%s) - start ))
[ $(( took + 10 )) -lt $(( ${asked:-0} / 1000 / 2 )) ] \
  && ok "7b's worst case, the suites' ${took} s plus 10 s of retries, is under half the timeout" \
  || bad "7b's worst case is $(( took + 10 )) s against a timeout of ${asked:-?} ms"

# ── An unfinished install is recovered, never snapshotted ───────────────────
echo "Testing that an unfinished install is recovered by the next run:"
mkdir -p "$(h unfin)/.claude-workbench/bin"; printf 'old dispatch-agent.sh\n' > "$(h unfin)/.claude-workbench/bin/dispatch-agent.sh"
install_run unfin "$(fake_src v2)" >/dev/null
expect_eq "7b passes and leaves the install marked unfinished" "installing" "$(mark_of unfin)"
# 7c never runs. The next setup run, whatever it would install, recovers first.
out=$(install_run unfin "$(fake_src v3)"); rc=$?
expect_eq "the next run exits 1" 1 "$rc"
expect_has "and says it restored what ran before, and changed nothing else" "An earlier setup stopped after it replaced the scripts and before a tick was proven" "$out"
expect_eq "the original scripts are back, and nothing new is left in bin" "old - -" "$(bin_of unfin)"
expect_eq "the snapshot still holds the original, never the unproven scripts" "old" "$(cut -d' ' -f1 "$(h unfin)/.claude-workbench/bin.before/dispatch-agent.sh")"
expect_eq "the unproven job leaves LaunchAgents" "" "$(agents_of unfin)"
expect_eq "the mark is cleared" "" "$(mark_of unfin)"
out=$(install_run unfin "$(fake_src v3)"); rc=$?
expect_eq "a third run installs as a first install again" "0 v3 v3 v3" "$rc $(bin_of unfin)"
expect_eq "with the original in its snapshot" "old" "$(cut -d' ' -f1 "$(h unfin)/.claude-workbench/bin.before/dispatch-agent.sh")"

proven unfin2 v1
install_run unfin2 "$(fake_src v2)" >/dev/null
out=$(install_run unfin2 "$(fake_src v3)"); rc=$?
expect_eq "a re-run left unproven is recovered to the proven scripts" "1 v1 v1 v1" "$rc $(bin_of unfin2)"
expect_eq "and the proven job file" "$(cat "$(h unfin2)/.claude-workbench/bin.proven/dispatch-tick.plist")" "$(cat "$(plist unfin2)")"

# A kill while 7c renames the staged proven set: the next run finishes it.
proven half v1
install_run half "$(fake_src v2)" >/dev/null
hs="$(h half)/.claude-workbench"
mkdir -p "$hs/bin.proven.next"
for f in $SCRIPTS; do cp -p "$hs/bin/$f" "$hs/bin.proven.next/$f"; done
cp "$(plist half)" "$hs/bin.proven.next/dispatch-tick.plist"
mv -f "$hs/bin.proven.next/dispatch-agent.sh" "$hs/bin.proven/dispatch-agent.sh"
printf 'proving\n' > "$hs/dispatch-install.state"
expect_eq "the half-written proven set is a mix" "v2 v1 v1" "$(proven_of half)"
out=$(install_run half "$(fake_src v2)"); rc=$?
expect_has "the next run says it finished the write" "That write is finished now." "$out"
expect_eq "the proven set is whole again, all from the passed tick" "v2 v2 v2" "$(proven_of half)"
expect_eq "and the run goes on to install" "0 installing" "$rc $(mark_of half)"

# ── Three passed re-runs leave one replaced slot ────────────────────────────
echo "Testing that backup and staging folders are fixed names:"
proven slots v1
for v in v2 v3 v4; do
  install_run slots "$(fake_src "$v")" >/dev/null
  KICK_LINES="$OKLINE" prove_run slots >/dev/null
done
expect_eq "three passed re-runs leave the newest proven set" "v4 v4 v4" "$(proven_of slots)"
expect_eq "one replaced slot, holding the set before it" "v3 v3 v3" "$(ver "$(h slots)/.claude-workbench/bin.proven.replaced")"
expect_eq "and no other backup or staging folder" "bin bin.before bin.proven bin.proven.next bin.proven.replaced" \
  "$(cd "$(h slots)/.claude-workbench" && ls -d bin* | tr '\n' ' ' | sed 's/ $//')"
expect_eq "the staging folder is left empty" "" "$(ls "$(h slots)/.claude-workbench/bin.proven.next")"

# Setup's blocks run in the session's own shell, which can be zsh, where an
# unquoted variable is not split into words.
if command -v zsh >/dev/null 2>&1; then
  echo "Testing the blocks under zsh:"
  zrun() { ( HOME="$(h "$1")" SRC_ROOT="$2" PATH="$STUB:/opt/fake-tools:$PATH" zsh "$WORK/dispatch-install.sh" 2>&1 ); }
  mkdir -p "$(h zfirst)/.claude"
  out=$(zrun zfirst "$(fake_src v1)"); rc=$?
  expect_eq "zsh: a first install exits 0" 0 "$rc"
  expect_eq "zsh: the scripts are installed" "v1 v1 v1" "$(bin_of zfirst)"
  expect_eq "zsh: the job matches the bash one, apart from its home" \
    "$(sed "s#$(h first)#HOME#g" "$(plist first)")" "$(sed "s#$(h zfirst)#HOME#g" "$(plist zfirst)")"
  out=$( HOME="$(h zfirst)" TICK_LOG="$(h zfirst)/.claude-workbench/dev-team-logs/dispatch-tick.log" KICK_LINES="$OKLINE" PATH="$STUB:$PATH" zsh "$WORK/launchd-prove.sh" 2>&1 ); rc=$?
  expect_eq "zsh: a clean tick proves the job" 0 "$rc"
  expect_eq "zsh: and writes the proven set" "v1 v1 v1" "$(proven_of zfirst)"
  out=$( HOME="$(h zfirst)" SRC_ROOT="$(fake_src v2)" INSTALL_FAIL_ON=dispatch-tick.sh.new PATH="$STUB:$PATH" zsh "$WORK/dispatch-install.sh" 2>&1 ); rc=$?
  expect_eq "zsh: a failed second install restores the proven scripts" "1 v1 v1 v1" "$rc $(bin_of zfirst)"
  out=$( HOME="$(h zfirst)" SRC_ROOT="$(fake_src v2)" PATH="$NOCLAUDE:/usr/bin:/bin:/usr/sbin:/sbin" zsh "$WORK/dispatch-install.sh" 2>&1 ); rc=$?
  expect_eq "zsh: no claude on PATH exits 1 and changes nothing" "1 v1 v1 v1" "$rc $(bin_of zfirst)"
  install_run zfirst "$(fake_src v3)" >/dev/null
  out=$( HOME="$(h zfirst)" TICK_LOG="$(h zfirst)/.claude-workbench/dev-team-logs/dispatch-tick.log" PATH="$STUB:$PATH" zsh "$WORK/launchd-prove.sh" 2>&1 ); rc=$?
  expect_eq "zsh: a silent tick fails and restores the proven scripts" "1 v1 v1 v1" "$rc $(bin_of zfirst)"
fi

# ── router-retire ────────────────────────────────────────────────────────────
echo "Testing setup's router-retire:"
retire() { ( HOME="$WORK/home-rr" WORKBENCH_SETTINGS_FILE="$1" bash "$WORK/router-retire.sh" 2>&1 ); }
mkdir -p "$WORK/home-rr"
ABS="Bash(bash $WORK/home-rr/.claude-workbench/bin/dispatch-agent.sh:*)"
# shellcheck disable=SC2016  # the rule spells $HOME literally
HOMEFORM='Bash(bash "$HOME/.claude-workbench/bin/dispatch-agent.sh":*)'
cfg="$WORK/rr.json"
jq -n --arg a "$ABS" --arg h "$HOMEFORM" \
  '{model: "x", permissions: {allow: ["Bash(ls:*)", $a, $h, "Read"], ask: ["Bash(git push *)"]}}' > "$cfg"
out=$(retire "$cfg"); rc=$?
expect_eq "exit 0" 0 "$rc"
expect_eq "only the two router rules go" '["Bash(ls:*)","Read"]' "$(jq -c .permissions.allow "$cfg")"
expect_eq "every other key stays" '{"ask":["Bash(git push *)"],"model":"x"}' "$(jq -c '{ask: .permissions.ask, model}' "$cfg")"
expect_eq "a backup is taken" 1 "$(ls "$cfg".bak-router-* 2>/dev/null | wc -l | tr -d ' ')"
before=$(cat "$cfg")
out=$(retire "$cfg")
expect_has "a re-run finds nothing to remove" "No router allow rules" "$out"
expect_eq "and changes nothing" "$before" "$(cat "$cfg")"
expect_eq "and takes no second backup" 1 "$(ls "$cfg".bak-router-* 2>/dev/null | wc -l | tr -d ' ')"

printf '["not", "an", "object"]' > "$WORK/rr-array.json"
out=$(retire "$WORK/rr-array.json"); rc=$?
expect_eq "a settings file that is not an object exits 1" 1 "$rc"
expect_eq "and is left untouched" '["not", "an", "object"]' "$(cat "$WORK/rr-array.json")"

out=$(retire "$WORK/rr-none.json"); rc=$?
expect_eq "no settings file exits 0" 0 "$rc"
[ -e "$WORK/rr-none.json" ] && bad "a settings file was created" || ok "no settings file is created"

echo
echo "dispatch setup: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
