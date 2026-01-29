// Citeproc Engine Wrapper
// Provides citation formatting using citeproc-js library
// Requires CSL style and locale XML files

// @ts-ignore - citeproc doesn't have type definitions
import CSL from 'citeproc';

// Import bundled CSL style and locale via Vite's ?raw suffix
// Note: these are local to milkdown/src
import chicagoStyle from './csl/chicago-author-date.csl?raw';
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
export interface CitationOptions {
  suppressAuthor?: boolean;
  locator?: string;
  prefix?: string;
  suffix?: string;
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
      retrieveItem: (id: string) => this.items.get(id),
    };

    try {
      this.engine = new CSL.Engine(sys, this.styleXML);
    } catch (error) {
      console.error('[CiteprocEngine] Failed to initialize:', error);
      throw error;
    }
  }

  // Set the bibliography items
  setBibliography(items: CSLItem[]): void {
    console.log('[CiteprocEngine] setBibliography called with', items.length, 'items');
    this.items.clear();
    items.forEach(item => {
      // Use citationKey if available, otherwise id
      // Note: bracket notation for hyphenated JSON key from Swift encoding
      const key = (item as any)['citation-key'] || item.citationKey || item.id;
      this.items.set(key, { ...item, id: key });
    });

    // Update engine with new item IDs
    const ids = Array.from(this.items.keys());
    console.log('[CiteprocEngine] Keys after setBibliography:', ids);
    if (ids.length > 0) {
      try {
        this.engine.updateItems(ids);
      } catch (error) {
        console.error('[CiteprocEngine] Failed to update items:', error);
      }
    }
  }

  // Check if an item exists in the bibliography
  hasItem(citekey: string): boolean {
    const result = this.items.has(citekey);
    console.log('[CiteprocEngine] hasItem("' + citekey + '") =', result, '| available keys:', Array.from(this.items.keys()));
    return result;
  }

  // Get an item by citekey
  getItem(citekey: string): CSLItem | undefined {
    return this.items.get(citekey);
  }

  // Format a single citation (e.g., "(Smith, 2023)")
  formatCitation(citekeys: string[], options?: CitationOptions): string {
    if (citekeys.length === 0) return '';

    // Filter to only existing citekeys
    const validKeys = citekeys.filter(key => this.items.has(key));
    if (validKeys.length === 0) {
      // Return unresolved indicator
      return citekeys.map(k => `${k}?`).join('; ');
    }

    try {
      // Build citation cluster
      const citationItems = validKeys.map(key => ({
        id: key,
        ...(options?.suppressAuthor ? { 'suppress-author': true } : {}),
        ...(options?.locator ? { locator: options.locator } : {}),
        ...(options?.prefix ? { prefix: options.prefix } : {}),
        ...(options?.suffix ? { suffix: options.suffix } : {}),
      }));

      const citation = {
        citationItems,
        properties: { noteIndex: 0 },
      };

      // Process citation
      const result = this.engine.processCitationCluster(citation, [], []);

      // result[1] is an array of [index, formattedString] pairs
      if (result && result[1] && result[1].length > 0) {
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
      // If specific citekeys provided, update items to only those
      const keysToUse = citekeys?.filter(k => this.items.has(k)) || Array.from(this.items.keys());

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
    const plainEntries = entries.map(entry => {
      return entry
        .replace(/<\/?i>/g, '*')           // Italics to markdown
        .replace(/<\/?b>/g, '**')          // Bold to markdown
        .replace(/<[^>]+>/g, '')           // Strip remaining HTML
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
    const item = this.items.get(citekey);
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
