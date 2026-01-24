# Phase 1.5: CodeMirror 6 Source Editor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Integrate CodeMirror 6 as the source mode editor with full markdown support, cursor position preservation on mode toggle, and formatting shortcuts.

**Architecture:** Mirror the MilkdownEditor pattern - WKWebView wrapper with 500ms polling, same window.FinalFinal API, theme injection via CSS variables.

**Tech Stack:** CodeMirror 6, @codemirror/lang-markdown, Vite (IIFE build), SwiftUI NSViewRepresentable

---

## Pre-Implementation: Update LESSONS-LEARNED.md

Before starting Phase 1.5, update `docs/LESSONS-LEARNED.md` with bug fixes discovered in Phases 1.1-1.4.

**Add these sections:**

### Thread Safety

```markdown
## Thread Safety

### @MainActor on @Observable Classes
Any `@Observable` class holding UI state MUST have `@MainActor`:
```swift
@MainActor
@Observable
class EditorViewState { ... }
```

### Timer Callbacks Need Safe Actor Transition
Timer callbacks are not guaranteed to run on main thread:
```swift
// Wrong
Timer.scheduledTimer { self.updateUI() }

// Right
Timer.scheduledTimer { _ in
    Task { @MainActor in self.updateUI() }
}
```

### NotificationCenter Publishers Need Main Thread
```swift
.onReceive(NotificationCenter.default.publisher(for: .myNotification)
    .receive(on: DispatchQueue.main)) { _ in ... }
```

### Cleanup Flags for Async Callbacks
Views with timers/callbacks need cleanup guard:
```swift
private var isCleanedUp = false

func cleanup() {
    isCleanedUp = true
    timer?.invalidate()
}

private func pollContent() {
    guard !isCleanedUp else { return }
    // ...
}
```
```

### Database

```markdown
## Database (GRDB)

### Use Persistent Storage
In-memory databases lose data on restart. Use Application Support:
```swift
let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
let dbPath = appSupport.appendingPathComponent("com.kerim.final-final/database.sqlite")
```

### Type-Safe Records over Raw SQL
```swift
// Wrong
try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])

// Right
try Setting.filter(Column("key") == key).fetchOne(db)?.value
```

### Add Indices for Foreign Keys
```sql
CREATE INDEX content_projectId ON content(projectId);
```
```

### String Handling

```markdown
## String Handling

### Character Count vs Byte Count
Use `.count` for Swift String indices, `.utf8.count` only for bytes:
```swift
// For character positions (outline offsets)
let offset = text.prefix(position).count  // Right

// Only for byte-level operations (network, files)
let byteSize = text.utf8.count
```

Test with multi-byte characters (emoji: 🎉, accents: é).
```

### Resource Bundling

```markdown
## Resource Bundling

### Fallback for Xcode Folder Handling
Xcode may flatten folder references. Use fallback lookup:
```swift
// Try subdirectory first
if let url = Bundle.main.url(forResource: path, withExtension: nil, subdirectory: dir) {
    return url
}
// Fall back to flat resources
return Bundle.main.url(forResource: name, withExtension: ext)
```
```

### Color Space

```markdown
## Colors

### Use sRGB for Portable Colors
`deviceRGB` varies by display. Use sRGB for web/cross-platform:
```swift
nsColor.usingColorSpace(.sRGB)  // Right - consistent across displays
nsColor.usingColorSpace(.deviceRGB)  // Wrong - display-dependent
```
```

---

## Task 1: Install CodeMirror 6 Dependencies

**Files:**
- Modify: `web/codemirror/package.json`

**Step 1: Update package.json with CodeMirror dependencies**

```json
{
  "name": "@final-final/codemirror-editor",
  "version": "0.1.5",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build"
  },
  "dependencies": {
    "@codemirror/lang-markdown": "^6.2.0",
    "@codemirror/language-data": "^6.4.0",
    "@codemirror/state": "^6.4.0",
    "@codemirror/view": "^6.25.0",
    "codemirror": "^6.0.1"
  },
  "devDependencies": {
    "typescript": "^5.3.0",
    "vite": "^5.0.0"
  }
}
```

