// Search state and find/replace functions

import { editorViewCtx } from '@milkdown/kit/core';
import { Selection } from '@milkdown/kit/prose/state';
import { getEditorInstance } from './editor-state';
import { clearSearchMatches, setSearchMatches } from './search-plugin';
import type { FindOptions, FindResult, SearchMatch, SearchState } from './types';

// === Search state ===
let currentSearchQuery = '';
let currentSearchOptions: FindOptions = {};
let searchMatches: SearchMatch[] = [];
let currentMatchIndex = 0;

/**
 * Find all matches in the document for the given query
 * Searches directly within ProseMirror's document structure
 */
export function findAllMatches(query: string, options: FindOptions): SearchMatch[] {
  console.log('[Search] findAllMatches called with query:', JSON.stringify(query), 'options:', options);

  const editorInstance = getEditorInstance();
  if (!editorInstance || !query) {
    console.log('[Search] Early return: editorInstance=', !!editorInstance, 'query=', !!query);
    return [];
  }

  const view = editorInstance.ctx.get(editorViewCtx);
  const doc = view.state.doc;
  const matches: SearchMatch[] = [];

  console.log('[Search] Document size:', doc.content.size);
  console.log('[Search] Document structure:', doc.toString().substring(0, 200));

  // Build regex from query
  let pattern: string;
  let flags = 'g';

  if (options.regexp) {
    pattern = query;
  } else {
    // Escape regex special characters for literal search
    pattern = query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }

  if (options.wholeWord) {
    pattern = `\\b${pattern}\\b`;
  }

  if (!options.caseSensitive) {
    flags += 'i';
  }

  console.log('[Search] Regex pattern:', pattern, 'flags:', flags);

  try {
    const regex = new RegExp(pattern, flags);

    // Walk through all text nodes in the document
    let nodeCount = 0;
    let textNodeCount = 0;
    doc.descendants((node, pos) => {
      nodeCount++;
      if (node.isText && node.text) {
        textNodeCount++;
        const text = node.text;
        console.log(`[Search] Text node #${textNodeCount} at pos`, pos, ':', JSON.stringify(text.substring(0, 80)));

        let match: RegExpExecArray | null;

        // Reset regex for each node
        regex.lastIndex = 0;

        while ((match = regex.exec(text)) !== null) {
          const from = pos + match.index;
          const to = from + match[0].length;

          console.log(
            '[Search] Match found:',
            JSON.stringify(match[0]),
            'at from:',
            from,
            'to:',
            to,
            'docSize:',
            doc.content.size
          );

          // Validate positions are within document bounds
          if (from >= 0 && to <= doc.content.size) {
            matches.push({ from, to });
            console.log('[Search] Match accepted');
          } else {
            console.log('[Search] Match REJECTED - out of bounds');
          }
        }
      }
      return true; // Continue traversal
    });

    console.log('[Search] Visited', nodeCount, 'nodes,', textNodeCount, 'text nodes, found', matches.length, 'matches');
  } catch (e) {
    console.log('[Search] Regex error:', e);
    // Invalid regex, return empty
  }

  // Sort matches by position (descendants may not visit in order for complex docs)
  matches.sort((a, b) => a.from - b.from);

  return matches;
}

/**
 * Navigate to a specific match
 */
export function goToMatch(index: number): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance || searchMatches.length === 0) return;

  // Wrap around
  if (index < 0) index = searchMatches.length - 1;
  if (index >= searchMatches.length) index = 0;

  currentMatchIndex = index;
  const match = searchMatches[index];

  const view = editorInstance.ctx.get(editorViewCtx);

  // Select the match
  try {
    const selection = Selection.near(view.state.doc.resolve(match.from));
    view.dispatch(view.state.tr.setSelection(selection).scrollIntoView());
    view.focus();
  } catch (_e) {
    // Position resolution failed
  }

  // Trigger decoration update
  updateSearchDecorations();
}

/**
 * Update search decorations to highlight matches
 */
export function updateSearchDecorations(): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;

  // Dispatch an empty transaction to trigger decoration refresh
  // The actual decorations are handled via a plugin (see below)
  const view = editorInstance.ctx.get(editorViewCtx);
  view.dispatch(view.state.tr.setMeta('searchUpdate', true));
}

// === Find/Replace API implementations ===

