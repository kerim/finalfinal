// undo-mode-switch-focus, second timing gap, P3 (4e): a CodeMirror `Annotation` marking a
// `setContent` push that overlaps text the user just typed (see recent-edit-span.ts) and is
// therefore being dispatched as its own undoable step instead of silently, `addToHistory:
// false`. Same pattern as `Transaction.addToHistory` -- a plain `Annotation.define()`, checked
// via `tr.annotation(derivedCorrection)`. Lives in its own tiny module (not text-diff.ts or
// api.ts) so undo-coordinator.ts's three provenance predicates (§4e) and main.ts's edit-span
// tracker can both import it without a circular dependency on api.ts.
import { Annotation } from '@codemirror/state';

export const derivedCorrection = Annotation.define<boolean>();
