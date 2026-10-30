import argparse
import fnmatch
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from contextlib import redirect_stderr
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from unittest import mock

import calibrate
import fake_gh

HERE = Path(__file__).resolve().parent

PRICES_MD = """
| Model | Base input tokens | 5m cache writes | 1h cache writes | Cache hits and refreshes | Output tokens |
| :---- | :---- | :---- | :---- | :---- | :---- |
| Claude Opus 5.5 | $4 / MTok | $5 / MTok | $8 / MTok | $0.20 / MTok<sup>2</sup> | $20 / MTok |
| Claude Opus 4.1 ([retired](https://example.com/x)) | $15 / MTok | $18.75 / MTok | $30 / MTok | $1.50 / MTok | $75 / MTok |
| Claude Sonnet 5.5 | $2 / MTok | $2.50 / MTok | $4 / MTok | $0.10 / MTok | $10 / MTok |
| Claude Haiku 5.5 (for prompts up to 100,000 tokens) | $0.10 / MTok | $0.125 / MTok | $0.20 / MTok | $0.01 / MTok | $0.50 / MTok |
| Claude Haiku 5.5 (for prompts over 100,000 tokens) | $0.50 / MTok | $0.625 / MTok | $1 / MTok | $0.05 / MTok | $2.50 / MTok |
| Concept | Details |
"""

LENS = {"lane": "holmes-lens", "expect": {"any_of": [["StructuredText", "preg"], ["__construct", "file.scope"]]}}
CLEAN_LENS = {"lane": "holmes-lens", "expect": {"no_blockers": True}}
SWEEP = {"lane": "lestrade-sweep", "repo": "o/r", "expect": {"links": [[2, 1], [3, 1]], "optional_links": [[3, 2]]}}
ITEM = {
    "lane": "lestrade-item", "item_id": 7,
    "expect": {"move": "Backlog", "fields": ["Size", "Priority"], "ac_anchors": ["tests/Unit", "testDirectory"]},
}
GOOD_AC = "- [ ] A test in tests/Unit counts.\n- [ ] A custom testDirectory keeps the old result."
CELL = {"model": "claude-opus-5-5[1m]", "effort": "medium"}
GIT_USER = ["-c", "user.name=t", "-c", "user.email=t@t"]


def item_calls(criteria=GOOD_AC, fields=("Size", "Priority"), moves=("Backlog",), item_id=7):
    calls = [("get_item", {"id": item_id}), ("set_acceptance_criteria", {"id": item_id, "agent": "lestrade", "criteria": criteria})]
    calls.append(("update_fields", {"id": item_id, "agent": "lestrade", "fields": {f: 1 for f in fields}}))
    calls += [("move", {"id": item_id, "agent": "lestrade", "column": m}) for m in moves]
    return calls


