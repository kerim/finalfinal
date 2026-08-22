/**
 * Section Anchor & Bibliography Plugin for CodeMirror 6
 *
 * Hides invisible markers in the editor while preserving them in the document:
 * - `<!-- @sid:UUID -->` - Section anchors for ID tracking
 * - `<!-- ::auto-bibliography:: -->` - Bibliography marker (on same line as header)
 * - `<!-- ::auto-bibliography-end:: -->` - Bibliography terminator (own line, closes the
 *   section for BlockParser.parse() — see BlockParser.bibliographyEndMarker's Swift-side doc
 *   comment). Same treatment as the opening marker above: hidden, atomic, clipboard-stripped.
 *   Unlike the opening marker, an accidentally-corrupted terminator (e.g. one dropped
 *   character from the cursor landing inside it) doesn't just fail to re-open the section —
 *   `parse()` matches it by exact string equality, so a corrupted terminator silently fails
 *   to CLOSE the section, re-flagging trailing user text as bibliography on the next reparse
 *   and reopening the exact orphan-flag bug this marker exists to fix. That's why the atomic
 *   range here isn't optional polish. It also gets three keyboard fixes; the first is a
 *   CodeMirror analogue of a fix in bibliography-end-marker-plugin.ts (Milkdown package), the
 *   other two have no Milkdown-side analogue because ProseMirror's atom-node model doesn't
 *   expose the underlying danger the same way:
 *   - An Enter-key insertion-boundary fix — see `bibliographyEndEnterKeymap` below.
 *   - Delete/Backspace protection — see `bibliographyEndDeleteKeymap` below. Without it,
 *     CodeMirror's own delete commands silently destroy the entire hidden terminator in one
 *     keystroke the moment the cursor sits next to it (a different mechanism than the
 *     Milkdown side's atom-delete fallback, same user-visible result — see that keymap's own
 *     doc comment for the full mechanism, the exact reachable key set, and two explicit
 *     non-goals).
 *   - Line-relocation/whole-line-delete protection — see `bibliographyEndLineRelocationKeymap`
 *     and the `Shift-Mod-k` binding inside `bibliographyEndDeleteKeymap` below. CodeMirror's
 *     move-line/copy-line/delete-line commands bypass the atomic-range mechanism entirely
 *     (they act on whole document lines, with no `skipAtomic` involved at all), so they can
 *     silently relocate or duplicate the invisible terminator onto the wrong line — worse than
 *     deletion, since nothing looks wrong until the next bibliography regeneration.
 * - `<!-- ::zoom-notes:: -->` - Zoom-notes separator (between content and footnotes)
 *
 * Features:
 * - Decoration.replace() makes markers invisible
 * - atomicRanges makes cursor skip over hidden regions
 * - Clipboard handlers strip markers from copied text
 * - Enter at the end of the last bibliography entry's line inserts the new line after the
 *   terminator instead of before it
 * - Delete/Backspace immediately adjacent to the bibliography terminator is a no-op instead
 *   of silently destroying it
 * - Moving, duplicating, or deleting the terminator's own line (Alt-Arrow / Shift-Alt-Arrow /
 *   Cmd-Shift-K) is a no-op instead of silently relocating, duplicating, or deleting it
 */

import { type EditorState, type Extension, Prec, RangeSetBuilder } from '@codemirror/state';
import { Decoration, type DecorationSet, EditorView, keymap, ViewPlugin, type ViewUpdate } from '@codemirror/view';

// Regex to match section anchor comments: <!-- @sid:UUID -->
// UUID format: 8-4-4-4-12 hex characters (standard UUID v4)
// Anchors are on the same line as headers (no trailing newline)
const _ANCHOR_REGEX = /<!-- @sid:[0-9a-fA-F-]+ -->/g;

// For extracting anchor info (no newline - just the comment)
const ANCHOR_PATTERN = /<!-- @sid:([0-9a-fA-F-]+) -->/;

// For decorations and atomic ranges
// Anchors are on the same line as headers: <!-- @sid:UUID --># Header
const ANCHOR_DECORATION_REGEX = /<!-- @sid:[0-9a-fA-F-]+ -->/g;

