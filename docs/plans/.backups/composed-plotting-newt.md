# Phase 1.4: Milkdown Editor Integration

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Integrate Milkdown WYSIWYG editor with WKWebView wrapper and 500ms polling for content synchronization.

**Architecture:** Swift WKWebView loads bundled Milkdown via `editor://` URL scheme. Content sync uses 500ms polling of `window.FinalFinal.getContent()` with feedback loop prevention. Focus mode uses ProseMirror Decorations (not DOM manipulation).

**Tech Stack:** Swift/SwiftUI, WKWebView, Milkdown 7.x, ProseMirror, Vite

---

## Version Updates

Before starting, update versions:
- `project.yml`: `CURRENT_PROJECT_VERSION: "0.1.4"`
- `web/milkdown/package.json`: `"version": "0.1.4"`

---

## Part 1: Web Layer (Tasks 1-5)

### Task 1: Add Milkdown dependencies

**Files:**
- Modify: `web/milkdown/package.json`

**Step 1: Update package.json**

```json
{
  "name": "@final-final/milkdown-editor",
  "version": "0.1.4",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build"
  },
  "dependencies": {
    "@milkdown/kit": "^7.8.0",
    "@milkdown/components": "^7.8.0"
  },
  "devDependencies": {
    "typescript": "^5.3.0",
    "vite": "^5.0.0"
  }
}
```

**Step 2: Install dependencies**

Run: `cd "/Users/niyaro/Documents/Code/final final/web/milkdown" && pnpm install`

**Step 3: Commit**

```bash
git add web/milkdown/package.json web/milkdown/pnpm-lock.yaml
git commit -m "chore: Add Milkdown dependencies"
```

---

### Task 2: Create focus mode plugin

**Files:**
- Create: `web/milkdown/src/focus-mode-plugin.ts`

**Step 1: Create the plugin file**

```typescript
// Focus mode plugin using ProseMirror Decoration system
// NOT DOM manipulation - critical for ProseMirror reconciliation

import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import { Decoration, DecorationSet } from '@milkdown/kit/prose/view';

export const focusModePluginKey = new PluginKey('focus-mode');

let focusModeEnabled = false;

export function setFocusModeEnabled(enabled: boolean) {
  focusModeEnabled = enabled;
}

export function isFocusModeEnabled(): boolean {
  return focusModeEnabled;
}

export const focusModePlugin = new Plugin({
  key: focusModePluginKey,
  props: {
    decorations(state) {
      if (!focusModeEnabled) {
        return DecorationSet.empty;
      }

      const { selection, doc } = state;
      const currentPos = selection.from;
      const decorations: Decoration[] = [];

      // Find the block containing the cursor
      let currentBlockStart = 0;
      let currentBlockEnd = doc.content.size;

      doc.descendants((node, pos) => {
        if (node.isBlock && node.isTextblock) {
          const nodeEnd = pos + node.nodeSize;
          if (currentPos >= pos && currentPos <= nodeEnd) {
            currentBlockStart = pos;
            currentBlockEnd = nodeEnd;
          }
        }
        return true;
      });

      // Add 'dimmed' decoration to all blocks except current
      doc.descendants((node, pos) => {
        if (node.isBlock && node.isTextblock) {
          const nodeEnd = pos + node.nodeSize;
          const isCurrent = pos === currentBlockStart;

          if (!isCurrent) {
            decorations.push(
              Decoration.node(pos, nodeEnd, { class: 'ff-dimmed' })
            );
          }
        }
        return true;
      });

      return DecorationSet.create(doc, decorations);
    },
  },
});
```

**Step 2: Commit**

```bash
git add web/milkdown/src/focus-mode-plugin.ts
git commit -m "feat: Add focus mode plugin with ProseMirror Decorations"
```

---

### Task 3: Create editor styles

**Files:**
- Create: `web/milkdown/src/styles.css`

**Step 1: Create styles file**

