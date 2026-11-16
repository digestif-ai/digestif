// Search highlights (DIG-128): the words of a search marked where they matched. The node matches each
// word against the start of a word in the text, in any case and with diacritics folded
// (Store.Search.query), so a mark starts at a word and runs the length of the word typed.

/** One piece of a text: marked where a word of the search matched, plain elsewhere. */
export interface MarkPart {
  text: string;
  mark: boolean;
}

/** The words of a search, lower case, each holding a letter or digit: the words the node keeps. */
export function searchWords(query: string | null | undefined): string[] {
  return (query ?? '')
    .toLowerCase()
    .split(/\s+/)
    .filter((w) => /[\p{L}\p{N}]/u.test(w));
}

/** A character folded the way the search folds it: lower case, its diacritics dropped. */
const fold = (ch: string): string => ch.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase();

const isWordChar = (ch: string | undefined): boolean => ch !== undefined && /[\p{L}\p{N}]/u.test(ch);

/** [text] in pieces, every place a word of [words] matches the start of a word marked; one plain piece when nothing matches. */
export function markParts(text: string, words: string[]): MarkPart[] {
  const wanted = words.map((w) => [...w].map(fold).join('')).filter((w) => w !== '');
  if (wanted.length === 0 || text === '') return [{ text, mark: false }];
  const chars = [...text];
  const folded = chars.map(fold);
  const parts: MarkPart[] = [];
  let plain = '';
  let i = 0;
  while (i < chars.length) {
    const length = isWordChar(chars[i - 1]) ? 0 : matchAt(folded, i, wanted);
    if (length > 0) {
      if (plain !== '') parts.push({ text: plain, mark: false });
      plain = '';
      parts.push({ text: chars.slice(i, i + length).join(''), mark: true });
      i += length;
    } else {
      plain += chars[i];
      i += 1;
    }
  }
  if (plain !== '') parts.push({ text: plain, mark: false });
  return parts;
}

/** How many characters from [at] the longest of [words] covers, 0 when none starts there. */
function matchAt(folded: string[], at: number, words: string[]): number {
  let best = 0;
  for (const w of words) {
    let k = 0;
    let n = 0;
    while (k < w.length && at + n < folded.length) {
      const f = folded[at + n]!;
      if (f === '' || !w.startsWith(f, k)) break;
      k += f.length;
      n += 1;
    }
    if (k >= w.length && n > best) best = n;
  }
  return best;
}

/** [href] with the search that opened it, so the page marks the words too. */
export function withSearch(href: string, query: string): string {
  const q = query.trim();
  if (q === '') return href;
  return href + (href.includes('?') ? '&' : '?') + 'q=' + encodeURIComponent(q);
}
