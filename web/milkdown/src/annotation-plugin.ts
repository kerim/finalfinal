// Annotation Plugin for Milkdown
// Renders annotations as atomic inline nodes with text stored as attribute
// Click to edit via popup (annotation-edit-popup.ts)
// Serializes to <!-- ::type:: content --> HTML comments
// Types: task (☐/☑), comment (◇), reference (▤)

import type { Ctx, MilkdownPlugin } from '@milkdown/kit/ctx';
import type { Node } from '@milkdown/kit/prose/model';
import { $node, $remark, $view } from '@milkdown/kit/utils';
import type { Root } from 'mdast';
import { visit } from 'unist-util-visit';
import { getAnnotationDisplayModes } from './annotation-display-plugin';
import { showAnnotationEditPopup } from './annotation-edit-popup';
import { isSourceModeEnabled } from './source-mode-plugin';

// Annotation type definitions
export type AnnotationType = 'task' | 'comment' | 'reference';

export interface AnnotationAttrs {
  type: AnnotationType;
  isCompleted: boolean;
  text: string;
}

// Marker symbols for display
export const annotationMarkers: Record<AnnotationType, string> = {
  task: '☐',
  comment: '◇',
  reference: '▤',
};

export const completedTaskMarker = '☑';

// Regex to parse annotation HTML comments: <!-- ::type:: content -->
// For tasks: <!-- ::task:: [ ] text --> or <!-- ::task:: [x] text -->
// Note: (.*?) allows empty content for newly created annotations
export const annotationRegex = /^<!--\s*::(\w+)::\s*(.*?)\s*-->$/s;
export const taskCheckboxRegex = /^\s*\[([ xX])\]\s*(.*)$/s;

// Same shape as annotationRegex, but NOT anchored to end-of-string ($). Used
// to find an annotation comment at the START of a longer string, without
// requiring the whole string to be just that one comment. The non-greedy
// '.*?' with no trailing '$' means the match stops at the FIRST '-->' it
// finds, not the last -- this is what lets it isolate one leading comment
// even when more text (prose, or another annotation) follows on the same
// line.
//
// `^\s{0,3}` tolerates up to 3 leading whitespace characters before the
// `<!--` -- matching CommonMark's own indented-code threshold (4+ spaces of
// indentation makes it a DIFFERENT block type entirely, so a real HTML
// comment can legally sit at 0-3 spaces of indentation and still land here
// as one 'html' node). Without this, an indented leading annotation
// (`   <!-- ::task:: [ ] a --> prose`) never matches, and reproduces the
// original whole-line garble unfixed.
const leadingAnnotationRegex = /^\s{0,3}<!--\s*::(\w+)::\s*(.*?)\s*-->/s;

// Parse one already-isolated `<!-- ::type:: content -->` comment string into
// annotation attributes, or null if it isn't a valid annotation comment.
// Shared by the main html-node visitor below and by splitLeadingAnnotations,
// so both agree on exactly what counts as a valid annotation.
function parseAnnotationComment(rawComment: string): AnnotationAttrs | null {
  const value = rawComment?.trim();
  if (!value) return null;

  // Normalize Unicode whitespace and invisible characters
  const normalizedValue = value
    .replace(/\u00A0/g, ' ') // Non-breaking space → regular space
    .replace(/[\u200B-\u200D\uFEFF]/g, '') // Zero-width spaces
    .replace(/\u2003/g, ' ') // Em space
    .replace(/\u2002/g, ' ') // En space
    .replace(/\r\n/g, '\n') // Windows line endings
    .replace(/\r/g, '\n') // Old Mac line endings
    .trim();

  const match = normalizedValue.match(annotationRegex);
  if (!match) return null;

  const [, typeStr, content] = match;

  // Validate type before type assertion
  if (!['task', 'comment', 'reference'].includes(typeStr)) return null;
  const type = typeStr as AnnotationType;

  let text = content;
  let isCompleted = false;

  // Parse task checkbox
  if (type === 'task') {
    const checkboxMatch = content.match(taskCheckboxRegex);
    if (checkboxMatch) {
      isCompleted = checkboxMatch[1].toLowerCase() === 'x';
      text = checkboxMatch[2];
    }
  }

  return { type, isCompleted, text: text.trim() };
}

