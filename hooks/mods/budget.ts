// Each dev-team agent's working-context budget, as pure functions.
// hooks/register.ts measures every model request of a dev-team agent's loop in
// turn.step, and notifies the human once when a request passes the budget. It
// stops nothing: the agents' rule is to finish the work and say what made it
// expensive, never to buy the budget with the work.

import type { TurnUsage } from 'claude-code'

// The budget every dev-team agent's prose states: about 250k tokens of working
// context.
export const BUDGET_TOKENS = 250_000

// A request's working context: every input token it was answered over, cached
// or not. Undefined when the request carried no usage.
export const contextOf = (usage: TurnUsage | null | undefined): number | undefined =>
  usage == null ? undefined : usage.input_tokens + usage.cache_read_input_tokens + usage.cache_creation_input_tokens

export const isOverBudget = (tokens: number | undefined): boolean => tokens !== undefined && tokens > BUDGET_TOKENS

// The notice, one line: which agent, how far past, and that nothing stopped.
export function budgetNotice(type: string, id: string, tokens: number): string {
  const k = (n: number) => `${Math.round(n / 1000)}k`
  return `📏 workbench-dev-team: ${type.split(':').pop()} (${id}) passed its ${k(BUDGET_TOKENS)}-token working-context budget, at ${k(tokens)} in its latest request. Nothing was stopped.`
}
