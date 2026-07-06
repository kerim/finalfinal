// Block Sync Plugin for tracking changes to blocks
// Tracks inserts, updates, and deletes via ProseMirror transactions
// Exports pending changes for Swift polling via getBlockChanges()

import type { Mark, Node } from '@milkdown/kit/prose/model';
import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import { $prose } from '@milkdown/kit/utils';
import { type Align, formatTable, type ParsedTable } from '../../shared/format-table';
import { getAllBlockIds, SYNC_DIAG_DETAIL } from './block-id-plugin';
import type { CitationAttrs } from './citation-plugin';
import { serializeCitation } from './citation-plugin';
import { syncLog } from './sync-debug';

export const blockSyncPluginKey = new PluginKey<BlockSyncPluginState>('block-sync');

// Block types that are synced (top-level only — no list_item)
const SYNC_BLOCK_TYPES = new Set([
  'paragraph',
  'heading',
  'bullet_list',
  'ordered_list',
  'blockquote',
  'code_block',
  'horizontal_rule',
  'section_break',
  'table',
  'figure',
  'math_display',
]);

// Types for block changes
export interface BlockUpdate {
  id: string;
  textContent?: string;
  markdownFragment?: string;
  headingLevel?: number;
}

export interface BlockInsert {
  tempId: string;
  blockType: string;
  textContent: string;
  markdownFragment: string;
  headingLevel?: number;
  afterBlockId?: string;
}

export interface BlockChanges {
  updates: BlockUpdate[];
  inserts: BlockInsert[];
  deletes: string[];
}

interface BlockSyncPluginState {
  // Snapshot of blocks from last sync
  lastSnapshot: Map<string, BlockSnapshot>;
  // Pending changes since last getBlockChanges() call
  pendingUpdates: Map<string, BlockUpdate>;
  pendingInserts: Map<string, BlockInsert>;
  pendingDeletes: Set<string>;
}

export interface BlockSnapshot {
  id: string;
  pos: number;
  blockType: string;
  textContent: string;
  nodeSize: number; // Detect atom node add/remove (citations)
  headingLevel?: number;
  node: Node; // Store node reference for markdown serialization
  _cachedMarkdown: string | null; // Lazily computed markdown fragment
}

/** Get or compute the markdown fragment for a snapshot (lazy + cached) */
function getMarkdownFragment(snapshot: BlockSnapshot): string {
  if (snapshot._cachedMarkdown === null) {
    snapshot._cachedMarkdown = nodeToMarkdownFragment(snapshot.node);
  }
  return snapshot._cachedMarkdown;
}

// Current state for external access
// Note: Cleared when editor is destroyed via resetBlockSyncState()
let currentState: BlockSyncPluginState | null = null;

// Pause flag to suppress change detection during programmatic content replacement
let syncPaused = false;

/**
 * Pause or resume sync change detection.
 * Use during setContent/applyBlocks to prevent false insert/delete waves.
 */
export function setSyncPaused(paused: boolean): void {
  syncPaused = paused;
}

// ---------------------------------------------------------------------------
// Inline mark serialization
//
// Reconstructs markdown mark syntax (link, bold, italic, code, strike, highlight)
// from ProseMirror marks. See docs/plans/markdown-html-links-text-url-majestic-mountain.md
// for the design. The alternative — calling Milkdown's own serializer — is
// unavailable here because this plugin is created via `$prose(() => …)` with no
// editor-ctx access at construction time.
//
// Mark names: Milkdown exposes two naming conventions depending on preset/version,
// so each mark accepts a primary name and optional alias. See the plan for the
// full rationale and precedent at `source-mode-plugin.ts:41-56`.
// ---------------------------------------------------------------------------

type CanonicalMarkKey = 'link' | 'strong' | 'emphasis' | 'inlineCode' | 'strike_through' | 'highlight';

const MARK_ALIASES: Record<CanonicalMarkKey, readonly string[]> = {
  link: ['link'],
  strong: ['strong'],
  emphasis: ['emphasis', 'em'],
  inlineCode: ['inlineCode', 'code_inline'],
  strike_through: ['strike_through', 'strikethrough'],
  highlight: ['highlight'],
};

/** Per-mark delimiter strings. Link's close is a function because href/title escape into it. */
const MARK_DELIMITERS: Record<CanonicalMarkKey, { open: string; close: string | ((mark: Mark) => string) }> = {
  link: {
    open: '[',
    close: (mark) => {
      const attrs = mark.attrs as { href?: string; title?: string };
      const href = escapeHref(attrs.href || '');
      const title = attrs.title ? ` "${escapeTitle(attrs.title)}"` : '';
      return `](${href}${title})`;
    },
  },
  highlight: { open: '==', close: '==' },
  strong: { open: '**', close: '**' },
  emphasis: { open: '*', close: '*' },
  strike_through: { open: '~~', close: '~~' },
  inlineCode: { open: '`', close: '`' }, // exclusive; not opened via openFor/closeFor
};

