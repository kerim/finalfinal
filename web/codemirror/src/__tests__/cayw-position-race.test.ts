// @vitest-environment jsdom
// Regression tests for CAYW (Cite-As-You-Write) position tracking in the CodeMirror /
// Source-mode editor — the parallel implementation of
// web/milkdown/src/__tests__/cayw.test.ts (Milkdown/WYSIWYG side).
//
// The bug this hardens against: /cite command position tracking used to live in a single
// module-level singleton (`pendingCAYWRange` in editor-state.ts). The Zotero round-trip is
// a real async HTTP call that can take arbitrary time and is NOT blocked by the app's own
// UI, so (a) a second /cite before the first resolves would clobber the first's stored
// range, and (b) continued editing during the round-trip would make stale raw offsets
// point at the wrong content. The fix replaces the singleton with a Map keyed by an
// opaque, monotonically-increasing requestId (editor-state.ts's pendingCAYWRequests),
// plus a CodeMirror ViewPlugin (caywRemapPlugin) that remaps every pending entry across
// doc-changing transactions via ChangeDesc.mapPos() — the CM6 analogue of ProseMirror's
// tr.mapping.map() used by Milkdown's caywRemapPlugin, and the same mapPos() idiom already
// used for spellcheck results in spellcheck-plugin.ts.
//
// Uses a real CodeMirror EditorView with caywRemapPlugin registered as an extension (not a
// bare EditorState) — the plugin under test needs live dispatch-time hooks to run, same as
// production wiring in main.ts.

import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { afterEach, describe, expect, it } from 'vitest';
import { citationPickerCallback, citationPickerCancelled, citationPickerError } from '../api';
import { caywRemapPlugin } from '../cayw-remap-plugin';
import {
  allocateCAYWRequestId,
  clearPendingCAYWRequests,
  getPendingAppendMode,
  getPendingAppendRange,
  getPendingCAYWRequests,
  setEditorView,
  setPendingAppendMode,
  setPendingAppendRange,
} from '../editor-state';

