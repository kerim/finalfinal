// @vitest-environment jsdom
import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { history } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { getMarkdown } from '@milkdown/kit/utils';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { setContentWithBlockIds } from '../api-content';
import { blockIdPlugin, resetBlockIdState, setBlockIdZoomMode } from '../block-id-plugin';
import { blockSyncPlugin, resetBlockSyncState } from '../block-sync-plugin';
import { citationPlugin, clearPendingResolution } from '../citation-plugin';
import { prefillCitationsBegin, prefillCitationsStep } from '../citation-prefill';
import {
  type CitationOptions,
  CiteprocEngine,
  citationMemoKey,
  getCiteprocEngine,
  resetCiteprocEngine,
  setCitationMemoEnabled,
} from '../citeproc-engine';
import { getContentHasBeenSet, setEditorInstance } from '../editor-state';
import { footnotePlugin } from '../footnote-plugin';
import { highlightPlugin } from '../highlight-plugin';
import { chapterBrackets, LIBRARY, NOTE_STYLE } from './citation-fixtures';

// Ahead-of-time citation fill (plan: plan-citations-ahead-of-time.md, step W2; judge's must-fix 4).
//
// The fill must ask the citation engine for exactly what a real load asks for, change nothing in the editor, and leave a memo in which
// every entry equals what the engine would have produced anyway. Everything below runs on a REAL Milkdown editor with the citation and
// footnote plugins in main.ts's order, and the "real load" is the app's own entry point (`setContentWithBlockIds`), not a stand-in.
//
// Fixture documents are built from the purity file's chapter (68 citation groups over a 35-item library), with CJK prose, CJK locators,
// multi-key groups, suppressed authors, prefixes, citations inside footnote definitions, citation-looking brackets in inline code and in
// a code block (these are NOT citations), and one unresolved key (the last group of the last chapter).

const UNRESOLVED_KEY = 'nosuchsource2024';

// ---------------------------------------------------------------------------------------------------
// Fixture documents
// ---------------------------------------------------------------------------------------------------

interface FixtureDoc {
  name: string;
  markdown: string;
  /** Citation groups in the document, as built: chapters x 68. */
  groups: number;
  /** Groups placed inside footnote definitions. */
  footnoteGroups: number;
}

// A CJK locator for every even page number: a pure function of the bracket text, injective, so identical groups stay identical and
// different groups stay different (the distinct counts of the plain chapter are unchanged).
function decorate(inner: string): string {
  return inner.replace(/, p\. (\d*[02468])(?!\d)/, ', 第$1页');
}

function buildDocument(chapters: number, shiftPages: boolean): FixtureDoc {
  const parts: string[] = [];
  let groups = 0;
  let footnoteGroups = 0;
  let footnoteLabel = 0;

  for (let c = 0; c < chapters; c++) {
    const brackets = chapterBrackets(shiftPages ? c : 0).map(decorate);
    // The last group of the last chapter is a repeat of an earlier plain group; making it unresolved leaves the distinct count alone.
    if (c === chapters - 1) brackets[brackets.length - 1] = `@${UNRESOLVED_KEY}`;

    parts.push(`## 第${c + 1}章 Chapter ${c + 1}`);
    for (let start = 0, paragraph = 0; start < brackets.length; start += 4, paragraph++) {
      const slice = brackets.slice(start, start + 4);
      const definitions: string[] = [];
      const sentences = slice.map((bracket, k) => {
        groups++;
        if ((start + k) % 9 === 4) {
          // This one lives in a footnote definition.
          footnoteLabel++;
          footnoteGroups++;
          definitions.push(`[^${footnoteLabel}]: 脚注 ${footnoteLabel}，见 [${bracket}]。`);
          return `第${k + 1}句，注释在此[^${footnoteLabel}]`;
        }
        return k % 2 === 0
          ? `这一段讨论了相关研究 [${bracket}] 以及更多材料`
          : `Further discussion follows [${bracket}] in English`;
      });
      parts.push(`${sentences.join('。 ')}。`);
      if (definitions.length > 0) parts.push(definitions.join('\n\n'));
      if (paragraph === 0) {
        // Citation-looking text that is code, not a citation.
        parts.push('Inline code stays code: `[@adams1999]` and `[@baker2003, p. 5]`.');
        parts.push('```text\n[@adams1999] is not a citation here\n[@baker2003; @chen2011, p. 9]\n```');
      }
    }
  }
  return {
    name: `${chapters} chapter(s), ${shiftPages ? 'locators differ per chapter' : 'identical chapters'}`,
    markdown: `${parts.join('\n\n')}\n`,
    groups,
    footnoteGroups,
  };
}

