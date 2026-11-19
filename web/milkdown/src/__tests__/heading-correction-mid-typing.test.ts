// @vitest-environment jsdom
import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { history } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { splitBlock } from '@milkdown/kit/prose/commands';
import { redo, undo } from '@milkdown/kit/prose/history';
import { TextSelection } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { ackReportsApi, updateHeadingLevels } from '../api-content';
import { blockIdPlugin, getAllBlockIds } from '../block-id-plugin';
import {
  type BlockChanges,
  blockSyncPlugin,
  getBlockChanges,
  resetAndSnapshot,
  resetBlockSyncState,
  setSyncPaused,
} from '../block-sync-plugin';
import { setEditorInstance } from '../editor-state';
import { highlightPlugin } from '../highlight-plugin';
import { noteTransactionForEditSpanTracking, resetRecentUserEditSpanForTests } from '../recent-edit-span';
import { __resetReportOutboxForTest, foldBatches, reportSession } from '../report-outbox';

// Rich Text (Milkdown) side of the "heading-level correction lands in the middle of typing" check.
//
// The situation: the user starts a new heading by typing `### ` at the start of a new line and keeps
// typing the title. While they type, the app's automatic heading-level correction
// (`updateHeadingLevels`, called from Swift's hierarchy enforcement) decides that a level-3 heading
// directly under a level-1 heading is one level too deep and demotes it to level 2. The correction can
// arrive between any two keystrokes. What the user must see, whenever it arrives:
//   * every character they typed is still there, in order, and none of them ended up inside the
//     correction (no lost, doubled or merged keystroke);
//   * Cmd-Z first takes back what they typed after the correction, then the correction on its own,
//     then their earlier typing; Cmd-Shift-Z walks the same path forward again.
//
// Harness: the real Milkdown editor with the plugins that matter here (commonmark, gfm, highlight,
// block ids, block sync, history). The bare harness never runs main.ts's `initEditor()`, so the
// production `view.dispatch` override that feeds every transaction to
// `noteTransactionForEditSpanTracking` is mirrored by `installDispatchTracking` below (the heading
// input rule dispatches its own transaction, so calling it by hand after each keystroke would miss it).
// The fake clock does not move while keystrokes are typed (it moves only when a test runs timers, by a few
// tens of milliseconds), so history grouping is decided by adjacency alone: the tests therefore do not
// assert how many keystrokes one undo takes back, only the order of the states.
// Cmd-Z and Cmd-Shift-Z are driven through the history library's own `undo` and `redo` commands, not
// through the app's undo coordinator (undo-coordinator.ts).

const START_DOC = '# Top\n\nIntro.';
const TITLE = 'Title more';
const TITLE_BEFORE_FIX = 'Ti';
/** The points in the title where the correction can land: after 0, 1, ... 10 typed characters. */
const POINTS = Array.from({ length: TITLE.length + 1 }, (_, k) => k);

const liveEditors: Array<{ editor: Editor; div: HTMLElement }> = [];

async function makeEditor(markdown: string): Promise<Editor> {
  const div = document.createElement('div');
  document.body.appendChild(div);
  const editor = await Editor.make()
    .config((ctx) => {
      ctx.set(rootCtx, div);
      ctx.set(defaultValueCtx, markdown);
    })
    .use(commonmark)
    .use(gfm)
    .use(highlightPlugin)
    .use(blockIdPlugin)
    .use(blockSyncPlugin)
    .use(history)
    .create();
  liveEditors.push({ editor, div });
  return editor;
}

/** One typed character, the way the real view does it: the input rules see it first (the heading rule lives
 * there and dispatches its own transaction), and only when none handled it does the character get inserted
 * (copied from guard-removed-extend-repro.test.ts). */
function typeText(view: EditorView, text: string): void {
  const pos = view.state.selection.from;
  const handled = view.someProp('handleTextInput', (f: any) => f(view, pos, pos, text)) ?? false;
  if (!handled) {
    view.dispatch(view.state.tr.insertText(text, pos));
  }
}

/** Mirrors the production dispatch override in main.ts: every dispatched transaction, including the ones the
 * input rules and the undo commands dispatch themselves, is also passed to the edit-span tracker. */
function installDispatchTracking(view: EditorView): void {
  const originalDispatch = view.dispatch.bind(view);
  view.dispatch = (tr) => {
    originalDispatch(tr);
    noteTransactionForEditSpanTracking(tr);
  };
}

/** `H3:"Ti"` for a heading, `P:"Intro."` for a paragraph, joined by ` | `. */
function summarize(view: EditorView): string {
  const parts: string[] = [];
  view.state.doc.forEach((node) => {
    parts.push(node.type.name === 'heading' ? `H${node.attrs.level}:"${node.textContent}"` : `P:"${node.textContent}"`);
  });
  return parts.join(' | ');
}

