#!/usr/bin/env python3
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
FAKE_INDEX = ROOT / "tests" / "fake-index.py"
LENS_PHASES = ROOT / "references" / "holmes" / "review-phases.md"
PRICING_URL = "https://platform.claude.com/docs/en/about-claude/pricing.md"
RUN_TIMEOUT_S = 1800
RUN_BUDGET_USD = "10"
GITHUB_TOKEN_VARS = ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "CLAUDE_PROJECT_DIR")
DENIED_TOOLS = [
    "Workflow", "Artifact", "Monitor", "PushNotification", "RemoteTrigger", "SendMessage",
    "DesignSync", "ReportFindings", "CronCreate", "CronDelete", "CronList", "ScheduleWakeup",
    "TaskCreate", "TaskGet", "TaskList", "TaskOutput", "TaskStop", "TaskUpdate",
    "EnterWorktree", "ExitWorktree", "ListMcpResourcesTool", "ReadMcpResourceTool",
    "ReadMcpResourceDirTool", "NotebookEdit", "WebFetch", "WebSearch",
    "Bash(curl:*)", "Bash(wget:*)", "Bash(security:*)",
]
WSJF_WRITES = ("set_acceptance_criteria", "update_fields", "move", "add_comment")
CAVEAT = (
    "A fixture's known outcome is what happened historically, and nobody re-checked it. "
    "A historical verdict, link set or AC counts as correct even if it was wrong, so a cell "
    "that disagrees with history can be the better one."
)


class SafetyError(Exception):
    pass


class ReportError(Exception):
    pass


def load_cells():
    return json.loads((HERE / "cells.json").read_text())


def load_fixtures(lane):
    return [json.loads(p.read_text()) for p in sorted((HERE / "fixtures" / lane).glob("*.json"))]


def plan(args):
    grid = load_cells()
    runs = args.runs or grid["runs_per_cell"]
    out = []
    for lane, cells in grid["lanes"].items():
        if args.lane and lane not in args.lane:
            continue
        for fixture in load_fixtures(lane):
            if args.fixture and fixture["name"] not in args.fixture:
                continue
            for cell in cells:
                if args.cell and cell not in args.cell:
                    continue
                out += [(lane, cell, grid["cells"][cell], fixture, n) for n in range(1, runs + 1)]
    return out


def git(*args, cwd=None, env=None):
    subprocess.run(["git", *args], cwd=cwd, env=env, check=True, capture_output=True, text=True)


def mirror(out, repo, shas):
    path = out / "repos" / (repo.replace("/", "__") + ".git")
    if not path.exists():
        git("clone", "--bare", "--quiet", f"https://github.com/{repo}.git", str(path))
    for sha in shas:
        git("-C", str(path), "fetch", "--quiet", "origin", sha)
        git("-C", str(path), "update-ref", f"refs/eval/{sha}", sha)
    return path


def needed_shas(fixture):
    if fixture["lane"] == "holmes-lens":
        return [fixture["base"], fixture["head"]]
    if fixture["lane"] == "lestrade-item":
        return [fixture["commit"]]
    return []


def lens_prompt(fixture, checkout):
    text = LENS_PHASES.read_text()
    skeleton = re.search(r"Prompt skeleton for each lens.*?\n```\n(.*?)\n```", text, re.S)
    task = re.search(r"^\d+\. \*\*" + re.escape(fixture["lens"]) + r"\*\* — (.+)$", text, re.M)
    if not skeleton or not task:
        raise SafetyError(f"{LENS_PHASES} no longer holds the lens skeleton or the {fixture['lens']} task")
    prompt = skeleton.group(1)
    values = {
        "<checkout path>": str(checkout),
        "<PR_NUM>": str(fixture["pr"]),
        "<repo>": fixture["repo"],
        "<AC text pasted verbatim>": fixture["acceptance_criteria"],
        "<one lens's task, from the list above>": f"{fixture['lens']} — {task.group(1)}",
    }
    for placeholder, value in values.items():
        if placeholder not in prompt:
            raise SafetyError(f"the lens skeleton has no {placeholder} placeholder")
        prompt = prompt.replace(placeholder, value)
    return prompt


