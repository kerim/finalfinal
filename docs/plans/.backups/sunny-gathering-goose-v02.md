# Phase 1.5: CodeMirror 6 Source Editor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Integrate CodeMirror 6 as the source mode editor with full markdown support, cursor position preservation on mode toggle, and formatting shortcuts.

**Architecture:** Mirror the MilkdownEditor pattern - WKWebView wrapper with 500ms polling, same window.FinalFinal API, theme injection via CSS variables. Use IIFE build format (not ES modules) for WKWebView compatibility.

**Tech Stack:** CodeMirror 6 (codemirror package with basicSetup), @codemirror/lang-markdown, Vite IIFE library build, SwiftUI NSViewRepresentable

---

## Pre-Implementation: Update LESSONS-LEARNED.md

Before starting Phase 1.5, update `docs/LESSONS-LEARNED.md` with bug fixes discovered in Phases 1.1-1.4.

**File:** `docs/LESSONS-LEARNED.md`

**Add these sections after the existing content:**

```markdown
---

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

---

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

---

## String Handling

### Character Count vs Byte Count

Use `.count` for Swift String indices, `.utf8.count` only for bytes:

```swift
// For character positions (outline offsets)
let offset = text.prefix(position).count  // Right

// Only for byte-level operations (network, files)
let byteSize = text.utf8.count
```

Test with multi-byte characters (emoji, accents).

---

## WKWebView / JavaScript

### IIFE Format Required

ES modules don't work reliably in WKWebView with custom URL schemes. Build web editors as IIFE:

```typescript
// vite.config.ts
lib: {
  entry: resolve(__dirname, 'src/main.ts'),
  formats: ['iife'],
}
```

### Register API Before Async Init

Register `window.FinalFinal` before async initialization to avoid race conditions:

```typescript
// Register API immediately (synchronous)
window.FinalFinal = { ... };

// Then start async init
initEditor().then(...);
```

### Content Feedback Loop Prevention

Track timestamp to prevent Swift pushing content it just received:

```swift
private var lastReceivedFromEditor: Date = .distantPast

func shouldPushContent(_ newContent: String) -> Bool {
    let timeSinceLastReceive = Date().timeIntervalSince(lastReceivedFromEditor)
    if timeSinceLastReceive < 0.6 { return false }
    return newContent != lastPushedContent
}
```

---

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

---

## Colors

### Use sRGB for Portable Colors

`deviceRGB` varies by display. Use sRGB for web/cross-platform:

```swift
nsColor.usingColorSpace(.sRGB)  // Right - consistent across displays
nsColor.usingColorSpace(.deviceRGB)  // Wrong - display-dependent
```
```

**Commit after updating:**

```bash
git add docs/LESSONS-LEARNED.md
git commit -m "docs: add lessons learned from Phases 1.1-1.4"
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
    "codemirror": "^6.0.1",
    "@codemirror/lang-markdown": "^6.2.0",
    "@codemirror/language-data": "^6.4.0"
  },
  "devDependencies": {
    "typescript": "^5.3.0",
    "vite": "^5.0.0"
  }
}
```

**Step 2: Install dependencies**

Run: `cd web/codemirror && pnpm install` (with sandbox disabled for network access)

Expected: Dependencies installed successfully

**Step 3: Commit**

```bash
git add web/codemirror/package.json web/codemirror/pnpm-lock.yaml
git commit -m "chore: add CodeMirror 6 dependencies for Phase 1.5"
```

---

## Task 2: Update Vite Config for IIFE Build

**Files:**
- Modify: `web/codemirror/vite.config.ts`

**Step 1: Replace vite.config.ts with IIFE library build (matching Milkdown pattern)**

```typescript
import { defineConfig, Plugin } from 'vite';
import { resolve } from 'path';
import { writeFileSync } from 'fs';

// Plugin to generate static HTML without type="module"
function generateHtml(): Plugin {
  return {
    name: 'generate-html',
    closeBundle() {
      const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>CodeMirror Editor</title>
  <style>
    :root {
      --editor-background: #ffffff;
      --editor-text: #1a1a1a;
      --editor-selection: rgba(0, 122, 255, 0.2);
      --editor-caret: #007aff;
      --editor-header: #1a1a1a;
      --editor-link: #007aff;
      --editor-url: #666666;
      --editor-code-bg: #f5f5f5;
    }
    html, body {
      margin: 0;
      padding: 0;
      height: 100%;
      overflow: hidden;
      background: var(--editor-background);
      color: var(--editor-text);
      font-family: -apple-system, BlinkMacSystemFont, sans-serif;
    }
    #editor {
      height: 100%;
      width: 100%;
    }
  </style>
  <link rel="stylesheet" href="/codemirror.css">
</head>
<body>
  <div id="editor"></div>
  <script src="/codemirror.js"></script>
</body>
</html>`;
      const outDir = resolve(__dirname, '../../final final/Resources/editor/codemirror');
      writeFileSync(resolve(outDir, 'codemirror.html'), html);
      console.log('Generated codemirror.html (no type="module")');
    },
  };
}

