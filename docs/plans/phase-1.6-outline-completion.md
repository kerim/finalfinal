# Phase 1.6a/b/c Plan: Outline Sidebar Completion

## Overview

Phase 1.6 is functionally complete but has gaps that need addressing. This plan covers three sub-phases:

- **Phase 1.6a**: Fix current bugs (scroll, slash command, word counts)
- **Phase 1.6b**: Editor → Sidebar sync (enables undo/redo)
- **Phase 1.6c**: Tagging and keyboard navigation

---

## Phase 1.6a Status (v0.1.50)

| Issue | Status | Notes |
|-------|--------|-------|
| 1. Milkdown Scroll | **BROKEN** | First attempt failed - needs investigation |
| 2. Slash Commands | **BROKEN** | First attempt failed - needs investigation |
| 3. Word Count | **DONE** | Created `MarkdownUtils.swift` |
| 4. Demo Content | **DONE** | Expanded in `ContentView.swift` |

---

## Phase 1.6a: Bug Fixes and Polish

### Issue 1: Milkdown Scroll Positioning [NEEDS FIX]

**Problem:** Single-click scroll to section positions incorrectly in Milkdown - header appears at bottom of viewport, or first paragraph appears at top instead of header.

**Root Cause:** Milkdown's `scrollToOffset()` uses ProseMirror's `scrollIntoView()` without specifying viewport positioning. CodeMirror uses `y: 'start'` which is more predictable.

**Files to modify:**
- `web/milkdown/src/main.ts` (lines 212-223)

**First Attempt (v0.1.50 - FAILED):**
```javascript
// Used coordsAtPos() and manual scrollContainer.scrollTo()
const coords = view.coordsAtPos(pos);
const scrollContainer = view.dom.parentElement;
const containerRect = scrollContainer.getBoundingClientRect();
const scrollTop = scrollContainer.scrollTop;
const targetY = coords.top - containerRect.top + scrollTop - 100;
scrollContainer.scrollTo({ top: Math.max(0, targetY), behavior: 'smooth' });
```

**Why it failed:** Need to investigate. Possible issues:
- Wrong scroll container (maybe need to find actual scrollable ancestor)
- `coordsAtPos()` returning incorrect coordinates
- Offset calculation issue
- Container vs window scroll confusion

**Next steps to investigate:**
1. Add debug logging to see actual coordinate values
2. Check which element is actually scrollable (WebView? Container? Editor?)
3. Compare with CodeMirror's working implementation
4. Test if `window.scrollTo()` works instead of container scroll

### Issue 2: `/break` Slash Command in Milkdown [NEEDS FIX]

**Problem:** Slash command not working in Milkdown at all.

**Files to modify:**
- `web/milkdown/src/main.ts`

**First Attempt (v0.1.50 - FAILED):**
Used `$prose()` to create a ProseMirror plugin with `handleTextInput`:
```javascript
const slashCommandPlugin = $prose(() => {
  return new Plugin({
    key: slashCommandPluginKey,
    props: {
      handleTextInput(view, from, to, text) {
        // Triggered on space/newline after /command
        // Replaced command text with replacement
      }
    }
  });
});
```

**Why it failed:** Need to investigate. Possible issues:
- Plugin not being registered correctly with Milkdown
- `handleTextInput` not being called (check if prop is correct)
- Transaction being overwritten by other plugins
- Need to check console for errors

**Alternative approaches to try:**
1. Use Milkdown's official `@milkdown/plugin-slash` (requires UI component)
2. Use ProseMirror's `inputRules` instead of `handleTextInput`
3. Add keydown handler to intercept before Milkdown processes
4. Debug by adding console.log to verify plugin is running

### Issue 3: Word Count Includes Markdown Symbols [DONE ✓]

**Completed in v0.1.50:**
- Created `final final/Utils/MarkdownUtils.swift` with `stripMarkdownSyntax()` and `wordCount()`
- Updated `SectionSyncService.swift` to use `MarkdownUtils.wordCount()`
- Updated `ContentView.swift` to use `MarkdownUtils.wordCount()`
- Updated `Section.swift` `recalculateWordCount()` to use `MarkdownUtils.wordCount()`

