// The dispatch gate held to workbench-core's bash gate, case for case, over
// every prompt case of its test (tests/gate-cases.ts). Core retires the bash
// gate once this module reaches parity, and its own case file records no hint
// verdicts, so the hint has no other check than this one.

import { describe, expect, test } from 'claude-code/testing'

import { hintOf } from '../hooks/mods/spawn'
import { GATE_CASES } from './gate-cases'
import { spawnInput, world } from './world'

describe('the fixture — a deny is exactly a brief core finds incomplete', () => {
  test('every case agrees with itself', () => {
    expect(GATE_CASES).toHaveLength(63)
    for (const c of GATE_CASES) expect([c.name, c.verdict === 'deny']).toEqual([c.name, !c.check.isComplete])
    expect(GATE_CASES.filter(c => c.verdict === 'hint').length).toBe(4)
  })
})

describe('hintOf — a hint exactly where the bash gate gave one', () => {
  for (const c of GATE_CASES.filter(c => c.verdict !== 'deny')) {
    test(`${c.verdict}: ${c.name}`, () => {
      expect(hintOf(c.check, c.prompt) !== undefined).toBe(c.verdict === 'hint')
    })
  }
})

describe("the module's verdict — deny at spawn, hint on the Agent call, or silence", () => {
  for (const c of GATE_CASES) {
    test(`${c.verdict}: ${c.name}`, async ($, on) => {
      const w = world(on, { check: () => c.check })
      const spawn = await $.agent.spawn(spawnInput('general-purpose', c.prompt))
      let verdict: string
      if ((spawn as { deny?: string }).deny !== undefined) {
        verdict = 'deny'
        expect(w.spawned).toEqual([])
      } else {
        const call = await $.tool.call({ tool: 'Agent', tool_use_id: 'toolu_1', description: 'd', prompt: c.prompt, subagent_type: 'general-purpose' } as never)
        verdict = ((call as { context?: string[] }).context ?? []).length > 0 ? 'hint' : 'silent'
      }
      expect(verdict).toBe(c.verdict)
    })
  }
})