function headingsOf(view: EditorView): Array<{ level: number; text: string }> {
  const out: Array<{ level: number; text: string }> = [];
  view.state.doc.forEach((node) => {
    if (node.type.name === 'heading') out.push({ level: node.attrs.level, text: node.textContent });
  });
  return out;
}

/** The whole document as the user sees it with the title at heading `level` holding `text`. */
const docSummary = (level: number, text: string): string => `H1:"Top" | P:"Intro." | H${level}:"${text}"`;

interface Session {
  editor: Editor;
  view: EditorView;
  /** Every distinct document the user (or an undo/redo) has seen so far, keyed by the document's JSON. */
  seen: Map<string, string>;
  /** Block id of the "Intro." paragraph. */
  introId: string;
  /** Block id of the heading being typed (set by `startNewHeading`). */
  headingId?: string;
  record(): void;
  type(text: string): void;
  pressEnter(): void;
  /** The id of the heading at the end of the document, as the block-id plugin currently reports it. */
  lastHeadingId(): string | undefined;
  /** The heading-level correction: demote the typed heading to level 2, as Swift's hierarchy enforcement does. */
  applyLevelFix(): void;
  docJson(): string;
}

async function startSession(): Promise<Session> {
  const editor = await makeEditor(START_DOC);
  setEditorInstance(editor);
  vi.useFakeTimers();
  const view = editor.ctx.get(editorViewCtx);
  installDispatchTracking(view);
  // The loaded document is block sync's baseline, as after the content load Swift makes.
  resetAndSnapshot(view.state.doc);

  const seen = new Map<string, string>();
  const docJson = () => JSON.stringify(view.state.doc.toJSON());
  const record = () => {
    seen.set(docJson(), summarize(view));
  };

  let introId: string | undefined;
  const ids = getAllBlockIds();
  view.state.doc.forEach((node, pos) => {
    if (node.textContent === 'Intro.') introId = ids.get(pos);
  });
  expect(introId, 'the Intro. paragraph has a block id').toBeDefined();

  // Caret at the end of "Intro."
  view.dispatch(view.state.tr.setSelection(TextSelection.atEnd(view.state.doc)));
  expect(summarize(view)).toBe('H1:"Top" | P:"Intro."');
  record();

  return {
    editor,
    view,
    seen,
    introId: introId as string,
    record,
    docJson,
    type(text: string) {
      typeText(view, text);
      record();
    },
    pressEnter() {
      // A user transaction: splitBlock is what the Enter key runs.
      const done = splitBlock(view.state, (tr) => view.dispatch(tr));
      expect(done).toBe(true);
      record();
    },
    lastHeadingId() {
      let id: string | undefined;
      const idsNow = getAllBlockIds();
      view.state.doc.forEach((node, pos) => {
        if (node.type.name === 'heading') id = idsNow.get(pos);
      });
      return id;
    },
    applyLevelFix() {
      const id = this.lastHeadingId();
      expect(id).toBeDefined();
      updateHeadingLevels([{ blockId: id as string, newLevel: 2 }]);
      record();
    },
  };
}

/** Enter, then `### ` at the start of the new line: the heading input rule must turn it into an empty level-3 heading. */
function startNewHeading(s: Session): void {
  s.pressEnter();
  expect(summarize(s.view)).toBe('H1:"Top" | P:"Intro." | P:""');
  for (const ch of '### ') s.type(ch);
  // A broken input rule (the "###" staying text) must fail loudly here, not later.
  expect(summarize(s.view)).toBe(docSummary(3, ''));
  s.headingId = s.lastHeadingId();
  expect(s.headingId).toBeDefined();
}

/** What block sync holds for Swift after the correction and the rest of the typing: the heading is a block Swift has
 * never been told about (nothing was drained since it was made), so it is ONE insert with the final level and the whole
 * title, placed after "Intro."; nothing else: no update, no delete, no other insert. Block sync pauses itself from the
 * correction until an animation frame and the rest of the title is typed inside that window, so this is also what shows
 * that none of it was left out of what Swift is told. */
function expectBlockSyncHoldsOnlyTheTitle(s: Session): void {
  const changes = getBlockChanges();
  expect(s.lastHeadingId(), 'the heading keeps its block id through the correction').toBe(s.headingId);
  expect(changes).toEqual({
    updates: [],
    deletes: [],
    inserts: [
      {
        tempId: s.headingId,
        blockType: 'heading',
        textContent: TITLE,
        markdownFragment: `## ${TITLE}`,
        headingLevel: 2,
        afterBlockId: s.introId,
      },
    ],
  } satisfies BlockChanges);
}