**Original problem:** Word counts include markdown syntax characters (**, #, [], etc.)

<details>
<summary>Implementation reference (for documentation)</summary>
```swift
static func stripMarkdownSyntax(from content: String) -> String {
    var result = content

    // Remove heading markers: # ## ### etc at line start
    let headingPattern = "^#{1,6}\\s+"
    if let regex = try? NSRegularExpression(pattern: headingPattern, options: .anchorsMatchLines) {
        let range = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
    }

    // Remove bold/italic markers: ** __ * _
    let emphasisPattern = "\\*{1,3}|_{1,3}"
    if let regex = try? NSRegularExpression(pattern: emphasisPattern, options: []) {
        let range = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
    }

    // Remove inline code backticks
    result = result.replacingOccurrences(of: "`", with: "")

    // Convert links [text](url) to just text
    let linkPattern = "\\[([^\\]]+)\\]\\([^)]+\\)"
    if let regex = try? NSRegularExpression(pattern: linkPattern, options: []) {
        let range = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
    }

    // Remove images ![alt](url) entirely
    let imagePattern = "!\\[[^\\]]*\\]\\([^)]+\\)"
    if let regex = try? NSRegularExpression(pattern: imagePattern, options: []) {
        let range = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
    }

    // Remove list markers: - * + or 1. 2. etc
    let listPattern = "^\\s*(?:[-*+]|\\d+\\.)\\s+"
    if let regex = try? NSRegularExpression(pattern: listPattern, options: .anchorsMatchLines) {
        let range = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
    }

    // Remove blockquote markers
    let blockquotePattern = "^>+\\s*"
    if let regex = try? NSRegularExpression(pattern: blockquotePattern, options: .anchorsMatchLines) {
        let range = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
    }

    // Remove break markers
    let breakPattern = "<!--\\s*::break::\\s*-->"
    if let regex = try? NSRegularExpression(pattern: breakPattern, options: []) {
        let range = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
    }

    return result
}

static func wordCount(for content: String) -> Int {
    let text = stripMarkdownSyntax(from: content)
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return 0 }

    return trimmed.components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .count
}
```
</details>

### Issue 4: Longer Default Document for Testing [DONE ✓]

**Completed in v0.1.50:**
- Expanded `demoContent` in `ContentView.swift` from ~20 lines to ~100 lines
- Now includes 10 sections with varying depths (H1, H2, H3)
- Contains: bold, italic, links, code blocks, tables, blockquotes, lists

### Phase 1.6a Verification

- [ ] Single-click scroll positions header ~100px from top in Milkdown ❌ BROKEN
- [x] Single-click scroll works consistently in CodeMirror ✓
- [ ] `/break` command works in Milkdown (inserts `<!-- ::break:: -->`) ❌ BROKEN
- [ ] `/h1`, `/h2`, `/h3` commands work in Milkdown ❌ BROKEN
- [x] Word counts exclude markdown symbols ✓
- [x] Word counts match between raw text and formatted view ✓
- [x] Default document has sufficient content for scroll testing ✓

---

## Phase 1.6b: Editor → Sidebar Sync (Bidirectional)

### Overview

Currently sync is one-way: Sidebar changes → Editor rebuild. For undo/redo to work, we need: Editor changes → Sidebar update.

### Architecture

```
┌─────────────┐         ┌──────────────────┐         ┌─────────────┐
│   Editor    │ ──────> │ SectionSyncService│ ──────> │   Sidebar   │
│ (WebView)   │ <────── │                  │ <────── │   (SwiftUI) │
└─────────────┘         └──────────────────┘         └─────────────┘
     │                         │                           │
     │  content change         │  parse & diff             │  drag-drop
     │  (polling/callback)     │  sections                 │  reorder
     └─────────────────────────┴───────────────────────────┘
```

### Implementation Steps

#### Step 1: Detect Editor Content Changes

**Files to modify:**
- `final final/Editors/MilkdownEditor.swift`
- `final final/Editors/CodeMirrorEditor.swift`
- `final final/ViewState/EditorViewState.swift`

**Current state:** Editors poll `getContent()` every 500ms to detect changes.

**Enhancement:** When content changes, trigger section re-parse:
```swift
// In EditorViewState
func contentDidChange(_ newContent: String) {
    guard newContent != currentContent else { return }
    currentContent = newContent

    // Re-parse sections from new content
    let newSections = SectionSyncService.shared.parseSections(from: newContent)

    // Diff and update (preserve metadata like goals, status, tags)
    updateSectionsPreservingMetadata(newSections)
}
```

#### Step 2: Section Diffing Algorithm

**Files to create:**
- `final final/Services/SectionDiffer.swift`

**Purpose:** Match new parsed sections to existing sections to preserve metadata.

**Algorithm:**
1. For each new section, find best match in existing sections by:
   - Exact title match (highest confidence)
   - Similar title (fuzzy match for edits)
   - Same position in hierarchy
2. Preserve metadata (id, goals, status, tags) from matched section
3. New sections get fresh UUIDs
4. Deleted sections are removed

```swift
struct SectionDiffer {
    static func diff(old: [Section], new: [Section]) -> [Section] {
        var result: [Section] = []
        var usedOldIds: Set<String> = []

        for newSection in new {
            // Try exact title match first
            if let match = old.first(where: {
                $0.title == newSection.title && !usedOldIds.contains($0.id)
            }) {
                usedOldIds.insert(match.id)
                result.append(newSection.preservingMetadata(from: match))
            } else {
                // New section
                result.append(newSection)
            }
        }

        return result
    }
}
```

#### Step 3: Handle Section Operations

**Scenarios to handle:**

1. **User adds heading in editor** → New section appears in sidebar
2. **User deletes heading in editor** → Section removed from sidebar
3. **User changes heading text** → Section title updates
4. **User changes heading level** → Section level updates, hierarchy adjusts
5. **User uses undo** → Sections revert to previous state

**Files to modify:**
- `final final/Services/SectionSyncService.swift`
- `final final/ViewState/EditorViewState.swift`

#### Step 4: Throttle Re-parsing

**Problem:** Re-parsing on every keystroke is expensive.

**Solution:** Debounce content changes:
```swift
private var parseDebouncer: Task<Void, Never>?

