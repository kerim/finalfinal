# Fix: Xcode scheme missing executable

## Context

After `xcodegen generate`, the "final final" scheme's run action doesn't specify an executable. With multiple targets (app + QuickLook Extension), Xcode defaults to "Ask on Launch" instead of running the built app.

## Fix

Add `executable: final final` to the `run` section in `project.yml` (line 18), then regenerate.

```yaml
    run:
      config: Debug
      executable: final final
```

Then run `xcodegen generate` to update the Xcode project.

---

# Annotation Pop-up Editing

## Context

Annotations are currently inline-editable ProseMirror nodes (`content: 'text*'`) with a `contentDOM` where the cursor can enter for direct text editing. This has caused persistent cursor positioning issues -- the editor can't reliably tell when the cursor is inside vs outside the annotation block. After two days of attempted fixes, we're switching to the citation plugin's approach: treat annotations as atomic (non-editable) inline nodes and open a pop-up window for editing.

## Approach

Convert annotations from content-bearing inline nodes to `atom: true` inline nodes with text stored as an attribute. Clicking an annotation opens a pop-up (modeled on `citation-edit-popup.ts`). The serialization format (`<!-- ::type:: content -->`) stays unchanged, so the Swift side needs no modifications.

## Files to Modify

| File | Change |
|------|--------|
| `web/milkdown/src/annotation-edit-popup.ts` | **New file.** Pop-up UI for editing annotation text (modeled on `citation-edit-popup.ts`) |
| `web/milkdown/src/annotation-plugin.ts` | Node: `atom: true`, `attrs.text`, remove `content: 'text*'`. NodeView: non-editable, click opens popup. Update `AnnotationAttrs` interface. |
| `web/milkdown/src/annotation-display-plugin.ts` | Remove cursor-inside logic. Use `node.attrs.text` instead of `node.textContent` (3 occurrences: lines 115, 126, 137) |
| `web/milkdown/src/api-annotations.ts` | `insertAnnotation()` opens popup after insert. `getAnnotations()` reads `attrs.text` |
| `web/milkdown/src/slash-commands.ts` | `/task`, `/comment`, `/reference` open popup after insertion. Fix cursor placement for atom nodes. |
| `web/milkdown/src/block-sync-plugin.ts` | `serializeInlineContent()` line 109: change `child.textContent` to `child.attrs.text` |
| `web/milkdown/src/styles.css` | Add `cursor: pointer`, update `.ff-annotation-text` styles, add popup styles |

**No Swift changes needed** -- `AnnotationSyncService` parses the markdown format, which is unchanged. Confirmed by reviewing all Swift annotation files: the sync service uses regex on serialized markdown, not ProseMirror internals.

**IMPORTANT**: All `node.textContent` -> `node.attrs.text` changes must land atomically in the same commit as the `atom: true` schema change, or `getAnnotations()` will return empty text, causing `AnnotationSyncService` to overwrite database text with empty strings.

## Steps

### 1. Create `annotation-edit-popup.ts`

New file following the `citation-edit-popup.ts` singleton pattern:

- **Singleton state**: `editPopup`, `editPopupInput`, `editingNodePos`, `editingView`, blur timeout
- **`createAnnotationEditPopup()`**: Lazily create DOM structure:
  - Type indicator row (marker icon + "Task"/"Comment"/"Reference" label)
  - Checkbox row (visible only for tasks, toggles `isCompleted`)
  - `<input type="text">` for annotation text (annotations are single-line -- `toMarkdown` normalizes newlines to spaces)
  - Hint: "Enter to save - Escape to cancel"
  - Styled with `position: fixed; z-index: 10000` and theme variables
- **`showAnnotationEditPopup(pos, view, attrs)`**: Position below annotation via `view.coordsAtPos(pos)`, populate fields, show, focus input
- **`commitAnnotationEdit()`**: Read input + checkbox state, dispatch `setNodeMarkup()` to update attrs, hide popup, refocus editor
- **`cancelAnnotationEdit()`**: Hide popup, refocus editor
- **`hideAnnotationEditPopup()`**: Hide popup, clear state
- **`isAnnotationEditPopupOpen()`**: Returns whether popup is visible
- **Event handling**: Enter commits, Escape cancels, blur with 150ms timeout commits, focus cancels pending blur

### 2. Modify `annotation-plugin.ts` -- Node schema

**Update `AnnotationAttrs` interface** (lines 17-20):
- Add `text: string` field so all `node.attrs as AnnotationAttrs` casts include the text

**Remark plugin** (`remarkAnnotationPlugin`):
- Add text to `node.data`: `node.data = { annotationType: type, isCompleted, text: text.trim() }`
- Set `node.children = []` (no text children for atomic node)
- Must preserve existing `annotationType` and `isCompleted` in `node.data` alongside new `text`

**Node definition** (`annotationNode`):
- Remove `content: 'text*'`
- Add `atom: true`
- Add `attrs.text: { default: '' }`
- **`parseDOM`**: Remove `contentElement: '.ff-annotation-text'`, read text from `dataset.text`
- **`toDOM`**: Replace content hole (`0`) with static text span showing text preview
- **`parseMarkdown.runner`**: Use `state.addNode(type, { type: node.data.annotationType, isCompleted: node.data.isCompleted, text: node.data.text })` instead of `openNode/next/closeNode`
- **`toMarkdown.runner`**: Read `node.attrs.text` instead of `node.textContent`