/** From the typed document (title at level 2): undo takes back what came after the correction (nothing, when the
 * correction landed after the last character), and then the correction by itself; redo goes forward through the same
 * states in reverse, back to the typed document. `k` is how many characters had been typed when the correction landed. */
function walkUndoRedoAroundCorrection(s: Session, k: number): void {
  const { view } = s;
  const prefix = TITLE.slice(0, k);
  const typedSummary = docSummary(2, TITLE);
  const typedJson = s.docJson();
  const undoStates = k < TITLE.length ? [docSummary(2, prefix), docSummary(3, prefix)] : [docSummary(3, prefix)];
  const undoJsons: string[] = [];

  undoStates.forEach((expected, i) => {
    expect(undo(view.state, view.dispatch), `undo ${i + 1}, k=${k}`).toBe(true);
    expect(summarize(view), `undo ${i + 1}, k=${k}`).toBe(expected);
    undoJsons.push(s.docJson());
  });

  const redoStates = [...undoStates.slice(0, -1).reverse(), typedSummary];
  const redoJsons = [...undoJsons.slice(0, -1).reverse(), typedJson];
  redoStates.forEach((expected, i) => {
    expect(redo(view.state, view.dispatch), `redo ${i + 1}, k=${k}`).toBe(true);
    expect(summarize(view), `redo ${i + 1}, k=${k}`).toBe(expected);
    expect(s.docJson(), `redo ${i + 1}, k=${k}`).toBe(redoJsons[i]);
  });
  expect(redo(view.state, view.dispatch), `nothing left to redo, k=${k}`).toBe(false);
}

/** Puts the module-level state the editor and block sync leave behind back to rest: used after every test. When a
 * test stops early (a failed assertion), the animation frame it still had pending is dropped with the fake timers, and
 * block sync's pause (`setSyncPaused`) stays on: seen with a break patch applied, the next test's frames then never ran
 * and it failed on block sync instead of on its own text check. Running what is pending first, and lifting the pause,
 * keeps one failure from reading as a second, unrelated one. */
async function resetModuleState(): Promise<void> {
  if (vi.isFakeTimers()) vi.runOnlyPendingTimers();
  vi.useRealTimers();
  setEditorInstance(null);
  for (const { editor, div } of liveEditors.splice(0)) {
    await editor.destroy();
    div.remove();
  }
  resetBlockSyncState();
  setSyncPaused(false);
  resetRecentUserEditSpanForTests();
  __resetReportOutboxForTest({ enabled: false });
}

