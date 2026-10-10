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

// === Formatted-citation memo ===
//
// `formatCitation` is a pure function of (the group asked for, the style, the locale, the library): the same request gives the same
// text whatever was formatted before it (pinned by __tests__/citeproc-format-purity.test.ts in the bundled author-date style and a note
// style with ibid./short forms; structurally it holds because every call passes empty before/after lists and note index 0, so the
// processor carries no position between calls). The engine therefore remembers each answer, keyed on everything that is asked:
// the lower-cased keys in order, the per-position suppress-author flags and locators, the prefix and the suffix.
//
// What empties it (so a remembered answer can never be older than the style, locale or library it was made under):
//   - `initEngine()`: a new processor, which covers a different style, the rollback after a rejected style, and a new locale;
//   - a change in what the library CONTAINS (see `setBibliography` / `addItems`): any item added, removed or edited, because a
//     neighbour can change an item's text (year suffixes, name disambiguation);
//   - `generateBibliography` (it re-registers the engine's items; nothing in the page calls it, so this costs nothing);
//   - growth past `MEMO_MAX_ENTRIES`.
// Never stored: the unresolved `key?` text, the processor-error text, and the "no result" fallback. Only text the processor produced.
const MEMO_MAX_ENTRIES = 5000;

/**
 * The memo key of one `formatCitation` request. Exported so the ahead-of-time fill (citation-prefill.ts) counts distinct requests with
 * exactly the key the engine uses.
 */
export function citationMemoKey(citekeys: string[], options?: CitationOptions): string {
  return JSON.stringify([
    citekeys.map((k) => k.toLowerCase()),
    options?.suppressAuthors ?? null,
    options?.locators ?? null,
    options?.prefix ?? '',
    options?.suffix ?? '',
  ]);
}

/** What `CiteprocEngine.getMemoStats()` reports. `misses` counts the calls that had to run the citation processor. */
export interface CitationMemoStats {
  size: number;
  hits: number;
  misses: number;
  enabled: boolean;
}

// The switch a freshly built engine starts with. Production leaves it on; the VM comparison runs flip it before the engine exists
// (setCitationMemoEnabled), without building the engine just to set a flag.
let memoEnabledPreference = true;

class CiteprocEngine {
  private engine: any;
  private items: Map<string, CSLItem> = new Map();
  private styleXML: string;
  private localeXML: string;

  // Formatted-citation memo (see the block comment above). All of it is bypassed when `memoEnabled` is false.
  private memoEnabled = memoEnabledPreference;
  private memo = new Map<string, string>();
  private memoHits = 0;
  private memoMisses = 0;
  // Per normalised key: JSON of the item AS STORED in `items` (after the id normalisation below). Comparing stored forms on both
  // sides is what lets the app's re-push of the same library (at every mount, and setStyle's own re-add of stored items, whose ids
  // are already lower-cased) read as "no change".
  private itemSignatures = new Map<string, string>();

  constructor(styleXML?: string, localeXML?: string) {
    this.styleXML = styleXML || chicagoStyle;
    this.localeXML = localeXML || localeEnUS;
    this.initEngine();
  }

