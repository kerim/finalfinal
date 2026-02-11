# Lessons Learned

Technical patterns and pitfalls. Consult before writing new code.

---

## ProseMirror / Milkdown

### Use Decoration System, Not DOM Manipulation

Direct DOM manipulation breaks ProseMirror's reconciliation. Use `Decoration` system:

```typescript
// Wrong
document.querySelectorAll('.paragraph').forEach(el => el.classList.add('dimmed'));

// Right
const decorations = DecorationSet.create(doc, [
  Decoration.node(from, to, { class: 'dimmed' })
]);
```

### Decoration.node() Creates Wrapper Elements

**Problem:** CSS tooltip using `::after` with `content: attr(data-text)` showed "t" instead of the annotation text, even though the NodeView had the correct `data-text` attribute.

**Root Cause:** `Decoration.node()` creates a **wrapper element** around the NodeView DOM. The wrapper receives the decoration's attributes (like `class`), but NOT the attributes on the inner NodeView element.

```html
<!-- DOM structure when Decoration.node() is applied -->
<div class="ff-annotation-collapsed">  <!-- Wrapper: HAS class, NO data-text -->
  <span class="ff-annotation" data-text="actual text">  <!-- NodeView: HAS data-text -->
    ...
  </span>
</div>
```

The CSS `::after` attaches to the wrapper (which has the class), but `attr(data-text)` fails because the wrapper lacks that attribute. The "t" is a rendering artifact from the failed lookup.

**Solution:** Include any attributes needed by CSS selectors in the decoration attributes:

```typescript
// Wrong - only class on wrapper
Decoration.node(pos, pos + node.nodeSize, {
  class: 'ff-annotation-collapsed',
})

// Right - data-text also on wrapper
Decoration.node(pos, pos + node.nodeSize, {
  class: 'ff-annotation-collapsed',
  'data-text': node.textContent,
})
```

**General principle:** When using `Decoration.node()`, any attributes needed by CSS pseudo-elements (`::before`, `::after`) must be explicitly added to the decoration attributes, not just the NodeView.

---

## SwiftUI / WebKit

### AppDelegate.shared Pattern

`NSApp.delegate as? YourAppDelegate` returns `nil` with `@NSApplicationDelegateAdaptor`. Store static reference:

```swift
class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
    }
}
```

### WKWebView Web Inspector

Enable with `webView.isInspectable = true`. Connect via Safari → Develop menu.

---

## JavaScript

### Keyboard Shortcuts with Shift

`e.key` returns uppercase when Shift held. Always normalize:

```typescript
if (e.key.toLowerCase() === 'e') { ... }
```

---

## Cursor Position Mapping (Milkdown ↔ CodeMirror)

### ProseMirror textBetween() Returns Plain Text

