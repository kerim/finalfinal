// @vitest-environment jsdom
// Tests for hover-tooltip.ts's delegated show/hide logic — the shared
// singleton tooltip that replaced the old .ff-annotation-collapsed::after
// pseudo-element and .ff-footnote-tooltip in-DOM child (both of which
// silently ignored max-width in real WebKit; see hover-tooltip.ts's top
// comment). Exercises installHoverTooltipListeners() directly against plain
// DOM fixtures rather than a full Milkdown Editor, since the delegation logic
// itself doesn't depend on ProseMirror — main.ts wires the exact same
// function to the real editor root via hoverTooltipPlugin's view().
//
// IMPORTANT: jsdom has no real layout engine. These tests can verify that the
// singleton is created/shown/hidden at the right moments, that positionPopup()
// is invoked with the anchor, and that only one tooltip element ever exists —
// but NOT that the tooltip actually renders at the right pixel position or
// respects max-width/viewport clamping visually. That requires real-WebKit
// measurement (this project's e2e-verify pipeline stage), not this file.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it, vi } from 'vitest';
import * as positionPopupModule from '../../../shared/position-popup';
import { annotationDisplayPlugin, setAnnotationDisplayModes } from '../annotation-display-plugin';
import { annotationPlugin } from '../annotation-plugin';
import { setFootnoteDefinitions } from '../footnote-plugin';
import {
  getHoverTooltipElement,
  hideHoverTooltip,
  hoverTooltipPlugin,
  installHoverTooltipListeners,
  isHoverTooltipVisible,
} from '../hover-tooltip';
import { setSourceModeEnabled } from '../source-mode-plugin';

