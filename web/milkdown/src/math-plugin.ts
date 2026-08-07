// Math Plugin for Milkdown
// Renders LaTeX equations using KaTeX (offline, bundled).
// Two atom node types:
//   math_inline  — inline $...$  (group: inline)
//   math_display — display $$...$$ (group: block)
// Mirrors citation-plugin.ts: atom node + NodeView + toMarkdown via 'html' node type.

import { ParserReady, parserCtx } from '@milkdown/kit/core';
import type { Ctx, MilkdownPlugin } from '@milkdown/kit/ctx';
import type { Node } from '@milkdown/kit/prose/model';
import { $node, $remark, $view } from '@milkdown/kit/utils';
import katex from 'katex';
import remarkMath from 'remark-math';
import { showMathEditPopup } from './math-edit-popup';
import { normalizeMathFences } from './math-paste-normalize';

// === Remark plugin to handle math nodes from remark-math ===
// remark-math converts $...$ to inlineMath nodes and $$...$$ to math nodes
const remarkMathPlugin = $remark('math', () => remarkMath as any);

// Wrap the shared parser (ctx.get(parserCtx)) so any caller that hands it raw
// markdown — the clipboard plugin's plain-text paste path, and setContent()/
// api-content.ts's programmatic loads — gets malformed `$$` fences repaired
// first. See math-paste-normalize.ts for why this is needed: remark-math's
// tokenizer swallows everything after a glued `$$` fence to EOF, which is
// exactly what happens when markdown containing a malformed math block
// arrives from OUTSIDE the app (paste) rather than from our own serializer
// (fixed separately, above/below — see toMarkdown).
//
// Must wait for the ParserReady timer before wrapping: @milkdown/core's own
// internal `parser` plugin doesn't call `ctx.set(parserCtx, ...)` with the
// real parser closure until schema construction finishes (it starts as an
// out-of-scope placeholder). Updating parserCtx before that SET would wrap
// the placeholder, and the later `ctx.set` would silently discard our wrap
// entirely — confirmed empirically while building this fix.
const mathPasteNormalizePlugin: MilkdownPlugin = (ctx: Ctx) => async () => {
  await ctx.wait(ParserReady);
  ctx.update(parserCtx, (prevParser) => (markdown: string) => prevParser(normalizeMathFences(markdown)));
};

// === math_inline node (inline atom) ===
export const mathInlineNode = $node('math_inline', () => ({
  group: 'inline',
  inline: true,
  atom: true,
  selectable: true,
  draggable: false,

  attrs: {
    latex: { default: '' },
  },

  parseDOM: [
    {
      tag: 'span.ff-math-inline',
      getAttrs: (dom: HTMLElement) => ({
        latex: dom.dataset.latex || '',
      }),
    },
  ],

  toDOM: (node: Node) => {
    return [
      'span',
      {
        class: 'ff-math-inline',
        'data-latex': node.attrs.latex,
      },
      node.attrs.latex ? `$${node.attrs.latex}$` : '$?$',
    ];
  },

  parseMarkdown: {
    match: (node: any) => node.type === 'inlineMath',
    runner: (state: any, node: any, type: any) => {
      state.addNode(type, { latex: node.value || '' });
    },
  },

  toMarkdown: {
    match: (node: Node) => node.type.name === 'math_inline',
    runner: (state: any, node: Node) => {
      // Use 'html' node type to avoid $ → \$ escaping (same reason as citation-plugin.ts:207-212)
      state.addNode('html', undefined, `$${node.attrs.latex}$`);
    },
  },
}));