// Bibliography marker - on same line as header, matched as one standalone HTML comment
// (not a start/end delimiter pair itself — the separate BIBLIOGRAPHY_END_REGEX below is a
// different marker altogether, closing the whole section rather than this one comment)
// Pattern: <!-- ::auto-bibliography:: --># Bibliography
const BIBLIOGRAPHY_START_REGEX = /<!-- ::auto-bibliography:: -->/g;

// Bibliography terminator - own blank-line-separated line, closes the section for
// BlockParser.parse() (Swift side). See BlockParser.bibliographyEndMarker's doc comment.
const BIBLIOGRAPHY_END_REGEX = /<!-- ::auto-bibliography-end:: -->/g;

// Zoom-notes marker - separates main content from footnotes when zoomed into a section
const ZOOM_NOTES_MARKER_REGEX = /<!-- ::zoom-notes:: -->/g;

// Combined regex for stripping all hidden markers from clipboard
// Exported for spellcheck-plugin to strip markers before checking
export const ALL_HIDDEN_MARKERS_REGEX =
  /<!-- @sid:[0-9a-fA-F-]+ -->|<!-- ::auto-bibliography:: -->|<!-- ::auto-bibliography-end:: -->|<!-- ::zoom-notes:: -->/g;

/**
 * Find all hidden marker ranges in the document for decoration purposes
 * Includes section anchors and bibliography markers
 */
function findHiddenMarkers(state: EditorState): { from: number; to: number }[] {
  const text = state.doc.toString();
  const markers: { from: number; to: number }[] = [];

  // Find section anchors
  let match: RegExpExecArray | null;
  ANCHOR_DECORATION_REGEX.lastIndex = 0;
  while ((match = ANCHOR_DECORATION_REGEX.exec(text)) !== null) {
    markers.push({
      from: match.index,
      to: match.index + match[0].length,
    });
  }

  // Find bibliography start markers (on same line as header, no end marker)
  BIBLIOGRAPHY_START_REGEX.lastIndex = 0;
  while ((match = BIBLIOGRAPHY_START_REGEX.exec(text)) !== null) {
    markers.push({
      from: match.index,
      to: match.index + match[0].length,
    });
  }

  // Find bibliography end (terminator) markers
  BIBLIOGRAPHY_END_REGEX.lastIndex = 0;
  while ((match = BIBLIOGRAPHY_END_REGEX.exec(text)) !== null) {
    markers.push({
      from: match.index,
      to: match.index + match[0].length,
    });
  }

  // Find zoom-notes markers (separates content from footnotes in zoomed sections)
  ZOOM_NOTES_MARKER_REGEX.lastIndex = 0;
  while ((match = ZOOM_NOTES_MARKER_REGEX.exec(text)) !== null) {
    markers.push({
      from: match.index,
      to: match.index + match[0].length,
    });
  }

  // Sort by position (required for RangeSetBuilder)
  markers.sort((a, b) => a.from - b.from);

  return markers;
}

/**
 * Build decorations to hide all hidden markers visually
 */
function buildDecorations(state: EditorState): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const markers = findHiddenMarkers(state);

  for (const marker of markers) {
    // Use Decoration.replace with empty widget to completely hide the marker
    builder.add(marker.from, marker.to, Decoration.replace({}));
  }

  return builder.finish();
}

/**
 * ViewPlugin that maintains decorations to hide all markers visually
 */
const anchorDecorationPlugin = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;

    constructor(view: EditorView) {
      this.decorations = buildDecorations(view.state);
    }

    update(update: ViewUpdate) {
      if (update.docChanged || update.viewportChanged) {
        this.decorations = buildDecorations(update.state);
      }
    }
  },
  {
    decorations: (v) => v.decorations,
  }
);

/**
 * Extension that makes cursor skip over hidden marker regions
 * Section anchors are on the same line as headers, so hiding them doesn't create blank lines
 * Bibliography markers are on their own lines (may leave empty lines when hidden)
 */
const atomicAnchorRanges = EditorView.atomicRanges.of((view: EditorView) => {
  const plugin = view.plugin(anchorDecorationPlugin);
  return plugin?.decorations ?? Decoration.none;
});