```css
/* Editor styles with CSS variable support for theming */
:root {
  --editor-bg: #ffffff;
  --editor-text: #000000;
  --editor-selection: rgba(0, 122, 255, 0.3);
  --accent-color: #007aff;
}

html, body {
  margin: 0;
  padding: 0;
  height: 100%;
  background: var(--editor-bg);
  color: var(--editor-text);
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
}

#editor {
  padding: 24px 48px;
  min-height: 100%;
  outline: none;
}

.milkdown { background: var(--editor-bg); color: var(--editor-text); }
.milkdown .editor { outline: none; }
.ProseMirror ::selection { background: var(--editor-selection); }

/* Focus mode dimming */
.ff-dimmed { opacity: 0.3; transition: opacity 0.2s ease; }

/* Typography */
.milkdown h1, .milkdown h2, .milkdown h3 { color: var(--editor-text); margin-top: 1.5em; margin-bottom: 0.5em; }
.milkdown h1 { font-size: 2em; }
.milkdown h2 { font-size: 1.5em; }
.milkdown h3 { font-size: 1.25em; }
.milkdown p { margin: 0.75em 0; line-height: 1.6; }

/* Code */
.milkdown code { background: rgba(128, 128, 128, 0.1); padding: 0.2em 0.4em; border-radius: 3px; font-family: 'SF Mono', Menlo, Monaco, monospace; }
.milkdown pre { background: rgba(128, 128, 128, 0.1); padding: 1em; border-radius: 6px; overflow-x: auto; }

/* Links and lists */
.milkdown a { color: var(--accent-color); text-decoration: none; }
.milkdown a:hover { text-decoration: underline; }
.milkdown ul, .milkdown ol { padding-left: 1.5em; }
.milkdown li { margin: 0.25em 0; }
.milkdown blockquote { border-left: 4px solid var(--accent-color); margin: 1em 0; padding-left: 1em; opacity: 0.9; }
```

**Step 2: Commit**

```bash
git add web/milkdown/src/styles.css
git commit -m "feat: Add editor styles with theme CSS variables"
```

---

### Task 4: Implement Milkdown editor

**Files:**
- Modify: `web/milkdown/src/main.ts` (replace stub)

**Step 1: Replace main.ts with full implementation**