// === math_display node (block atom) ===
export const mathDisplayNode = $node('math_display', () => ({
  group: 'block',
  atom: true,
  selectable: true,
  draggable: false,

  attrs: {
    latex: { default: '' },
  },

  parseDOM: [
    {
      tag: 'div.ff-math-display',
      getAttrs: (dom: HTMLElement) => ({
        latex: dom.dataset.latex || '',
      }),
    },
  ],

  toDOM: (node: Node) => {
    return [
      'div',
      {
        class: 'ff-math-display',
        'data-latex': node.attrs.latex,
      },
      `$$\n${node.attrs.latex}\n$$`,
    ];
  },

  parseMarkdown: {
    match: (node: any) => node.type === 'math',
    runner: (state: any, node: any, type: any) => {
      // Older documents (pre-fix) may have been written with `$$` glued directly
      // onto the first LaTeX line (e.g. `$$x &= y`). remark-math parses that
      // shape as YAML-ish front matter and stashes the first line in `node.meta`,
      // silently dropping it from `node.value`. Recover it here so those
      // documents self-repair to the canonical `$$\nlatex\n$$` shape on next
      // parse/serialize round-trip instead of losing the first line forever.
      const latex = node.meta ? `${node.meta}\n${node.value || ''}` : node.value || '';
      state.addNode(type, { latex });
    },
  },

  toMarkdown: {
    match: (node: Node) => node.type.name === 'math_display',
    runner: (state: any, node: Node) => {
      // Use 'html' node type to avoid $ → \$ escaping.
      // Each `$$` fence on its own line — NOT glued onto the first latex line
      // (`$$latex$$`) — because a glued `$$foo` open is misread by remark-math
      // as YAML-ish metadata (see parseMarkdown above), dropping the first line.
      state.addNode('html', undefined, `$$\n${node.attrs.latex}\n$$`);
    },
  },
}));

// === NodeViews ===
// One factory for both node types — they differ only in element tag, class name,
// KaTeX display mode, and the raw-source fallback text.
function createMathNodeView(nodeSchema: typeof mathInlineNode, isDisplay: boolean) {
  const typeName = isDisplay ? 'math_display' : 'math_inline';
  const className = isDisplay ? 'ff-math-display' : 'ff-math-inline';
  // Display fallback uses the canonical unglued `$$\nlatex\n$$` shape (see toMarkdown
  // above) so this visible KaTeX-error/empty-latex fallback text matches what the
  // serializer would emit — a glued `$$latex$$` here would round-trip-corrupt if a
  // user copied it back in as markdown. Inline math has no such ambiguity — it's
  // always a single line — so it stays glued.
  const wrapRaw = (latex: string) => (isDisplay ? `$$\n${latex}\n$$` : `$${latex}$`);

  return $view(nodeSchema, (_ctx: Ctx) => {
    return (node, view, getPos) => {
      const dom = document.createElement(isDisplay ? 'div' : 'span');
      dom.className = className;
      // Track the current latex locally — the constructor's `node` goes stale after
      // update(), so the click handler must not read node.attrs.latex.
      let currentLatex: string = node.attrs.latex;
      dom.dataset.latex = currentLatex;

      const renderKaTeX = (latex: string) => {
        if (!latex) {
          dom.textContent = wrapRaw('?');
          return;
        }
        try {
          katex.render(latex, dom, {
            displayMode: isDisplay,
            throwOnError: false,
            output: 'html',
          });
        } catch (_e) {
          dom.textContent = wrapRaw(latex);
        }
      };

      renderKaTeX(currentLatex);

      dom.addEventListener('click', (e) => {
        e.preventDefault();
        e.stopPropagation();
        const pos = typeof getPos === 'function' ? getPos() : null;
        if (pos !== null && pos !== undefined) {
          showMathEditPopup(pos, view, currentLatex, isDisplay);
        }
      });

      return {
        dom,
        update: (updatedNode) => {
          if (updatedNode.type.name !== typeName) return false;
          if (updatedNode.attrs.latex !== currentLatex) {
            currentLatex = updatedNode.attrs.latex;
            dom.dataset.latex = currentLatex;
            renderKaTeX(currentLatex);
          }
          return true;
        },
        stopEvent: () => false,
        ignoreMutation: () => true,
      };
    };
  });
}

const mathInlineNodeView = createMathNodeView(mathInlineNode, false);
const mathDisplayNodeView = createMathNodeView(mathDisplayNode, true);

// Export the plugin array — node views MUST be in the same array as their nodes
export const mathPlugin: MilkdownPlugin[] = [
  remarkMathPlugin,
  mathInlineNode,
  mathInlineNodeView,
  mathDisplayNode,
  mathDisplayNodeView,
  mathPasteNormalizePlugin,
].flat();
