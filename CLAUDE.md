# CLAUDE.md

## Build Commands

```bash
# Build web editors (required before Xcode build)
cd web && pnpm install && pnpm build

# Regenerate Xcode project (after moving/adding Swift files)
xcodegen generate

# Build macOS app
xcodebuild -scheme "final final" -destination 'platform=macOS' build

# Full rebuild
cd web && pnpm build && cd .. && xcodegen generate && xcodebuild -scheme "final final" -destination 'platform=macOS' build

# Lint web editors (TypeScript/CSS)
cd web && pnpm lint          # Check for issues
cd web && pnpm lint:fix      # Auto-fix issues
cd web && pnpm format        # Format files
```

Web output goes to `final final/Resources/editor/` which Xcode bundles.

**Note:** This project uses `xcodegen` to generate the Xcode project from `project.yml`. Always run `xcodegen generate` after moving or adding Swift files.

## Architecture

**SQLite-first hybrid app:** SwiftUI shell + GRDB database + WKWebView editors (Milkdown WYSIWYG, CodeMirror source).

**Requirements:** macOS 14.0+ (uses @Observable macro)

**Core principle:** Database is single source of truth. No file watching, no manifest sync.

### Swift ↔ Web Communication

Custom `editor://` URL scheme + 500ms polling:

1. **EditorSchemeHandler** serves bundled assets with proper MIME types
2. **EditorWebView** polls `window.FinalFinal.getContent()` to detect changes
3. Swift calls `window.FinalFinal.setContent(markdown)` to push content
4. Feedback loop prevention: track `lastReceivedFromEditor` timestamp

### Key Files

| File | Purpose |
|------|---------|
| `App/AppDelegate.swift` | App lifecycle + database init |
| `App/FinalFinalApp.swift` | SwiftUI app entry point |
| `Models/Database.swift` | GRDB setup, migrations, persistent storage |
| `Models/ProjectDatabase.swift` | Project-specific database with CRUD operations |
| `Models/Document.swift` | Project + Content GRDB models |
| `Models/Section.swift` | Section model with metadata (status, tags, goals) |
| `ViewState/EditorViewState.swift` | Editor state (@Observable, @MainActor) |
| `Editors/EditorSchemeHandler.swift` | Custom URL scheme handler |
| `Editors/MilkdownEditor.swift` | WYSIWYG editor WKWebView wrapper |
| `Editors/CodeMirrorEditor.swift` | Source editor WKWebView wrapper |
| `Services/DocumentManager.swift` | Project lifecycle + Getting Started + recent projects |
| `Services/SectionSyncService.swift` | Editor ↔ section sync with debouncing |
| `Services/OutlineParser.swift` | Markdown headers → outline nodes |
| `Views/Sidebar/OutlineSidebar.swift` | Section cards with drag-drop reordering |
| `Views/Sidebar/SectionCardView.swift` | Individual section card + SectionViewModel |
| `Theme/ColorScheme.swift` | App color scheme definitions |
| `web/milkdown/src/main.ts` | WYSIWYG editor + focus mode plugin |
| `web/codemirror/src/main.ts` | Source editor |

### window.FinalFinal API

```javascript
setContent(markdown)     // Load content into editor
getContent()             // Get current markdown
setFocusMode(enabled)    // Toggle paragraph dimming (WYSIWYG only)
getStats()               // Returns {words, characters}
scrollToOffset(n)        // Scroll to character offset
```

## Versioning

- **Marketing Version**: `1` (static until release)
- **Project Version**: `0.PHASE.BUILD` format

Increment BUILD with every build. Update in `web/package.json` and `project.yml`.

## Debugging

### Two-Attempt Rule

After 2 failed fix attempts, STOP. Add diagnostic logging before trying again.

1. First attempt fails → Reassess, try different approach
2. Second attempt fails → Add logging to trace actual execution
3. Analyze logs → Find verified root cause
4. Then fix

### Web Inspector

Set `webView.isInspectable = true` in development. Safari → Develop → [app name].

**Limitation:** Web Inspector context is erased when switching between Milkdown and CodeMirror (WebView reloads). For debugging editor switches, use:

