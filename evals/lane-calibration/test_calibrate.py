import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request
from pathlib import Path
from unittest import mock

import calibrate

HERE = Path(__file__).resolve().parent

PRICES_MD = """
| Model | Base input tokens | 5m cache writes | 1h cache writes | Cache hits and refreshes | Output tokens |
| :---- | :---- | :---- | :---- | :---- | :---- |
| Claude Opus 5.5 | $4 / MTok | $5 / MTok | $8 / MTok | $0.20 / MTok<sup>2</sup> | $20 / MTok |
| Claude Opus 4.1 ([retired](https://example.com/x)) | $15 / MTok | $18.75 / MTok | $30 / MTok | $1.50 / MTok | $75 / MTok |
| Claude Haiku 5.5 (for prompts up to 100,000 tokens) | $0.10 / MTok | $0.125 / MTok | $0.20 / MTok | $0.01 / MTok | $0.50 / MTok |
| Claude Haiku 5.5 (for prompts over 100,000 tokens) | $0.50 / MTok | $0.625 / MTok | $1 / MTok | $0.05 / MTok | $2.50 / MTok |
| Concept | Details |
"""

LENS = {"lane": "holmes-lens", "expect": {"any_of": [["StructuredText", "preg"], ["__construct", "file.scope"]]}}
SWEEP = {"lane": "lestrade-sweep", "repo": "o/r", "expect": {"links": [[2, 1], [3, 1]], "optional_links": [[3, 2]]}}
ITEM = {
    "lane": "lestrade-item", "item_id": 7,
    "expect": {"move": "Backlog", "fields": ["Size", "Priority"], "ac_anchors": ["tests/Unit", "testDirectory"]},
}
GOOD_AC = "- [ ] A test in tests/Unit counts.\n- [ ] A custom testDirectory keeps the old result."


def item_calls(criteria=GOOD_AC, fields=("Size", "Priority"), moves=("Backlog",), item_id=7):
    calls = [("get_item", {"id": item_id}), ("set_acceptance_criteria", {"id": item_id, "agent": "lestrade", "criteria": criteria})]
    calls.append(("update_fields", {"id": item_id, "agent": "lestrade", "fields": {f: 1 for f in fields}}))
    calls += [("move", {"id": item_id, "agent": "lestrade", "column": m}) for m in moves]
    return calls


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
            calibrate.price_row(self.prices, "claude-sonnet-5-5", 0)
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
        self.assertTrue(calibrate.grade_sweep({"repo": "o/r", "expect": {"links": []}}, [("find_item", {})])[0])


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


class Fixtures(unittest.TestCase):
    def test_every_lane_has_five_fixtures_with_a_known_outcome(self):
        for lane in calibrate.load_cells()["lanes"]:
            fixtures = calibrate.load_fixtures(lane)
            self.assertEqual(len(fixtures), 5, lane)
            for f in fixtures:
                self.assertEqual(f["lane"], lane)
                self.assertTrue(f["known_outcome"].strip(), f["name"])
                self.assertTrue(f["source"], f["name"])

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
        args = type("A", (), {"lane": None, "cell": None, "fixture": None, "runs": None})()
        self.assertEqual(len(calibrate.plan(args)), 165)
        self.assertEqual(grid["cells"][grid["baseline"]], {"model": "claude-opus-5-5[1m]", "effort": "medium"})
        self.assertNotIn("haiku-medium", grid["lanes"]["lestrade-item"])


class Selection(unittest.TestCase):
    def rows(self, **cells):
        return {c: {"runs": 3, "pass_rate": p, "cost": k} for c, (p, k) in cells.items()}

    def test_picks_the_cheapest_cell_at_or_above_baseline(self):
        rows = self.rows(base=(0.8, 1.0), low=(0.8, 0.5), cheap=(0.6, 0.1), better=(1.0, 0.7))
        self.assertEqual(calibrate.cheapest(rows, "base"), "low")

    def test_baseline_wins_when_nothing_cheaper_matches(self):
        self.assertEqual(calibrate.cheapest(self.rows(base=(1.0, 1.0), cheap=(0.9, 0.1)), "base"), "base")

    def test_no_baseline_runs_names_no_cell(self):
        self.assertIsNone(calibrate.cheapest(self.rows(cheap=(1.0, 0.1)), "base"))
        self.assertIsNone(calibrate.cheapest({"base": {"runs": 0, "pass_rate": 0.0, "cost": 0.0}}, "base"))