def scenario(fixture):
    tools = {}
    if fixture["lane"] == "lestrade-item":
        tools["get_item"] = {"result": fixture["item"]}
    if fixture["lane"] == "lestrade-sweep":
        answers = {
            str(i["number"]): {"result": {"found": True, "item": {"id": 900000 + i["number"], "issue_number": i["number"], "pr_number": None, "repo": fixture["repo"], "status": "Backlog", "title": i["title"]}}}
            for i in fixture["github"]["issues"]
        }
        tools["find_item"] = {"byArg": "issue_number", "answers": answers, "default": {"result": {"found": False}}}
    return {"tools_list": json.loads((HERE / "index-tools.json").read_text()), "tools": tools}


def start_index(rundir, fixture):
    (rundir / "index-scenario.json").write_text(json.dumps(scenario(fixture)))
    port = rundir / "index.port"
    proc = subprocess.Popen([sys.executable, str(FAKE_INDEX), str(rundir / "index-scenario.json"), str(rundir / "index-log.jsonl"), str(port)])
    for _ in range(100):
        if port.exists():
            return proc, port.read_text()
        time.sleep(0.1)
    proc.kill()
    raise SafetyError("the fake Index did not start")


def run_env(rundir, fixture, extra):
    env = {k: v for k, v in os.environ.items() if k not in GITHUB_TOKEN_VARS}
    (rundir / "ghconfig").mkdir(exist_ok=True)
    (rundir / "gitconfig").write_text("")
    env.update({
        "PATH": f"{rundir / 'bin'}:{env.get('PATH', '')}",
        "GH_TOKEN": "eval-replay-no-github-access",
        "GH_CONFIG_DIR": str(rundir / "ghconfig"),
        "GH_PROMPT_DISABLED": "1",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": str(rundir / "gitconfig"),
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_SSH_COMMAND": "false",
        "WORKBENCH_DEV_TEAM_PIPELINE": "1",
        "EVAL_GH_DATA": str(rundir / "fixture.json"),
        "EVAL_GH_LOG": str(rundir / "gh-log.jsonl"),
    })
    env.update(extra)
    return env


def prepare_run(out, rundir, fixture):
    rundir.mkdir(parents=True)
    (rundir / "work").mkdir()
    (rundir / "fixture.json").write_text(json.dumps(fixture))
    (rundir / "bin").mkdir()
    gh = rundir / "bin" / "gh"
    gh.write_text(f'#!/bin/sh\nexec "{sys.executable}" -I "{HERE / "fake_gh.py"}" "$@"\n')
    gh.chmod(0o755)
    lane = fixture["lane"]
    if lane == "holmes-lens":
        checkout = rundir / "checkout"
        source = mirror(out, fixture["repo"], [])
        git("clone", "--quiet", "--shared", "--no-checkout", str(source), str(checkout))
        git("-C", str(checkout), "checkout", "--quiet", "-B", f"eval-pr-{fixture['pr']}", fixture["head"])
        git("-C", str(checkout), "update-ref", "refs/remotes/origin/main", fixture["base"])
        git("-C", str(checkout), "remote", "set-url", "--push", "origin", "eval-replay-no-push")
        return lens_prompt(fixture, checkout), {"EVAL_CHECKOUT": str(checkout), "EVAL_DIFF_BASE": fixture["base"], "EVAL_DIFF_HEAD": fixture["head"]}
    if lane == "lestrade-item":
        snapshot = rundir / "snapshot.git"
        git("clone", "--bare", "--quiet", "--shared", str(mirror(out, fixture["repo"], [])), str(snapshot))
        git("-C", str(snapshot), "update-ref", "refs/heads/eval-snapshot", fixture["commit"])
        git("-C", str(snapshot), "symbolic-ref", "HEAD", "refs/heads/eval-snapshot")
        return f"Item ID: {fixture['item_id']}", {"EVAL_CLONE_FROM": str(snapshot)}
    return f"Repo sweep: {fixture['repo']}", {}


