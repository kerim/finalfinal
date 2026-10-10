// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import chicagoStyle from '../../../../final final/Resources/Export/chicago-author-date.csl?raw';
import { citationFormatRequest } from '../citation-plugin';
import type { CitationAttrs } from '../citation-types';
import {
  CiteprocEngine,
  type CSLItem,
  getCitationMemoStats,
  getCiteprocEngine,
  resetCiteprocEngine,
  setCitationMemoEnabled,
} from '../citeproc-engine';
import localeEnUS from '../locales/locales-en-US.xml?raw';
import {
  book,
  chapterBrackets,
  documentGroups,
  type Group,
  groupFromBracket,
  LIBRARY,
  NOTE_STYLE,
  n,
  purityGroups,
  shuffled,
} from './citation-fixtures';

// The formatted-citation memo inside CiteprocEngine (plan: plan-citations-ahead-of-time.md, step W1; judge's must-fix 2).
//
// The memo may only ever hand back what the citation processor itself would give for the same request under the style, locale and
// library the engine holds RIGHT NOW. These tests pin that from every side:
//   - memo on and memo off give the same text, byte for byte, for every purity group in both style families, in any order;
//   - everything that can change an answer empties the memo (style, rollback, locale, any item added/removed/edited/reordered,
//     generateBibliography). Order counts: the engine registers items in the order they are pushed;
//   - what cannot change an answer keeps it (identical style, identical items in the same order, identical items again, and the app's
//     re-push of the same mixed-case-id library AFTER a style change);
//   - nothing but processor output is ever stored (the unresolved text, the processor-error text, the no-result text);
//   - with the memo switched off none of it runs.

function engineWith(style?: string, items: CSLItem[] = LIBRARY): CiteprocEngine {
  const engine = new CiteprocEngine(style);
  engine.setBibliography(items);
  return engine;
}

function format(engine: CiteprocEngine, g: Group): string {
  return engine.formatCitation(g.citekeys, g.options);
}

function formatAll(engine: CiteprocEngine, groups: Group[]): string[] {
  return groups.map((g) => format(engine, g));
}

function group(inner: string): Group {
  return groupFromBracket(inner);
}

/** The reference answer for every group: a memo-less engine under the same style and library. */
function referenceFor(groups: Group[], style?: string, items: CSLItem[] = LIBRARY): string[] {
  const engine = engineWith(style, items);
  engine.setMemoEnabled(false);
  return formatAll(engine, groups);
}

/** Better BibTeX keys normally carry capitals; the document uses whatever case the author typed. */
function mixedCaseIds(items: CSLItem[]): CSLItem[] {
  return items.map((item) => ({ ...item, id: item.id.charAt(0).toUpperCase() + item.id.slice(1) }));
}

/** A few distinct, fully resolvable groups. */
function warmGroups(): Group[] {
  return [
    group('@adams1999'),
    group('@baker2003, p. 12'),
    group('@chen2011; @dube2007'),
    group('see @evans2015, pp. 3–9'),
    group('-@fischer1994'),
  ];
}

function warm(engine: CiteprocEngine): number {
  formatAll(engine, warmGroups());
  return engine.getMemoStats().size;
}

function withEditedYear(items: CSLItem[], id: string, year: number): CSLItem[] {
  return items.map((item) => (item.id === id ? { ...item, issued: { 'date-parts': [[year]] } } : item));
}

afterEach(() => {
  // The module-level switch and the singleton engine must not leak between tests.
  setCitationMemoEnabled(true);
  resetCiteprocEngine();
  vi.restoreAllMocks();
});