export default defineConfig({
  build: {
    outDir: '../../final final/Resources/editor/codemirror',
    emptyOutDir: true,
    // Build as library in IIFE format (not ES modules) for WKWebView compatibility
    lib: {
      entry: resolve(__dirname, 'src/main.ts'),
      name: 'CodeMirrorEditor',
      fileName: () => 'codemirror.js',
      formats: ['iife'],
    },
    rollupOptions: {
      output: {
        assetFileNames: 'codemirror.[ext]',
      },
    },
  },
  plugins: [generateHtml()],
});
```

**Step 2: Verify build works**

Run: `cd web/codemirror && pnpm build`

Expected: Build succeeds, outputs `codemirror.js`, `codemirror.css`, `codemirror.html`

**Step 3: Commit**

```bash
git add web/codemirror/vite.config.ts
git commit -m "chore: update CodeMirror vite config for IIFE build"
```

---

## Task 3: Implement CodeMirror Editor (TypeScript)

**Files:**
- Modify: `web/codemirror/src/main.ts`
- Create: `web/codemirror/src/styles.css`

**Step 1: Create styles.css**

```css
/* CodeMirror Editor Styles */

* {
  box-sizing: border-box;
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
  background: var(--editor-selection, rgba(0, 122, 255, 0.2)) !important;
}

