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
times each: 177 agent runs. Narrow it with `--lane`, `--cell` and `--fixture`,
each repeatable, and with `--runs N`. `--jobs N` runs N agents at once. Each
run has its own fake servers and folders, so parallel runs do not share
state.

If `GH_TOKEN` or `GITHUB_TOKEN` is set in the shell, `run --confirm` refuses to
start. Start a new shell without the token, rather than running `unset` in this
one, because `ps eww` still shows a token the shell received when it started.

Results go to `~/Developer/scratchpad/lane-calibration/<stamp>/`, or to
`--out`:

- `results.jsonl` holds one line per run: pass or fail and why, tokens per
  model, wall time, Claude Code's own cost, every Index call and every `gh`
  call.
- `report.md` holds the report.
- `runs/<lane>/<cell>/<fixture>/<n>/` holds each run's stream, logs, settings
  and fixture.

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
Claude Code's own cost figure as a cross-check. The `holmes-lens` table also
gives the mean number of blocker findings per run, so a cell that passes by
flagging everything shows up. Under each table, the report names the cheapest
cell whose pass rate is at least the baseline's. It also lists passes per
fixture, why each failed run failed, and every invalid run.

The selection rules:

- A cell needs at least 3 valid runs to be named, and so does the baseline.
- When the baseline passes no run, the report names no cell, because nothing
  can be shown to match it.
- A cost tie, to four decimal places, goes to the cell listed first in
  `cells.json`.
- An invalid run counts toward neither the pass rate nor the cost. A run is
  invalid when it printed no init event, its fake Index did not connect, it
  ended without a result, or the harness itself failed.
- The invalid rules come first. A run that times out before it prints its init
  event is invalid, not failed, because its MCP servers and plugins were never
  checked, and the model never started work the eval could grade. A run whose
  fake Index did not connect is invalid even if it also timed out.
- A run that passes its init event and then times out after 30 minutes is a
  failure, not an invalid run. It costs what its streamed requests cost, which
  can be less than it billed.
- A run that ends with any result other than success, such as
  `error_max_turns` or a budget stop, is a failure, even when its Index calls
  were right.
- A streamed request is priced only when its model is a `claude-` model and it
  used tokens. Usage the run billed under two names of one model, such as
  `claude-opus-5-5` and `claude-opus-5-5[1m]`, is added together.
- A run whose output cannot be graded, such as a non-numeric issue number, is
  a failure that says why.
- When any run of a cell has no Claude Code cost figure, that column reads
  "unknown".

**Prices are read live** from
`https://platform.claude.com/docs/en/about-claude/pricing.md` each time a
report is built. The report names the page and the time it read it. A failed
read, or a model the page has no row for, stops the report, rather than
leaving a run unpriced. Haiku 5.5 has a higher rate for prompts over 100,000
tokens, so the eval prices each request from its own prompt size.

## Fixtures

Each fixture is a closed item on The Index, with the outcome that actually
happened. Each one records its source: the item, the issue, and the log,
review or note the outcome came from.

| Lane | Known outcome | Pass when |
|---|---|---|
| `holmes-lens` | A Holmes rejection with a review-learnings note, at the commit Holmes reviewed | A `blocker` finding matches every pattern of one `expect.any_of` group |
| `holmes-lens`, clean | A PR Holmes approved on the first review (`expect.no_blockers`) | The report holds no `blocker` finding, and is either "no findings" or structured findings |
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

The layers fall into two groups. A layer that **holds** cannot be undone by
an agent that types commands on purpose, because the agent has no command
that reaches it. A layer that is **best-effort** stops the commands the lanes
would type by accident, but an agent that sets out to get past it can. The
offline tests check every layer in both groups as the harness builds it.

### Layers that hold

- **No GitHub token exported to the eval.** `run --confirm` refuses to start
  when `GH_TOKEN` or `GITHUB_TOKEN` is set in its own environment. So neither
  token is in the harness process or any run. Other processes of yours,
  including the shell that launched the harness, are not covered: see the
  starting-environment layer below.
- **No git remote or push URL points at GitHub.** The harness clones each
  repository once, then removes its remote. It fetches commits by URL with
  `--no-write-fetch-head`, so no `FETCH_HEAD` keeps the URL. No file in the
  mirror, a lens checkout or an item snapshot holds the URL it was fetched
  from. Every checkout and clone a run sees has a local folder as its remote,
  and the lens checkout's push URL is a placeholder. The run folder's
  `fixture.json` still holds `github.com` URLs in issue and review links, as
  text.

### Best-effort layers, and the routes past each one

