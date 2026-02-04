# Block-Based Architecture with Dual-Appearance ProseMirror

## Decision

Refactor from the current fragile architecture to a **block-based data model** with a **single ProseMirror editor** that supports dual-appearance mode (WYSIWYG and source-like view).

**Key changes:**
1. Replace single markdown blob with discrete blocks (paragraphs, headings, etc.) with stable UUIDs
2. Remove CodeMirror entirely - use Milkdown/ProseMirror for both modes
3. Annotations attach to block IDs, not character offsets
4. Mode switching is CSS + decorations, not serialization/parsing

---

## Problem Summary

Current fragility stems from:
- Position-based annotation offsets drift when content changes
- Two editors (Milkdown + CodeMirror) require markdown round-trips that lose structure
- Three independent sync services (Section, Annotation, Bibliography) race with each other
- Bibliography can duplicate, annotations can misplace, section breaks get confused

---

## New Database Schema

### Block Table

```sql
CREATE TABLE block (
    id TEXT PRIMARY KEY,
    projectId TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    parentId TEXT REFERENCES block(id) ON DELETE CASCADE,
    sortOrder REAL NOT NULL,  -- Fractional for easy insertion
    blockType TEXT NOT NULL,  -- 'paragraph', 'heading', 'bullet_list', etc.

    textContent TEXT NOT NULL DEFAULT '',
    markdownFragment TEXT NOT NULL DEFAULT '',
    headingLevel INTEGER,  -- 1-6 for headings

    -- Section metadata (for heading blocks)
    status TEXT DEFAULT 'next',
    tags TEXT DEFAULT '[]',
    wordGoal INTEGER,
    wordCount INTEGER DEFAULT 0,

    isBibliography BOOLEAN DEFAULT FALSE,
    isPseudoSection BOOLEAN DEFAULT FALSE,

    createdAt DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updatedAt DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
```

### Updated Annotation Table

```sql
CREATE TABLE annotation_v2 (
    id TEXT PRIMARY KEY,
    contentId TEXT NOT NULL REFERENCES content(id) ON DELETE CASCADE,
    blockId TEXT NOT NULL REFERENCES block(id) ON DELETE CASCADE,
    type TEXT NOT NULL,  -- 'task', 'comment', 'reference'
    text TEXT NOT NULL,
    isCompleted BOOLEAN DEFAULT FALSE,
    inlineStartOffset INTEGER,  -- Position within block (local, not global)
    inlineEndOffset INTEGER,
    createdAt DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updatedAt DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
```

---

## ProseMirror Changes

### Block ID Attribute

Add `blockId` attribute to all block-level nodes:

```typescript
// All block nodes get this attribute
attrs: {
  blockId: { default: null }  // UUID from database
}

// Rendered as data attribute
toDOM: (node) => ['p', { 'data-block-id': node.attrs.blockId }, 0]
```

### Dual-Appearance Mode

**WYSIWYG mode (default):**
- Formatted text, markdown syntax hidden
- Current Milkdown behavior

**Source mode:**
- Same document structure
- Decorations add visible syntax (`#`, `**`, etc.)
- Monospace font via CSS class

```typescript
// Plugin adds decorations when source mode enabled
if (sourceModeEnabled && node.type.name === 'heading') {
  decorations.push(Decoration.widget(pos + 1, () => {
    const span = document.createElement('span');
    span.textContent = '#'.repeat(node.attrs.level) + ' ';
    return span;
  }, { side: -1 }));
}
```

Mode toggle is CSS + redecoration, not document serialization.

---

## Swift-JS Bridge

### New Block API

```typescript
interface window.FinalFinal {
  // Block operations (replaces getContent/setContent)
  getBlockChanges(): {
    updates: BlockUpdate[];
    inserts: BlockInsert[];
    deletes: string[];  // block IDs
  };

  applyBlocks(blocks: Block[]): void;

  // Mode toggle (replaces editor switch)
  setEditorMode(mode: 'wysiwyg' | 'source'): void;

  // Navigation
  scrollToBlock(blockId: string): void;
  getBlockAtCursor(): { blockId: string; offset: number };
}
```

### BlockSyncService (replaces 3 services)

Single service handles all sync:
- Polls for block changes every 300ms
- Applies updates/inserts/deletes in single transaction
- Bibliography is just another block (type: 'bibliography', singleton)

---

## Implementation Phases

### Phase A: Database Foundation (Week 1)

1. Create Block model in Swift (`Models/Block.swift`)
2. Add migration v8 with block table
3. Create BlockParser to convert markdown → blocks
4. Add block CRUD to ProjectDatabase

**Files:**
- `Models/Block.swift` (new)
- `Models/Database.swift` (add migration)
- `Models/ProjectDatabase.swift` (add block operations)
- `Services/BlockParser.swift` (new)