// ---- Bibliography terminator Enter-key insertion-boundary fix ----
//
// CodeMirror analogue of bibliography-end-marker-plugin.ts's `bibliographyEndEnterKeymap` in
// the Milkdown package — see that file's doc comment for the full rationale. CodeMirror has no
// block-node structure, so both the check and the fix below operate on raw text lines instead
// of ProseMirror doc nodes.
//
// The terminator always sits on its own line, blank-line-separated from whatever precedes it
// (fragments are joined with "\n\n" — see BlockParser+Assembly.swift's
// `assembleMarkdownForEditor`). CodeMirror's default Enter behavior (`insertNewlineAndIndent`,
// from `defaultKeymap` in main.ts) inserts the new line AT the cursor position — so a cursor at
// the end of the last bibliography entry's line, followed by Enter, would insert the new line
// BEFORE the terminator: still positionally inside the section on the next reparse (Source
// Mode's debounced re-parse, or the reparse that runs immediately before every PDF export),
// reproducing the exact orphan-flag bug this whole mechanism exists to close — on the single
// most natural way a user would type: Enter, then type.

/**
 * If `pos` sits at the very end of the nearest non-blank line above the bibliography-end
 * terminator (skipping any blank lines in between — the ordinary case is exactly one, from the
 * "\n\n" fragment join), returns the position immediately after the terminator's own line text
 * — where a new blank-line-separated line should be inserted instead of splitting at the
 * cursor. Returns null when there's no terminator in the document, or `pos` doesn't qualify
 * (ordinary mid-text or mid-document Enter, which must fall through to CodeMirror's default
 * behavior).
 *
 * Exported so it can be exercised directly in tests, mirroring how bibliography-end-marker-
 * plugin.ts's `isBibliographyEndMarkerAdjacent` is exported for the same reason.
 */
export function bibliographyEndInsertionPoint(state: EditorState, pos: number): number | null {
  const cursorLine = state.doc.lineAt(pos);
  if (pos !== cursorLine.to) return null; // must be at the very end of its line

  const text = state.doc.toString();
  BIBLIOGRAPHY_END_REGEX.lastIndex = 0;
  let match: RegExpExecArray | null;
  // Loop defensively over every match — assembleMarkdownForEditor only ever emits one
  // terminator per document today, but nothing here depends on that staying true.
  while ((match = BIBLIOGRAPHY_END_REGEX.exec(text)) !== null) {
    const terminatorLine = state.doc.lineAt(match.index);

    let lineNumber = terminatorLine.number - 1;
    while (lineNumber >= 1 && state.doc.line(lineNumber).text.trim() === '') {
      lineNumber--;
    }
    if (lineNumber >= 1 && lineNumber === cursorLine.number) {
      return terminatorLine.to;
    }
  }

  return null;
}

/**
 * Enter-key placement fix as a CodeMirror keymap binding. Wrapped in `Prec.highest` so it
 * always gets first refusal on Enter regardless of where `anchorPlugin()` sits in main.ts's
 * extension array — main.ts registers `defaultKeymap` (which owns the default Enter binding,
 * `insertNewlineAndIndent`) in its own separate `keymap.of([...])` call earlier in that array,
 * so without an explicit precedence bump this binding would lose on plain array order. This
 * makes the same guarantee the Milkdown fix documents relying on (every `$prose` plugin sits
 * ahead of Milkdown's merged base+preset keymap) explicit here via CodeMirror's own precedence
 * mechanism instead of an implicit array-order convention.
 */
const bibliographyEndEnterKeymap = Prec.highest(
  keymap.of([
    {
      key: 'Enter',
      run: (view: EditorView): boolean => {
        const sel = view.state.selection.main;
        if (!sel.empty) return false;

        const insertPos = bibliographyEndInsertionPoint(view.state, sel.head);
        if (insertPos === null) return false;

        // Insert two newlines right after the terminator's own line text. Combined with the
        // blank line already separating the terminator from whatever precedes or follows it,
        // this lands the cursor on its own blank-line-separated empty line — a new paragraph
        // positioned strictly after the terminator (and before any trailing content), instead
        // of splitting the current line in place ahead of it.
        view.dispatch({
          changes: { from: insertPos, to: insertPos, insert: '\n\n' },
          selection: { anchor: insertPos + 2 },
          scrollIntoView: true,
          userEvent: 'input',
        });
        return true;
      },
    },
  ])
);

