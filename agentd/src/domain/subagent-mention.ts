// Pi expands subagent mentions written as `>name` into the canonical `subagent:name`
// form before persisting them to its session JSONL. Terminal sync dedup compares the HUD's
// raw user text against the Pi-imported text, so both sides must be canonicalized to the
// same shape or the expanded copy slips through as a duplicate bubble.
const SUBAGENT_MENTION_PATTERN = /(?<![\w>-])subagent:([A-Za-z0-9._-]+)/g;

export function canonicalizeSubagentMentions(text: string): string {
  return text.replace(SUBAGENT_MENTION_PATTERN, (_match, name: string) => `>${name}`);
}