**Step 2: Install dependencies**

Run: `cd web/codemirror && pnpm install`
Expected: Dependencies installed successfully

**Step 3: Commit**

```bash
git add web/codemirror/package.json web/codemirror/pnpm-lock.yaml
git commit -m "chore: add CodeMirror 6 dependencies for Phase 1.5"
```

---

## Task 2: Implement CodeMirror Editor (TypeScript)

**Files:**
- Modify: `web/codemirror/src/main.ts`
- Create: `web/codemirror/src/styles.css`

**Step 1: Create styles.css**

```css
* {
  box-sizing: border-box;
}

html, body {
  margin: 0;
  padding: 0;
  height: 100%;
  overflow: hidden;
  background: var(--editor-background, #ffffff);
  color: var(--editor-text, #1a1a1a);
  font-family: var(--editor-font, -apple-system, BlinkMacSystemFont, sans-serif);
}

#editor {
  height: 100%;
  width: 100%;
}

.cm-editor {
  height: 100%;
  font-size: 16px;
  line-height: 1.6;
}

.cm-editor .cm-scroller {
  padding: 20px;
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, monospace;
}

.cm-editor .cm-content {
  caret-color: var(--editor-caret, #007aff);
}

.cm-editor .cm-cursor {
  border-left-color: var(--editor-caret, #007aff);
}

.cm-editor.cm-focused .cm-selectionBackground,
.cm-editor .cm-selectionBackground {
  background: var(--editor-selection, rgba(0, 122, 255, 0.2));
}

/* Markdown syntax highlighting */
.cm-header { color: var(--editor-header, #1a1a1a); font-weight: 600; }
.cm-header-1 { font-size: 1.5em; }
.cm-header-2 { font-size: 1.3em; }
.cm-header-3 { font-size: 1.1em; }
.cm-strong { font-weight: 700; }
.cm-emphasis { font-style: italic; }
.cm-link { color: var(--editor-link, #007aff); }
.cm-url { color: var(--editor-url, #666); }
.cm-code {
  background: var(--editor-code-bg, #f5f5f5);
  border-radius: 3px;
  padding: 0 4px;
}
```

**Step 2: Implement main.ts with full CodeMirror setup**