// ---- Bibliography terminator Delete/Backspace protection ----
//
// CodeMirror analogue of bibliography-end-marker-plugin.ts's `bibliographyEndDeleteKeymap` in
// the Milkdown package — see that file's doc comment for the full rationale on WHY this
// protection exists (the orphan-flag bug). The underlying danger here is different in mechanism
// from ProseMirror's "atom-delete fallback", though the user-visible outcome is the same: the
// terminator gets silently destroyed by an ordinary Delete/Backspace press.
//
// `atomicAnchorRanges` above (EditorView.atomicRanges) already makes the cursor SKIP over the
// hidden marker when moving with arrow keys — but it does NOT block deletion. @codemirror/
// commands' delete family (deleteCharBackward/Forward, deleteGroupBackward/Forward,
// deleteLineBoundaryBackward/Forward, deleteToLineEnd — all built on that package's shared
// `deleteBy` + `skipAtomic` helpers, confirmed by reading the bundled source directly) computes
// a naive one-step target position FIRST, and only then calls `skipAtomic(target, towards,
// forward)`: if that naive target would land STRICTLY INSIDE an atomic range, `skipAtomic` snaps
// the target to the FAR edge of that range instead — i.e. it expands the deletion to swallow the
// entire atomic region in one keystroke, rather than refusing it. The atomic range here spans
// EXACTLY the terminator's own ~34 characters (`findHiddenMarkers` above builds it straight from
// a BIBLIOGRAPHY_END_REGEX match, with no dependency on line boundaries), so a single Backspace
// with the cursor immediately after that range, or a single Delete with the cursor immediately
// before it, deletes exactly the terminator's text in one shot — same end result (terminator
// destroyed, orphan-flag bug reopens on next reparse) as the Milkdown side's atom-fallback
// danger, just reached through CodeMirror's snap-to-atomic-boundary mechanism instead of
// ProseMirror's node-fallback mechanism.
//
// The reachable key set is NOT the same API surface as ProseMirror's macBaseKeymap — verified
// against @codemirror/commands' actual `defaultKeymap` (= extras concat'd with `standardKeymap`,
// which itself folds `emacsStyleKeymap` in under `mac:` aliases) as registered by main.ts
// (`keymap.of([...defaultKeymap.filter(...), ...])`, filtering out only `Mod-/`). On this
// macOS-only app, the bindings that reach a `deleteBy`-family command are:
//   Forward (dangerous when the cursor sits immediately BEFORE the marker, i.e. the marker
//   begins exactly at the cursor):
//     `Delete` (deleteCharForward), `Ctrl-d` (deleteCharForward, emacs alias), `Alt-Delete`
//     (deleteGroupForward, mac alias of `Mod-Delete`), `Mod-Delete` i.e. Cmd-Delete
//     (deleteLineBoundaryForward — a separate mac-only binding from the one above), `Ctrl-k`
//     (deleteToLineEnd, emacs alias — dangerous here specifically because when the cursor sits
//     at the marker's line start, the marker's own line end IS the marker's own end).
//   Backward (dangerous when the cursor sits immediately AFTER the marker, i.e. the marker ends
//   exactly at the cursor):
//     `Backspace` / `Shift-Backspace` (deleteCharBackward — the same command either way, per
//     standardKeymap's own inline `shift:` fallback), `Ctrl-h` (deleteCharBackward, emacs
//     alias), `Alt-Backspace` (deleteGroupBackward, mac alias of `Mod-Backspace`),
//     `Mod-Backspace` i.e. Cmd-Backspace (deleteLineBoundaryBackward — a separate mac-only
//     binding from the one above), `Ctrl-Alt-h` (deleteGroupBackward, emacs alias — same command
//     as Alt-Backspace, different key).
// Ten bindings in total here — not the same COUNT-implies-parity story it might look like at a
// glance, though. Notably, this list guards bare `Backspace`, while the Milkdown side's own
// ten-binding list (bibliography-end-marker-plugin.ts's `bibliographyEndDeleteKeymap`)
// deliberately does NOT: on the Milkdown side, Milkdown's own `overrideBaseKeymap` already
// replaces bare `Backspace` with `joinTextblockBackward`, a strictly textblock-to-textblock join
// that never reaches the atom-delete fallback at all — bare Backspace is already safe there, so
// guarding it would be a no-op with extra code. CodeMirror has no equivalent override; bare
// `Backspace` here really does resolve to the dangerous `deleteCharBackward`, so it has to be
// guarded. Beyond that one asymmetry, the two lists cover the same conceptual ground (every
// forward- and backward-deleting command reachable on macOS) with different literal key
// spellings, since CodeMirror has no "Mod-Backspace = word delete" convention of its own (that's
// `Alt-Backspace` here) and instead has its own line-boundary and emacs-alias bindings that
// ProseMirror doesn't.
//
// `Ctrl-k` was the one genuine surprise here, and is worth calling out on its own: it's an
// emacs "kill to end of line" binding, not an obvious delete-family command at first glance,
// and it would be easy to miss by pattern-matching against the Milkdown side's key list alone.
// It's dangerous for a reason specific to this marker's layout: `deleteToLineEnd` targets
// `view.lineBlockAt(head).to`, i.e. wherever the CURRENT line ends, not the atomic range's own
// end. In the common case — the terminator alone on its own document line, which is how
// `assembleMarkdownForEditor` (BlockParser+Assembly.swift) always writes it — a cursor at that
// line's start (the same "before" position every other forward binding above cares about) has a
// line-end that IS the atomic range's own end, so "delete to end of line" from there deletes
// exactly the terminator. The terminator CAN end up glued to other text on the same line, though
// — hand-typed edits can produce this, which is exactly the shape the sibling Swift-side fix in
// this same worktree (BlockParser+Splitting.swift's `RawBlockSplitter`) exists to tolerate — and
// in that case `Ctrl-k` from the marker's own start could reach past the terminator into
// whatever follows it on the line. That doesn't create a gap in this guard: the check below is
// `isBibliographyEndMarkerAdjacent`'s exact atomic-range-boundary predicate, not a line-boundary
// one, so it still fires (and still no-ops the keystroke) purely from cursor position, regardless
// of what else shares the line.
//
// Two deliberate non-goals, both matching scope decisions already made on the Milkdown side:
//   1. Only a collapsed cursor is guarded (`isBibliographyEndMarkerAdjacent` returns `false`
//      for any non-empty selection, mirroring the Milkdown predicate's own `if (!empty) return
//      false`). A real drag-selection that happens to span across the terminator and gets
//      deleted is treated as the user's explicit intent, not a fat-finger — same call the
//      Milkdown side already made.
//   2. This protects the terminator's own TEXT, not the blank-line separator next to it. A
//      command that consumes only the blank line before/after the terminator (e.g. `Ctrl-k`
//      pressed from that blank line, rather than from the marker's own line start) glues the
//      terminator closer to neighboring content without deleting any of its characters — a
//      real but different concern (glue, not destruction) that this keymap does not address.
//      It's out of scope here because `RawBlockSplitter` (BlockParser+Splitting.swift, Swift
//      side) already splits the terminator out as its own fragment even when hand-typed glued
//      to neighboring content — see that file's `consumeContentLine` and this file's own doc
//      comment above on `BIBLIOGRAPHY_END_REGEX`'s sibling in bibliography-end-marker-
//      plugin.ts. Only the marker's own text surviving intact is load-bearing for
//      `BlockParser.parse()`'s exact-string-equality check; its blank-line spacing isn't.
//
// `isBibliographyEndMarkerAdjacent` is exported so it can be exercised directly in tests,
// mirroring the Milkdown side's identically-named predicate.

