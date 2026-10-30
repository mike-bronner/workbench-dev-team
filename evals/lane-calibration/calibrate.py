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
USER_AGENT = "workbench-dev-team-lane-calibration"
RUN_TIMEOUT_S = 1800
RUN_BUDGET_USD = "10"
MIN_VALID_RUNS = 3
SCRUBBED_PREFIXES = ("GIT_", "GH_", "GITHUB_")
SCRUBBED_VARS = ("SSH_AUTH_SOCK", "SSH_ASKPASS", "CLAUDE_PROJECT_DIR")
TOKEN_VARS = ("GH_TOKEN", "GITHUB_TOKEN")
GIT_PINS = (
    ("credential.helper", ""),
    ("core.askPass", ""),
    ("protocol.allow", "never"),
    ("protocol.https.allow", "never"),
    ("protocol.http.allow", "never"),
    ("protocol.ssh.allow", "never"),
    ("protocol.git.allow", "never"),
    ("protocol.file.allow", "always"),
)
PLUGINS = ("workbench-dev-team@claude-workbench", "workbench-core@claude-workbench")
SETTINGS_DENY = [
    "Bash(git push:*)", "Bash(git * push)", "Bash(git * push *)",
    "Bash(git -c:*)", "Bash(git * -c *)",
    "Bash(git --config-env*)", "Bash(git * --config-env*)",
    "Bash(git credential*)", "Bash(git * credential*)", "Bash(git-credential*)", "Bash(*/git-credential*)",
    "Bash(git config*protocol.*)", "Bash(git * config*protocol.*)",
    "Bash(gh auth:*)", "Bash(*/gh auth*)",
    "Bash(claude:*)", "Bash(claude)", "Bash(* claude)", "Bash(* claude *)", "Bash(*/claude)", "Bash(*/claude *)",
]
NETWORK_BINARIES = ("curl", "wget", "security", "nc", "ssh", "scp")
BINARY_PATHS = ("/usr/bin", "/bin", "/opt/homebrew/bin", "/usr/local/bin")
DENIED_TOOLS = [
    "Workflow", "Artifact", "Monitor", "PushNotification", "RemoteTrigger", "SendMessage",
    "DesignSync", "ReportFindings", "CronCreate", "CronDelete", "CronList", "ScheduleWakeup",
    "TaskCreate", "TaskGet", "TaskList", "TaskOutput", "TaskStop", "TaskUpdate",
    "EnterWorktree", "ExitWorktree", "ListMcpResourcesTool", "ReadMcpResourceTool",
    "ReadMcpResourceDirTool", "NotebookEdit", "WebFetch", "WebSearch",
]
DENIED_TOOLS += [f"Bash({name}:*)" for name in NETWORK_BINARIES]
DENIED_TOOLS += [f"Bash({path}/{name}:*)" for path in BINARY_PATHS for name in NETWORK_BINARIES + ("gh",)]
INDEX_WRITES = ("set_acceptance_criteria", "update_fields", "move", "add_comment")
ALL_INDEX_WRITES = INDEX_WRITES + ("add_blocked_by", "close_as_duplicate", "submit_review", "create_issue", "claim_item", "release_item")
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


def remote_url(repo):
    return f"https://github.com/{repo}.git"


def mirror(out, repo, shas):
    path = out / "repos" / (repo.replace("/", "__") + ".git")
    if not path.exists():
        git("clone", "--bare", "--quiet", remote_url(repo), str(path))
        git("-C", str(path), "remote", "remove", "origin")
    for sha in shas:
        git("-C", str(path), "fetch", "--quiet", "--no-write-fetch-head", remote_url(repo), sha)
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


