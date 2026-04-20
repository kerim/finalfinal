// Block Sync Plugin for tracking changes to blocks
// Tracks inserts, updates, and deletes via ProseMirror transactions
// Exports pending changes for Swift polling via getBlockChanges()

import type { Mark, Node } from '@milkdown/kit/prose/model';
import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import { $prose } from '@milkdown/kit/utils';
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

interface BlockSnapshot {
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

// Outermost-first opening order. `inlineCode` is exclusive — not in the stack.
const MARK_OPEN_ORDER: CanonicalMarkKey[] = ['link', 'highlight', 'strong', 'emphasis', 'strike_through'];

function canonicalMarkKey(name: string): CanonicalMarkKey | null {
  for (const [key, aliases] of Object.entries(MARK_ALIASES) as [CanonicalMarkKey, readonly string[]][]) {
    if (aliases.includes(name)) return key;
  }
  return null;
}

function isCodeMark(mark: Mark): boolean {
  return canonicalMarkKey(mark.type.name) === 'inlineCode';
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
 */
export function padCodeSpan(text: string): string {
  let inner = text;
  if (inner.startsWith('`')) inner = ' ' + inner;
  if (inner.endsWith('`')) inner = inner + ' ';
  return inner;
}

/**
 * Escape inline text. Minimal — see plan for rationale. The leading-char
 * escapes (for `#` / `[^N]:`) apply only to the first text segment of a
 * paragraph, to prevent re-parse-as-heading / re-parse-as-footnote-def.
 */
export function escapeInlineText(
  text: string,
  opts: { insideLink: boolean; applyLeadingEscape: boolean }
): string {
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
  switch (canonicalMarkKey(mark.type.name)) {
    case 'link':
      return '[';
    case 'highlight':
      return '==';
    case 'strong':
      return '**';
    case 'emphasis':
      return '*';
    case 'strike_through':
      return '~~';
    default:
      return '';
  }
}

function closeFor(mark: Mark): string {
  switch (canonicalMarkKey(mark.type.name)) {
    case 'link': {
      const attrs = mark.attrs as { href?: string; title?: string };
      const href = escapeHref(attrs.href || '');
      const title = attrs.title ? ` "${escapeTitle(attrs.title)}"` : '';
      return `](${href}${title})`;
    }
    case 'highlight':
      return '==';
    case 'strong':
      return '**';
    case 'emphasis':
      return '*';
    case 'strike_through':
      return '~~';
    default:
      return '';
  }
}

/** Canonical outermost-first comparator for non-code marks. */
function compareByCanonicalOrder(a: Mark, b: Mark): number {
  const ai = MARK_OPEN_ORDER.indexOf(canonicalMarkKey(a.type.name) as CanonicalMarkKey);
  const bi = MARK_OPEN_ORDER.indexOf(canonicalMarkKey(b.type.name) as CanonicalMarkKey);
  return ai - bi;
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
    const key = canonicalMarkKey(m.type.name);
    return key !== null && key !== 'inlineCode';
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
        // Warn once per unknown mark name.
        for (const m of child.marks) {
          if (canonicalMarkKey(m.type.name) === null) warnUnknownMark(m.type.name);
        }

        const codeMark = child.marks.find(isCodeMark);

        // Code mark is exclusive — close ALL active marks, emit code span, reopen.
        if (codeMark) {
          const stashed = active.slice();
          closeAllActive();
          const inner = padCodeSpan(child.text || '');
          parts.push('`' + inner + '`');
          for (const m of stashed) {
            active.push(m);
            parts.push(openFor(m));
          }
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
        const insideLink = innermost !== undefined && canonicalMarkKey(innermost.type.name) === 'link';
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
    case 'table':
      return node.textContent;
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
function snapshotBlocks(doc: Node): Map<string, BlockSnapshot> {
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
function detectChanges(
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

        const capturedOld = pendingOldSnapshot!;

        // Return proper new state first (immutable contract)
        const newValue = {
          ...value,
          lastSnapshot: newSnapshot,
        };
        currentState = newValue;

        detectTimer = setTimeout(() => {
          if (currentState) {
            // Re-key captured snapshots with any confirmations that arrived mid-debounce
            const resolvedOld = remapSnapshot(capturedOld, pendingIdRemap);
            const resolvedNew = remapSnapshot(newSnapshot, pendingIdRemap);
            detectChanges(resolvedOld, resolvedNew, currentState);
          }
          pendingOldSnapshot = null;
          pendingIdRemap.clear();
          detectTimer = null;
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
  }
  pendingIdRemap.clear();
  currentState.pendingUpdates.clear();
  currentState.pendingInserts.clear();
  currentState.pendingDeletes.clear();
  currentState.lastSnapshot = snapshotBlocks(doc);
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
