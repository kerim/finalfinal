// Block Sync Plugin for tracking changes to blocks
// Tracks inserts, updates, and deletes via ProseMirror transactions
// Exports pending changes for Swift polling via getBlockChanges()

import type { Node } from '@milkdown/kit/prose/model';
import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import { $prose } from '@milkdown/kit/utils';
import { getAllBlockIds } from './block-id-plugin';
import type { CitationAttrs } from './citation-plugin';
import { serializeCitation } from './citation-plugin';

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
  markdownFragment: string; // Detect attr-only changes (citation edits)
  headingLevel?: number;
  node: Node; // Store node reference for markdown serialization
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

/**
 * Serialize inline content of a node, preserving citation atoms and annotations.
 * Unlike node.textContent which strips atom nodes, this reconstructs their markdown syntax.
 */
function serializeInlineContent(node: Node): string {
  if (node.isTextblock) {
    let result = '';
    node.forEach((child) => {
      if (child.isText) {
        result += child.text || '';
      } else if (child.type.name === 'citation') {
        const attrs = child.attrs as CitationAttrs;
        if (attrs.rawSyntax) {
          result += attrs.rawSyntax;
        } else {
          try {
            result += serializeCitation(attrs);
          } catch {
            result += `[@${attrs.citekeys}]`;
          }
        }
      } else if (child.type.name === 'annotation') {
        const { type, isCompleted } = child.attrs;
        const text = (child.attrs.text || '')
          .replace(/[\r\n]+/g, ' ')
          .replace(/\s+/g, ' ')
          .trim();
        if (type === 'task') {
          result += `<!-- ::task:: ${isCompleted ? '[x]' : '[ ]'} ${text} -->`;
        } else {
          result += `<!-- ::${type}:: ${text} -->`;
        }
      } else if (child.type.name === 'footnote_ref') {
        result += `[^${child.attrs.label}]`;
      } else if (child.type.name === 'footnote_def') {
        result += `[^${child.attrs.label}]:`;
        // IMPORTANT: Inline atom nodes (citation, annotation, footnote_ref, footnote_def)
        // must be handled explicitly above — child.textContent returns '' for atom nodes.
      } else {
        result += child.textContent;
      }
    });
    return result;
  }
  // Container nodes (list_item, blockquote children): recurse
  const parts: string[] = [];
  node.forEach((child) => {
    parts.push(serializeInlineContent(child));
  });
  return parts.join('\n');
}

/**
 * Build a markdown fragment from a ProseMirror node.
 * Inline-aware: preserves citations and annotations that node.textContent strips.
 */
function nodeToMarkdownFragment(node: Node): string {
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
    case 'figure':
      return `![${node.attrs.alt || ''}](${node.attrs.src || ''})`;
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

  // Use doc.forEach() for top-level only traversal, matching BlockParser behavior
  doc.forEach((node, offset) => {
    if (SYNC_BLOCK_TYPES.has(node.type.name)) {
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
          markdownFragment: nodeToMarkdownFragment(node),
          headingLevel: effectiveLevel,
          node,
        });
      }
    }
  });

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
    } else if (
      oldBlock.textContent !== newBlock.textContent ||
      oldBlock.nodeSize !== newBlock.nodeSize ||
      oldBlock.markdownFragment !== newBlock.markdownFragment ||
      oldBlock.headingLevel !== newBlock.headingLevel
    ) {
      // Block was updated — use pre-computed markdownFragment from snapshot
      state.pendingUpdates.set(id, {
        id,
        textContent: newBlock.textContent,
        markdownFragment: newBlock.markdownFragment,
        headingLevel: newBlock.headingLevel,
      });
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
        markdownFragment: newBlock.markdownFragment,
        headingLevel: newBlock.headingLevel,
        afterBlockId,
      });
    }
  }
}

// Debounce state for detectChanges() — keeps snapshotBlocks() synchronous
let detectTimer: ReturnType<typeof setTimeout> | null = null;
let pendingOldSnapshot: Map<string, BlockSnapshot> | null = null;

// Wrap ProseMirror plugin with $prose for Milkdown compatibility
export const blockSyncPlugin = $prose(() => {
  return new Plugin<BlockSyncPluginState>({
    key: blockSyncPluginKey,

    state: {
      init(_, state) {
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
            detectChanges(capturedOld, newSnapshot, currentState);
          }
          pendingOldSnapshot = null;
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
  if (currentState) {
    currentState.pendingUpdates.clear();
    currentState.pendingInserts.clear();
    currentState.pendingDeletes.clear();
    currentState.lastSnapshot.clear();
  }
  currentState = null;
}
