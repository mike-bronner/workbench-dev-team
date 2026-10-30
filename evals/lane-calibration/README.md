# Lane calibration

This eval tests whether a cheaper model or effort setting gets the same result
as the pinned `claude-opus-5-5[1m]` at `medium`. It covers three lanes:
`holmes-lens`, `lestrade-sweep` and `lestrade-item`. It changes no agent file
and no setting. You read the report and decide.

## Run it

```bash
python3 evals/lane-calibration/calibrate.py run              # print the plan, spend nothing
python3 evals/lane-calibration/calibrate.py run --confirm    # the full grid
python3 evals/lane-calibration/calibrate.py report <out dir> # rebuild a report
```

`run --confirm` runs every cell of `cells.json` against every fixture, three
times each: 165 agent runs. Narrow it with `--lane`, `--cell` and `--fixture`,
each repeatable, and with `--runs N`. `--jobs N` runs N agents at once. Each
run has its own fake servers and folders, so parallel runs do not share
state.

Results go to `~/Developer/scratchpad/lane-calibration/<stamp>/`, or to
`--out`:

- `results.jsonl` holds one line per run: pass or fail and why, tokens per
  model, wall time, Claude Code's own cost, every Index call and every `gh`
  call.
- `report.md` holds the report.
- `runs/<lane>/<cell>/<fixture>/<n>/` holds each run's stream, logs and
  fixture.

The run deletes the repository clones it made when it finishes. It keeps the
results.

Do not put `run --confirm` in CI or a schedule. The full grid costs real money
on every run. `test-lane-calibration.sh` is the only part of this folder the
suite runs, and it calls no model.

## The grid

`cells.json` holds the grid. The baseline is `opus-medium`. Every lane also
runs `opus-low` and `sonnet-medium`. `holmes-lens` and `lestrade-sweep` also
run `haiku-medium`. Each run passes `--model` and `--effort` on the command
line, so the cell overrides the agent's frontmatter and leaves the file as it
is. `holmes-lens` has no pin of its own, so this is the only way it gets a
model.

## What the report gives

For each lane, one table row per cell: valid runs, pass rate, mean tokens
(output tokens in brackets), mean wall time, mean cost at live prices, and
Claude Code's own cost figure as a cross-check. Under the table, the report
names the cheapest cell whose pass rate is at least the baseline's. The
report also lists passes per fixture, why each failed run failed, and any
invalid run.

**Prices are read live** from
`https://platform.claude.com/docs/en/about-claude/pricing.md` each time a
report is built. The report names the page and the time it read it. A model
the page has no row for stops the report, rather than leaving the run
unpriced. Haiku 5.5 has a higher rate for prompts over 100,000 tokens, so the
eval prices each request from its own prompt size.

## Fixtures

Each fixture is a closed item on The Index, with the outcome that actually
happened. Each one records its source: the item, the issue, and the log,
review or note the outcome came from.

| Lane | Known outcome | Pass when |
|---|---|---|
| `holmes-lens` | A Holmes rejection with a review-learnings note, at the commit Holmes reviewed | A `blocker` finding matches every pattern of one `expect.any_of` group |
| `lestrade-sweep` | The blocked-by links a scheduled sweep set, from its log | The `add_blocked_by` links hold every required link and nothing outside `links` and `optional_links`, with no consolidation write |
| `lestrade-item` | Lestrade's AC that Holmes approved on the first review, from the AC comment | The last AC write is a checklist that matches every `ac_anchors` pattern, all six WSJF fields are set, and the last move is to `Backlog`, with no escalation |

Each pattern is a case-insensitive regular expression. A test checks that each
item fixture's historical AC passes its own anchors, and that each sweep
fixture's historical links pass its own grader.

**Caveat: a wrong historical outcome counts as correct.** Nobody re-checked
the verdicts, links or AC. A cell that disagrees with history can be the
better one. The report states this too.

The replayed state is rebuilt, not recorded:

- A sweep fixture holds the issues that were open when the sweep ran, and only
  the comments made before it. Each fixture's count matches the count its
  sweep log reports.
- Issue titles, bodies and labels are today's. An edit made after the
  historical run shows in the replay.
- A lens fixture checks out the reviewed commit, and diffs it against its
  merge base with the default branch at review time.
- An item fixture is the item's `get_item` reply with its status cleared, plus
  the issue and its comments from before triage. Its clone is the default
  branch at triage time.

## How a run is kept from writing

- **The Index.** Each run starts with `--strict-mcp-config` and one MCP server,
  `the-index`, which is `tests/fake-index.py` on `127.0.0.1`. It serves the
  live Index's tool list from `index-tools.json`, answers from the fixture,
  and logs every call. Those logged write calls are the graded output. As a
  backstop, the harness reads the init event each run prints when it starts.
  If any other MCP server or MCP tool loaded, it kills the run and stops the
  grid.
- **GitHub.** A fake `gh` comes first on `PATH`. It serves the reads the lanes
  make from the fixture, refuses every write subcommand and every non-GET
  `gh api` call, and logs each call. `GH_TOKEN` is set to a value GitHub
  refuses, and `GH_CONFIG_DIR` points at an empty folder, so the real `gh`
  has no credentials either.
- **git.** System and global git config are off, so no credential helper
  loads. SSH is set to fail. Each clone's remote is a local folder.
- **Tools.** The run denies `WebFetch`, `WebSearch`, `curl`, `wget` and
  `security`, plus the tools `bin/dispatch-agent.sh` denies to every pipeline
  run.

The report counts the Index writes the fake logged and the `gh` writes the
fake refused. Both numbers say what was attempted. Neither reached a real
system.

## What differs from production

- The runs use the agents of the installed plugin, as the scheduled pipeline
  does. The lens prompt comes from this repository's
  `references/holmes/review-phases.md`, filled in for one lens.
- No memory MCP loads, so Lestrade's `feedback/` search finds nothing.
- `find_item` in a sweep replay answers with made-up item IDs.
- Each run sets `WORKBENCH_DEV_TEAM_PIPELINE=1` and caps spend at $10, as a
  scheduled run does. A run that hits the cap, or runs past 30 minutes, fails.

## The fake Index

The eval uses three things in `tests/fake-index.py` that the dispatch tests do
not:

- `initialize` and `tools/list` answers, and HTTP 202 for a notification, so
  `claude -p` can connect to it as an HTTP MCP server.
- A `tools_list` scenario key: the reply to `tools/list`.
- An answer of the form
  `{"byArg": "<argument>", "answers": {"<value>": answer}, "default": answer}`,
  which picks the answer by the call's argument value.
