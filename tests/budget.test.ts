// hooks/register.ts with hooks/mods/budget.ts: each dev-team run's working
// context, measured on every model request, and one notice to the human when a
// run passes its budget. Nothing is stopped.

import { describe, expect, test } from 'claude-code/testing'

import { BUDGET_TOKENS, budgetNotice, contextOf, isOverBudget } from '../hooks/mods/budget'
import { BRIEF, complete, spawnInput, step, usageOf, world } from './world'

const T = (name: string) => `workbench-dev-team:${name}`

describe('budget — a run past its working-context budget notifies the human once', () => {
  test('a Watson request past 250k shows a toast and a transcript line', async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    w.usage.push(usageOf(260_000))
    await step($ as never, 'agent-1')
    const notice = budgetNotice(T('watson-direct'), 'agent-1', 260_000)
    expect(w.shown).toEqual([`toast: ${notice}`, `transcript: ${notice}`])
    expect(notice).toContain('watson-direct (agent-1) passed its 250k-token working-context budget, at 260k')
    expect(notice).toContain('Nothing was stopped.')
  })

  test('the notice comes once per run, and again for the next run', async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput(T('holmes'), BRIEF))
    w.usage.push(usageOf(300_000), usageOf(320_000))
    await step($ as never, 'agent-1')
    await step($ as never, 'agent-1')
    expect(w.shown.length).toBe(2)
    await complete($ as never, 'agent-1')
    w.usage.push(usageOf(330_000))
    await step($ as never, 'agent-1')
    expect(w.shown.length).toBe(4)
  })

  test('exactly the budget is within it, and one token more is past it', async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    w.usage.push(usageOf(BUDGET_TOKENS), usageOf(BUDGET_TOKENS + 1))
    await step($ as never, 'agent-1')
    expect(w.shown).toEqual([])
    await step($ as never, 'agent-1')
    expect(w.shown.length).toBe(2)
  })

  test('each run is measured on its own', async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput(T('watson'), BRIEF)) // agent-1
    await $.agent.spawn(spawnInput(T('holmes-lens'), 'lens', { parentAgentId: 'agent-h' })) // agent-2
    w.usage.push(usageOf(400_000), usageOf(400_000))
    await step($ as never, 'agent-1')
    await step($ as never, 'agent-2')
    expect(w.shown.filter(line => line.startsWith('toast:'))).toEqual([
      `toast: ${budgetNotice(T('watson-direct'), 'agent-1', 400_000)}`,
      `toast: ${budgetNotice(T('holmes-lens'), 'agent-2', 400_000)}`,
    ])
  })

  test('the top-level loop of a dev-team --agent run is measured', async ($, on) => {
    const w = world(on, { lane: () => 'top-level-agent', env: { CLAUDE_CODE_AGENT: T('holmes-index') } })
    w.usage.push(usageOf(270_000))
    await step($ as never)
    expect(w.shown).toEqual([`toast: ${budgetNotice(T('holmes-index'), 'run', 270_000)}`, `transcript: ${budgetNotice(T('holmes-index'), 'run', 270_000)}`])
  })

  test('the main session, and an agent outside the dev-team, are not measured', async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput('general-purpose', BRIEF)) // agent-1
    w.usage.push(usageOf(900_000), usageOf(900_000))
    await step($ as never)
    await step($ as never, 'agent-1')
    expect(w.shown).toEqual([])
  })

  test('a request with no usage notifies nothing, and passes on', async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    await step($ as never, 'agent-1')
    expect(w.shown).toEqual([])
    expect(w.steps.length).toBe(1)
  })
})

describe('budget — the pure rules', () => {
  test('contextOf counts every input token, cached or not, and no output', () => {
    expect(contextOf({ input_tokens: 1, output_tokens: 99, cache_read_input_tokens: 10, cache_creation_input_tokens: 100, model: 'm' })).toBe(111)
    expect(contextOf(null)).toBeUndefined()
    expect(isOverBudget(undefined)).toBe(false)
    expect(isOverBudget(BUDGET_TOKENS + 1)).toBe(true)
  })
})
