// Math Plugin for Milkdown
// Renders LaTeX equations using KaTeX (offline, bundled).
// Two atom node types:
//   math_inline  — inline $...$  (group: inline)
//   math_display — display $$...$$ (group: block)
// Mirrors citation-plugin.ts: atom node + NodeView + toMarkdown via 'html' node type.

import type { Ctx, MilkdownPlugin } from '@milkdown/kit/ctx';
import type { Node } from '@milkdown/kit/prose/model';
import { $node, $remark, $view } from '@milkdown/kit/utils';
import katex from 'katex';
import remarkMath from 'remark-math';
import { showMathEditPopup } from './math-edit-popup';

// === Remark plugin to handle math nodes from remark-math ===
// remark-math converts $...$ to inlineMath nodes and $$...$$ to math nodes
const remarkMathPlugin = $remark('math', () => remarkMath as any);

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
      `$$${node.attrs.latex}$$`,
    ];
  },

  parseMarkdown: {
    match: (node: any) => node.type === 'math',
    runner: (state: any, node: any, type: any) => {
      state.addNode(type, { latex: node.value || '' });
    },
  },

  toMarkdown: {
    match: (node: Node) => node.type.name === 'math_display',
    runner: (state: any, node: Node) => {
      // Use 'html' node type to avoid $ → \$ escaping
      state.addNode('html', undefined, `$$${node.attrs.latex}$$`);
    },
  },
}));

// === NodeViews ===
// One factory for both node types — they differ only in element tag, class name,
// KaTeX display mode, and the raw-source fallback text.
function createMathNodeView(nodeSchema: typeof mathInlineNode, isDisplay: boolean) {
  const typeName = isDisplay ? 'math_display' : 'math_inline';
  const className = isDisplay ? 'ff-math-display' : 'ff-math-inline';
  const wrapRaw = (latex: string) => (isDisplay ? `$$${latex}$$` : `$${latex}$`);

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
].flat();