```typescript
// Milkdown WYSIWYG Editor for final final
// Uses window.FinalFinal API for Swift ↔ JS communication

import { Editor, defaultValueCtx, editorViewCtx, parserCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { history } from '@milkdown/kit/plugin/history';
import { getMarkdown } from '@milkdown/kit/utils';
import { Slice } from '@milkdown/kit/prose/model';
import { Selection } from '@milkdown/kit/prose/state';

import { focusModePlugin, setFocusModeEnabled } from './focus-mode-plugin';
import './styles.css';

console.log('[Milkdown] Initializing editor...');

declare global {
  interface Window {
    FinalFinal: {
      setContent: (markdown: string) => void;
      getContent: () => string;
      setFocusMode: (enabled: boolean) => void;
      getStats: () => { words: number; characters: number };
      scrollToOffset: (offset: number) => void;
      setTheme: (cssVariables: string) => void;
    };
  }
}

let editorInstance: Editor | null = null;
let currentContent = '';
let isSettingContent = false;

async function initEditor() {
  const root = document.getElementById('editor');
  if (!root) {
    console.error('[Milkdown] Editor root element not found');
    return;
  }

  editorInstance = await Editor.make()
    .config((ctx) => {
      ctx.set(defaultValueCtx, '');
    })
    .use(commonmark)
    .use(gfm)
    .use(history)
    .use(focusModePlugin)
    .create();

  root.appendChild(editorInstance.ctx.get(editorViewCtx).dom);

  // Track content changes
  const view = editorInstance.ctx.get(editorViewCtx);
  const originalDispatch = view.dispatch.bind(view);
  view.dispatch = (tr) => {
    originalDispatch(tr);
    if (tr.docChanged && !isSettingContent) {
      currentContent = editorInstance!.action(getMarkdown());
    }
  };

  console.log('[Milkdown] Editor initialized');
}

window.FinalFinal = {
  setContent(markdown: string) {
    if (!editorInstance) {
      currentContent = markdown;
      return;
    }
    if (currentContent === markdown) return;

    isSettingContent = true;
    try {
      editorInstance.action((ctx) => {
        const view = ctx.get(editorViewCtx);
        const parser = ctx.get(parserCtx);
        const doc = parser(markdown);
        if (!doc) return;

        const { from } = view.state.selection;
        let tr = view.state.tr.replace(0, view.state.doc.content.size, new Slice(doc.content, 0, 0));

        const safeFrom = Math.min(from, Math.max(0, doc.content.size - 1));
        try {
          tr = tr.setSelection(Selection.near(tr.doc.resolve(safeFrom)));
        } catch {
          tr = tr.setSelection(Selection.atStart(tr.doc));
        }
        view.dispatch(tr);
      });
      currentContent = markdown;
    } finally {
      isSettingContent = false;
    }
  },

  getContent() {
    return editorInstance ? editorInstance.action(getMarkdown()) : currentContent;
  },

  setFocusMode(enabled: boolean) {
    setFocusModeEnabled(enabled);
    if (editorInstance) {
      const view = editorInstance.ctx.get(editorViewCtx);
      view.dispatch(view.state.tr);
    }
    console.log('[Milkdown] Focus mode:', enabled);
  },

  getStats() {
    const content = this.getContent();
    const words = content.split(/\s+/).filter(w => w.length > 0).length;
    return { words, characters: content.length };
  },

  scrollToOffset(offset: number) {
    if (!editorInstance) return;
    const view = editorInstance.ctx.get(editorViewCtx);
    const pos = Math.min(offset, view.state.doc.content.size - 1);
    try {
      const selection = Selection.near(view.state.doc.resolve(pos));
      view.dispatch(view.state.tr.setSelection(selection).scrollIntoView());
      view.focus();
    } catch (e) {
      console.warn('[Milkdown] scrollToOffset failed:', e);
    }
  },

  setTheme(cssVariables: string) {
    const root = document.documentElement;
    cssVariables.split(';').filter(s => s.trim()).forEach(pair => {
      const [key, value] = pair.split(':').map(s => s.trim());
      if (key && value) root.style.setProperty(key, value);
    });
  },
};

initEditor().catch((e) => console.error('[Milkdown] Init failed:', e));
console.log('[Milkdown] window.FinalFinal API registered');
```

**Step 2: Commit**

```bash
git add web/milkdown/src/main.ts
git commit -m "feat: Implement Milkdown editor with window.FinalFinal API"
```

---

### Task 5: Build web editors

**Step 1: Build**

Run: `cd "/Users/niyaro/Documents/Code/final final/web" && pnpm install && pnpm build`

**Step 2: Verify output**

Check that `final final/Resources/editor/milkdown/milkdown.html` and `milkdown.js` exist.

**Step 3: Commit**

```bash
git add "final final/Resources/editor/"
git commit -m "chore: Build Milkdown editor for bundling"
```

---

## Part 2: Swift Layer (Tasks 6-10)

### Task 6: Create MilkdownEditor wrapper

**Files:**
- Create: `final final/Editors/MilkdownEditor.swift`

**Step 1: Create the WKWebView wrapper**

