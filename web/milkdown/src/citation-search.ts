// Citation library cache for Milkdown
// Caches CSL items (from the CAYW/Zotero picker flow) across editor toggles so
// citeproc can render bibliographies without waiting on Swift/Zotero again.
// NOTE: citations are inserted via Zotero's native CAYW picker window (see cayw.ts),
// not through any in-app search UI. An earlier in-app "/cite" search popup lived here
// but was never wired to a live call site and has been removed as dead code.

import { type CSLItem, getCiteprocEngine } from './citeproc-engine';

// localStorage key for citation library persistence across editor toggles
const CITATION_CACHE_KEY = 'ff-citation-library';

// Cached items from search results (for citeproc)
let cachedItems: CSLItem[] = [];

// Initialize search with library items (legacy - now just caches items for citeproc)
export function setCitationLibrary(items: CSLItem[]): void {
  cachedItems = items;
  // Persist to localStorage for restoration after editor toggle
  try {
    localStorage.setItem(CITATION_CACHE_KEY, JSON.stringify(items));
  } catch (_e) {
    // Cache storage failed
  }
}

// Restore citation library from localStorage (called on editor init)
export function restoreCitationLibrary(): void {
  try {
    const stored = localStorage.getItem(CITATION_CACHE_KEY);
    if (stored) {
      const items = JSON.parse(stored) as CSLItem[];
      cachedItems = items;
      getCiteprocEngine().setBibliography(items);
    }
  } catch (_e) {
    // Restore failed
  }
}

// Export for window.FinalFinal API
export function getCitationLibrarySize(): number {
  return cachedItems.length;
}

// Export cached items for citeproc
export function getCachedItems(): CSLItem[] {
  return cachedItems;
}

// Get the current citation library (alias for getCachedItems)
export function getCitationLibrary(): CSLItem[] {
  return cachedItems;
}