```typescript
import { EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter } from '@codemirror/view';
import { EditorState, StateEffect, StateField } from '@codemirror/state';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { languages } from '@codemirror/language-data';
import { defaultKeymap, history, historyKeymap } from '@codemirror/commands';
import { syntaxHighlighting, defaultHighlightStyle } from '@codemirror/language';
import './styles.css';

declare global {
  interface Window {
    FinalFinal: {
      setContent: (markdown: string) => void;
      getContent: () => string;
      setFocusMode: (enabled: boolean) => void;
      getStats: () => { words: number; characters: number };
      scrollToOffset: (offset: number) => void;
      setTheme: (cssVariables: string) => void;
      getCursorPosition: () => number;
      setCursorPosition: (pos: number) => void;
    };
    __CODEMIRROR_DEBUG__?: {
      editorReady: boolean;
      lastContentLength: number;
      lastStatsUpdate: string;
    };
  }
}

let editorView: EditorView | null = null;

// Debug state for Swift introspection
window.__CODEMIRROR_DEBUG__ = {
  editorReady: false,
  lastContentLength: 0,
  lastStatsUpdate: ''
};

function initEditor() {
  const container = document.getElementById('editor');
  if (!container) {
    console.error('[CodeMirror] #editor container not found');
    return;
  }

  const state = EditorState.create({
    doc: '',
    extensions: [
      lineNumbers(),
      highlightActiveLine(),
      highlightActiveLineGutter(),
      history(),
      markdown({ base: markdownLanguage, codeLanguages: languages }),
      syntaxHighlighting(defaultHighlightStyle),
      keymap.of([
        ...defaultKeymap,
        ...historyKeymap,
        // Cmd+B: Bold
        { key: 'Mod-b', run: () => { wrapSelection('**'); return true; } },
        // Cmd+I: Italic
        { key: 'Mod-i', run: () => { wrapSelection('*'); return true; } },
        // Cmd+K: Link
        { key: 'Mod-k', run: () => { insertLink(); return true; } },
      ]),
      EditorView.lineWrapping,
      EditorView.theme({
        '&': { height: '100%' },
        '.cm-scroller': { overflow: 'auto' }
      })
    ]
  });

  editorView = new EditorView({
    state,
    parent: container
  });

  window.__CODEMIRROR_DEBUG__!.editorReady = true;
  console.log('[CodeMirror] Editor initialized');
}

function wrapSelection(wrapper: string) {
  if (!editorView) return;
  const { from, to } = editorView.state.selection.main;
  const selected = editorView.state.sliceDoc(from, to);
  const wrapped = wrapper + selected + wrapper;
  editorView.dispatch({
    changes: { from, to, insert: wrapped },
    selection: { anchor: from + wrapper.length, head: to + wrapper.length }
  });
}

function insertLink() {
  if (!editorView) return;
  const { from, to } = editorView.state.selection.main;
  const selected = editorView.state.sliceDoc(from, to);
  const linkText = selected || 'link text';
  const inserted = `[${linkText}](url)`;
  editorView.dispatch({
    changes: { from, to, insert: inserted },
    selection: { anchor: from + 1, head: from + 1 + linkText.length }
  });
}

function countWords(text: string): number {
  return text.split(/\s+/).filter(w => w.length > 0).length;
}

// Register window.FinalFinal API
window.FinalFinal = {
  setContent(markdown: string) {
    if (!editorView) return;
    editorView.dispatch({
      changes: { from: 0, to: editorView.state.doc.length, insert: markdown }
    });
    window.__CODEMIRROR_DEBUG__!.lastContentLength = markdown.length;
    console.log('[CodeMirror] setContent:', markdown.length, 'chars');
  },

  getContent(): string {
    if (!editorView) return '';
    return editorView.state.doc.toString();
  },

  setFocusMode(enabled: boolean) {
    // Focus mode is WYSIWYG-only; ignore in source mode
    console.log('[CodeMirror] setFocusMode ignored (source mode)');
  },

  getStats() {
    const content = editorView?.state.doc.toString() || '';
    const words = countWords(content);
    const characters = content.length;
    window.__CODEMIRROR_DEBUG__!.lastStatsUpdate = new Date().toISOString();
    return { words, characters };
  },

  scrollToOffset(offset: number) {
    if (!editorView) return;
    const pos = Math.min(offset, editorView.state.doc.length);
    editorView.dispatch({
      effects: EditorView.scrollIntoView(pos, { y: 'start', yMargin: 50 })
    });
    console.log('[CodeMirror] scrollToOffset:', offset);
  },

  setTheme(cssVariables: string) {
    const root = document.documentElement;
    const pairs = cssVariables.split(';').filter(s => s.trim());
    pairs.forEach(pair => {
      const [key, value] = pair.split(':').map(s => s.trim());
      if (key && value) {
        root.style.setProperty(key, value);
      }
    });
    console.log('[CodeMirror] Theme applied with', pairs.length, 'variables');
  },

  getCursorPosition(): number {
    if (!editorView) return 0;
    return editorView.state.selection.main.head;
  },

  setCursorPosition(pos: number) {
    if (!editorView) return;
    const safePos = Math.min(pos, editorView.state.doc.length);
    editorView.dispatch({
      selection: { anchor: safePos }
    });
    editorView.focus();
    console.log('[CodeMirror] setCursorPosition:', safePos);
  }
};

// Initialize on DOM ready
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', initEditor);
} else {
  initEditor();
}

console.log('[CodeMirror] window.FinalFinal API registered');
```

