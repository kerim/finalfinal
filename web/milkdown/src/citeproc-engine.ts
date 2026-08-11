// Citeproc Engine Wrapper
// Provides citation formatting using citeproc-js library
// Requires CSL style and locale XML files

// @ts-expect-error - citeproc doesn't have type definitions
import CSL from 'citeproc';

// Import bundled CSL style and locale via Vite's ?raw suffix
// chicago-author-date.csl lives under Resources/Export — it's also read at
// runtime by Swift (ExportService+PandocResources.swift) for PDF export.
// That copy is the single source of truth; do not re-add a web/ copy.
import chicagoStyle from '../../../final final/Resources/Export/chicago-author-date.csl?raw';
import localeEnUS from './locales/locales-en-US.xml?raw';

// CSL-JSON item interface (matches Swift CSLItem)
export interface CSLItem {
  id: string;
  type: string;
  title?: string;
  author?: CSLName[];
  editor?: CSLName[];
  issued?: CSLDate;
  accessed?: CSLDate;
  'container-title'?: string;
  publisher?: string;
  'publisher-place'?: string;
  DOI?: string;
  ISBN?: string;
  ISSN?: string;
  URL?: string;
  volume?: string | number;
  issue?: string | number;
  page?: string;
  abstract?: string;
  note?: string;
  citationKey?: string;
}

export interface CSLName {
  family?: string;
  given?: string;
  literal?: string;
}

export interface CSLDate {
  'date-parts'?: number[][];
  raw?: string;
  literal?: string;
}

// Citeproc sys object interface
interface CiteprocSys {
  retrieveLocale: (lang: string) => string;
  retrieveItem: (id: string) => CSLItem | undefined;
}

// Citation formatting options
// Arrays are per-citation (indexed to match citekeys order)
// Single values apply to the entire cluster
export interface CitationOptions {
  suppressAuthors?: boolean[]; // Per-citation suppress flags
  locators?: string[]; // Per-citation locators (page numbers, etc.)
  prefix?: string; // Applies to first citation in cluster
  suffix?: string; // Applies to last citation in cluster
}

// Resolve the key to store/look up an item under.
// Prefer the CSL `id` (Better BibTeX's canonical KeyManager key, the field BBT actually
// resolves/matches by); fall back to citation-key/citationKey only when `id` is absent or
// empty. This mirrors the Swift-side fix (ZoteroService / ZoteroService+LibraryScope): BBT
// can report a stale `citation-key` (from a legacy `Citation Key:` line in the item's Zotero
// Extra field) that differs from its own `id` for the same item.
// Note: bracket notation for hyphenated JSON key from Swift encoding.
//
// Exported so every place in the app that reads/writes/caches an item "by its citekey" (the
// citation search/insert popup, pending-resolution bookkeeping, etc.) shares this exact
// precedence instead of re-deriving it with the wrong order.
export function resolveKey(item: CSLItem): string | undefined {
  const key = item.id || (item as any)['citation-key'] || item.citationKey;
  return key || undefined;
}

class CiteprocEngine {
  private engine: any;
  private items: Map<string, CSLItem> = new Map();
  private styleXML: string;
  private localeXML: string;

  constructor(styleXML?: string, localeXML?: string) {
    this.styleXML = styleXML || chicagoStyle;
    this.localeXML = localeXML || localeEnUS;
    this.initEngine();
  }

  private initEngine() {
    const sys: CiteprocSys = {
      retrieveLocale: () => this.localeXML,
      retrieveItem: (id: string) => this.items.get(id.toLowerCase()),
    };

    try {
      this.engine = new CSL.Engine(sys, this.styleXML);
    } catch (error) {
      console.error('[CiteprocEngine] Failed to initialize:', error);
      throw error;
    }
  }

  // Lookups/storage are case-insensitive: BBT's `id` casing can differ from the casing used
  // in the document (e.g. `Friedman2010` vs `friedman2010`).
  private static normalize(key: string): string {
    return key.toLowerCase();
  }

  // Set the bibliography items
  setBibliography(items: CSLItem[]): void {
    this.items.clear();
    items.forEach((item) => {
      const key = resolveKey(item);
      if (!key) return;
      const normalizedKey = CiteprocEngine.normalize(key);
      this.items.set(normalizedKey, { ...item, id: normalizedKey });
    });

    // Update engine with new item IDs
    const ids = Array.from(this.items.keys());
    if (ids.length > 0) {
      try {
        this.engine.updateItems(ids);
      } catch (_error) {
        // Update failed
      }
    }
  }

  // Add items to the bibliography without replacing existing ones
  addItems(items: CSLItem[]): void {
    items.forEach((item) => {
      const key = resolveKey(item);
      if (!key) return;
      const normalizedKey = CiteprocEngine.normalize(key);
      this.items.set(normalizedKey, { ...item, id: normalizedKey });
    });

    // Update engine with all item IDs
    const ids = Array.from(this.items.keys());
    if (ids.length > 0) {
      try {
        this.engine.updateItems(ids);
      } catch (_error) {
        // Update failed
      }
    }
  }