describe('memo on versus memo off: same text, byte for byte', () => {
  const CASES: Array<{ name: string; style: string | undefined }> = [
    { name: 'bundled Chicago author-date', style: undefined },
    { name: 'hand-written note style with ibid. and short forms', style: NOTE_STYLE },
  ];

  for (const { name, style } of CASES) {
    it(
      `${name}: every purity group plus a 68-group chapter, shuffled, in order and repeated`,
      { timeout: 120_000 },
      () => {
        const groups = [...purityGroups(), ...documentGroups(1, false)];
        const reference = referenceFor(groups, style);
        expect(reference).toHaveLength(groups.length);
        for (const text of reference) expect(text.length).toBeGreaterThan(0);

        const off = engineWith(style);
        off.setMemoEnabled(false);
        formatAll(off, groups);
        expect(off.getMemoStats()).toEqual({ size: 0, hits: 0, misses: 0, enabled: false });

        const on = engineWith(style);
        const order = shuffled(groups.map((_, i) => i));
        const shuffledPass: string[] = [];
        for (const i of order) shuffledPass[i] = format(on, groups[i]);
        const orderedPass = formatAll(on, groups);
        const repeatPass = formatAll(on, groups);

        expect(shuffledPass).toEqual(reference);
        expect(orderedPass).toEqual(reference);
        expect(repeatPass).toEqual(reference);

        const stats = on.getMemoStats();
        expect(stats.enabled).toBe(true);
        expect(stats.size).toBeGreaterThan(0);
        expect(stats.hits).toBeGreaterThan(groups.length); // the second and third passes are all hits
      }
    );
  }

  it(
    'a style change in the middle of a run never serves the old style text, there and back',
    { timeout: 120_000 },
    () => {
      const groups = purityGroups();
      const authorDateReference = referenceFor(groups);
      const noteReference = referenceFor(groups, NOTE_STYLE);
      expect(noteReference).not.toEqual(authorDateReference);

      const engine = engineWith();
      expect(formatAll(engine, groups)).toEqual(authorDateReference);
      expect(engine.getMemoStats().size).toBeGreaterThan(0);

      expect(engine.setStyle(NOTE_STYLE)).toBe(true);
      expect(formatAll(engine, groups)).toEqual(noteReference);

      expect(engine.setStyle(chicagoStyle)).toBe(true);
      expect(formatAll(engine, groups)).toEqual(authorDateReference);
    }
  );
});

describe('what the node view asks for is what the fixtures ask for', () => {
  it('citationFormatRequest(attrs) of a parsed citation equals the purity group of the same bracket', () => {
    for (const inner of chapterBrackets(0)) {
      const expected = groupFromBracket(inner);
      // The attrs the remark plugin gives a citation node (citation-plugin.ts: citekeys joined by ",", locators as JSON).
      const attrs: CitationAttrs = {
        citekeys: expected.citekeys.join(','),
        locators: JSON.stringify(expected.options.locators ?? []),
        prefix: expected.options.prefix ?? '',
        suffix: expected.options.suffix ?? '',
        suppressAuthor: !!expected.options.suppressAuthors,
        rawSyntax: `[${inner}]`,
      };
      const request = citationFormatRequest(attrs);
      expect(request.citekeys).toEqual(expected.citekeys);
      expect(request.options).toEqual(expected.options);
    }
  });
});

