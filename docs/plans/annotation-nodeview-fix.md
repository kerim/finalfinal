# NodeView Fixes: Citations and Annotations

## Overview

This document chronicles the debugging journey from broken citation display to working citations, and the subsequent annotation infinite loop that was exposed and fixed.

**Timeline:**
1. Citations not displaying formatted text (showed raw `[@citekey]`)
2. Diagnostic investigation revealed `$view` signature bug
3. Fix applied to both citation and annotation NodeViews
4. Fix exposed latent infinite loop bug in annotations
5. Root cause identified as MutationObserver interference
6. MutationObserver disabled, annotations now work

---

## Part 1: Citation NodeView Not Working

### The Problem

Citations were being parsed correctly but displayed as raw syntax `[@friedman2018]` instead of formatted output like `(Friedman 2018)`. The citeproc engine was working, but the NodeView wasn't being applied.

### Diagnostic Approach (Plan v9)

We added factory-level logging to understand where the breakdown occurred:

```typescript
// What we added to diagnose
const citationNodeView = $view(citationNode, () => (ctx: Ctx) => {
  console.log('[CitationNodeView] FACTORY CALLED');  // <-- Does this fire?
  return (node, view, getPos) => {
    console.log('[CitationNodeView] VIEW CREATED');  // <-- Does this fire?
    // ...
  };
});
```

**Initial hypothesis:** `atom: true` might prevent NodeView from being called.

**What the logs revealed:**
- `FACTORY CALLED` logged once
- `VIEW CREATED` never logged
- Annotations showed similar pattern but worked anyway (because they used `toDOM` fallback)

### Root Cause Discovery

Comparing working examples in Milkdown documentation revealed the issue:

**Wrong signature (what we had):**
```typescript
const nodeView = $view(node, () => (ctx: Ctx) => {
  return (node, view, getPos) => { ... };
});
```

**Correct signature:**
```typescript
const nodeView = $view(node, (ctx: Ctx) => {
  return (node, view, getPos) => { ... };
});
```

The extra `() =>` wrapper meant:
- `$view` called our outer function `() => (ctx: Ctx) => ...`
- That returned `(ctx: Ctx) => ...` which `$view` stored
- When Milkdown tried to call it with `ctx`, it got back `(node, view, getPos) => ...`
- But Milkdown expected the NodeView instance, not another function

**The NodeView constructor was never actually instantiated.**

### The Fix

Remove the extra wrapper from both citation-plugin.ts and annotation-plugin.ts:

```typescript
// BEFORE (broken)
const citationNodeView = $view(citationNode, () => (ctx: Ctx) => {

// AFTER (fixed)
const citationNodeView = $view(citationNode, (ctx: Ctx) => {
```

**Result:** Citations now display as `(Friedman 2018)` correctly.

---

## Part 2: Annotation Infinite Loop Exposed

### The New Problem

After fixing the `$view` signature, annotations caused the browser to hang with 181,280+ "VIEW CREATED" calls. The app became completely unresponsive.

### Why This Was Hidden Before

With the wrong `$view` signature:
- The NodeView constructor was never called
- Annotations fell back to `toDOM` rendering
- `toDOM` worked fine, just without NodeView features
- No infinite loop because no NodeView code ran

With the correct signature:
- NodeView IS instantiated
- MutationObserver starts watching `contentDOM`
- Bug in MutationObserver causes infinite recreation

### Diagnostic Logging

Added logging to track the update cycle:

```typescript
update: (updatedNode) => {
  console.log('[AnnotationNodeView] update() called, type:', updatedNode.type.name);
  if (updatedNode.type.name !== 'annotation') {
    console.log('[AnnotationNodeView] update() returning FALSE');
    return false;
  }
  // ... update logic ...
  console.log('[AnnotationNodeView] update() returning TRUE');
  return true;
},
```

**Log output revealed:**
```
[AnnotationNodeView] VIEW CREATED for node: "task"
[AnnotationNodeView] update() called, type: "annotation"
[AnnotationNodeView] update() returning TRUE
[AnnotationNodeView] VIEW CREATED for node: "task" (x213584)
```

