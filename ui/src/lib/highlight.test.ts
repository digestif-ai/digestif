import { describe, expect, it } from 'vitest';
import { markParts, searchWords, withSearch } from './highlight.ts';

const marked = (text: string, q: string): string =>
  markParts(text, searchWords(q))
    .map((p) => (p.mark ? '[' + p.text + ']' : p.text))
    .join('');

describe('search highlights (DIG-128)', () => {
  it('marks each word where it starts a word, in any case', () => {
    expect(marked('The Zeppelin migration ran', 'zepp MIGR')).toBe('The [Zepp]elin [migr]ation ran');
  });

  it('does not mark a word inside another', () => {
    expect(marked('rehovering hover', 'hover')).toBe('rehovering [hover]');
  });

  it('folds diacritics the way the search does', () => {
    expect(marked('Café crème', 'cafe creme')).toBe('[Café] [crème]');
  });

  it('marks every place, and nothing for no words', () => {
    expect(marked('a relay, the relay', 'relay')).toBe('a [relay], the [relay]');
    expect(marked('a relay', '  !! ')).toBe('a relay');
  });

  it('carries the search to the page it opens', () => {
    expect(withSearch('/inbox/itm-1', ' zepp ')).toBe('/inbox/itm-1?q=zepp');
    expect(withSearch('/feed/abc?version=2', 'a b')).toBe('/feed/abc?version=2&q=a%20b');
    expect(withSearch('/inbox/itm-1', '')).toBe('/inbox/itm-1');
  });
});