def make_repo(path):
    subprocess.run(["git", "init", "-q", str(path)], check=True)
    (path / "a.txt").write_text("one\n")
    subprocess.run(["git", "-C", str(path), "add", "a.txt"], check=True)
    subprocess.run(["git", "-C", str(path), *GIT_USER, "commit", "-qm", "base"], check=True)
    base = subprocess.run(["git", "-C", str(path), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    (path / "b.txt").write_text("added line\n")
    subprocess.run(["git", "-C", str(path), "add", "b.txt"], check=True)
    subprocess.run(["git", "-C", str(path), *GIT_USER, "commit", "-qm", "head"], check=True)
    head = subprocess.run(["git", "-C", str(path), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    return base, head


PLUGIN_NAMES = ["workbench-dev-team", "workbench-core"]


def init_event(servers=None, tools=(), plugins=None):
    return {
        "mcp_servers": servers if servers is not None else [{"name": "the-index", "status": "connected"}],
        "tools": list(tools),
        "plugins": [{"name": p, "path": f"/plugins/{p}"} for p in (plugins if plugins is not None else PLUGIN_NAMES)],
    }


def write_lines(path, lines):
    path.write_text("".join(line + "\n" for line in lines))


def success_stream(rundir, text="ok", init=True, cost=0.5):
    events = []
    if init:
        events.append(dict(init_event(), type="system", subtype="init"))
    events.append({"type": "result", "subtype": "success", "result": text, "total_cost_usd": cost, "modelUsage": {}})
    write_lines(rundir / "stream.jsonl", [json.dumps(e) for e in events])


class Pricing(unittest.TestCase):
    def setUp(self):
        self.prices = calibrate.parse_prices(PRICES_MD)

    def test_rows_parse_with_markup_stripped(self):
        self.assertEqual(self.prices["Claude Opus 5.5"]["hit"], 0.20)
        self.assertEqual(self.prices["Claude Opus 4.1"]["output"], 75.0)
        self.assertNotIn("Concept", " ".join(self.prices))

    def test_model_id_maps_to_its_row(self):
        self.assertEqual(calibrate.price_row(self.prices, "claude-opus-5-5[1m]", 0)["input"], 4.0)

    def test_haiku_tier_follows_prompt_size(self):
        self.assertEqual(calibrate.price_row(self.prices, "claude-haiku-5-5", 100000)["input"], 0.10)
        self.assertEqual(calibrate.price_row(self.prices, "claude-haiku-5-5", 100001)["input"], 0.50)

    def test_unpriced_model_fails_closed(self):
        with self.assertRaises(calibrate.ReportError):
            calibrate.price_row(self.prices, "claude-fable-5-1", 0)
        with self.assertRaises(calibrate.ReportError):
            calibrate.row_name("gpt-5")

    def test_run_cost_prices_each_request_and_the_unstreamed_rest(self):
        record = {
            "model_usage": {"claude-haiku-5-5": {"inputTokens": 1000, "outputTokens": 2000, "cacheReadInputTokens": 200000, "cacheCreationEphemeral5mInputTokens": 0, "cacheCreationEphemeral1hInputTokens": 10000}},
            "requests": [{"model": "claude-haiku-5-5", "usage": {"input_tokens": 0, "output_tokens": 1000, "cache_read_input_tokens": 200000, "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 0}}}],
        }
        over = (1000 * 2.50 + 200000 * 0.05) / 1e6
        rest = (1000 * 0.10 + 1000 * 0.50 + 10000 * 0.20) / 1e6
        self.assertAlmostEqual(calibrate.run_cost(record, self.prices), over + rest)

    def test_run_cost_matches_the_probe_haiku_call(self):
        record = {"model_usage": {"claude-haiku-5-5": {"inputTokens": 2, "outputTokens": 4, "cacheReadInputTokens": 0, "cacheCreationEphemeral5mInputTokens": 0, "cacheCreationEphemeral1hInputTokens": 34229}}, "requests": []}
        self.assertAlmostEqual(calibrate.run_cost(record, self.prices), 0.006848)

    def test_a_timed_out_run_costs_what_it_streamed(self):
        record = {"model_usage": {}, "requests": [{"model": "claude-opus-5-5", "usage": {"input_tokens": 1000, "output_tokens": 1000}}]}
        self.assertAlmostEqual(calibrate.run_cost(record, self.prices), (1000 * 4 + 1000 * 20) / 1e6)
        self.assertEqual(calibrate.run_tokens(record), {"all": 2000, "output": 1000})


class PriceFetch(unittest.TestCase):
    def serve(self, needs_agent):
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                allowed = needs_agent and self.headers.get("User-Agent") == calibrate.USER_AGENT
                body = PRICES_MD.encode() if allowed else b"forbidden"
                self.send_response(200 if allowed else 403)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        server = HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_address[1]}/pricing.md"

    def test_the_page_refuses_a_default_agent_and_serves_ours(self):
        url = self.serve(needs_agent=True)
        with self.assertRaises(urllib.error.HTTPError) as refused:
            urllib.request.urlopen(url)
        self.assertEqual(refused.exception.code, 403)
        self.assertEqual(calibrate.fetch_prices(url)["Claude Opus 5.5"]["input"], 4.0)

    def test_a_403_means_no_report(self):
        url = self.serve(needs_agent=False)
        with tempfile.TemporaryDirectory() as d:
            write_lines(Path(d) / "results.jsonl", [json.dumps({"lane": "holmes-lens"})])
            err = io.StringIO()
            with mock.patch.object(calibrate, "PRICING_URL", url), redirect_stderr(err):
                code = calibrate.cmd_report(argparse.Namespace(out=d))
            self.assertEqual(code, 1)
            self.assertIn("No report", err.getvalue())
            self.assertFalse((Path(d) / "report.md").exists())


class LensGrade(unittest.TestCase):
    def test_matching_blocker_passes(self):
        text = "- claim: lineMatches returns 0 when preg_match_all fails, untested\n  location: src/StructuredText.php:40\n  severity: blocker\n  scope: in-pr"
        self.assertTrue(calibrate.grade_lens(LENS, text)[0])

    def test_any_alternative_group_passes(self):
        text = "- claim: a file-scope __construct is scanned\n  location: x.php:1\n  severity: blocker"
        self.assertTrue(calibrate.grade_lens(LENS, text)[0])

    def test_a_note_does_not_count(self):
        text = "- claim: StructuredText preg branch untested\n  location: a:1\n  severity: note"
        self.assertFalse(calibrate.grade_lens(LENS, text)[0])

    def test_every_pattern_in_a_group_must_match_one_finding(self):
        text = "- claim: StructuredText is long\n  severity: blocker\n- claim: preg is slow\n  severity: blocker"
        self.assertFalse(calibrate.grade_lens(LENS, text)[0])

    def test_unstructured_report_fails(self):
        self.assertFalse(calibrate.grade_lens(LENS, "StructuredText preg blocker")[0])
        self.assertFalse(calibrate.grade_lens(LENS, "no findings")[0])

    def test_clean_pr_passes_with_no_findings_or_only_notes(self):
        self.assertTrue(calibrate.grade_lens(CLEAN_LENS, "no findings")[0])
        self.assertTrue(calibrate.grade_lens(CLEAN_LENS, "- claim: a long name\n  severity: note")[0])

    def test_clean_pr_fails_on_any_blocker(self):
        text = "- claim: a long name\n  severity: note\n- claim: a made-up bug\n  severity: blocker"
        ok, why = calibrate.grade_lens(CLEAN_LENS, text)
        self.assertFalse(ok)
        self.assertIn("1 blocker", why)

    def test_clean_pr_fails_on_an_unreadable_report(self):
        self.assertFalse(calibrate.grade_lens(CLEAN_LENS, "looks fine to me")[0])


class SweepGrade(unittest.TestCase):
    def link(self, blocked, blockers, repo="o/r"):
        return ("add_blocked_by", {"agent": "lestrade", "repo": repo, "issue_number": blocked, "blocked_by": blockers})

    def test_required_links_pass(self):
        self.assertTrue(calibrate.grade_sweep(SWEEP, [self.link(2, [1]), self.link(3, [1])])[0])

    def test_optional_link_is_allowed(self):
        self.assertTrue(calibrate.grade_sweep(SWEEP, [self.link(2, [1]), self.link(3, [1, 2])])[0])

    def test_missing_link_fails(self):
        self.assertFalse(calibrate.grade_sweep(SWEEP, [self.link(2, [1])])[0])

    def test_unexpected_link_fails(self):
        self.assertFalse(calibrate.grade_sweep(SWEEP, [self.link(2, [1]), self.link(3, [1]), self.link(1, [3])])[0])

    def test_reversed_link_fails(self):
        self.assertFalse(calibrate.grade_sweep(SWEEP, [self.link(1, [2]), self.link(3, [1])])[0])

    def test_link_in_another_repo_fails(self):
        self.assertFalse(calibrate.grade_sweep(SWEEP, [self.link(2, [1]), self.link(3, [1], repo="o/other")])[0])

    def test_consolidation_write_fails(self):
        calls = [self.link(2, [1]), self.link(3, [1]), ("close_as_duplicate", {"repo": "o/r", "canonical": 2, "duplicates": [3]})]
        self.assertFalse(calibrate.grade_sweep(SWEEP, calls)[0])

    def test_no_links_expected_and_none_made_passes(self):
        self.assertTrue(calibrate.grade_sweep({"lane": "lestrade-sweep", "repo": "o/r", "expect": {"links": []}}, [("find_item", {})])[0])


class ItemGrade(unittest.TestCase):
    def test_full_triage_passes(self):
        self.assertTrue(calibrate.grade_item(ITEM, item_calls())[0])

    def test_no_ac_fails(self):
        self.assertFalse(calibrate.grade_item(ITEM, [c for c in item_calls() if c[0] != "set_acceptance_criteria"])[0])

    def test_ac_that_is_not_a_checklist_fails(self):
        self.assertFalse(calibrate.grade_item(ITEM, item_calls(criteria="tests/Unit and testDirectory"))[0])

    def test_missing_anchor_fails(self):
        self.assertFalse(calibrate.grade_item(ITEM, item_calls(criteria="- [ ] A test in tests/Unit counts."))[0])

    def test_last_ac_write_is_the_one_graded(self):
        calls = item_calls()
        calls.insert(1, ("set_acceptance_criteria", {"id": 7, "criteria": "- [ ] nothing"}))
        self.assertTrue(calibrate.grade_item(ITEM, calls)[0])
        calls.append(("set_acceptance_criteria", {"id": 7, "criteria": "- [ ] nothing"}))
        self.assertFalse(calibrate.grade_item(ITEM, calls)[0])

    def test_missing_wsjf_field_fails(self):
        self.assertFalse(calibrate.grade_item(ITEM, item_calls(fields=("Size",)))[0])

    def test_wrong_final_column_fails(self):
        self.assertFalse(calibrate.grade_item(ITEM, item_calls(moves=("Ready",)))[0])
        self.assertFalse(calibrate.grade_item(ITEM, item_calls(moves=()))[0])

    def test_escalation_fails_even_when_it_ends_in_backlog(self):
        self.assertFalse(calibrate.grade_item(ITEM, item_calls(moves=("Escalated", "Backlog")))[0])

    def test_write_to_another_item_fails(self):
        calls = item_calls() + [("add_comment", {"id": 8, "agent": "lestrade", "body": "x"})]
        self.assertFalse(calibrate.grade_item(ITEM, calls)[0])


class MalformedOutput(unittest.TestCase):
    def test_a_non_numeric_issue_number_fails_the_run(self):
        calls = [("add_blocked_by", {"repo": "o/r", "issue_number": "two", "blocked_by": [1]})]
        ok, why = calibrate.grade(SWEEP, calls, "")
        self.assertFalse(ok)
        self.assertIn("could not be graded: ValueError", why)

    def test_list_valued_fields_fail_the_run(self):
        calls = item_calls()
        calls[2] = ("update_fields", {"id": 7, "fields": ["Size", "Priority"]})
        ok, why = calibrate.grade(ITEM, calls, "")
        self.assertFalse(ok)
        self.assertIn("could not be graded: AttributeError", why)

    def test_a_truncated_last_line_is_skipped_and_counted(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "log.jsonl"
            path.write_text('{"a": 1}\n["not", "an", "object"]\n{"b": ')
            self.assertEqual(calibrate.read_jsonl(path), [{"a": 1}])
            self.assertEqual(calibrate.unreadable_lines(path), 2)

    def test_a_truncated_index_log_still_grades(self):
        with tempfile.TemporaryDirectory() as d:
            rundir = Path(d)
            success_stream(rundir)
            call = {"body": {"method": "tools/call", "params": {"name": "add_blocked_by", "arguments": {"repo": "o/r", "issue_number": 2, "blocked_by": [1]}}}}
            (rundir / "index-log.jsonl").write_text(json.dumps(call) + '\n{"body": {"method": "tools/ca')
            state = {"connected": True, "timeout": False}
            record = calibrate.build_record("lestrade-sweep", "opus-medium", CELL, dict(SWEEP, name="s"), 1, rundir, 0, state, 1.0)
            self.assertIsNone(record["invalid"])
            self.assertFalse(record["pass"])
            self.assertIn("missing links [(3, 1)]", record["reason"])


class HarnessFailure(unittest.TestCase):
    def run_grid(self, error):
        def fail(*args):
            raise error

        reported = []
        clean = {k: v for k, v in os.environ.items() if k not in calibrate.TOKEN_VARS}
        with tempfile.TemporaryDirectory() as d, \
                mock.patch.dict(os.environ, clean, clear=True), \
                mock.patch.object(calibrate, "run_one", fail), \
                mock.patch.object(calibrate, "cmd_report", lambda args: reported.append(args.out) or 0), \
                mock.patch.object(calibrate.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "claude 0", "")):
            args = argparse.Namespace(lane=["lestrade-sweep"], cell=["opus-medium"], fixture=["clean-code-no-links"], runs=2, jobs=1, out=f"{d}/out", confirm=True)
            code = calibrate.cmd_run(args)
            return code, calibrate.read_jsonl(Path(d) / "out" / "results.jsonl"), reported

    def test_a_failed_step_is_an_invalid_run_and_the_grid_goes_on(self):
        code, records, reported = self.run_grid(subprocess.CalledProcessError(128, ["git"], stderr="fatal: no such ref"))
        self.assertEqual(code, 0)
        self.assertEqual(len(records), 2)
        self.assertTrue(all(r["invalid"] == "the harness failed: fatal: no such ref" and not r["pass"] for r in records))
        self.assertEqual(len(reported), 1)

    def test_a_value_error_is_an_invalid_run_and_the_grid_still_reports(self):
        code, records, reported = self.run_grid(ValueError("bad stream"))
        self.assertEqual(code, 0)
        self.assertEqual([r["invalid"] for r in records], ["the harness failed: ValueError: bad stream"] * 2)
        self.assertEqual(len(reported), 1)

    def test_an_exported_github_token_refuses_the_grid(self):
        for name in calibrate.TOKEN_VARS:
            started = []
            with tempfile.TemporaryDirectory() as d, \
                    mock.patch.dict(os.environ, {name: "a-token"}), \
                    mock.patch.object(calibrate, "run_one", lambda *args: started.append(args)), \
                    mock.patch.object(calibrate.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "claude 0", "")):
                err = io.StringIO()
                args = argparse.Namespace(lane=["lestrade-sweep"], cell=["opus-medium"], fixture=["clean-code-no-links"], runs=1, jobs=1, out=f"{d}/out", confirm=True)
                with redirect_stderr(err):
                    code = calibrate.cmd_run(args)
                self.assertEqual(code, 1, name)
                self.assertIn(f"Refused: {name} is set", err.getvalue())
                self.assertIn("Start a new shell without it", err.getvalue())
                self.assertNotIn("a-token", err.getvalue())
                self.assertFalse((Path(d) / "out").exists())
                self.assertEqual(started, [])

    def test_a_safety_stop_ends_the_grid_with_nothing_recorded(self):
        code, records, reported = self.run_grid(calibrate.SafetyError("foreign MCP server"))
        self.assertEqual(code, 2)
        self.assertEqual(records, [])
        self.assertEqual(reported, [])


class Sandbox(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.rundir = Path(self.dir.name)
        (self.rundir / "bin").mkdir()

    def tearDown(self):
        self.dir.cleanup()

    def env(self):
        inherited = {
            "GH_TOKEN": "real", "GITHUB_TOKEN": "real", "GH_HOST": "github.com", "GIT_ASKPASS": "/x", "SSH_AUTH_SOCK": "/sock",
            "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "credential.helper", "GIT_CONFIG_VALUE_0": "osxkeychain",
            "GIT_CONFIG_PARAMETERS": "'credential.helper'='osxkeychain'", "GIT_DIR": "/elsewhere", "CLAUDE_PROJECT_DIR": "/repo",
            "SSH_ASKPASS": "/askpass", f"GIT_CONFIG_KEY_{len(calibrate.GIT_PINS) + 3}": "protocol.https.allow",
            f"GIT_CONFIG_VALUE_{len(calibrate.GIT_PINS) + 3}": "always",
        }
        with mock.patch.dict(os.environ, inherited):
            return calibrate.run_env(self.rundir, {"EVAL_CHECKOUT": "/c"})

    def test_inherited_credentials_and_git_config_are_scrubbed(self):
        env = self.env()
        self.assertEqual(env["GH_TOKEN"], "eval-replay-no-github-access")
        above = len(calibrate.GIT_PINS) + 3
        for name in ("GITHUB_TOKEN", "GH_HOST", "GIT_ASKPASS", "SSH_AUTH_SOCK", "SSH_ASKPASS", "GIT_CONFIG_PARAMETERS", "GIT_DIR",
                     "CLAUDE_PROJECT_DIR", f"GIT_CONFIG_KEY_{above}", f"GIT_CONFIG_VALUE_{above}"):
            self.assertNotIn(name, env)
        pins = {env[f"GIT_CONFIG_KEY_{i}"]: env[f"GIT_CONFIG_VALUE_{i}"] for i in range(int(env["GIT_CONFIG_COUNT"]))}
        self.assertEqual(pins, dict(calibrate.GIT_PINS))
        self.assertEqual(env["EVAL_CHECKOUT"], "/c")

    def test_the_run_bin_folder_comes_first_on_path(self):
        self.assertEqual(self.env()["PATH"].split(":")[0], str(self.rundir / "bin"))

    def test_git_has_no_credential_helper_and_no_network_transport(self):
        env = self.env()
        helpers = subprocess.run(["git", "config", "--get-all", "credential.helper"], env=env, capture_output=True, text=True).stdout.splitlines()
        self.assertEqual(helpers[-1:], [""])
        remote = subprocess.run(["git", "ls-remote", "https://github.com/mike-bronner/workbench-dev-team.git"], env=env, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(remote.returncode, 0)
        self.assertIn("transport 'https' not allowed", remote.stderr)

    def test_a_local_per_protocol_allow_does_not_reopen_https(self):
        env = self.env()
        repo = self.rundir / "work-repo"
        subprocess.run(["git", "init", "-q", str(repo)], check=True, env=env)
        subprocess.run(["git", "-C", str(repo), "config", "protocol.https.allow", "always"], check=True, env=env)
        remote = subprocess.run(["git", "-C", str(repo), "ls-remote", "https://github.com/mike-bronner/workbench-dev-team.git"], env=env, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(remote.returncode, 0)
        self.assertIn("transport 'https' not allowed", remote.stderr)

    def test_no_file_in_the_mirror_checkout_or_snapshot_holds_the_remote_url(self):
        source = self.rundir / "remote-url-marker"
        base, head = make_repo(source)
        url = "file://" + str(source)
        out = self.rundir / "out"
        lens = {"lane": "holmes-lens", "name": "f", "repo": "o/r", "pr": 5, "base": base, "head": head, "lens": "Correctness lens", "acceptance_criteria": "- [ ] x"}
        item = {"lane": "lestrade-item", "name": "i", "repo": "o/r", "item_id": 7, "commit": head}
        with mock.patch.object(calibrate, "remote_url", lambda repo: url):
            calibrate.mirror(out, "o/r", [base, head])
            calibrate.prepare_run(out, out / "lens", lens)
            calibrate.prepare_run(out, out / "item", item)
        trees = [out / "repos" / "o__r.git", out / "lens" / "checkout", out / "item" / "snapshot.git"]
        files = [f for tree in trees for f in tree.rglob("*") if f.is_file()]
        self.assertGreater(len(files), 30)
        holding = [str(f) for f in files if b"remote-url-marker" in f.read_bytes()]
        self.assertEqual(holding, [])
        self.assertIn("pushurl = eval-replay-no-push", (out / "lens" / "checkout" / ".git" / "config").read_text())

    def test_the_run_command_is_pinned_to_the_fake_index_and_its_own_settings(self):
        out = self.rundir / "out"
        fixture = calibrate.load_fixtures("lestrade-sweep")[0]
        captured = {}

        def fake_execute(cmd, cwd, env, stream_path):
            captured["cmd"], captured["env"] = cmd, env
            Path(stream_path).write_text(json.dumps({"type": "result", "subtype": "success", "result": "x"}) + "\n")
            return 0, {"connected": None, "timeout": False}

        with mock.patch.object(calibrate, "execute", fake_execute):
            record = calibrate.run_one(out, "lestrade-sweep", "opus-medium", CELL, fixture, 1)
        cmd, rundir = captured["cmd"], out / "runs" / "lestrade-sweep" / "opus-medium" / fixture["name"] / "1"
        self.assertIn("--strict-mcp-config", cmd)
        servers = json.loads(Path(cmd[cmd.index("--mcp-config") + 1]).read_text())["mcpServers"]
        self.assertEqual(list(servers), ["the-index"])
        self.assertTrue(servers["the-index"]["url"].startswith("http://127.0.0.1:"))
        self.assertEqual(cmd[cmd.index("--setting-sources") + 1], "project")
        settings = json.loads(Path(cmd[cmd.index("--settings") + 1]).read_text())
        self.assertEqual({p for p, on in settings["enabledPlugins"].items() if on}, set(calibrate.PLUGINS))
        self.assertIn("Bash(git * push *)", settings["permissions"]["deny"])
        self.assertEqual(cmd[cmd.index("--model") + 1], CELL["model"])
        self.assertEqual(cmd[-1], "Repo sweep: " + fixture["repo"])
        denied = cmd[cmd.index("--disallowedTools") + 1].split(",")
        for rule in ("Bash(curl:*)", "Bash(/usr/bin/curl:*)", "Bash(/usr/bin/security:*)", "Bash(/opt/homebrew/bin/gh:*)", "WebFetch"):
            self.assertIn(rule, denied)
        self.assertEqual(Path(captured["env"]["PATH"].split(":")[0]), rundir / "bin")
        self.assertTrue(record["invalid"].startswith("the run printed no init event"))
        self.assertFalse(record["pass"])


class RunEnd(unittest.TestCase):
    def build(self, events):
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        rundir = Path(d.name)
        write_lines(rundir / "stream.jsonl", [json.dumps(dict(init_event(), type="system", subtype="init"))] + [json.dumps(e) for e in events])
        calls = [{"body": {"method": "tools/call", "params": {"name": "add_blocked_by", "arguments": {"repo": "o/r", "issue_number": a, "blocked_by": [b]}}}} for a, b in ((2, 1), (3, 1))]
        write_lines(rundir / "index-log.jsonl", [json.dumps(c) for c in calls])
        return calibrate.build_record("lestrade-sweep", "opus-medium", CELL, dict(SWEEP, name="s"), 1, rundir, 0, {"connected": True, "timeout": False}, 30.0)

    def test_a_run_with_no_result_event_is_invalid(self):
        record = self.build([])
        self.assertEqual(record["invalid"], "the run ended without a result event")
        self.assertFalse(record["pass"])

    def test_a_run_that_hits_max_turns_fails_even_with_the_right_calls(self):
        record = self.build([{"type": "result", "subtype": "error_max_turns", "result": "", "modelUsage": {}}])
        self.assertIsNone(record["invalid"])
        self.assertFalse(record["pass"])
        self.assertEqual(record["reason"], "run ended with error_max_turns")


class NoInitEvent(unittest.TestCase):
    def test_a_stream_without_init_yields_no_graded_record(self):
        with tempfile.TemporaryDirectory() as d:
            rundir = Path(d)
            success_stream(rundir, init=False)
            fixture = {"lane": "lestrade-sweep", "name": "s", "repo": "o/r", "expect": {"links": []}}
            record = calibrate.build_record("lestrade-sweep", "opus-medium", CELL, fixture, 1, rundir, 0, {"connected": None, "timeout": False}, 1.0)
            self.assertFalse(record["pass"])
            self.assertIn("no init event", record["invalid"])
            self.assertEqual(record["reason"], record["invalid"])

    def test_a_fake_index_that_never_connects_is_invalid_even_when_the_run_times_out(self):
        with tempfile.TemporaryDirectory() as d:
            rundir = Path(d)
            (rundir / "stream.jsonl").write_text("")
            record = calibrate.build_record("lestrade-sweep", "opus-medium", CELL, dict(SWEEP, name="s"), 1, rundir, -9, {"connected": False, "timeout": True}, 1800.0)
            self.assertEqual(record["invalid"], "the fake Index did not connect")
            self.assertEqual(record["reason"], "the fake Index did not connect")
            self.assertNotIn("timed out", record["reason"])

    def test_a_run_that_times_out_before_its_init_event_is_invalid(self):
        with tempfile.TemporaryDirectory() as d:
            rundir = Path(d)
            (rundir / "stream.jsonl").write_text("")
            record = calibrate.build_record("lestrade-sweep", "opus-medium", CELL, dict(SWEEP, name="s"), 1, rundir, -9, {"connected": None, "timeout": True}, 1800.0)
            self.assertIn("no init event", record["invalid"])
            self.assertFalse(record["pass"])

    def test_a_timed_out_run_is_a_failure_not_an_invalid_run(self):
        with tempfile.TemporaryDirectory() as d:
            rundir = Path(d)
            (rundir / "stream.jsonl").write_text("")
            record = calibrate.build_record("lestrade-sweep", "opus-medium", CELL, dict(SWEEP, name="s"), 1, rundir, -9, {"connected": True, "timeout": True}, 1800.0)
            self.assertIsNone(record["invalid"])
            self.assertFalse(record["pass"])
            self.assertIn("timed out", record["reason"])


def report_record(lane, cell, fixture, passed, model, cost=0.5, invalid=None, text=""):
    usage = {model: {"inputTokens": 1000, "outputTokens": 500, "cacheReadInputTokens": 0, "cacheCreationEphemeral5mInputTokens": 0, "cacheCreationEphemeral1hInputTokens": 0}}
    return {
        "lane": lane, "cell": cell, "model": model, "effort": "medium", "fixture": fixture, "run": 1,
        "wall_s": 60.0, "pass": passed, "reason": "ok" if passed else "missed", "invalid": invalid,
        "model_usage": usage, "requests": [], "cli_cost_usd": cost, "result_text": text, "gh_calls": [], "index_calls": [],
    }


def render(records):
    prices = calibrate.parse_prices(PRICES_MD)
    with tempfile.TemporaryDirectory() as d:
        return calibrate.render_report(Path(d), records, prices, datetime(2026, 10, 30, tzinfo=timezone.utc), 0)


class Report(unittest.TestCase):
    record = staticmethod(report_record)
    render = staticmethod(render)

    def test_report_rows_cheapest_line_caveat_and_invalid_runs(self):
        opus, sonnet = "claude-opus-5-5[1m]", "claude-sonnet-5-5"
        blocker = "- claim: x\n  severity: blocker"
        records = [self.record("holmes-lens", "opus-medium", f"f{i}", True, opus, text=blocker) for i in range(3)]
        records += [self.record("holmes-lens", "sonnet-medium", f"f{i}", True, sonnet, text="\n".join([blocker, blocker])) for i in range(3)]
        records.append(self.record("holmes-lens", "sonnet-medium", "f9", False, sonnet, invalid="the fake Index did not connect"))
        records += [self.record("lestrade-sweep", "opus-medium", f"s{i}", True, opus) for i in range(3)]
        report = self.render(records)
        self.assertIn(calibrate.CAVEAT, report)
        opus_cost = (1000 * 4 + 500 * 20) / 1e6
        self.assertIn(f"| opus-medium (baseline) | `{opus}` | medium | 3 | 100% | 1,500 (500) | 60 s | ${opus_cost:.4f} | $0.5000 | 1.0 |", report)
        self.assertIn(f"| sonnet-medium | `{sonnet}` | medium | 3 | 100% |", report)
        self.assertIn("| 2.0 |", report)
        self.assertIn("**Cheapest cell that matches the baseline pass rate: sonnet-medium**", report)
        self.assertEqual(report.count("**Cheapest cell that matches the baseline pass rate:"), 2)
        self.assertIn("## Invalid runs", report)
        self.assertIn("sonnet-medium / f9 #1: the fake Index did not connect", report)

    def test_a_missing_cli_cost_shows_as_unknown(self):
        opus = "claude-opus-5-5[1m]"
        records = [self.record("lestrade-sweep", "opus-medium", f"s{i}", True, opus, cost=None if i == 0 else 0.5) for i in range(3)]
        self.assertIn("| unknown |", self.render(records))


class Selection(unittest.TestCase):
    ORDER = ["base", "low", "cheap", "better", "tie-a", "tie-b"]

    def rows(self, runs=3, **cells):
        return {c: {"runs": runs, "pass_rate": p, "cost": k} for c, (p, k) in cells.items()}

    def pick(self, rows):
        return calibrate.cheapest(rows, "base", self.ORDER)

    def test_picks_the_cheapest_cell_at_or_above_baseline(self):
        self.assertEqual(self.pick(self.rows(base=(0.8, 1.0), low=(0.8, 0.5), cheap=(0.6, 0.1), better=(1.0, 0.7)))[0], "low")

    def test_baseline_wins_when_nothing_cheaper_matches(self):
        self.assertEqual(self.pick(self.rows(base=(1.0, 1.0), cheap=(0.9, 0.1)))[0], "base")

    def test_no_baseline_runs_names_no_cell(self):
        self.assertIsNone(self.pick(self.rows(cheap=(1.0, 0.1)))[0])
        self.assertIsNone(self.pick({"base": {"runs": 0, "pass_rate": 0.0, "cost": 0.0}})[0])

    def test_a_baseline_with_too_few_valid_runs_names_no_cell(self):
        cell, why = self.pick(self.rows(runs=calibrate.MIN_VALID_RUNS - 1, base=(1.0, 1.0)))
        self.assertIsNone(cell)
        self.assertIn(f"fewer than {calibrate.MIN_VALID_RUNS} valid runs", why)

    def test_a_cell_with_too_few_valid_runs_is_not_named(self):
        rows = self.rows(base=(1.0, 1.0))
        rows["cheap"] = {"runs": calibrate.MIN_VALID_RUNS - 1, "pass_rate": 1.0, "cost": 0.1}
        self.assertEqual(self.pick(rows)[0], "base")

    def test_a_zero_pass_baseline_is_no_match(self):
        cell, why = self.pick(self.rows(base=(0.0, 1.0), cheap=(0.0, 0.1)))
        self.assertIsNone(cell)
        self.assertTrue(why.startswith("No match"))

    def test_a_cost_tie_goes_to_the_cell_listed_first(self):
        self.assertEqual(self.pick(self.rows(base=(0.5, 1.0), **{"tie-b": (0.5, 0.2), "tie-a": (0.5, 0.2)}))[0], "tie-a")
        self.assertEqual(self.pick(self.rows(base=(0.5, 1.0), **{"tie-b": (0.5, 0.20001), "tie-a": (0.5, 0.2)}))[0], "tie-a")


class RunSettings(unittest.TestCase):
    def home(self, installed, enabled):
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        home = Path(d.name)
        (home / ".claude" / "plugins").mkdir(parents=True)
        (home / ".claude" / "plugins" / "installed_plugins.json").write_text(json.dumps({"plugins": {p: [] for p in installed}}))
        (home / ".claude" / "settings.json").write_text(json.dumps({"enabledPlugins": enabled}))
        return home

    def test_every_other_known_plugin_is_disabled(self):
        home = self.home(["unifi-network@unifi-plugins", *calibrate.PLUGINS], {"gt7-livery-kit@gt7-livery-kit": True, "cc-plugin-diff@builtin": False})
        enabled = calibrate.run_settings(home)["enabledPlugins"]
        self.assertEqual({p for p, on in enabled.items() if on}, set(calibrate.PLUGINS))
        for plugin in ("unifi-network@unifi-plugins", "gt7-livery-kit@gt7-livery-kit", "cc-plugin-diff@builtin"):
            self.assertIs(enabled[plugin], False)

    def test_a_home_with_no_plugin_files_still_enables_only_the_two(self):
        enabled = calibrate.run_settings(Path(tempfile.gettempdir()) / "no-such-home")["enabledPlugins"]
        self.assertEqual(enabled, {p: True for p in calibrate.PLUGINS})

    def test_the_written_settings_deny_the_routes_an_agent_could_undo_a_pin_by(self):
        with tempfile.TemporaryDirectory() as d:
            rundir = Path(d)
            calibrate.build_cmd("holmes-lens", CELL, rundir, "1", "prompt")
            deny = json.loads((rundir / "settings.json").read_text())["permissions"]["deny"]
        for rule in ("Bash(git push:*)", "Bash(git * push *)", "Bash(git -c:*)", "Bash(git * -c *)",
                     "Bash(git --config-env*)", "Bash(git * --config-env*)", "Bash(git credential*)", "Bash(git * credential*)",
                     "Bash(git-credential*)", "Bash(*/git-credential*)", "Bash(gh auth:*)", "Bash(*/gh auth*)",
                     "Bash(git config*protocol.*)", "Bash(git * config*protocol.*)",
                     "Bash(claude:*)", "Bash(claude)", "Bash(* claude)", "Bash(* claude *)", "Bash(*/claude)", "Bash(*/claude *)"):
            self.assertIn(rule, deny)

    def test_the_deny_rules_match_each_route_past_a_pin(self):
        patterns = [rule[len("Bash("):-1].replace(":*", "*") for rule in calibrate.SETTINGS_DENY]

        def denied(command):
            return any(fnmatch.fnmatchcase(command, pattern) for pattern in patterns)

        for command in (
            "git credential-osxkeychain get",
            "git credential fill",
            "git -C /tmp/x credential-osxkeychain get",
            "/usr/local/libexec/git-core/git-credential-osxkeychain get",
            "git --config-env=credential.helper=H fill",
            "git -C /tmp/x --config-env=protocol.allow=V ls-remote https://github.com/o/r",
            "git -c protocol.allow=always ls-remote https://github.com/o/r",
            "git -C /tmp/x push https://github.com/o/r",
            "gh auth token",
            "/opt/local/bin/gh auth token",
            "git config protocol.https.allow always",
            "git -C /tmp/x config --local protocol.https.allow always",
            "claude -p hello",
            "claude",
            "env FOO=1 claude -p hello",
            "command claude",
            "nohup claude --model x -p hello",
            "cd /tmp/x && claude -p hello",
            "/Users/mike/.local/bin/claude -p hello",
            "~/.local/bin/claude",
        ):
            self.assertTrue(denied(command), command)
        for command in ("git -C /tmp/x log --oneline", "git diff base...head", "gh issue view 1 -R o/r",
                        "git config --get user.name", "ls ~/.claude/plugins", "grep -n claude-opus README.md"):
            self.assertFalse(denied(command), command)


class CostEdges(unittest.TestCase):
    def setUp(self):
        self.prices = calibrate.parse_prices(PRICES_MD)

    def test_a_synthetic_or_empty_request_is_not_priced_and_the_report_renders(self):
        opus = "claude-opus-5-5[1m]"
        records = []
        for i in range(3):
            record = report_record("lestrade-sweep", "opus-medium", f"s{i}", True, opus)
            record["requests"] = [
                {"model": "<synthetic>", "usage": {"input_tokens": 0, "output_tokens": 0}},
                {"model": "<synthetic>", "usage": {"input_tokens": 5, "output_tokens": 5}},
                {"model": "claude-opus-5-5", "usage": {"input_tokens": 0, "output_tokens": 0}},
            ]
            records.append(record)
        self.assertAlmostEqual(calibrate.run_cost(records[0], self.prices), (1000 * 4 + 500 * 20) / 1e6)
        report = render(records)
        self.assertIn("**Cheapest cell that matches the baseline pass rate: opus-medium**", report)

    def test_usage_under_two_keys_of_one_model_is_summed(self):
        usage = {"inputTokens": 1000, "outputTokens": 0, "cacheReadInputTokens": 0}
        record = {"model_usage": {"claude-opus-5-5": usage, "claude-opus-5-5[1m]": usage}, "requests": []}
        self.assertAlmostEqual(calibrate.run_cost(record, self.prices), 2 * 1000 * 4 / 1e6)


class SetupCleanup(unittest.TestCase):
    def run_failing(self, fail_in):
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        out = Path(d.name)
        fixture = calibrate.load_fixtures("holmes-lens")[0]
        rundir = out / "runs" / "holmes-lens" / "opus-medium" / fixture["name"] / "1"

        def prepare(out_, rundir_, fixture_):
            (rundir_ / "checkout" / ".git").mkdir(parents=True)
            (rundir_ / "snapshot.git").mkdir()
            if fail_in == "prepare":
                raise subprocess.CalledProcessError(1, ["git"], stderr="checkout failed")
            return "prompt", {}

        def start(rundir_, fixture_):
            raise calibrate.SafetyError("the fake Index did not start")

        with mock.patch.object(calibrate, "prepare_run", prepare), mock.patch.object(calibrate, "start_index", start):
            with self.assertRaises((calibrate.SafetyError, subprocess.CalledProcessError)):
                calibrate.run_one(out, "holmes-lens", "opus-medium", CELL, fixture, 1)
        return rundir

    def test_a_failed_prepare_leaves_no_clone(self):
        rundir = self.run_failing("prepare")
        self.assertFalse((rundir / "checkout").exists())
        self.assertFalse((rundir / "snapshot.git").exists())

    def test_a_fake_index_that_does_not_start_leaves_no_clone(self):
        rundir = self.run_failing("start")
        self.assertFalse((rundir / "checkout").exists())
        self.assertFalse((rundir / "snapshot.git").exists())


class Fixtures(unittest.TestCase):
    def test_every_lane_has_at_least_five_fixtures_with_a_known_outcome(self):
        for lane in calibrate.load_cells()["lanes"]:
            fixtures = calibrate.load_fixtures(lane)
            self.assertGreaterEqual(len(fixtures), 5, lane)
            for f in fixtures:
                self.assertEqual(f["lane"], lane)
                self.assertTrue(f["known_outcome"].strip(), f["name"])
                self.assertTrue(f["source"], f["name"])

    def test_the_lens_set_holds_a_clean_pr(self):
        clean = [f for f in calibrate.load_fixtures("holmes-lens") if f["expect"].get("no_blockers")]
        self.assertGreaterEqual(len(clean), 1)
        for f in clean:
            self.assertEqual(f["source"]["item_status"], "Done")
            self.assertIn("approved", f["known_outcome"])

    def test_each_item_fixture_history_passes_its_own_grader(self):
        for f in calibrate.load_fixtures("lestrade-item"):
            ok, why = calibrate.grade_item(f, item_calls(criteria=f["held_acceptance_criteria"], fields=f["expect"]["fields"], item_id=f["item_id"]))
            self.assertTrue(ok, f"{f['name']}: {why}")

    def test_each_sweep_fixture_history_passes_its_own_grader(self):
        for f in calibrate.load_fixtures("lestrade-sweep"):
            calls = [("add_blocked_by", {"repo": f["repo"], "issue_number": a, "blocked_by": [b]}) for a, b in f["expect"]["links"]]
            ok, why = calibrate.grade_sweep(f, calls)
            self.assertTrue(ok, f"{f['name']}: {why}")
            numbers = {i["number"] for i in f["github"]["issues"]}
            self.assertEqual(len(numbers), f["source"]["open_issue_count_in_log"], f["name"])
            for link in f["expect"]["links"] + f["expect"].get("optional_links", []):
                self.assertLessEqual(set(link), numbers, f"{f['name']}: {link} names an issue that was not open")

    def test_each_lens_fixture_renders_a_complete_prompt(self):
        for f in calibrate.load_fixtures("holmes-lens"):
            prompt = calibrate.lens_prompt(f, Path("/checkout"))
            self.assertIn("/checkout", prompt)
            self.assertIn(f"Your lens: {f['lens']} — ", prompt)
            self.assertNotIn("<PR_NUM>", prompt)

    def test_grid_is_the_approved_one(self):
        grid = calibrate.load_cells()
        args = argparse.Namespace(lane=None, cell=None, fixture=None, runs=None)
        expected = sum(len(calibrate.load_fixtures(lane)) * len(cells) * 3 for lane, cells in grid["lanes"].items())
        self.assertEqual(len(calibrate.plan(args)), expected)
        self.assertEqual(expected, 177)
        self.assertEqual(grid["cells"][grid["baseline"]], {"model": "claude-opus-5-5[1m]", "effort": "medium"})
        self.assertNotIn("haiku-medium", grid["lanes"]["lestrade-item"])


class InitCheck(unittest.TestCase):
    def test_only_the_fake_index_passes(self):
        self.assertTrue(calibrate.check_init(init_event(tools=["Bash", "mcp__the-index__move"])))

    def test_any_other_server_stops_the_grid(self):
        with self.assertRaises(calibrate.SafetyError):
            calibrate.check_init(init_event(servers=[{"name": "the-index", "status": "connected"}, {"name": "github", "status": "connected"}]))

    def test_a_foreign_mcp_tool_stops_the_grid(self):
        with self.assertRaises(calibrate.SafetyError):
            calibrate.check_init(init_event(tools=["mcp__github__create_issue"]))

    def test_an_unconnected_fake_marks_the_run_invalid(self):
        self.assertFalse(calibrate.check_init(init_event(servers=[{"name": "the-index", "status": "failed"}])))

    def test_an_extra_plugin_stops_the_grid(self):
        with self.assertRaises(calibrate.SafetyError) as stop:
            calibrate.check_init(init_event(plugins=PLUGIN_NAMES + ["unifi-network"]))
        self.assertIn("unifi-network", str(stop.exception))

    def test_a_missing_plugin_stops_the_grid(self):
        with self.assertRaises(calibrate.SafetyError):
            calibrate.check_init(init_event(plugins=["workbench-dev-team"]))


class FakeGh(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        d = Path(self.dir.name)
        fixture = {"repo": "o/r", "github": {"issues": [
            {"number": 1, "title": "One", "body": "b1", "labels": [], "state": "OPEN", "comments": [{"author": {"login": "mike"}, "body": "c1", "createdAt": "2026-01-01T00:00:00Z"}]},
            {"number": 2, "title": "Two", "body": "b2", "labels": [], "state": "CLOSED", "comments": []},
        ], "pulls": []}}
        (d / "fixture.json").write_text(json.dumps(fixture))
        self.env = dict(os.environ, EVAL_GH_DATA=str(d / "fixture.json"), EVAL_GH_LOG=str(d / "log.jsonl"))
        self.log = d / "log.jsonl"

    def tearDown(self):
        self.dir.cleanup()

    def gh(self, *args, env=None):
        return subprocess.run([sys.executable, str(HERE / "fake_gh.py"), *args], env=env or self.env, capture_output=True, text=True)

    def outcomes(self):
        return [json.loads(line)["outcome"] for line in self.log.read_text().splitlines()]

    def test_issue_list_serves_open_issues_with_the_asked_fields(self):
        done = self.gh("issue", "list", "-R", "o/r", "--state", "open", "--json", "number,title", "--limit", "200")
        self.assertEqual(json.loads(done.stdout), [{"number": 1, "title": "One"}])

    def test_issue_view_comments_through_jq(self):
        done = self.gh("issue", "view", "1", "-R", "o/r", "--json", "comments", "--jq", ".comments[].body")
        self.assertEqual(done.stdout.strip(), "c1")
        self.assertEqual(self.outcomes(), ["served"])

    def test_every_write_subcommand_and_write_group_is_refused(self):
        cases = [[group, verb, "1"] for group, verbs in fake_gh.WRITES.items() for verb in sorted(verbs)]
        cases += [[group, "list"] for group in sorted(fake_gh.WRITE_GROUPS)]
        cases += [
            ["api", "graphql", "-f", "query=mutation { closeIssue(input: {issueId: \"x\"}) { clientMutationId } }"],
            ["api", "repos/o/r/issues/1", "--input", "body.json"],
            ["api", "-X", "DELETE", "repos/o/r/issues/1"],
            ["api", "-X", "POST", "repos/o/r/issues/1/comments"],
            ["api", "repos/o/r/issues/1/comments", "-f", "body=x"],
            ["api", "--method=PATCH", "repos/o/r/issues/1"],
        ]
        self.assertGreater(len(cases), 60)
        for args in cases:
            done = self.gh(*args)
            self.assertEqual(done.returncode, 1, args)
            self.assertIn("refused", done.stderr, args)
        self.assertEqual(self.outcomes(), ["refused"] * len(cases))

    def test_another_repo_and_unknown_reads_are_not_served(self):
        self.assertEqual(self.gh("issue", "list", "-R", "o/other").returncode, 1)
        self.assertEqual(self.gh("search", "issues", "x").returncode, 1)
        self.assertEqual(self.gh("issue", "view", "9", "-R", "o/r").returncode, 1)
        self.assertEqual(self.outcomes(), ["unsupported"] * 3)

    def test_api_get_serves_issue_comments(self):
        done = self.gh("api", "repos/o/r/issues/1/comments", "--jq", ".[0].user.login")
        self.assertEqual(done.stdout.strip(), "mike")

    def test_pr_diff_shows_the_fixture_range_for_a_lens_fixture_with_no_issue_data(self):
        repo = Path(self.dir.name) / "repo"
        base, head = make_repo(repo)
        lens = Path(self.dir.name) / "lens.json"
        lens.write_text(json.dumps({"repo": "o/r", "pr": 5}))
        env = dict(self.env, EVAL_GH_DATA=str(lens), EVAL_CHECKOUT=str(repo), EVAL_DIFF_BASE=base, EVAL_DIFF_HEAD=head)
        done = self.gh("pr", "diff", "5", env=env)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("+++ b/b.txt", done.stdout)
        self.assertIn("+added line", done.stdout)
        self.assertNotIn("a.txt", done.stdout)
        self.assertEqual(self.gh("pr", "diff", "5", "--name-only", env=env).stdout, "b.txt\n")
        self.assertEqual(self.outcomes(), ["served", "served"])

    def test_repo_clone_copies_the_local_snapshot(self):
        source = Path(self.dir.name) / "src"
        make_repo(source)
        target = Path(self.dir.name) / "clone"
        done = self.gh("repo", "clone", "o/r", str(target), "--", "--depth", "1", env=dict(self.env, EVAL_CLONE_FROM=str(source)))
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual((target / "b.txt").read_text(), "added line\n")
        self.assertEqual(self.gh("repo", "clone", "o/other", str(target) + "2", env=dict(self.env, EVAL_CLONE_FROM=str(source))).returncode, 1)


class FakeIndexHandshake(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        d = Path(self.dir.name)
        scenario = {"tools_list": [{"name": "find_item"}], "tools": {"find_item": {"byArg": "issue_number", "answers": {"5": {"result": {"id": 50}}}, "default": {"result": {"found": False}}}}}
        (d / "scenario.json").write_text(json.dumps(scenario))
        self.proc = subprocess.Popen([sys.executable, str(calibrate.FAKE_INDEX), str(d / "scenario.json"), str(d / "log.jsonl"), str(d / "port")])
        for _ in range(100):
            if (d / "port").exists():
                break
            time.sleep(0.05)
        self.url = f"http://127.0.0.1:{(d / 'port').read_text()}/mcp"

    def tearDown(self):
        self.proc.kill()
        self.proc.wait()
        self.dir.cleanup()

    def post(self, body):
        request = urllib.request.Request(self.url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(request) as reply:
            return reply.status, reply.read().decode()

    def test_initialize_and_tools_list(self):
        status, body = self.post({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}})
        self.assertEqual(json.loads(body)["result"]["protocolVersion"], "2025-06-18")
        status, body = self.post({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        self.assertEqual(json.loads(body)["result"]["tools"], [{"name": "find_item"}])

    def test_notification_gets_202_and_no_body(self):
        self.assertEqual(self.post({"jsonrpc": "2.0", "method": "notifications/initialized"}), (202, ""))

    def test_answer_by_argument(self):
        def call(n):
            _, body = self.post({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "find_item", "arguments": {"issue_number": n}}})
            return json.loads(json.loads(body)["result"]["content"][0]["text"])
        self.assertEqual(call(5), {"id": 50})
        self.assertEqual(call(6), {"found": False})


if __name__ == "__main__":
    unittest.main()