func contentDidChange(_ newContent: String) {
    parseDebouncer?.cancel()
    parseDebouncer = Task {
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        await MainActor.run {
            performSectionSync(newContent)
        }
    }
}
```

#### Step 5: Persist Section Metadata

**Current gap:** `updateSection()` has TODO for database persistence.

**Files to modify:**
- `final final/Views/ContentView.swift`
- `final final/Models/Database.swift`

**Solution:** Save section metadata (goals, status, tags) to database when changed.

### Phase 1.6b Verification

- [ ] Adding `# New Section` in editor creates section in sidebar
- [ ] Deleting a header removes section from sidebar
- [ ] Changing header text updates section title
- [ ] Changing `##` to `###` updates section level and hierarchy
- [ ] Cmd+Z (undo) in editor reverts sidebar to previous state
- [ ] Section metadata (goals, status) preserved through edits
- [ ] No performance lag during typing (debounce works)
- [ ] Drag-drop in sidebar still works after bidirectional sync

---

## Phase 1.6c: Tagging and Keyboard Navigation

### Tag Features

#### Tag Filtering

**Files to modify:**
- `final final/Views/OutlineFilterBar.swift`
- `final final/Views/OutlineSidebar.swift`

**Implementation:**
1. Add tag filter chips alongside status filter
2. Extract unique tags from all sections
3. Filter shows sections matching ANY selected tag (OR logic)
4. Combine with status filter (AND logic): status AND tags

#### Tag Autocomplete

**Files to modify:**
- `final final/Views/SectionCardView.swift` (tag input)
- Create `final final/Views/TagAutocomplete.swift`

**Implementation:**
1. When user starts typing tag, show dropdown of existing tags
2. Match by prefix (case-insensitive)
3. Allow creating new tags
4. Store tag vocabulary in database for persistence

### Keyboard Navigation

**Files to modify:**
- `final final/Views/OutlineSidebar.swift`
- `final final/Views/SectionCardView.swift`

**Key bindings:**
| Key | Action |
|-----|--------|
| ↑/↓ | Move selection between sections |
| Enter | Scroll to selected section |
| Space | Toggle expand/collapse (if has children) |
| Tab | Indent section (increase level) |
| Shift+Tab | Outdent section (decrease level) |
| Delete/Backspace | Delete section (with confirmation) |
| Cmd+↑/↓ | Move section up/down in list |

**Implementation:**
1. Track `selectedSectionId` in OutlineSidebar
2. Add `.focusable()` and `.onKeyPress()` modifiers
3. Handle arrow keys for navigation
4. Handle modifier keys for operations

### Phase 1.6c Verification

- [ ] Tag chips appear in filter bar
- [ ] Clicking tag filters to sections with that tag
- [ ] Multiple tags can be selected (OR filter)
- [ ] Tag + status filter combines correctly (AND)
- [ ] Tag autocomplete shows existing tags
- [ ] New tags can be created
- [ ] Arrow keys navigate between sections
- [ ] Enter scrolls to selected section
- [ ] Tab/Shift+Tab changes section level
- [ ] Delete removes section (with confirmation)

---

## Implementation Order

1. **Phase 1.6a** (bug fixes) - Do first, enables proper testing
2. **Phase 1.6b** (bidirectional sync) - Core functionality for undo/redo
3. **Phase 1.6c** (polish) - Nice-to-have features

## Critical Files Summary

| Phase | Key Files |
|-------|-----------|
| 1.6a (remaining) | `web/milkdown/src/main.ts` (scroll + slash commands) |
| 1.6a (done) | `final final/Utils/MarkdownUtils.swift` ✓, `ContentView.swift` (demo content) ✓ |
| 1.6b | `EditorViewState.swift`, `SectionSyncService.swift`, new `SectionDiffer.swift` |
| 1.6c | `OutlineFilterBar.swift`, `OutlineSidebar.swift`, new `TagAutocomplete.swift` |

---

## Next Session: Debug Issues 1 & 2

When resuming work on Phase 1.6a:

1. **Add debug logging** to `scrollToOffset()` to see actual coordinate values
2. **Check console** in Web Inspector for any JavaScript errors from slash command plugin
3. **Compare** with CodeMirror's working scroll implementation
4. **Test** if the slash command plugin is even being loaded (add console.log in plugin)
