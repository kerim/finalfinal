# Annotation Edit Popup: UI Improvements

## Context

The initial annotation popup (commit 98c78be) is functional but has two UX problems:

1. **Text input is single-line** — A cramped `<input type="text">` doesn't give enough room for annotation text. Users need a multi-line textarea with at least 3 visible lines.
2. **Task checkbox is confusing** — The popup shows a ☐ marker icon in the type row AND a separate "Completed" checkbox below it. The ☐ looks like it should be clickable but isn't; the actual checkbox is a separate native element. Users expect the box icon to be the toggle.

## File to Modify

`web/milkdown/src/annotation-edit-popup.ts` — all changes are in this one file.

## Changes

### 1. Replace `<input type="text">` with `<textarea>`

**Current** (line 92-106): `<input type="text">` single-line input.

**New**: `<textarea>` with these properties:
- `rows="3"` — 3 visible lines by default
- `resize: vertical` — user can drag to make taller, not wider
- `max-height: 150px` — prevent excessive growth
- `overflow-y: auto` — scroll when content exceeds max-height
- Same font, padding, border, colors as current input
- `spellcheck: true` (already set)

**Keyboard handling** (line 126-134):
- `Enter` (no modifier) → `commitAnnotationEdit()` (same as now)
- `Shift+Enter` → insert newline (allow default behavior, do NOT call commit)
- `Escape` → `cancelAnnotationEdit()` (same as now)

```typescript
textarea.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    commitAnnotationEdit();
  } else if (e.key === 'Escape') {
    e.preventDefault();
    cancelAnnotationEdit();
  }
  // Shift+Enter falls through — default textarea newline behavior
});
```

**Hint text**: Update from `"Enter to save • Escape to cancel"` to `"Enter to save • Shift+Enter for new line • Escape to cancel"`

**Note**: Newlines in the text attr are already normalized to spaces by `toMarkdown` (annotation-plugin.ts line 182-185), so multi-line input is safe — it gives a comfortable editing area but serializes cleanly.

**Module-level type change**: `editPopupInput` changes from `HTMLInputElement | null` to `HTMLTextAreaElement | null`.

### 2. Merge task checkbox into type icon

**Current layout** (tasks):
```
☐ Task              ← type row (icon not clickable)
○ Completed          ← separate checkbox row (ugly, confusing)
[text input]
```

**New layout** (tasks):
```
☐ Task              ← icon IS the checkbox, clickable with hover effect
[textarea]
```

**New layout** (comment/reference — unchanged concept):
```
◇ Comment           ← static icon, not clickable
[textarea]
```

**Implementation**:

- **Remove** the separate checkbox row (`checkboxRow`, `checkbox`, `checkboxLabel` elements) and its module-level refs (`editPopupCheckbox`, `editPopupCheckboxRow`)
- **Add completion state** to the module: `let editPopupCompleted = false`
- **Make type icon clickable for tasks**: Add click handler on the type icon span that toggles `editPopupCompleted` and updates the icon between ☐/☑
- **Hover effect on task icon**: CSS transition on the icon span when the annotation type is task:
  - `cursor: pointer` (only for tasks)
  - On hover: `transform: scale(1.2)` with `transition: transform 0.15s ease`
  - Brief "pop" feel to signal interactivity
- **`showAnnotationEditPopup()`**: Set `editPopupCompleted = attrs.isCompleted`, update icon accordingly
- **`commitAnnotationEdit()`**: Read `editPopupCompleted` instead of `editPopupCheckbox?.checked`

**Type icon click handler**:
```typescript
typeIcon.addEventListener('click', () => {
  if (currentEditType !== 'task') return;
  editPopupCompleted = !editPopupCompleted;
  typeIcon.textContent = editPopupCompleted ? completedTaskMarker : annotationMarkers.task;
});
```

Need a module-level `let currentEditType: AnnotationType = 'comment'` to track which type is being edited, set in `showAnnotationEditPopup()`.

## Verification

1. **Build**: `cd web && pnpm build` — no errors
2. **Textarea**: Click an annotation — popup shows 3-line textarea, not single-line input
3. **Enter saves**: Press Enter in textarea — popup closes, text saved
4. **Shift+Enter**: Press Shift+Enter — newline inserted in textarea (not saved)
5. **Resize**: Drag textarea bottom edge — resizes vertically only
6. **Task checkbox icon**: Click ☐ icon on a task popup — toggles to ☑, saves with `isCompleted: true`
7. **Icon hover**: Hover over ☐ on task popup — icon scales up slightly
8. **Non-task popups**: Comment/reference popups show static icon, no hover effect, no click behavior
9. **Escape cancels**: Press Escape — popup closes, no changes
10. **Blur commits**: Click outside popup — auto-saves after 150ms delay
11. **Existing text preserved**: Edit a task, toggle completion, save — both text and completion state persist
