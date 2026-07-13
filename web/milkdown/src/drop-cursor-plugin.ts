// Drop-cursor plugin — shows a visible caret/line indicator tracking the
// mouse while dragging (a file from Finder, or an existing figure within the
// document) over the editor. Part of the image-placement drag-and-drop fix.
//
// prosemirror-dropcursor@1.8.2 is already present transitively via
// @milkdown/kit/prose/dropcursor (confirmed in node_modules) — no new
// dependency required.

import type { MilkdownPlugin } from '@milkdown/kit/ctx';
import { dropCursor } from '@milkdown/kit/prose/dropcursor';
import { $prose } from '@milkdown/kit/utils';

export const dropCursorPlugin: MilkdownPlugin[] = [
  $prose(() => dropCursor({ color: false, width: 3, class: 'ff-dropcursor' })),
].flat();
