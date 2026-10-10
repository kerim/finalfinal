// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
// The bundled default the engine's constructor starts with (the same file citeproc-engine.ts imports).
import chicagoStyle from '../../../../final final/Resources/Export/chicago-author-date.csl?raw';
import { setCitationStyle } from '../api-annotations';
import { CiteprocEngine, type CSLItem, resetCiteprocEngine } from '../citeproc-engine';

// Coverage for the "identical style" early return in CiteprocEngine.setStyle().
//
// Why it exists: building a CSL.Engine from the ~160 KB bundled style takes about a second, and
// the Swift side pushes the effective style (`window.FinalFinal.setCitationStyle`) at every Rich
// Text mount. A fresh page already holds the bundled style (the constructor default), and the
// standby page is given the user's style ahead of time, so the push at mount is usually text the
// engine is already running. setStyle() now returns false -- and rebuilds nothing -- in that case,
// and setCitationStyle() then dispatches neither the update event nor the empty transaction.
// The comparison is against the style the engine is ACTUALLY running, so a style citeproc
// rejected (rolled back) is retried by the next push exactly as before.
function minimalStyle(label: string): string {
  return `<?xml version="1.0" encoding="utf-8"?>
<style xmlns="http://purl.org/net/xbiblio/csl" class="in-text" version="1.0">
  <info>
    <title>Minimal Test Style ${label}</title>
    <id>http://example.com/minimal-test-style-${label}</id>
    <updated>2024-01-01T00:00:00+00:00</updated>
  </info>
  <citation>
    <layout prefix="[${label}: " suffix="]">
      <text variable="title"/>
    </layout>
  </citation>
  <bibliography>
    <layout>
      <text variable="title"/>
    </layout>
  </bibliography>
</style>`;
}

const styleA = minimalStyle('A');
const styleB = minimalStyle('B');

const item: CSLItem = {
  id: 'friedman2010',
  type: 'book',
  title: 'A Test Book',
  author: [{ family: 'Friedman', given: 'P. Kerim' }],
  issued: { 'date-parts': [[2010]] },
};

// The CSL.Engine instance currently held by the wrapper (private, so reached through `any`).
function citeprocInstance(engine: CiteprocEngine): unknown {
  return (engine as unknown as { engine: unknown }).engine;
}

describe('CiteprocEngine.setStyle with the style the engine is already running', () => {
  it('returns false for the bundled default and keeps the very same engine instance', () => {
    const engine = new CiteprocEngine();
    const before = citeprocInstance(engine);

    expect(engine.setStyle(chicagoStyle)).toBe(false);
    expect(citeprocInstance(engine)).toBe(before);
  });

  it('returns false the second time the same custom style is pushed, with the same engine instance', () => {
    const engine = new CiteprocEngine();

    expect(engine.setStyle(styleA)).toBe(true);
    const afterFirst = citeprocInstance(engine);
    expect(afterFirst).toBeDefined();

    expect(engine.setStyle(styleA)).toBe(false);
    expect(citeprocInstance(engine)).toBe(afterFirst);
  });

  it('returns true and changes the formatted output when the style differs', () => {
    const engine = new CiteprocEngine();
    engine.setBibliography([item]);
    const chicago = engine.formatCitation(['friedman2010']);
    expect(chicago).toContain('Friedman');

    expect(engine.setStyle(styleA)).toBe(true);
    const a = engine.formatCitation(['friedman2010']);
    expect(a).toBe('[A: A Test Book]');
    expect(a).not.toBe(chicago);
  });

  it('rebuilds on every change in A -> B -> A, and the output returns to A', () => {
    const engine = new CiteprocEngine();
    engine.setBibliography([item]);

    expect(engine.setStyle(styleA)).toBe(true);
    const a1 = citeprocInstance(engine);
    const outputA = engine.formatCitation(['friedman2010']);

    expect(engine.setStyle(styleB)).toBe(true);
    const b = citeprocInstance(engine);
    expect(b).not.toBe(a1);
    expect(engine.formatCitation(['friedman2010'])).toBe('[B: A Test Book]');

    expect(engine.setStyle(styleA)).toBe(true);
    expect(citeprocInstance(engine)).not.toBe(b);
    expect(engine.formatCitation(['friedman2010'])).toBe(outputA);
  });

  it('after an invalid style (rolled back), pushing the previous style is a no-op and citations still format', () => {
    const engine = new CiteprocEngine();
    engine.setBibliography([item]);
    expect(engine.setStyle(styleA)).toBe(true);
    const outputA = engine.formatCitation(['friedman2010']);

    // The invalid style is attempted (so the caller re-renders) and rolled back to A.
    expect(engine.setStyle('this is not valid CSL XML at all <<<')).toBe(true);
    expect(engine.formatCitation(['friedman2010'])).toBe(outputA);

    // The same invalid style is retried on the next push, exactly as before the identity check.
    expect(engine.setStyle('this is not valid CSL XML at all <<<')).toBe(true);
    expect(engine.formatCitation(['friedman2010'])).toBe(outputA);

    // A is what the engine is running, so pushing A again rebuilds nothing.
    const running = citeprocInstance(engine);
    expect(engine.setStyle(styleA)).toBe(false);
    expect(citeprocInstance(engine)).toBe(running);
    expect(engine.formatCitation(['friedman2010'])).toBe(outputA);
  });

  it('keeps items registered before an identical push formatted after it', () => {
    const engine = new CiteprocEngine();
    engine.setBibliography([item]);
    const before = engine.formatCitation(['friedman2010']);
    const bibliographyBefore = engine.generateBibliography(['friedman2010']);

    expect(engine.setStyle(chicagoStyle)).toBe(false);

    expect(engine.hasItem('friedman2010')).toBe(true);
    expect(engine.formatCitation(['friedman2010'])).toBe(before);
    expect(engine.generateBibliography(['friedman2010'])).toEqual(bibliographyBefore);

    // Same for a custom style.
    expect(engine.setStyle(styleA)).toBe(true);
    const outputA = engine.formatCitation(['friedman2010']);
    expect(engine.setStyle(styleA)).toBe(false);
    expect(engine.hasItem('friedman2010')).toBe(true);
    expect(engine.formatCitation(['friedman2010'])).toBe(outputA);
  });
});

describe('setCitationStyle (window.FinalFinal.setCitationStyle) with an identical style', () => {
  let updates: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    resetCiteprocEngine();
    updates = vi.fn();
    document.addEventListener('citation-library-updated', updates);
  });

  afterEach(() => {
    document.removeEventListener('citation-library-updated', updates);
    resetCiteprocEngine();
  });

  it('dispatches no update event for the bundled default', () => {
    setCitationStyle(chicagoStyle);
    expect(updates).not.toHaveBeenCalled();
  });

  it('dispatches the update event once for a new style and not again for the same text', () => {
    setCitationStyle(styleA);
    expect(updates).toHaveBeenCalledTimes(1);

    setCitationStyle(styleA);
    expect(updates).toHaveBeenCalledTimes(1);

    setCitationStyle(styleB);
    expect(updates).toHaveBeenCalledTimes(2);
  });
});