  // Check if an item exists in the bibliography
  hasItem(citekey: string): boolean {
    return this.items.has(CiteprocEngine.normalize(citekey));
  }

  // Get an item by citekey
  getItem(citekey: string): CSLItem | undefined {
    return this.items.get(CiteprocEngine.normalize(citekey));
  }

  // Format a single citation (e.g., "(Smith, 2023)")
  formatCitation(citekeys: string[], options?: CitationOptions): string {
    if (citekeys.length === 0) return '';

    // Filter to only existing citekeys (case-insensitive)
    const validKeys = citekeys.filter((key) => this.hasItem(key));
    if (validKeys.length === 0) {
      // Return unresolved indicator
      return citekeys.map((k) => `${k}?`).join('; ');
    }

    try {
      // Build citation cluster with per-citation options
      const citationItems = validKeys.map((key, index) => ({
        id: CiteprocEngine.normalize(key),
        ...(options?.suppressAuthors?.[index] ? { 'suppress-author': true } : {}),
        ...(options?.locators?.[index] ? { locator: options.locators[index] } : {}),
        ...(index === 0 && options?.prefix ? { prefix: options.prefix } : {}),
        ...(index === validKeys.length - 1 && options?.suffix ? { suffix: options.suffix } : {}),
      }));

      const citation = {
        citationItems,
        properties: { noteIndex: 0 },
      };

      // Process citation
      const result = this.engine.processCitationCluster(citation, [], []);

      // result[1] is an array of [index, formattedString] pairs
      if (result?.[1] && result[1].length > 0) {
        return result[1][0][1];
      }

      return validKeys.join('; ');
    } catch (error) {
      console.error('[CiteprocEngine] formatCitation error:', error);
      return citekeys.join('; ');
    }
  }

  // Generate formatted bibliography entries
  generateBibliography(citekeys?: string[]): string[] {
    try {
      // If specific citekeys provided, update items to only those (case-insensitive)
      const keysToUse = citekeys
        ? citekeys.filter((k) => this.hasItem(k)).map((k) => CiteprocEngine.normalize(k))
        : Array.from(this.items.keys());

      if (keysToUse.length === 0) {
        return [];
      }

      this.engine.updateItems(keysToUse);
      const result = this.engine.makeBibliography();

      if (!result || !result[1]) {
        return [];
      }

      // result[1] is an array of formatted bibliography entries
      return result[1].map((entry: string) => entry.trim());
    } catch (error) {
      console.error('[CiteprocEngine] generateBibliography error:', error);
      return [];
    }
  }

  // Generate full bibliography as markdown
  generateBibliographyMarkdown(citekeys?: string[]): string {
    const entries = this.generateBibliography(citekeys);
    if (entries.length === 0) {
      return '';
    }

    // Convert HTML entries to plain text (citeproc outputs HTML)
    const plainEntries = entries.map((entry) => {
      return entry
        .replace(/<\/?i>/g, '*') // Italics to markdown
        .replace(/<\/?b>/g, '**') // Bold to markdown
        .replace(/<[^>]+>/g, '') // Strip remaining HTML
        .replace(/&amp;/g, '&')
        .replace(/&lt;/g, '<')
        .replace(/&gt;/g, '>')
        .replace(/&quot;/g, '"')
        .trim();
    });

    return plainEntries.join('\n\n');
  }

  // Reset engine with new style
  setStyle(styleXML: string): void {
    this.styleXML = styleXML;
    this.initEngine();

    // Re-add items
    const items = Array.from(this.items.values());
    if (items.length > 0) {
      this.setBibliography(items);
    }
  }

  // Reset engine with new locale
  setLocale(localeXML: string): void {
    this.localeXML = localeXML;
    this.initEngine();

    // Re-add items
    const items = Array.from(this.items.values());
    if (items.length > 0) {
      this.setBibliography(items);
    }
  }

  // Get short citation for display (without citeproc processing)
  // Used as fallback when full processing isn't needed
  getShortCitation(citekey: string): string {
    const item = this.getItem(citekey);
    if (!item) {
      return `${citekey}?`;
    }

    const author = item.author?.[0];
    const authorName = author?.family || author?.literal || author?.given || '';

    let year = 'n.d.';
    if (item.issued?.['date-parts']?.[0]?.[0]) {
      year = String(item.issued['date-parts'][0][0]);
    } else if (item.issued?.raw) {
      const match = item.issued.raw.match(/\d{4}/);
      if (match) year = match[0];
    }

    if (authorName) {
      return `${authorName}, ${year}`;
    }
    return year;
  }
}

// Singleton instance for the editor
let citeprocEngine: CiteprocEngine | null = null;

export function getCiteprocEngine(): CiteprocEngine {
  if (!citeprocEngine) {
    citeprocEngine = new CiteprocEngine();
  }
  return citeprocEngine;
}

export function resetCiteprocEngine(): void {
  citeprocEngine = null;
}

export { CiteprocEngine };