// Build the mdast 'annotation' node shape (atomic, text stored in `data`),
// matching what the visit() callback below assigns onto a converted html node.
function makeAnnotationNode(attrs: AnnotationAttrs): any {
  return {
    type: 'annotation',
    data: {
      annotationType: attrs.type,
      isCompleted: attrs.isCompleted,
      text: attrs.text,
    },
    children: [],
  };
}

// CommonMark's HTML-block rule (type 2, `<!-- -->`) ends AT the line
// containing the closing '-->' -- NOT at the next blank line. Verified
// directly: `<!-- ::task:: [ ] lead --> Prose line one.
// more prose line two.` (a real line break between them) parses with the
// html node covering ONLY "<!-- ::task:: [ ] lead --> Prose line one." --
// line two is already its own separate paragraph node. So the bug this
// repairs only happens when a leading annotation's closing '-->' and the
// prose (and possibly another annotation) that follows all sit on the SAME
// line with no line break in between: CommonMark then has no choice but to
// fold the entire line into one 'html' node, and the regex above only
// recognizes a node as an annotation when its ENTIRE value is exactly one
// annotation comment -- so that whole line, prose and all, was being
// swallowed as the text of one giant annotation.
//
// This peels off each leading annotation comment (there can be more than
// one back-to-back) and returns what's left, so the caller can re-parse the
// remainder as ordinary prose. A malformed/pathological match that fails to
// shorten the string can't spin the loop forever (progress guard below).
function splitLeadingAnnotations(value: string): {
  annotations: AnnotationAttrs[];
  gaps: string[];
  remainder: string;
} {
  const annotations: AnnotationAttrs[] = [];
  const gaps: string[] = [];
  let rest = value;

  while (true) {
    const match = rest.match(leadingAnnotationRegex);
    if (!match) break;

    const parsed = parseAnnotationComment(match[0]);
    if (!parsed) break;

    const afterComment = rest.slice(match[0].length);
    // Progress guard: a real match always consumes at least the literal
    // `<!--...-->`, so this shouldn't be reachable -- but a malformed or
    // pathological marker must never be able to spin this loop forever.
    if (afterComment.length >= rest.length) break;

    // The whitespace between this annotation and whatever comes next
    // (another annotation, or prose) is not part of the comment itself, but
    // it IS load-bearing: micromark strips a paragraph's own leading
    // whitespace, and remark-stringify never inserts a space between
    // adjacent inline nodes. If this gap isn't re-injected as its own text
    // node when the tree is reassembled, a later markdown round-trip welds
    // the annotation directly onto whatever follows (`-->Prose...`).
    const gapMatch = afterComment.match(/^[ \t]*/);
    const gap = gapMatch ? gapMatch[0] : '';

    annotations.push(parsed);
    gaps.push(gap);
    rest = afterComment.slice(gap.length);
  }

  return { annotations, gaps, remainder: rest };
}

// Minimal shape we need from the unified Processor: enough to re-parse the
// remainder of a repaired line through the SAME configured parser (so GFM
// tables, math, etc. all still apply inside it) without taking a hard
// dependency on the `unified` package's own types.
interface MarkdownParser {
  parse: (value: string) => Root;
}

// `this.parse(remainder)` parses `remainder` as if it were its own
// standalone document, so every node it returns has line/column/offset
// relative to the START of `remainder` -- NOT to the real document. That
// matters because milkdown's built-in remarkMarker transformer (registered
// later in the same pipeline, see @milkdown/preset-commonmark) reads
// `file.value.charAt(node.position.start.offset)` against the WHOLE
// document's source text to recover which character (`*` vs `_`) was used
// to write a `strong`/`emphasis` node. Splicing in a subtree with
// remainder-local offsets makes it read the wrong character entirely --
// confirmed: `<!-- ::comment:: x --> **bold** tail` saves as
// `<!-- ::comment:: x --> <<bold<< tail`, and gets WORSE on every further
// save because the corrupted `<<`/`<` markers shift the offsets again next
// round. remarkMarker also dereferences `node.position.start` unguarded, so
// deleting `position` instead of fixing it would just trade a silent
// corruption for a crash.
//
// This walks every node in a freshly reparsed subtree and shifts its
// position onto the real document's coordinate space:
// - `offsetShift` moves every absolute offset by however many characters of
//   the ORIGINAL html node's value were consumed before `remainder` began
//   (the peeled annotation(s), any gap whitespace, and up to 3 characters of
//   leading indentation) plus the html node's own starting offset.
// - Only line 1 of the reparsed subtree is a continuation of a partial line
//   in the real document (everything on `remainder`'s own line 2+ already
//   starts at real column 1, same as it does locally), so the column shift
//   only applies there; `lineShift` still applies to every line.
function rebaseParsedPositions(
  root: Root,
  shift: { offsetShift: number; lineShift: number; firstLineColumnShift: number }
): void {
  visit(root, (node: any) => {
    if (!node.position) return;
    for (const key of ['start', 'end'] as const) {
      const point = node.position[key];
      if (!point) continue;
      if (point.line === 1 && typeof point.column === 'number') {
        point.column += shift.firstLineColumnShift;
      }
      if (typeof point.line === 'number') {
        point.line += shift.lineShift;
      }
      if (typeof point.offset === 'number') {
        point.offset += shift.offsetShift;
      }
    }
  });
}