def run_env(rundir, extra):
    env = {k: v for k, v in os.environ.items() if not k.startswith(SCRUBBED_PREFIXES) and k not in SCRUBBED_VARS}
    (rundir / "ghconfig").mkdir(exist_ok=True)
    (rundir / "gitconfig").write_text("")
    env.update({
        "PATH": f"{rundir / 'bin'}:{env.get('PATH', '')}",
        "GH_TOKEN": "eval-replay-no-github-access",
        "GH_CONFIG_DIR": str(rundir / "ghconfig"),
        "GH_PROMPT_DISABLED": "1",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_SYSTEM": str(rundir / "gitconfig"),
        "GIT_CONFIG_GLOBAL": str(rundir / "gitconfig"),
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_SSH_COMMAND": "false",
        "GIT_CONFIG_COUNT": str(len(GIT_PINS)),
        "WORKBENCH_DEV_TEAM_PIPELINE": "1",
        "EVAL_GH_DATA": str(rundir / "fixture.json"),
        "EVAL_GH_LOG": str(rundir / "gh-log.jsonl"),
    })
    for i, (key, value) in enumerate(GIT_PINS):
        env[f"GIT_CONFIG_KEY_{i}"], env[f"GIT_CONFIG_VALUE_{i}"] = key, value
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
        git("clone", "--quiet", "--shared", "--no-checkout", str(mirror(out, fixture["repo"], [])), str(checkout))
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


def known_plugins(home):
    names = set()
    sources = ((home / ".claude" / "plugins" / "installed_plugins.json", "plugins"), (home / ".claude" / "settings.json", "enabledPlugins"))
    for path, key in sources:
        try:
            names |= set(json.loads(path.read_text()).get(key) or {})
        except (OSError, ValueError, AttributeError):
            continue
    return names


def run_settings(home):
    enabled = {plugin: False for plugin in known_plugins(home)}
    enabled.update({plugin: True for plugin in PLUGINS})
    return {"enabledPlugins": enabled, "permissions": {"deny": SETTINGS_DENY}}


def build_cmd(lane, cell, rundir, port, prompt):
    (rundir / "mcp.json").write_text(json.dumps({"mcpServers": {"the-index": {"type": "http", "url": f"http://127.0.0.1:{port}/mcp"}}}))
    (rundir / "settings.json").write_text(json.dumps(run_settings(Path.home())))
    return [
        "claude", "-p", "--agent", f"workbench-dev-team:{lane}",
        "--model", cell["model"], "--effort", cell["effort"],
        "--setting-sources", "project", "--settings", str(rundir / "settings.json"),
        "--strict-mcp-config", "--mcp-config", str(rundir / "mcp.json"),
        "--disallowedTools", ",".join(DENIED_TOOLS),
        "--allowedTools", "mcp__the-index__*",
        "--max-budget-usd", RUN_BUDGET_USD,
        "--permission-mode", "auto", "--permission-prompts", "none",
        "--output-format", "stream-json", "--verbose", prompt,
    ]


def check_init(event):
    servers = {s.get("name"): s.get("status") for s in event.get("mcp_servers", [])}
    if set(servers) != {"the-index"}:
        raise SafetyError(f"the run loaded MCP servers {sorted(servers)}; only the fake the-index may load")
    foreign = [t for t in event.get("tools", []) if t.startswith("mcp__") and not t.startswith("mcp__the-index__")]
    if foreign:
        raise SafetyError(f"the run loaded MCP tools outside the fake Index: {foreign}")
    plugins = {p.get("name") if isinstance(p, dict) else p for p in event.get("plugins", [])}
    expected = {plugin.split("@")[0] for plugin in PLUGINS}
    if plugins != expected:
        raise SafetyError(f"the run loaded plugins {sorted(plugins)}; only {sorted(expected)} may load")
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
    records = []
    if not path.exists():
        return records
    for line in path.read_text().splitlines():
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if isinstance(record, dict):
            records.append(record)
    return records


def unreadable_lines(path):
    lines = [line for line in path.read_text().splitlines() if line.strip()] if path.exists() else []
    return len(lines) - len(read_jsonl(path))


