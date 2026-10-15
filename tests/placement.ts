import type { PromptComposeSection } from 'claude-code'

const PAD = /\n[ \t]*\n\s*$/

export function placeShared(sections: readonly PromptComposeSection[], ours: readonly PromptComposeSection[]): PromptComposeSection[] {
  const ids = new Set(ours.map(section => section.id))
  const theirs = sections.filter(section => !ids.has(section.id))
  const cut = theirs.findIndex(section => section.scope === 'session')
  const at = cut === -1 ? theirs.length : cut
  const last = ours[ours.length - 1]
  if (last === undefined) return [...theirs]
  const before = theirs.slice(0, at).map((section, i) => (i === at - 1 && PAD.test(section.text) ? { ...section, text: section.text.replace(/\s+$/, '') } : section))
  const placed = cut === -1 ? ours : [...ours.slice(0, -1), { ...last, text: `${last.text.replace(/\s+$/, '')}\n\n` }]
  return [...before, ...placed, ...theirs.slice(at)]
}
