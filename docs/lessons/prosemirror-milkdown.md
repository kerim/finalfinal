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
