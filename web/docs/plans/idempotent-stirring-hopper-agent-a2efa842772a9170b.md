# Review: CM6 Caption Replace Decorations Hypothesis

## Verdict: The Hypothesis is WRONG

The plan at `idempotent-stirring-hopper.md` states:

> "In CM6, replace decorations from StateFields are not applied -- they must come from a ViewPlugin"

This is the **opposite** of what the CM6 documentation says. Moving replace decorations from a StateField to a ViewPlugin will not fix the problem, and in fact would introduce a new violation of CM6's rules.

---

## Evidence from CM6 Documentation

The CM6 reference manual (`EditorView.decorations` facet) states:

> "Decorations can be provided in two ways -- directly, or via a function that takes an editor view. Only decoration sets provided **directly** are allowed to influence the editor's vertical layout structure. The ones provided as functions are called _after_ the new viewport has been computed, and thus **must not introduce block widgets or replacing decorations that cover line breaks**."

The CM6 system guide repeats:

> "Only directly provided decoration sets may influence the vertical block structure of the editor."

### What "directly" and "indirectly" mean

| Method | How it works | CM6 classification | Can use replace/block? |
|--------|-------------|-------------------|----------------------|
| `StateField` with `provide: f => EditorView.decorations.from(f)` | Puts a plain `DecorationSet` value into the facet | **Direct** | YES |
| `ViewPlugin` with `{ decorations: (v) => v.decorations }` | Provides a function `(view) => DecorationSet` | **Indirect** (function from view) | NO (if crossing line breaks) |

### What the current code does

The current `image-preview-plugin.ts` uses a **StateField** (direct). This is the CORRECT approach for:
- `Decoration.replace({})` that spans an entire line + newline (lines 168-174)
- `Decoration.widget({ block: true })` (line 183-186)

Both of these affect vertical layout. Both REQUIRE direct provision (StateField).

### What the anchor-plugin does

The `anchor-plugin.ts` uses a **ViewPlugin** (indirect). This works because its `Decoration.replace({})` calls are **inline** -- they hide `<!-- @sid:UUID -->` text on the same line as a header, never crossing a line break. The documentation permits this because it does not "cover line breaks."

### Why the proposed fix would be counterproductive

Moving the replace decorations to a ViewPlugin would violate CM6's documented constraint, because the image caption replace decoration spans `prevLine.from` to `prevLine.to + 1` -- it crosses a line break (consuming the trailing newline). CM6 explicitly says indirect decorations "must not introduce ... replacing decorations that cover line breaks."

The block widget (`Decoration.widget({ block: true })`) also requires direct provision. So the StateField is the correct home for BOTH decoration types in this plugin.

---

## Alternative Root Cause Analysis

Since the StateField approach is correct per CM6 docs, the "no visible change" must have a different cause. Here are the candidates I investigated:

### 1. RangeSetBuilder ordering issue (LIKELY ROOT CAUSE)

In `buildDecorations()` (lines 190-197), the code sorts decorations and feeds them to a `RangeSetBuilder`. The sorting comparator is:

```typescript
decorations.sort((a, b) => a.from - b.from || (a.to - a.from) - (b.to - b.from));
```

Consider a caption on line N-1 and an image on line N. The replace decoration spans `prevLine.from` to `prevLine.to + 1` (which equals `imageLine.from`). The widget decoration is placed at `line.to` (end of the image line). These have different `from` values, so they sort correctly by position.

However, there is a subtlety: the replace decoration's `to` value (`prevLine.to + 1`) equals `imageLine.from`. This means the replace decoration ends at the exact start of the image line. The widget sits at `imageLine.to`. These should not conflict.

This is probably NOT the issue, but it is worth verifying with diagnostic logging.

### 2. The `console.log` calls not visible (CONFIRMED ISSUE)

The plan document itself notes (section 5) that `console.log()` from WKWebView does NOT appear in Xcode's console. This means the developer may not have been able to verify whether `buildDecorations()` was even running or finding captions. The diagnostic `console.log('[ImagePreview] Found caption:', ...)` on line 164 would be invisible. This alone could explain why the developer concluded "no visible change" -- they may not have had any confirmation the code path was executing at all.

