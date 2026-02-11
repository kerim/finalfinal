# CodeMirror Patterns

Patterns for CodeMirror 6 editor integration. Consult before writing related code.

---

## ATX Headings Require # at Column 0

**Problem:** Heading styling (font-size, font-weight) worked for some headings but not others. `## sub header` on its own line was styled correctly, but `# header 1` on the same line as a section anchor was not.

**Root Cause:** The Lezer markdown parser strictly follows the CommonMark spec: ATX headings must have `#` at column 0 (start of line). When section anchors precede headings:

```markdown
<!-- @sid:UUID --># header 1
```

The `#` is at column 22 (after the anchor comment), so the parser produces:
- `CommentBlock` (the anchor)
- `Paragraph` (the "# header 1" text, NOT an ATXHeading)

Meanwhile, a heading on its own line:
```markdown
## sub header
```

Has `#` at column 0, so the parser produces:
- `ATXHeading2`

**Evidence from syntax tree inspection:**
```
Document content: "<!-- @sid:... --># header 1\n\n## sub header"
Nodes found: ["Document", "CommentBlock", "Paragraph", "ATXHeading2"]
                                          ^^^^^^^^^^^ NOT ATXHeading1!
```

**Solution:** Add a regex fallback pass in the heading decoration plugin. After the syntax tree pass, scan for lines matching the anchor+heading pattern:

```typescript
buildDecorations(view: EditorView): DecorationSet {
  const decorations: { pos: number; level: number }[] = [];
  const decoratedLines = new Set<number>();

  // First pass: Syntax tree (standard headings at column 0)
  for (const { from, to } of view.visibleRanges) {
    syntaxTree(view.state).iterate({
      enter: (node) => {
        const match = node.name.match(/^ATXHeading(\d)$/);
        if (match) {
          const line = doc.lineAt(node.from);
          decoratedLines.add(line.number);
          decorations.push({ pos: line.from, level: parseInt(match[1]) });
        }
      },
    });
  }

  // Second pass: Regex fallback for headings after anchors
  const anchorHeadingRegex = /^<!--\s*@sid:[^>]+-->(#{1,6})\s/;
  for (let lineNum = startLine; lineNum <= endLine; lineNum++) {
    if (decoratedLines.has(lineNum)) continue;
    const match = line.text.match(anchorHeadingRegex);
    if (match) {
      decorations.push({ pos: line.from, level: match[1].length });
    }
  }

  // Sort and build (RangeSetBuilder requires sorted order)
  decorations.sort((a, b) => a.pos - b.pos);
  // ... build from sorted decorations
}
```

**Alternative solutions considered:**
- Move anchors to end of heading line -- requires content migration
- Put anchors on their own line -- changes document structure
- Custom Lezer grammar -- complex, affects all markdown parsing

**General principle:** When using syntax-aware decorations that depend on line-start patterns, add a fallback for cases where prefixed metadata breaks the pattern. Check what nodes the parser actually produces vs. what you expect.

---

## Keymap Intercepts Events Before DOM Handlers

**Problem:** Custom undo behavior in `EditorView.domEventHandlers({ keydown })` never executed because the handler never fired.

**Root Cause:** CodeMirror's `historyKeymap` binds `Mod-z` and intercepts the event before DOM handlers run:

1. User presses Cmd+Z
2. `historyKeymap` matches `Mod-z` -> calls built-in `undo()` -> returns `true` (handled)
3. Event is consumed; `domEventHandlers.keydown` **never fires**

**Wrong approach (DOM handler):**
```typescript
EditorView.domEventHandlers({
  keydown(event, view) {
    if (event.key === 'z' && event.metaKey) {
      // This never runs! historyKeymap already handled the event
      customUndo(view);
      return true;
    }
    return false;
  }
})
```

**Right approach (custom keymap):**
```typescript
keymap.of([
  ...defaultKeymap.filter(k => k.key !== 'Mod-/'),
  // Custom undo replaces historyKeymap's Mod-z binding
  {
    key: 'Mod-z',
    run: (view) => {
      if (needsCustomBehavior) {
        customUndo(view);
        return true;
      }
      return undo(view);  // Fallback to normal undo
    }
  },
  { key: 'Mod-Shift-z', run: (view) => redo(view) },
  { key: 'Mod-y', run: (view) => redo(view) },
  // ... other bindings
])
```

**Key insight:** Don't include `...historyKeymap` when you need to override undo/redo behavior. Define your own `Mod-z`, `Mod-Shift-z`, and `Mod-y` bindings explicitly.

**General principle:** To intercept keyboard shortcuts in CodeMirror, replace the keymap binding, not the DOM handler. Keymap handlers run first.
