/**
 * Line Height Measurement Fix
 *
 * CM6's measureTextSize() picks the first short line (<=20 chars) with children
 * to determine defaultLineHeight. When that line is a heading with Decoration.line
 * CSS (font-size: 31px, line-height: 1.2), CM measures 37px instead of the correct
 * body height of ~31px. This 19% overestimate for every off-screen line causes
 * "Viewport failed to stabilize" during scrolling.
 *
 * This fix monkey-patches measureTextSize() on the DocView instance to correct its
 * lineHeight return value using a clean dummy .cm-line element measurement.
 *
 * PRIVATE API: Accesses view.docView.measureTextSize (internal CM6).
 * All access uses optional chaining — degrades to no-op if CM6 internals change.
 *
 * @see https://github.com/codemirror/view/blob/main/src/docview.ts (measureTextSize)
 * @see https://github.com/codemirror/view/blob/main/src/heightmap.ts (HeightOracle)
 */

import type { EditorView } from '@codemirror/view';

/**
 * Measure the correct body line height by creating a dummy .cm-line element
 * inside the editor's contentDOM. This inherits editor CSS but has no heading
 * decoration classes, giving the true body text height.
 *
 * Uses observer.ignore() to suppress CM6's MutationObserver during DOM manipulation,
 * matching how CM6's own fallback measurement works internally.
 */
function measureBodyLineHeight(view: EditorView): number {
  let height = 0;

  // Suppress CM6's MutationObserver to prevent unexpected re-measurements
  const ignoreFn = (view as any).observer?.ignore?.bind((view as any).observer);
  const measure = () => {
    const dummy = document.createElement('div');
    dummy.className = 'cm-line';
    dummy.textContent = 'x';
    dummy.style.cssText = 'position: absolute; width: 99999px; visibility: hidden;';
    view.contentDOM.appendChild(dummy);
    height = dummy.getBoundingClientRect().height;
    view.contentDOM.removeChild(dummy);
  };

  if (ignoreFn) {
    ignoreFn(measure);
  } else {
    measure();
  }

  return height;
}

/**
 * Install the line height fix by monkey-patching measureTextSize() on the DocView.
 *
 * Call this ONCE after creating the EditorView. The patch wraps the original
 * measureTextSize(), lets it run normally, then corrects lineHeight if it was
 * contaminated by a heading-decorated line.
 *
 * Degrades gracefully: if docView or measureTextSize doesn't exist (CM6 internals
 * changed), this is a no-op.
 */
export function installLineHeightFix(view: EditorView): void {
  const docView = (view as any).docView;
  if (!docView?.measureTextSize) return;

  const original = docView.measureTextSize.bind(docView);

  docView.measureTextSize = () => {
    const result = original();

    const correct = measureBodyLineHeight(view);
    if (correct > 0 && Math.abs(result.lineHeight - correct) > 1) {
      result.lineHeight = correct;
    }

    return result;
  };
}