export function find(query: string, options?: FindOptions): FindResult {
  const editorInstance = getEditorInstance();
  if (!editorInstance) {
    return { matchCount: 0, currentIndex: 0 };
  }

  currentSearchQuery = query;
  currentSearchOptions = options || {};

  if (!query) {
    clearSearch();
    return { matchCount: 0, currentIndex: 0 };
  }

  // Find all matches
  searchMatches = findAllMatches(query, currentSearchOptions);
  currentMatchIndex = searchMatches.length > 0 ? 0 : 0;

  // Update decorations
  setSearchMatches(searchMatches, currentMatchIndex);

  // If we have matches, navigate to the first one near cursor
  if (searchMatches.length > 0) {
    const view = editorInstance.ctx.get(editorViewCtx);
    const cursorPos = view.state.selection.from;

    // Find the first match at or after cursor
    let nearestIndex = 0;
    for (let i = 0; i < searchMatches.length; i++) {
      if (searchMatches[i].from >= cursorPos) {
        nearestIndex = i;
        break;
      }
    }

    currentMatchIndex = nearestIndex;
    setSearchMatches(searchMatches, currentMatchIndex);
    goToMatch(currentMatchIndex);
  }

  // Trigger decoration update
  updateSearchDecorations();

  return { matchCount: searchMatches.length, currentIndex: currentMatchIndex + 1 };
}

export function findNext(): FindResult | null {
  const editorInstance = getEditorInstance();
  if (!editorInstance || !currentSearchQuery || searchMatches.length === 0) {
    return null;
  }

  currentMatchIndex = (currentMatchIndex + 1) % searchMatches.length;
  setSearchMatches(searchMatches, currentMatchIndex);
  goToMatch(currentMatchIndex);

  return { matchCount: searchMatches.length, currentIndex: currentMatchIndex + 1 };
}

export function findPrevious(): FindResult | null {
  const editorInstance = getEditorInstance();
  if (!editorInstance || !currentSearchQuery || searchMatches.length === 0) {
    return null;
  }

  currentMatchIndex = (currentMatchIndex - 1 + searchMatches.length) % searchMatches.length;
  setSearchMatches(searchMatches, currentMatchIndex);
  goToMatch(currentMatchIndex);

  return { matchCount: searchMatches.length, currentIndex: currentMatchIndex + 1 };
}

export function replaceCurrent(replacement: string): boolean {
  const editorInstance = getEditorInstance();
  if (!editorInstance || !currentSearchQuery || searchMatches.length === 0) {
    return false;
  }

  const match = searchMatches[currentMatchIndex];
  if (!match) return false;

  try {
    const view = editorInstance.ctx.get(editorViewCtx);

    // Replace the current match
    const tr = view.state.tr.replaceWith(match.from, match.to, view.state.schema.text(replacement));
    view.dispatch(tr);

    // Recalculate matches after replacement
    searchMatches = findAllMatches(currentSearchQuery, currentSearchOptions);

    // Adjust current index if needed
    if (currentMatchIndex >= searchMatches.length) {
      currentMatchIndex = Math.max(0, searchMatches.length - 1);
    }

    setSearchMatches(searchMatches, currentMatchIndex);
    updateSearchDecorations();

    // Navigate to the current match (which is now the next one)
    if (searchMatches.length > 0) {
      goToMatch(currentMatchIndex);
    }

    return true;
  } catch (_e) {
    return false;
  }
}

export function replaceAll(replacement: string): number {
  const editorInstance = getEditorInstance();
  if (!editorInstance || !currentSearchQuery || searchMatches.length === 0) {
    return 0;
  }

  const count = searchMatches.length;

  try {
    const view = editorInstance.ctx.get(editorViewCtx);

    // Replace all matches in reverse order (to preserve positions)
    let tr = view.state.tr;
    const reversedMatches = [...searchMatches].reverse();

    for (const match of reversedMatches) {
      tr = tr.replaceWith(match.from, match.to, view.state.schema.text(replacement));
    }

    view.dispatch(tr);

    // Clear search state after replace all
    searchMatches = [];
    currentMatchIndex = 0;
    setSearchMatches(searchMatches, currentMatchIndex);
    updateSearchDecorations();

    return count;
  } catch (_e) {
    return 0;
  }
}

export function clearSearch(): void {
  currentSearchQuery = '';
  currentSearchOptions = {};
  searchMatches = [];
  currentMatchIndex = 0;
  clearSearchMatches();

  const editorInstance = getEditorInstance();
  if (editorInstance) {
    updateSearchDecorations();
  }
}

export function getSearchState(): SearchState | null {
  if (!currentSearchQuery) {
    return null;
  }

  return {
    query: currentSearchQuery,
    matchCount: searchMatches.length,
    currentIndex: currentMatchIndex + 1,
    options: currentSearchOptions,
  };
}