`doc.textBetween()` strips all markdown syntax (`**`, `*`, `` ` ``, etc.). Searching for this plain text in markdown source will fail because the markdown contains the syntax characters.

**Wrong approach (text anchor):**
```typescript
const textBefore = doc.textBetween(start, head, '\n');
markdown.indexOf(textBefore); // Fails - textBefore has no syntax
```

**Right approach (line matching + offset mapping):**
1. Match paragraph text content to markdown lines (strip syntax from both sides)
2. Use bidirectional offset mapping that accounts for inline syntax length

### Bidirectional Offset Mapping Required

Converting cursor positions between WYSIWYG and source requires accounting for inline syntax:

| Markdown | Text Length | Markdown Length |
|----------|-------------|-----------------|
| `**bold**` | 4 ("bold") | 8 |
| `*italic*` | 6 ("italic") | 8 |
| `` `code` `` | 4 ("code") | 6 |
| `[link](url)` | 4 ("link") | 12 |

Functions needed:
- `textToMdOffset(mdLine, textOffset)` - ProseMirror → CodeMirror
- `mdToTextOffset(mdLine, mdOffset)` - CodeMirror → ProseMirror

### Line-Start Syntax Must Be Handled Separately

Headers, lists, and blockquotes have line-start syntax that affects column calculation:

```typescript
const syntaxMatch = line.match(/^(#+\s*|\s*[-*+]\s*|\s*\d+\.\s*|\s*>\s*)/);
const syntaxLength = syntaxMatch ? syntaxMatch[0].length : 0;
const contentAfterSyntax = line.slice(syntaxLength);
```

Apply offset mapping only to content after syntax, then add syntax length back.

---

## macOS Event Handling

### Ctrl-Click vs Right-Click Are Different Events

On macOS, ctrl+left-click and physical right-click generate **different event types**:

- **Physical right-click** (two-finger tap, right mouse button) → `.rightMouseDown` event
- **Ctrl+left-click** → `.leftMouseDown` event with `event.modifierFlags.contains(.control) == true`

To handle both as "secondary click", monitor both event types:

```swift
eventMonitor = NSEvent.addLocalMonitorForEvents(
    matching: [.rightMouseDown, .leftMouseDown]
) { event in
    let isRightClick = event.type == .rightMouseDown
    let isCtrlClick = event.type == .leftMouseDown && event.modifierFlags.contains(.control)

    guard isRightClick || isCtrlClick else { return event }
    // Handle secondary click...
    return nil  // Consume event
}
```

SwiftUI's `.onTapGesture` consumes ctrl+click before custom handlers can intercept it, so use `NSEvent.addLocalMonitorForEvents` with event consumption (`return nil`) to prevent click-through.

---

## Performance

### Console Print Statements Cause UI Freezes

**Problem:** During drag-drop reordering, the UI would freeze/stutter noticeably.

**Root Cause:** Print statements scattered throughout the code path were causing synchronous console I/O. Even "small" prints in frequently-called functions compound:

- SectionSyncService printing "[SectionSyncService] Not configured" 11 times per drop
- SectionCardView printing status/level changes on every render
- Editor coordinators printing cursor position debug info during content changes

**Why it matters:**
- `print()` is synchronous - blocks the main thread
- Drag-drop triggers many rapid state updates
- Each update cascades through multiple components with prints
- Console I/O latency (especially with Xcode attached) compounds

**Solution:**
1. Remove all debug prints from hot code paths
2. Wrap essential debug logging in `#if DEBUG` guards
3. For expected conditions (like "not configured" in demo mode), fail silently

**Pattern to avoid:**
```swift
// Bad - prints on every content change
func contentChanged(_ markdown: String) {
    print("[Service] Content changed: \(markdown.prefix(50))...")
    // process...
}
```

**Pattern to use:**
```swift
// Good - only print actual errors in debug builds
func contentChanged(_ markdown: String) {
    #if DEBUG
    if unexpectedCondition {
        print("[Service] Warning: \(reason)")
    }
    #endif
    // process...
}
```

---

## Milkdown Remark Plugins

### HTML Nodes Are Filtered Before Custom Plugins Run

**Problem:** Custom HTML comments like `<!-- ::break:: -->` aren't parsed when loaded via `setContent()`, but work fine when inserted via slash command.

**Root Cause:** Milkdown's commonmark preset includes `filterHTMLPlugin` that removes HTML nodes (including comments) **before** custom remark plugins can transform them.

**Pipeline order:**
```
Markdown → remark-parse → [filterHTMLPlugin removes HTML] → [Your remark plugin] → ProseMirror
```

**Why slash command works:** It creates the ProseMirror node directly, bypassing the parsing pipeline.

**Solution:** Register your remark plugin BEFORE the commonmark preset:

```typescript
// Wrong - plugin runs after HTML is filtered out
Editor.make()
  .use(commonmark)
  .use(sectionBreakPlugin)  // Too late!

// Right - plugin runs before filtering
Editor.make()
  .use(sectionBreakPlugin)  // Intercepts HTML first
  .use(commonmark)
```

Use `unist-util-visit` for proper tree traversal:

```typescript
import { visit } from 'unist-util-visit';

const remarkPlugin = $remark('section-break', () => () => (tree) => {
  visit(tree, 'html', (node: any) => {
    if (node.value?.trim() === '<!-- ::break:: -->') {
      node.type = 'sectionBreak';  // Transform before filtering
      delete node.value;
    }
  });
});
```

**Dependency:** Add `unist-util-visit` to package.json.

---

## Build

### Vite emptyOutDir: false

Changes to source `index.html` won't sync to output. Either manually sync or set `emptyOutDir: true`.

---

## Milkdown SlashProvider

### Dual Visibility Control Causes Menu to Not Reappear

**Problem:** Slash menu shows on first `/` keystroke, command executes, but subsequent `/` keystrokes don't show the menu.

**Root Cause:** Two independent visibility controls fighting each other:

1. **SlashProvider** controls visibility via `data-show` attribute
2. **Custom code** sets `style.display = 'none'` directly

When hiding after command execution:
```typescript
// Problem: sets inline CSS that SlashProvider doesn't clear
slashMenuElement.style.display = 'none';
```

When SlashProvider shows the menu again, it only sets `data-show="true"` — it does NOT clear the inline `style.display`. CSS specificity means `style.display: none` wins.

**Solution:** Use a single visibility mechanism. Rely solely on SlashProvider's `data-show` attribute:

```typescript
// Hide menu - let SlashProvider handle it
if (slashProviderInstance) {
  slashProviderInstance.hide();  // Sets data-show="false"
}
// DON'T set style.display = 'none'
```

Add CSS to enforce the attribute-based visibility:
```css
.slash-menu[data-show="false"] {
  display: none !important;
}
```

**General principle:** When integrating with library-managed UI components, use the library's visibility API exclusively. Mixing direct DOM manipulation with library state causes desync.

---

## SwiftUI Data Flow

### Use IDs Not Indices When Communicating Between Filtered and Full Arrays

**Problem:** Drag-drop reordering worked correctly when viewing all sections, but moved sections to wrong positions when the sidebar was zoomed/filtered to show only a subset.

**Root Cause:** The drop handler calculated an `insertionIndex` based on the **filtered** array (`filteredSections` with 5 items), but the reorder function interpreted that index against the **full** array (`sections` with 17 items).

```swift
// In OutlineSidebar (filtered view):
let insertionIndex = 4  // Position in filteredSections

// In ContentView (full array):
let targetIdx = insertionIndex - 1  // = 3
let target = sections[targetIdx]    // WRONG! Index 3 in full array != index 3 in filtered array
```

**Solution:** Pass the **target section ID** instead of an index. IDs are stable across both arrays:

```swift
// Before (ambiguous)
struct SectionReorderRequest {
    let sectionId: String
    let insertionIndex: Int  // Filtered or full array? Unclear!
}

// After (unambiguous)
struct SectionReorderRequest {
    let sectionId: String
    let targetSectionId: String?  // Insert AFTER this section (nil = beginning)
}
```

The receiver uses `sections.firstIndex(where: { $0.id == targetId })` to find the correct position in its own array.

**General principle:** When passing position information between components that may have different views of the same data (filtered, sorted, paginated), use stable identifiers rather than indices.

---

## CodeMirror

### ATX Headings Require # at Column 0

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
- Move anchors to end of heading line — requires content migration
- Put anchors on their own line — changes document structure
- Custom Lezer grammar — complex, affects all markdown parsing

**General principle:** When using syntax-aware decorations that depend on line-start patterns, add a fallback for cases where prefixed metadata breaks the pattern. Check what nodes the parser actually produces vs. what you expect.

---

### Keymap Intercepts Events Before DOM Handlers

**Problem:** Custom undo behavior in `EditorView.domEventHandlers({ keydown })` never executed because the handler never fired.

**Root Cause:** CodeMirror's `historyKeymap` binds `Mod-z` and intercepts the event before DOM handlers run:

1. User presses Cmd+Z
2. `historyKeymap` matches `Mod-z` → calls built-in `undo()` → returns `true` (handled)
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

---

## Milkdown Empty Content Handling

### Early Return Checks Can Bypass Essential Fixes

**Problem:** Section break symbol (§) appeared when switching from CodeMirror to Milkdown on blank documents, even though empty content handling code existed.

**Root Cause:** The `setContent()` function had this structure:

```typescript
let currentContent = '';  // Initial state

setContent(markdown: string) {
  if (currentContent === markdown) {
    return;  // EARLY RETURN
  }
  // ... later in function ...
  if (!markdown.trim()) {
    // Empty content fix - never reached when both are ''
  }
}
```

When `currentContent = ''` and `setContent('')` is called:
1. Check at line 1: `'' === ''` → **returns early**
2. Empty content fix **never executes**
3. Editor keeps its default state (section_break node from schema)

**Solution:** Handle special cases BEFORE equality optimization checks:

```typescript
setContent(markdown: string) {
  // Handle empty content FIRST
  if (!markdown.trim()) {
    // Fix empty document state
    return;
  }

  // THEN check if content unchanged (for non-empty only)
  if (currentContent === markdown) {
    return;
  }
  // ... rest of parsing
}
```

**General principle:** When a function has both an optimization (skip if unchanged) and a fix for edge cases, ensure the edge case handling runs before the optimization can bypass it.

---

## GRDB ValueObservation

### Race Condition: In-Memory Corrections vs Async Observation Delivery

**Problem:** Hierarchy enforcement corrected section header levels in memory, but the sidebar kept showing the old (uncorrected) levels.

**Root Cause:** ValueObservation delivers database updates asynchronously. When enforcement modified sections in memory:

```
T+0ms:    User types /h1 (H2 -> H1)
T+500ms:  Database updated with new header
T+501ms:  ValueObservation delivers update
T+502ms:  Enforcement corrects sibling H3 -> H2 in MEMORY
T+503ms:  ValueObservation delivers AGAIN (same DB change, async)
T+504ms:  sections = viewModels  // OVERWRITES in-memory corrections!
```

The second observation delivery reverted the in-memory corrections before they could be persisted.

**Solution:** Use a state machine to block observation updates during enforcement:

```swift
// In startObserving() - check state before applying updates
guard contentState == .idle else {
    print("[OBSERVE] SKIPPED due to contentState: \(contentState)")
    continue
}

// In enforcement function - use async with state blocking
@MainActor
private static func enforceHierarchyAsync(editorState: EditorViewState, ...) async {
    editorState.contentState = .hierarchyEnforcement
    defer { editorState.contentState = .idle }

    enforceConstraints(...)
    rebuildContent(...)
    await persistToDatabase(...)  // Wait for completion before clearing state
}
```

**Key elements:**
1. **State machine enum** (`EditorContentState: idle | zoomTransition | hierarchyEnforcement`)
2. **Check state in observation loop** - skip updates when not `.idle`
3. **Use `defer` for cleanup** - guarantees state reset even on errors
4. **Persist before clearing state** - wait for database write to complete
5. **async/await instead of DispatchQueue** - modern, structured concurrency

**General principle:** When in-memory state corrections compete with async observation delivery, block observation updates during the correction window using a state machine, and await persistence completion before re-enabling observation.

---

### Dual Content Properties: Update Both When Mode-Specific

**Problem:** Drag-drop section reorder in the sidebar updated the document correctly in WYSIWYG mode, but the editor didn't update when in Source mode (CodeMirror).

**Root Cause:** The app has two separate content properties for different editor modes:
- `editorState.content` - used by WYSIWYG mode (MilkdownEditor binding)
- `editorState.sourceContent` - used by Source mode (CodeMirrorEditor binding), contains anchor markup

The `rebuildDocumentContent()` function only updated `editorState.content`:

```swift
// rebuildDocumentContent() - ONLY updates content
editorState.content = newContent  // MilkdownEditor sees this

// But CodeMirrorEditor binds to sourceContent:
CodeMirrorEditor(content: $editorState.sourceContent, ...)  // Never updated!
```

When in source mode, the binding to `sourceContent` never changed, so `updateNSView()` was never triggered, and the editor continued showing the old content.

**Solution:** After rebuilding `content`, also update `sourceContent` when in source mode:

```swift
private func finalizeSectionReorder(sections: [SectionViewModel]) {
    editorState.contentState = .dragReorder
    defer { editorState.contentState = .idle }

    // ... recalculate offsets, rebuild content ...
    rebuildDocumentContent()

    // If in source mode, also update sourceContent with anchors
    if editorState.editorMode == .source {
        var adjustedSections: [SectionViewModel] = []
        var adjustedOffset = 0
        for section in editorState.sections.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            adjustedSections.append(section.withUpdates(startOffset: adjustedOffset))
            adjustedOffset += section.markdownContent.count
        }

        let injected = sectionSyncService.injectSectionAnchors(
            markdown: editorState.content,
            sections: adjustedSections
        )
        editorState.sourceContent = injected
    }
}
```

**Why `contentState` is also needed:** Even with `sourceContent` updated, editor polling could race with the update. Setting `contentState = .dragReorder` during the operation suppresses polling, ensuring the editor receives the complete reordered content.

**General principle:** When a view model has multiple properties that serve the same purpose for different contexts (e.g., mode-specific content), ensure all relevant properties are updated when the shared state changes. Track which property each consumer binds to.

---

## GRDB Configuration

### Never Use eraseDatabaseOnSchemaChange in Production

**Problem:** User data was being completely wiped when opening projects. All tables existed with correct schema, but all data rows were empty.

**Root Cause:** GRDB's `DatabaseMigrator` has an `eraseDatabaseOnSchemaChange` option that's useful during development but catastrophic in production:

```swift
// DANGEROUS - destroys all data on ANY schema change
var migrator = DatabaseMigrator()
#if DEBUG
migrator.eraseDatabaseOnSchemaChange = true  // DO NOT USE
#endif
```

When enabled, if GRDB detects any difference between the current schema and migrations, it:
1. Drops ALL tables
2. Recreates tables from migrations
3. **All user data is permanently lost**

This triggers on seemingly innocuous changes like:
- Modifying column defaults
- Adding indexes
- Changing column constraints
- Even recompiling with different Swift optimization levels

**Solution:** Never use `eraseDatabaseOnSchemaChange`. Instead:

1. **Write proper incremental migrations** that preserve data:
```swift
migrator.registerMigration("v2_add_column") { db in
    try db.alter(table: "section") { t in
        t.add(column: "newField", .text).defaults(to: "")
    }
}
```

2. **Use GRDB's migration versioning** - migrations run once and are tracked in `grdb_migrations` table

3. **Test migrations on copies of real databases** before deploying

**Detection:** If you see:
- All tables exist with correct schema
- `grdb_migrations` table shows all migrations completed
- All data tables are empty (0 rows)

This is the signature of `eraseDatabaseOnSchemaChange` having wiped the database.

**Recovery:** Data cannot be recovered once wiped. The repair service can recreate structural records (project, content) but original content is lost forever.

---

## XeTeX / PDF Export

### Use -output-driver for Paths with Spaces

**Problem:** When the app bundle path contains spaces (e.g., "final final.app"), xelatex fails with error 32512 when calling xdvipdfmx:

```
sh: /Users/.../Build/Products/Debug/final: No such file or directory
```

**Root Cause:** XeTeX internally calls xdvipdfmx via shell without quoting the path. The shell interprets the space as an argument separator:

```
# What xelatex runs internally:
/path/to/final final.app/.../xdvipdfmx args

# Shell interprets as:
Command: /path/to/final
Arg 1: final.app/.../xdvipdfmx
Arg 2: args
```

**What doesn't work:**
- Setting `XDVIPDFMX` environment variable (xelatex ignores it)
- Setting `SELFAUTOLOC` and other kpathsea variables (only affects package resolution)
- Putting wrapper scripts in PATH (xelatex uses absolute path, not PATH lookup)
- Copying binaries to temp directory (breaks TeX package resolution)

**Solution:** Use XeTeX's documented `-output-driver` command-line option to specify the XDV-to-PDF driver command:

```swift
// 1. Create symlink to TinyTeX at space-free path (for package resolution)
let symlinkURL = tempDir.appendingPathComponent("TinyTeX")
try fm.createSymbolicLink(at: symlinkURL, withDestinationURL: bundledTinyTeXURL)

// 2. Create xdvipdfmx wrapper script at space-free path
let wrapperScript = """
    #!/bin/bash
    exec "\(tinyTeXBin)/xdvipdfmx" "$@"
    """
try wrapperScript.write(to: wrapperURL, atomically: true, encoding: .utf8)

// 3. Pass to xelatex via -output-driver option (through Pandoc)
arguments.append(contentsOf: ["--pdf-engine", xelatexPath])
arguments.append(contentsOf: ["--pdf-engine-opt", "-output-driver=\(wrapperURL.path)"])
```

**Reference:** [XeTeX Reference Guide](https://mirrors.mit.edu/CTAN/info/xetexref/xetex-reference.pdf) - the `-output-driver=CMD` option "use CMD as the XDV-to-PDF driver instead of xdvipdfmx"

**General principle:** When bundling TeX in macOS apps, avoid spaces in the app name. If unavoidable, use `-output-driver` to redirect xdvipdfmx calls through a wrapper script at a space-free path.

---

## Zoom Feature

### Async Coordination Patterns

#### CheckedContinuation Double-Resume Prevention

**Problem:** Fatal error when both timeout and acknowledgement callback fire for the same continuation.

**Root Cause:** `waitForContentAcknowledgement()` uses a continuation with timeout. If the timeout fires and then `acknowledgeContent()` is called (or vice versa), the continuation is resumed twice, causing a crash.

**Solution:** Add an `isAcknowledged` flag to prevent double-resume:

```swift
private var isAcknowledged = false

func waitForContentAcknowledgement() async {
    isAcknowledged = false
    // ... in timeout handler:
    guard !isAcknowledged else { return }
    isAcknowledged = true
    contentAckContinuation?.resume()
}

func acknowledgeContent() {
    guard !isAcknowledged else { return }
    isAcknowledged = true
    contentAckContinuation?.resume()
}
```

**General principle:** When using `CheckedContinuation` with timeout races, guard against double-resume with a flag.

---

#### Set Transitional State Before Awaits

**Problem:** Race condition where `contentState` was set after `await zoomOut()`, allowing other operations to start during the transition.

**Root Cause:** The `contentState = .zoomTransition` assignment came after the first `await`, leaving a window where `contentState == .idle` while async work was in progress.

**Solution:** Set transitional state BEFORE any awaits:

```swift
func zoomToSection(_ sectionId: String) async {
    guard contentState == .idle else { return }

    // SET CONTENTSTATE FIRST - before any awaits
    contentState = .zoomTransition

    if zoomedSectionId != nil && zoomedSectionId != sectionId {
        await zoomOut()  // zoomOut detects we're already in transition
    }
    // ...
}
```

**General principle:** In async state machines, set transitional states BEFORE any `await` points to prevent race conditions.

---

#### Caller-Managed State for Nested Async Calls

**Problem:** `zoomOut()` reset `contentState = .idle`, but when called from `zoomToSection()`, the caller still needed the transition state.

**Root Cause:** `zoomOut()` assumes it owns the state lifecycle, but it can be called both standalone (owns state) and nested (caller owns state).

**Solution:** Detect if caller is managing state:

```swift
func zoomOut() async {
    let callerManagedState = (contentState == .zoomTransition)
    if !callerManagedState {
        contentState = .zoomTransition
    }
    // ... do work ...

    // Only reset if we set it ourselves
    if !callerManagedState {
        contentState = .idle
    }
}
```

**General principle:** When async functions can be called standalone or nested, check if the caller is managing shared state before setting/clearing it.

---

### State Protection

#### Protect Backup State During Consecutive Operations

**Problem:** When zooming from section A to section B (without fully unzooming), the backup was overwritten with partial content.

**Root Cause:** Each `zoomToSection()` call stored the current content as backup. When already zoomed, the "current content" was the zoomed section's content, not the full document.

**Solution:** Only store backup if none exists:

```swift
if fullDocumentBeforeZoom == nil {
    fullDocumentBeforeZoom = content
}
```

**General principle:** When storing "before" state for undo/restore operations, guard against overwriting during chained operations.

---

### Field Sync Completeness

#### Sync All Editable Fields, Not Just Content

**Problem:** When user edited a header title while zoomed, the database wasn't updated with the new title.

**Root Cause:** The sync function only checked if content changed, not if title or level changed:

```swift
// Before: only content comparison
if section.markdownContent != newContent {
    // update
}
```

**Solution:** Check for title and level changes, not just content:

```swift
if header.title != existing.title {
    updates.title = header.title
    hasChanges = true
}
if header.level != existing.headerLevel {
    updates.headerLevel = header.level
    hasChanges = true
}
```

**General principle:** When syncing structured data, ensure ALL editable fields are checked for changes.

---

### Use Database as Source of Truth, Not Backup Parsing

**Problem:** When zooming into a section in Milkdown, editing the title, then zooming out, the title reverted to the original. CodeMirror worked correctly.

**Root Cause:** The `zoomOut()` function stored a backup of the full document before zoom, then when zooming out, it parsed the backup to find sections by **title AND level**. When a title changed while zoomed, no match was found:

```swift
// In zoomOut() - FRAGILE
let originalSections = parseMarkdownToSectionOffsets(fullDocumentBeforeZoom)
for original in originalSections {
    if zoomedIds.contains(original.id) {
        // Match by ID works if we can find the ID...
        // But parseMarkdownToSectionOffsets matches by title+level!
        if let edited = sections.first(where: { $0.id == original.id }) {
            mergedContent += edited.markdownContent
        }
    } else {
        mergedContent += original.content  // Uses backup content
    }
}
```

The `parseMarkdownToSectionOffsets()` function assigns IDs by matching title+level against the current sections array. When the title changed:
- Parser sees "one point two gb" (new title)
- Sections array has "one point two gb" (new title from sync)
- Backup has "one point two OH" (old title)
- Parser tries to match backup's "one point two OH" → no match → assigns "unknown-N" ID
- zoomedIds check fails → uses backup content (old title)

**Why CodeMirror worked:** CodeMirror uses section anchors (`<!-- section:UUID -->`) embedded in the content. These anchors preserve the actual section ID regardless of title changes.

**Solution:** Eliminate backup parsing entirely. The `sections` array (synced via ValueObservation) already contains all needed content:
- Zoomed sections: have edited content (synced via `syncZoomedSections`)
- Non-zoomed sections: have original content (unchanged in database)

```swift
// In zoomOut() - ROBUST
let sortedSections = sections
    .filter { !$0.isBibliography }
    .sorted { $0.sortOrder < $1.sortOrder }

var mergedContent = sortedSections
    .map { section in
        var md = section.markdownContent
        if !md.hasSuffix("\n") { md += "\n" }
        return md
    }
    .joined()

// Append bibliography at end
if let bibSection = sections.first(where: { $0.isBibliography }) {
    mergedContent += bibSection.markdownContent
}
```

**Why this works:**
1. **Database is truth** - `syncZoomedSections` persists edits during zoom
2. **`sections` array is current** - ValueObservation keeps it in sync
3. **No title matching** - We use section IDs and sortOrder directly
4. **Handles all cases** - Title changes, content changes, reordering all work

**General principle:** When restoring state after an editing operation, prefer using the live database-backed model rather than parsing a text backup. Text parsing is fragile when identifiers (like titles) can change during the operation.

---

### Bibliography Sync During Zoom

**Problem:** Citations added while zoomed into a section didn't trigger bibliography updates until app restart.

**Root Cause:** The bibliography sync service extracts citekeys from `editorState.content`, but during zoom this only contains the zoomed section's content, not the full document. Citations in the zoomed section were invisible to the sync check.

**Solution:** Post a `.didZoomOut` notification when zoom-out completes, triggering bibliography sync with the full document:

```swift
// In zoomOut()
if !callerManagedState {
    contentState = .idle
    NotificationCenter.default.post(name: .didZoomOut, object: nil)
}

// In ContentView
.onReceive(NotificationCenter.default.publisher(for: .didZoomOut)) { _ in
    let citekeys = BibliographySyncService.extractCitekeys(from: editorState.content)
    bibliographySyncService.checkAndUpdateBibliography(
        currentCitekeys: citekeys,
        projectId: projectId
    )
}
```

**General principle:** When operations occur in a partial-view context (zoom, filter), defer side effects that require the full view until the context is restored.

---

### Dual Editor Mode Content Update

**Problem:** After operations like drag-drop reorder, the CodeMirror editor (source mode) didn't update even though Milkdown (WYSIWYG) showed the correct content.

**Root Cause:** The app maintains two content properties:
- `editorState.content` - used by MilkdownEditor
- `editorState.sourceContent` - used by CodeMirrorEditor (includes section anchors)

Functions like `rebuildDocumentContent()` only updated `content`. When in source mode, `sourceContent` remained stale, so CodeMirror didn't re-render.

**Solution:** Create a helper that updates `sourceContent` whenever `content` changes while in source mode:

```swift
private func updateSourceContentIfNeeded() {
    guard editorState.editorMode == .source else { return }

    // Recalculate section offsets for anchor injection
    var adjustedSections: [SectionViewModel] = []
    var adjustedOffset = 0
    for section in sectionsForAnchors {
        adjustedSections.append(section.withUpdates(startOffset: adjustedOffset))
        adjustedOffset += section.markdownContent.count
        if !section.markdownContent.hasSuffix("\n") { adjustedOffset += 1 }
    }

    let withAnchors = sectionSyncService.injectSectionAnchors(
        markdown: editorState.content, sections: adjustedSections)
    editorState.sourceContent = sectionSyncService.injectBibliographyMarker(
        markdown: withAnchors, sections: editorState.sections)
}
```

Call this at the end of `rebuildDocumentContent()`.

**General principle:** When a view model has mode-specific content properties, ensure ALL are updated when shared state changes. Track which property each editor binds to.

---

### Pseudo-Sections Have parentId=nil (Use Document Order Instead)

**Problem:** When double-clicking a section to zoom, pseudo-sections (content breaks marked with `<!-- ::break:: -->`) that visually belonged to the zoomed section were not included. For example, zooming into `# Introduction` didn't include the `§ In asking...` pseudo-section that followed it.

**Root Cause:** Pseudo-sections are stored with H1 header level (inherited from the preceding actual header), which means they have `parentId = nil`. The `getDescendantIds()` method used `parentId` to find children:

```swift
// BROKEN: Misses pseudo-sections because they have parentId=nil
for section in sections where section.parentId != nil && ids.contains(section.parentId!) {
    ids.insert(section.id)
}
```

Even though `§ In asking...` follows `# Introduction` in the document, there's no parent-child relationship in the data model.

**Solution:** Use **document order** (sortOrder) to find pseudo-sections that belong to a regular section. A pseudo-section "belongs to" the regular section that immediately precedes it, until hitting another regular section at the same or shallower level:

```swift
private func getDescendantIds(of sectionId: String) -> Set<String> {
    var ids = Set<String>([sectionId])
    let sortedSections = sections.sorted { $0.sortOrder < $1.sortOrder }

    guard let rootIndex = sortedSections.firstIndex(where: { $0.id == sectionId }),
          let rootSection = sortedSections.first(where: { $0.id == sectionId }) else {
        return ids
    }
    let rootLevel = rootSection.headerLevel

    // First: Add pseudo-sections by document order
    for i in (rootIndex + 1)..<sortedSections.count {
        let section = sortedSections[i]

        // Stop at a regular (non-pseudo) section at same or shallower level
        if !section.isPseudoSection && section.headerLevel <= rootLevel {
            break
        }

        // Include pseudo-sections (they visually belong to the preceding section)
        if section.isPseudoSection {
            ids.insert(section.id)
        }
    }

    // Second: Add all transitive children by parentId (runs AFTER pseudo-sections added)
    var changed = true
    while changed {
        changed = false
        for section in sortedSections where section.parentId != nil && ids.contains(section.parentId!) {
            if !ids.contains(section.id) {
                ids.insert(section.id)
                changed = true
            }
        }
    }

    return ids
}
```

**Key insight:** The `parentId`-based loop runs AFTER pseudo-sections are added, so it picks up all transitive children of pseudo-sections (the pseudo-section's children have `parentId` pointing to the pseudo-section).

**General principle:** When parent-child relationships don't capture all logical groupings (like pseudo-sections inheriting H1 level), fall back to document order for ownership determination.

---

### Sidebar Must Use Same Zoom IDs as Editor

**Problem:** When zoomed into a pseudo-section with shallow mode, the sidebar still showed `## History` which shouldn't be visible. The editor showed correct content.

**Root Cause:** The sidebar had its own `filterToSubtree()` method that recalculated descendants using `parentId`. This created a mismatch with EditorViewState's `zoomedSectionIds`, which used the fixed document-order algorithm.

```swift
// OutlineSidebar - BROKEN: recalculates using parentId only
private func filterToSubtree(sections: [SectionViewModel], rootId: String) -> [SectionViewModel] {
    var idsToInclude = Set<String>([rootId])
    for section in sections where section.parentId != nil && idsToInclude.contains(section.parentId!) {
        // Misses pseudo-sections, same bug as before
    }
}
```

**Solution:** Pass `zoomedSectionIds` from EditorViewState to OutlineSidebar as a read-only property, and use it directly instead of recalculating:

```swift
// OutlineSidebar - FIXED: uses EditorViewState's pre-calculated IDs
struct OutlineSidebar: View {
    let zoomedSectionIds: Set<String>?  // Read-only, from EditorViewState

    private var filteredSections: [SectionViewModel] {
        var result = sections

        // Apply zoom filter using zoomedSectionIds from EditorViewState
        if let zoomedIds = zoomedSectionIds {
            result = result.filter { zoomedIds.contains($0.id) }
        }
        // ...
    }
}
```

Then remove the now-unused `filterToSubtree()` method entirely.

**General principle:** When multiple components need to filter/display the same subset of data, compute the filter criteria once in the source-of-truth (EditorViewState) and share it, rather than having each component recalculate independently. Independent recalculation leads to subtle mismatches.

---

### WKWebView Compositor Caching on Content Change

**Problem:** When zooming into a long section (2000+ words), the WebView showed the **wrong content** (previous section or full document). Scrolling in any direction "fixed" the display.

**Root Cause:** WKWebView's compositor layer caches the rendered content. When the DOM is updated via `setContent()`, the DOM and scroll position are correct (verified via JavaScript logging), but the compositor layer still shows cached content from the previous state. The browser's rendering pipeline hasn't flushed the compositor cache.

This is NOT a DOM issue (the DOM is correct) or a scroll position issue (scrollY is 0). It's a compositor-level caching issue specific to WKWebView.

**Evidence:** User-triggered scroll (any direction, any amount) immediately fixes the display. This indicates the compositor cache is invalidated on scroll events.

**Solution:** Trigger a programmatic micro-scroll after content update to force compositor refresh:

```typescript
// In setContent() zoom transition handler, after double RAF
requestAnimationFrame(() => {
  requestAnimationFrame(() => {
    // CRITICAL: Force compositor refresh with micro-scroll
    // WKWebView's compositor caches the previous content.
    // A scroll triggers compositor refresh, showing the new content.
    window.scrollTo({ top: 1, left: 0, behavior: 'instant' });
    window.scrollTo({ top: 0, left: 0, behavior: 'instant' });
    view.dom.scrollTop = 0;

    // Signal Swift that paint is complete
    webkit.messageHandlers.paintComplete.postMessage({ ... });
  });
});
```

**Why double RAF isn't enough:** The double `requestAnimationFrame` pattern waits for the browser to render the new content, but this only ensures the DOM is painted—it doesn't guarantee the compositor layer is updated. WKWebView's compositor operates independently and may still serve cached tiles.

**Why micro-scroll works:** Scrolling invalidates the compositor cache because the browser must re-composite the visible viewport. By scrolling 1px down then immediately back to 0, we force cache invalidation without visible UI change.

**What didn't work:**
- `alphaValue = 0/1` hiding/showing the WebView (hides the view but doesn't touch compositor)
- `display: none` / `display: block` (same issue)
- Forcing layout with `void element.offsetHeight` (triggers layout, not compositor refresh)
- Longer delays (the compositor cache persists indefinitely until invalidated)

**General principle:** When WKWebView shows stale content despite correct DOM state, trigger a micro-scroll to force compositor cache invalidation.
