// Citation Search Popup for Milkdown
// Provides /cite slash command with Swift-bridged search via JSON-RPC
// Inserts Pandoc-style citations at cursor

import { Selection } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { type CSLItem, getCiteprocEngine } from './citeproc-engine';

// localStorage key for citation library persistence across editor toggles
const CITATION_CACHE_KEY = 'ff-citation-library';

// Search popup state
let searchPopup: HTMLElement | null = null;
let selectedIndex = 0;
let filteredResults: CSLItem[] = [];
let currentCmdStart = 0;
let currentView: EditorView | null = null;

// Cached items from search results (for citeproc)
let cachedItems: CSLItem[] = [];

// Debounce timer for search
let searchDebounceTimer: ReturnType<typeof setTimeout> | null = null;

// Track if search is in progress
let _isSearching = false;

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

// Search citations via Swift bridge (calls Zotero JSON-RPC)
function searchCitationsViaSwift(query: string): void {
  if (!query.trim()) {
    // Show "type to search" message for empty query
    updateResultsDisplay([]);
    return;
  }

  // Call Swift message handler
  if (typeof (window as any).webkit?.messageHandlers?.searchCitations?.postMessage === 'function') {
    _isSearching = true;
    updateSearchingState();
    (window as any).webkit.messageHandlers.searchCitations.postMessage(query);
  } else {
    // Fallback: no Swift bridge available (dev mode)
    updateResultsDisplay([]);
  }
}