def index_calls(path):
    calls = []
    for entry in read_jsonl(path):
        body = entry.get("body")
        if not isinstance(body, dict):
            continue
        params = body.get("params") if isinstance(body.get("params"), dict) else {}
        if body.get("method", "tools/call") == "tools/call" and params.get("name"):
            arguments = params.get("arguments")
            calls.append((params["name"], arguments if isinstance(arguments, dict) else {}))
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


def blocker_blocks(text):
    return [b for b in finding_blocks(text) if re.search(r"severity\**:\s*\**\s*blocker", b, re.I)]


def grade_lens(fixture, text):
    blocks, blockers = finding_blocks(text), blocker_blocks(text)
    if fixture["expect"].get("no_blockers"):
        if blockers:
            return False, f"{len(blockers)} blocker finding(s) on a PR Holmes approved"
        if blocks or re.search(r"no findings", text or "", re.I):
            return True, "no blocker on a PR Holmes approved"
        return False, "no structured findings and no 'no findings' line in the report"
    if not blocks:
        return False, "no structured findings in the report"
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
        if name in INDEX_WRITES and str(args.get("id")) != str(fixture["item_id"]):
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
    try:
        if fixture["lane"] == "holmes-lens":
            return grade_lens(fixture, text)
        if fixture["lane"] == "lestrade-sweep":
            return grade_sweep(fixture, calls)
        return grade_item(fixture, calls)
    except Exception as failure:
        return False, f"the run's output could not be graded: {type(failure).__name__}: {failure}"


def build_record(lane, cell_id, cell, fixture, n, rundir, code, state, wall):
    result, requests = stream_metrics(rundir / "stream.jsonl")
    calls = index_calls(rundir / "index-log.jsonl")
    text = (result or {}).get("result", "") if isinstance(result, dict) else ""
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
        "timed_out": state["timeout"],
        "invalid": None,
    }
    if state["connected"] is None:
        record["invalid"] = "the run printed no init event, so its MCP servers were never checked"
    elif state["connected"] is False:
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
    return record


def run_one(out, lane, cell_id, cell, fixture, n):
    rundir = out / "runs" / lane / cell_id / fixture["name"] / str(n)
    index = None
    try:
        prompt, extra = prepare_run(out, rundir, fixture)
        index, port = start_index(rundir, fixture)
        cmd = build_cmd(lane, cell, rundir, port, prompt)
        started = time.monotonic()
        code, state = execute(cmd, rundir / "work", run_env(rundir, extra), rundir / "stream.jsonl")
        wall = round(time.monotonic() - started, 1)
    finally:
        if index is not None:
            index.kill()
            index.wait()
        for leftover in ("checkout", "snapshot.git"):
            shutil.rmtree(rundir / leftover, ignore_errors=True)
    return build_record(lane, cell_id, cell, fixture, n, rundir, code, state, wall)


def harness_failure(lane, cell_id, cell, fixture, n, failure):
    detail = getattr(failure, "stderr", None) or f"{type(failure).__name__}: {failure}"
    reason = f"the harness failed: {str(detail).strip()}"
    return {
        "lane": lane, "cell": cell_id, "model": cell["model"], "effort": cell["effort"],
        "fixture": fixture["name"], "run": n, "invalid": reason, "pass": False, "reason": reason,
        "gh_calls": [], "index_calls": [], "model_usage": {}, "requests": [], "cli_cost_usd": None, "result_text": "",
    }


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
    exported = [name for name in TOKEN_VARS if os.environ.get(name)]
    if exported:
        print(f"Refused: {', '.join(exported)} is set in this shell, and a run could read it from this process's environment. Start a new shell without it and run again, because unset does not remove it from what ps eww shows for this shell.", file=sys.stderr)
        return 1
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
        except Exception as failure:
            record = harness_failure(lane, cell_id, cell, fixture, n, failure)
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


def fetch_prices(url):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=30) as reply:
        prices = parse_prices(reply.read().decode())
    if not prices:
        raise ReportError(f"no price rows parsed from {url}")
    return prices


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