### 3. Modify `annotation-plugin.ts` -- NodeView

Rewrite to be fully non-editable:
- **Remove** `contentDOM`, `ignoreMutation` logic, `updateSourceModeDisplay` helper
- **Marker span**: Keep task completion click toggle (unchanged)
- **Text span**: Non-editable, shows text preview. Keep `dom.dataset.text` in sync with `attrs.text` in `update()` (required for copy/paste -- `parseDOM` reads `dataset.text`)
- **Click handler on `dom`**: Call `showAnnotationEditPopup(pos, view, node.attrs)` (skip if click was on marker for task toggle)
- **Source mode**: Same pattern -- show raw `<!-- ::type:: content -->` syntax, read from `attrs.text`
- **`update()`**: Return false on source mode change (force recreation). Otherwise update attrs, text span, and `dom.dataset.text`
- **`ignoreMutation`**: Always return `true` (atom node)

### 4. Simplify `annotation-display-plugin.ts`

- Remove cursor-inside detection block (lines 85-95): no cursor can be inside atomic nodes
- Remove all three `if (!isCursorInside)` guard wrappers (lines 111, 122, 133)
- Remove `selection` destructuring (no longer needed)
- Change `node.textContent` to `node.attrs.text` in all three decoration attribute objects (lines 115, 126, 137)

### 5. Update `api-annotations.ts`

- **`getAnnotations()`**: Change `node.textContent` (line 54) to `node.attrs.text`
- **`insertAnnotation(type)`**: Create node with `{ type, isCompleted: false, text: '' }`, insert, then call `showAnnotationEditPopup(from, view, attrs)` using the pre-dispatch position

### 6. Update `slash-commands.ts`

- Import `showAnnotationEditPopup` from `annotation-edit-popup.ts`
- In annotation insertion block (lines 212-231): Create atom node, delete slash text, insert node
- Place cursor after the atom: `tr.setSelection(Selection.near(tr.doc.resolve(cmdStart + node.nodeSize)))` instead of `cmdStart + 1`
- After dispatch, call `showAnnotationEditPopup(cmdStart, view, attrs)` to open popup
- Do NOT set `pendingSlashUndo` after popup-based insertion (the popup edit is a separate user action)

### 7. Update `block-sync-plugin.ts`

- `serializeInlineContent()` line 109: Change `child.textContent` to `child.attrs.text`
- This is critical -- without this change, block-level sync will see all annotations as empty text

### 8. Update `styles.css`

- `.ff-annotation`: Add `cursor: pointer`
- `.ff-annotation-text`: Remove `outline: none`, `min-width: 1em` (no longer editable)
- `.ff-annotation-text:empty::before`: Update placeholder to "..." or keep as subtle indicator
- Add popup styles if any theme-specific overrides are needed (most styling is inline in JS)

## Behavioral Changes to Be Aware Of

These are expected changes from switching to atom nodes:

- **Arrow keys**: Left/right arrows skip over annotation as a single unit (one keypress). Previously cursor could enter the annotation text.
- **Backspace/Delete**: Pressing Backspace when cursor is immediately after an annotation selects it (blue highlight). A second Backspace deletes it. Previously Backspace deleted the last character of annotation text.
- **Selection**: Selecting text that spans an annotation selects it as a whole unit.
- **Copy/paste**: Copying an annotation and pasting produces `<!-- ::type:: text -->` via the toMarkdown serializer. `parseDOM` reconstructs the atom from the pasted HTML using `dataset.text`.

## Verification

1. **Build**: `cd web && pnpm build` -- should compile without errors
2. **Existing annotations load**: Open a document with existing annotations -- they should render as marker + text preview
3. **Click to edit**: Click an annotation -- popup opens with text, type indicator, and (for tasks) checkbox
4. **Enter commits**: Type new text, press Enter -- annotation updates inline
5. **Escape cancels**: Press Escape -- popup closes without changes
6. **Slash commands**: Type `/task`, `/comment`, `/reference` -- annotation inserts and popup opens immediately
7. **Task toggle**: Click the marker on a task annotation -- toggles completion without opening popup
8. **Display modes**: Test inline, collapsed, hidden modes -- all work without cursor-inside logic
9. **Collapsed tooltip**: Hover over a collapsed annotation -- tooltip shows annotation text
10. **Source mode**: Toggle to source mode -- annotations show raw HTML comment syntax
11. **Serialization roundtrip**: Edit content, switch to source mode, verify `<!-- ::type:: text -->` format is correct
12. **Swift sync**: Verify annotation panel updates when annotations are edited via popup
13. **Copy/paste**: Copy text containing annotations, paste elsewhere -- annotations should be preserved
14. **Undo**: Edit annotation text via popup, then Cmd+Z -- annotation reverts to previous text
15. **Multiple annotations**: Test two annotations on the same line -- clicking one opens its popup correctly
16. **Standalone annotation**: Test a paragraph containing only an annotation and no other text
17. **Spellcheck**: Verify spellcheck doesn't break around annotation atoms