/**
 * Whether the cursor — a collapsed selection only, matching the Milkdown predicate's own scope —
 * sits exactly at the boundary of a bibliography-end terminator's hidden, atomic range.
 * `direction: 'after'` is true when the terminator begins exactly at the cursor (the position a
 * forward-delete command steps into first); `direction: 'before'` is true when the terminator
 * ends exactly at the cursor (the position a backward-delete command steps into first).
 */
export function isBibliographyEndMarkerAdjacent(state: EditorState, direction: 'before' | 'after'): boolean {
  const { main } = state.selection;
  if (!main.empty) return false;

  const text = state.doc.toString();
  BIBLIOGRAPHY_END_REGEX.lastIndex = 0;
  let match: RegExpExecArray | null;
  // Loop defensively over every match, mirroring bibliographyEndInsertionPoint above.
  while ((match = BIBLIOGRAPHY_END_REGEX.exec(text)) !== null) {
    const from = match.index;
    const to = match.index + match[0].length;
    if (direction === 'after' && main.head === from) return true;
    if (direction === 'before' && main.head === to) return true;
  }

  return false;
}

// ---- Whole-line danger: deleteLine / moveLine / copyLine bypass skipAtomic entirely ----
//
// Everything guarded above goes through @codemirror/commands' shared `deleteBy` + `skipAtomic`
// helpers, which at least KNOW about atomic ranges even though they don't refuse to cross them.
// Three more default-keymap commands don't consult atomic ranges — or `deleteBy` — at all:
// `deleteLine` (Shift-Mod-k, i.e. Cmd-Shift-K on macOS) and `moveLine`/`copyLine` (the
// Alt-ArrowUp/Down and Shift-Alt-ArrowUp/Down families) all build their changes straight from
// `selectedLineBlocks(state)` — the document line(s) under the selection — with no awareness of
// `EditorView.atomicRanges` anywhere in that path (confirmed by reading the bundled source
// directly, same as the `deleteBy` family above). Whatever text shares the cursor's line goes
// along for the ride, hidden or not:
//   - `deleteLine` deletes the whole line outright — strictly worse than nothing (the marker's
//     ~34 characters are just gone), but at least it fails loud in the sense that a full line
//     vanishes from the document's length.
//   - `moveLine`/`copyLine` are the genuinely nastier failure mode: nothing is deleted.
//     `moveLineUp`/`moveLineDown` (Alt-ArrowUp/Down, macOS's native "move line" gesture)
//     silently RELOCATE the terminator to a different line — re-scoping what
//     `BlockParser.parse()` treats as bibliography content on the next reparse without an
//     obvious edit having happened. Nothing looks wrong in the editor (the marker is invisible
//     either way), so nothing warns the user until the next bibliography regeneration silently
//     wipes out whatever ended up on the wrong side of the relocated terminator.
//     `copyLineUp`/`copyLineDown` (Shift-Alt-ArrowUp/Down, "duplicate line") produce a second
//     terminator instead — a real, reachable way to end up with two markers on one line, the
//     exact shape the sibling Swift-side fix in this same worktree
//     (BlockParser+Splitting.swift's `RawBlockSplitter`) exists to handle.
// And unlike a delete key, this is an easy accident: ordinary Option-Arrow line reordering can
// land the cursor on the terminator's line with no visual warning at all, since the line looks
// empty (the marker is hidden) rather than looking like something worth avoiding.
//
// One more asymmetry worth naming plainly, per this section's own "count things honestly"
// standard above: `Shift-Mod-k` is bound below using the SAME line-based predicate as the
// Alt-Arrow family (`isBibliographyEndMarkerLine`), not the edge-based
// `isBibliographyEndMarkerAdjacent` used everywhere else in `bibliographyEndDeleteKeymap`. That's
// deliberate, not an inconsistency: `deleteLine` deletes whatever line the cursor is ON,
// regardless of where in that line the cursor sits — an edge-adjacency check would miss a cursor
// sitting in the MIDDLE of the marker's line (impossible today since the atomic range makes the
// cursor skip over the marker's interior, but this predicate doesn't rely on that holding, and
// it's the structurally correct check for what `deleteLine` actually does either way).