def check_init(event):
    servers = {s.get("name"): s.get("status") for s in event.get("mcp_servers", [])}
    if set(servers) != {"the-index"}:
        raise SafetyError(f"the run loaded MCP servers {sorted(servers)}; only the fake the-index may load")
    foreign = [t for t in event.get("tools", []) if t.startswith("mcp__") and not t.startswith("mcp__the-index__")]
    if foreign:
        raise SafetyError(f"the run loaded MCP tools outside the fake Index: {foreign}")
    return servers["the-index"] == "connected"


def execute(cmd, cwd, env, stream_path):
    proc = subprocess.Popen(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    state = {"connected": None, "timeout": False}

    def expire():
        state["timeout"] = True
        proc.kill()

    timer = threading.Timer(RUN_TIMEOUT_S, expire)
    timer.start()
    try:
        with open(stream_path, "w") as stream:
            for line in proc.stdout:
                stream.write(line)
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if event.get("type") == "system" and event.get("subtype") == "init" and state["connected"] is None:
                    try:
                        state["connected"] = check_init(event)
                    except SafetyError:
                        proc.kill()
                        raise
                    if not state["connected"]:
                        proc.kill()
    finally:
        timer.cancel()
        proc.wait()
    return proc.returncode, state


def read_jsonl(path):
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def index_calls(path):
    calls = []
    for entry in read_jsonl(path):
        body = entry.get("body") or {}
        if body.get("method", "tools/call") == "tools/call" and (body.get("params") or {}).get("name"):
            calls.append((body["params"]["name"], body["params"].get("arguments") or {}))
    return calls


def stream_metrics(path):
    result, requests = None, {}
    for event in read_jsonl(path):
        if event.get("type") == "assistant":
            message = event.get("message") or {}
            if message.get("id") and message.get("usage"):
                requests[message["id"]] = {"model": message.get("model", ""), "usage": message["usage"]}
        if event.get("type") == "result":
            result = event
    return result, list(requests.values())


def finding_blocks(text):
    return re.split(r"(?im)^\s*-?\s*\**claim\**:", text or "")[1:]


def grade_lens(fixture, text):
    blocks = finding_blocks(text)
    if not blocks:
        return False, "no structured findings in the report"
    blockers = [b for b in blocks if re.search(r"severity\**:\s*\**\s*blocker", b, re.I)]
    for group in fixture["expect"]["any_of"]:
        if any(all(re.search(rx, b, re.I) for rx in group) for b in blockers):
            return True, "a blocker finding names the known defect"
    return False, f"{len(blockers)} blocker finding(s), none names the known defect"


def grade_sweep(fixture, calls):
    made = set()
    for name, args in calls:
        if name in ("close_as_duplicate", "set_acceptance_criteria"):
            return False, f"unexpected consolidation write: {name}"
        if name == "add_blocked_by":
            if str(args.get("repo", "")).lower() != fixture["repo"].lower():
                return False, f"add_blocked_by aimed at {args.get('repo')}"
            made |= {(int(args["issue_number"]), int(b)) for b in args.get("blocked_by") or []}
    required = {tuple(link) for link in fixture["expect"]["links"]}
    allowed = required | {tuple(link) for link in fixture["expect"].get("optional_links", [])}
    missing, extra = sorted(required - made), sorted(made - allowed)
    if missing or extra:
        return False, f"missing links {missing}, unexpected links {extra}"
    return True, "link set matches"


def grade_item(fixture, calls):
    expect = fixture["expect"]
    for name, args in calls:
        if name in WSJF_WRITES and str(args.get("id")) != str(fixture["item_id"]):
            return False, f"{name} aimed at item {args.get('id')}"
    criteria = [args.get("criteria") or "" for name, args in calls if name == "set_acceptance_criteria"]
    if not criteria:
        return False, "no acceptance criteria written"
    if not re.search(r"(?m)^\s*- \[ \]", criteria[-1]):
        return False, "the acceptance criteria are not a checklist"
    missing = [rx for rx in expect["ac_anchors"] if not re.search(rx, criteria[-1], re.I)]
    if missing:
        return False, f"the acceptance criteria miss anchors {missing}"
    fields = set()
    for name, args in calls:
        if name == "update_fields":
            fields |= set((args.get("fields") or {}).keys())
    absent = [f for f in expect["fields"] if f not in fields]
    if absent:
        return False, f"WSJF fields not set: {absent}"
    moves = [args.get("column") for name, args in calls if name == "move"]
    if not moves or moves[-1] != expect["move"] or "Escalated" in moves:
        return False, f"moves were {moves}, expected a final move to {expect['move']}"
    return True, "AC, WSJF fields and move match"


def grade(fixture, calls, text):
    if fixture["lane"] == "holmes-lens":
        return grade_lens(fixture, text)
    if fixture["lane"] == "lestrade-sweep":
        return grade_sweep(fixture, calls)
    return grade_item(fixture, calls)


def run_one(out, lane, cell_id, cell, fixture, n):
    rundir = out / "runs" / lane / cell_id / fixture["name"] / str(n)
    prompt, extra = prepare_run(out, rundir, fixture)
    index, port = start_index(rundir, fixture)
    try:
        (rundir / "mcp.json").write_text(json.dumps({"mcpServers": {"the-index": {"type": "http", "url": f"http://127.0.0.1:{port}/mcp"}}}))
        cmd = [
            "claude", "-p", "--agent", f"workbench-dev-team:{lane}",
            "--model", cell["model"], "--effort", cell["effort"],
            "--strict-mcp-config", "--mcp-config", str(rundir / "mcp.json"),
            "--disallowedTools", ",".join(DENIED_TOOLS),
            "--allowedTools", "mcp__the-index__*",
            "--max-budget-usd", RUN_BUDGET_USD,
            "--permission-mode", "auto", "--permission-prompts", "none",
            "--output-format", "stream-json", "--verbose", prompt,
        ]
        started = time.monotonic()
        code, state = execute(cmd, rundir / "work", run_env(rundir, fixture, extra), rundir / "stream.jsonl")
        wall = round(time.monotonic() - started, 1)
    finally:
        index.kill()
        index.wait()
    result, requests = stream_metrics(rundir / "stream.jsonl")
    calls = index_calls(rundir / "index-log.jsonl")
    text = (result or {}).get("result", "")
    record = {
        "lane": lane, "cell": cell_id, "model": cell["model"], "effort": cell["effort"],
        "fixture": fixture["name"], "run": n, "wall_s": wall, "exit": code,
        "result_subtype": (result or {}).get("subtype"),
        "cli_cost_usd": (result or {}).get("total_cost_usd"),
        "model_usage": (result or {}).get("modelUsage") or {},
        "requests": requests,
        "index_calls": [{"name": name, "arguments": args} for name, args in calls],
        "gh_calls": read_jsonl(rundir / "gh-log.jsonl"),
        "result_text": text,
        "invalid": None,
    }
    if state["connected"] is False:
        record["invalid"] = "the fake Index did not connect"
    elif result is None and not state["timeout"]:
        record["invalid"] = "the run ended without a result event"
    if record["invalid"]:
        record["pass"], record["reason"] = False, record["invalid"]
    elif state["timeout"]:
        record["pass"], record["reason"] = False, f"timed out after {RUN_TIMEOUT_S} s"
    elif record["result_subtype"] != "success":
        record["pass"], record["reason"] = False, f"run ended with {record['result_subtype']}"
    else:
        record["pass"], record["reason"] = grade(fixture, calls, text)
    for leftover in ("checkout", "snapshot.git"):
        shutil.rmtree(rundir / leftover, ignore_errors=True)
    return record


def cmd_run(args):
    runs = plan(args)
    if not runs:
        print("Nothing matches those filters.")
        return 1
    print(f"{len(runs)} agent runs:")
    for lane in dict.fromkeys(r[0] for r in runs):
        lane_runs = [r for r in runs if r[0] == lane]
        cells = sorted({r[1] for r in lane_runs})
        fixtures = sorted({r[3]["name"] for r in lane_runs})
        print(f"  {lane}: {len(lane_runs)} runs, cells {', '.join(cells)}, {len(fixtures)} fixtures")
    if not args.confirm:
        print("Nothing ran. Add --confirm to spend on these runs.")
        return 0
    out = Path(args.out or Path.home() / "Developer" / "scratchpad" / "lane-calibration" / datetime.now().strftime("%Y%m%d-%H%M%S"))
    out.mkdir(parents=True, exist_ok=False)
    claude_version = subprocess.run(["claude", "--version"], capture_output=True, text=True).stdout.strip()
    (out / "meta.json").write_text(json.dumps({"started": datetime.now(timezone.utc).isoformat(), "claude_version": claude_version, "runs": len(runs)}))
    for fixture in {r[3]["name"]: r[3] for r in runs}.values():
        if needed_shas(fixture):
            mirror(out, fixture["repo"], needed_shas(fixture))
    lock, abort = threading.Lock(), threading.Event()

    def work(item):
        lane, cell_id, cell, fixture, n = item
        if abort.is_set():
            return
        try:
            record = run_one(out, lane, cell_id, cell, fixture, n)
        except SafetyError as stop:
            abort.set()
            print(f"STOPPED: {stop}", file=sys.stderr)
            return
        except (OSError, subprocess.CalledProcessError) as failure:
            detail = getattr(failure, "stderr", None) or failure
            record = {
                "lane": lane, "cell": cell_id, "model": cell["model"], "effort": cell["effort"],
                "fixture": fixture["name"], "run": n, "invalid": f"the harness failed: {detail}".strip(),
                "pass": False, "gh_calls": [], "index_calls": [],
            }
            record["reason"] = record["invalid"]
        with lock, open(out / "results.jsonl", "a") as f:
            f.write(json.dumps(record) + "\n")
        print(f"{lane} {cell_id} {fixture['name']} #{n}: {'pass' if record['pass'] else 'fail'} ({record['reason']})", flush=True)

    try:
        with ThreadPoolExecutor(max_workers=args.jobs) as pool:
            list(pool.map(work, runs))
    finally:
        shutil.rmtree(out / "repos", ignore_errors=True)
    print(f"Results: {out / 'results.jsonl'}")
    if abort.is_set():
        return 2
    return cmd_report(argparse.Namespace(out=str(out)))


def parse_prices(markdown):
    prices = {}
    for line in markdown.splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) != 6 or not cells[0].startswith("Claude "):
            continue
        name = re.sub(r"\s*\(\[[^\]]*\]\([^)]*\)\)", "", cells[0]).strip()
        values = [re.search(r"\$([0-9.]+)\s*/\s*MTok", c) for c in cells[1:]]
        if all(values):
            prices[name] = dict(zip(("input", "write_5m", "write_1h", "hit", "output"), (float(v.group(1)) for v in values)))
    return prices