describe('what empties the memo', () => {
  it('a different style (setStyle)', { timeout: 60_000 }, () => {
    const engine = engineWith();
    expect(warm(engine)).toBe(5);
    expect(engine.setStyle(NOTE_STYLE)).toBe(true);
    expect(engine.getMemoStats().size).toBe(0);
  });

  it(
    'the rollback after a style citeproc rejects (the engine is rebuilt on the previous style)',
    { timeout: 60_000 },
    () => {
      vi.spyOn(console, 'error').mockImplementation(() => {});
      const engine = engineWith();
      const before = formatAll(engine, warmGroups());
      expect(engine.getMemoStats().size).toBe(5);
      expect(engine.setStyle('this is not valid CSL XML at all <<<')).toBe(true);
      expect(engine.getMemoStats().size).toBe(0);
      // And what comes out afterwards is the rolled-back style's own text, filled again.
      expect(formatAll(engine, warmGroups())).toEqual(before);
      expect(engine.getMemoStats().size).toBe(5);
    }
  );

  it('a new locale (setLocale)', { timeout: 60_000 }, () => {
    const engine = engineWith();
    expect(warm(engine)).toBe(5);
    engine.setLocale(localeEnUS);
    expect(engine.getMemoStats().size).toBe(0);
  });

  it('setBibliography with one item edited (its year)', { timeout: 60_000 }, () => {
    const engine = engineWith();
    expect(warm(engine)).toBe(5);
    engine.setBibliography(withEditedYear(LIBRARY, 'evans2015', 2016));
    expect(engine.getMemoStats().size).toBe(0);
  });

  it('setBibliography with one item removed', { timeout: 60_000 }, () => {
    const engine = engineWith();
    expect(warm(engine)).toBe(5);
    engine.setBibliography(LIBRARY.filter((item) => item.id !== 'garcia2018'));
    expect(engine.getMemoStats().size).toBe(0);
  });

  it('setBibliography with one item added', { timeout: 60_000 }, () => {
    const engine = engineWith();
    expect(warm(engine)).toBe(5);
    engine.setBibliography([...LIBRARY, book('zeta2021', [n('Zeta', 'Zoe')], 2021, 'An Unrelated Work')]);
    expect(engine.getMemoStats().size).toBe(0);
  });

  // The engine registers items in the order they are pushed (`updateItems(ids)`), so the same items in another order are NOT treated as
  // "no change": the memo is emptied rather than argued about (see `sameSignatures`).
  it('setBibliography with the same items in another order', { timeout: 60_000 }, () => {
    const engine = engineWith();
    expect(warm(engine)).toBe(5);
    const reordered = shuffled(LIBRARY);
    expect(reordered.map((item) => item.id)).not.toEqual(LIBRARY.map((item) => item.id));
    engine.setBibliography(reordered);
    expect(engine.getMemoStats().size).toBe(0);
    // ...and what is formatted afterwards is what a memo-less engine gives for the same order, filled again.
    expect(formatAll(engine, warmGroups())).toEqual(referenceFor(warmGroups(), undefined, reordered));
    expect(engine.getMemoStats().size).toBe(5);
  });

  it('setBibliography with just two items swapped', { timeout: 60_000 }, () => {
    const engine = engineWith();
    expect(warm(engine)).toBe(5);
    const swapped = [...LIBRARY];
    [swapped[0], swapped[1]] = [swapped[1], swapped[0]];
    engine.setBibliography(swapped);
    expect(engine.getMemoStats().size).toBe(0);
  });

  it('addItems with a new item', { timeout: 60_000 }, () => {
    const engine = engineWith();
    expect(warm(engine)).toBe(5);
    engine.addItems([book('zeta2021', [n('Zeta', 'Zoe')], 2021, 'An Unrelated Work')]);
    expect(engine.getMemoStats().size).toBe(0);
  });

  it('addItems with an existing item whose contents differ', { timeout: 60_000 }, () => {
    const engine = engineWith();
    expect(warm(engine)).toBe(5);
    engine.addItems(withEditedYear(LIBRARY, 'evans2015', 2016).filter((item) => item.id === 'evans2015'));
    expect(engine.getMemoStats().size).toBe(0);
  });

  it('generateBibliography', { timeout: 60_000 }, () => {
    const engine = engineWith();
    expect(warm(engine)).toBe(5);
    engine.generateBibliography();
    expect(engine.getMemoStats().size).toBe(0);
  });
});

describe('what keeps the memo', () => {
  it('setStyle with the style the engine already runs', { timeout: 60_000 }, () => {
    const engine = engineWith();
    expect(warm(engine)).toBe(5);
    expect(engine.setStyle(chicagoStyle)).toBe(false);
    expect(engine.getMemoStats().size).toBe(5);
  });

  it('addItems with items that are already there, unchanged', { timeout: 60_000 }, () => {
    const engine = engineWith();
    expect(warm(engine)).toBe(5);
    engine.addItems(LIBRARY.slice(0, 10));
    expect(engine.getMemoStats().size).toBe(5);
  });

  // Judge's must-fix 2. setStyle re-adds the engine's own STORED items, whose ids are already lower-cased; Better BibTeX keys usually
  // carry capitals. If the comparison read the incoming item instead of the stored one, the app's re-push of the original library (it
  // pushes it at every mount) would read as "changed" after a style change and throw the filled memo away.
  it(
    'the app re-pushing the same mixed-case-id library AFTER a style change keeps what was formatted under the new style',
    {
      timeout: 60_000,
    },
    () => {
      const library = mixedCaseIds(LIBRARY);
      const engine = engineWith(undefined, library);
      expect(engine.hasItem('adams1999')).toBe(true);

      expect(engine.setStyle(NOTE_STYLE)).toBe(true);
      expect(engine.getMemoStats().size).toBe(0);
      const noteTexts = formatAll(engine, warmGroups());
      expect(engine.getMemoStats().size).toBe(5);

      // The mount's push: the original items, original-case ids.
      engine.setBibliography(library);
      expect(engine.getMemoStats().size).toBe(5);
      const hitsBefore = engine.getMemoStats().hits;
      expect(formatAll(engine, warmGroups())).toEqual(noteTexts);
      expect(engine.getMemoStats().hits).toBe(hitsBefore + 5);
      // What was kept is also what a memo-less engine gives for the same style and library.
      expect(noteTexts).toEqual(referenceFor(warmGroups(), NOTE_STYLE, library));

      // The same through addItems.
      engine.addItems(library.slice(0, 12));
      expect(engine.getMemoStats().size).toBe(5);

      // And an edit through the same mixed-case route still empties it.
      engine.setBibliography(withEditedYear(library, 'Evans2015', 2016));
      expect(engine.getMemoStats().size).toBe(0);
    }
  );

  it('a repeated push of the same library keeps the memo, without any style change', { timeout: 60_000 }, () => {
    const library = mixedCaseIds(LIBRARY);
    const engine = engineWith(undefined, library);
    expect(warm(engine)).toBe(5);
    engine.setBibliography(library);
    engine.setBibliography(library);
    expect(engine.getMemoStats().size).toBe(5);
  });

  // The assumption behind keeping the memo across an unchanged push: pushing the same items again (the engine re-registers them) does
  // not change what the engine would answer for any group.
  for (const [name, style] of [
    ['bundled Chicago author-date', undefined],
    ['note style', NOTE_STYLE],
  ] as const) {
    it(`an unchanged re-push of the library changes no answer (${name})`, { timeout: 120_000 }, () => {
      const groups = purityGroups();
      const engine = engineWith(style, mixedCaseIds(LIBRARY));
      engine.setMemoEnabled(false);
      const before = formatAll(engine, groups);
      engine.setBibliography(mixedCaseIds(LIBRARY));
      engine.addItems(mixedCaseIds(LIBRARY).slice(0, 15));
      expect(formatAll(engine, groups)).toEqual(before);
    });
  }
});