/**
 * Whether the cursor's current line is a bibliography-end terminator's line — i.e. the line
 * `deleteLine`/`moveLine`/`copyLine`'s shared `selectedLineBlocks(state)` would operate on.
 * Unlike `isBibliographyEndMarkerAdjacent`'s exact atomic-range-boundary check, this doesn't
 * require the terminator to occupy the line's ENTIRE text — a terminator glued to other text on
 * the same line (see the `Ctrl-k` callout above) is still fully covered, because these three
 * commands act on whole document lines regardless of what else shares them.
 *
 * Only a collapsed cursor is guarded, matching `isBibliographyEndMarkerAdjacent`'s own scope: a
 * deliberate multi-line selection that happens to include the terminator's line is still the
 * user's explicit intent, not a fat-finger.
 */
export function isBibliographyEndMarkerLine(state: EditorState): boolean {
  const { main } = state.selection;
  if (!main.empty) return false;

  const cursorLineNumber = state.doc.lineAt(main.head).number;
  const text = state.doc.toString();
  BIBLIOGRAPHY_END_REGEX.lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = BIBLIOGRAPHY_END_REGEX.exec(text)) !== null) {
    if (state.doc.lineAt(match.index).number === cursorLineNumber) return true;
  }

  return false;
}

/**
 * Delete-key protection as a CodeMirror keymap binding, wrapped in `Prec.highest` for the same
 * reason `bibliographyEndEnterKeymap` above is: main.ts registers `defaultKeymap` (unwrapped) in
 * its own separate `keymap.of([...])` call BEFORE `anchorPlugin()` in its extension array, so
 * without an explicit precedence bump these bindings would lose to defaultKeymap's own
 * Backspace/Delete/etc. bindings on plain array order.
 *
 * Each binding returns `true` WITHOUT dispatching a transaction exactly when the keystroke would
 * otherwise reach the atomic-range-snap danger described above (or, for `Shift-Mod-k` alone, the
 * whole-line `deleteLine` danger described in the section above) — a deliberate no-op — and
 * `false` everywhere else, falling through to normal editing (and to defaultKeymap's own
 * binding) untouched.
 */
