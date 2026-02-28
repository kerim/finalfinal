# Plan Review: Fix CodeMirror 6 Blank Display with Image Markdown

## Diagnosis Validation

**Verdict: The diagnosis is correct.**

The error `RangeError: Block decorations may not be specified via plugins` is caused by the code at `/Users/niyaro/Documents/Code/ff-dev/images/web/codemirror/src/image-preview-plugin.ts`, lines 108-112:

```typescript
Decoration.widget({
  widget: w.widget,
  block: true,   // <-- THIS is the problem
  side: 1,
})
```

This decoration is provided via `ViewPlugin.fromClass(...)` (line 122), which violates a hard constraint in CodeMirror 6. The CM6 changelog entry from v0.19.36 (2021-12-22) states explicitly:

> "Adding block decorations from a plugin now raises an error."

The reason: ViewPlugins run during the view update cycle, and block decorations affect document layout/height calculations. CM6 needs to know about block decorations before the view update starts (during state computation), so they must come from a `StateField`, not a `ViewPlugin`.

## Proposed Fix Assessment

### Change 1: ViewPlugin -> StateField

**Status: Correct and necessary.**

Switching from `ViewPlugin.fromClass(...)` to `StateField.define<DecorationSet>(...)` is the canonical CM6 fix for this error. The StateField approach:
- Computes decorations during state updates (before layout)
- Provides them via `provide: f => EditorView.decorations.from(f)`
- Allows `block: true` on widget decorations

### Change 2: buildDecorations(view: EditorView) -> buildDecorations(state: EditorState)

**Status: Correct and necessary.**

A `StateField.update()` method receives a `Transaction`, which gives access to `tr.state` (an `EditorState`) but not an `EditorView`. The current `buildDecorations` function only uses `view.state.doc` anyway (line 83), so changing the parameter to `EditorState` and using `state.doc` is a straightforward refactor with no loss of functionality.

### Change 3: Remove view parameter from ImagePreviewWidget; use EditorView.findFromDOM

**Status: Correct, but needs careful implementation.**

Currently, `ImagePreviewWidget` stores a direct reference to `EditorView` (line 29) and uses it in two places:
- `img.onload` callback (line 59): `this.view.requestMeasure()`
- `img.onerror` callback (line 67): `this.view.requestMeasure()`

Since a `StateField` does not have access to the `EditorView` at decoration-build time, the widget must obtain the view reference lazily. `EditorView.findFromDOM(wrapper)` is the right approach -- it walks up the DOM from the widget's element to find the owning EditorView.

**Implementation note:** `EditorView.findFromDOM()` must be called from within `toDOM()` callbacks (onload/onerror), NOT during `toDOM()` itself, because the element may not yet be attached to the CM6 DOM tree at construction time. The proposed approach of using it inside the event handlers is correct.

### Change 4: Export still returns Extension type

**Status: Correct.**

The call site in `main.ts` (line 243) is:
```typescript
imagePreviewPlugin(),
```

As long as `imagePreviewPlugin()` continues to return an `Extension` (which a `StateField` is), no changes are needed in `main.ts`.

## Other Plugins: Same Bug Elsewhere?

I reviewed all 8 CodeMirror plugins in the codebase. **None of the other plugins have this bug.** Here is the analysis:

| Plugin | File | Uses ViewPlugin? | Block decorations? | Bug? |
|--------|------|-------------------|-------------------|------|
| anchor-plugin | `anchor-plugin.ts` | Yes (line 103) | No - uses `Decoration.replace({})` | Safe |
| annotation-decoration-plugin | `annotation-decoration-plugin.ts` | Yes (line 97) | No - uses `Decoration.mark(...)` | Safe |
| focus-mode-plugin | `focus-mode-plugin.ts` | Yes (line 25) | No - uses `Decoration.line(...)` | Safe |
| footnote-decoration-plugin | `footnote-decoration-plugin.ts` | Yes (line 111) | No - uses `Decoration.mark(...)` | Safe |
| heading-plugin | `heading-plugin.ts` | Yes (line 27) | No - uses `Decoration.line(...)` | Safe |
| selection-toolbar-plugin | `selection-toolbar-plugin.ts` | Yes (line 111) | No decorations at all | Safe |
| spellcheck-plugin | `spellcheck-plugin.ts` | Yes (line 329) | No - uses `Decoration.mark(...)` | Safe |
| scroll-stabilizer | `scroll-stabilizer.ts` | Yes (line 15) | No decorations at all | Safe |
| **image-preview-plugin** | `image-preview-plugin.ts` | **Yes (line 122)** | **Yes - `block: true` (line 110)** | **BUG** |

The `image-preview-plugin` is the only plugin that uses `block: true` on a widget decoration, and it is the only one using `ViewPlugin` to provide those decorations. All other plugins use only inline marks (`Decoration.mark`), line decorations (`Decoration.line`), or replace decorations (`Decoration.replace`) -- none of which trigger the block decoration constraint.

## Completeness Check: Missing Steps?

The plan covers the core fix. There are a few additional items to consider:

### 1. Widget equality and recreation (Important)

The current `eq()` method (line 38-40) compares `src` and `alt`. After the refactor, the widget no longer stores `view`, so `eq()` remains unchanged. However, with a StateField, decorations are rebuilt on every `docChanged` transaction. The `eq()` method is important here because CM6 uses it to avoid re-creating DOM elements when the widget hasn't changed. The current implementation is correct and should be preserved as-is.

### 2. requestMeasure timing (Important)