describe('unresolved and partly resolved groups', () => {
  it(
    'a group with no key in the library returns "key?" and is never stored, never counted',
    { timeout: 60_000 },
    () => {
      const engine = engineWith();
      const before = engine.getMemoStats();
      expect(engine.formatCitation(['nosuchkey'])).toBe('nosuchkey?');
      expect(engine.formatCitation(['nosuchkey', 'alsomissing'])).toBe('nosuchkey?; alsomissing?');
      expect(engine.getMemoStats()).toEqual(before);
      expect(engine.getMemoStats().size).toBe(0);
    }
  );

  it(
    'a group with one missing key is stored under its full key list, and replaced by the full text once the item arrives',
    { timeout: 60_000 },
    () => {
      const engine = engineWith();
      const partly = engine.formatCitation(['adams1999', 'zeta2021']);
      expect(engine.getMemoStats().size).toBe(1);
      expect(engine.formatCitation(['adams1999', 'zeta2021'])).toBe(partly);
      expect(engine.getMemoStats().hits).toBe(1);

      engine.addItems([book('zeta2021', [n('Zeta', 'Zoe')], 2021, 'An Unrelated Work')]);
      expect(engine.getMemoStats().size).toBe(0);
      const complete = engine.formatCitation(['adams1999', 'zeta2021']);
      expect(complete).not.toBe(partly);
      expect(complete).toContain('Zeta');

      const fresh = engineWith(undefined, [
        ...LIBRARY,
        book('zeta2021', [n('Zeta', 'Zoe')], 2021, 'An Unrelated Work'),
      ]);
      fresh.setMemoEnabled(false);
      expect(complete).toBe(fresh.formatCitation(['adams1999', 'zeta2021']));
    }
  );

  it('an edited item is shown with its new data, not the remembered text', { timeout: 60_000 }, () => {
    const engine = engineWith();
    expect(engine.formatCitation(['adams1999'])).toBe('(Adams 1999)');
    expect(engine.formatCitation(['adams1999'])).toBe('(Adams 1999)');
    expect(engine.getMemoStats().hits).toBe(1);

    engine.setBibliography(withEditedYear(LIBRARY, 'adams1999', 2001));
    expect(engine.formatCitation(['adams1999'])).toBe('(Adams 2001)');

    engine.addItems(withEditedYear(LIBRARY, 'adams1999', 2003).filter((item) => item.id === 'adams1999'));
    expect(engine.formatCitation(['adams1999'])).toBe('(Adams 2003)');
  });
});

