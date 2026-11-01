// The always-on rule (docs/design.md, Guarding what goes out), read from the one text every prompt
// includes, behaviors/prompts/always-on.md, so the Rules page shows exactly what the agent is told.
// The build inlines it; there is no copy here and no setting that turns it off.
import text from '../../../behaviors/prompts/always-on.md?raw';

export interface AlwaysOnRule {
  title: string;
  paragraphs: string[];
}

/** The file's first paragraph is the rule's title; every other is a paragraph of it. */
export function parseAlwaysOn(raw: string): AlwaysOnRule {
  const [title = '', ...paragraphs] = raw
    .split(/\n\s*\n/)
    .map((p) => p.replace(/\s+/g, ' ').trim())
    .filter((p) => p !== '');
  return { title, paragraphs };
}

export const alwaysOn: AlwaysOnRule = parseAlwaysOn(text);