**Step 3: Update codemirror.html**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>CodeMirror Editor</title>
  <script>window.__CODEMIRROR_SCRIPT_STARTED__ = Date.now();</script>
  <script type="module" src="./src/main.ts"></script>
</head>
<body>
  <div id="editor"></div>
</body>
</html>
```

**Step 4: Build the editor**

Run: `cd web/codemirror && pnpm build`
Expected: Build succeeds, files in `final final/Resources/editor/codemirror/`

**Step 5: Commit**

```bash
git add web/codemirror/
git commit -m "feat: implement CodeMirror 6 editor with markdown support"
```

---

## Task 3: Create CodeMirrorEditor.swift

**Files:**
- Create: `final final/Editors/CodeMirrorEditor.swift`

**Step 1: Create CodeMirrorEditor.swift mirroring MilkdownEditor pattern**

```swift
//
//  CodeMirrorEditor.swift
//  final final
//
//  WKWebView wrapper for CodeMirror 6 source editor.
//  Uses 500ms polling pattern for content synchronization.
//

import SwiftUI
import WebKit

struct CodeMirrorEditor: NSViewRepresentable {
    @Binding var content: String

    let onContentChange: (String) -> Void
    let onStatsChange: (Int, Int) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(EditorSchemeHandler(), forURLScheme: "editor")