def priced_requests(record):
    for request in record["requests"]:
        tokens = request_tokens(request.get("usage") or {})
        if str(request.get("model", "")).startswith("claude-") and any(tokens.values()):
            yield base_model(request["model"]), tokens


def add(totals, key, tokens):
    old = totals.get(key, {k: 0 for k in tokens})
    totals[key] = {k: old[k] + tokens[k] for k in tokens}


def run_cost(record, prices):
    total, billed, streamed = 0.0, {}, {}
    for model, usage in record["model_usage"].items():
        tokens = usage_tokens(usage)
        if any(tokens.values()):
            add(billed, base_model(model), tokens)
    for base, tokens in priced_requests(record):
        total += cost(prices, base, tokens, tokens["input"] + tokens["write_5m"] + tokens["write_1h"] + tokens["hit"])
        add(streamed, base, tokens)
    for base, tokens in billed.items():
        seen = streamed.get(base, {k: 0 for k in tokens})
        total += cost(prices, base, {k: max(tokens[k] - seen[k], 0) for k in tokens}, 0)
    return total


def run_tokens(record):
    totals = {"all": 0, "output": 0}
    if record["model_usage"]:
        sources = [usage_tokens(u) for u in record["model_usage"].values()]
    else:
        sources = [tokens for _, tokens in priced_requests(record)]
    for tokens in sources:
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
        cli = [r.get("cli_cost_usd") for r in valid]
        rows[cell_id] = {
            "model": runs[0]["model"], "effort": runs[0]["effort"],
            "runs": len(valid), "invalid": len(runs) - len(valid),
            "pass_rate": mean([1.0 if r["pass"] else 0.0 for r in valid]),
            "tokens": mean([run_tokens(r)["all"] for r in valid]),
            "output_tokens": mean([run_tokens(r)["output"] for r in valid]),
            "wall_s": mean([r["wall_s"] for r in valid]),
            "cost": mean([run_cost(r, prices) for r in valid]),
            "cli_cost": mean(cli) if cli and None not in cli else None,
            "blockers": mean([len(blocker_blocks(r.get("result_text"))) for r in valid]),
        }
    return rows


def cheapest(rows, baseline, order):
    if baseline not in rows or rows[baseline]["runs"] < MIN_VALID_RUNS:
        return None, f"No cell can be named: the baseline has fewer than {MIN_VALID_RUNS} valid runs."
    floor = rows[baseline]["pass_rate"]
    if floor == 0:
        return None, "No match: the baseline passed no run, so no cell can be shown to match it."
    matching = [c for c, row in rows.items() if row["runs"] >= MIN_VALID_RUNS and row["pass_rate"] >= floor]
    rank = {c: i for i, c in enumerate(order)}
    return min(matching, key=lambda c: (round(rows[c]["cost"], 4), rank.get(c, len(order)))), None


def money(value):
    return "unknown" if value is None else f"${value:.4f}"