const bibliographyEndDeleteKeymap = Prec.highest(
  keymap.of([
    { key: 'Delete', run: (view: EditorView) => isBibliographyEndMarkerAdjacent(view.state, 'after') },
    { key: 'Ctrl-d', run: (view: EditorView) => isBibliographyEndMarkerAdjacent(view.state, 'after') },
    { key: 'Alt-Delete', run: (view: EditorView) => isBibliographyEndMarkerAdjacent(view.state, 'after') },
    { key: 'Mod-Delete', run: (view: EditorView) => isBibliographyEndMarkerAdjacent(view.state, 'after') },
    { key: 'Ctrl-k', run: (view: EditorView) => isBibliographyEndMarkerAdjacent(view.state, 'after') },
    {
      key: 'Backspace',
      run: (view: EditorView) => isBibliographyEndMarkerAdjacent(view.state, 'before'),
      shift: (view: EditorView) => isBibliographyEndMarkerAdjacent(view.state, 'before'),
    },
    { key: 'Ctrl-h', run: (view: EditorView) => isBibliographyEndMarkerAdjacent(view.state, 'before') },
    { key: 'Alt-Backspace', run: (view: EditorView) => isBibliographyEndMarkerAdjacent(view.state, 'before') },
    { key: 'Mod-Backspace', run: (view: EditorView) => isBibliographyEndMarkerAdjacent(view.state, 'before') },
    { key: 'Ctrl-Alt-h', run: (view: EditorView) => isBibliographyEndMarkerAdjacent(view.state, 'before') },
  ])
);
// REMOVED (2026-08-22): a `Shift-Mod-k` -> `deleteLine` guard binding used to live in the keymap
// above, protecting against `defaultKeymap`'s own whole-line-delete binding on that chord. That
// danger no longer exists: `main.ts` now filters `Shift-Mod-k` out of `defaultKeymap` entirely
// (a real, separate fix -- that chord is this app's native "Insert Citation" menu shortcut, and
// CodeMirror's own `deleteLine` binding was silently winning the race against it). With
// `deleteLine` gone from the keymap, this `Prec.highest`-wrapped binding no longer prevented
// anything -- it just unconditionally swallowed `Shift-Mod-k` (via `isBibliographyEndMarkerLine`
// returning true) whenever the cursor sat on the bibliography end-marker line, silently blocking
// Insert Citation in that one cursor position with no defensive purpose left to justify it.

/**
 * Line-relocation protection (`moveLine`/`copyLine`, i.e. Alt-ArrowUp/Down and
 * Shift-Alt-ArrowUp/Down) as its own keymap, separate from `bibliographyEndDeleteKeymap` above
 * because these two commands don't delete anything — see the section comment above
 * `isBibliographyEndMarkerLine` for why silent relocation/duplication is a real, distinct danger
 * worth its own name rather than folding into a keymap called "Delete". Wrapped in `Prec.highest`
 * for the same reason every other keymap in this file is: main.ts registers `defaultKeymap`
 * (which owns these four bindings by default) before `anchorPlugin()` in its extension array.
 */