class HarnessFailure(unittest.TestCase):
    def run_grid(self, error):
        def fail(*args):
            raise error

        with tempfile.TemporaryDirectory() as d, \
                mock.patch.object(calibrate, "run_one", fail), \
                mock.patch.object(calibrate, "cmd_report", lambda args: 0), \
                mock.patch.object(calibrate.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "claude 0", "")):
            args = argparse.Namespace(lane=["lestrade-sweep"], cell=["opus-medium"], fixture=["clean-code-no-links"], runs=2, jobs=1, out=f"{d}/out", confirm=True)
            code = calibrate.cmd_run(args)
            return code, calibrate.read_jsonl(Path(d) / "out" / "results.jsonl")

    def test_a_failed_step_is_an_invalid_run_and_the_grid_goes_on(self):
        code, records = self.run_grid(subprocess.CalledProcessError(128, ["git"], stderr="fatal: no such ref"))
        self.assertEqual(code, 0)
        self.assertEqual(len(records), 2)
        self.assertTrue(all(r["invalid"] == "the harness failed: fatal: no such ref" and not r["pass"] for r in records))

    def test_a_safety_stop_ends_the_grid_with_nothing_recorded(self):
        code, records = self.run_grid(calibrate.SafetyError("foreign MCP server"))
        self.assertEqual(code, 2)
        self.assertEqual(records, [])


class InitCheck(unittest.TestCase):
    def test_only_the_fake_index_passes(self):
        event = {"mcp_servers": [{"name": "the-index", "status": "connected"}], "tools": ["Bash", "mcp__the-index__move"]}
        self.assertTrue(calibrate.check_init(event))

    def test_any_other_server_stops_the_grid(self):
        event = {"mcp_servers": [{"name": "the-index", "status": "connected"}, {"name": "github", "status": "connected"}], "tools": []}
        with self.assertRaises(calibrate.SafetyError):
            calibrate.check_init(event)

    def test_a_foreign_mcp_tool_stops_the_grid(self):
        event = {"mcp_servers": [{"name": "the-index", "status": "connected"}], "tools": ["mcp__github__create_issue"]}
        with self.assertRaises(calibrate.SafetyError):
            calibrate.check_init(event)

    def test_an_unconnected_fake_marks_the_run_invalid(self):
        self.assertFalse(calibrate.check_init({"mcp_servers": [{"name": "the-index", "status": "failed"}], "tools": []}))


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

    def test_write_verbs_are_refused(self):
        for args in (["issue", "comment", "1", "-R", "o/r", "-b", "x"], ["pr", "merge", "3"], ["issue", "edit", "1", "--add-label", "x"],
                     ["api", "-X", "POST", "repos/o/r/issues/1/comments"], ["api", "repos/o/r/issues/1/comments", "-f", "body=x"],
                     ["api", "--method=PATCH", "repos/o/r/issues/1"], ["repo", "delete", "o/r"], ["auth", "token"]):
            done = self.gh(*args)
            self.assertEqual(done.returncode, 1, args)
            self.assertIn("refused", done.stderr, args)
        self.assertEqual(set(self.outcomes()), {"refused"})

    def test_another_repo_and_unknown_reads_are_not_served(self):
        self.assertEqual(self.gh("issue", "list", "-R", "o/other").returncode, 1)
        self.assertEqual(self.gh("search", "issues", "x").returncode, 1)
        self.assertEqual(self.gh("issue", "view", "9", "-R", "o/r").returncode, 1)
        self.assertEqual(self.outcomes(), ["unsupported"] * 3)

    def test_api_get_serves_issue_comments(self):
        done = self.gh("api", "repos/o/r/issues/1/comments", "--jq", ".[0].user.login")
        self.assertEqual(done.stdout.strip(), "mike")

    def test_pr_diff_serves_a_lens_fixture_that_has_no_issue_data(self):
        lens = Path(self.dir.name) / "lens.json"
        lens.write_text(json.dumps({"repo": "o/r", "pr": 5}))
        head = subprocess.run(["git", "-C", str(calibrate.ROOT), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
        env = dict(self.env, EVAL_GH_DATA=str(lens), EVAL_CHECKOUT=str(calibrate.ROOT), EVAL_DIFF_BASE=head, EVAL_DIFF_HEAD=head)
        done = self.gh("pr", "diff", "5", "--name-only", env=env)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(self.outcomes(), ["served"])

    def test_repo_clone_copies_the_local_snapshot(self):
        source = Path(self.dir.name) / "src"
        subprocess.run(["git", "init", "-q", str(source)], check=True)
        (source / "f.txt").write_text("x")
        subprocess.run(["git", "-C", str(source), "add", "f.txt"], check=True)
        subprocess.run(["git", "-C", str(source), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"], check=True)
        target = Path(self.dir.name) / "clone"
        done = self.gh("repo", "clone", "o/r", str(target), "--", "--depth", "1", env=dict(self.env, EVAL_CLONE_FROM=str(source)))
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual((target / "f.txt").read_text(), "x")
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
