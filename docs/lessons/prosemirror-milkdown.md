# ProseMirror / Milkdown Patterns

Patterns for ProseMirror and Milkdown editors. Consult before writing related code.

---

## Use Decoration System, Not DOM Manipulation

Direct DOM manipulation breaks ProseMirror's reconciliation. Use `Decoration` system:

```typescript
// Wrong
document.querySelectorAll('.paragraph').forEach(el => el.classList.add('dimmed'));

// Right
const decorations = DecorationSet.create(doc, [
  Decoration.node(from, to, { class: 'dimmed' })
]);
```

## Decoration.node() Creates Wrapper Elements

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

## HTML Nodes Are Filtered Before Custom Plugins Run

**Problem:** Custom HTML comments like `<!-- ::break:: -->` aren't parsed when loaded via `setContent()`, but work fine when inserted via slash command.

**Root Cause:** Milkdown's commonmark preset includes `filterHTMLPlugin` that removes HTML nodes (including comments) **before** custom remark plugins can transform them.

**Pipeline order:**
```
Markdown -> remark-parse -> [filterHTMLPlugin removes HTML] -> [Your remark plugin] -> ProseMirror
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

## SlashProvider Dual Visibility Control

**Problem:** Slash menu shows on first `/` keystroke, command executes, but subsequent `/` keystrokes don't show the menu.

**Root Cause:** Two independent visibility controls fighting each other:

1. **SlashProvider** controls visibility via `data-show` attribute
2. **Custom code** sets `style.display = 'none'` directly

When hiding after command execution:
```typescript
// Problem: sets inline CSS that SlashProvider doesn't clear
slashMenuElement.style.display = 'none';
```

When SlashProvider shows the menu again, it only sets `data-show="true"` -- it does NOT clear the inline `style.display`. CSS specificity means `style.display: none` wins.

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

## Empty Content Handling: Early Return Bypass

**Problem:** Section break symbol appeared when switching from CodeMirror to Milkdown on blank documents, even though empty content handling code existed.

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
1. Check at line 1: `'' === ''` -> **returns early**
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

## Clipboard Plugin Required for Markdown Paste

**Problem:** Pasting raw markdown into Milkdown treated it as plain text. `## Heading` appeared as literal "##" text, `>` blockquotes were escaped as `\>`, links as `\[text\]\(url\)`, and bold/italic got backslash-escaped.

**Root Cause:** The `clipboard` plugin from `@milkdown/kit` was not enabled. Without it, ProseMirror's default paste handler inserts markdown as literal text into paragraph nodes, and the serializer then escapes the special characters on output.

**Solution:** Enable the clipboard plugin in `main.ts`:

```typescript
import { clipboard } from '@milkdown/kit/plugin/clipboard';

Editor.make()
  // ...
  .use(history)
  .use(clipboard)  // Parse pasted markdown as rich text
```

The plugin is bundled with `@milkdown/kit` — no extra install needed. It intercepts `handlePaste`: if the clipboard contains plain text only (no HTML), it parses the text as markdown via the editor's parser and converts it to ProseMirror nodes. It also handles copy by serializing ProseMirror content back to clean markdown.

**Legacy workarounds:** Two workarounds existed for symptoms of this missing plugin — `api-content.ts` unescaping `\#` heading syntax, and `block-sync-plugin.ts` detecting heading syntax inside paragraph nodes. These were kept as safety nets but may be removable now.

---

## Stateless Decorations Cause "Traveling" Artifacts

**Problem:** Spell check underlines appeared on wrong words during typing. They "traveled" across the document and only settled on the correct words after typing stopped for ~400ms.

**Root Cause:** The plugin used stateless `props.decorations(state)` which rebuilt the `DecorationSet` from a module-level results array on every state change. The results array held absolute document positions computed before the edit. Each keystroke shifts positions after the edit point, but the stored positions remained unchanged.

**Solution:** Convert to plugin `state` with `init()`/`apply()`. On `tr.docChanged`, use `DecorationSet.map(tr.mapping, tr.doc)` to shift decoration positions. Also map the module-level results array (for click handlers) with asymmetric bias: `from` maps with +1 (don't extend left), `to` maps with -1 (don't extend right).

Deliver fresh results via `tr.setMeta(pluginKey, results)` instead of no-op transactions. This lets `apply()` distinguish "new results" from "document changed" from "cursor moved."

```typescript
// Wrong — rebuilds from stale positions on every state change
props: {
  decorations(state) {
    return DecorationSet.create(state.doc, resultsToDecorations(results));
  }
}

// Right — maps positions through document changes
state: {
  init() { return DecorationSet.empty; },
  apply(tr, decorationSet) {
    if (tr.getMeta(pluginKey) !== undefined)
      return buildDecorationSet(tr.getMeta(pluginKey), tr.doc);
    if (tr.docChanged)
      return decorationSet.map(tr.mapping, tr.doc);
    return decorationSet;
  }
}
```

**General principle:** Any plugin storing absolute document positions must map them through transaction changes. ProseMirror's `DecorationSet.map()` and `Mapping.map()` exist exactly for this purpose. Stateless `props.decorations()` is only safe when decorations are derived purely from the current document state (e.g., syntax highlighting), not from external data with stored positions.

---

## Debounce Plugin `apply()` Side Effects, Not State Updates

**Problem:** The block-sync plugin called `detectChanges()` synchronously inside `apply()` on every doc-changing transaction. This ran string serialization (`nodeToMarkdownFragment`) per keystroke, adding main-thread overhead.

**Root Cause:** ProseMirror's `apply()` must return the new plugin state synchronously — but the *side effects* of state changes (like network calls or heavy computations) don't need to run immediately.

**Solution:** Separate the snapshot (synchronous, needed for correct state) from change detection (debounced side effect). Return the updated state immediately but defer `detectChanges()` with a 100ms timer. Preserve the oldest un-processed snapshot across debounce resets so rapid keystrokes A→B→C diff A→C, not B→C.

```typescript
apply(tr, value, _oldState, newState) {
  const newSnapshot = snapshotBlocks(newState.doc); // synchronous — state needs this
  if (detectTimer) clearTimeout(detectTimer);
  else pendingOldSnapshot = value.lastSnapshot;     // preserve baseline from first keystroke
  detectTimer = setTimeout(() => {
    detectChanges(pendingOldSnapshot, newSnapshot, currentState); // deferred
    pendingOldSnapshot = null;
    detectTimer = null;
  }, 100);
  return { ...value, lastSnapshot: newSnapshot };
}
```

**General principle:** In ProseMirror plugin `apply()`, keep state updates synchronous but debounce expensive side effects. When debouncing diffs, always compare against the oldest un-processed state, not the most recent, or intermediate changes are lost.