// Remark plugin to convert HTML comments to annotation nodes.
//
// The outer factory below returns a plain `function` (not an arrow function)
// specifically so it can be invoked as `attacher.call(processor, ...)` by
// unified's plugin-freezing machinery -- an arrow function would silently
// ignore that `this` binding. The returned transformer is itself an arrow
// function, which is fine: it only needs to READ `this` (inherited from the
// enclosing function's binding), not receive its own.
const remarkAnnotationPlugin = $remark('annotation', () => {
  return function (this: MarkdownParser) {
    return (tree: Root) => {
      // Repair pass -- must run BEFORE the visit() below, which only
      // recognizes a node as an annotation when its ENTIRE value is exactly
      // one annotation comment. Only root-level 'html' nodes are candidates:
      // that's where CommonMark HTML blocks land (see splitLeadingAnnotations
      // above for why one can contain leading annotations plus real prose).
      for (let i = tree.children.length - 1; i >= 0; i--) {
        const node = tree.children[i] as any;
        if (node.type !== 'html' || typeof node.value !== 'string') continue;

        const { annotations, gaps, remainder } = splitLeadingAnnotations(node.value);
        if (annotations.length === 0) continue;

        // How many characters of the original html node's value were
        // consumed before `remainder` began -- covers the peeled
        // annotation(s), every gap, AND any leading indentation
        // (leadingAnnotationRegex now tolerates 0-3 leading spaces), however
        // the mix breaks down, since `remainder` is always a plain suffix of
        // `node.value` (only ever produced by slicing off the front, never
        // by rebuilding the string). Needed to rebase the reparsed
        // remainder's positions back onto the real document -- see
        // rebaseParsedPositions above.
        const consumedLength = node.value.length - remainder.length;

        // Re-parse the remainder through the SAME processor (before
        // building anything else) so every registered micromark/remark
        // extension (math, GFM, etc.) still applies to it, exactly as if it
        // had been its own paragraph from the start.
        let remainderChildren: any[] = [];
        if (remainder !== '') {
          const reparsed = this.parse(remainder);
          const first = reparsed.children[0] as any;
          if (first && first.type === 'paragraph') {
            const start = node.position?.start;
            if (start) {
              rebaseParsedPositions(reparsed, {
                offsetShift: (start.offset ?? 0) + consumedLength,
                lineShift: (start.line ?? 1) - 1,
                firstLineColumnShift: (start.column ?? 1) - 1 + consumedLength,
              });
            }
            remainderChildren = first.children;
          } else if (remainder.trim() !== '') {
            // The remainder didn't come back as a paragraph -- CommonMark
            // parsed it as some OTHER block type standalone (a heading,
            // list item, blockquote, thematic break, ...). Stringifying it
            // here would be lossy in two ways: it escapes emphasis/strong
            // markers into literal backslash-escaped asterisks
            // (`**bold**` -> `\*\*bold\*\*`), and it turns any further
            // HTML-comment-like content in the remainder (a second real
            // annotation, or an unrelated `<!-- ::break:: -->` marker) into
            // escaped literal text, destroying it. The pre-repair-pass
            // behavior for this whole line was byte-safe (garbled display,
            // but round-tripped to markdown untouched) -- bail out of the
            // repair for this node entirely, same as if no leading
            // annotation had been found, so this specific shape stays at
            // least that safe rather than getting worse.
            continue;
          }
          // Else: remainder is pure whitespace -- nothing to add, same as
          // before.
        }

        // Land every peeled annotation as a child of ONE new paragraph node
        // that replaces the original root-level html node in place -- never
        // as a new root-level sibling, or the nodesToWrap step below would
        // wrap it in its OWN separate paragraph, splitting what should be a
        // single visible paragraph into two.
        const children: any[] = [];
        annotations.forEach((attrs, idx) => {
          children.push(makeAnnotationNode(attrs));
          const isLast = idx === annotations.length - 1;
          const gap = gaps[idx];
          // Keep the gap after this annotation only if something follows it:
          // another annotation, or (for the last one) real remainder prose.
          if (gap && (!isLast || remainder !== '')) {
            children.push({ type: 'text', value: gap });
          }
        });
        children.push(...remainderChildren);

        tree.children[i] = { type: 'paragraph', children };
      }

      // Track nodes that need to be wrapped in paragraphs (can't mutate during visit)
      const nodesToWrap: Array<{ parent: any; index: number }> = [];

      visit(tree, 'html', (node: any, index: number | undefined, parent: any) => {
        const attrs = parseAnnotationComment(node.value);
        if (!attrs) return;

        // Transform to annotation node with text stored in data (for atom node)
        node.type = 'annotation';
        node.data = {
          annotationType: attrs.type,
          isCompleted: attrs.isCompleted,
          text: attrs.text,
        };
        // No children for atomic node
        node.children = [];
        delete node.value;

        // If annotation is a direct child of root (block-level), mark it for wrapping
        // Inline nodes can't be direct children of doc in ProseMirror
        if (parent && parent.type === 'root' && typeof index === 'number') {
          nodesToWrap.push({ parent, index });
        }
      });

      // Wrap standalone annotations in paragraphs (process in reverse to preserve indices)
      for (let i = nodesToWrap.length - 1; i >= 0; i--) {
        const { parent, index } = nodesToWrap[i];
        const annotationNode = parent.children[index];
        // Wrap the annotation in a paragraph
        parent.children[index] = {
          type: 'paragraph',
          children: [annotationNode],
        };
      }
    };
  };
});

