import { describe, expect, it } from 'vitest';
import { CiteprocEngine, type CSLItem } from '../citeproc-engine';

// Regression test for the "not found" (key?) placeholder bug caused by Better BibTeX
// resolving items by their own KeyManager key (CSL `id`) while reporting a different,
// stale `citation-key` (left over from a legacy `Citation Key:` line in the item's
// Zotero Extra field). The engine must key its bibliography map by `id` first, and all
// lookups must be case-insensitive since BBT's `id` casing can differ from the casing
// used in the document.
describe('CiteprocEngine id-vs-citation-key precedence', () => {
  it('resolves a citation when the document citekey matches `id` (not `citation-key`), case-insensitively', () => {
    const engine = new CiteprocEngine();

    const item: CSLItem & { 'citation-key': string } = {
      id: 'friedman2010',
      type: 'book',
      title: 'A Test Book',
      author: [{ family: 'Friedman', given: 'P. Kerim' }],
      issued: { 'date-parts': [[2010]] },
      // Stale legacy citation-key, unrelated to both `id` and what the document cites.
      'citation-key': 'oldLegacyKey2010',
    };

    engine.setBibliography([item]);

    // Document cites `Friedman2010` — differs in case from `id` (`friedman2010`) and bears
    // no relation to the stale `citation-key` (`oldLegacyKey2010`).
    expect(engine.hasItem('Friedman2010')).toBe(true);
    expect(engine.getItem('Friedman2010')).toBeDefined();

    const formatted = engine.formatCitation(['Friedman2010']);
    // The bug produced the literal unresolved placeholder "Friedman2010?".
    expect(formatted).not.toContain('?');
    expect(formatted).toContain('Friedman');
    expect(formatted).toContain('2010');

    // The stale citation-key must no longer be a valid lookup key now that `id` takes
    // precedence over it.
    expect(engine.hasItem('oldLegacyKey2010')).toBe(false);
  });
});