// ---------------------------------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------------------------------

function waitForRAF(frames = 3): Promise<void> {
  return new Promise((resolve) => {
    let remaining = frames;
    const step = () => {
      remaining--;
      if (remaining <= 0) resolve();
      else requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  });
}

let editor: Editor | null = null;

async function mountEditor() {
  const div = document.createElement('div');
  document.body.appendChild(div);
  // main.ts's order: block plugins first, citation and footnote before commonmark/gfm.
  editor = await Editor.make()
    .config((ctx) => {
      ctx.set(rootCtx, div);
      ctx.set(defaultValueCtx, '');
    })
    .use(blockIdPlugin)
    .use(blockSyncPlugin)
    .use(citationPlugin)
    .use(footnotePlugin)
    .use(commonmark)
    .use(gfm)
    .use(highlightPlugin)
    .use(history)
    .create();
  setEditorInstance(editor);
  return editor.ctx.get(editorViewCtx);
}

async function unmountEditor() {
  setEditorInstance(null);
  if (editor) {
    await editor.destroy();
    editor = null;
  }
  resetBlockSyncState();
  resetBlockIdState();
  setBlockIdZoomMode(false);
  document.body.replaceChildren();
}

interface EngineSetup {
  memo?: boolean;
  style?: string;
  items?: typeof LIBRARY;
}

/** A fresh page-level engine, as a freshly loaded page holds one. */
function freshEngine(setup: EngineSetup = {}) {
  resetCiteprocEngine();
  setCitationMemoEnabled(setup.memo ?? true);
  const engine = getCiteprocEngine();
  if (setup.style) engine.setStyle(setup.style);
  engine.setBibliography(setup.items ?? LIBRARY);
  return engine;
}

type Call = [string[], CitationOptions | undefined];

function recordCalls(engine: CiteprocEngine) {
  const spy = vi.spyOn(engine, 'formatCitation');
  return {
    calls: (): Call[] => spy.mock.calls.map(([keys, options]) => [keys, options] as Call),
    keys: (): string[] => spy.mock.calls.map(([keys, options]) => citationMemoKey(keys, options)),
    stop: () => spy.mockRestore(),
  };
}

function citationTexts(root: HTMLElement): string[] {
  return Array.from(root.querySelectorAll('.ff-citation')).map((el) => `${el.className} | ${el.textContent}`);
}

interface LoadResult {
  keys: string[];
  calls: Call[];
  hits: number;
  misses: number;
  ms: number;
  texts: string[];
  markdown: string;
  citationNodes: number;
  /** Citation nodes that sit in a footnote definition paragraph (one that starts with the footnote_def pill). */
  footnoteCitations: number;
}

/** The app's real load of a document into the mounted editor. */
async function realLoad(markdown: string): Promise<LoadResult> {
  const view = editor!.ctx.get(editorViewCtx);
  const engine = getCiteprocEngine();
  const recorder = recordCalls(engine);
  const before = engine.getMemoStats();
  const t0 = performance.now();
  setContentWithBlockIds(markdown, []);
  const ms = performance.now() - t0;
  const after = engine.getMemoStats();
  const keys = recorder.keys();
  const calls = recorder.calls();
  recorder.stop();
  await waitForRAF();
  let citationNodes = 0;
  let footnoteCitations = 0;
  view.state.doc.descendants((node, _pos, parent) => {
    if (node.type.name === 'citation') {
      citationNodes++;
      if (parent?.firstChild?.type.name === 'footnote_def') footnoteCitations++;
    }
    return true;
  });
  return {
    keys,
    calls,
    hits: after.hits - before.hits,
    misses: after.misses - before.misses,
    ms,
    texts: citationTexts(view.dom),
    markdown: editor!.action(getMarkdown()),
    citationNodes,
    footnoteCitations,
  };
}

interface FillResult {
  begin: ReturnType<typeof prefillCitationsBegin>;
  steps: number;
  formatted: number;
  keys: string[];
  ms: number;
}

/** begin + steps (25 ms each) until done, recording what the fill asks the engine for. */
function runFill(markdown: string, budgetMs = 25): FillResult {
  const engine = getCiteprocEngine();
  const recorder = recordCalls(engine);
  const t0 = performance.now();
  const begin = prefillCitationsBegin(markdown);
  let steps = 0;
  let formatted = 0;
  for (;;) {
    const step = prefillCitationsStep(budgetMs);
    steps++;
    formatted += step.formatted;
    if (step.done) break;
    if (steps > 5000) throw new Error('fill does not finish');
  }
  const ms = performance.now() - t0;
  const keys = recorder.keys();
  recorder.stop();
  return { begin, steps, formatted, keys, ms };
}

/** What a real load gives with no fill and no memo (today's behaviour), in a throwaway editor. */
async function truthFor(markdown: string, setup: EngineSetup = {}): Promise<LoadResult> {
  await mountEditor();
  freshEngine({ ...setup, memo: false });
  const result = await realLoad(markdown);
  await unmountEditor();
  return result;
}

const fillTimings: string[] = [];

/** A fresh "ask the app to resolve a key" recorder, with the page's pending-key bookkeeping cleared as a fresh page has it. */
function resetResolutionSpy(): void {
  clearPendingResolution([UNRESOLVED_KEY]);
  (window as unknown as { FinalFinal: unknown }).FinalFinal = { requestCitationResolution: vi.fn() };
}

beforeEach(resetResolutionSpy);

afterEach(async () => {
  await unmountEditor();
  setCitationMemoEnabled(true);
  resetCiteprocEngine();
  delete (window as unknown as { FinalFinal?: unknown }).FinalFinal;
  vi.restoreAllMocks();
  // Prefill state is module-level: leave it empty for the next test.
  prefillCitationsBegin('');
});

function resolutionRequests(): string[][] {
  const spy = (window as unknown as { FinalFinal: { requestCitationResolution: ReturnType<typeof vi.fn> } }).FinalFinal
    .requestCitationResolution;
  return spy.mock.calls.map((call) => call[0] as string[]);
}

// ---------------------------------------------------------------------------------------------------
// The fill asks for what a real load asks for
// ---------------------------------------------------------------------------------------------------

const SCENARIOS: Array<{
  label: string;
  chapters: number;
  shift: boolean;
  groups: number;
  distinct: number;
  timeout: number;
}> = [
  { label: 'article-shaped, 68 groups', chapters: 1, shift: false, groups: 68, distinct: 66, timeout: 120_000 },
  {
    label: 'six chapters, 408 groups, 66 distinct',
    chapters: 6,
    shift: false,
    groups: 408,
    distinct: 66,
    timeout: 300_000,
  },
  {
    label: 'six chapters with different locators per chapter, 408 groups, 256 distinct',
    chapters: 6,
    shift: true,
    groups: 408,
    distinct: 256,
    timeout: 300_000,
  },
];

describe('the groups the fill asks for equal the groups a real load asks for', () => {
  for (const scenario of SCENARIOS) {
    it(
      `${scenario.label}: same requests, zero misses at the load, same text as a load with no fill`,
      { timeout: scenario.timeout },
      async () => {
        const doc = buildDocument(scenario.chapters, scenario.shift);
        // The numbers the title states are the numbers the fixture has.
        expect(doc.groups).toBe(scenario.groups);
        expect(doc.footnoteGroups).toBeGreaterThan(0);

        // 1. Ground truth: no fill, no memo (today's behaviour).
        const truth = await truthFor(doc.markdown);
        expect(truth.citationNodes).toBe(scenario.groups);
        expect(truth.footnoteCitations).toBe(doc.footnoteGroups); // the footnote-definition groups are real citation nodes of the parsed document
        const resolvable = scenario.groups - 1; // one unresolved key
        expect(truth.keys).toHaveLength(resolvable); // the node view makes no engine call for the unresolved group
        expect(new Set(truth.keys).size).toBe(scenario.distinct);
        // The unresolved key was asked of the app (not of the engine), and the CJK text came through.
        expect(truth.texts.some((t) => t.includes('ff-citation-unresolved') && t.includes(`${UNRESOLVED_KEY}?`))).toBe(
          true
        );
        expect(truth.markdown).toContain('第1章');
        // CJK locators come through the engine verbatim.
        expect(truth.texts.some((t) => /第\d+页/.test(t))).toBe(true);

        // 2. The fill, in a fresh editor and a fresh engine, then the real load in the same editor.
        resetResolutionSpy();
        const view = await mountEditor();
        const engine = freshEngine({ memo: true });
        const stateBefore = view.state;
        const contentSetBefore = getContentHasBeenSet();

        const fill = runFill(doc.markdown);

        // Nothing in the editor moved, nothing was asked of the app.
        expect(view.state).toBe(stateBefore);
        expect(getContentHasBeenSet()).toBe(contentSetBefore);
        expect(resolutionRequests()).toEqual([]);

        expect(fill.begin).toMatchObject({
          status: 'ok',
          groups: scenario.groups,
          distinct: scenario.distinct,
          pending: scenario.distinct,
          unresolved: 1,
        });
        expect(fill.formatted).toBe(scenario.distinct);
        // The set of requests the fill made equals the set a real load makes (verdict must-fix 4), and each was made once.
        expect(fill.keys).toHaveLength(scenario.distinct);
        expect(new Set(fill.keys)).toEqual(new Set(truth.keys));
        const afterFill = engine.getMemoStats();
        expect(afterFill).toMatchObject({ size: scenario.distinct, hits: 0, misses: scenario.distinct });

        const load = await realLoad(doc.markdown);

        // Misses 0 for every group whose keys are all in the library; hits at least that many.
        expect(load.misses).toBe(0);
        expect(load.hits).toBeGreaterThanOrEqual(resolvable);
        expect(new Set(load.keys)).toEqual(new Set(truth.keys));
        // The unresolved group is still resolved by the load as it always was: the app is asked for its key.
        expect(resolutionRequests().flat()).toEqual([UNRESOLVED_KEY]);
        // No leaked state: the same text, classes and serialised Markdown as a load that had no fill.
        expect(load.texts).toEqual(truth.texts);
        expect(load.markdown).toBe(truth.markdown);
        expect(load.citationNodes).toBe(scenario.groups);

        // The cold-memo load (memo on, nothing filled), for the timing report.
        await unmountEditor();
        await mountEditor();
        freshEngine({ memo: true });
        const cold = await realLoad(doc.markdown);
        expect(cold.texts).toEqual(truth.texts);
        expect(cold.markdown).toBe(truth.markdown);
        expect(cold.misses).toBe(scenario.distinct);

        const line = `${scenario.label}: load with the memo off ${truth.ms.toFixed(0)} ms, memo on but empty ${cold.ms.toFixed(0)} ms, memo filled ${load.ms.toFixed(0)} ms; the fill itself ${fill.ms.toFixed(0)} ms in ${fill.steps} steps (parse ${fill.begin.parseMs} ms); ${scenario.distinct} formatted, ${load.hits} hits and ${load.misses} misses at the filled load`;
        fillTimings.push(line);
        console.log(`[CITE-PREFILL] ${line}`);
      }
    );
  }
});

// ---------------------------------------------------------------------------------------------------
// begin / step behaviour
// ---------------------------------------------------------------------------------------------------

describe('prefillCitationsBegin / prefillCitationsStep', () => {
  it('say notReady before the editor exists, and queue nothing', () => {
    expect(prefillCitationsBegin('[@adams1999]')).toEqual({
      status: 'notReady',
      groups: 0,
      distinct: 0,
      pending: 0,
      unresolved: 0,
      parseMs: 0,
    });
    expect(prefillCitationsStep(25)).toEqual({ done: true, formatted: 0, remaining: 0, ms: 0 });
  });

  it('say parseFailed when the parser throws, and queue nothing', async () => {
    await mountEditor();
    freshEngine();
    prefillCitationsBegin('Some text [@adams1999].');
    vi.spyOn(editor!, 'action').mockImplementation(() => {
      throw new Error('parser exploded');
    });
    const result = prefillCitationsBegin('Some text [@adams1999].');
    expect(result.status).toBe('parseFailed');
    expect(result).toMatchObject({ groups: 0, distinct: 0, pending: 0, unresolved: 0 });
    // The failed begin replaced the earlier queue with nothing.
    expect(prefillCitationsStep(25)).toEqual({ done: true, formatted: 0, remaining: 0, ms: 0 });
  });

  it('a small budget makes progress and reports the rest; repeating finishes; calling again after done is harmless', async () => {
    const doc = buildDocument(1, false);
    await mountEditor();
    const engine = freshEngine();
    const begin = prefillCitationsBegin(doc.markdown);
    expect(begin.pending).toBe(66);

    // A zero budget still formats one request per call.
    const first = prefillCitationsStep(0);
    expect(first).toMatchObject({ done: false, formatted: 1, remaining: 65 });
    const second = prefillCitationsStep(-5);
    expect(second).toMatchObject({ done: false, formatted: 1, remaining: 64 });
    expect(engine.getMemoStats().size).toBe(2);

    let formatted = 2;
    let last = second;
    for (let i = 0; i < 100 && !last.done; i++) {
      last = prefillCitationsStep(5);
      formatted += last.formatted;
    }
    expect(last).toMatchObject({ done: true, remaining: 0 });
    expect(formatted).toBe(66);
    expect(engine.getMemoStats()).toMatchObject({ size: 66, misses: 66, hits: 0 });

    expect(prefillCitationsStep(25)).toEqual({ done: true, formatted: 0, remaining: 0, ms: 0 });
    expect(engine.getMemoStats().size).toBe(66);
  });

  it('a second begin replaces the queue; only the new document is formatted', async () => {
    await mountEditor();
    const engine = freshEngine();
    const first = prefillCitationsBegin('One [@adams1999] and two [@baker2003, p. 3] and three [@chen2011].');
    expect(first).toMatchObject({ status: 'ok', groups: 3, distinct: 3, pending: 3 });
    prefillCitationsStep(0); // formats the first request of the old queue
    const second = prefillCitationsBegin('Only [@dube2007] here, again [@dube2007].');
    expect(second).toMatchObject({ status: 'ok', groups: 2, distinct: 1, pending: 1 });

    const recorder = recordCalls(engine);
    expect(prefillCitationsStep(25)).toMatchObject({ done: true, formatted: 1, remaining: 0 });
    expect(recorder.calls().map(([keys]) => keys)).toEqual([['dube2007']]);
    recorder.stop();
  });

  it('groups already in the memo are not queued again, and never count as hits', async () => {
    const doc = buildDocument(1, false);
    await mountEditor();
    const engine = freshEngine();
    expect(runFill(doc.markdown).formatted).toBe(66);
    const again = prefillCitationsBegin(doc.markdown);
    expect(again).toMatchObject({ groups: 68, distinct: 66, pending: 0, unresolved: 1 });
    expect(prefillCitationsStep(25)).toEqual({ done: true, formatted: 0, remaining: 0, ms: 0 });
    expect(engine.getMemoStats().hits).toBe(0);
  });

  it('with the memo switched off queue nothing (a fill with nowhere to put the text would only burn time)', async () => {
    const doc = buildDocument(1, false);
    await mountEditor();
    const engine = freshEngine({ memo: false });
    const begin = prefillCitationsBegin(doc.markdown);
    expect(begin).toMatchObject({ status: 'ok', groups: 68, distinct: 66, pending: 0, unresolved: 1 });
    expect(prefillCitationsStep(25)).toEqual({ done: true, formatted: 0, remaining: 0, ms: 0 });
    expect(engine.getMemoStats()).toMatchObject({ size: 0, hits: 0, misses: 0, enabled: false });
  });

  it('a library without the document keys leaves every group unresolved and formats nothing', async () => {
    await mountEditor();
    const engine = freshEngine({ items: [] });
    const begin = prefillCitationsBegin('A [@adams1999] and B [@baker2003; @chen2011].');
    expect(begin).toMatchObject({ status: 'ok', groups: 2, distinct: 0, pending: 0, unresolved: 2 });
    expect(prefillCitationsStep(25)).toMatchObject({ done: true, formatted: 0 });
    expect(engine.getMemoStats().size).toBe(0);
  });

  it('a group with some keys missing is skipped (the node view would not format it either)', async () => {
    await mountEditor();
    const engine = freshEngine();
    const begin = prefillCitationsBegin('Mixed [@adams1999; @nosuchsource2024] and fine [@baker2003].');
    expect(begin).toMatchObject({ groups: 2, distinct: 1, pending: 1, unresolved: 1 });
    expect(runFill('Mixed [@adams1999; @nosuchsource2024] and fine [@baker2003].').formatted).toBe(1);
    expect(engine.getMemoStats().size).toBe(1);
  });
});

// ---------------------------------------------------------------------------------------------------
// A fill that is stopped, or interrupted by a style or library change, never changes what the load shows
// ---------------------------------------------------------------------------------------------------

describe('a partly completed fill', () => {
  it(
    'followed by a load gives the same text as no fill, and every entry it left equals the unmemoised answer',
    { timeout: 120_000 },
    async () => {
      const doc = buildDocument(1, false);
      const truth = await truthFor(doc.markdown);

      await mountEditor();
      const engine = freshEngine();
      prefillCitationsBegin(doc.markdown);
      for (let i = 0; i < 3; i++) prefillCitationsStep(0);
      const stopped = prefillCitationsStep(0);
      expect(stopped).toMatchObject({ done: false, remaining: 62 });
      expect(engine.getMemoStats().size).toBe(4);

      // Every remembered answer equals what a memo-less engine gives for the same request.
      const reference = new CiteprocEngine();
      reference.setBibliography(LIBRARY);
      reference.setMemoEnabled(false);
      let checked = 0;
      for (const [keys, options] of truth.calls) {
        if (engine.isMemoized(keys, options)) {
          expect(engine.formatCitation(keys, options)).toBe(reference.formatCitation(keys, options));
          checked++;
        }
      }
      expect(checked).toBeGreaterThanOrEqual(4);

      const hitsBefore = engine.getMemoStats().hits;
      const load = await realLoad(doc.markdown);
      expect(load.texts).toEqual(truth.texts);
      expect(load.markdown).toBe(truth.markdown);
      // The 62 requests the fill had not reached were formatted by the load, as today.
      expect(load.misses).toBe(62);
      expect(load.hits).toBeGreaterThan(0);
      expect(engine.getMemoStats().hits).toBeGreaterThan(hitsBefore);
    }
  );

  it(
    'survives a style change in the middle: the rest is formatted under the new style, and the load shows the new style',
    { timeout: 120_000 },
    async () => {
      const doc = buildDocument(1, false);
      const truth = await truthFor(doc.markdown, { style: NOTE_STYLE });

      await mountEditor();
      const engine = freshEngine();
      prefillCitationsBegin(doc.markdown);
      for (let i = 0; i < 3; i++) prefillCitationsStep(0);
      expect(engine.getMemoStats().size).toBe(3);
      engine.setStyle(NOTE_STYLE);
      expect(engine.getMemoStats().size).toBe(0);
      let last = prefillCitationsStep(25);
      for (let i = 0; i < 500 && !last.done; i++) last = prefillCitationsStep(25);
      expect(last.done).toBe(true);

      const load = await realLoad(doc.markdown);
      expect(load.texts).toEqual(truth.texts);
      expect(load.markdown).toBe(truth.markdown);
    }
  );

  it(
    'survives a library edit after a finished fill, and in the middle of one: nothing from before the edit is shown',
    { timeout: 120_000 },
    async () => {
      const doc = buildDocument(1, false);
      const edited = LIBRARY.map((item) =>
        item.id === 'adams1999' ? { ...item, issued: { 'date-parts': [[2001]] } } : item
      );
      const truth = await truthFor(doc.markdown, { items: edited });
      // The edit is visible in the ground truth, so a stale memo entry would show.
      expect(truth.texts.some((t) => t.includes('Adams 2001'))).toBe(true);

      // After a finished fill: everything remembered under the old library is dropped by the edit.
      await mountEditor();
      let engine = freshEngine();
      expect(prefillCitationsBegin(doc.markdown).pending).toBe(66);
      expect(prefillCitationsStep(10_000)).toMatchObject({ done: true, formatted: 66 });
      expect(engine.getMemoStats().size).toBe(66);
      engine.setBibliography(edited);
      expect(engine.getMemoStats().size).toBe(0);
      let load = await realLoad(doc.markdown);
      expect(load.texts).toEqual(truth.texts);
      expect(load.markdown).toBe(truth.markdown);
      await unmountEditor();

      // In the middle of a fill: the rest is formatted under the edited library.
      await mountEditor();
      engine = freshEngine();
      prefillCitationsBegin(doc.markdown);
      for (let i = 0; i < 5; i++) prefillCitationsStep(0);
      expect(engine.getMemoStats().size).toBe(5);
      engine.setBibliography(edited);
      expect(engine.getMemoStats().size).toBe(0);
      let last = prefillCitationsStep(25);
      for (let i = 0; i < 500 && !last.done; i++) last = prefillCitationsStep(25);
      expect(last.done).toBe(true);
      load = await realLoad(doc.markdown);
      expect(load.texts).toEqual(truth.texts);
      expect(load.markdown).toBe(truth.markdown);
    }
  );
});

// ---------------------------------------------------------------------------------------------------
// Larger documents
// ---------------------------------------------------------------------------------------------------

describe('twelve chapters', () => {
  it(
    '816 groups: the fill asks for what a real load asks for, zero misses at the load, same text',
    { timeout: 600_000 },
    async () => {
      const doc = buildDocument(12, true);
      expect(doc.groups).toBe(816);

      const truth = await truthFor(doc.markdown);
      expect(truth.citationNodes).toBe(816);
      expect(truth.keys).toHaveLength(815);

      const view = await mountEditor();
      const engine = freshEngine();
      const stateBefore = view.state;
      const fill = runFill(doc.markdown);
      expect(view.state).toBe(stateBefore);
      expect(fill.begin).toMatchObject({ status: 'ok', groups: 816, unresolved: 1 });
      expect(new Set(fill.keys)).toEqual(new Set(truth.keys));
      expect(fill.begin.distinct).toBe(484); // the fixture's own count: 816 groups, 484 distinct
      expect(fill.begin.distinct).toBe(new Set(truth.keys).size);
      expect(engine.getMemoStats().size).toBe(fill.begin.distinct);

      const load = await realLoad(doc.markdown);
      expect(load.misses).toBe(0);
      expect(load.hits).toBeGreaterThanOrEqual(815);
      expect(load.texts).toEqual(truth.texts);
      expect(load.markdown).toBe(truth.markdown);

      const line = `twelve chapters, 816 groups, ${fill.begin.distinct} distinct: load with the memo off ${truth.ms.toFixed(0)} ms, memo filled ${load.ms.toFixed(0)} ms; the fill itself ${fill.ms.toFixed(0)} ms in ${fill.steps} steps (parse ${fill.begin.parseMs} ms)`;
      console.log(`[CITE-PREFILL] ${line}`);
    }
  );
});
