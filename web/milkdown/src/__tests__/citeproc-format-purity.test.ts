// @vitest-environment jsdom
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { afterAll, describe, expect, it } from 'vitest';
import { citationBracketRegex } from '../citation-types';
import { CiteprocEngine, type CSLItem } from '../citeproc-engine';
import {
  book,
  documentGroups,
  type Group,
  groupFromBracket,
  LIBRARY,
  NOTE_STYLE,
  n,
  purityGroups,
  RELATED_ITEM,
  shuffled,
  UNRELATED_ITEM,
} from './citation-fixtures';

// Facts first, before any citation cache is built (plan: plan-book-length-switch.md, Step 3a).
//
// A citation cache is only safe if what `CiteprocEngine.formatCitation` returns is a pure function of
// (group, style, locale, library): the same group must come out as the same string whatever was
// formatted before it, in any order, and however often. This file tests exactly that, in the bundled
// Chicago author-date style and in a small hand-written note style with "ibid." and a subsequent short
// form (users can load custom styles), and it measures what a cache would save:
//   - how many of a document's citation groups are distinct (a cache formats each distinct group once);
//   - what one `formatCitation` call costs for a first-time group versus a repeat, and what a cache hit costs.
// Facts are printed with a `[CITE-FACTS]` prefix and written to
// `<worktree>/.claude/scratch/unit-out/cite-facts.txt` (git-ignored; overwritten on each run; a failed
// write never fails a test). No behaviour of the app depends on any of it.
//
// The user's own article is private. When the environment variable FF_PRIVATE_SAMPLE_ARTICLE names a
// file, its citation groups are read at test time and only COUNTS and timings are printed; its text is
// never copied anywhere. When the variable is unset that one test skips.

// ---------------------------------------------------------------------------------------------------
// Facts file
// ---------------------------------------------------------------------------------------------------

const factLines: string[] = [];

function fact(line: string): void {
  factLines.push(line);
  console.log(`[CITE-FACTS] ${line}`);
}