def row_name(model):
    match = re.match(r"claude-([a-z]+)-(\d+)-(\d+)", model)
    if not match:
        raise ReportError(f"cannot map model {model!r} to a pricing row")
    return f"Claude {match.group(1).capitalize()} {match.group(2)}.{match.group(3)}"


def price_row(prices, model, prompt_tokens):
    name = row_name(model)
    if name in prices:
        return prices[name]
    tier = "over" if prompt_tokens > 100000 else "up to"
    tiered = f"{name} (for prompts {tier} 100,000 tokens)"
    if tiered in prices:
        return prices[tiered]
    raise ReportError(f"the pricing page has no row for {name}")


def request_tokens(usage):
    split = usage.get("cache_creation")
    if split:
        write_5m, write_1h = split.get("ephemeral_5m_input_tokens", 0), split.get("ephemeral_1h_input_tokens", 0)
    else:
        write_5m, write_1h = usage.get("cache_creation_input_tokens", 0), 0
    return {
        "input": usage.get("input_tokens", 0), "write_5m": write_5m, "write_1h": write_1h,
        "hit": usage.get("cache_read_input_tokens", 0), "output": usage.get("output_tokens", 0),
    }


def usage_tokens(usage):
    split = "cacheCreationEphemeral5mInputTokens" in usage or "cacheCreationEphemeral1hInputTokens" in usage
    return {
        "input": usage.get("inputTokens", 0),
        "write_5m": usage.get("cacheCreationEphemeral5mInputTokens", 0) if split else usage.get("cacheCreationInputTokens", 0),
        "write_1h": usage.get("cacheCreationEphemeral1hInputTokens", 0),
        "hit": usage.get("cacheReadInputTokens", 0), "output": usage.get("outputTokens", 0),
    }


