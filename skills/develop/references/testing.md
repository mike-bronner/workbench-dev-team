# Testing — the §4 rules that need more than a bullet

The skill's §4 states each rule. This file carries the reasons and the detail
for three of them: the test tier, mutation testing, and the doc-drift grep.

## Write each test at the lowest tier that can prove the behavior

Prefer a unit test to a feature test, and a feature test to an integration
test. The three tiers:

- **Unit** — the code under test, called directly in the test's own process.
  A function, a class, or a small shell pipeline fed fixture input.
- **Feature** — the application driven from its own surface, through the
  framework it boots: an HTTP route, a component, a command, a queued job. A
  database query alone does not make a test a feature test. The boundary is the
  application's surface, not the infrastructure under it.
- **Integration** — real processes, the network, or the OS: spawning a script
  end to end, starting a server or an HTTP stand-in, running an install block,
  calling a live service.

**Why.** Each tier up boots more: the framework, then processes, the network,
and the OS. So each tier up costs more per assertion, runs slower, and breaks
more often because of its environment rather than the code. A higher-tier test
earns that cost only by crossing a boundary the tier below cannot reach.

**Name the boundary.** A feature or integration test names the boundary a lower
tier cannot reach, such as "the route's middleware" or "the exit code the
shell sees". Put it in the test's name or description string, and in your
report or PR body. Do not write a code comment for it: §3's no-comments rule
still holds.

**How to choose.** Start at the unit tier and ask what it cannot prove. Move up
one tier only for that part. A setup script whose behavior is one small
pipeline gets a unit test of that pipeline with fixture input. It does not get
a test that runs the whole install block or starts a local HTTP stand-in,
unless the install or the HTTP exchange is itself the behavior. A regression
test for a bug first seen at a high tier goes at the lowest tier that still
fails without the fix.

**Upstream guidance that says otherwise.** Some projects load guidance that
prefers a higher tier, such as Laravel Boost's "most tests should be feature
tests". The house rule wins. State the departure in your report or PR body, so
the reader sees that you chose the lower tier on purpose and did not miss the
upstream line.

**Scope.** The rule applies to the tests you write. Do not rewrite existing
higher-tier tests to a lower tier as part of another change. That is its own
change, and the human decides it.

## Mutation-test your own tests

For every test that guards a behavior, delete or invert the guarded code and
confirm the test goes red. A test that stays green when its target breaks is
theater: it asserts trivia or the wrong thing. Rewrite it until it
discriminates. This is the cheapest defense against the most common review
rejection, tests that do not actually test.

Never restore a mutation with `git checkout`, `git restore`, or `git stash`.
Each one reverts the whole file or tree to the last commit, and in an
uncommitted change that erases your own work along with the mutation. Undo the
mutation by hand, then read your final diff and confirm no mutation is left in
it.

## Grep for every symbol or claim your diff changed

Renamed a symbol, changed a documented behavior, altered a contract or a type
signature? Search with `grep` or `rg` for every reference, in code, comments,
the README, and docs, and fix each one in the same change. A stale reference
that no test catches is a silent regression for the next reader.
