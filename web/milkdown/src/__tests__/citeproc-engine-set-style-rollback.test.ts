import { describe, expect, it } from 'vitest';
import { CiteprocEngine, type CSLItem } from '../citeproc-engine';

// Regression coverage for a custom-CSL-style must-fix: setStyle() used to call initEngine()
// unguarded, so a malformed/garbled CSL file (a corrupted download, or a user-provided .csl
// that isn't actually valid CSL) would throw straight out of setStyle() -- which the Swift
// bridge call (setCitationStyle -> pushCitationStyle) has no error-handling path for -- and
// brick live citation rendering for the rest of the session. setStyle() must instead roll
// back to the previously-active (known-good) style, log an error, and never rethrow.
describe('CiteprocEngine.setStyle malformed-CSL rollback', () => {
  const item: CSLItem = {
    id: 'friedman2010',
    type: 'book',
    title: 'A Test Book',
    author: [{ family: 'Friedman', given: 'P. Kerim' }],
    issued: { 'date-parts': [[2010]] },
  };

  it('does not throw when given malformed CSL XML', () => {
    const engine = new CiteprocEngine();
    engine.setBibliography([item]);

    expect(() => engine.setStyle('this is not valid CSL XML at all <<<')).not.toThrow();
  });

  it('keeps citation formatting working after a malformed setStyle call (rolls back, does not brick the engine)', () => {
    const engine = new CiteprocEngine();
    engine.setBibliography([item]);

    const before = engine.formatCitation(['friedman2010']);
    expect(before).not.toContain('?');
    expect(before).toContain('Friedman');

    engine.setStyle('this is not valid CSL XML at all <<<');

    // The engine must still be usable -- both the item lookup and citation formatting --
    // after the failed style change, using the rolled-back (previous, known-good) style.
    expect(engine.hasItem('friedman2010')).toBe(true);
    const after = engine.formatCitation(['friedman2010']);
    expect(after).not.toContain('?');
    expect(after).toContain('Friedman');
  });

  it('applies a subsequent, well-formed style change normally after a prior rollback', () => {
    const engine = new CiteprocEngine();
    engine.setBibliography([item]);

    engine.setStyle('garbage, not xml');

    // A later, valid setStyle call (e.g. the user picks a real CSL file after their first
    // pick failed) must still work -- the rollback shouldn't have left the engine wedged.
    const chicagoLikeStyle = `<?xml version="1.0" encoding="utf-8"?>
<style xmlns="http://purl.org/net/xbiblio/csl" class="in-text" version="1.0">
  <info>
    <title>Minimal Test Style</title>
    <id>http://example.com/minimal-test-style</id>
    <updated>2024-01-01T00:00:00+00:00</updated>
  </info>
  <citation>
    <layout>
      <text variable="title"/>
    </layout>
  </citation>
  <bibliography>
    <layout>
      <text variable="title"/>
    </layout>
  </bibliography>
</style>`;

    expect(() => engine.setStyle(chicagoLikeStyle)).not.toThrow();
    expect(engine.hasItem('friedman2010')).toBe(true);
    expect(engine.formatCitation(['friedman2010'])).toContain('A Test Book');
  });
});