### Phase B: ProseMirror Schema (Week 2)

1. Add blockId to all node specs
2. Implement change tracking in transactions
3. Create block API on window.FinalFinal
4. Test block round-trip Swift ↔ JS

**Files:**
- `web/milkdown/src/block-id-plugin.ts` (new)
- `web/milkdown/src/block-schema.ts` (new)
- `web/milkdown/src/main.ts` (update API)

### Phase C: Dual-Appearance Mode (Week 3)

1. Create source-mode decoration plugin
2. Add CSS for mode switching
3. Implement setEditorMode API
4. Remove CodeMirror editor switch logic

**Files:**
- `web/milkdown/src/source-mode-plugin.ts` (new)
- `web/milkdown/src/styles.css` (add source mode styles)
- `Editors/MilkdownEditor.swift` (update mode handling)

### Phase D: Block Sync Service (Week 4)

1. Create BlockSyncService
2. Wire Swift-JS block operations
3. Update sidebar to use block IDs
4. Bibliography as block

**Files:**
- `Services/BlockSyncService.swift` (new)
- `ViewState/EditorViewState.swift` (use BlockSyncService)
- `Views/Sidebar/OutlineSidebar.swift` (use blocks)

### Phase E: Migration & Cleanup (Week 5-6)

1. Implement document migration (markdown → blocks)
2. Migrate annotation offsets to block-relative
3. Remove CodeMirror entirely
4. Remove legacy sync services
5. Extensive testing

**Files to remove:**
- `Editors/CodeMirrorEditor.swift`
- `web/codemirror/` (entire directory)
- `Services/SectionSyncService.swift`
- `Services/AnnotationSyncService.swift`

---

## Critical Files

| File | Action |
|------|--------|
| `Models/Block.swift` | Create - new block model |
| `Models/Database.swift` | Modify - add migration v8 |
| `Services/BlockSyncService.swift` | Create - unified sync |
| `Services/BlockParser.swift` | Create - markdown → blocks |
| `web/milkdown/src/block-id-plugin.ts` | Create - block ID tracking |
| `web/milkdown/src/source-mode-plugin.ts` | Create - dual appearance |
| `Editors/MilkdownEditor.swift` | Modify - block API, mode toggle |
| `Editors/CodeMirrorEditor.swift` | Delete |

---

## Verification

### Phase A Verification
- [ ] Can create/read/update/delete blocks in database
- [ ] BlockParser correctly parses sample markdown
- [ ] Blocks preserve section metadata (status, tags, goals)

### Phase B Verification
- [ ] ProseMirror nodes have blockId attributes
- [ ] Changes to blocks detected via transactions
- [ ] Block IDs survive edits (except split/join which create new blocks)

### Phase C Verification
- [ ] Cmd+/ toggles between WYSIWYG and source appearance
- [ ] Same document structure in both modes (no parsing)
- [ ] Cursor position preserved on mode switch
- [ ] Markdown syntax visible in source mode

### Phase D Verification
- [ ] Block changes sync to database within 500ms
- [ ] Sidebar reflects block changes
- [ ] Bibliography block is singleton (cannot duplicate)
- [ ] Section reorder updates block sortOrder only

### Final Verification (all original problems solved)
- [ ] Bibliography never duplicates or misplaces
- [ ] Annotations stay attached after edits elsewhere in document
- [ ] Section breaks maintain correct position
- [ ] Zoom works with block IDs (no offset reconstruction)
- [ ] Header level changes propagate to descendants correctly

---

## Block Split Behavior

When a user splits a paragraph (presses Enter in the middle):

1. **First segment keeps original block ID** - preserves section metadata, external references
2. **Second segment gets new block ID** - treated as a newly created block
3. **Annotations move with content** - if an annotation was at offset 55 and the split happens at position 50, the annotation moves to the new block with recalculated offset 5

This matches user mental model: the original block remains, a new block is created from the split-off portion.

---

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Source mode decorations complex for nested formatting | Start with heading/paragraph/lists, add complex nodes incrementally |
| Block IDs lost on split/join | First segment keeps original ID, second gets new ID |
| Performance with many blocks | Batch operations, coalesce rapid edits, fractional sortOrder |
| Annotation migration from offsets | Parse with context, store relative offset within block |
| Bibliography edits conflict with auto-update | Mark user-edited bibliography, stop auto-updates |

---

## Research Sources

- [Notion's Block-Based Data Model](https://www.notion.com/blog/data-model-behind-notion)
- [ProseMirror Guide](https://prosemirror.net/docs/guide/)
- [Peritext CRDT for Rich Text](https://www.inkandswitch.com/peritext/)
- [Medium: ProseMirror Markdown Editor](https://medium.com/@dan-niles/building-a-markdown-editor-with-prosemirror-react)