def cost(prices, model, tokens, prompt_tokens):
    row = price_row(prices, model, prompt_tokens)
    return sum(tokens[k] * row[k] for k in tokens) / 1_000_000


def base_model(model):
    return re.sub(r"\[.*\]$", "", model)


def run_cost(record, prices):
    total = 0.0
    for model, usage in record["model_usage"].items():
        billed = usage_tokens(usage)
        streamed = {k: 0 for k in billed}
        for request in record["requests"]:
            if base_model(request["model"]) != base_model(model):
                continue
            tokens = request_tokens(request["usage"])
            total += cost(prices, model, tokens, tokens["input"] + tokens["write_5m"] + tokens["write_1h"] + tokens["hit"])
            streamed = {k: streamed[k] + tokens[k] for k in streamed}
        total += cost(prices, model, {k: max(billed[k] - streamed[k], 0) for k in billed}, 0)
    return total


def run_tokens(record):
    totals = {"all": 0, "output": 0}
    for usage in record["model_usage"].values():
        tokens = usage_tokens(usage)
        totals["all"] += sum(tokens.values())
        totals["output"] += tokens["output"]
    return totals


def mean(values):
    return sum(values) / len(values) if values else 0.0


def summarize(records, prices):
    cells = {}
    for record in records:
        cells.setdefault(record["cell"], []).append(record)
    rows = {}
    for cell_id, runs in cells.items():
        valid = [r for r in runs if not r["invalid"]]
        rows[cell_id] = {
            "model": runs[0]["model"], "effort": runs[0]["effort"],
            "runs": len(valid), "invalid": len(runs) - len(valid),
            "pass_rate": mean([1.0 if r["pass"] else 0.0 for r in valid]),
            "tokens": mean([run_tokens(r)["all"] for r in valid]),
            "output_tokens": mean([run_tokens(r)["output"] for r in valid]),
            "wall_s": mean([r["wall_s"] for r in valid]),
            "cost": mean([run_cost(r, prices) for r in valid]),
            "cli_cost": mean([r["cli_cost_usd"] or 0.0 for r in valid]),
        }
    return rows


