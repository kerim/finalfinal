# Phase 1.6 Completion Plan: Outline Sidebar

## Summary

Complete the outline sidebar with bidirectional sync, single-click scroll, level-aware drag-drop, slash commands, and word count interactions.

---

## Design Decisions (from brainstorming)

| Decision | Choice |
|----------|--------|
| Sync priority | Both directions simultaneously |
| Scroll position | Store `startOffset` during parse (Elegant) |
| Document rebuild | Concatenate sections in sortOrder |
| Pseudo-section creation | Menu + keyboard + `/break` slash command |
| Slash command UI | Editor-native autocomplete (Milkdown/CodeMirror) |
| Drag-drop levels | Horizontal zones - drop line margin indicates level |
| Children on move | Move with parent as subtree |
| Word count | Single-click toggles aggregate/individual, double-click sets goal |
| Status filter | Flat list (no hierarchy preservation) |

---

## Implementation Steps

### Step 1: Add `startOffset` Field to Section Model

**Files:**
- `Models/Section.swift` — Add `startOffset: Int` field
- `Models/ProjectDatabase.swift` — Add migration v3
- `Services/SectionSyncService.swift` — Store offset during parse (already calculates it)
- `ViewState/EditorViewState.swift` — Add to SectionViewModel

**Migration:**
```sql
ALTER TABLE section ADD COLUMN startOffset INTEGER NOT NULL DEFAULT 0;
```

**Verification:** After parsing, print offsets to verify alignment with header positions.

---

### Step 2: Single-Click Scroll to Section

**Files:**
- `Views/ContentView.swift` — Fix `scrollToSection()` to use `startOffset`
- `Editors/MilkdownEditor.swift` — Call JS when scrollOffset changes
- `Editors/CodeMirrorEditor.swift` — Same

**Flow:**
1. User clicks section card
2. `onScrollToSection` callback fires with sectionId
3. Look up section's `startOffset`
4. Call `webView.evaluateJavaScript("window.FinalFinal.scrollToOffset(\(offset))")`

**Verification:** Click section card → editor scrolls to that header in both modes.

---

### Step 3: Sections → Document Sync

**Files:**
- `Services/SectionSyncService.swift` — Add `rebuildDocument(from:)` method
- `Views/ContentView.swift` — After reorder, rebuild and update `editorState.content`

**rebuildDocument:**
```swift
func rebuildDocument(from sections: [Section]) -> String {
    sections
        .sorted { $0.sortOrder < $1.sortOrder }
        .map { $0.markdownContent }
        .joined()  // Content already includes trailing newlines
}
```

**Header level changes:** When a section's level changes during drag, update the header prefix in `markdownContent`:
```swift
func updateHeaderLevel(in markdown: String, to newLevel: Int) -> String {
    // Replace first line's # count
}
```

**Verification:** Drag section A below section B → document reflects new order.

---

### Step 4: Drag-Drop with Level Changes

**Files:**
- `Views/Sidebar/OutlineSidebar.swift` — Modify `SectionDropDelegate` and `DropIndicatorLine`

**Horizontal zones:**
- Track `info.location.x` in `dropUpdated()`
- Calculate target level from horizontal position (20px per indent level)
- Update `DropPosition` enum to include `level: Int`

**Drop indicator:**
```swift
struct DropIndicatorLine: View {
    let level: Int

    var body: some View {
        Rectangle()
            .fill(accentColor)
            .frame(height: 3)
            .padding(.leading, CGFloat(level - 1) * 20 + 12)
    }
}
```

**Subtree movement:**
- When parent moves, calculate `levelDelta = newLevel - oldLevel`
- Apply delta to all descendants
- Maintain relative sortOrder within subtree

**Verification:**
- Drag to left edge → drop line at level 1
- Drag to right → drop line indents
- Children follow parent

---

### Step 5: `/break` Slash Command

**Files:**
- `web/milkdown/src/main.ts` — Add Milkdown slash plugin
- `web/codemirror/src/main.ts` — Add CodeMirror autocomplete
- `App/MainMenu.swift` or equivalent — Add menu item
- Both editors — Add `insertAtCursor(text)` to window.FinalFinal API

**Milkdown:**
```typescript
import { slashFactory } from '@milkdown/plugin-slash';

const slashPlugin = slash.configure({
    items: [{
        name: 'Break',
        keyword: 'break',
        onSelect: (ctx) => {
            // Insert <!-- ::break:: --> at cursor
        }
    }]
});
```