describe('only processor output is ever stored', () => {
  it('a processor error is not stored, and the next call asks the processor again', { timeout: 60_000 }, () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    const engine = engineWith();
    const internal = (engine as unknown as { engine: { processCitationCluster: (...a: unknown[]) => unknown } }).engine;
    const real = internal.processCitationCluster.bind(internal);
    const spy = vi.spyOn(internal, 'processCitationCluster').mockImplementation(() => {
      throw new Error('boom');
    });

    expect(engine.formatCitation(['adams1999'])).toBe('adams1999');
    expect(engine.getMemoStats().size).toBe(0);

    spy.mockImplementation(real);
    expect(engine.formatCitation(['adams1999'])).toBe('(Adams 1999)');
    expect(engine.getMemoStats().size).toBe(1);
  });

  it('a result with no formatted text is not stored', { timeout: 60_000 }, () => {
    const engine = engineWith();
    const internal = (engine as unknown as { engine: { processCitationCluster: (...a: unknown[]) => unknown } }).engine;
    const real = internal.processCitationCluster.bind(internal);
    const spy = vi.spyOn(internal, 'processCitationCluster').mockImplementation(() => [{}, []]);

    expect(engine.formatCitation(['adams1999', 'baker2003'])).toBe('adams1999; baker2003');
    expect(engine.getMemoStats().size).toBe(0);

    spy.mockImplementation(real);
    expect(engine.formatCitation(['adams1999', 'baker2003'])).toContain('Adams');
    expect(engine.getMemoStats().size).toBe(1);
  });
});

describe('the memo switch', () => {
  it('is on by default, and a disabled memo is off the code path entirely', { timeout: 60_000 }, () => {
    expect(new CiteprocEngine().getMemoStats().enabled).toBe(true);

    const engine = engineWith();
    engine.setMemoEnabled(false);
    const g = group('@adams1999, p. 4');
    for (let i = 0; i < 3; i++) format(engine, g);
    expect(engine.getMemoStats()).toEqual({ size: 0, hits: 0, misses: 0, enabled: false });
    expect(engine.isMemoized(g.citekeys, g.options)).toBe(false);
  });

  it(
    'library edits made while the memo is off are never served stale after turning it on again',
    { timeout: 60_000 },
    () => {
      const engine = engineWith();
      expect(engine.formatCitation(['adams1999'])).toBe('(Adams 1999)');
      engine.setMemoEnabled(false);
      engine.setBibliography(withEditedYear(LIBRARY, 'adams1999', 2001));
      engine.setMemoEnabled(true);
      expect(engine.getMemoStats().size).toBe(0);
      expect(engine.formatCitation(['adams1999'])).toBe('(Adams 2001)');
      // Tracking resumed from the library as it stands now: the same library again keeps the memo, an edit empties it.
      engine.setBibliography(withEditedYear(LIBRARY, 'adams1999', 2001));
      expect(engine.getMemoStats().size).toBe(1);
      engine.setBibliography(LIBRARY);
      expect(engine.getMemoStats().size).toBe(0);
      expect(engine.formatCitation(['adams1999'])).toBe('(Adams 1999)');
    }
  );

  it(
    'setCitationMemoEnabled applies to the engine that exists and to engines built later, without building one',
    { timeout: 60_000 },
    () => {
      resetCiteprocEngine();
      expect(getCitationMemoStats()).toEqual({ size: 0, hits: 0, misses: 0, enabled: true });
      setCitationMemoEnabled(false);
      // No engine was built to set the flag...
      expect(getCitationMemoStats()).toEqual({ size: 0, hits: 0, misses: 0, enabled: false });
      // ...and the one built later starts with it off.
      expect(getCiteprocEngine().getMemoStats().enabled).toBe(false);
      setCitationMemoEnabled(true);
      expect(getCiteprocEngine().getMemoStats().enabled).toBe(true);
    }
  );
});

describe('counters', () => {
  it('counts a hit per remembered answer and a miss per processor run', { timeout: 60_000 }, () => {
    const engine = engineWith();
    formatAll(engine, warmGroups());
    expect(engine.getMemoStats()).toMatchObject({ size: 5, hits: 0, misses: 5 });
    formatAll(engine, warmGroups());
    expect(engine.getMemoStats()).toMatchObject({ size: 5, hits: 5, misses: 5 });
  });
});

describe('the cap', () => {
  it('empties the memo when it would pass 5000 entries and keeps working', { timeout: 120_000 }, () => {
    const engine = engineWith();
    // 5000 distinct requests: one key, a different locator each time.
    const request = (i: number) => engine.formatCitation(['adams1999'], { locators: [`p. ${i}`] });
    for (let i = 0; i < 5000; i++) request(i);
    expect(engine.getMemoStats().size).toBe(5000);
    const text = request(5000);
    // The 5001st distinct request emptied the memo first and was then stored on its own.
    expect(engine.getMemoStats().size).toBe(1);
    expect(text).toContain('5000');
    expect(request(5000)).toBe(text);
    expect(engine.getMemoStats().hits).toBe(1);
  });
});