        // Error handler script to capture JS errors
        let errorScript = WKUserScript(
            source: """
                window.onerror = function(msg, url, line, col, error) {
                    window.webkit.messageHandlers.errorHandler.postMessage({
                        type: 'error',
                        message: msg,
                        url: url,
                        line: line,
                        column: col,
                        error: error ? error.toString() : null
                    });
                    return false;
                };
                window.addEventListener('unhandledrejection', function(e) {
                    window.webkit.messageHandlers.errorHandler.postMessage({
                        type: 'unhandledrejection',
                        message: 'Unhandled Promise Rejection: ' + e.reason,
                        url: '',
                        line: 0,
                        column: 0,
                        error: e.reason ? e.reason.toString() : null
                    });
                });
                console.log('[ErrorHandler] JS error capture installed');
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(errorScript)
        configuration.userContentController.add(context.coordinator, name: "errorHandler")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator

        #if DEBUG
        webView.isInspectable = true
        #endif

        if let url = URL(string: "editor://codemirror/codemirror.html") {
            webView.load(URLRequest(url: url))
        }

        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.shouldPushContent(content) {
            context.coordinator.setContent(content)
        }

        let cssVars = ThemeManager.shared.cssVariables
        if context.coordinator.lastThemeCss != cssVars {
            context.coordinator.lastThemeCss = cssVars
            context.coordinator.setTheme(cssVars)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(content: $content, onContentChange: onContentChange, onStatsChange: onStatsChange)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cleanup()
    }

    @MainActor
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?

        private var contentBinding: Binding<String>
        private let onContentChange: (String) -> Void
        private let onStatsChange: (Int, Int) -> Void

        private var pollingTimer: Timer?
        private var lastReceivedFromEditor: Date = .distantPast
        private var lastPushedContent: String = ""

        var lastThemeCss: String = ""
        private var isEditorReady = false
        private var isCleanedUp = false

        init(content: Binding<String>, onContentChange: @escaping (String) -> Void, onStatsChange: @escaping (Int, Int) -> Void) {
            self.contentBinding = content
            self.onContentChange = onContentChange
            self.onStatsChange = onStatsChange
            super.init()
        }

        deinit { pollingTimer?.invalidate() }

        func cleanup() {
            isCleanedUp = true
            pollingTimer?.invalidate()
            pollingTimer = nil
            webView = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            #if DEBUG
            print("[CodeMirrorEditor] WebView finished loading")

            webView.evaluateJavaScript("typeof window.__CODEMIRROR_SCRIPT_STARTED__") { result, error in
                print("[CodeMirrorEditor] JS script check: \(result ?? "nil")")
            }

            webView.evaluateJavaScript("typeof window.FinalFinal") { result, error in
                print("[CodeMirrorEditor] window.FinalFinal type: \(result ?? "nil")")
            }
            #endif

            isEditorReady = true
            setContent(contentBinding.wrappedValue)
            setTheme(ThemeManager.shared.cssVariables)
            startPolling()
        }

        nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "errorHandler", let body = message.body as? [String: Any] {
                let msgType = body["type"] as? String ?? "unknown"
                let errorMsg = body["message"] as? String ?? "unknown"
                print("[CodeMirrorEditor] JS \(msgType.uppercased()): \(errorMsg)")
            }
        }

        func shouldPushContent(_ newContent: String) -> Bool {
            let timeSinceLastReceive = Date().timeIntervalSince(lastReceivedFromEditor)
            if timeSinceLastReceive < 0.6 && newContent == lastPushedContent { return false }
            return newContent != lastPushedContent
        }

        func setContent(_ markdown: String) {
            guard isEditorReady, let webView else { return }
            lastPushedContent = markdown
            let escaped = markdown.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "$", with: "\\$")
            webView.evaluateJavaScript("window.FinalFinal.setContent(`\(escaped)`)") { _, error in
                if let error { print("[CodeMirrorEditor] setContent error: \(error)") }
            }
        }

        func setTheme(_ cssVariables: String) {
            guard isEditorReady, let webView else { return }
            let escaped = cssVariables.replacingOccurrences(of: "`", with: "\\`")
            webView.evaluateJavaScript("window.FinalFinal.setTheme(`\(escaped)`)") { _, _ in }
        }

        func getCursorPosition(completion: @escaping (Int) -> Void) {
            guard isEditorReady, let webView else { completion(0); return }
            webView.evaluateJavaScript("window.FinalFinal.getCursorPosition()") { result, _ in
                completion(result as? Int ?? 0)
            }
        }

        func setCursorPosition(_ position: Int) {
            guard isEditorReady, let webView else { return }
            webView.evaluateJavaScript("window.FinalFinal.setCursorPosition(\(position))") { _, _ in }
        }

        private func startPolling() {
            pollingTimer?.invalidate()
            pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.pollContent()
                }
            }
        }

        private func pollContent() {
            guard !isCleanedUp, isEditorReady, let webView else { return }

            webView.evaluateJavaScript("window.FinalFinal.getContent()") { [weak self] result, _ in
                guard let self, !self.isCleanedUp,
                      let content = result as? String, content != self.lastPushedContent else { return }
                self.lastReceivedFromEditor = Date()
                self.lastPushedContent = content
                self.contentBinding.wrappedValue = content
                self.onContentChange(content)
            }

            webView.evaluateJavaScript("window.FinalFinal.getStats()") { [weak self] result, _ in
                guard let self, !self.isCleanedUp,
                      let dict = result as? [String: Any],
                      let words = dict["words"] as? Int, let chars = dict["characters"] as? Int else { return }
                self.onStatsChange(words, chars)
            }
        }
    }
}
```

**Step 2: Verify file compiles**

Run: `xcodegen generate && xcodebuild -scheme "final final" -destination 'platform=macOS' build`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add "final final/Editors/CodeMirrorEditor.swift"
git commit -m "feat: add CodeMirrorEditor Swift wrapper"
```

---

## Task 4: Implement Mode Toggle with Cursor Preservation

**Files:**
- Modify: `final final/ViewState/EditorViewState.swift`
- Modify: `final final/Views/ContentView.swift`

**Step 1: Add cursor position tracking to EditorViewState**

In `EditorViewState.swift`, add:

```swift
// MARK: - Cursor Position (for mode toggle)
var cursorPosition: Int = 0

func toggleEditorMode() {
    editorMode = editorMode == .wysiwyg ? .source : .wysiwyg
}
```

**Step 2: Update ContentView to pass cursor and use CodeMirrorEditor**

Replace the source mode placeholder in `ContentView.swift`:

```swift
@ViewBuilder
private var editorView: some View {
    switch editorState.editorMode {
    case .wysiwyg:
        MilkdownEditor(
            content: $editorState.content,
            focusModeEnabled: $editorState.focusModeEnabled,
            onContentChange: { _ in
                // Content change handling
            },
            onStatsChange: { words, characters in
                editorState.updateStats(words: words, characters: characters)
            }
        )
    case .source:
        CodeMirrorEditor(
            content: $editorState.content,
            onContentChange: { _ in
                // Content change handling
            },
            onStatsChange: { words, characters in
                editorState.updateStats(words: words, characters: characters)
            }
        )
    }
}
```

**Step 3: Build and verify**

Run: `xcodebuild -scheme "final final" -destination 'platform=macOS' build`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add "final final/ViewState/EditorViewState.swift" "final final/Views/ContentView.swift"
git commit -m "feat: integrate CodeMirror editor with mode toggle"
```

---

## Task 5: Update Version Numbers

**Files:**
- Modify: `web/codemirror/package.json` (already done in Task 1)
- Modify: `web/milkdown/package.json`
- Modify: `project.yml`

**Step 1: Update milkdown package.json version**

Change version to `0.1.5`

**Step 2: Update project.yml version**

Change `CURRENT_PROJECT_VERSION` to `0.1.5`

**Step 3: Commit**

```bash
git add web/milkdown/package.json project.yml
git commit -m "chore: bump version to 0.1.5 for Phase 1.5"
```

---

## Task 6: End-to-End Verification

**Manual Testing Checklist:**

1. **Build and launch app**
   - `cd web && pnpm install && pnpm build`
   - `xcodegen generate && xcodebuild -scheme "final final" -destination 'platform=macOS' build`
   - Run the app

2. **Verify WYSIWYG mode still works**
   - [ ] Milkdown editor loads and displays content
   - [ ] Typing works
   - [ ] Focus mode toggle (Cmd+Shift+F) works

3. **Verify Source mode**
   - [ ] Press Cmd+/ to toggle to source mode
   - [ ] CodeMirror editor loads and displays markdown
   - [ ] Typing works
   - [ ] Line numbers visible
   - [ ] Syntax highlighting for markdown

4. **Verify formatting shortcuts in source mode**
   - [ ] Cmd+B wraps selection in `**bold**`
   - [ ] Cmd+I wraps selection in `*italic*`
   - [ ] Cmd+K inserts link `[text](url)`

5. **Verify mode toggle**
   - [ ] Toggle back and forth preserves content
   - [ ] No data loss on multiple toggles

6. **Verify themes**
   - [ ] Theme switching works in both modes
   - [ ] Cmd+Opt+1-5 changes editor colors in source mode

7. **Verify stats**
   - [ ] Word count updates in status bar
   - [ ] Character count updates in status bar

---

## Task 7: Swift Code Review

**After all tasks complete, run swift-engineering code review:**

```
Task(subagent_type="swift-engineering:swift-code-reviewer", prompt="Review the Swift code in Phase 1.5 implementation, specifically:
- CodeMirrorEditor.swift
- Changes to EditorViewState.swift
- Changes to ContentView.swift

Check for:
1. Thread safety (MainActor, async callbacks)
2. Memory management (weak references, cleanup)
3. GRDB patterns if applicable
4. SwiftUI best practices
5. Code style consistency with existing codebase")
```

---

## Verification Summary

After completing all tasks:

- [ ] CodeMirror 6 editor loads in source mode
- [ ] Markdown syntax highlighting works
- [ ] Cmd+/ toggles between WYSIWYG and Source modes
- [ ] Content preserved on mode toggle
- [ ] Cmd+B/I/K formatting shortcuts work in source mode
- [ ] Theme switching works in source mode
- [ ] Word/character counts update correctly
- [ ] No console errors in Web Inspector
- [ ] Swift code passes review
- [ ] LESSONS-LEARNED.md updated with Phase 1.1-1.4 fixes