def lane_section(lane, records, prices, baseline, order):
    rows = summarize(records, prices)
    cells = [c for c in order if c in rows]
    lens = lane == "holmes-lens"
    head = "| Cell | Model | Effort | Valid runs | Pass rate | Mean tokens (output) | Mean wall time | Mean cost | Claude Code's cost |"
    lines = [f"## {lane}", "", head + (" Mean blockers |" if lens else ""), "|---" * (10 if lens else 9) + "|"]
    for cell_id in cells:
        row = rows[cell_id]
        mark = " (baseline)" if cell_id == baseline else ""
        line = (
            f"| {cell_id}{mark} | `{row['model']}` | {row['effort']} | {row['runs']} | {row['pass_rate']:.0%} | "
            f"{row['tokens']:,.0f} ({row['output_tokens']:,.0f}) | {row['wall_s']:.0f} s | {money(row['cost'])} | {money(row['cli_cost'])} |"
        )
        lines.append(line + (f" {row['blockers']:.1f} |" if lens else ""))
    pick, why = cheapest(rows, baseline, order)
    lines.append("")
    if pick is None:
        lines.append(why)
    else:
        lines.append(
            f"**Cheapest cell that matches the baseline pass rate: {pick}** (`{rows[pick]['model']}` at {rows[pick]['effort']}), "
            f"pass rate {rows[pick]['pass_rate']:.0%} against the baseline's {rows[baseline]['pass_rate']:.0%}, "
            f"mean cost {money(rows[pick]['cost'])} against {money(rows[baseline]['cost'])}."
        )
    lines += ["", "Passes per fixture:", "", "| Fixture | " + " | ".join(cells) + " |", "|---|" + "---|" * len(cells)]
    for name in sorted({r["fixture"] for r in records}):
        cols = []
        for cell_id in cells:
            runs = [r for r in records if r["cell"] == cell_id and r["fixture"] == name and not r["invalid"]]
            cols.append(f"{sum(r['pass'] for r in runs)}/{len(runs)}")
        lines.append(f"| {name} | " + " | ".join(cols) + " |")
    failures = [r for r in records if not r["pass"] and not r["invalid"]]
    if failures:
        lines += ["", "Why runs failed:", ""]
        lines += [f"- {r['cell']} / {r['fixture']} #{r['run']}: {r['reason']}" for r in failures]
    return lines


def write_audit(records):
    refused = [c for r in records for c in r["gh_calls"] if c.get("outcome") == "refused"]
    writes = [c for r in records for c in r["index_calls"] if c.get("name") in ALL_INDEX_WRITES]
    return [
        "## Writes",
        "",
        f"- Index write calls: {len(writes)}. Each one went to the run's local fake Index, which logged it as the run's output. None reached The Index.",
        f"- gh calls the fake gh refused as writes: {len(refused)}. None reached GitHub.",
        "- A write made past a best-effort layer, such as the real gh at another path, would appear in neither count. The eval's README names those routes.",
    ] + [f"  - `gh {' '.join(c['argv'])}`" for c in refused]


def render_report(out, records, prices, fetched, skipped):
    grid = load_cells()
    meta = json.loads((out / "meta.json").read_text()) if (out / "meta.json").exists() else {}
    lines = [
        "# Dev-team lane calibration",
        "",
        f"Results: `{out}`. Claude Code: {meta.get('claude_version', 'unknown')}.",
        f"Prices: {PRICING_URL}, read {fetched:%Y-%m-%d %H:%M} UTC. Cost uses the base input, 5-minute and 1-hour cache write, cache hit and output rates, per model.",
        f"A cell needs at least {MIN_VALID_RUNS} valid runs to be named. A run that times out after its init event counts as a failure, at the cost of the requests it streamed. A run that times out before it is invalid. A cost tie goes to the cell listed first in cells.json.",
        "",
        f"**Caveat:** {CAVEAT}",
        "",
    ]
    if skipped:
        lines += [f"**{skipped} result line(s) could not be read** and are left out.", ""]
    for lane in grid["lanes"]:
        lane_records = [r for r in records if r["lane"] == lane]
        if lane_records:
            lines += lane_section(lane, lane_records, prices, grid["baseline"], list(grid["cells"])) + [""]
    invalid = [r for r in records if r["invalid"]]
    if invalid:
        lines += ["## Invalid runs", "", "These runs are left out of every pass rate.", ""]
        lines += [f"- {r['lane']} {r['cell']} / {r['fixture']} #{r['run']}: {r['invalid']}" for r in invalid] + [""]
    return "\n".join(lines + write_audit(records)) + "\n"


def cmd_report(args):
    out = Path(args.out)
    records = read_jsonl(out / "results.jsonl")
    if not records:
        print(f"No results in {out}.", file=sys.stderr)
        return 1
    try:
        prices = fetch_prices(PRICING_URL)
        report = render_report(out, records, prices, datetime.now(timezone.utc), unreadable_lines(out / "results.jsonl"))
    except (ReportError, OSError) as failure:
        print(f"No report: {failure}", file=sys.stderr)
        return 1
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