// Define the annotation node as atomic (non-editable, text stored in attrs)
const annotationNode = $node('annotation', () => ({
  group: 'inline',
  inline: true,
  atom: true,
  selectable: true,
  draggable: false,

  attrs: {
    type: { default: 'comment' },
    isCompleted: { default: false },
    text: { default: '' },
  },

  parseDOM: [
    {
      tag: 'span.ff-annotation',
      getAttrs: (dom: HTMLElement) => ({
        type: dom.dataset.type || 'comment',
        isCompleted: dom.dataset.completed === 'true',
        text: dom.dataset.text || '',
      }),
    },
  ],

  toDOM: (node: Node) => {
    const { type, isCompleted, text } = node.attrs as AnnotationAttrs;
    let marker = annotationMarkers[type];

    if (type === 'task' && isCompleted) {
      marker = completedTaskMarker;
    }

    const classes = ['ff-annotation', `ff-annotation-${type}`, isCompleted ? 'ff-annotation-completed' : '']
      .filter(Boolean)
      .join(' ');

    // Collapsed annotations already show a hover tooltip driven by data-text
    // (hover-tooltip.ts's single delegated listener, matching the
    // `.ff-annotation-collapsed` class this element gets from
    // annotation-display-plugin.ts's decoration). Also setting the native
    // `title` attribute would pop up the browser's OWN tooltip on top of it
    // after ~1s hover — two overlapping tooltips for the same annotation.
    // Omit `title` in that case, and expose the text via `role="img"` +
    // `aria-label` instead so collapsed annotations still have an accessible
    // name (the JS-driven tooltip is only in the DOM while actually hovered,
    // same accessibility-tree gap the old CSS-only bubble had). See
    // applyAnnotationAccessibilityAttrs() below for the equivalent logic used
    // by the live NodeView.
    const isCollapsed = getAnnotationDisplayModes()[type] === 'collapsed';

    // Atomic structure: marker + static text span (no content hole)
    return [
      'span',
      {
        class: classes,
        'data-type': type,
        'data-text': text,
        'data-completed': String(isCompleted),
        ...(isCollapsed ? { role: 'img', 'aria-label': text } : { title: text }),
      },
      // Marker span (non-editable)
      ['span', { class: 'ff-annotation-marker', contenteditable: 'false' }, marker],
      // Text span (static display, not editable inline)
      ['span', { class: 'ff-annotation-text' }, text || ''],
    ];
  },

  parseMarkdown: {
    match: (node: any) => node.type === 'annotation',
    runner: (state: any, node: any, type: any) => {
      // Add as atom node with text in attrs
      state.addNode(type, {
        type: node.data.annotationType,
        isCompleted: node.data.isCompleted,
        text: node.data.text || '',
      });
    },
  },

  toMarkdown: {
    match: (node: Node) => node.type.name === 'annotation',
    runner: (state: any, node: Node) => {
      const { type, isCompleted, text: rawText } = node.attrs as AnnotationAttrs;
      // Sanitize newlines in text attribute
      const text = (rawText || '')
        .replace(/[\r\n]+/g, ' ')
        .replace(/\s+/g, ' ')
        .trim();

      let content: string;
      if (type === 'task') {
        const checkbox = isCompleted ? '[x]' : '[ ]';
        content = `<!-- ::task:: ${checkbox} ${text} -->`;
      } else {
        content = `<!-- ::${type}:: ${text} -->`;
      }

      state.addNode('html', undefined, content);
    },
  },
}));

