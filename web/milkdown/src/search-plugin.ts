/**
 * Search decoration plugin for Milkdown
 * Provides visual highlighting for search matches
 */

import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import { Decoration, DecorationSet } from '@milkdown/kit/prose/view';
import { $prose } from '@milkdown/kit/utils';

// Search state shared with main.ts
interface SearchMatch {
  from: number;
  to: number;
}

let matches: SearchMatch[] = [];
let currentIndex = 0;

// Plugin key for accessing state
export const searchPluginKey = new PluginKey('search-decorations');

/**
 * Update the search matches to highlight
 */
export function setSearchMatches(newMatches: SearchMatch[], current: number): void {
  matches = newMatches;
  currentIndex = current;
}

/**
 * Clear all search highlights
 */
export function clearSearchMatches(): void {
  matches = [];
  currentIndex = 0;
}

/**
 * Get the current search matches
 */
export function getSearchMatches(): { matches: SearchMatch[]; currentIndex: number } {
  return { matches, currentIndex };
}

/**
 * Search decoration plugin
 * Creates decorations for all matches, with special styling for current match
 */
export const searchPlugin = $prose(() => {
  return new Plugin({
    key: searchPluginKey,
    props: {
      decorations(state) {
        if (matches.length === 0) {
          return DecorationSet.empty;
        }

        const decorations: Decoration[] = [];

        for (let i = 0; i < matches.length; i++) {
          const match = matches[i];

          // Validate positions are within document bounds
          if (match.from < 0 || match.to > state.doc.content.size) {
            continue;
          }

          const className = i === currentIndex ? 'search-match search-match-current' : 'search-match';

          try {
            decorations.push(Decoration.inline(match.from, match.to, { class: className }));
          } catch (_e) {
            // Invalid position, skip
          }
        }

        return DecorationSet.create(state.doc, decorations);
      },
    },
  });
});

export default searchPlugin;