const bibliographyEndLineRelocationKeymap = Prec.highest(
  keymap.of([
    { key: 'Alt-ArrowUp', run: (view: EditorView) => isBibliographyEndMarkerLine(view.state) },
    { key: 'Alt-ArrowDown', run: (view: EditorView) => isBibliographyEndMarkerLine(view.state) },
    { key: 'Shift-Alt-ArrowUp', run: (view: EditorView) => isBibliographyEndMarkerLine(view.state) },
    { key: 'Shift-Alt-ArrowDown', run: (view: EditorView) => isBibliographyEndMarkerLine(view.state) },
  ])
);

/**
 * Strip all hidden markers from text (anchors and bibliography markers)
 * Used for clipboard operations to ensure clean export
 */
export function stripAnchors(text: string): string {
  return text.replace(ALL_HIDDEN_MARKERS_REGEX, '');
}

/**
 * Extract anchor IDs and their positions from text
 * Returns array of { id, offset } where offset is position in the STRIPPED text
 */
export function extractAnchors(text: string): { id: string; headerOffset: number }[] {
  const results: { id: string; headerOffset: number }[] = [];
  let strippedOffset = 0;
  let _originalOffset = 0;

  const lines = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const match = line.match(ANCHOR_PATTERN);

    if (match) {
      // This line is an anchor - the next non-empty line should be the header
      // Store the offset where the header will be after stripping
      results.push({
        id: match[1],
        headerOffset: strippedOffset,
      });
      // Don't add this line to strippedOffset since it will be removed
      _originalOffset += line.length + 1;
      continue;
    }

    strippedOffset += line.length + 1;
    _originalOffset += line.length + 1;
  }

  return results;
}

/**
 * Inject anchor comments before headers
 * Takes markdown and a map of header positions to section IDs
 * Anchors are placed on the SAME LINE as the header (no newline after anchor)
 * to prevent blank lines when the anchor decoration hides the comment
 */
export function injectAnchors(markdown: string, anchors: { sectionId: string; headerOffset: number }[]): string {
  if (anchors.length === 0) return markdown;

  // Sort anchors by offset in reverse order so we can insert from end to start
  // (this prevents offset drift during insertion)
  const sorted = [...anchors].sort((a, b) => b.headerOffset - a.headerOffset);

  let result = markdown;
  for (const anchor of sorted) {
    // No newline after anchor - anchor stays on same line as header
    const anchorText = `<!-- @sid:${anchor.sectionId} -->`;
    const offset = Math.min(anchor.headerOffset, result.length);
    result = result.slice(0, offset) + anchorText + result.slice(offset);
  }

  return result;
}

/**
 * DOM event handlers for clipboard operations
 * Strips anchors from copied/cut text to ensure clean export
 */
const clipboardHandlers = EditorView.domEventHandlers({
  copy(event, view) {
    const selection = view.state.selection.main;
    if (selection.empty) return false;

    const text = view.state.sliceDoc(selection.from, selection.to);
    const cleanText = stripAnchors(text);

    // Only intercept if there were anchors to strip
    if (cleanText !== text) {
      event.clipboardData?.setData('text/plain', cleanText);
      event.preventDefault();
      return true;
    }

    return false;
  },

  cut(event, view) {
    const selection = view.state.selection.main;
    if (selection.empty) return false;

    const text = view.state.sliceDoc(selection.from, selection.to);
    const cleanText = stripAnchors(text);

    // Only intercept if there were anchors to strip
    if (cleanText !== text) {
      event.clipboardData?.setData('text/plain', cleanText);
      event.preventDefault();

      // Perform the cut by deleting selected text
      view.dispatch({
        changes: { from: selection.from, to: selection.to },
        userEvent: 'delete.cut',
      });

      return true;
    }

    return false;
  },
});

/**
 * Main extension bundle for the anchor plugin
 * Includes all necessary extensions for hiding anchors and handling clipboard
 */
export function anchorPlugin(): Extension {
  return [
    anchorDecorationPlugin,
    atomicAnchorRanges,
    clipboardHandlers,
    bibliographyEndEnterKeymap,
    bibliographyEndDeleteKeymap,
    bibliographyEndLineRelocationKeymap,
  ];
}

/**
 * Get content without anchors (for Swift API)
 */
export function getContentWithoutAnchors(view: EditorView): string {
  return stripAnchors(view.state.doc.toString());
}

/**
 * Get raw content including anchors
 */
export function getContentWithAnchors(view: EditorView): string {
  return view.state.doc.toString();
}