def cheapest(rows, baseline):
    if baseline not in rows or not rows[baseline]["runs"]:
        return None
    floor = rows[baseline]["pass_rate"]
    matching = [c for c, row in rows.items() if row["runs"] and row["pass_rate"] >= floor]
    return min(matching, key=lambda c: rows[c]["cost"])


def lane_section(lane, records, prices, baseline, order):
    rows = summarize(records, prices)
    lines = [f"## {lane}", "", "| Cell | Model | Effort | Valid runs | Pass rate | Mean tokens (output) | Mean wall time | Mean cost | Claude Code's cost |", "|---|---|---|---|---|---|---|---|---|"]
    for cell_id in [c for c in order if c in rows]:
        row = rows[cell_id]
        mark = " (baseline)" if cell_id == baseline else ""
        lines.append(
            f"| {cell_id}{mark} | `{row['model']}` | {row['effort']} | {row['runs']} | {row['pass_rate']:.0%} | "
            f"{row['tokens']:,.0f} ({row['output_tokens']:,.0f}) | {row['wall_s']:.0f} s | ${row['cost']:.4f} | ${row['cli_cost']:.4f} |"
        )
    pick = cheapest(rows, baseline)
    lines.append("")
    if pick is None:
        lines.append("No cell can be named: the baseline cell has no valid runs in these results.")
    else:
        lines.append(
            f"**Cheapest cell that matches the baseline pass rate: {pick}** (`{rows[pick]['model']}` at {rows[pick]['effort']}), "
            f"pass rate {rows[pick]['pass_rate']:.0%} against the baseline's {rows[baseline]['pass_rate']:.0%}, "
            f"mean cost ${rows[pick]['cost']:.4f} against ${rows[baseline]['cost']:.4f}."
        )
    fixtures = sorted({r["fixture"] for r in records})
    lines += ["", "Passes per fixture:", "", "| Fixture | " + " | ".join(c for c in order if c in rows) + " |", "|---|" + "---|" * len([c for c in order if c in rows])]
    for name in fixtures:
        cols = []
        for cell_id in [c for c in order if c in rows]:
            runs = [r for r in records if r["cell"] == cell_id and r["fixture"] == name and not r["invalid"]]
            cols.append(f"{sum(r['pass'] for r in runs)}/{len(runs)}")
        lines.append(f"| {name} | " + " | ".join(cols) + " |")
    failures = [r for r in records if not r["pass"]]
    if failures:
        lines += ["", "Why runs failed:", ""]
        lines += [f"- {r['cell']} / {r['fixture']} #{r['run']}: {r['reason']}" for r in failures]
    return lines


