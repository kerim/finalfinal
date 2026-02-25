# Data Model

Database schema and project package structure.

---

## Project Model

### Package Structure

Each project is a macOS package (folder appearing as file):

```
MyBook.ff/
+-- content.sqlite        # SQLite database (GRDB)
+-- references/           # Reference files (Phase 6+)
    +-- (user-organized folders)
```

**Benefits:**
- Portable: backup/share as single "file"
- Sync-friendly: package or just SQLite
- Finder shows as file, "Show Package Contents" reveals internals
- Standard macOS pattern (like Scrivener, Final Draft)

---

## Core Tables (GRDB)

```sql
-- Project metadata
CREATE TABLE project (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

-- Block-based content (one row per structural element)
CREATE TABLE block (
    id TEXT PRIMARY KEY,
    projectId TEXT NOT NULL REFERENCES project(id),
    parentId TEXT,                -- For nested blocks (list items in lists)
    sortOrder DOUBLE NOT NULL,   -- Fractional for easy insertion
    blockType TEXT NOT NULL,     -- paragraph, heading, bulletList, orderedList,
                                 -- listItem, blockquote, codeBlock, horizontalRule,
                                 -- sectionBreak, bibliography, table, image
    textContent TEXT NOT NULL,   -- Plain text (search, word count)
    markdownFragment TEXT NOT NULL, -- Original markdown for this block
    headingLevel INTEGER,        -- 1-6 for headings, NULL otherwise
    status TEXT,                 -- draft, review, final, cut (headings only)
    tags TEXT,                   -- JSON array string
    wordGoal INTEGER,
    goalType TEXT DEFAULT 'approx',
    aggregateGoal INTEGER,
    aggregateGoalType TEXT NOT NULL DEFAULT 'approx',
    wordCount INTEGER DEFAULT 0,
    isBibliography BOOLEAN DEFAULT FALSE,
    isPseudoSection BOOLEAN DEFAULT FALSE,
    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL
);

-- Full markdown content (one row per project, kept in sync)
CREATE TABLE content (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL REFERENCES project(id),
    markdown TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

-- Legacy section table (dual-write for backward compatibility)
-- Also has aggregateGoal and aggregateGoalType columns (v11 migration)
CREATE TABLE section (
    -- ... (same as before, populated by persistReorderedBlocks_legacySections)
);

-- User preferences per project
CREATE TABLE settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
```

## Content Model

One project = many blocks, ordered by `sortOrder`. Headers within the block sequence define the outline structure. The `content` table stores the assembled markdown string and is kept in sync.

```markdown
# Book Title          -> block(type=heading, level=1, sortOrder=1.0)
                      -> block(type=paragraph, sortOrder=2.0)
## Chapter 1          -> block(type=heading, level=2, sortOrder=3.0)
Content here...       -> block(type=paragraph, sortOrder=4.0)
```

The `block` table is the primary content store. `observeOutlineBlocks()` filters to heading + pseudo-section blocks for fast sidebar rendering. Word counts are calculated at two scopes: `sectionOnlyWordCount(blockId:)` counts content from a heading to the next heading of any level (own content only), while `wordCountForHeading(blockId:)` counts to the next same-or-higher-level heading (including descendants). See [word-count.md](word-count.md) for details.