// Callback from Swift with search results
export function searchCitationsCallback(items: CSLItem[]): void {
  try {
    _isSearching = false;
    // Cache results for citeproc
    for (const item of items) {
      const existing = cachedItems.find((i) => i.id === item.id);
      if (!existing) {
        cachedItems.push(item);
      }
    }
    filteredResults = items;
    updateResultsDisplay(items);

    // Update citeproc engine with all cached items so citations can render
    getCiteprocEngine().setBibliography(cachedItems);

    // Persist accumulated items to localStorage
    try {
      localStorage.setItem(CITATION_CACHE_KEY, JSON.stringify(cachedItems));
    } catch (_e) {
      // Cache storage failed
    }
  } catch (error) {
    _isSearching = false;
    console.error('[Citation Search] Callback error:', error);
    filteredResults = [];
    updateResultsDisplay([]);
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

// Update UI to show searching state
function updateSearchingState(): void {
  if (!searchPopup) return;

  const resultsContainer = searchPopup.querySelector('.ff-citation-search-results');
  if (!resultsContainer) return;

  // Clear existing results
  while (resultsContainer.firstChild) {
    resultsContainer.removeChild(resultsContainer.firstChild);
  }

  const searching = document.createElement('div');
  searching.style.cssText = 'padding: 16px; text-align: center; color: var(--editor-muted, #999);';
  searching.textContent = 'Searching Zotero...';
  resultsContainer.appendChild(searching);
}

// Create popup UI
function createPopup(): HTMLElement {
  const popup = document.createElement('div');
  popup.className = 'ff-citation-search';
  popup.style.cssText = `
    position: absolute;
    z-index: 1000;
    background: var(--editor-bg, white);
    border: 1px solid var(--editor-border, #e0e0e0);
    border-radius: 8px;
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.15);
    max-width: 400px;
    min-width: 300px;
    max-height: 350px;
    overflow: hidden;
    display: flex;
    flex-direction: column;
  `;

  // Search input
  const inputWrapper = document.createElement('div');
  inputWrapper.style.cssText = 'padding: 8px; border-bottom: 1px solid var(--editor-border, #e0e0e0);';

  const input = document.createElement('input');
  input.type = 'text';
  input.placeholder = 'Search citations...';
  input.className = 'ff-citation-search-input';
  input.style.cssText = `
    width: 100%;
    padding: 8px 12px;
    border: 1px solid var(--editor-border, #e0e0e0);
    border-radius: 4px;
    font-size: 14px;
    outline: none;
    background: var(--editor-bg, white);
    color: var(--editor-text, #333);
  `;

  inputWrapper.appendChild(input);
  popup.appendChild(inputWrapper);

  // Results container
  const results = document.createElement('div');
  results.className = 'ff-citation-search-results';
  results.style.cssText = `
    overflow-y: auto;
    flex: 1;
    padding: 4px 0;
  `;
  popup.appendChild(results);

  return popup;
}

// Create result item element
function createResultItem(item: CSLItem, index: number, isSelected: boolean): HTMLElement {
  const div = document.createElement('div');
  div.className = `ff-citation-search-item${isSelected ? ' selected' : ''}`;
  div.dataset.index = String(index);
  div.style.cssText = `
    padding: 8px 12px;
    cursor: pointer;
    ${isSelected ? 'background: var(--editor-selection, #e8f0fe);' : ''}
  `;

  // Author(s)
  const authorNames = item.author?.map((a) => a.family || a.literal || a.given || '').filter(Boolean) || [];
  const authorText =
    authorNames.length > 0
      ? authorNames.length > 2
        ? `${authorNames[0]} et al.`
        : authorNames.join(' & ')
      : 'Unknown';

  // Year
  const year = item.issued?.['date-parts']?.[0]?.[0] || item.issued?.raw?.match(/\d{4}/)?.[0] || 'n.d.';

  // Citekey (use bracket notation for hyphenated JSON key from Swift encoding)
  const citekey = (item as any)['citation-key'] || item.citationKey || item.id;

  // Title
  const title = document.createElement('div');
  title.style.cssText = 'font-size: 13px; margin-bottom: 2px; color: var(--editor-text, #333);';
  title.textContent = item.title || 'Untitled';
  div.appendChild(title);

  // Metadata row
  const meta = document.createElement('div');
  meta.style.cssText = 'font-size: 11px; color: var(--editor-muted, #666); display: flex; gap: 8px;';

  const authorSpan = document.createElement('span');
  authorSpan.textContent = authorText;
  meta.appendChild(authorSpan);

  const yearSpan = document.createElement('span');
  yearSpan.textContent = `(${year})`;
  meta.appendChild(yearSpan);

  const keySpan = document.createElement('span');
  keySpan.style.cssText = 'font-family: monospace; opacity: 0.7;';
  keySpan.textContent = `@${citekey}`;
  meta.appendChild(keySpan);

  div.appendChild(meta);

  // Click handler
  div.addEventListener('click', () => {
    selectItem(index);
  });

  // Hover handler
  div.addEventListener('mouseenter', () => {
    selectedIndex = index;
    updateSelection();
  });

  return div;
}

// Update results display with items from Swift search
function updateResultsDisplay(items: CSLItem[]): void {
  if (!searchPopup) return;

  const resultsContainer = searchPopup.querySelector('.ff-citation-search-results');
  if (!resultsContainer) return;

  // Clear existing results safely using DOM methods
  while (resultsContainer.firstChild) {
    resultsContainer.removeChild(resultsContainer.firstChild);
  }

  filteredResults = items;
  selectedIndex = 0;

  // Get current search query
  const input = searchPopup.querySelector('input') as HTMLInputElement;
  const query = input?.value || '';

  if (items.length === 0) {
    const noResults = document.createElement('div');
    noResults.style.cssText = 'padding: 16px; text-align: center; color: var(--editor-muted, #999);';
    noResults.textContent = query.trim() ? 'No matching citations found.' : 'Type to search your Zotero library...';
    resultsContainer.appendChild(noResults);
    return;
  }

  // Add result items
  items.forEach((item, index) => {
    resultsContainer.appendChild(createResultItem(item, index, index === selectedIndex));
  });
}

// Update selection highlight
function updateSelection(): void {
  if (!searchPopup) return;

  const items = searchPopup.querySelectorAll('.ff-citation-search-item');
  items.forEach((item, i) => {
    const isSelected = i === selectedIndex;
    item.classList.toggle('selected', isSelected);
    (item as HTMLElement).style.background = isSelected ? 'var(--editor-selection, #e8f0fe)' : '';
  });

  // Scroll into view
  const selectedItem = items[selectedIndex] as HTMLElement;
  if (selectedItem) {
    selectedItem.scrollIntoView({ block: 'nearest' });
  }
}

// Select and insert citation
function selectItem(index: number): void {
  if (index < 0 || index >= filteredResults.length) return;

  const item = filteredResults[index];
  // Use bracket notation for hyphenated JSON key from Swift encoding
  const citekey = (item as any)['citation-key'] || item.citationKey || item.id;

  insertCitation(citekey);
}

// Insert citation at cursor
function insertCitation(citekey: string): void {
  if (!currentView) {
    hideSearchPopup();
    return;
  }

  const { state, dispatch } = currentView;
  const citationType = state.schema.nodes.citation;

  if (!citationType) {
    hideSearchPopup();
    return;
  }

  const from = currentCmdStart;
  const to = state.selection.from;

  // Step 1: Validate positions using resolve() - catches out-of-range errors
  let $from, _$to;
  try {
    $from = state.doc.resolve(from);
    _$to = state.doc.resolve(to);
  } catch (_e) {
    hideSearchPopup();
    return;
  }

  // Step 2: Verify parent accepts inline content
  const parent = $from.parent;
  if (!parent.inlineContent) {
    hideSearchPopup();
    return;
  }

  // Step 3: Create citation node
  let citationNode;
  try {
    citationNode = citationType.create({
      citekeys: citekey,
      locators: '[]',
      prefix: '',
      suffix: '',
      suppressAuthor: false,
      rawSyntax: `[@${citekey}]`,
    });
  } catch (_e) {
    hideSearchPopup();
    return;
  }

  // Step 4: Create and dispatch transaction using replaceRangeWith
  // (handles position mapping internally, more reliable than delete + insert)
  try {
    let tr = state.tr.replaceRangeWith(from, to, citationNode);

    // Set cursor after the inserted citation node
    const insertPos = from + citationNode.nodeSize;
    tr = tr.setSelection(Selection.near(tr.doc.resolve(insertPos)));

    dispatch(tr);
    currentView.focus();
  } catch (_e) {
    // Fallback: insert as text (user will see raw markdown until reload)
    try {
      const textNode = state.schema.text(`[@${citekey}]`);
      const tr = state.tr.replaceRangeWith(from, to, textNode);
      dispatch(tr);
      currentView.focus();
    } catch (_e2) {
      // Text fallback also failed
    }
  }

  hideSearchPopup();
}

// Show the search popup
export function showCitationSearchPopup(cmdStart: number, view: EditorView): void {
  // Store context
  currentCmdStart = cmdStart;
  currentView = view;

  // Create popup if needed
  if (!searchPopup) {
    searchPopup = createPopup();
    document.body.appendChild(searchPopup);
  }

  // Position popup near cursor
  const coords = view.coordsAtPos(view.state.selection.from);
  if (coords) {
    searchPopup.style.left = `${coords.left}px`;
    searchPopup.style.top = `${coords.bottom + 8}px`;
  }

  // Show popup
  searchPopup.style.display = 'flex';

  // Show initial "type to search" message
  updateResultsDisplay([]);

  // Focus input
  const input = searchPopup.querySelector('input') as HTMLInputElement;
  if (input) {
    input.value = '';
    input.focus();

    // Input handler with debounce
    input.oninput = () => {
      // Clear any pending search
      if (searchDebounceTimer) {
        clearTimeout(searchDebounceTimer);
      }

      const query = input.value.trim();

      if (!query) {
        // Immediately show "type to search" for empty input
        updateResultsDisplay([]);
        return;
      }

      // Debounce search requests (300ms)
      searchDebounceTimer = setTimeout(() => {
        searchCitationsViaSwift(query);
      }, 300);
    };

    // Keyboard handler
    input.onkeydown = (e) => {
      if (e.key === 'ArrowDown') {
        e.preventDefault();
        selectedIndex = Math.min(selectedIndex + 1, filteredResults.length - 1);
        updateSelection();
      } else if (e.key === 'ArrowUp') {
        e.preventDefault();
        selectedIndex = Math.max(selectedIndex - 1, 0);
        updateSelection();
      } else if (e.key === 'Enter') {
        e.preventDefault();
        selectItem(selectedIndex);
      } else if (e.key === 'Escape') {
        e.preventDefault();
        hideSearchPopup();
        view.focus();
      } else if (e.key === 'Tab') {
        e.preventDefault();
        selectItem(selectedIndex);
      }
    };

    // Blur handler
    input.onblur = () => {
      // Delay to allow click on results
      setTimeout(() => {
        if (!searchPopup?.contains(document.activeElement)) {
          hideSearchPopup();
        }
      }, 150);
    };
  }
}

// Hide the search popup
export function hideSearchPopup(): void {
  if (searchPopup) {
    searchPopup.style.display = 'none';
    // Clear input handlers to prevent stale references
    const input = searchPopup.querySelector('input') as HTMLInputElement;
    if (input) {
      input.oninput = null;
      input.onkeydown = null;
      input.onblur = null;
    }
  }
  // Clear pending search timer
  if (searchDebounceTimer) {
    clearTimeout(searchDebounceTimer);
    searchDebounceTimer = null;
  }
  currentView = null;
  filteredResults = [];
  selectedIndex = 0;
  _isSearching = false;
}

// Check if popup is visible
export function isSearchPopupVisible(): boolean {
  return searchPopup?.style.display === 'flex';
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