// Set the attributes that give an annotation wrapper its accessible name.
// Collapsed annotations already show a hover tooltip driven by data-text
// (hover-tooltip.ts's single delegated listener, matching the
// `.ff-annotation-collapsed` class) — leaving the native `title` attribute in
// place too would pop up the browser's OWN tooltip on top of it after ~1s
// hover, so the same annotation would show two overlapping tooltips at once.
// Omit `title` for collapsed annotations to avoid that. But the JS-driven
// tooltip is only ever added to the DOM while actually hovered, which excludes
// it from the accessibility tree, so a `title`-less span would otherwise have
// NO accessible name at all for screen readers. Collapsed annotations get
// `role="img"` + `aria-label` instead — a role is needed because `aria-label`
// on a bare element with no ARIA role (a `span` implies none) is exposed
// inconsistently by assistive tech.
function applyAnnotationAccessibilityAttrs(dom: HTMLElement, type: AnnotationType, text: string): void {
  const isCollapsed = getAnnotationDisplayModes()[type] === 'collapsed';
  if (isCollapsed) {
    dom.removeAttribute('title');
    dom.setAttribute('role', 'img');
    dom.setAttribute('aria-label', text || '');
  } else {
    dom.removeAttribute('role');
    dom.removeAttribute('aria-label');
    dom.title = text || '';
  }
}