.cm-editor .cm-gutters {
  background: var(--editor-background, #ffffff);
  border-right: 1px solid var(--editor-gutter-border, #e0e0e0);
  color: var(--editor-gutter-text, #999);
}

.cm-editor .cm-activeLineGutter {
  background: var(--editor-active-line, rgba(0, 0, 0, 0.05));
}

.cm-editor .cm-activeLine {
  background: var(--editor-active-line, rgba(0, 0, 0, 0.03));
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
.cm-code, .cm-monospace {
  background: var(--editor-code-bg, #f5f5f5);
  border-radius: 3px;
  padding: 0 4px;
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, monospace;
}
```

**Step 2: Implement main.ts with full CodeMirror setup**

```typescript
// CodeMirror 6 Source Editor for final final
// Uses window.FinalFinal API for Swift ↔ JS communication

// Debug state - register immediately before any async operations
const debugState = {
  scriptLoaded: true,
  importsComplete: false,
  apiRegistered: false,
  initStarted: false,
  initSteps: [] as string[],
  errors: [] as string[],
  editorCreated: false,
};
(window as any).__CODEMIRROR_DEBUG__ = debugState;
(window as any).__CODEMIRROR_SCRIPT_STARTED__ = Date.now();
console.log('[CodeMirror] SCRIPT TAG EXECUTED - timestamp:', Date.now());

import { EditorView, basicSetup } from 'codemirror';
import { EditorState, StateEffect } from '@codemirror/state';
import { keymap } from '@codemirror/view';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { languages } from '@codemirror/language-data';
import './styles.css';

debugState.importsComplete = true;
debugState.initSteps.push('Imports completed');
console.log('[CodeMirror] IMPORTS COMPLETED');

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
  }
}

let editorView: EditorView | null = null;

function wrapSelection(wrapper: string) {
  if (!editorView) return false;
  const { from, to } = editorView.state.selection.main;
  const selected = editorView.state.sliceDoc(from, to);
  const wrapped = wrapper + selected + wrapper;
  editorView.dispatch({
    changes: { from, to, insert: wrapped },
    selection: { anchor: from + wrapper.length, head: to + wrapper.length }
  });
  return true;
}

function insertLink() {
  if (!editorView) return false;
  const { from, to } = editorView.state.selection.main;
  const selected = editorView.state.sliceDoc(from, to);
  const linkText = selected || 'link text';
  const inserted = `[${linkText}](url)`;
  editorView.dispatch({
    changes: { from, to, insert: inserted },
    selection: { anchor: from + 1, head: from + 1 + linkText.length }
  });
  return true;
}

function countWords(text: string): number {
  return text.split(/\s+/).filter(w => w.length > 0).length;
}

// Register window.FinalFinal API IMMEDIATELY (before async init)
window.FinalFinal = {
  setContent(markdown: string) {
    if (!editorView) {
      debugState.initSteps.push('setContent called before editor ready, queued');
      return;
    }
    editorView.dispatch({
      changes: { from: 0, to: editorView.state.doc.length, insert: markdown }
    });
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
    const safePos = Math.min(Math.max(0, pos), editorView.state.doc.length);
    editorView.dispatch({
      selection: { anchor: safePos }
    });
    editorView.focus();
    console.log('[CodeMirror] setCursorPosition:', safePos);
  }
};

debugState.apiRegistered = true;
debugState.initSteps.push('API registered');
console.log('[CodeMirror] window.FinalFinal API registered');

function initEditor() {
  debugState.initStarted = true;
  debugState.initSteps.push('initEditor() started');
  console.log('[CodeMirror] INIT STEP 1: Function entered');

  const container = document.getElementById('editor');
  debugState.initSteps.push(`#editor element = ${container ? 'found' : 'NOT FOUND'}`);
  console.log('[CodeMirror] INIT STEP 2: querySelector result:', container);

  if (!container) {
    const error = 'Editor container #editor not found';
    debugState.errors.push(error);
    console.error('[CodeMirror] INIT FAILED:', error);
    return;
  }

  try {
    debugState.initSteps.push('Creating EditorState');
    console.log('[CodeMirror] INIT STEP 3: Creating editor state');

    const state = EditorState.create({
      doc: '',
      extensions: [
        basicSetup,
        markdown({ base: markdownLanguage, codeLanguages: languages }),
        keymap.of([
          { key: 'Mod-b', run: () => wrapSelection('**') },
          { key: 'Mod-i', run: () => wrapSelection('*') },
          { key: 'Mod-k', run: () => insertLink() },
        ]),
        EditorView.lineWrapping,
        EditorView.theme({
          '&': { height: '100%' },
          '.cm-scroller': { overflow: 'auto' }
        })
      ]
    });

    debugState.initSteps.push('Creating EditorView');
    console.log('[CodeMirror] INIT STEP 4: Creating editor view');

    editorView = new EditorView({
      state,
      parent: container
    });

    debugState.editorCreated = true;
    debugState.initSteps.push('Editor created successfully');
    console.log('[CodeMirror] INIT STEP 5: Editor initialized successfully');

  } catch (e) {
    const errorMsg = e instanceof Error ? e.message : String(e);
    debugState.errors.push(`Editor creation failed: ${errorMsg}`);
    console.error('[CodeMirror] INIT FAILED:', e);
  }
}

// Initialize on DOM ready
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', initEditor);
} else {
  initEditor();
}
```

**Step 3: Delete the old codemirror.html (will be generated by Vite)**

Remove `web/codemirror/codemirror.html` - the Vite plugin generates it.

**Step 4: Build the editor**

Run: `cd web/codemirror && pnpm build`

Expected: Build succeeds, files in `final final/Resources/editor/codemirror/`

**Step 5: Commit**

```bash
git add web/codemirror/src/
git commit -m "feat: implement CodeMirror 6 editor with markdown support"
```

---

## Task 4: Add Cursor Position APIs to Milkdown

**Files:**
- Modify: `web/milkdown/src/main.ts`

**Step 1: Add getCursorPosition and setCursorPosition to Milkdown's window.FinalFinal**

In the type declaration, add:

```typescript
declare global {
  interface Window {
    FinalFinal: {
      // ... existing methods ...
      getCursorPosition: () => number;
      setCursorPosition: (pos: number) => void;
    };
  }
}
```

In the window.FinalFinal object, add these methods:

```typescript
getCursorPosition(): number {
  if (!editorInstance) return 0;
  const view = editorInstance.ctx.get(editorViewCtx);
  return view.state.selection.from;
},

setCursorPosition(pos: number) {
  if (!editorInstance) return;
  const view = editorInstance.ctx.get(editorViewCtx);
  const safePos = Math.min(Math.max(0, pos), view.state.doc.content.size - 1);
  try {
    const selection = Selection.near(view.state.doc.resolve(safePos));
    view.dispatch(view.state.tr.setSelection(selection));
    view.focus();
    console.log('[Milkdown] setCursorPosition:', safePos);
  } catch (e) {
    console.warn('[Milkdown] setCursorPosition failed:', e);
  }
},
```

**Step 2: Rebuild Milkdown**

Run: `cd web/milkdown && pnpm build`

Expected: Build succeeds

**Step 3: Commit**

```bash
git add web/milkdown/src/main.ts
git commit -m "feat: add cursor position APIs to Milkdown for mode toggle"
```

---

## Task 5: Create CodeMirrorEditor.swift

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

            webView.evaluateJavaScript("typeof window.__CODEMIRROR_SCRIPT_STARTED__") { result, _ in
                print("[CodeMirrorEditor] JS script check: \(result ?? "nil")")
            }

            webView.evaluateJavaScript("typeof window.FinalFinal") { result, _ in
                print("[CodeMirrorEditor] window.FinalFinal type: \(result ?? "nil")")
            }

            webView.evaluateJavaScript("window.__CODEMIRROR_DEBUG__ ? JSON.stringify(window.__CODEMIRROR_DEBUG__) : 'not defined'") { result, _ in
                print("[CodeMirrorEditor] Debug state: \(result ?? "nil")")
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

**Step 2: Regenerate Xcode project and verify build**

Run: `xcodegen generate && xcodebuild -scheme "final final" -destination 'platform=macOS' build`

Expected: Build succeeds

**Step 3: Commit**

```bash
git add "final final/Editors/CodeMirrorEditor.swift"
git commit -m "feat: add CodeMirrorEditor Swift wrapper"
```

---

## Task 6: Update ContentView for Mode Toggle

**Files:**
- Modify: `final final/Views/ContentView.swift`

**Step 1: Replace the source mode placeholder with CodeMirrorEditor**

Change the `editorView` computed property:

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

**Step 2: Build and verify**

Run: `xcodebuild -scheme "final final" -destination 'platform=macOS' build`

Expected: Build succeeds

**Step 3: Commit**

```bash
git add "final final/Views/ContentView.swift"
git commit -m "feat: integrate CodeMirror editor with mode toggle"
```

---

## Task 7: Update Version Numbers

**Files:**
- Modify: `web/milkdown/package.json`
- Modify: `project.yml`

**Step 1: Update milkdown package.json version to 0.1.5**

**Step 2: Update project.yml CURRENT_PROJECT_VERSION to 0.1.5**

**Step 3: Commit**

```bash
git add web/milkdown/package.json project.yml
git commit -m "chore: bump version to 0.1.5 for Phase 1.5"
```

---

## Task 8: End-to-End Verification

**Build Steps:**

```bash
# Build web editors
cd web/codemirror && pnpm install && pnpm build
cd ../milkdown && pnpm build
cd ../..

# Regenerate and build Xcode project
xcodegen generate
xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

**Manual Testing Checklist:**

1. **WYSIWYG mode still works**
   - [ ] Milkdown editor loads and displays content
   - [ ] Typing works
   - [ ] Focus mode toggle (Cmd+Shift+F) works

2. **Source mode works**
   - [ ] Press Cmd+/ to toggle to source mode
   - [ ] CodeMirror editor loads and displays markdown
   - [ ] Line numbers visible
   - [ ] Syntax highlighting for markdown headers, bold, italic, links

3. **Formatting shortcuts in source mode**
   - [ ] Cmd+B wraps selection in `**bold**`
   - [ ] Cmd+I wraps selection in `*italic*`
   - [ ] Cmd+K inserts link `[text](url)`

4. **Mode toggle**
   - [ ] Toggle back and forth preserves content
   - [ ] No data loss on multiple toggles

5. **Themes**
   - [ ] Cmd+Opt+1-5 changes colors in both modes
   - [ ] Background and text colors apply correctly

6. **Stats**
   - [ ] Word count updates in status bar
   - [ ] Character count updates in status bar

7. **No errors**
   - [ ] Safari Web Inspector shows no JS errors
   - [ ] Xcode console shows no Swift errors

---

## Task 9: Swift Code Review

**After all tasks complete, run swift-engineering code review:**

```
Task(subagent_type="swift-engineering:swift-code-reviewer", prompt="Review the Swift code in Phase 1.5 implementation:
- CodeMirrorEditor.swift
- Changes to ContentView.swift

Check for:
1. Thread safety (MainActor, async callbacks, cleanup flags)
2. Memory management (weak references, timer invalidation)
3. Pattern consistency with MilkdownEditor.swift
4. SwiftUI best practices
5. Error handling")
```

---

## Critical Files Summary

| File | Action | Purpose |
|------|--------|---------|
| `docs/LESSONS-LEARNED.md` | Modify | Add Phase 1.1-1.4 learnings |
| `web/codemirror/package.json` | Modify | Add CodeMirror dependencies |
| `web/codemirror/vite.config.ts` | Modify | IIFE build config |
| `web/codemirror/src/main.ts` | Modify | Full CodeMirror implementation |
| `web/codemirror/src/styles.css` | Create | Editor styles |
| `web/milkdown/src/main.ts` | Modify | Add cursor position APIs |
| `final final/Editors/CodeMirrorEditor.swift` | Create | Swift WKWebView wrapper |
| `final final/Views/ContentView.swift` | Modify | Integrate CodeMirror |
| `web/milkdown/package.json` | Modify | Version bump |
| `project.yml` | Modify | Version bump |

---

## Verification Summary

After completing all tasks:

- [ ] LESSONS-LEARNED.md updated with Phase 1.1-1.4 fixes
- [ ] CodeMirror 6 editor loads in source mode
- [ ] Markdown syntax highlighting works
- [ ] Cmd+/ toggles between WYSIWYG and Source modes
- [ ] Content preserved on mode toggle
- [ ] Cmd+B/I/K formatting shortcuts work in source mode
- [ ] Theme switching works in both modes
- [ ] Word/character counts update correctly
- [ ] No console errors in Web Inspector or Xcode
- [ ] Swift code passes review