def write_audit(records):
    refused = [c for r in records for c in r["gh_calls"] if c["outcome"] == "refused"]
    writes = [c for r in records for c in r["index_calls"] if c["name"] in WSJF_WRITES + ("add_blocked_by", "close_as_duplicate", "submit_review", "create_issue", "claim_item", "release_item")]
    return [
        "## Writes",
        "",
        f"- Index write calls: {len(writes)}. Each one went to the run's local fake Index, which logged it as the run's output. None reached The Index.",
        f"- gh calls the fake gh refused as writes: {len(refused)}. None reached GitHub.",
    ] + [f"  - `gh {' '.join(c['argv'])}`" for c in refused]


def cmd_report(args):
    out = Path(args.out)
    records = read_jsonl(out / "results.jsonl")
    if not records:
        print(f"No results in {out}.", file=sys.stderr)
        return 1
    fetched = datetime.now(timezone.utc)
    try:
        request = urllib.request.Request(PRICING_URL, headers={"User-Agent": "workbench-dev-team-lane-calibration"})
        with urllib.request.urlopen(request, timeout=30) as reply:
            prices = parse_prices(reply.read().decode())
        if not prices:
            raise ReportError(f"no price rows parsed from {PRICING_URL}")
        grid = load_cells()
        meta = json.loads((out / "meta.json").read_text()) if (out / "meta.json").exists() else {}
        lines = [
            "# Dev-team lane calibration",
            "",
            f"Results: `{out}`. Claude Code: {meta.get('claude_version', 'unknown')}.",
            f"Prices: {PRICING_URL}, read {fetched:%Y-%m-%d %H:%M} UTC. Cost uses the base input, 5-minute and 1-hour cache write, cache hit and output rates, per model.",
            "",
            f"**Caveat:** {CAVEAT}",
            "",
        ]
        for lane in grid["lanes"]:
            lane_records = [r for r in records if r["lane"] == lane]
            if lane_records:
                lines += lane_section(lane, lane_records, prices, grid["baseline"], list(grid["cells"])) + [""]
        invalid = [r for r in records if r["invalid"]]
        if invalid:
            lines += ["## Invalid runs", "", "These runs are left out of every pass rate.", ""]
            lines += [f"- {r['lane']} {r['cell']} / {r['fixture']} #{r['run']}: {r['invalid']}" for r in invalid] + [""]
        lines += write_audit(records)
    except (ReportError, OSError) as failure:
        print(f"No report: {failure}", file=sys.stderr)
        return 1
    report = "\n".join(lines) + "\n"
    (out / "report.md").write_text(report)
    print(report)
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description="Per-lane model and effort calibration for the dev-team agents. See README.md.")
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run")
    run.add_argument("--lane", action="append")
    run.add_argument("--cell", action="append")
    run.add_argument("--fixture", action="append")
    run.add_argument("--runs", type=int)
    run.add_argument("--jobs", type=int, default=1)
    run.add_argument("--out")
    run.add_argument("--confirm", action="store_true")
    report = sub.add_parser("report")
    report.add_argument("out")
    args = parser.parse_args(argv)
    return cmd_run(args) if args.command == "run" else cmd_report(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