```swift
//
//  MilkdownEditor.swift
//  final final
//
//  WKWebView wrapper for Milkdown WYSIWYG editor.
//  Uses 500ms polling pattern for content synchronization.
//

import SwiftUI
import WebKit

struct MilkdownEditor: NSViewRepresentable {
    @Binding var content: String
    @Binding var focusModeEnabled: Bool

    let onContentChange: (String) -> Void
    let onStatsChange: (Int, Int) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(EditorSchemeHandler(), forURLScheme: "editor")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator

        #if DEBUG
        webView.isInspectable = true
        #endif

        if let url = URL(string: "editor://milkdown/milkdown.html") {
            webView.load(URLRequest(url: url))
        }

        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastFocusModeState != focusModeEnabled {
            context.coordinator.lastFocusModeState = focusModeEnabled
            context.coordinator.setFocusMode(focusModeEnabled)
        }

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

    @MainActor
    class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?

        private var contentBinding: Binding<String>
        private let onContentChange: (String) -> Void
        private let onStatsChange: (Int, Int) -> Void

        private var pollingTimer: Timer?
        private var lastReceivedFromEditor: Date = .distantPast
        private var lastPushedContent: String = ""

        var lastFocusModeState: Bool = false
        var lastThemeCss: String = ""
        private var isEditorReady = false

        init(content: Binding<String>, onContentChange: @escaping (String) -> Void, onStatsChange: @escaping (Int, Int) -> Void) {
            self.contentBinding = content
            self.onContentChange = onContentChange
            self.onStatsChange = onStatsChange
            super.init()
        }

        deinit { pollingTimer?.invalidate() }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("[MilkdownEditor] WebView finished loading")
            isEditorReady = true
            setContent(contentBinding.wrappedValue)
            setTheme(ThemeManager.shared.cssVariables)
            startPolling()
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
                if let error { print("[MilkdownEditor] setContent error: \(error)") }
            }
        }

        func setFocusMode(_ enabled: Bool) {
            guard isEditorReady, let webView else { return }
            webView.evaluateJavaScript("window.FinalFinal.setFocusMode(\(enabled))") { _, _ in }
        }

        func setTheme(_ cssVariables: String) {
            guard isEditorReady, let webView else { return }
            let escaped = cssVariables.replacingOccurrences(of: "`", with: "\\`")
            webView.evaluateJavaScript("window.FinalFinal.setTheme(`\(escaped)`)") { _, _ in }
        }

        private func startPolling() {
            pollingTimer?.invalidate()
            pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pollContent() }
            }
        }

        private func pollContent() {
            guard isEditorReady, let webView else { return }

            webView.evaluateJavaScript("window.FinalFinal.getContent()") { [weak self] result, _ in
                guard let self, let content = result as? String, content != self.lastPushedContent else { return }
                self.lastReceivedFromEditor = Date()
                self.lastPushedContent = content
                self.contentBinding.wrappedValue = content
                self.onContentChange(content)
            }

            webView.evaluateJavaScript("window.FinalFinal.getStats()") { [weak self] result, _ in
                guard let self, let dict = result as? [String: Any],
                      let words = dict["words"] as? Int, let chars = dict["characters"] as? Int else { return }
                self.onStatsChange(words, chars)
            }
        }
    }
}
```

**Step 2: Commit**

```bash
git add "final final/Editors/MilkdownEditor.swift"
git commit -m "feat: Add MilkdownEditor WKWebView wrapper with polling"
```

---

### Task 7: Update EditorViewState

**Files:**
- Modify: `final final/ViewState/EditorViewState.swift`

**Step 1: Add content and stats methods**

Add after line 21 (`currentSectionName`):

```swift
    // MARK: - Content
    var content: String = ""

    // MARK: - Scroll Request
    var scrollToOffset: Int? = nil

    // MARK: - Stats Update
    func updateStats(words: Int, characters: Int) {
        wordCount = words
        characterCount = characters
    }

    func scrollTo(offset: Int) {
        scrollToOffset = offset
    }

    func clearScrollRequest() {
        scrollToOffset = nil
    }
```

**Step 2: Commit**

```bash
git add "final final/ViewState/EditorViewState.swift"
git commit -m "feat: Add content and scroll support to EditorViewState"
```

---

### Task 8: Update ContentView

**Files:**
- Modify: `final final/Views/ContentView.swift`

**Step 1: Replace entire file with MilkdownEditor integration**

See Task 8 in exploration output for full implementation. Key changes:
- Add `@State private var editorState = EditorViewState()`
- Replace placeholder detail view with `MilkdownEditor` for WYSIWYG mode
- Add `loadDemoContent()` task on appear
- Wire up `onContentChange` and `onStatsChange` callbacks

**Step 2: Commit**

```bash
git add "final final/Views/ContentView.swift"
git commit -m "feat: Integrate MilkdownEditor into ContentView"
```

---

### Task 9: Update StatusBar

**Files:**
- Modify: `final final/Views/StatusBar.swift`

**Step 1: Update to accept EditorViewState**

Change to accept `let editorState: EditorViewState` parameter and use `editorState.wordCount`, etc.