### 3. Content loading order

In `api.ts`, `setContent()` (line 99) calls `dismissImageCaptionPopup()` and then dispatches a full document replacement. After the dispatch, the StateField's `update()` method runs and calls `buildDecorations()` on the new state. This should work correctly.

However, `initialize()` (line 341) calls `setContent()` which replaces the entire document. The StateField's `create()` runs on the initial empty document (no images, no captions), and then the `update()` runs when `setContent()` dispatches the replacement. Since `tr.docChanged` is true, `buildDecorations()` re-runs. This should also work.

### 4. CSS interference

If the replaced range is hidden but there is no CSS for `.cm-image-preview` or the widget is rendering with `display: none` or zero height, it would look like "no visible change." This would be a CSS issue, not a decoration delivery issue.

### 5. The IMAGE_REGEX or CAPTION_REGEX not matching actual content

The `IMAGE_REGEX` is `/!\[([^\]]*)\]\((media\/[^)]+)\)/` -- it specifically requires the path to start with `media/`. If the actual image paths in test documents use a different prefix, no images would be found, and therefore no caption-hiding would occur.

The `CAPTION_REGEX` is `/^<!--\s*caption:\s*(.+?)\s*-->$/` -- it uses `^` and `$` anchors AND is applied to `prevLine.text.trim()`. The `.trim()` removes leading/trailing whitespace, and `^`/`$` match the trimmed string boundaries. This should work.

### 6. The `resetForProjectSwitch()` recreating state

In `api.ts` line 1048, `resetForProjectSwitch()` creates a brand new `EditorState` from the stored extensions and calls `view.setState(newState)`. This would discard all field values and re-run `create()` on the current doc. If `resetForProjectSwitch()` is called at inopportune times, it could discard decorations, though they would be rebuilt on the next update.

---

## Recommendation

Before implementing the StateField-to-ViewPlugin split (which would be incorrect per CM6 docs), the following diagnostic steps should be taken:

1. **Verify `buildDecorations()` is executing and finding captions.** Replace `console.log` with `webkit.messageHandlers.errorHandler.postMessage()` as the plan already suggests, but do NOT split the decorations. Just add diagnostics to the existing StateField approach.

2. **Verify the `DecorationSet` contains the expected ranges.** After `builder.finish()`, log the size of the result: `decorations.length` (the array before building) and confirm replace decorations are present.

3. **Inspect the DOM.** In Safari Web Inspector (Develop menu), check whether the caption line's DOM element is still present. If `Decoration.replace()` is working, the line's text should not appear in the DOM. If the text IS present, the decoration is not being applied. If the text is absent, the issue is CSS or layout, not decoration delivery.

4. **Check for competing decorations.** The anchor-plugin also runs `Decoration.replace()` via a ViewPlugin. If a section anchor appears on the same line as a caption comment (unlikely but possible), there could be a conflict. Verify the test content does not have overlapping decoration ranges.

5. **Check the `block: true` widget.** Even if the replace decoration works, if the block widget is not rendering (e.g., the `projectmedia://` scheme is failing to load images), the visual result might not be noticeable. The `img.onerror` handler sets `wrapper.textContent` to an error message -- check if that is appearing.

---

## Summary

| Claim in plan | Correct? | Evidence |
|--------------|----------|---------|
| "Replace decorations from StateFields are not applied" | NO | CM6 docs say StateField (direct) is the ONLY way to provide replace decorations that cross line breaks |
| "Must come from ViewPlugin" | NO | ViewPlugin (indirect) is PROHIBITED from providing replace decorations that cover line breaks |
| "anchor-plugin.ts uses ViewPlugin and works" | TRUE, but misleading | anchor-plugin's replaces are inline (no line breaks), so ViewPlugin is fine for that case |
| Proposed fix: move replace to ViewPlugin | WOULD BE WRONG | Would violate CM6's documented constraint for line-break-crossing replaces |

The actual root cause is likely one of: (a) inability to see diagnostic logs from WKWebView leading to a misdiagnosis, (b) regex not matching test content, or (c) a CSS/rendering issue. Diagnostic logging via `webkit.messageHandlers` should be the first step before any architectural changes.