describe('CAYW position tracking (CodeMirror)', () => {
  let view: EditorView | null = null;

  afterEach(() => {
    clearPendingCAYWRequests();
    setPendingAppendMode(false);
    setPendingAppendRange(null);
    delete (window as any).webkit;
    setEditorView(null);
    if (view) {
      view.destroy();
      view = null;
    }
  });

  function makeEditor(doc: string): EditorView {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const v = new EditorView({
      state: EditorState.create({
        doc,
        extensions: [markdown({ base: markdownLanguage }), caywRemapPlugin],
      }),
      parent: div,
    });
    view = v;
    setEditorView(v);
    return v;
  }

  /** Installs a fake Swift bridge for openCitationPicker and returns the array
   * that captures every requestId posted through it, in call order. */
  function installOpenPickerMock(): number[] {
    const captured: number[] = [];
    (window as any).webkit = {
      messageHandlers: {
        openCitationPicker: {
          postMessage: (id: number) => {
            captured.push(id);
          },
        },
      },
    };
    return captured;
  }

  /**
   * Mirrors the /cite slash command's apply() in slash-completions.ts. There is no
   * standalone exported production function to call directly here (unlike Milkdown's
   * openCAYWPicker) — the real logic is inline in the slash command handler — so this
   * helper performs the exact same steps using the real, exported editor-state.ts
   * primitives (allocateCAYWRequestId, getPendingCAYWRequests) and posts through the
   * (mocked) Swift bridge exactly as production code does.
   */
  function openCAYWPicker(from: number, to: number): void {
    const requestId = allocateCAYWRequestId();
    getPendingCAYWRequests().set(requestId, { start: from, end: to });
    if ((window as any).webkit?.messageHandlers?.openCitationPicker) {
      (window as any).webkit.messageHandlers.openCitationPicker.postMessage(requestId);
    } else {
      getPendingCAYWRequests().delete(requestId);
    }
  }

  function makeCallbackData(overrides: Record<string, unknown>): Record<string, unknown> {
    return {
      rawSyntax: '[@testkey]',
      citekeys: ['testkey'],
      locators: '[]',
      prefix: '',
      suppressAuthor: false,
      requestId: -999,
      ...overrides,
    };
  }

  // ---- 1: monotonic id generation ----

  it('allocateCAYWRequestId produces strictly increasing requestIds across multiple /cite requests', () => {
    makeEditor('Hello world.');
    const captured = installOpenPickerMock();

    openCAYWPicker(0, 0);
    openCAYWPicker(1, 1);
    openCAYWPicker(2, 2);

    expect(captured).toHaveLength(3);
    expect(captured[1]).toBeGreaterThan(captured[0]);
    expect(captured[2]).toBeGreaterThan(captured[1]);
  });

  // ---- 2: clearPendingCAYWRequests clears the map but NOT the counter ----

  it('clearPendingCAYWRequests() clears pending requests but the id counter keeps increasing across the reset', () => {
    makeEditor('Hello world.');
    const captured = installOpenPickerMock();

    openCAYWPicker(0, 0);
    const idBeforeReset = captured[0];

    clearPendingCAYWRequests();
    // The pre-reset request must be gone.
    expect(getPendingCAYWRequests().size).toBe(0);

    openCAYWPicker(0, 0);
    const idAfterReset = captured[1];

    // The counter survived the reset: the new id is strictly greater, never reused.
    expect(idAfterReset).toBeGreaterThan(idBeforeReset);
    // Only the post-reset request is pending.
    expect(getPendingCAYWRequests().size).toBe(1);
    expect(getPendingCAYWRequests().has(idAfterReset)).toBe(true);
  });

  // ---- 3: no-op for an unrecognized requestId ----

  it('citationPickerCallback/citationPickerCancelled/citationPickerError silently no-op for a requestId not in the pending map', () => {
    const v = makeEditor('See details.');
    const before = v.state.doc.toString();
    const STALE_REQUEST_ID = 999999;

    expect(() => {
      citationPickerCallback(makeCallbackData({ requestId: STALE_REQUEST_ID }), []);
    }).not.toThrow();
    expect(v.state.doc.toString()).toBe(before);

    expect(() => {
      citationPickerCancelled(STALE_REQUEST_ID);
    }).not.toThrow();
    expect(v.state.doc.toString()).toBe(before);

    expect(() => {
      citationPickerError('some error', STALE_REQUEST_ID);
    }).not.toThrow();
    expect(v.state.doc.toString()).toBe(before);
  });

  // ---- 4: remap plugin shifts a pending range across an intervening edit ----

  it('caywRemapPlugin shifts the pending range when an unrelated edit lands before it, so the citation is inserted at the correct (shifted) position', () => {
    const v = makeEditor('Hello /cite world.');
    const captured = installOpenPickerMock();

    const cmdStart = v.state.doc.toString().indexOf('/cite');
    expect(cmdStart).toBeGreaterThan(-1);
    const cmdEnd = cmdStart + '/cite'.length;

    openCAYWPicker(cmdStart, cmdEnd);
    const requestId = captured[0];

    // Intervening unrelated edit: insert text BEFORE the pending range's start,
    // simulating the user continuing to type while the async Zotero round-trip is
    // still in flight. caywRemapPlugin is registered as a real extension on this view,
    // so it picks this up automatically via dispatch — no manual remap call needed.
    v.dispatch({ changes: { from: 0, to: 0, insert: 'XX ' } });
    const inserted = 'XX '.length;

    // Resolve the (now-stale-if-unmapped) request.
    citationPickerCallback(makeCallbackData({ requestId }), []);

    const text = v.state.doc.toString();
    expect(text).not.toContain('/cite');
    expect(text).toContain('[@testkey]');
    // The citation must land at the shifted position, not the stale original offset.
    expect(text.indexOf('[@testkey]')).toBe(cmdStart + inserted);
    expect(text.indexOf('XX Hello')).toBeLessThan(text.indexOf('world.'));
  });

  // ---- 5: two overlapping requests, resolved out of order ----

  it('two overlapping /cite requests, resolved out of order, each land in their own correct position with no cross-contamination', () => {
    const v = makeEditor('First /cite line.\nSecond /cite line.');
    const captured = installOpenPickerMock();

    const text0 = v.state.doc.toString();
    const posA = text0.indexOf('/cite');
    const posB = text0.indexOf('/cite', posA + 1);
    expect(posA).toBeGreaterThan(-1);
    expect(posB).toBeGreaterThan(posA);

    // Open request A (first line) ...
    openCAYWPicker(posA, posA + '/cite'.length);
    const requestA = captured[0];

    // ... then open request B (second line) BEFORE resolving A.
    openCAYWPicker(posB, posB + '/cite'.length);
    const requestB = captured[1];

    expect(getPendingCAYWRequests().size).toBe(2);

    // Resolve B first, then A — out of order relative to when they were opened.
    citationPickerCallback(makeCallbackData({ requestId: requestB, rawSyntax: '[@bravo]', citekeys: ['bravo'] }), []);
    citationPickerCallback(makeCallbackData({ requestId: requestA, rawSyntax: '[@alpha]', citekeys: ['alpha'] }), []);

    expect(getPendingCAYWRequests().size).toBe(0);

    const finalText = v.state.doc.toString();
    // Exactly the right citation landed on the right line — no duplication, no
    // cross-contamination between the two requests.
    expect(finalText).not.toContain('/cite');
    expect(finalText).toContain('First [@alpha] line.');
    expect(finalText).toContain('Second [@bravo] line.');
  });

  // ---- 6: an unrelated normal-mode cancel/error must not drop a pending append-mode citation ----
  //
  // Append-mode requests (the "+" button next to an existing citation — see
  // handleAddCitationClick in citations.ts) always use the reserved sentinel requestId -1
  // and are never stored in pendingCAYWRequests, which is exclusively for normal-mode /cite
  // requests. citationPickerCancelled/citationPickerError used to unconditionally clear
  // append-mode state regardless of which requestId they were actually resolving. That meant
  // an unrelated normal-mode /cite request being cancelled or erroring while an append-mode
  // picker was still pending would wipe out the append-mode state out from under it, so the
  // append-mode picker's eventual (successful) resolution fell through to normal-mode
  // handling, looked up -1 in pendingCAYWRequests (never present), and silently dropped the
  // user's citation.

  it('cancelling an unrelated normal-mode /cite request does not drop a still-pending append-mode citation', () => {
    const v = makeEditor('See [@existing] here. /cite there.');
    const captured = installOpenPickerMock();

    // Simulate handleAddCitationClick's append-mode setup: user clicked "+" next to the
    // existing citation, storing its range and entering append mode (sentinel -1).
    const existingStart = v.state.doc.toString().indexOf('[@existing]');
    const existingEnd = existingStart + '[@existing]'.length;
    setPendingAppendMode(true);
    setPendingAppendRange({ start: existingStart, end: existingEnd });

    // Meanwhile, an UNRELATED normal-mode /cite request is also outstanding.
    const cmdStart = v.state.doc.toString().indexOf('/cite');
    const cmdEnd = cmdStart + '/cite'.length;
    openCAYWPicker(cmdStart, cmdEnd);
    const normalRequestId = captured[0];
    expect(getPendingCAYWRequests().has(normalRequestId)).toBe(true);

    // The unrelated normal-mode request gets cancelled (e.g. user pressed Escape) while the
    // append-mode picker is still pending.
    citationPickerCancelled(normalRequestId);

    // Append-mode state is keyed off the -1 sentinel, not the normal request's id — an
    // unrelated cancellation must never touch it.
    expect(getPendingAppendMode()).toBe(true);
    expect(getPendingAppendRange()).toEqual({ start: existingStart, end: existingEnd });

    // Now the append-mode picker resolves with the user's actual citation pick.
    citationPickerCallback(makeCallbackData({ requestId: -1, rawSyntax: '[@newkey]', citekeys: ['newkey'] }), []);

    // The append-mode citation must actually be inserted (merged with the existing one),
    // not silently dropped.
    const finalText = v.state.doc.toString();
    expect(finalText).toContain('[@existing; @newkey]');
    expect(getPendingAppendMode()).toBe(false);
    expect(getPendingAppendRange()).toBeNull();
  });

  it('an unrelated normal-mode /cite request erroring does not drop a still-pending append-mode citation', () => {
    const v = makeEditor('See [@existing] here. /cite there.');
    const captured = installOpenPickerMock();

    const existingStart = v.state.doc.toString().indexOf('[@existing]');
    const existingEnd = existingStart + '[@existing]'.length;
    setPendingAppendMode(true);
    setPendingAppendRange({ start: existingStart, end: existingEnd });

    const cmdStart = v.state.doc.toString().indexOf('/cite');
    const cmdEnd = cmdStart + '/cite'.length;
    openCAYWPicker(cmdStart, cmdEnd);
    const normalRequestId = captured[0];

    // The unrelated normal-mode request errors (e.g. a Zotero connection hiccup on that
    // specific request) while the append-mode picker is still pending.
    citationPickerError('Zotero connection hiccup', normalRequestId);

    expect(getPendingAppendMode()).toBe(true);
    expect(getPendingAppendRange()).toEqual({ start: existingStart, end: existingEnd });

    citationPickerCallback(makeCallbackData({ requestId: -1, rawSyntax: '[@newkey]', citekeys: ['newkey'] }), []);

    const finalText = v.state.doc.toString();
    expect(finalText).toContain('[@existing; @newkey]');
    expect(getPendingAppendMode()).toBe(false);
    expect(getPendingAppendRange()).toBeNull();
  });
});