**Step 2: Commit**

```bash
git add "final final/Views/StatusBar.swift"
git commit -m "feat: Update StatusBar to display live editor statistics"
```

---

### Task 10: Add keyboard shortcuts

**Files:**
- Create: `final final/Commands/EditorCommands.swift`
- Modify: `final final/App/FinalFinalApp.swift`

**Step 1: Create EditorCommands.swift**

```swift
import SwiftUI

struct EditorCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Toggle Focus Mode") {
                NotificationCenter.default.post(name: .toggleFocusMode, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Button("Toggle Editor Mode") {
                NotificationCenter.default.post(name: .toggleEditorMode, object: nil)
            }
            .keyboardShortcut("/", modifiers: .command)
        }
    }
}

extension Notification.Name {
    static let toggleFocusMode = Notification.Name("toggleFocusMode")
    static let toggleEditorMode = Notification.Name("toggleEditorMode")
}
```

**Step 2: Add to FinalFinalApp.swift**

Add `.commands { ThemeCommands(); EditorCommands() }` to WindowGroup.

**Step 3: Commit**

```bash
git add "final final/Commands/EditorCommands.swift" "final final/App/FinalFinalApp.swift"
git commit -m "feat: Add keyboard shortcuts for focus and editor mode"
```

---

## Part 3: Build & Test (Tasks 11-12)

### Task 11: Regenerate Xcode project and build

**Step 1: Regenerate project (new Swift files added)**

Run: `cd "/Users/niyaro/Documents/Code/final final" && xcodegen generate`

**Step 2: Build**

Run: `xcodebuild -scheme "final final" -destination 'platform=macOS' build`

**Step 3: Fix any build errors**

---

### Task 12: Manual verification

Test the following manually:
- [ ] App launches and shows Milkdown editor
- [ ] Demo content displays in editor
- [ ] Typing updates word count in status bar
- [ ] Cmd+Shift+F toggles focus mode (paragraphs dim/undim)
- [ ] Theme switching works (Cmd+Opt+1-5)
- [ ] No flicker during editing (feedback loop prevention works)
- [ ] Web Inspector accessible (Safari → Develop menu)

---

## Part 4: Code Review (Task 13)

### Task 13: Run swift-code-reviewer

**REQUIRED:** Before marking Phase 1.4 complete, run the code reviewer:

```
Task(subagent_type="swift-engineering:swift-code-reviewer",
     prompt="Review the Swift code added in Phase 1.4:
     - final final/Editors/MilkdownEditor.swift
     - final final/ViewState/EditorViewState.swift
     - final final/Views/ContentView.swift
     - final final/Views/StatusBar.swift
     - final final/Commands/EditorCommands.swift

     Focus on: @MainActor correctness, memory management in WKWebView coordinator (weak references, timer cleanup), proper @Observable usage, feedback loop prevention logic.")
```

Address any issues found before final commit.

---

## Final Commit

After all reviews pass:

```bash
git add .
git commit -m "feat: Phase 1.4 - Milkdown editor integration with focus mode"
```

---

## Verification Checklist

- [ ] Editor loads and displays demo content
- [ ] Typing updates word count in real-time
- [ ] Cmd+Shift+F toggles focus mode
- [ ] Theme switching applies to editor
- [ ] No feedback loops during editing
- [ ] Web Inspector accessible in debug builds
- [ ] Code review completed with no critical issues

---

## Critical Files

| File | Action | Purpose |
|------|--------|---------|
| `web/milkdown/src/main.ts` | Replace | Full Milkdown implementation |
| `web/milkdown/src/focus-mode-plugin.ts` | Create | ProseMirror Decorations for focus |
| `web/milkdown/src/styles.css` | Create | Theme-aware editor styles |
| `final final/Editors/MilkdownEditor.swift` | Create | WKWebView wrapper with 500ms polling |
| `final final/ViewState/EditorViewState.swift` | Modify | Add content property and stats methods |
| `final final/Views/ContentView.swift` | Modify | Integrate MilkdownEditor |
| `final final/Commands/EditorCommands.swift` | Create | Keyboard shortcuts |
