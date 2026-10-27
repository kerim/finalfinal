// @vitest-environment jsdom
//
// The bridge registration of the redo put-back (t-14f908b4): main.ts must hand Swift a `clearStructuralUndoRegistry` that ALSO
// forgets the set-aside redo records (a barrier replaces the timeline they belong to; a record left behind would be taken by a later
// quick redo of the same operation id).
// Like main-mount-paint-signal.test.ts, this imports the REAL main.ts (its top-level initEditor() builds a real editor) and reads
// what it put on `window.FinalFinal`.

import { afterEach, describe, expect, it, vi } from 'vitest';

describe('main.ts registers the redo put-back on window.FinalFinal', () => {
  afterEach(() => {
    delete (window as any).webkit;
    document.body.innerHTML = '';
    vi.resetModules();
  });

  it('registers the barrier clear that also forgets the redo records', async () => {
    const root = document.createElement('div');
    root.id = 'editor';
    document.body.appendChild(root);
    (window as any).webkit = { messageHandlers: { paintComplete: { postMessage: vi.fn() } } };

    await import('../main');
    const undoApi = await import('../api-section-undo');

    const bridge = (window as any).FinalFinal;
    expect(bridge.clearStructuralUndoRegistry, 'the barrier clear also forgets the redo records').toBe(
      undoApi.clearStructuralUndoRegistryAndRedoRecords
    );
  });
});