1. **Swift-side logging:** Add `print()` statements in `MilkdownEditor.swift` / `CodeMirrorEditor.swift` to log values returned from `evaluateJavaScript`
2. **Persistent debug state:** Use `window.__MILKDOWN_DEBUG__` or similar to store values, then query via `getDebugState()` before the switch
3. **Xcode console:** All Swift `print()` output appears in Xcode's debug console and persists across editor switches

## Git Commits

When asked to commit changes:

1. **Always run `git status` first** to see ALL modified files, not just the ones you recently edited
2. **Review the full list** of staged and unstaged changes before committing
3. **Ask the user** if any modified files should be excluded from the commit
4. **Include all related work** from the session, not just the last task

Never commit only the files you remember working on - always check for other modifications that may have been made earlier in the session.

**Commit message format:** Use multiple `-m` flags instead of heredocs (heredocs fail in sandbox):
```bash
git commit -m "Title" -m "Body line 1" -m "Body line 2"
```

## Documentation

- `docs/plans/` - Feature plans (protected from overwrites)
- `docs/deferred/` - Abandoned approaches that might be revisited later
- `docs/LESSONS-LEARNED.md` - Technical patterns discovered
- `docs/design.md` - Master design document
- `KARMA.md` - Third-party code attribution and inspiration sources

### Updating Documentation After Features

When completing a feature phase, update these documents:

1. **CLAUDE.md** - Add to "Completed Phases" list
2. **README.md** - Move feature from "Planned" to "Implemented" table
3. **docs/design.md** - Add phase section and update "Future Phases" table
4. **KARMA.md** - If new dependencies were added:
   - Add to appropriate "Bundled Dependencies" table
   - Include package name, version, license, author, and URL
   - Update the "Last updated" date and changelog

### Plan Files

Plan files in `docs/plans/` are **immutable** once created. A hook blocks overwrites.

**To revise a plan:** Create a new version with `-v02`, `-v03` suffix:
- `feature-name.md` (original)
- `feature-name-v02.md` (first revision)
- `feature-name-v03.md` (second revision)

Never edit existing plan files. Always create a new versioned file.

## Swift Engineering Plugin

Use the `swift-engineering` plugin for code review and Swift best practices.

### Invocation Patterns

| Type | Location | How to Invoke | Example |
|------|----------|---------------|---------|
| **Commands** | `commands/` | `/swift-engineering:name` | `/swift-engineering:reflect` |
| **Skills** | `skills/` | `Skill("swift-engineering:grdb")` | Load GRDB reference |
| **Agents** | `agents/` | `Task(subagent_type="swift-engineering:swift-code-reviewer")` | Spawn reviewer |

### Available Skills

- `grdb` - GRDB patterns, migrations, ValueObservation
- `swift-style` - Swift code style conventions
- `swiftui-patterns` - SwiftUI best practices
- `composable-architecture` - TCA patterns
- `modern-swift` - async/await, Sendable, actors

### Code Review

After completing implementation work, run code review:
```
Task(subagent_type="swift-engineering:swift-code-reviewer", prompt="Review the Swift code...")
```

Or use the reflect command for instruction improvements:
```
/swift-engineering:reflect
```

## Completed Phases

- [x] **Phase 1.1** - Project setup, GRDB, editor:// scheme (2026-01-23)
- [x] **Phase 1.6** - Outline sidebar with section management (2026-01-26)
- [x] **Phase 1.6b** - Editor ↔ sidebar sync with database wiring (2026-01-27)
- [x] **Phase 1.7** - Annotations (task, comment, reference) (2026-01-29)
- [x] **Phase 1.8** - Zotero citation integration (2026-01-29)
- [x] **Phase 1.9** - Onboarding (project picker, Getting Started guide, sidebar toggles) (2026-01-31)

## Phase 1 Verification

- [x] WYSIWYG editing works (Milkdown)
- [x] Source editing works (CodeMirror)
- [x] Cmd+/ toggles modes, cursor preserved
- [x] Outline sidebar shows headers with preview text
- [x] Single click → scroll to section
- [x] Double click → zoom into section
- [x] Focus mode dims non-current paragraphs
- [x] Content persists after restart
- [x] Themes switch correctly
- [x] Drag-drop reordering with hierarchy constraints
- [x] Section metadata (status, tags, word goals) persists
- [ ] /cite command opens citation search (requires Zotero + BBT)
- [ ] Citations render as formatted inline text (Author, Year)
- [ ] Bibliography section auto-generates from citations