// Outermost-first rank for sort ordering. `inlineCode` is exclusive — not in the stack.
const MARK_RANK: Record<CanonicalMarkKey, number> = {
  link: 0,
  highlight: 1,
  strong: 2,
  emphasis: 3,
  strike_through: 4,
  inlineCode: -1, // unused; exclusive path bypasses the sort
};

// Flat alias → canonical-key lookup, precomputed once to avoid Object.entries scans on the hot path.
const CANONICAL_BY_NAME: Readonly<Record<string, CanonicalMarkKey>> = (() => {
  const map: Record<string, CanonicalMarkKey> = {};
  for (const [key, aliases] of Object.entries(MARK_ALIASES) as [CanonicalMarkKey, readonly string[]][]) {
    for (const alias of aliases) map[alias] = key;
  }
  return map;
})();

function isCodeMark(mark: Mark): boolean {
  return CANONICAL_BY_NAME[mark.type.name] === 'inlineCode';
}

/** Percent-encode href characters that would break CommonMark parsing. */
export function escapeHref(href: string): string {
  return href
    .replace(/\\/g, '%5C')
    .replace(/\(/g, '%28')
    .replace(/\)/g, '%29')
    .replace(/ /g, '%20')
    .replace(/</g, '%3C')
    .replace(/>/g, '%3E')
    .replace(/"/g, '%22');
}

/** Escape the link title portion: backslashes and double-quotes only. */
export function escapeTitle(title: string): string {
  return title.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
}

/**
 * Pad code-span inner text when it starts or ends with a backtick
 * (CommonMark requires spaces in that case to disambiguate the delimiter).
 * @deprecated — use codeSpanFor() which handles internal backtick sequences
 */
export function padCodeSpan(text: string): string {
  let inner = text;
  if (inner.startsWith('`')) inner = ` ${inner}`;
  if (inner.endsWith('`')) inner = `${inner} `;
  return inner;
}

/**
 * Build a CommonMark-correct code span for arbitrary inline-code content.
 * Implements §6.1: delimiter length = longest internal backtick run + 1;
 * space-pads when content starts or ends with a backtick so the delimiter
 * and content backtick are never adjacent (the parser strips those spaces).
 */
export function codeSpanFor(text: string): string {
  // Fast path for the common case: content has no backticks at all.
  // Skips the regex scan and String.repeat allocation that fire on every code-mark text node.
  if (!text.includes('`')) return `\`${text}\``;
  let maxRun = 0;
  for (const m of text.matchAll(/`+/g)) {
    if (m[0].length > maxRun) maxRun = m[0].length;
  }
  const delim = '`'.repeat(maxRun + 1);
  const inner = text.startsWith('`') || text.endsWith('`') ? ` ${text} ` : text;
  return `${delim}${inner}${delim}`;
}

/**
 * Escape inline text. Minimal — see plan for rationale. The leading-char
 * escapes (for `#` / `[^N]:`) apply only to the first text segment of a
 * paragraph, to prevent re-parse-as-heading / re-parse-as-footnote-def.
 */
export function escapeInlineText(text: string, opts: { insideLink: boolean; applyLeadingEscape: boolean }): string {
  let result = text.replace(/\\/g, '\\\\');
  if (opts.insideLink) {
    result = result.replace(/\[/g, '\\[').replace(/\]/g, '\\]');
  }
  if (opts.applyLeadingEscape) {
    result = result.replace(/^(#+\s)/, '\\$1');
    result = result.replace(/^(\[\^\d+\]:)/, '\\$1');
  }
  return result;
}

function openFor(mark: Mark): string {
  const key = CANONICAL_BY_NAME[mark.type.name];
  return key ? MARK_DELIMITERS[key].open : '';
}

function closeFor(mark: Mark): string {
  const key = CANONICAL_BY_NAME[mark.type.name];
  if (!key) return '';
  const close = MARK_DELIMITERS[key].close;
  return typeof close === 'function' ? close(mark) : close;
}

/** Canonical outermost-first comparator for non-code marks. Unknown marks sort last. */
function compareByCanonicalOrder(a: Mark, b: Mark): number {
  const ai = CANONICAL_BY_NAME[a.type.name];
  const bi = CANONICAL_BY_NAME[b.type.name];
  return (ai ? MARK_RANK[ai] : Number.MAX_SAFE_INTEGER) - (bi ? MARK_RANK[bi] : Number.MAX_SAFE_INTEGER);
}

/**
 * Return the known non-code marks of a text node, aligned with the current
 * `active` stack so that marks already open keep their relative order. New
 * marks are appended in canonical order. This mirrors prosemirror-markdown's
 * "mixable mark reorder" step and maximizes the shared prefix with `active`,
 * avoiding spurious close-reopen churn for cases like `**bold [link] bold**`.
 */
function alignedKnownNonCodeMarks(marks: readonly Mark[], active: readonly Mark[]): Mark[] {
  const known = marks.filter((m) => {
    const key = CANONICAL_BY_NAME[m.type.name];
    return key !== undefined && key !== 'inlineCode';
  });
  const inBoth: Mark[] = [];
  for (const a of active) {
    const match = known.find((m) => m.eq(a));
    if (match) inBoth.push(match);
  }
  const newOnes = known.filter((m) => !active.some((a) => a.eq(m)));
  newOnes.sort(compareByCanonicalOrder);
  return [...inBoth, ...newOnes];
}

// Module-scoped one-time-warn set for unknown marks.
const _warnedUnknownMarks = new Set<string>();
function warnUnknownMark(name: string): void {
  if (!_warnedUnknownMarks.has(name)) {
    _warnedUnknownMarks.add(name);
    // eslint-disable-next-line no-console
    console.warn(`block-sync: unknown mark "${name}" — emitting text without delimiters`);
  }
}

/**
 * Fail loud at plugin init if the editor schema is missing all aliases for any
 * mark we expect to serialize. Safer than silently dropping marks after a
 * future Milkdown upgrade retires one alias.
 */
function assertExpectedMarksRegistered(schema: { marks: Record<string, unknown> }): void {
  const missing: CanonicalMarkKey[] = [];
  for (const [key, aliases] of Object.entries(MARK_ALIASES) as [CanonicalMarkKey, readonly string[]][]) {
    const found = aliases.some((name) => name in schema.marks);
    if (!found) missing.push(key);
  }
  if (missing.length > 0) {
    const detail = missing.map((k) => `${k} (aliases: ${MARK_ALIASES[k].join(', ')})`).join('; ');
    const msg = `block-sync: editor schema is missing expected marks: ${detail}. Check Milkdown plugin loading order.`;
    // eslint-disable-next-line no-console
    console.error(msg);
    throw new Error(msg);
  }
}

/**
 * Serialize inline content of a node, preserving citation/annotation/footnote
 * atoms AND inline marks (link, strong, emphasis, inlineCode, strike_through,
 * highlight). Unlike `node.textContent` which strips both atoms and marks.
 */
function serializeInlineContent(node: Node): string {
  if (node.isTextblock) {
    const applyLeadingForBlock = node.type.name === 'paragraph';
    const active: Mark[] = []; // stack, outermost first
    const parts: string[] = [];
    // Track whether we're still at the first visible text segment. Flips
    // false after the first non-empty emit (text or atom) within this block.
    let awaitingFirstEmit = applyLeadingForBlock;

    const closeAllActive = () => {
      while (active.length > 0) {
        parts.push(closeFor(active.pop() as Mark));
      }
    };

    node.forEach((child) => {
      if (child.isText) {
        // Hot-path fast exit: plain text with no marks and no active marks is the
        // overwhelming common case while typing. Skip mark alignment / keep-prefix
        // allocations and emit the escaped text directly.
        if (child.marks.length === 0 && active.length === 0) {
          parts.push(escapeInlineText(child.text || '', { insideLink: false, applyLeadingEscape: awaitingFirstEmit }));
          if (child.text && child.text.length > 0) awaitingFirstEmit = false;
          return;
        }

        // Warn once per unknown mark name.
        for (const m of child.marks) {
          if (!CANONICAL_BY_NAME[m.type.name]) warnUnknownMark(m.type.name);
        }

        const codeMark = child.marks.find(isCodeMark);

        // Code mark is exclusive — close ALL active marks, emit code span.
        // Do NOT reopen stashed marks here: the next child's prefix-matching
        // already opens whatever marks it needs, avoiding stray empty-delimiter
        // pairs when the following node has fewer (or no) marks.
        if (codeMark) {
          closeAllActive();
          parts.push(codeSpanFor(child.text || ''));
          if (child.text && child.text.length > 0) awaitingFirstEmit = false;
          return;
        }

        const desired = alignedKnownNonCodeMarks(child.marks, active);

        // Find longest shared prefix between `active` and `desired` using
        // deep equality. Everything beyond `keep` on `active` must close
        // (innermost first); everything beyond `keep` on `desired` must open.
        let keep = 0;
        while (keep < active.length && keep < desired.length && (active[keep] as Mark).eq(desired[keep] as Mark)) {
          keep++;
        }
        while (active.length > keep) {
          parts.push(closeFor(active.pop() as Mark));
        }
        for (let i = keep; i < desired.length; i++) {
          const m = desired[i] as Mark;
          active.push(m);
          parts.push(openFor(m));
        }

        // Emit escaped text.
        const innermost = active.length > 0 ? active[active.length - 1] : undefined;
        const insideLink = innermost !== undefined && CANONICAL_BY_NAME[innermost.type.name] === 'link';
        parts.push(
          escapeInlineText(child.text || '', {
            insideLink,
            applyLeadingEscape: awaitingFirstEmit,
          })
        );
        if (child.text && child.text.length > 0) awaitingFirstEmit = false;
      } else if (child.type.name === 'citation') {
        closeAllActive();
        const attrs = child.attrs as CitationAttrs;
        if (attrs.rawSyntax) {
          parts.push(attrs.rawSyntax);
        } else {
          try {
            parts.push(serializeCitation(attrs));
          } catch {
            parts.push(`[@${attrs.citekeys}]`);
          }
        }
        awaitingFirstEmit = false;
      } else if (child.type.name === 'annotation') {
        closeAllActive();
        const { type, isCompleted } = child.attrs;
        const text = (child.attrs.text || '')
          .replace(/[\r\n]+/g, ' ')
          .replace(/\s+/g, ' ')
          .trim();
        if (type === 'task') {
          parts.push(`<!-- ::task:: ${isCompleted ? '[x]' : '[ ]'} ${text} -->`);
        } else {
          parts.push(`<!-- ::${type}:: ${text} -->`);
        }
        awaitingFirstEmit = false;
      } else if (child.type.name === 'footnote_ref') {
        closeAllActive();
        parts.push(`[^${child.attrs.label}]`);
        awaitingFirstEmit = false;
      } else if (child.type.name === 'footnote_def') {
        closeAllActive();
        parts.push(`[^${child.attrs.label}]:`);
        // IMPORTANT: Inline atom nodes (citation, annotation, footnote_ref, footnote_def)
        // must be handled explicitly above — child.textContent returns '' for atom nodes.
        awaitingFirstEmit = false;
      } else if (child.type.name === 'math_inline') {
        closeAllActive();
        parts.push(`$${child.attrs.latex || ''}$`);
        awaitingFirstEmit = false;
      } else if (child.type.name === 'hard_break') {
        closeAllActive();
        parts.push('<br>');
        awaitingFirstEmit = false;
      } else {
        closeAllActive();
        parts.push(child.textContent);
        if (child.textContent.length > 0) awaitingFirstEmit = false;
      }
    });

    // Close trailing marks.
    closeAllActive();
    return parts.join('');
  }
  // Container nodes (list_item, blockquote children): recurse.
  const parts: string[] = [];
  node.forEach((child) => {
    parts.push(serializeInlineContent(child));
  });
  return parts.join('\n');
}

/**
 * Escape pipe characters (`|`) that appear outside of backtick code spans.
 * Inside code spans the pipe is part of the code content and must not be escaped.
 */
function escapePipesOutsideCode(text: string): string {
  const parts: string[] = [];
  const codeSpanPattern = /(`+)([\s\S]*?)\1/g;
  let lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = codeSpanPattern.exec(text)) !== null) {
    // Escape pipes in the text before this code span
    parts.push(text.slice(lastIndex, match.index).replace(/\|/g, '\\|'));
    // Keep the code span verbatim (no pipe escaping inside)
    parts.push(match[0]);
    lastIndex = match.index + match[0].length;
  }
  // Escape pipes in the remaining text after the last code span
  parts.push(text.slice(lastIndex).replace(/\|/g, '\\|'));
  return parts.join('');
}

/**
 * Build a markdown fragment from a ProseMirror node.
 * Inline-aware: preserves citations and annotations that node.textContent strips.
 * Exported for unit testing. In production, reached via `getMarkdownFragment`.
 */
export function nodeToMarkdownFragment(node: Node): string {
  const text = serializeInlineContent(node);
  switch (node.type.name) {
    case 'heading': {
      const level = node.attrs.level || 1;
      return `${'#'.repeat(level)} ${text}`;
    }
    case 'paragraph':
      return text;
    case 'blockquote':
      return text
        .split('\n')
        .map((line: string) => `> ${line}`)
        .join('\n');
    case 'code_block': {
      const lang = node.attrs.language || '';
      return `\`\`\`${lang}\n${node.textContent}\n\`\`\``;
    }
    case 'bullet_list': {
      const items: string[] = [];
      node.forEach((child) => {
        items.push(`- ${serializeInlineContent(child)}`);
      });
      return items.join('\n');
    }
    case 'ordered_list': {
      const oItems: string[] = [];
      node.forEach((child, _offset, index) => {
        oItems.push(`${index + 1}. ${serializeInlineContent(child)}`);
      });
      return oItems.join('\n');
    }
    case 'horizontal_rule':
      return '---';
    case 'section_break':
      return '<!-- ::break:: -->';
    case 'figure': {
      const base = `![${node.attrs.alt || ''}](${node.attrs.src || ''})`;
      return node.attrs.width ? `${base}{width=${node.attrs.width}%}` : base;
    }
    case 'math_display':
      return `$$${node.attrs.latex || ''}$$`;
    case 'table': {
      const header: string[] = [];
      const separator: Align[] = [];
      const bodyRows: string[][] = [];

      node.forEach((rowNode, _offset, rowIndex) => {
        const isHeaderRow = rowIndex === 0;
        const cells: string[] = [];

        rowNode.forEach((cellNode) => {
          const rawContent = serializeInlineContent(cellNode);
          cells.push(escapePipesOutsideCode(rawContent));
          if (isHeaderRow) {
            const align = (cellNode.attrs as { align?: string | null }).align;
            separator.push(align === 'left' || align === 'center' || align === 'right' ? align : null);
          }
        });

        if (isHeaderRow) {
          header.push(...cells);
        } else {
          bodyRows.push(cells);
        }
      });

      const parsedTable: ParsedTable = { header, separator, rows: bodyRows };
      return formatTable(parsedTable);
    }
    default:
      return text;
  }
}

/**
 * Get pending block changes and clear them
 * Called by Swift polling
 */
export function getBlockChanges(): BlockChanges {
  if (!currentState) {
    return { updates: [], inserts: [], deletes: [] };
  }

  const changes: BlockChanges = {
    updates: Array.from(currentState.pendingUpdates.values()),
    inserts: Array.from(currentState.pendingInserts.values()),
    deletes: Array.from(currentState.pendingDeletes),
  };

  if (changes.updates.length || changes.inserts.length || changes.deletes.length) {
    syncLog(
      'BlockSync:getChanges',
      `u=${changes.updates.length} i=${changes.inserts.length} d=${changes.deletes.length}`,
      changes.deletes.length > 0 ? `delIds=[${changes.deletes.map((d) => d.slice(0, 8)).join(',')}]` : '',
      changes.inserts.length > 0 ? `insIds=[${changes.inserts.map((i) => i.tempId.slice(0, 13)).join(',')}]` : ''
    );
  }

  // Clear pending changes
  currentState.pendingUpdates.clear();
  currentState.pendingInserts.clear();
  currentState.pendingDeletes.clear();

  return changes;
}

/**
 * Check if there are any pending changes
 */
export function hasPendingChanges(): boolean {
  if (!currentState) return false;
  return (
    currentState.pendingUpdates.size > 0 || currentState.pendingInserts.size > 0 || currentState.pendingDeletes.size > 0
  );
}

/**
 * Take a snapshot of current blocks
 */
export function snapshotBlocks(doc: Node): Map<string, BlockSnapshot> {
  const snapshot = new Map<string, BlockSnapshot>();
  const blockIds = getAllBlockIds();

  // [SYNC-DIAG Phase 0] Collect offsets where blockIds is missing an entry;
  // emit a SINGLE aggregated log line at end of the function (not per skip).
  const skippedOffsets: number[] = [];
  let syncBlockCount = 0;

  // Use doc.forEach() for top-level only traversal, matching BlockParser behavior
  doc.forEach((node, offset) => {
    if (SYNC_BLOCK_TYPES.has(node.type.name)) {
      syncBlockCount++;
      const blockId = blockIds.get(offset);
      if (blockId) {
        // Detect heading syntax in paragraphs (paste creates paragraphs, not headings)
        const headingMatch = node.type.name === 'paragraph' ? node.textContent.match(/^(#{1,6})\s/) : null;
        const effectiveType = headingMatch ? 'heading' : node.type.name === 'figure' ? 'image' : node.type.name;
        const effectiveLevel = headingMatch
          ? headingMatch[1].length
          : node.type.name === 'heading'
            ? node.attrs.level
            : undefined;

        snapshot.set(blockId, {
          id: blockId,
          pos: offset,
          blockType: effectiveType,
          textContent: node.textContent,
          nodeSize: node.nodeSize,
          headingLevel: effectiveLevel,
          node,
          _cachedMarkdown: null, // Lazily computed only when needed
        });
      } else {
        skippedOffsets.push(offset);
      }
    }
  });

  if (SYNC_DIAG_DETAIL && skippedOffsets.length > 0) {
    syncLog(
      'BlockSync:snapshot',
      `SKIP count=${skippedOffsets.length} docBlockCount=${syncBlockCount} existingIdsSize=${blockIds.size} firstOffsets=[${skippedOffsets.slice(0, 5).join(',')}]`
    );
  }

  // [SYNC-DIAG Round 2] Dump all image entries (bounded by actual figure count,
  // typically 10-20) plus first 3 non-image entries for context. Targeted at the
  // figure↔paragraph ID-theft hypothesis.
  if (SYNC_DIAG_DETAIL) {
    const images: string[] = [];
    const nonImages: string[] = [];
    for (const entry of snapshot.values()) {
      const fmt = `(${entry.id.slice(0, 8)},pos=${entry.pos},textLen=${entry.textContent.length},size=${entry.nodeSize})`;
      if (entry.blockType === 'image') {
        images.push(fmt);
      } else if (nonImages.length < 3) {
        nonImages.push(`(${entry.id.slice(0, 8)},pos=${entry.pos},${entry.blockType})`);
      }
    }
    syncLog(
      'BlockSync:snapshot',
      `size=${snapshot.size} images=[${images.join(',')}] firstNonImage=[${nonImages.join(',')}]`
    );
  }

  return snapshot;
}

/**
 * Compare snapshots and detect changes
 */
export function detectChanges(
  oldSnapshot: Map<string, BlockSnapshot>,
  newSnapshot: Map<string, BlockSnapshot>,
  state: BlockSyncPluginState
): void {
  // Detect updates and deletes
  for (const [id, oldBlock] of oldSnapshot) {
    const newBlock = newSnapshot.get(id);
    if (!newBlock) {
      // Block was deleted
      state.pendingDeletes.add(id);
      // Remove from updates if pending
      state.pendingUpdates.delete(id);
      syncLog(
        'BlockSync:detect',
        `DELETE id=${id.slice(0, 8)} type=${oldBlock.blockType} "${oldBlock.textContent.slice(0, 40)}"`
      );
    } else if (oldBlock.node === newBlock.node) {
      // Fast path: same ProseMirror node reference — nothing changed
    } else if (
      oldBlock.textContent !== newBlock.textContent ||
      oldBlock.nodeSize !== newBlock.nodeSize ||
      oldBlock.headingLevel !== newBlock.headingLevel ||
      getMarkdownFragment(oldBlock) !== getMarkdownFragment(newBlock)
    ) {
      // If this block is already pending as an insert, update the insert's content
      // instead of adding a separate update (prevents INSERT+UPDATE overlap → orphan blocks)
      if (state.pendingInserts.has(id)) {
        const existing = state.pendingInserts.get(id)!;
        state.pendingInserts.set(id, {
          ...existing,
          textContent: newBlock.textContent,
          markdownFragment: getMarkdownFragment(newBlock),
          headingLevel: newBlock.headingLevel,
        });
        syncLog(
          'BlockSync:detect',
          `UPDATE-merged-into-INSERT id=${id.slice(0, 13)} "${newBlock.textContent.slice(0, 40)}"`
        );
      } else {
        // Block was updated — lazily compute markdownFragment only for changed blocks
        state.pendingUpdates.set(id, {
          id,
          textContent: newBlock.textContent,
          markdownFragment: getMarkdownFragment(newBlock),
          headingLevel: newBlock.headingLevel,
        });
        if (SYNC_DIAG_DETAIL) {
          const changes: string[] = [];
          if (oldBlock.textContent !== newBlock.textContent) changes.push('text');
          if (oldBlock.nodeSize !== newBlock.nodeSize) changes.push(`size:${oldBlock.nodeSize}→${newBlock.nodeSize}`);
          if (oldBlock.headingLevel !== newBlock.headingLevel)
            changes.push(`level:${oldBlock.headingLevel}→${newBlock.headingLevel}`);
          const typeStr =
            oldBlock.blockType !== newBlock.blockType
              ? `type:${oldBlock.blockType}→${newBlock.blockType}`
              : `type=${newBlock.blockType}`;
          syncLog(
            'BlockSync:detect',
            `UPDATE id=${id.slice(0, 8)} [${changes.join(',')}] ${typeStr} "${newBlock.textContent.slice(0, 40)}"`
          );
        }
      }
    }
  }

  // Detect inserts (new blocks not in old snapshot)
  for (const [id, newBlock] of newSnapshot) {
    if (!oldSnapshot.has(id) && id.startsWith('temp-')) {
      // New block with temporary ID
      // Find the block before this one for ordering
      let afterBlockId: string | undefined;
      const sortedBlocks = Array.from(newSnapshot.entries()).sort((a, b) => a[1].pos - b[1].pos);

      for (let i = 0; i < sortedBlocks.length; i++) {
        if (sortedBlocks[i][0] === id && i > 0) {
          afterBlockId = sortedBlocks[i - 1][0];
          break;
        }
      }

      state.pendingInserts.set(id, {
        tempId: id,
        blockType: newBlock.blockType,
        textContent: newBlock.textContent,
        markdownFragment: getMarkdownFragment(newBlock),
        headingLevel: newBlock.headingLevel,
        afterBlockId,
      });
      syncLog(
        'BlockSync:detect',
        `INSERT tempId=${id.slice(0, 13)} type=${newBlock.blockType} L${newBlock.headingLevel ?? '-'} after=${afterBlockId?.slice(0, 8) ?? 'none'} "${newBlock.textContent.slice(0, 40)}"`
      );
    }
  }
}

// Debounce state for detectChanges() — keeps snapshotBlocks() synchronous
let detectTimer: ReturnType<typeof setTimeout> | null = null;
let pendingOldSnapshot: Map<string, BlockSnapshot> | null = null;
// Always current as of the latest doc-changing transaction — lets a forced
// flush (flushPendingBlockChanges) run detection immediately instead of
// waiting on detectTimer, without needing the setTimeout closure's captured
// reference. See flushPendingBlockChanges() below.
let pendingNewSnapshot: Map<string, BlockSnapshot> | null = null;

// Accumulates temp→permanent ID remappings that arrive mid-debounce.
// Applied to closure-captured snapshots in the setTimeout callback
// before calling detectChanges(), preventing stale temp IDs from
// generating spurious INSERT/UPDATE pairs.
const pendingIdRemap: Map<string, string> = new Map();

/**
 * Re-key a snapshot map using accumulated ID remappings.
 * Must be applied to BOTH capturedOld AND newSnapshot — applying only to one
 * would cause the permanent-ID block to fail the `id.startsWith('temp-')` guard
 * in insert detection, silently losing the insert.
 */
function remapSnapshot(snapshot: Map<string, BlockSnapshot>, remap: Map<string, string>): Map<string, BlockSnapshot> {
  if (remap.size === 0) return snapshot;
  const result = new Map<string, BlockSnapshot>();
  for (const [id, block] of snapshot) {
    const newId = remap.get(id);
    if (newId) {
      result.set(newId, { ...block, id: newId });
    } else {
      result.set(id, block);
    }
  }
  return result;
}

/**
 * Run change detection against the current pending snapshots immediately,
 * cancelling any scheduled debounce timer. Shared by the normal 100ms-debounce
 * path and flushPendingBlockChanges() (an out-of-band forced flush) so both
 * go through the exact same detection logic.
 */
function runPendingDetectChanges(): void {
  if (detectTimer !== null) {
    clearTimeout(detectTimer);
    detectTimer = null;
  }
  if (currentState && pendingOldSnapshot && pendingNewSnapshot) {
    const resolvedOld = remapSnapshot(pendingOldSnapshot, pendingIdRemap);
    const resolvedNew = remapSnapshot(pendingNewSnapshot, pendingIdRemap);
    detectChanges(resolvedOld, resolvedNew, currentState);
  }
  pendingOldSnapshot = null;
  pendingNewSnapshot = null;
  pendingIdRemap.clear();
}

/**
 * Force any debounced-but-not-yet-detected change to be processed right now.
 * Called from Swift's forced poll (`BlockSyncService.pollBlockChangesNow()`)
 * to close a race where a confirming transaction (e.g. footnote-trigger →
 * real footnote marker) lands just before its own 100ms detectTimer fires —
 * the forced poll's `force: true` only skips a Swift-side generation check
 * and does nothing about this JS-side timer on its own. Calling this first
 * guarantees getBlockChanges() reflects the latest transaction, not a stale
 * mid-burst one.
 */
export function flushPendingBlockChanges(): void {
  if (detectTimer === null) return; // nothing pending — normal periodic-poll cadence untouched
  runPendingDetectChanges();
}

// Wrap ProseMirror plugin with $prose for Milkdown compatibility
export const blockSyncPlugin = $prose(() => {
  return new Plugin<BlockSyncPluginState>({
    key: blockSyncPluginKey,

    state: {
      init(_, state) {
        assertExpectedMarksRegistered(state.schema);
        const snapshot = snapshotBlocks(state.doc);
        const initialState: BlockSyncPluginState = {
          lastSnapshot: snapshot,
          pendingUpdates: new Map(),
          pendingInserts: new Map(),
          pendingDeletes: new Set(),
        };
        currentState = initialState;
        return initialState;
      },

      apply(tr, value, _oldState, newState) {
        if (!tr.docChanged || syncPaused) {
          return value;
        }

        // [SYNC-DIAG Round 2] doc.content.size delta — correlates "how much doc actually
        // changed" with the diff churn. Source is explicit (_oldState, not tr.before).
        if (SYNC_DIAG_DETAIL) {
          const pre = _oldState.doc.content.size;
          const post = newState.doc.content.size;
          syncLog('BlockSync:apply', `docSize pre=${pre} post=${post} delta=${post - pre}`);
        }

        // Snapshot is synchronous — needs current block IDs and doc positions
        const newSnapshot = snapshotBlocks(newState.doc);
        pendingNewSnapshot = newSnapshot;

        // Preserve the oldest un-processed snapshot across debounce resets.
        // Without this, rapid keystrokes A→B→C would only diff B→C,
        // losing an insert that happened at A (e.g., pressing Enter).
        if (detectTimer) {
          clearTimeout(detectTimer);
          // Keep existing pendingOldSnapshot from first keystroke in burst
        } else {
          // First keystroke in this debounce window
          pendingOldSnapshot = value.lastSnapshot;
        }

        // Return proper new state first (immutable contract)
        const newValue = {
          ...value,
          lastSnapshot: newSnapshot,
        };
        currentState = newValue;

        detectTimer = setTimeout(() => {
          runPendingDetectChanges();
        }, 100);

        return newValue;
      },
    },
  });
});

/**
 * Reset sync state (called when loading new content or destroying editor)
 * This clears all pending changes and the current state reference
 */
export function resetBlockSyncState(): void {
  // Cancel any pending detect timer — its captured snapshots are stale
  if (detectTimer) {
    clearTimeout(detectTimer);
    detectTimer = null;
    pendingOldSnapshot = null;
    pendingNewSnapshot = null;
  }
  pendingIdRemap.clear();
  if (currentState) {
    currentState.pendingUpdates.clear();
    currentState.pendingInserts.clear();
    currentState.pendingDeletes.clear();
    currentState.lastSnapshot.clear();
  }
  // Don't null out currentState here - it will be recreated on next editor init
}

/**
 * Update snapshot IDs after block ID confirmation (temp→permanent).
 * Re-keys lastSnapshot and pending changes so detectChanges() won't
 * see temp IDs as deleted and permanent IDs as new inserts.
 */
export function updateSnapshotIds(mapping: Map<string, string>): void {
  if (!currentState || mapping.size === 0) return;
  // [SYNC-DIAG Round 2] One log per call, capped 5 pairs
  if (SYNC_DIAG_DETAIL) {
    const pairs = Array.from(mapping.entries())
      .slice(0, 5)
      .map(([oldId, newId]) => `(${oldId.slice(0, 10)}→${newId.slice(0, 8)})`);
    syncLog('BlockSync:updateSnapshotIds', `size=${mapping.size} firstFew=[${pairs.join(',')}]`);
  }
  const updated = new Map<string, BlockSnapshot>();
  for (const [oldId, snapshot] of currentState.lastSnapshot) {
    const newId = mapping.get(oldId);
    if (newId) {
      updated.set(newId, { ...snapshot, id: newId });
    } else {
      updated.set(oldId, snapshot);
    }
  }
  currentState.lastSnapshot = updated;
  // Accumulate for detectTimer — re-keys closure-captured snapshots mid-debounce
  for (const [oldId, newId] of mapping) {
    pendingIdRemap.set(oldId, newId);
  }
  // Re-key any pending changes that reference old temp IDs
  for (const [oldId, newId] of mapping) {
    if (currentState.pendingUpdates.has(oldId)) {
      const update = currentState.pendingUpdates.get(oldId)!;
      currentState.pendingUpdates.delete(oldId);
      currentState.pendingUpdates.set(newId, { ...update, id: newId });
    }
    currentState.pendingInserts.delete(oldId); // Already processed by Swift
    if (currentState.pendingDeletes.has(oldId)) {
      currentState.pendingDeletes.delete(oldId);
      currentState.pendingDeletes.add(newId);
    }
  }
}

/**
 * Reset sync state and rebuild snapshot from the current document.
 * Call after setContent() to prevent false insert/delete waves.
 * Unlike resetBlockSyncState() which clears lastSnapshot (causing all blocks
 * to appear as new on next transaction), this properly captures the current
 * document as the new baseline.
 */
export function resetAndSnapshot(doc: Node): void {
  if (!currentState) return;
  // Cancel any pending detect timer — its captured snapshots are stale
  if (detectTimer) {
    clearTimeout(detectTimer);
    detectTimer = null;
    pendingOldSnapshot = null;
    pendingNewSnapshot = null;
  }
  pendingIdRemap.clear();
  currentState.pendingUpdates.clear();
  currentState.pendingInserts.clear();
  currentState.pendingDeletes.clear();
  currentState.lastSnapshot = snapshotBlocks(doc);
}

/**
 * Like resetAndSnapshot, but first detects any edits that happened while sync
 * was paused (comparing an EXPLICITLY CAPTURED baseline against the current
 * doc) and queues them as genuine pending changes instead of silently
 * discarding them.
 *
 * `baseline` must be a snapshot taken by the caller at the precise moment the
 * paused content push finished settling (e.g. right after setBlockIdsForTopLevel
 * assigns real IDs to freshly-pushed restored content) — NOT the ambient
 * `currentState.lastSnapshot`. That ambient value reflects whatever the doc
 * looked like *before* this pause began, which for a version-history restore
 * is typically an unrelated, already-reset-to-empty document (a separate,
 * unconditional project-switch reset runs immediately beforehand) — comparing
 * against it can never detect an edit to content that didn't exist until the
 * paused push itself. Requiring an explicit, correctly-timed baseline from the
 * caller avoids that entirely, regardless of what else may have mutated
 * ambient state before the pause started.
 *
 * Use ONLY when old and new doc represent the SAME logical document scope
 * (e.g. a version-history restore refreshing the full document) — NEVER when
 * scope is intentionally changing (zoom in/out, project switch), where the
 * two snapshots are expected to differ wholesale and diffing them would risk
 * spurious mass deletes/inserts.
 */
export function detectPausedEditsAndSnapshot(doc: Node, baseline: Map<string, BlockSnapshot>): void {
  if (!currentState) return;
  if (detectTimer) {
    clearTimeout(detectTimer);
    detectTimer = null;
    pendingOldSnapshot = null;
    pendingNewSnapshot = null;
  }
  pendingIdRemap.clear();
  currentState.pendingUpdates.clear();
  currentState.pendingInserts.clear();
  currentState.pendingDeletes.clear();

  const newSnapshot = snapshotBlocks(doc);
  detectChanges(baseline, newSnapshot, currentState);
  currentState.lastSnapshot = newSnapshot;
}

/**
 * Fully clear module state (call when destroying editor instance)
 */
export function destroyBlockSyncState(): void {
  // Cancel any pending detect timer — prevents stale snapshot from leaking into next editor
  if (detectTimer) {
    clearTimeout(detectTimer);
    detectTimer = null;
    pendingOldSnapshot = null;
    pendingNewSnapshot = null;
  }
  pendingIdRemap.clear();
  if (currentState) {
    currentState.pendingUpdates.clear();
    currentState.pendingInserts.clear();
    currentState.pendingDeletes.clear();
    currentState.lastSnapshot.clear();
  }
  currentState = null;
}