describe('hover-tooltip', () => {
  let root: HTMLElement | null = null;
  let cleanup: (() => void) | null = null;

  afterEach(() => {
    cleanup?.();
    cleanup = null;
    hideHoverTooltip();
    root?.remove();
    root = null;
    setAnnotationDisplayModes({ task: 'inline', comment: 'inline', reference: 'inline' });
    setFootnoteDefinitions({});
    setSourceModeEnabled(false);
    vi.restoreAllMocks();
  });

  function setUpRoot(...children: HTMLElement[]): HTMLElement {
    root = document.createElement('div');
    for (const child of children) root.appendChild(child);
    document.body.appendChild(root);
    cleanup = installHoverTooltipListeners(root);
    return root;
  }

  function makeAnnotationAnchor(
    type: string,
    text: string
  ): { anchor: HTMLElement; marker: HTMLElement; textSpan: HTMLElement } {
    const anchor = document.createElement('span');
    anchor.className = `ff-annotation ff-annotation-${type} ff-annotation-collapsed`;
    anchor.dataset.type = type;
    anchor.dataset.text = text;

    const marker = document.createElement('span');
    marker.className = 'ff-annotation-marker';
    const textSpan = document.createElement('span');
    textSpan.className = 'ff-annotation-text';
    anchor.appendChild(marker);
    anchor.appendChild(textSpan);

    return { anchor, marker, textSpan };
  }

  function makeFootnoteAnchor(label: string): HTMLElement {
    const sup = document.createElement('sup');
    sup.className = 'ff-footnote-ref';
    sup.dataset.label = label;
    return sup;
  }

  // --- Annotation anchors ---

  it('shows the singleton tooltip on mouseover of a collapsed annotation, positioned via positionPopup(anchor)', () => {
    setAnnotationDisplayModes({ comment: 'collapsed' });
    const { anchor } = makeAnnotationAnchor('comment', 'Full annotation text');
    setUpRoot(anchor);

    const positionSpy = vi.spyOn(positionPopupModule, 'positionPopup');

    expect(isHoverTooltipVisible()).toBe(false);
    anchor.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));

    expect(isHoverTooltipVisible()).toBe(true);
    expect(getHoverTooltipElement()?.textContent).toBe('Full annotation text');
    expect(positionSpy).toHaveBeenCalledTimes(1);
    // Only checks the tooltip element was passed as the first argument — NOT
    // that the anchor's coordinates (the second argument) are correct. jsdom
    // returns all-zero rects for getBoundingClientRect(), so asserting the
    // actual coords here wouldn't catch a wrong-anchor bug; that's covered by
    // real-WebKit e2e verification instead, not this test.
    expect(positionSpy.mock.calls[0][0]).toBe(getHoverTooltipElement());
  });

  it('does NOT show a tooltip for an annotation whose display mode is not actually collapsed (belt-and-suspenders gate)', () => {
    // Class present (as if from a stale decoration) but the live display mode
    // says 'inline' — hover-tooltip.ts must re-check getAnnotationDisplayModes()
    // itself rather than trusting the class alone.
    setAnnotationDisplayModes({ comment: 'inline' });
    const { anchor } = makeAnnotationAnchor('comment', 'Full annotation text');
    setUpRoot(anchor);

    anchor.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));

    expect(isHoverTooltipVisible()).toBe(false);
  });

  it('does NOT hide the tooltip when mouseout moves between two child nodes of the SAME anchor', () => {
    setAnnotationDisplayModes({ comment: 'collapsed' });
    const { anchor, marker, textSpan } = makeAnnotationAnchor('comment', 'Full annotation text');
    setUpRoot(anchor);

    marker.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
    expect(isHoverTooltipVisible()).toBe(true);

    // Cursor moves from the marker child to the text child — still inside the
    // same anchor. Must NOT flicker/hide.
    marker.dispatchEvent(new MouseEvent('mouseout', { bubbles: true, relatedTarget: textSpan }));
    expect(isHoverTooltipVisible()).toBe(true);
  });

  it('hides the tooltip when mouseout truly leaves the anchor for an unrelated element', () => {
    setAnnotationDisplayModes({ comment: 'collapsed' });
    const { anchor, marker } = makeAnnotationAnchor('comment', 'Full annotation text');
    const outside = document.createElement('div');
    setUpRoot(anchor, outside);

    marker.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
    expect(isHoverTooltipVisible()).toBe(true);

    marker.dispatchEvent(new MouseEvent('mouseout', { bubbles: true, relatedTarget: outside }));
    expect(isHoverTooltipVisible()).toBe(false);
  });

  it('hides the tooltip on mouseout with no relatedTarget at all (pointer left the window)', () => {
    setAnnotationDisplayModes({ comment: 'collapsed' });
    const { anchor, marker } = makeAnnotationAnchor('comment', 'Full annotation text');
    setUpRoot(anchor);

    marker.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
    expect(isHoverTooltipVisible()).toBe(true);

    marker.dispatchEvent(new MouseEvent('mouseout', { bubbles: true, relatedTarget: null }));
    expect(isHoverTooltipVisible()).toBe(false);
  });

  it('only ever has ONE tooltip element in the DOM, regardless of how many anchors are hovered in sequence', () => {
    setAnnotationDisplayModes({ comment: 'collapsed', reference: 'collapsed' });
    const { anchor: a1 } = makeAnnotationAnchor('comment', 'First');
    const { anchor: a2 } = makeAnnotationAnchor('reference', 'Second');
    setUpRoot(a1, a2);

    a1.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
    a1.dispatchEvent(new MouseEvent('mouseout', { bubbles: true, relatedTarget: a2 }));
    a2.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));

    expect(document.querySelectorAll('.ff-hover-tooltip').length).toBe(1);
    expect(getHoverTooltipElement()?.textContent).toBe('Second');
  });

  // --- Dismissal triggers ---

  it('hides on a scroll event dispatched on document', () => {
    // NOTE: this dispatches directly on `document`, so it would still pass
    // even if the listener were registered without the capture flag — it
    // only proves document-level scroll hides the tooltip, not that capture
    // phase specifically is wired up. A real capture-phase check would need
    // a non-bubbling scroll dispatched on a nested descendant element.
    setAnnotationDisplayModes({ comment: 'collapsed' });
    const { anchor } = makeAnnotationAnchor('comment', 'text');
    setUpRoot(anchor);
    anchor.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
    expect(isHoverTooltipVisible()).toBe(true);

    document.dispatchEvent(new Event('scroll'));
    expect(isHoverTooltipVisible()).toBe(false);
  });

  it('hides on any click', () => {
    setAnnotationDisplayModes({ comment: 'collapsed' });
    const { anchor } = makeAnnotationAnchor('comment', 'text');
    setUpRoot(anchor);
    anchor.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
    expect(isHoverTooltipVisible()).toBe(true);

    document.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    expect(isHoverTooltipVisible()).toBe(false);
  });

  it('hides on any mousedown', () => {
    setAnnotationDisplayModes({ comment: 'collapsed' });
    const { anchor } = makeAnnotationAnchor('comment', 'text');
    setUpRoot(anchor);
    anchor.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
    expect(isHoverTooltipVisible()).toBe(true);

    document.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }));
    expect(isHoverTooltipVisible()).toBe(false);
  });

  it('hides on window resize', () => {
    setAnnotationDisplayModes({ comment: 'collapsed' });
    const { anchor } = makeAnnotationAnchor('comment', 'text');
    setUpRoot(anchor);
    anchor.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
    expect(isHoverTooltipVisible()).toBe(true);

    window.dispatchEvent(new Event('resize'));
    expect(isHoverTooltipVisible()).toBe(false);
  });

  it('hides on editor root blur', () => {
    setAnnotationDisplayModes({ comment: 'collapsed' });
    const { anchor } = makeAnnotationAnchor('comment', 'text');
    const editorRoot = setUpRoot(anchor);
    anchor.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
    expect(isHoverTooltipVisible()).toBe(true);

    editorRoot.dispatchEvent(new Event('blur'));
    expect(isHoverTooltipVisible()).toBe(false);
  });

  it('hides on plugin/view destroy (the cleanup function returned by installHoverTooltipListeners)', () => {
    setAnnotationDisplayModes({ comment: 'collapsed' });
    const { anchor } = makeAnnotationAnchor('comment', 'text');
    setUpRoot(anchor);
    anchor.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
    expect(isHoverTooltipVisible()).toBe(true);

    // Simulate hover-tooltip.ts's own $prose plugin view().destroy(), which
    // calls cleanup() then hideHoverTooltip() explicitly (the cleanup
    // function itself only removes listeners, it doesn't hide anything still
    // showing).
    cleanup?.();
    cleanup = null;
    hideHoverTooltip();
    expect(isHoverTooltipVisible()).toBe(false);
  });

  // --- Footnote anchors ---

  it('shows the footnote-variant tooltip using the live footnote definitions map', () => {
    setFootnoteDefinitions({ '1': 'A footnote definition.' });
    const sup = makeFootnoteAnchor('1');
    setUpRoot(sup);

    sup.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));

    expect(isHoverTooltipVisible()).toBe(true);
    expect(getHoverTooltipElement()?.textContent).toBe('A footnote definition.');
    expect(getHoverTooltipElement()?.classList.contains('ff-hover-tooltip--footnote')).toBe(true);
  });

  it('reads the CURRENT definition at hover time (no stale content after setFootnoteDefinitions() updates)', () => {
    setFootnoteDefinitions({ '1': 'Old text.' });
    const sup = makeFootnoteAnchor('1');
    setUpRoot(sup);

    sup.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
    expect(getHoverTooltipElement()?.textContent).toBe('Old text.');
    sup.dispatchEvent(new MouseEvent('mouseout', { bubbles: true, relatedTarget: null }));

    setFootnoteDefinitions({ '1': 'New text.' });
    sup.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
    expect(getHoverTooltipElement()?.textContent).toBe('New text.');
  });

  it('does NOT show a tooltip for a footnote ref with no resolved definition', () => {
    setFootnoteDefinitions({});
    const sup = makeFootnoteAnchor('99');
    setUpRoot(sup);

    sup.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));

    expect(isHoverTooltipVisible()).toBe(false);
  });

  it('does NOT show a footnote tooltip while source mode is enabled', () => {
    setFootnoteDefinitions({ '1': 'A footnote definition.' });
    setSourceModeEnabled(true);
    const sup = makeFootnoteAnchor('1');
    setUpRoot(sup);

    sup.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));

    expect(isHoverTooltipVisible()).toBe(false);
  });

  // --- Real editor wiring (proves hoverTooltipPlugin's view() actually
  // installs the delegated listeners on the real editorView.dom, not just
  // that installHoverTooltipListeners() works in isolation) ---

  describe('wired into a real Milkdown Editor via hoverTooltipPlugin', () => {
    let editor: Editor | null = null;

    afterEach(async () => {
      if (editor) {
        await editor.destroy();
        editor = null;
      }
    });

    async function makeEditor(markdown: string): Promise<EditorView> {
      const div = document.createElement('div');
      document.body.appendChild(div);
      const e = await Editor.make()
        .config((ctx) => {
          ctx.set(rootCtx, div);
          ctx.set(defaultValueCtx, markdown);
        })
        .use(annotationPlugin)
        .use(commonmark)
        .use(gfm)
        .use(annotationDisplayPlugin)
        .use(hoverTooltipPlugin)
        .create();
      editor = e;
      return e.ctx.get(editorViewCtx);
    }

    it('shows the shared tooltip on real mouseover of a collapsed annotation rendered by the real NodeView', async () => {
      setAnnotationDisplayModes({ comment: 'collapsed' });
      const view = await makeEditor('<!-- ::comment:: Needs more detail -->');
      const wrapper = view.dom.querySelector('.ff-annotation') as HTMLElement;

      expect(wrapper.classList.contains('ff-annotation-collapsed')).toBe(true);
      expect(isHoverTooltipVisible()).toBe(false);

      wrapper.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));

      expect(isHoverTooltipVisible()).toBe(true);
      expect(getHoverTooltipElement()?.textContent).toBe('Needs more detail');

      // Destroying the editor (plugin view teardown) must hide it again.
      await editor?.destroy();
      editor = null;
      expect(isHoverTooltipVisible()).toBe(false);
    });

    it('does not show a tooltip for an INLINE (non-collapsed) annotation via the real editor', async () => {
      const view = await makeEditor('<!-- ::comment:: Needs more detail -->');
      const wrapper = view.dom.querySelector('.ff-annotation') as HTMLElement;

      expect(wrapper.classList.contains('ff-annotation-collapsed')).toBe(false);

      wrapper.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));

      expect(isHoverTooltipVisible()).toBe(false);
    });
  });
});
