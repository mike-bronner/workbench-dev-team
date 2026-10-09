// hooks/register.ts with hooks/mods/session-rules.ts: the dev-team session
// rules as one shared prompt.compose section, whose bytes never change within a
// lane, placed by hook order beside workbench-core's own sections, and a
// sub-agent's copy at
// SubagentStart.

import { describe, expect, mock, test } from 'claude-code/testing'
import type { MockClock } from 'claude-code/testing'
import type { On, PromptComposeSection } from 'claude-code'

import { OMITS_CLAUDE_MD, RULES, RULES_ID, SECTION, isRulesLane, withRules } from '../hooks/mods/session-rules'

const HOME = '/Users/tester'
const NOTICES = `${HOME}/.claude-workbench/warmup-notices.md`
// One minute before midnight UTC, so a two-minute move changes the date.
const BEFORE_MIDNIGHT = Date.UTC(2026, 9, 9, 23, 59)
const PAST_MIDNIGHT_MS = 120_000
const COMPOSE = { model: 'claude-opus-5-5', promptModel: 'claude-opus-5-5', surfaces: ['terminal' as const], tools: [], outputStyle: null, traits: [] }
const START = { cwd: '/repo', surface: 'terminal' as const, isInteractive: true }

const CORE_SECTIONS: PromptComposeSection[] = [
  { id: 'workbench-core:rules', text: 'Workbench gates.', scope: 'shared' },
  { id: 'workbench-core:memory', text: 'Memory routing.', scope: 'shared' },
]

type Engine = { files: Map<string, string>; clock: MockClock }

// The engine beneath the module, with workbench-core's sections in its answer
// when `isCoreLoaded`. Its own prompt carries the date in a session section, as
// the engine's environment section does, so a date change moves a session
// section and never a shared one.
function engine(on: On, options: { env?: Record<string, string>; isCoreLoaded?: boolean; envFails?: boolean } = {}): Engine {
  const g: Engine = { files: new Map([[NOTICES, '# Warmup notices\n\nNo outstanding notices.\n']]), clock: mock.clock(on, { now: BEFORE_MIDNIGHT }) }
  if (options.envFails) {
    on('env.get', async () => {
      throw new Error('env unreadable')
    })
  } else mock.env(on, { HOME, ...(options.env ?? {}) })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('ui.panes', () => ({ value: [] }) as never)
  on('fs.exists', ($, e) => ({ value: g.files.has(e.path) }))
  on('fs.read', ($, e) => {
    const text = g.files.get(e.path)
    if (text === undefined) throw new Error(`ENOENT: ${e.path}`)
    return { value: text }
  })
  on('prompt.compose', () => ({
    sections: [
      { id: 'intro', text: 'You are Claude Code.', scope: 'shared' as const },
      { id: 'tools', text: 'Use the tools.', scope: 'shared' as const },
      ...(options.isCoreLoaded === false ? [] : CORE_SECTIONS),
      { id: 'env_info_simple', text: `Today's date is ${new Date(g.clock.now()).toISOString().slice(0, 10)}.`, scope: 'session' as const },
      { id: 'context_management', text: 'Context is managed.', scope: 'session' as const },
    ],
  }))
  on('classic.SubagentStart', () => ({ additionalContext: ['BENEATH'] }))
  return g
}

const shared = (sections: readonly PromptComposeSection[]) => sections.filter(section => section.scope === 'shared')
const ids = (sections: readonly PromptComposeSection[]) => sections.map(section => section.id)
const ours = (sections: readonly PromptComposeSection[]) => sections.filter(section => section.id === RULES_ID)
const subagentStart = (agentType: string) => ({ hook_event_name: 'SubagentStart' as const, agent_id: 'a1', agent_type: agentType })

describe('AC2: the dev-team section is byte-identical across a reload, a notices change and a date change', () => {
  test('the section keeps its bytes, and only a session section moves', { timeoutMs: 60_000 }, async ($, on) => {
    const g = engine(on)
    await $.session.start(START)
    const before = (await $.prompt.compose(COMPOSE)).sections
    // A simulated reload: session.start fires again, as a reload does.
    await $.session.start(START)
    // A notices change: another start rewrote the notices file.
    g.files.set(NOTICES, '# Warmup notices\n\n## ⚠ Pending session summaries (7)\n')
    // A date change: the clock moves past midnight.
    await g.clock.advance(PAST_MIDNIGHT_MS)
    const after = (await $.prompt.compose(COMPOSE)).sections
    expect(ours(before)).toEqual([SECTION])
    expect(ours(after)).toEqual(ours(before))
    expect(shared(after)).toEqual(shared(before))
    expect(ids(after)).toEqual(ids(before))
    // The comparison is not vacuous: the engine's session side did change.
    expect(after.find(section => section.id === 'env_info_simple')?.text).not.toBe(before.find(section => section.id === 'env_info_simple')?.text)
  })

  test('the rules carry no date, version or count', () => {
    expect(RULES).not.toMatch(/\d/)
  })

  test('the rules are the moved session-warmup.md text, its three sections in order', () => {
    const headings = RULES.split('\n').filter(line => line.startsWith('## '))
    expect(headings).toEqual(['## Development workflow', '## Git commits', '## Dev-team delegation'])
    expect(RULES).toContain('A sub-agent does not commit, merge, or push, and never asks to.')
    expect(RULES).toContain('use the `/workbench-dev-team:develop` skill.')
    expect(RULES).toBe(RULES.trim())
  })
})