Each of these is a default, a check of the run's own start, or a rule that
matches command text. Every rule here matches the text of a command, so any
spelling the rules do not match gets past them: an absolute path, a wrapper
such as `command`, `env` or `xargs`, quoting, `sh -c`, a script, or an
interpreter. The offline deny test models the rules with Python's
`fnmatch.fnmatchcase`. It does not run Claude Code's own matcher.

- **The Index MCP route, settings and plugins, and the init check.** These
  three hold for the run the harness starts:
  - Its MCP configuration is fixed at the start: `--strict-mcp-config`, and
    one server, `the-index`, which is `tests/fake-index.py` on `127.0.0.1`. It
    serves the live Index's tool list from `index-tools.json`, answers from
    the fixture, and logs every call. Those logged write calls are the graded
    output.
  - It loads no user or local settings (`--setting-sources project`, in an
    empty folder). Its only settings come from the `settings.json` the harness
    writes into the run folder. That file enables `workbench-dev-team` and
    `workbench-core`, and disables every other plugin the harness can find:
    those in `~/.claude/plugins/installed_plugins.json` and those named in
    your user settings, built-in plugins included. The harness reads those two
    files and changes neither.
  - The harness reads the init event the run prints when it starts. If any MCP
    server other than the fake Index loaded, any MCP tool from another server,
    or any plugin set other than the two workbench plugins, it kills the run
    and stops the grid. This also catches a plugin installed later that the
    settings file did not know to disable. A run that prints no init event is
    invalid.

  Route past all three: the agent starts a second `claude` from Bash. That
  nested run reads your real `~/.claude.json` and user settings, so it gets
  the real Index MCP, your plugins and your login, and its init event never
  reaches the harness. The run's settings deny `claude` by name, after an
  option or a command such as `env` or `nohup` (`* claude`, `* claude *`), and
  by any path that ends in `claude` (`*/claude`, `*/claude *`). Any spelling
  these rules do not match gets past them, such as an absolute path, a wrapper
  such as `command`, `env` or `xargs`, quoting, `sh -c`, a script, or an
  interpreter. Among them: the versioned binary itself at
  `~/.local/share/claude/versions/<version>`, whose path does not end in
  `claude`; a separator with no space before `claude` (`;claude` or
  `$(claude ...)`); and a subprocess started from Python or Node. The eval
  does not isolate `HOME` or `CLAUDE_CONFIG_DIR`, by choice.

- **The rest of the starting environment.** The run inherits no `GIT_*`,
  `GH_*` or `GITHUB_*` variable from the shell that starts it, and no
  `SSH_AUTH_SOCK` or `SSH_ASKPASS`. The harness sets the few it needs itself,
  and none of them holds a credential: `GH_TOKEN` holds a value GitHub
  refuses. No Index token is passed to the run. Route past it: `ps eww -p
  <pid>` prints the full environment of the harness's Python process and of
  the shell that launched it. That shows anything the run did not inherit,
  such as `SSH_AUTH_SOCK`, which the ssh agent then answers on. `ps eww`
  works on any other process of yours too, such as a terminal or another
  session, and shows whatever token that process exported. If the shell
  received a token when it started, `unset` does not hide it from `ps eww`.
  Starting a new shell without the token does. No rule denies `ps`.
- **The fake `gh`.** It comes first on `PATH`. It serves the reads the lanes
  make from the fixture, and refuses every write subcommand, every call into
  a command group that can write (such as `gh workflow` or `gh secret`, reads
  included), and every `gh api` call that is not a plain GET, GraphQL
  included. Routes past it:
  - Run the real `gh` by a path other than `/usr/bin`, `/bin`,
    `/opt/homebrew/bin` and `/usr/local/bin`. Those four paths are denied by
    rule. Any spelling the rules do not match gets past them, such as an
    absolute path, a wrapper such as `command`, `env` or `xargs`, quoting,
    `sh -c`, a script, or an interpreter.
  - Unset `GH_TOKEN` and `GH_CONFIG_DIR` first. The real `gh` then finds its
    stored login in `~/.config/gh` and the Keychain.
  - Print the stored token with `gh auth token`. `gh auth` is denied by rule,
    by name and by any path, and any spelling those rules do not match gets
    past them.