afterAll(() => {
  if (factLines.length === 0) return;
  try {
    // Plain string handling, not `new URL(...)`: under jsdom the URL class is jsdom's, which Node's
    // fileURLToPath refuses. This file sits at <worktree>/web/milkdown/src/__tests__/.
    const here = decodeURIComponent(import.meta.url.replace(/^file:\/\//, ''));
    const dir = resolve(dirname(here), '../../../../.claude/scratch/unit-out');
    mkdirSync(dir, { recursive: true });
    writeFileSync(resolve(dir, 'cite-facts.txt'), `${factLines.map((l) => `[CITE-FACTS] ${l}`).join('\n')}\n`);
  } catch (error) {
    console.log(`[CITE-FACTS] (could not write cite-facts.txt: ${String(error)})`);
  }
});

function formatGroup(engine: CiteprocEngine, group: Group): string {
  return engine.formatCitation(group.citekeys, group.options);
}

// The key the planned cache would use (plan Step 3b): the valid keys in order, normalised, with the
// per-position suppress-author flag and locator, plus prefix and suffix.
function cacheKeyOf(engine: CiteprocEngine, group: Group): string {
  const valid = group.citekeys.filter((k) => engine.hasItem(k)).map((k) => k.toLowerCase());
  const positions = valid.map((k, i) => [k, !!group.options.suppressAuthors?.[i], group.options.locators?.[i] || '']);
  return JSON.stringify([positions, group.options.prefix || '', group.options.suffix || '']);
}

function engineWithLibrary(style?: string, items: CSLItem[] = LIBRARY): CiteprocEngine {
  const engine = new CiteprocEngine(style);
  engine.setBibliography(items);
  return engine;
}

function formatAll(engine: CiteprocEngine, groups: Group[]): string[] {
  return groups.map((g) => formatGroup(engine, g));
}

// Differences between a reference result and another run, as readable lines.
function differences(groups: Group[], reference: string[], other: string[]): string[] {
  const lines: string[] = [];
  for (let i = 0; i < groups.length; i++) {
    if (reference[i] !== other[i]) {
      lines.push(`${groups[i].label}: reference "${reference[i]}" vs "${other[i]}"`);
    }
  }
  return lines;
}

// ---------------------------------------------------------------------------------------------------
// 1. Author-date: is the output a pure function of (group, style, locale, library)?
// ---------------------------------------------------------------------------------------------------

describe('formatCitation purity, bundled Chicago author-date style', () => {
  const groups = purityGroups();
  const ID = groups.length;

  it('has a reference run that covers every kind of group, and is not just empty strings', { timeout: 120_000 }, () => {
    const engine = engineWithLibrary();
    const reference = formatAll(engine, groups);
    expect(reference).toHaveLength(ID);
    for (const text of reference) expect(text.length).toBeGreaterThan(0);

    // What the app's call shape (one lone cluster per call, no notes before or after) does with
    // disambiguation: a work alone reads "Lee 2010"; the year suffix only appears when both works are
    // cited in the SAME group. Nothing else in the library, and nothing formatted earlier, enters into it.
    const textOf = (label: string) => reference[groups.findIndex((g) => g.label === label)];
    expect(textOf('[@lee2010a]')).toBe('(Lee 2010)');
    expect(textOf('[@lee2010b]')).toBe('(Lee 2010)');
    expect(textOf('[@lee2010a; @lee2010b]')).toContain('2010a');
    expect(textOf('[@lee2010a; @lee2010b]')).toContain('2010b');
    fact(
      `author-date library: ${LIBRARY.length} items, ${groups.length} distinct test groups (plain, page numbers, several keys, suppressed author, prefix, suffix, one unresolved key)`
    );
    fact(
      `author-date same-author same-year works under the app's call shape: [@lee2010a] -> "${textOf('[@lee2010a]')}", [@lee2010b] -> "${textOf('[@lee2010b]')}", [@lee2010a; @lee2010b] -> "${textOf('[@lee2010a; @lee2010b]')}" (the year suffix appears only inside one group); [@park2014x] -> "${textOf('[@park2014x]')}"; [@brown2013] -> "${textOf('[@brown2013]')}"`
    );
  });

  it(
    'gives the same string in document order, reverse order, a shuffled order, and when the sequence is repeated three times',
    { timeout: 120_000 },
    () => {
      const reference = formatAll(engineWithLibrary(), groups);

      const reverseEngine = engineWithLibrary();
      const reverseOrder = [...groups].reverse();
      const reverseOut = formatAll(reverseEngine, reverseOrder).reverse();
      const reverseDiffs = differences(groups, reference, reverseOut);

      const shuffleEngine = engineWithLibrary();
      const order = shuffled(groups.map((_, i) => i));
      const shuffleOut: string[] = [];
      for (const i of order) shuffleOut[i] = formatGroup(shuffleEngine, groups[i]);
      const shuffleDiffs = differences(groups, reference, shuffleOut);

      const repeatEngine = engineWithLibrary();
      const pass1 = formatAll(repeatEngine, groups);
      const pass2 = formatAll(repeatEngine, groups);
      const pass3 = formatAll(repeatEngine, groups);
      const repeatDiffs = [
        ...differences(groups, reference, pass1),
        ...differences(groups, reference, pass2),
        ...differences(groups, reference, pass3),
      ];

      // The same group three times in a row (the shape a repeated citation takes in a document).
      const rowEngine = engineWithLibrary();
      const rowDiffs: string[] = [];
      groups.forEach((g, i) => {
        for (let k = 0; k < 3; k++) {
          const out = formatGroup(rowEngine, g);
          if (out !== reference[i]) rowDiffs.push(`${g.label}: "${reference[i]}" vs "${out}" (call ${k + 1})`);
        }
      });

      fact(
        `author-date order independence: reverse order ${reverseDiffs.length === 0 ? 'identical' : `DIFFERS in ${reverseDiffs.length}`}, shuffled order ${shuffleDiffs.length === 0 ? 'identical' : `DIFFERS in ${shuffleDiffs.length}`}, sequence repeated 3 times ${repeatDiffs.length === 0 ? 'identical' : `DIFFERS in ${repeatDiffs.length}`}, same group 3 times in a row ${rowDiffs.length === 0 ? 'identical' : `DIFFERS in ${rowDiffs.length}`} (${groups.length} groups each)`
      );
      expect(reverseDiffs).toEqual([]);
      expect(shuffleDiffs).toEqual([]);
      expect(repeatDiffs).toEqual([]);
      expect(rowDiffs).toEqual([]);
    }
  );

  it(
    'gives the same string on a fresh engine as on one that has formatted everything else first',
    { timeout: 300_000 },
    () => {
      const reference = formatAll(engineWithLibrary(), groups);
      // Each of these is the kind of group most likely to depend on the rest of the library or on history:
      // year suffixes, shared surnames, "et al.", collapsed same-author clusters, prefix and suffix, a
      // located group, and a group with an unresolved key.
      const sampleLabels = [
        '[@lee2010a]',
        '[@lee2010b]',
        '[@park2014x]',
        '[@kim2015]',
        '[@brown2013]',
        '[@lee2010a; @lee2010b]',
        '[see @adams1999, p. 4]',
        '[@adams1999 and passim]',
        '[@adams1999; @nosuchkey]',
        '[-@lee2010a, p. 5]',
      ];
      const diffs: string[] = [];
      for (const label of sampleLabels) {
        const index = groups.findIndex((g) => g.label === label);
        expect(index).toBeGreaterThanOrEqual(0);
        const fresh = formatGroup(engineWithLibrary(), groups[index]);
        if (fresh !== reference[index]) diffs.push(`${label}: reference "${reference[index]}" vs fresh "${fresh}"`);
      }
      fact(
        `author-date fresh engine per group: ${diffs.length === 0 ? 'identical' : `DIFFERS in ${diffs.length}`} (${sampleLabels.length} groups, each on its own newly built engine)`
      );
      expect(diffs).toEqual([]);
    }
  );

  it(
    'keeps no record of earlier groups: citeproc holds one citation however many were formatted',
    { timeout: 120_000 },
    () => {
      // Every call hands citeproc a lone cluster with no notes before or after, and citeproc replaces
      // the set of citations it knows with exactly that one. That is why nothing formatted earlier can
      // reach the next result.
      const engine = engineWithLibrary();
      const raw = (engine as unknown as { engine: any }).engine;
      const known = () => raw.registry.citationreg.citationByIndex.length;
      formatGroup(engine, groups[0]);
      const afterOne = known();
      for (let round = 0; round < 3; round++) formatAll(engine, groups);
      const afterMany = known();
      fact(
        `author-date citations citeproc keeps after 1 call: ${afterOne}; after ${1 + 3 * groups.length} calls: ${afterMany} (every call replaces the last, so nothing carries over)`
      );
      expect(afterOne).toBe(1);
      expect(afterMany).toBe(1);
    }
  );

  it(
    'is not changed by generateBibliography() with every key, or by addItems() of an unrelated item, between formats',
    { timeout: 300_000 },
    () => {
      const reference = formatAll(engineWithLibrary(), groups);

      const allKeysEngine = engineWithLibrary();
      const allKeysOut = groups.map((g) => {
        const out = formatGroup(allKeysEngine, g);
        allKeysEngine.generateBibliography();
        return out;
      });
      const allKeysDiffs = differences(groups, reference, allKeysOut);

      const unrelatedEngine = engineWithLibrary();
      const unrelatedOut = groups.map((g, i) => {
        if (i === Math.floor(groups.length / 2)) unrelatedEngine.addItems([UNRELATED_ITEM]);
        return formatGroup(unrelatedEngine, g);
      });
      const unrelatedDiffs = differences(groups, reference, unrelatedOut);

      fact(
        `author-date generateBibliography() with all keys between formats: ${allKeysDiffs.length === 0 ? 'identical' : `DIFFERS in ${allKeysDiffs.length}`}; addItems(one unrelated item) between formats: ${unrelatedDiffs.length === 0 ? 'identical' : `DIFFERS in ${unrelatedDiffs.length}`}`
      );
      expect(allKeysDiffs).toEqual([]);
      expect(unrelatedDiffs).toEqual([]);
    }
  );

  it(
    'is not changed by generateBibliography(subset of keys) between formats, whichever subset',
    { timeout: 600_000 },
    () => {
      const reference = formatAll(engineWithLibrary(), groups);

      // generateBibliography(subset) calls engine.updateItems(subset), which leaves only those items
      // registered with citeproc. The app has no caller of this form today. Subsets chosen to leave out
      // the keys of most groups, to hold only one of two works that disambiguate each other, and to hold
      // a single unrelated key.
      const subsets: string[][] = [
        ['adams1999', 'baker2003', 'chen2011'],
        ['lee2010a'],
        ['lee2010b', 'park2014x'],
        ['zhou2004'],
      ];
      const lines: string[] = [];
      for (const subsetKeys of subsets) {
        const engine = engineWithLibrary();
        const out = groups.map((g) => {
          engine.generateBibliography(subsetKeys);
          return formatGroup(engine, g);
        });
        const diffs = differences(groups, reference, out);
        lines.push(
          `${subsetKeys.length} key(s) from ${subsetKeys[0]}: ${diffs.length === 0 ? 'identical' : `DIFFERS in ${diffs.length}`}`
        );
        expect(diffs).toEqual([]);
      }
      fact(
        `author-date generateBibliography(subset) immediately before each of ${groups.length} formats, ${subsets.length} different subsets: ${lines.join('; ')}`
      );
    }
  );

  it(
    "depends on the library only through the cited works' data: a related work in the library changes nothing, an edited work does",
    { timeout: 120_000 },
    () => {
      const group = groupFromBracket('@adams1999');
      const both = groupFromBracket('@adams1999; @adams1999b');
      const alone = formatGroup(engineWithLibrary(), group);

      // A same-author same-year sibling in the library does not change a group that does not cite it ...
      const withSiblingEngine = engineWithLibrary();
      withSiblingEngine.addItems([RELATED_ITEM]);
      const withSibling = formatGroup(withSiblingEngine, group);
      expect(withSibling).toBe(alone);
      // ... but a group that cites both gets the year suffix.
      const bothText = formatGroup(withSiblingEngine, both);
      expect(bothText).toContain('1999a');

      // Changing the data of the cited work itself (same id, new year) changes the output: the library
      // is an input, so a cache has to be emptied whenever the library changes.
      const changedEngine = engineWithLibrary();
      changedEngine.addItems([{ ...LIBRARY[0], issued: { 'date-parts': [[2005]] } }]);
      const changed = formatGroup(changedEngine, group);
      expect(changed).not.toBe(alone);

      fact(
        `author-date library as an input: [@adams1999] "${alone}" is unchanged by a same-author same-year sibling in the library ("${withSibling}") and becomes "${changed}" when that work's own year is edited; a group citing both reads "${bothText}"`
      );
    }
  );
});

// ---------------------------------------------------------------------------------------------------
// 2. A note style with ibid and a subsequent short form
// ---------------------------------------------------------------------------------------------------

describe('formatCitation purity, hand-written note style with ibid and subsequent short forms', () => {
  const key = (id: string, locator?: string): Group => ({
    label: `${id}${locator ? `, ${locator}` : ''}`,
    citekeys: [id],
    options: locator ? { locators: [locator] } : {},
  });

  it(
    'is a valid note style that really produces ibid. and a short form when citeproc is given the notes before',
    { timeout: 120_000 },
    () => {
      const engine = engineWithLibrary(NOTE_STYLE);
      const raw = (engine as unknown as { engine: any }).engine;
      // Driven the way a word processor would: each note is told which notes came before it.
      const textFor = (result: any, citationID: string): string => {
        const entry = result[1].find((row: any[]) => row[2] === citationID);
        return entry ? entry[1] : '(not returned)';
      };
      const note = (id: string, key: string, noteIndex: number, pre: [string, number][]) =>
        textFor(
          raw.processCitationCluster(
            { citationID: id, citationItems: [{ id: key }], properties: { noteIndex } },
            pre,
            []
          ),
          id
        );
      const firstText = note('n1', 'adams1999', 1, []);
      const secondText = note('n2', 'adams1999', 2, [['n1', 1]]);
      const thirdText = note('n3', 'baker2003', 3, [
        ['n1', 1],
        ['n2', 2],
      ]);
      const fourthText = note('n4', 'adams1999', 4, [
        ['n1', 1],
        ['n2', 2],
        ['n3', 3],
      ]);
      fact(
        `note style with real note positions (this is NOT how the app calls it): 1st "${firstText}", 2nd same work "${secondText}", 3rd other work "${thirdText}", 4th first work again "${fourthText}"`
      );
      expect(secondText.toLowerCase()).toContain('ibid');
      expect(fourthText).not.toBe(firstText);
      expect(fourthText.toLowerCase()).not.toContain('ibid');
    }
  );

  it(
    "gives the same string for the same group three times in a row with the app's call shape (no notes before, noteIndex 0)",
    { timeout: 120_000 },
    () => {
      const engine = engineWithLibrary(NOTE_STYLE);
      const group = key('adams1999', 'p. 12');
      const outputs = [formatGroup(engine, group), formatGroup(engine, group), formatGroup(engine, group)];
      fact(
        `note style, same group 3 times in a row: "${outputs[0]}" | "${outputs[1]}" | "${outputs[2]}" => ${outputs[0] === outputs[1] && outputs[1] === outputs[2] ? 'identical' : 'DIFFERS'}`
      );
      // A real rendering (author, title, locator), not the engine's fallback of echoing the keys back.
      expect(outputs[0]).toContain('Adams');
      expect(outputs[0]).toContain('12');
      expect(outputs[1]).toBe(outputs[0]);
      expect(outputs[2]).toBe(outputs[0]);
      // The app never tells citeproc about earlier notes, so every call is the first note: no "ibid."
      expect(outputs[0].toLowerCase()).not.toContain('ibid');
    }
  );

  it(
    'gives the same string whatever was formatted before: A B A A B, fresh engines, reverse order',
    { timeout: 300_000 },
    () => {
      const a = key('adams1999');
      const b = key('baker2003', 'p. 3');
      const c = key('lee2010a');
      const all = [a, b, c];

      const freshOut = all.map((g) => formatGroup(engineWithLibrary(NOTE_STYLE), g));
      for (let i = 0; i < all.length; i++) expect(freshOut[i]).not.toBe(all[i].citekeys[0]);

      const sequence = [a, b, a, a, b, c, c, a, c, b, b];
      const engine = engineWithLibrary(NOTE_STYLE);
      const seqDiffs: string[] = [];
      for (const g of sequence) {
        const out = formatGroup(engine, g);
        const expected = freshOut[all.indexOf(g)];
        if (out !== expected) seqDiffs.push(`${g.label}: fresh "${expected}" vs "${out}"`);
      }

      const reverseEngine = engineWithLibrary(NOTE_STYLE);
      const reverseOut = [...all]
        .reverse()
        .map((g) => formatGroup(reverseEngine, g))
        .reverse();
      const reverseDiffs = differences(all, freshOut, reverseOut);

      // generateBibliography(all keys) and addItems(unrelated) between formats, as in the author-date test.
      const interleaved = engineWithLibrary(NOTE_STYLE);
      const interleavedDiffs: string[] = [];
      for (const g of sequence) {
        interleaved.generateBibliography();
        interleaved.addItems([UNRELATED_ITEM]);
        const out = formatGroup(interleaved, g);
        const expected = freshOut[all.indexOf(g)];
        if (out !== expected) interleavedDiffs.push(`${g.label}: fresh "${expected}" vs "${out}"`);
      }

      // generateBibliography(subset) between formats: recorded.
      const subsetEngine = engineWithLibrary(NOTE_STYLE);
      const subsetDiffs: string[] = [];
      for (const g of sequence) {
        subsetEngine.generateBibliography(['adams1999']);
        const out = formatGroup(subsetEngine, g);
        const expected = freshOut[all.indexOf(g)];
        if (out !== expected) subsetDiffs.push(`${g.label}: fresh "${expected}" vs "${out}"`);
      }

      fact(
        `note style: A B A A B C C A C B B on one engine vs fresh engines ${seqDiffs.length === 0 ? 'identical' : `DIFFERS in ${seqDiffs.length}`}; reverse order ${reverseDiffs.length === 0 ? 'identical' : `DIFFERS in ${reverseDiffs.length}`}; with generateBibliography(all keys) + addItems(unrelated) between ${interleavedDiffs.length === 0 ? 'identical' : `DIFFERS in ${interleavedDiffs.length}`}; with generateBibliography(1 key) between ${subsetDiffs.length === 0 ? 'identical' : `DIFFERS in ${subsetDiffs.length}`}`
      );
      expect(seqDiffs).toEqual([]);
      expect(reverseDiffs).toEqual([]);
      expect(interleavedDiffs).toEqual([]);
      expect(Array.isArray(subsetDiffs)).toBe(true);
    }
  );
});

// ---------------------------------------------------------------------------------------------------
// 3. How many groups are distinct, and what would a cache save?
// ---------------------------------------------------------------------------------------------------

interface DistinctCount {
  total: number;
  distinct: number;
}

function distinctCount(engine: CiteprocEngine, groups: Group[]): DistinctCount {
  return { total: groups.length, distinct: new Set(groups.map((g) => cacheKeyOf(engine, g))).size };
}

function pct(part: number, whole: number): string {
  return `${((100 * part) / whole).toFixed(1)}%`;
}

function median(values: number[]): number {
  const sorted = [...values].sort((x, y) => x - y);
  return sorted[Math.floor(sorted.length / 2)];
}

function mean(values: number[]): number {
  return values.length === 0 ? 0 : values.reduce((sum, v) => sum + v, 0) / values.length;
}

interface RunTiming {
  total: number; // all calls, ms
  firstCalls: number[]; // ms, calls whose group had not been formatted yet in this run
  repeatCalls: number[]; // ms, calls whose group had been formatted before in this run
  outputs: string[];
  firstHundred: number; // mean ms of the first 100 calls
  lastHundred: number; // mean ms of the last 100 calls
  perCall: number[]; // ms, every call in document order
}

// Format every group in document order on a freshly built engine, timing each call.
function timeUncachedRun(groups: Group[], items: CSLItem[]): RunTiming {
  const engine = engineWithLibrary(undefined, items);
  const seen = new Set<string>();
  const firstCalls: number[] = [];
  const repeatCalls: number[] = [];
  const perCall: number[] = [];
  const outputs: string[] = [];
  const start = performance.now();
  for (const g of groups) {
    const key = cacheKeyOf(engine, g);
    const t0 = performance.now();
    const out = formatGroup(engine, g);
    const dt = performance.now() - t0;
    perCall.push(dt);
    outputs.push(out);
    if (seen.has(key)) repeatCalls.push(dt);
    else {
      seen.add(key);
      firstCalls.push(dt);
    }
  }
  const total = performance.now() - start;
  return {
    total,
    firstCalls,
    repeatCalls,
    outputs,
    firstHundred: mean(perCall.slice(0, 100)),
    lastHundred: mean(perCall.slice(-100)),
    perCall,
  };
}

// The same document with a cache in front of formatCitation, kept here in the test (the production
// engine has none): the cache key is built for every group, citeproc is called only on a miss.
function timeCachedRun(groups: Group[], items: CSLItem[]): { total: number; outputs: string[]; hits: number } {
  const engine = engineWithLibrary(undefined, items);
  const cache = new Map<string, string>();
  const outputs: string[] = [];
  let hits = 0;
  const start = performance.now();
  for (const g of groups) {
    const key = cacheKeyOf(engine, g);
    let out = cache.get(key);
    if (out === undefined) {
      out = formatGroup(engine, g);
      cache.set(key, out);
    } else {
      hits++;
    }
    outputs.push(out);
  }
  return { total: performance.now() - start, outputs, hits };
}

// Cost of one cache hit: building the key and a Map lookup.
function timeCacheHit(groups: Group[], engine: CiteprocEngine): number {
  const cache = new Map<string, string>();
  for (const g of groups) cache.set(cacheKeyOf(engine, g), 'x');
  const rounds = 20;
  const start = performance.now();
  let sink = 0;
  for (let r = 0; r < rounds; r++) {
    for (const g of groups) sink += cache.get(cacheKeyOf(engine, g))?.length ?? 0;
  }
  const elapsed = performance.now() - start;
  expect(sink).toBeGreaterThan(0);
  return elapsed / (rounds * groups.length);
}

function ms(value: number): string {
  return value.toFixed(3);
}

interface Measured {
  name: string;
  distinct: DistinctCount;
  uncachedTotal: number;
  cachedTotal: number;
  firstMean: number;
  repeatMean: number;
  hitCost: number;
  firstHundred: number;
  lastHundred: number;
  shapeCosts: string; // mean ms per call by kind of group
}

// A group with no page number or section and one key, several keys, or with a page number or section.
function shapeOf(group: Group): string {
  if (group.options.locators?.some(Boolean)) return 'with page number or section';
  return group.citekeys.length === 1 ? 'plain single' : 'plain several keys';
}

function shapeCostLine(groups: Group[], perCall: number[]): string {
  const sums = new Map<string, { total: number; count: number }>();
  groups.forEach((g, i) => {
    const shape = shapeOf(g);
    const entry = sums.get(shape) ?? { total: 0, count: 0 };
    entry.total += perCall[i];
    entry.count++;
    sums.set(shape, entry);
  });
  return [...sums.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([shape, { total, count }]) => `${shape} ${ms(total / count)} ms (${count} calls)`)
    .join(', ');
}

function measureDocument(name: string, groups: Group[], items: CSLItem[]): Measured {
  const probe = engineWithLibrary(undefined, items);
  const distinct = distinctCount(probe, groups);
  const hitCost = timeCacheHit(groups, probe);

  const run1 = timeUncachedRun(groups, items);
  const run2 = timeUncachedRun(groups, items);
  const cached = timeCachedRun(groups, items);

  // A cache must change nothing visible.
  expect(cached.outputs).toEqual(run1.outputs);
  expect(run2.outputs).toEqual(run1.outputs);
  expect(cached.hits).toBe(groups.length - distinct.distinct);

  const uncachedTotal = median([run1.total, run2.total]);
  return {
    name,
    distinct,
    uncachedTotal,
    cachedTotal: cached.total,
    firstMean: median([mean(run1.firstCalls), mean(run2.firstCalls)]),
    repeatMean: run1.repeatCalls.length === 0 ? 0 : median([mean(run1.repeatCalls), mean(run2.repeatCalls)]),
    hitCost,
    firstHundred: median([run1.firstHundred, run2.firstHundred]),
    lastHundred: median([run1.lastHundred, run2.lastHundred]),
    shapeCosts: shapeCostLine(
      groups,
      run1.perCall.map((v, i) => (v + run2.perCall[i]) / 2)
    ),
  };
}

function reportMeasured(m: Measured): void {
  const repeats = m.distinct.total - m.distinct.distinct;
  const saved = m.uncachedTotal - m.cachedTotal;
  fact(
    `${m.name}: ${m.distinct.total} groups, ${m.distinct.distinct} distinct (${pct(m.distinct.distinct, m.distinct.total)} distinct, ${pct(repeats, m.distinct.total)} repeats); uncached ${ms(m.uncachedTotal)} ms in the test environment, with a cache ${ms(m.cachedTotal)} ms (two separately timed runs, difference ${ms(saved)} ms = ${pct(saved, m.uncachedTotal)}; noisy on a small document or a busy machine, the per-call-mean line below is the steadier figure)`
  );
  fact(
    `${m.name}: per call, first-time group ${ms(m.firstMean)} ms, repeat of a group already formatted (no cache) ${ms(m.repeatMean)} ms, cache hit (build key + lookup) ${ms(m.hitCost)} ms; mean of calls 1-100 ${ms(m.firstHundred)} ms vs last 100 calls ${ms(m.lastHundred)} ms`
  );
  fact(`${m.name}: mean cost per call by kind of group: ${m.shapeCosts}`);
  // The difference of two separate timed runs is noisy on a small document; this one is built from the
  // per-call means: every repeat costs a cache hit instead of a citeproc call.
  const analyticSaved = repeats * (m.repeatMean - m.hitCost);
  fact(
    `${m.name}: expected saving from the per-call means (repeats x (repeat cost - hit cost)): ${ms(analyticSaved)} ms = ${pct(analyticSaved, m.uncachedTotal)} of the citation time`
  );
}

describe('how many citation groups are distinct, and what a cache would save', () => {
  const measured: Measured[] = [];

  it(
    'book of six chapters with different page numbers per chapter (the real-book stand-in, 256 of 408 distinct)',
    { timeout: 300_000 },
    () => {
      const groups = documentGroups(6, true);
      const probe = engineWithLibrary();
      const count = distinctCount(probe, groups);
      expect(count.total).toBe(408);
      expect(count.distinct).toBe(256);
      const m = measureDocument('six chapters, page numbers differ per chapter', groups, LIBRARY);
      measured.push(m);
      reportMeasured(m);
    }
  );

  it(
    'book of six identical chapters (the stand-in the timing tables use, 66 of 408 distinct)',
    { timeout: 300_000 },
    () => {
      const groups = documentGroups(6, false);
      const probe = engineWithLibrary();
      const count = distinctCount(probe, groups);
      expect(count.total).toBe(408);
      expect(count.distinct).toBe(66);
      const m = measureDocument('six identical chapters', groups, LIBRARY);
      measured.push(m);
      reportMeasured(m);
    }
  );

  it('one chapter on its own (the 68-group article)', { timeout: 300_000 }, () => {
    const groups = documentGroups(1, false);
    const probe = engineWithLibrary();
    const count = distinctCount(probe, groups);
    expect(count.total).toBe(68);
    expect(count.distinct).toBe(66);
    const m = measureDocument('one chapter', groups, LIBRARY);
    measured.push(m);
    reportMeasured(m);
  });

  it(
    'twelve chapters with different page numbers (816 groups): the cost per call does not grow with the number of calls',
    { timeout: 300_000 },
    () => {
      const groups = documentGroups(12, true);
      const probe = engineWithLibrary();
      const count = distinctCount(probe, groups);
      expect(count.total).toBe(816);
      expect(count.distinct).toBe(28 + 38 * 12);
      const m = measureDocument('twelve chapters, page numbers differ per chapter', groups, LIBRARY);
      measured.push(m);
      reportMeasured(m);
    }
  );

  const privatePath = process.env.FF_PRIVATE_SAMPLE_ARTICLE;
  it.skipIf(!privatePath)(
    'the private sample article named by FF_PRIVATE_SAMPLE_ARTICLE (counts and timings only)',
    { timeout: 300_000 },
    () => {
      const text = readFileSync(privatePath as string, 'utf-8');
      const regex = new RegExp(citationBracketRegex.source, 'g');
      const groups: Group[] = [];
      for (const match of text.matchAll(regex)) groups.push(groupFromBracket(match[1]));
      expect(groups.length).toBeGreaterThan(0);

      // A synthetic library holding exactly the sources the article cites, so every group resolves.
      const keys = Array.from(new Set(groups.flatMap((g) => g.citekeys.map((k) => k.toLowerCase()))));
      const items = keys.map((k, i) => book(k, [n(`Author${i}`, 'Test')], 1990 + (i % 30), `Title number ${i}`));

      const m = measureDocument('private sample article', groups, items);
      measured.push(m);
      reportMeasured(m);
      fact(
        `private sample article: ${keys.length} distinct sources cited; one chapter repeated six times would have ${groups.length * 6} groups`
      );
    }
  );

  it('prints the estimate table the driver needs: milliseconds saved at 408 and 816 groups for 37%, 23% and 84% repeats', () => {
    expect(measured.length).toBeGreaterThanOrEqual(3);
    // Use the page-number-differs document's per-call costs: a mix of plain and located groups, the
    // same mix the real article has.
    const basis = measured[0];
    const repeatShares = [
      { label: '37% repeats (six chapters, page numbers differ)', share: 0.373 },
      { label: "23% repeats (the user's own article)", share: 0.227 },
      { label: '84% repeats (six identical chapters)', share: 0.838 },
    ];
    for (const total of [408, 816]) {
      for (const { label, share } of repeatShares) {
        const repeats = total * share;
        const saved = repeats * (basis.repeatMean - basis.hitCost);
        fact(
          `estimate in the test environment: ${total} groups, ${label}: ${ms(saved)} ms saved of ${ms(total * ((1 - share) * basis.firstMean + share * basis.repeatMean))} ms uncached`
        );
      }
    }
    // The user's article repeats mostly its cheap plain groups, so its repeats cost less than the average
    // call: the same repeat share saves a smaller part of the time. Same arithmetic with its own costs.
    const own = measured.find((m) => m.name === 'private sample article');
    if (own) {
      for (const total of [408, 816]) {
        const repeats = (total * (own.distinct.total - own.distinct.distinct)) / own.distinct.total;
        const saved = repeats * (own.repeatMean - own.hitCost);
        const uncached = total * (own.uncachedTotal / own.distinct.total);
        fact(
          `estimate in the test environment with the user's article's own per-call costs: ${total} groups at its repeat share: ${ms(saved)} ms saved of ${ms(uncached)} ms uncached (${pct(saved, uncached)})`
        );
      }
    }
  });
});