  private initEngine() {
    // A new processor: nothing remembered under the old one may be served.
    this.memo.clear();
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

  // Stores one item under its normalised key, exactly as it has always been stored, and returns that key.
  private storeItem(item: CSLItem): string | undefined {
    const key = resolveKey(item);
    if (!key) return undefined;
    const normalizedKey = CiteprocEngine.normalize(key);
    this.items.set(normalizedKey, { ...item, id: normalizedKey });
    return normalizedKey;
  }

  private signatureOfStored(normalizedKey: string): string {
    return JSON.stringify(this.items.get(normalizedKey));
  }

  // Order-sensitive on purpose. The engine registers the items in the order they were stored (`updateItems(ids)` below), so the same
  // items in another order are a different library as far as the processor is concerned, and the memo is emptied rather than argued
  // about. (A check on 2026-10-09 with a minimal numeric style found `formatCitation` unchanged by the push order, because
  // `processCitationCluster` re-registers just the cited items; this is a precaution, and its cost is only an emptied memo.) Both
  // maps iterate in insertion order, which is the order the items were stored in (a repeated key keeps its first position in both).
  private static sameSignatures(a: Map<string, string>, b: Map<string, string>): boolean {
    if (a.size !== b.size) return false;
    const right = b.entries();
    for (const [key, signature] of a) {
      const [otherKey, otherSignature] = right.next().value as [string, string];
      if (key !== otherKey || signature !== otherSignature) return false;
    }
    return true;
  }

  // Set the bibliography items
  setBibliography(items: CSLItem[]): void {
    this.items.clear();
    // Memo only: the contents after this call, as stored, in the order the engine registers them. An order-sensitive comparison with
    // the contents before it decides whether anything remembered can still be served.
    const signatures = this.memoEnabled ? new Map<string, string>() : null;
    items.forEach((item) => {
      const key = this.storeItem(item);
      if (key && signatures) signatures.set(key, this.signatureOfStored(key));
    });
    if (signatures) {
      if (!CiteprocEngine.sameSignatures(this.itemSignatures, signatures)) this.memo.clear();
      this.itemSignatures = signatures;
    }

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
    let changed = false;
    items.forEach((item) => {
      const key = this.storeItem(item);
      if (key && this.memoEnabled) {
        const signature = this.signatureOfStored(key);
        if (this.itemSignatures.get(key) !== signature) {
          changed = true;
          this.itemSignatures.set(key, signature);
        }
      }
    });
    if (changed) this.memo.clear();

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

  // Turns the memo on or off. Only the VM comparison runs and tests call this; production never does. Either way it starts empty, and
  // turning it on re-reads the library contents it will track from now on.
  setMemoEnabled(on: boolean): void {
    if (on === this.memoEnabled) return;
    this.memoEnabled = on;
    this.memo.clear();
    this.itemSignatures = new Map();
    if (on) {
      for (const key of this.items.keys()) this.itemSignatures.set(key, this.signatureOfStored(key));
    }
  }

  getMemoStats(): CitationMemoStats {
    return { size: this.memo.size, hits: this.memoHits, misses: this.memoMisses, enabled: this.memoEnabled };
  }

  // True when this request's text is already remembered (the ahead-of-time fill skips those). Never counts as a hit.
  isMemoized(citekeys: string[], options?: CitationOptions): boolean {
    return this.memoEnabled && this.memo.has(citationMemoKey(citekeys, options));
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

    // Remembered answer (see the memo block comment): a hit is exactly what the processor gave for this request under the style,
    // locale and library the engine holds now. With the memo off none of this runs.
    let memoKey: string | undefined;
    if (this.memoEnabled) {
      memoKey = citationMemoKey(citekeys, options);
      const remembered = this.memo.get(memoKey);
      if (remembered !== undefined) {
        this.memoHits++;
        return remembered;
      }
    }

    // Filter to only existing citekeys (case-insensitive)
    const validKeys = citekeys.filter((key) => this.hasItem(key));
    if (validKeys.length === 0) {
      // Return unresolved indicator
      return citekeys.map((k) => `${k}?`).join('; ');
    }

    if (memoKey !== undefined) {
      this.memoMisses++;
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
        const formatted: string = result[1][0][1];
        if (memoKey !== undefined) {
          // Only text the processor produced is ever remembered; the fallbacks below are not.
          if (this.memo.size >= MEMO_MAX_ENTRIES) this.memo.clear();
          this.memo.set(memoKey, formatted);
        }
        return formatted;
      }

      return validKeys.join('; ');
    } catch (error) {
      console.error('[CiteprocEngine] formatCitation error:', error);
      return citekeys.join('; ');
    }
  }

  // Generate formatted bibliography entries
  generateBibliography(citekeys?: string[]): string[] {
    // It re-registers the engine's items; whatever was remembered is dropped rather than argued about (nothing in the page calls this).
    this.memo.clear();
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

  // Reset engine with new style. A malformed/garbled custom CSL file (a corrupted download,
  // or a user-provided .csl that isn't actually valid CSL) must degrade gracefully rather
  // than brick live citation rendering for the rest of the session -- the Swift bridge call
  // (setCitationStyle -> pushCitationStyle) has no error-handling path of its own, so an
  // uncaught throw here would leave the engine in whatever half-initialized state
  // initEngine()'s own try/catch left it in after rethrowing.
  //
  // Returns false (and does nothing) when `styleXML` is exactly the style the engine is
  // already running: building a CSL.Engine from a ~160 KB style takes about a second, and the
  // Swift side pushes the effective style at every Rich Text mount. A fresh page already holds
  // the bundled Chicago style (the constructor default), so for the default style that push is
  // free here. The comparison is against the style the engine is ACTUALLY running
  // (`this.styleXML`, which a rejected style never changes -- the rollback below restores it),
  // so a style citeproc rejected is retried on the next push, exactly as before. Returns true
  // whenever a rebuild was attempted (including the rollback path), so the caller knows
  // on-screen citations need re-rendering.
  setStyle(styleXML: string): boolean {
    if (this.engine && styleXML === this.styleXML) return false;

    const previousStyleXML = this.styleXML;
    this.styleXML = styleXML;
    try {
      this.initEngine();
    } catch (error) {
      console.error('[CiteprocEngine] setStyle failed with invalid CSL, rolling back to previous style:', error);
      this.styleXML = previousStyleXML;
      try {
        this.initEngine();
      } catch (rollbackError) {
        // The previous style was already active a moment ago, so this should be
        // unreachable -- but never let a rollback failure escape either.
        console.error('[CiteprocEngine] Rollback to previous style also failed:', rollbackError);
        return true;
      }
    }

    // Re-add items to whichever engine ended up active (the new style, or the rolled-back
    // previous one) -- initEngine() always constructs a fresh CSL.Engine with no items
    // registered yet.
    const items = Array.from(this.items.values());
    if (items.length > 0) {
      this.setBibliography(items);
    }
    return true;
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

/**
 * The memo switch for the VM comparison runs (`window.FinalFinal.setCitationMemoEnabled`). Records the choice for engines built later
 * and applies it to the one that exists, without building an engine just to flip a flag. Production never calls it.
 */
export function setCitationMemoEnabled(on: boolean): void {
  memoEnabledPreference = on;
  citeprocEngine?.setMemoEnabled(on);
}

/** Memo size and hit/miss counts (`window.FinalFinal.getCitationMemoStats`). Never builds the engine: before it exists everything is zero. */
export function getCitationMemoStats(): CitationMemoStats {
  return citeprocEngine
    ? citeprocEngine.getMemoStats()
    : { size: 0, hits: 0, misses: 0, enabled: memoEnabledPreference };
}

export { CiteprocEngine };
