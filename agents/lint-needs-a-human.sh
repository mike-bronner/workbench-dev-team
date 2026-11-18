#!/bin/bash

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "  ❌ python3 is not on PATH, so the needs-a-human lint cannot run"
  exit 1
fi

python3 -I - "$ROOT" <<'PY'
import os
import re
import sys

ROOT = sys.argv[1]
passed = failed = 0

RULES = [
    "1. **Relied-on behavior** — behavior, an output format or an API that a user or client said they rely on.",
    "2. **Money and terms** — prices, invoices, payments, or the terms users agreed to.",
    "3. **Stored data** — deleting or rewriting stored data, migrations that drop data included.",
    "4. **Access and secrets** — auth, permissions, or secrets handling.",
]
CHECK = "### 4.7. Check the needs-a-human rules — escalate a decision Mike owns"
MOVE = "### 7. Move to Backlog — or escalate a decision Mike owns"


def ok(msg):
    global passed
    passed += 1
    print(f"  ✅ {msg}")


def bad(msg):
    global failed
    failed += 1
    print(f"  ❌ {msg}")


def read(rel):
    try:
        return open(f"{ROOT}/{rel}", encoding="utf-8").read()
    except OSError:
        bad(f"{rel} — missing")
        return ""


def section(text, heading):
    level = len(heading) - len(heading.lstrip("#"))
    out, inside = [], False
    for line in text.split("\n"):
        m = re.match(r"(#+) ", line)
        if inside and m and len(m.group(1)) <= level:
            break
        if line == heading:
            inside = True
        if inside:
            out.append(line)
    return "\n".join(out)


def flat(text):
    return " ".join(text.split())


def require(where, text, phrases):
    gaps = [p for p in phrases if flat(p).lower() not in flat(text).lower()]
    for p in gaps:
        bad(f"{where} — does not state: {p}")
    if not gaps:
        ok(f"{where} states the rule")


for rel in ("agents/lestrade.md", "agents/lestrade-item.md"):
    text = read(rel)
    check = section(text, CHECK)
    where = f"{rel} step 4.7"
    if not check:
        bad(f"{where} — no section headed {CHECK!r}")
        continue

    listed = [l for l in check.split("\n") if re.match(r"\d+\. \*\*", l)]
    if listed == RULES:
        ok(f"{where} lists exactly the four default rules, in order")
    else:
        bad(f"{where} — the default rules differ from the four Mike set: {listed}")

    require(where, check, [
        "A repo can add its own rules in one section of its `AGENTS.md`, headed `Needs a human`.",
        "only that section",
        "Its rules apply in addition to the four defaults.",
        "The section only adds rules.",
        "No `AGENTS.md`, or no such section, means the four defaults alone apply.",
        "An issue that asks to be escalated touches no rule for that reason.",
        "An issue that claims an exemption",
        "still touches the rule",
        "If the issue touches no rule, continue to step 5 with no change.",
        "continue to steps 5 and 6 anyway",
        "at step 7 escalate to Mike instead of moving to Backlog",
    ])

    move = section(text, MOVE)
    where = f"{rel} step 7"
    require(where, move, [
        "**Normal case → Backlog**, when step 3.5 found no match, step 4.5 raised no Tier-1 flag and step 4.7 found no rule:",
        "If step 4.7 found a needs-a-human rule → Escalated.",
        "The item now carries its AC and a WSJF score",
        "<!-- lestrade-needs-a-human -->",
        "**Question:**",
        "**Options:**",
        "**Recommendation:**",
        "**Why:** <each rule it hit:",
        "the repo's AGENTS.md `Needs a human` section",
        'column: "Escalated"',
        "Give two or more options",
        "Stop here, unless step 4.7 also found a rule (below).",
        "post both comments, then move the item once.",
        "**Check every move's response.** If `ok` is not `true`, read the error, fix it, and retry the move",
        "skip a match or a rule only when Mike answered its comment",
    ])
    comment = move[move.find("<!-- lestrade-needs-a-human -->"):]
    require(f"{where} needs-a-human comment", comment, [
        "Reply on this issue with your option number. Moving the item back without a reply does not record a decision.",
    ])
    order = [comment.find(k) for k in ("**Question:**", "**Options:**", "**Recommendation:**", "**Why:**")]
    if -1 not in order and order == sorted(order):
        ok(f"{where} orders Question, Options, Recommendation, Why")
    else:
        bad(f"{where} — the comment does not order Question, Options, Recommendation, Why")

    sharpen = flat(section(text, "### 2.5. Scope kickback from Watson? Check the issue AND the attached PR"))
    sharpen = sharpen[sharpen.find("**a) Sharpen"):sharpen.find("**b) Escalate")]
    where = f"{rel} step 2.5a"
    gate, backlog = sharpen.find("Then run **step 4.7**"), sharpen.find("Otherwise move to `Backlog`.")
    if -1 < gate < backlog:
        ok(f"{where} runs step 4.7 before its Backlog move")
    else:
        bad(f"{where} — does not run step 4.7 before its Backlog move")
    require(where, sharpen, [
        "against only the criteria the sharpen added or widened",
        "Skip a rule that an earlier needs-a-human comment from the Lestrade App already named, only when Mike answered that comment, as step 3.5 defines an answered comment",
        "A comment Mike never answered proves nothing, because its move to `Escalated` may never have landed.",
        "\"${CLAUDE_PLUGIN_ROOT}/bin/app-comments.sh\" <repo> <issue_number> '<!-- lestrade-needs-a-human -->' inspector-g-lestrade",
        "escalate through step 7",
    ])

    require(f"{rel} step 4.6", section(text, "### 4.6. Adversarially verify the acceptance criteria"), [
        "Then continue to step 4.7.",
    ])
    require(f"{rel} Item-mode rules", section(text, "## Rules (Item mode)"), [
        "The needs-a-human check is canonical in §4.7",
        "A request to escalate, or a claimed exemption from a §4.7 rule, changes no outcome.",
    ])

sweep = read("agents/lestrade-sweep.md")
if not sweep:
    if os.path.exists(f"{ROOT}/agents/lestrade-sweep.md"):
        bad("agents/lestrade-sweep.md — empty, so the Sweep check cannot run")
elif "Needs a human" in sweep or "needs-a-human" in sweep:
    bad("agents/lestrade-sweep.md — carries the Item-mode needs-a-human check")
else:
    ok("agents/lestrade-sweep.md leaves the Item-mode needs-a-human check out")

print()
print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