**CodeMirror:**
```typescript
function slashCompletions(context: CompletionContext) {
    const word = context.matchBefore(/\/\w*/);
    if (!word) return null;
    return {
        from: word.from,
        options: [{
            label: '/break',
            apply: '<!-- ::break:: -->\n\n'
        }]
    };
}
```

**Keyboard shortcut:** Cmd+Shift+Enter via menu or `.keyboardShortcut()`

**Verification:**
- Type `/` → dropdown shows `/break`
- Select → marker inserted
- Cmd+Shift+Enter → marker inserted
- Sidebar shows § section after parse

---

### Step 6: Word Count Interactions

**Files:**
- `Views/Sidebar/SectionCardView.swift` — Add tap gestures to word count

**State:**
```swift
@State private var showAggregateWordCount: Bool = false
```

**Gestures:**
- `.onTapGesture(count: 1)` → toggle `showAggregateWordCount`
- `.onTapGesture(count: 2)` → show `GoalPopover`

**Display:**
- Individual: `"450"` or `"450/500"` if goal set
- Aggregate: `"Σ 1,234"` (sum of section + descendants)

**Verification:**
- Single-click toggles display mode
- Double-click opens goal editor
- Goal persists after edit

---

### Step 7: Verify Status Filter

**Files:** `Views/Sidebar/OutlineSidebar.swift` (already implemented)

Current implementation filters to flat list. Just verify behavior matches spec.

**Verification:** Select status filter → only matching sections shown, no hierarchy.

---

## Implementation Order

```
1. startOffset field    ──┐
                          ├──► 2. scroll to section
                          │
3. sections→document ─────┼──► 4. drag-drop levels
                          │
5. slash command ─────────┤
                          │
6. word count ────────────┤
                          │
7. verify filter ─────────┘
```

Steps 1→2 and 3→4 are sequential. Steps 5, 6, 7 are independent.

---

## Data Model Changes

| Change | Location | Details |
|--------|----------|---------|
| Add `startOffset: Int` | Section.swift | Character offset where section begins |
| Migration v3 | ProjectDatabase.swift | `ALTER TABLE section ADD COLUMN startOffset` |

---

## Web API Additions

| Method | Purpose |
|--------|---------|
| `insertAtCursor(text)` | Insert text at current cursor position |

Existing: `scrollToOffset(offset)` — already implemented.

---

## Files to Modify

| File | Changes |
|------|---------|
| `Models/Section.swift` | Add startOffset field |
| `Models/ProjectDatabase.swift` | Add migration v3 |
| `Services/SectionSyncService.swift` | Store startOffset, add rebuildDocument() |
| `Views/Sidebar/OutlineSidebar.swift` | Horizontal drop zones, level indicators |
| `Views/Sidebar/SectionCardView.swift` | Word count tap gestures |
| `Views/ContentView.swift` | Wire up scroll, wire up document rebuild |
| `Editors/MilkdownEditor.swift` | scrollToOffset binding |
| `Editors/CodeMirrorEditor.swift` | scrollToOffset binding |
| `web/milkdown/src/main.ts` | Slash command plugin, insertAtCursor |
| `web/codemirror/src/main.ts` | Slash autocomplete, insertAtCursor |

---

## Verification Checklist

- [ ] Section model has startOffset, populated during parse
- [ ] Single-click scrolls editor to section
- [ ] Sidebar drag updates document content
- [ ] Horizontal drag position determines target level
- [ ] Drop indicator shows target level via margin
- [ ] Children move with parent
- [ ] `/break` slash command works in both editors
- [ ] Cmd+Shift+Enter inserts break
- [ ] Word count single-click toggles aggregate/individual
- [ ] Word count double-click opens goal editor
- [ ] Status filter shows flat list

---

## Phase 1.6b (Deferred)

For future reference, these features were scoped for Phase 1.6b:

### Tag Filter
- Add tag filter alongside status filter
- Multi-select tags (OR logic)
- Flat list behavior matching status filter

### Tag Suggestions/Autocomplete
- When editing tags in sidebar, show suggestions from existing tags
- Autocomplete from project's tag vocabulary

### Keyboard Navigation in Sidebar
- Arrow keys to move selection
- Enter to scroll/zoom
- Delete to remove section (with confirmation)
- Tab/Shift+Tab to change level

### Undo/Redo for Drag Operations
- Track drag operations in undo stack
- Cmd+Z reverts last drag
- Consider whether editor undo captures section reorders adequately first