- **The git pins.** The run's environment turns system and global git config
  off, sets an empty `credential.helper` (which also clears the Keychain
  helper Apple's Xcode git sets), allows only the `file` transport, and makes
  SSH fail. The transport pin sets `protocol.allow=never` and also
  `protocol.<name>.allow=never` for `https`, `http`, `ssh` and `git`, because
  a per-protocol key outranks `protocol.allow`. These are environment values,
  and the rules that guard them match text, so any spelling the rules do not
  match gets past them, such as an absolute path, a wrapper such as
  `command`, `env` or `xargs`, quoting, `sh -c`, a script, or an interpreter.
  Routes past them:
  - Write a per-protocol key, such as `git config protocol.https.allow always`,
    into the work repository's local `.git/config`. While the environment pins
    hold, they outrank it, so this works only together with a route below that
    removes them. Rules deny `git config*protocol.*` and
    `git * config*protocol.*`.
  - Set `GIT_SSH_COMMAND=ssh` inline in front of a git command. That replaces
    the `false` pin, so git can use your `~/.ssh` keys, once the `ssh`
    transport is also reopened by a route below. No rule denies the inline
    assignment, because the line starts with the variable, not with `ssh`.
  - Override them with `git -c` or `git --config-env`, which outrank the
    environment. Both are denied by rule, in the forms `git -c`,
    `git * -c *`, `git --config-env*` and `git * --config-env*`.
  - Set `GIT_CONFIG_COUNT` with `GIT_CONFIG_KEY_<n>` and
    `GIT_CONFIG_VALUE_<n>`, or `GIT_CONFIG_PARAMETERS`, inline in front of a
    git command. No rule denies this.
  - Remove them with `unset`, `env -u` or `env -i`, or point
    `GIT_CONFIG_GLOBAL` at another file. No rule denies these.
- **Git credentials.** A credential helper reads the GitHub login from the
  Keychain without the `security` command. The empty `credential.helper` pin
  does not stop a direct call, because git runs the helper from its own
  exec-path and `HOME` is real. The calls are `git credential-osxkeychain get`
  and `git credential fill`, or the helper binary itself. Rules deny
  `git credential*` and `git * credential*`, which catch both
  `credential-<helper>` and `credential fill`, and `git-credential*` by name
  and under any path. Any spelling these rules do not match gets past them,
  such as an absolute path, a wrapper such as `command`, `env` or `xargs`,
  quoting, `sh -c`, a script, or an interpreter.
- **Pushes.** The run's settings deny `git push` in every spelling the rules
  can match (`git push`, `git * push`, `git * push *`). Any spelling these
  rules do not match gets past them, such as an absolute path, a wrapper such
  as `command`, `env` or `xargs`, quoting, `sh -c`, a script, an interpreter,
  or a git alias. The run does not load your own ask rules for pushes, so
  these deny rules replace them. workbench-core's guards load in each run, but
  the run sets `WORKBENCH_DEV_TEAM_PIPELINE=1`, which lets the pipeline push,
  so they are not counted here.
- **Network commands.** The run denies `curl`, `wget`, `security`, `nc`, `ssh`
  and `scp`, by name and under the four paths above, plus `WebFetch`,
  `WebSearch`, and the tools `bin/dispatch-agent.sh` denies to every pipeline
  run. Any spelling these rules do not match gets past them, such as an
  absolute path, a wrapper such as `command`, `env` or `xargs` (for example
  `command curl` or `xargs curl`), quoting, `sh -c`, a script, or an
  interpreter such as Python or Node. Network tools outside the deny list are
  a route too, such as `socat`, `openssl s_client`, `rsync`, `sftp` and
  `osascript`.
- **The Keychain.** `security` is denied by rule, which also keeps The Index's
  client secret out of reach. Any spelling the rule does not match gets past
  it, such as an absolute path, a wrapper such as `command`, `env` or `xargs`,
  quoting, `sh -c`, a script, or an interpreter. The routes above that reach
  the Keychain without `security` (the real `gh`, the git credential helpers)
  are another way past it.

The report counts the Index writes the fake logged and the `gh` writes the
fake refused. Both numbers say what was attempted through the fakes. A write
made through one of the routes above would not appear in either count.

## What differs from production

- The runs use the agents of the installed plugin, as the scheduled pipeline
  does. The lens prompt comes from this repository's
  `references/holmes/review-phases.md`, filled in for one lens.
- Your plugin settings in `/config` are not loaded, so each plugin row takes
  its default, such as the model of Lestrade's helper lenses.
- No memory MCP loads, so Lestrade's `feedback/` search finds nothing.
- `find_item` in a sweep replay answers with made-up item IDs.
- Each run sets `WORKBENCH_DEV_TEAM_PIPELINE=1` and caps spend at $10, as a
  scheduled run does. A run that hits the cap fails.

## The fake Index

The eval uses three things in `tests/fake-index.py` that the dispatch tests do
not:

- `initialize` and `tools/list` answers, and HTTP 202 for a notification, so
  `claude -p` can connect to it as an HTTP MCP server.
- A `tools_list` scenario key: the reply to `tools/list`.
- An answer of the form
  `{"byArg": "<argument>", "answers": {"<value>": answer}, "default": answer}`,
  which picks the answer by the call's argument value.