With `EditorView.findFromDOM(wrapper)`, the `requestMeasure()` call in `img.onload` will work correctly because:
- By the time `onload` fires, the image element is in the DOM
- `findFromDOM` will traverse up to the `.cm-editor` element
- This is the standard pattern for widgets that need view access

**One edge case:** If the image loads extremely fast (cached/data URI) and `onload` fires before CM6 has inserted the widget into the DOM, `findFromDOM` could return `null`. The implementation should include a null guard:

```typescript
img.onload = () => {
  const view = EditorView.findFromDOM(wrapper);
  view?.requestMeasure();
};
```

### 3. The exceptionSink in main.ts (Observation)

Line 97-103 of `main.ts` has an `exceptionSink` that catches plugin errors and reports them to Swift. This is why the blank display occurs rather than a hard crash -- CM6 catches the RangeError, logs it, but the decorations fail silently, leaving the editor in a broken visual state. After the fix, this sink should no longer receive this error.

### 4. StateField update triggers

The current ViewPlugin rebuilds decorations on `docChanged || viewportChanged` (line 131). With a StateField, the `update` method should only rebuild on `docChanged` because:
- StateField decorations cover the full document, not just the viewport
- `viewportChanged` is a ViewPlugin-specific concern (ViewPlugins can optimize by only decorating visible ranges)

The `buildDecorations` function currently processes the entire document anyway (line 83-84: `doc.toString()`), so removing the viewport trigger is correct and slightly more efficient.

## Risks and Edge Cases

### Risk 1: Image src rewriting (Low risk)
The `projectmedia://` scheme rewriting (line 48) is purely DOM-level and unaffected by the ViewPlugin-to-StateField change.

### Risk 2: Performance with many images (Low risk)
The current implementation already scans the full document text with regex on every document change. Moving to StateField does not change this. If performance becomes an issue with very large documents, incremental decoration updates via `map(tr.changes)` could be added later, but that is outside the scope of this fix.

### Risk 3: Widget DOM lifecycle (Low risk)
CM6 manages widget DOM elements and uses `eq()` to decide whether to reuse or recreate them. The StateField approach does not change this behavior. Widgets will be reused when `eq()` returns true, and recreated otherwise.

### Risk 4: EditorView.findFromDOM availability (Very low risk)
`EditorView.findFromDOM` is a static method available since CM6 0.19.x. It is stable API and well-documented.

## Recommended Implementation

```typescript
import { type EditorState, type Extension, RangeSetBuilder, StateField } from '@codemirror/state';
import {
  Decoration,
  type DecorationSet,
  EditorView,
  WidgetType,
} from '@codemirror/view';

const IMAGE_REGEX = /!\[([^\]]*)\]\((media\/[^)]+)\)/g;

class ImagePreviewWidget extends WidgetType {
  constructor(private src: string, private alt: string) {
    super();
  }

  eq(other: ImagePreviewWidget): boolean {
    return this.src === other.src && this.alt === other.alt;
  }

  toDOM(): HTMLElement {
    const wrapper = document.createElement('div');
    wrapper.className = 'cm-image-preview';

    const img = document.createElement('img');
    img.src = `projectmedia://${this.src.slice(6)}`;
    img.alt = this.alt;
    img.style.maxWidth = '100%';
    img.style.maxHeight = '300px';
    img.style.display = 'block';
    img.style.margin = '4px 0 8px 0';
    img.style.borderRadius = '4px';
    img.draggable = false;

    img.onload = () => {
      const view = EditorView.findFromDOM(wrapper);
      view?.requestMeasure();
    };

    img.onerror = () => {
      wrapper.textContent = `[Image not found: ${this.src}]`;
      wrapper.style.color = 'var(--text-secondary, #888)';
      wrapper.style.fontStyle = 'italic';
      wrapper.style.padding = '4px 0';
      const view = EditorView.findFromDOM(wrapper);
      view?.requestMeasure();
    };

    wrapper.appendChild(img);
    return wrapper;
  }

  ignoreEvent(): boolean {
    return false;
  }
}

function buildDecorations(state: EditorState): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const doc = state.doc;
  const text = doc.toString();
  const widgets: { pos: number; widget: ImagePreviewWidget }[] = [];

  IMAGE_REGEX.lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = IMAGE_REGEX.exec(text)) !== null) {
    const alt = match[1];
    const src = match[2];
    const line = doc.lineAt(match.index);
    widgets.push({
      pos: line.to,
      widget: new ImagePreviewWidget(src, alt),
    });
  }

  widgets.sort((a, b) => a.pos - b.pos);

  for (const w of widgets) {
    builder.add(
      w.pos,
      w.pos,
      Decoration.widget({
        widget: w.widget,
        block: true,
        side: 1,
      })
    );
  }

  return builder.finish();
}

const imagePreviewField = StateField.define<DecorationSet>({
  create(state) {
    return buildDecorations(state);
  },
  update(value, tr) {
    if (!tr.docChanged) return value;
    return buildDecorations(tr.state);
  },
  provide: (f) => EditorView.decorations.from(f),
});

export function imagePreviewPlugin(): Extension {
  return imagePreviewField;
}
```

## Summary

| Question | Answer |
|----------|--------|
| Does the diagnosis match the code? | Yes -- `block: true` + `ViewPlugin` is the exact prohibited combination |
| Will the fix integrate without call-site changes? | Yes -- `imagePreviewPlugin()` still returns `Extension` |
| Same bug in other plugins? | No -- image-preview-plugin is the only one using block decorations |
| Is the plan complete? | Yes, with the minor additions noted above (null guard on findFromDOM, remove viewportChanged trigger) |
| Risks or edge cases? | Low -- null guard on findFromDOM for cached images is the main one to handle |
