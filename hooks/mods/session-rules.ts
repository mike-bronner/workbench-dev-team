// workbench-dev-team's session rules in the system prompt, as one
// prompt.compose section.
//
// They used to reach a session as this plugin's session-warmup.md, which
// workbench-core's warmup spliced into ~/.claude/CLAUDE.md, and which core's
// prompt rules (its hooks/mods/prompt-rules.ts) then read from the installed
// copy into its `workbench-core:plugins` section. That file is retired: the
// rules are stated once, here, and this plugin sends them itself, so they reach
// a session that loads the plugin with --plugin-dir as well as an installed
// one. With no session-warmup.md at this plugin's root, core's reader finds
// nothing to send, and the rules are not sent twice.
//
// The section is `shared`: the same bytes in every session, so the cache that
// holds it is read, not created, from the second session on. It holds no date,
// count, version, session id or path read from the machine.
//
// Who gets it, as core's lanes give its plugin section:
//   main    the main loop of a session, interactive or `claude -p`
//   agent   a top-level `claude -p --agent` run (CLAUDE_CODE_AGENT)
//   none    a run with WORKBENCH_SKIP_WARMUP=1 (core's summary-writer), which
//           runs with no rules on purpose
// A sub-agent's system prompt is its own, so it gets the rules as context at
// SubagentStart, unless it is a fork, which inherits the parent's prompt and
// the section with it, or its type leaves CLAUDE.md out (isRulesSubagent).
//
// Pure functions only: the engine follows `$` into no imported function, so the
// hooks that read the environment live in hooks/register.ts.

import type { PromptComposeSection } from 'claude-code'

export const RULES_ID = 'workbench-dev-team:rules'

export const RULES = `## Development workflow

For code implementation, bug fixes, refactors, and tests, use the \`/workbench-dev-team:develop\` skill.

## Git commits

For any git commit message — manual, scripted, or agent-driven — use the \`/workbench-dev-team:git-commit\` skill. It enforces Conventional Commits + Gitmoji format with full type/emoji references. This applies universally, not just to dev-team automation.

**Dev-team commits.** A sub-agent does not commit, merge, or push, and never asks to. It leaves the tree uncommitted and hands back the diff, the full \`git status\` list, and the proposed commit message. The orchestrator takes the uncommitted tree from there. Index-mode development commits and pushes unattended from the dispatcher's top-level run, and never asks about committing or pushing.

## Dev-team delegation

Development goes to Dr. Watson, triage to Inspector Lestrade, and review to Sherlock Holmes. Anything that ends in a changed file goes to one of them, never to a generic agent. Invoke \`/workbench-dev-team:orchestrate\` before you dispatch one, and before you act on a request to review, comment, merge, or triage on GitHub.`

// Agent types that leave CLAUDE.md out, as workbench-core names them in its
// hooks/mods/prompt-rules.ts (OMITS_CLAUDE_MD): they never saw the CLAUDE.md
// block, and core gives them no workbench rules either.
export const OMITS_CLAUDE_MD: ReadonlySet<string> = new Set([
  'Explore',
  'Plan',
  'web-fetch',
  'comment-thread-analyst',
  'summary-writer',
  'workbench-core:summary-writer',
  'meeting-writer',
  'workbench-core:meeting-writer',
])

// Whether a sub-agent of this type gets the rules at SubagentStart. A fork
// (agent_type "fork") inherits its parent's whole system prompt, which already
// holds the section, so it gets none. Nor does a type that leaves CLAUDE.md
// out.
export const isRulesSubagent = (agentType: string): boolean => agentType !== 'fork' && !OMITS_CLAUDE_MD.has(agentType)

export const SECTION: PromptComposeSection = { id: RULES_ID, text: RULES, scope: 'shared' }

// Whether a lane gets the rules, from the environment core reads for its
// lanes. Only WORKBENCH_SKIP_WARMUP=1 says no.
export const isRulesLane = (skipWarmup: string | undefined): boolean => skipWarmup !== '1'

const PAD = /\n[ \t]*\n\s*$/

export function withRules(sections: readonly PromptComposeSection[]): PromptComposeSection[] {
  const theirs = sections.filter(section => section.id !== RULES_ID)
  const cut = theirs.findIndex(section => section.scope === 'session')
  const at = cut === -1 ? theirs.length : cut
  const before = theirs.slice(0, at).map((section, i) => (i === at - 1 && PAD.test(section.text) ? { ...section, text: section.text.replace(/\s+$/, '') } : section))
  return [...before, cut === -1 ? SECTION : { ...SECTION, text: `${RULES}\n\n` }, ...theirs.slice(at)]
}