describe('heading-level correction in the middle of typing a new heading (Rich Text)', () => {
  afterEach(resetModuleState);

  it('no keystroke lost when the level fix lands after "### Ti"', async () => {
    const s = await startSession();
    startNewHeading(s);
    for (const ch of TITLE_BEFORE_FIX) s.type(ch);
    expect(summarize(s.view)).toBe(docSummary(3, 'Ti'));

    s.applyLevelFix();
    expect(summarize(s.view)).toBe(docSummary(2, 'Ti'));

    for (const ch of 'tle more') s.type(ch);

    // Every character present and in order, in the one heading the user was typing; nothing else touched.
    expect(headingsOf(s.view)).toEqual([
      { level: 1, text: 'Top' },
      { level: 2, text: TITLE },
    ]);
    expect(summarize(s.view)).toBe(docSummary(2, TITLE));

    // What block sync tells Swift: level 2, the whole title.
    await vi.runOnlyPendingTimersAsync();
    expectBlockSyncHoldsOnlyTheTitle(s);
  });

  it('Cmd-Z walks back in order, Cmd-Shift-Z walks forward', async () => {
    const s = await startSession();
    const { view } = s;
    const originalJson = s.docJson();
    startNewHeading(s);
    for (const ch of TITLE_BEFORE_FIX) s.type(ch);
    s.applyLevelFix();
    for (const ch of 'tle more') s.type(ch);
    await vi.runOnlyPendingTimersAsync(); // a person presses Cmd-Z later than one animation frame
    const typedJson = s.docJson();
    expect(summarize(view)).toBe(docSummary(2, TITLE));

    // Undo 1: only what was typed after the correction goes; the correction stays and was not merged into it.
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(summarize(view)).toBe(docSummary(2, 'Ti'));
    const undoPath: string[] = [s.docJson()];

    // Undo 2: the correction is its own step.
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(summarize(view)).toBe(docSummary(3, 'Ti'));
    undoPath.push(s.docJson());

    // Keep undoing: every state on the way back is one the user has seen (never a mixed one), ending at the
    // document they started from.
    for (let i = 0; i < 100 && undo(view.state, view.dispatch); i++) {
      const json = s.docJson();
      expect(s.seen.has(json), `undo reached a state nobody typed: ${summarize(view)}`).toBe(true);
      undoPath.push(json);
    }
    expect(s.docJson()).toBe(originalJson);
    expect(summarize(view)).toBe('H1:"Top" | P:"Intro."');
    expect(undo(view.state, view.dispatch)).toBe(false);

    // Redo walks the same path forward: each state is one seen before, in the reverse order of the undo path,
    // ending at the document as typed.
    const redoPath: string[] = [];
    for (let i = 0; i < 100 && redo(view.state, view.dispatch); i++) {
      const json = s.docJson();
      expect(s.seen.has(json), `redo reached a state nobody typed: ${summarize(view)}`).toBe(true);
      redoPath.push(json);
    }
    expect(redoPath).toEqual([...undoPath.slice(0, -1)].reverse().concat([typedJson]));
    expect(s.docJson()).toBe(typedJson);
    expect(summarize(view)).toBe(docSummary(2, TITLE));
    expect(redo(view.state, view.dispatch)).toBe(false);

    await vi.runOnlyPendingTimersAsync();
  });

  it.each(POINTS)('fix landing at every point in the title loses nothing (after %i typed characters)', async (k) => {
    const s = await startSession();
    const { view } = s;
    const prefix = TITLE.slice(0, k);
    startNewHeading(s);
    for (const ch of prefix) s.type(ch);
    expect(summarize(view), `before the fix, k=${k}`).toBe(docSummary(3, prefix));

    s.applyLevelFix();
    expect(summarize(view), `after the fix, k=${k}`).toBe(docSummary(2, prefix));

    for (const ch of TITLE.slice(k)) s.type(ch);
    expect(summarize(view), `after all typing, k=${k}`).toBe(docSummary(2, TITLE));

    // What block sync tells Swift: level 2, the whole title, as the one new block.
    await vi.runOnlyPendingTimersAsync();
    expectBlockSyncHoldsOnlyTheTitle(s);

    // Undo and redo, from the user's seat.
    walkUndoRedoAroundCorrection(s, k);
  });

  it('report path: a heading Swift has already confirmed gets its level fix and the rest of the title as one update', async () => {
    // The first report (the new heading, "### Ti") goes out and Swift acknowledges it, confirming the heading's
    // temporary id. The correction then names the confirmed id, and the rest of the title is typed. What leaves
    // for Swift after the acknowledgement must be one update of that row: level 2, the whole title.
    const posted: Array<{ es: number; changes: BlockChanges }> = [];
    __resetReportOutboxForTest({
      enabled: true,
      intervalMs: 250,
      repost: false,
      poster: (body) => {
        if (body.repost !== true) {
          posted.push({ es: body.es as number, changes: JSON.parse(body.json as string) as BlockChanges });
        }
        return true;
      },
    });
    const s = await startSession();
    startNewHeading(s);
    for (const ch of TITLE_BEFORE_FIX) s.type(ch);
    const tempId = s.headingId as string;
    expect(tempId.startsWith('temp-'), 'premise: Enter made a temp-id block').toBe(true);

    await vi.advanceTimersByTimeAsync(300); // the typing's detection (100 ms) and the report's turn (250 ms)
    expect(posted).toHaveLength(1);
    expect(posted[0].changes).toEqual({
      updates: [],
      deletes: [],
      inserts: [
        {
          tempId,
          blockType: 'heading',
          textContent: 'Ti',
          markdownFragment: '### Ti',
          headingLevel: 3,
          afterBlockId: s.introId,
        },
      ],
    });

    // Swift applied report 1 and made the row: the temp id is now confirmed.
    const confirmedId = 'confirmed-heading-id';
    ackReportsApi({ session: reportSession(), through: posted[0].es, idMapping: { [tempId]: confirmedId } });
    expect(s.lastHeadingId(), 'premise: the editor now knows the heading by the confirmed id').toBe(confirmedId);

    s.applyLevelFix(); // names the confirmed id
    expect(summarize(s.view)).toBe(docSummary(2, 'Ti'));
    for (const ch of 'tle more') s.type(ch);
    expect(summarize(s.view)).toBe(docSummary(2, TITLE));

    await vi.advanceTimersByTimeAsync(1000); // the animation frame that ends block sync's pause, then the report's turn

    const afterAck = posted.slice(1).map((p) => p.changes);
    expect(afterAck.length, 'something was reported after the acknowledgement').toBeGreaterThan(0);
    expect(foldBatches(afterAck)).toEqual({
      updates: [
        {
          id: confirmedId,
          blockType: 'heading',
          textContent: TITLE,
          markdownFragment: `## ${TITLE}`,
          headingLevel: 2,
        },
      ],
      inserts: [],
      deletes: [],
    });
  });
});