// NodeView for atomic annotation rendering with click-to-edit popup
const annotationNodeView = $view(annotationNode, (_ctx: Ctx) => {
  return (node, view, getPos) => {
    const attrs = node.attrs as AnnotationAttrs;

    // Track source mode at NodeView creation time
    const createdInSourceMode = isSourceModeEnabled();

    // Create the wrapper span
    const dom = document.createElement('span');
    dom.className = ['ff-annotation', `ff-annotation-${attrs.type}`, attrs.isCompleted ? 'ff-annotation-completed' : '']
      .filter(Boolean)
      .join(' ');
    dom.dataset.type = attrs.type;
    dom.dataset.completed = String(attrs.isCompleted);
    dom.dataset.text = attrs.text || '';
    applyAnnotationAccessibilityAttrs(dom, attrs.type, attrs.text);

    // Create the marker span (non-editable)
    const markerSpan = document.createElement('span');
    markerSpan.className = 'ff-annotation-marker';
    markerSpan.contentEditable = 'false';
    let marker = annotationMarkers[attrs.type];
    if (attrs.type === 'task' && attrs.isCompleted) {
      marker = completedTaskMarker;
    }
    markerSpan.textContent = marker;

    // Handle marker click for task completion toggle
    if (attrs.type === 'task') {
      markerSpan.style.cursor = 'pointer';
      markerSpan.addEventListener('click', (e) => {
        // When collapsed, the text span is hidden (display: none) so the marker is
        // the annotation's ONLY visible/clickable surface. Don't let it swallow the
        // click for a completion toggle in that case — fall through (no
        // preventDefault/stopPropagation) so the click bubbles to dom's listener
        // below and opens the edit popup instead, matching what a click on this
        // same annotation would do when expanded (click the visible text to edit).
        if (getAnnotationDisplayModes()[attrs.type] === 'collapsed') return;

        e.preventDefault();
        e.stopPropagation();
        const pos = typeof getPos === 'function' ? getPos() : null;
        if (pos !== null && pos !== undefined) {
          const currentNode = view.state.doc.nodeAt(pos);
          if (currentNode && currentNode.type.name === 'annotation') {
            const currentCompleted = currentNode.attrs.isCompleted;
            const tr = view.state.tr.setNodeMarkup(pos, undefined, {
              ...currentNode.attrs,
              isCompleted: !currentCompleted,
            });
            view.dispatch(tr);
          }
        }
      });
    }

    // Create the text span (non-editable display)
    const textSpan = document.createElement('span');
    textSpan.className = 'ff-annotation-text';
    textSpan.textContent = attrs.text || '';

    // Click handler to open edit popup (skip if click was on marker for task toggle)
    dom.addEventListener('click', (e) => {
      const isCollapsed = getAnnotationDisplayModes()[attrs.type] === 'collapsed';
      // Don't open popup if marker was clicked (task toggle handles it) — UNLESS
      // collapsed, where the marker is the only visible surface and click-to-edit
      // must work from it (see the collapsed early-return in the marker's own
      // click listener above, which lets this handler run instead of toggling).
      if (!isCollapsed && markerSpan.contains(e.target as HTMLElement)) return;
      // Don't open popup in source mode
      if (isSourceModeEnabled()) return;

      const pos = typeof getPos === 'function' ? getPos() : null;
      if (pos !== null && pos !== undefined) {
        const currentNode = view.state.doc.nodeAt(pos);
        if (currentNode && currentNode.type.name === 'annotation') {
          showAnnotationEditPopup(pos, view, currentNode.attrs as AnnotationAttrs);
        }
      }
    });

    // Source mode rendering helper
    const renderSourceMode = (a: AnnotationAttrs) => {
      const checkbox = a.type === 'task' ? (a.isCompleted ? '[x] ' : '[ ] ') : '';
      while (dom.firstChild) dom.removeChild(dom.firstChild);
      dom.textContent = `<!-- ::${a.type}:: ${checkbox}${a.text || ''} -->`;
      dom.classList.add('source-mode-annotation');
    };

    // Initial render
    if (createdInSourceMode) {
      renderSourceMode(attrs);
    } else {
      dom.appendChild(markerSpan);
      dom.appendChild(textSpan);
    }

    return {
      dom,
      update: (updatedNode) => {
        if (updatedNode.type.name !== 'annotation') {
          return false;
        }

        // Force recreation if source mode changed
        if (isSourceModeEnabled() !== createdInSourceMode) {
          return false;
        }

        const newAttrs = updatedNode.attrs as AnnotationAttrs;

        // Update wrapper attributes
        dom.dataset.type = newAttrs.type;
        dom.dataset.completed = String(newAttrs.isCompleted);
        dom.dataset.text = newAttrs.text || '';
        applyAnnotationAccessibilityAttrs(dom, newAttrs.type, newAttrs.text);
        dom.className = [
          'ff-annotation',
          `ff-annotation-${newAttrs.type}`,
          newAttrs.isCompleted ? 'ff-annotation-completed' : '',
        ]
          .filter(Boolean)
          .join(' ');

        if (isSourceModeEnabled()) {
          renderSourceMode(newAttrs);
        } else {
          // Update marker
          let newMarker = annotationMarkers[newAttrs.type];
          if (newAttrs.type === 'task' && newAttrs.isCompleted) {
            newMarker = completedTaskMarker;
          }
          markerSpan.textContent = newMarker;
          // Update text display
          textSpan.textContent = newAttrs.text || '';
        }

        return true;
      },
      ignoreMutation: () => true, // Atom node - ignore all mutations
    };
  };
});

// Export the plugin array
export const annotationPlugin: MilkdownPlugin[] = [remarkAnnotationPlugin, annotationNode, annotationNodeView].flat();

// Export node and helper for use in slash commands
export { annotationNode };

// Helper to create annotation markdown
export function createAnnotationMarkdown(type: AnnotationType, text: string = ''): string {
  if (type === 'task') {
    return `<!-- ::task:: [ ] ${text} -->`;
  }
  return `<!-- ::${type}:: ${text} -->`;
}