describe("where the section sits beside workbench-core's sections, by hook order", () => {
  test("when this hook wraps core's, after the last workbench-core section, and shared", async ($, on) => {
    engine(on)
    const sections = (await $.prompt.compose(COMPOSE)).sections
    expect(ids(sections)).toEqual(['intro', 'tools', 'workbench-core:rules', 'workbench-core:memory', RULES_ID, 'env_info_simple', 'context_management'])
    expect(ours(sections)[0]?.scope).toBe('shared')
  })

  test('with no workbench-core section, after the last shared section', async ($, on) => {
    engine(on, { isCoreLoaded: false })
    const sections = (await $.prompt.compose(COMPOSE)).sections
    expect(ids(sections)).toEqual(['intro', 'tools', RULES_ID, 'env_info_simple', 'context_management'])
  })

  test('a list with no session section takes it last', () => {
    const list: PromptComposeSection[] = [{ id: 'intro', text: 'a', scope: 'shared' }]
    expect(ids(withRules(list))).toEqual(['intro', RULES_ID])
  })

  test('a workbench-core section on the session side does not pull it past the boundary', () => {
    const list: PromptComposeSection[] = [
      { id: 'intro', text: 'a', scope: 'shared' },
      { id: 'env_info_simple', text: 'd', scope: 'session' },
      { id: 'workbench-core:status', text: 's', scope: 'session' },
    ]
    expect(ids(withRules(list))).toEqual(['intro', RULES_ID, 'env_info_simple', 'workbench-core:status'])
  })

  test("when core's hook wraps this one, it comes before core's sections, still shared and once", async ($, on) => {
    // Core's own placement (workbench-core hooks/mods/prompt-rules.ts,
    // withShared): its sections, minus any already there, at the first
    // session section. Applied here to what this module answered.
    const coreWithShared = (sections: readonly PromptComposeSection[]): PromptComposeSection[] => {
      const theirs = sections.filter(section => !section.id.startsWith('workbench-core:'))
      const cut = theirs.findIndex(section => section.scope === 'session')
      const at = cut === -1 ? theirs.length : cut
      return [...theirs.slice(0, at), ...CORE_SECTIONS, ...theirs.slice(at)]
    }
    engine(on, { isCoreLoaded: false })
    const first = coreWithShared((await $.prompt.compose(COMPOSE)).sections)
    const second = coreWithShared((await $.prompt.compose(COMPOSE)).sections)
    expect(ids(first)).toEqual(['intro', 'tools', RULES_ID, 'workbench-core:rules', 'workbench-core:memory', 'env_info_simple', 'context_management'])
    expect(ours(first)).toEqual([SECTION])
    expect(second).toEqual(first)
  })

  test('a list that already holds it keeps one copy, in place', () => {
    const once = withRules([...CORE_SECTIONS, { id: 'env_info_simple', text: 'd', scope: 'session' }])
    const twice = withRules(once)
    expect(twice).toEqual(once)
    expect(ours(twice).length).toBe(1)
  })
})

describe('lanes: every session gets the rules but a WORKBENCH_SKIP_WARMUP=1 run', () => {
  test('a top-level --agent run gets them', async ($, on) => {
    engine(on, { env: { CLAUDE_CODE_AGENT: 'workbench-dev-team:watson-index' } })
    expect(ours((await $.prompt.compose(COMPOSE)).sections)).toEqual([SECTION])
  })

  test('a WORKBENCH_SKIP_WARMUP=1 run gets none, and its prompt is left as the engine made it', async ($, on) => {
    engine(on, { env: { WORKBENCH_SKIP_WARMUP: '1' } })
    const sections = (await $.prompt.compose(COMPOSE)).sections
    expect(ids(sections)).toEqual(['intro', 'tools', 'workbench-core:rules', 'workbench-core:memory', 'env_info_simple', 'context_management'])
  })

  test('another WORKBENCH_SKIP_WARMUP value still gets them', () => {
    expect(isRulesLane(undefined)).toBe(true)
    expect(isRulesLane('0')).toBe(true)
    expect(isRulesLane('1')).toBe(false)
  })

  test('an environment that cannot be read still sends them', async ($, on) => {
    engine(on, { envFails: true })
    expect(ours((await $.prompt.compose(COMPOSE)).sections)).toEqual([SECTION])
  })
})

describe('SubagentStart: a sub-agent gets the rules as context', () => {
  test('a general-purpose sub-agent gets them after what is beneath', async ($, on) => {
    engine(on)
    const result = await $.classic.SubagentStart(subagentStart('general-purpose'))
    expect(result.additionalContext).toEqual(['BENEATH', RULES])
  })

  test('a dev-team agent gets them too', async ($, on) => {
    engine(on)
    const result = await $.classic.SubagentStart(subagentStart('workbench-dev-team:watson-direct'))
    expect(result.additionalContext).toEqual(['BENEATH', RULES])
  })

  test('a fork gets none, since its inherited system prompt already holds the section', async ($, on) => {
    engine(on)
    expect((await $.classic.SubagentStart(subagentStart('fork'))).additionalContext).toEqual(['BENEATH'])
    expect((await $.classic.SubagentStart(subagentStart('general-purpose'))).additionalContext).toEqual(['BENEATH', RULES])
  })

  test('each type that leaves CLAUDE.md out gets none', async ($, on) => {
    engine(on)
    for (const type of OMITS_CLAUDE_MD) {
      const result = await $.classic.SubagentStart(subagentStart(type))
      expect(result.additionalContext).toEqual(['BENEATH'])
    }
  })

  test('a WORKBENCH_SKIP_WARMUP=1 run gives its sub-agents none', async ($, on) => {
    engine(on, { env: { WORKBENCH_SKIP_WARMUP: '1' } })
    const result = await $.classic.SubagentStart(subagentStart('general-purpose'))
    expect(result.additionalContext).toEqual(['BENEATH'])
  })
})
