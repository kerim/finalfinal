# CLAUDE.md

## Build Commands

```bash
# Build web editors (required before Xcode build)
cd web && pnpm install && pnpm build

# Build macOS app
xcodebuild -scheme "final final" -destination 'platform=macOS' build

# Full rebuild
cd web && pnpm build && cd .. && xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

Web output goes to `final final/Resources/editor/` which Xcode bundles.

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
| `Models/Database.swift` | GRDB setup, migrations |
| `Models/Document.swift` | GRDB document model |
| `Models/OutlineNode.swift` | GRDB outline cache model |
| `Editors/EditorSchemeHandler.swift` | Custom URL scheme handler |
| `Editors/MilkdownEditor.swift` | WYSIWYG WKWebView wrapper |
| `Editors/CodeMirrorEditor.swift` | Source mode WKWebView wrapper |
| `Services/OutlineParser.swift` | Markdown headers → outline nodes |
| `web/milkdown/src/main.ts` | WYSIWYG editor + focus mode plugin |
| `web/codemirror/src/main.ts` | Source editor |
| `App/AppDelegate.swift` | App lifecycle + database init |
| `App/FinalFinalApp.swift` | SwiftUI app entry point |

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

## Documentation

- `docs/plans/` - Feature plans (protected from overwrites)
- `docs/LESSONS-LEARNED.md` - Technical patterns discovered
- `docs/design.md` - Master design document

### Plan Files

Plan files in `docs/plans/` are **immutable** once created. A hook blocks overwrites.

**To revise a plan:** Create a new version with `-v02`, `-v03` suffix:
- `feature-name.md` (original)
- `feature-name-v02.md` (first revision)
- `feature-name-v03.md` (second revision)

Never edit existing plan files. Always create a new versioned file.

## Phase 1 Verification

- [ ] WYSIWYG editing works (Milkdown)
- [ ] Source editing works (CodeMirror)
- [ ] Cmd+/ toggles modes, cursor preserved
- [ ] Outline sidebar shows headers with preview text
- [ ] Single click → scroll to section
- [ ] Double click → zoom into section
- [ ] Focus mode dims non-current paragraphs
- [ ] Content persists after restart
- [ ] Themes switch correctly
