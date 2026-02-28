# Plan: Fix CodeMirror Blank Display — Block Decorations From ViewPlugin

## Context

CodeMirror displays blank when image markdown `![alt](media/...)` is present. The diagnostic logging we added revealed the actual JS exception:

```
RangeError: Block decorations may not be specified via plugins
```

This is a well-known CM6 constraint: **block-level decorations** (widgets with `block: true`) must come from a `StateField`, not a `ViewPlugin`. The current `image-preview-plugin.ts` uses `ViewPlugin.fromClass(...)` with `Decoration.widget({ block: true })`, which CM6 rejects at runtime.

## Root Cause

In `web/codemirror/src/image-preview-plugin.ts`:
- Line 122: `ViewPlugin.fromClass(...)` — creates a ViewPlugin
- Line 110: `Decoration.widget({ block: true, ... })` — creates a block decoration
- CM6 throws `RangeError` because block decorations are forbidden from ViewPlugins

## Fix

### File: `web/codemirror/src/image-preview-plugin.ts`

Change from `ViewPlugin` to `StateField` for providing decorations. Three changes:

**A. Update imports** — Replace `ViewPlugin`/`ViewUpdate` with `StateField`/`EditorState`:

```typescript
import { RangeSetBuilder, StateField, type EditorState } from '@codemirror/state';
import {
  Decoration,
  type DecorationSet,
  EditorView,
  WidgetType,
} from '@codemirror/view';
```

**B. Change `buildDecorations` signature** — It only needs `state.doc`, not the full `EditorView`:

```typescript
function buildDecorations(state: EditorState): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const doc = state.doc;
  // ... rest unchanged
```

**C. Remove `view` from `ImagePreviewWidget`** — Use DOM traversal + `EditorView.findFromDOM()` in `onload`/`onerror` instead. Use `wrapper.closest('.cm-editor')` to guard against cached images where `onload` fires before full DOM attachment:

```typescript
class ImagePreviewWidget extends WidgetType {
  private src: string;
  private alt: string;

  constructor(src: string, alt: string) {
    super();
    this.src = src;
    this.alt = alt;
  }

  // In toDOM():
  img.onload = () => {
    const editorRoot = wrapper.closest('.cm-editor');
    if (editorRoot) {
      EditorView.findFromDOM(editorRoot as HTMLElement)?.requestMeasure();
    }
  };

  img.onerror = () => {
    wrapper.textContent = `[Image not found: ${this.src}]`;
    wrapper.style.color = 'var(--text-secondary, #888)';
    wrapper.style.fontStyle = 'italic';
    wrapper.style.padding = '4px 0';
    const editorRoot = wrapper.closest('.cm-editor');
    if (editorRoot) {
      EditorView.findFromDOM(editorRoot as HTMLElement)?.requestMeasure();
    }
  };
```

**D. Replace `ViewPlugin.fromClass(...)` with `StateField.define(...)`:**

```typescript
export function imagePreviewPlugin() {
  return StateField.define<DecorationSet>({
    create(state) {
      return buildDecorations(state);
    },
    update(value, tr) {
      if (tr.docChanged) {
        return buildDecorations(tr.state);
      }
      return value;
    },
    provide: (f) => EditorView.decorations.from(f),
  });
}
```

The return type is still a CM6 `Extension`, so the call site in `main.ts:243` (`imagePreviewPlugin()`) requires no changes.

## Fix 2: Diagnostic Logging Regression

### File: `final final/Editors/CodeMirrorCoordinator+Handlers.swift`

**A. Line ~258 — `as? NSError` narrows error matching (regression)**

The recent diagnostic change used `if let error = error as? NSError`, which skips the `lastPushedContent = ""` reset if the error isn't `NSError`. Fix: use `if let error` for the guard, `error as NSError` (unconditional bridging) for logging:

```swift
webView.evaluateJavaScript(script) { [weak self] _, error in
    if let error {
        #if DEBUG
        let nsError = error as NSError
        print("[CodeMirrorEditor] Initialize error: \(nsError.localizedDescription)")
        if let message = nsError.userInfo["WKJavaScriptExceptionMessage"] {
            print("[CodeMirrorEditor] JS Exception: \(message)")
        }
        if let line = nsError.userInfo["WKJavaScriptExceptionLineNumber"] {
            print("[CodeMirrorEditor] JS Line: \(line)")
        }
        if let column = nsError.userInfo["WKJavaScriptExceptionColumnNumber"] {
            print("[CodeMirrorEditor] JS Column: \(column)")
        }
        if let sourceURL = nsError.userInfo["WKJavaScriptExceptionSourceURL"] {
            print("[CodeMirrorEditor] JS Source: \(sourceURL)")
        }
        #endif
        self?.lastPushedContent = ""
    }
    self?.cursorPositionToRestoreBinding.wrappedValue = nil
}
```

**B. Lines 143-150 — Unguarded debug logging prints user content in release builds**

Wrap in `#if DEBUG`:

```swift
#if DEBUG
print("[CM-SAVE+NOTIFY] getContent returned length=\(content.count)")
print("[CM-SAVE+NOTIFY] Preview: \(String(content.prefix(300)))")
let lines = content.components(separatedBy: "\n")
for (i, line) in lines.enumerated() where line.hasPrefix("#") {
    let nextLine = i + 1 < lines.count ? lines[i + 1] : "(EOF)"
    print("[CM-SAVE+NOTIFY] Heading at line \(i): \"\(line.prefix(80))\" next: \"\(nextLine.prefix(40))\"")
}
#endif
```

## Files Modified

| File | Change |
|------|--------|
| `web/codemirror/src/image-preview-plugin.ts` | `ViewPlugin` → `StateField` for block decorations; use `wrapper.closest('.cm-editor')` for `findFromDOM` |
| `final final/Editors/CodeMirrorCoordinator+Handlers.swift` | Fix `as? NSError` → `if let error` + `as NSError`; wrap debug logging in `#if DEBUG` |

## Verification

1. `cd web && pnpm build` — should compile without errors
2. Build in Xcode
3. Open project with image content
4. Switch to CodeMirror (Cmd+/) — should render content with image preview (not blank)
5. Xcode console should NOT show `JS Exception: RangeError`
6. Switch back to Milkdown (Cmd+/) — content preserved
7. Verify no `[CM-SAVE+NOTIFY]` logging in release builds