**Key insight:** `update()` was called once and returned TRUE correctly, but the view was still recreated 213,584 times. The issue wasn't in `update()`.

### Root Cause: MutationObserver + contentDOM

The annotation NodeView has:
- `contentDOM` for editable text content (ProseMirror manages this)
- `MutationObserver` watching `contentDOM` for text changes
- `updateTooltip()` that modifies `dom.dataset.text` and `dom.title`

**The infinite loop:**
1. ProseMirror renders initial content into `contentDOM`
2. MutationObserver detects the change
3. `updateTooltip()` modifies wrapper DOM attributes
4. ProseMirror detects these DOM modifications
5. ProseMirror thinks the NodeView structure is corrupted
6. ProseMirror destroys and recreates the NodeView
7. Goto step 1

### Why `ignoreMutation` Didn't Help

We tried adding `ignoreMutation` to tell ProseMirror to ignore our DOM changes:

```typescript
ignoreMutation: (mutation: MutationRecord) => {
  if (mutation.type === 'attributes' && mutation.target === dom) {
    return true;  // Ignore our tooltip updates
  }
  return false;
},
```

This didn't fix it because:
- Mutations fired during ProseMirror's initial content population
- The recreation happened during setup, before `update()` could intervene
- ProseMirror's internal reconciliation detected structural issues

### The Fix

Disable the MutationObserver entirely:

```typescript
// DIAGNOSTIC: Commenting out MutationObserver to test if it causes infinite loop
// const textObserver = new MutationObserver(updateTooltip);
// textObserver.observe(contentDOM, {...});
const textObserver = { disconnect: () => {} }; // Stub for destroy()
```

**Result:** Infinite loop stopped. Annotations work.

---

## Part 3: Key Differences Between Citations and Annotations

| Feature | Citation | Annotation |
|---------|----------|------------|
| `atom` | `true` | `false` |
| `content` | None | `text*` |
| `contentDOM` | Not returned | Returned |
| MutationObserver | None | Was watching contentDOM |
| Editability | Click to edit (custom) | Inline editable (ProseMirror) |

Citations are **atomic** - ProseMirror treats them as single units and doesn't manage their internal DOM. This avoids the MutationObserver conflict entirely.

Annotations have **contentDOM** - ProseMirror manages the text inside. Adding a MutationObserver that modifies the wrapper during content updates creates conflicts.

---

## Current State

### What Works
- Citations display formatted: `(Friedman 2018)`
- Annotations can be created via slash commands
- Typing inside annotation text
- Task completion toggle (first time)

### What Doesn't Work
- Task completion toggle (second time) - needs investigation
- Tooltip no longer updates when text changes (acceptable tradeoff)

### Remaining Work
1. Investigate why second toggle fails
2. Consider alternative tooltip update strategy (on blur, in update())
3. Clean up diagnostic logging

---

## Lessons Learned

1. **`$view` signature matters:** `(ctx) =>` not `() => (ctx) =>`. The extra wrapper breaks instantiation.

2. **Bugs can be hidden by other bugs:** The wrong `$view` signature prevented annotations from using their NodeView, which hid the MutationObserver bug.

3. **MutationObserver + ProseMirror contentDOM = danger:** Don't use MutationObserver to watch content that ProseMirror manages. The two systems conflict.

4. **`ignoreMutation` isn't a silver bullet:** It tells ProseMirror to ignore mutations, but can't prevent all reconciliation issues during initial setup.

5. **Atomic nodes are simpler:** `atom: true` avoids many NodeView complexities by letting ProseMirror treat the node as a black box.

6. **Diagnostic logging reveals truth:** Adding logging at factory, view creation, and update levels quickly revealed that `update()` wasn't the problem.

---

## Commits

- `c9642ac` - feat: add Zotero citation integration via Better BibTeX
- `2957c1f` - fix: annotation NodeView infinite loop by disabling MutationObserver

## Files Modified

- `web/milkdown/src/citation-plugin.ts` - Fixed `$view` signature, consolidated NodeView
- `web/milkdown/src/annotation-plugin.ts` - Fixed `$view` signature, disabled MutationObserver
- `web/milkdown/src/citation-display.ts` - Deleted (consolidated into citation-plugin.ts)
