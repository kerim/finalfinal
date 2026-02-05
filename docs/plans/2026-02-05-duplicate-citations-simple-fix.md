# Debugging Plan: Duplicate Citations in Bibliography

## Root Cause Analysis

### The Bug
When a citation appears multiple times in the document (e.g., `[@smith2023]` used in two paragraphs), the bibliography generates duplicate entries for that same work.

### Root Cause Found
The `extractCitekeys()` function returns an array with duplicates when the same citekey is used multiple times in the document. While the comparison logic converts to a Set (line 97), the actual processing passes the raw array with duplicates (line 123).

**Flow:**
1. Document: `As Smith argues [@smith2023], and later confirms [@smith2023]...`
2. `extractCitekeys()` returns: `["smith2023", "smith2023"]`
3. `checkAndUpdateBibliography()` receives array with duplicates
4. Line 97 deduplicates for comparison: `Set(currentCitekeys)` = `{"smith2023"}`
5. Line 123 passes original array to `performBibliographyUpdate(citekeys: currentCitekeys, ...)`
6. `getItems(citekeys:)` returns `[CSLItem, CSLItem]` (same item twice)
7. Loop formats each item, creating duplicate bibliography entries

### Evidence
- `BibliographySyncService.swift:59-66` - `extractCitekeys` returns array with all matches (no deduplication)
- `BibliographySyncService.swift:123` - Passes original `currentCitekeys` array (not deduplicated Set)
- `ZoteroService.swift:437` - `getItems` uses `compactMap` which preserves duplicates
- `BibliographySyncService.swift:240-243` - Loop iterates over all items including duplicates

## Fix

### Option 1: Deduplicate in generateBibliographyMarkdown (Recommended)
Deduplicate citekeys when generating bibliography markdown.

**File:** `final final/Services/BibliographySyncService.swift`
**Line 221:**
```swift
private func generateBibliographyMarkdown(citekeys: [String]) -> String {
    let zoteroService = ZoteroService.shared

    // Deduplicate citekeys - a citation may appear multiple times in document
    let uniqueCitekeys = Array(Set(citekeys))

    // Get items for citekeys
    let items = zoteroService.getItems(citekeys: uniqueCitekeys)
    // ... rest unchanged
}
```

### Option 2: Deduplicate at extraction (Alternative)
Change `extractCitekeys` to return unique values.

**File:** `final final/Services/BibliographySyncService.swift`
**Line 59:**
```swift
static func extractCitekeys(from markdown: String) -> [String] {
    let range = NSRange(markdown.startIndex..., in: markdown)
    let matches = citationPattern.matches(in: markdown, range: range)
    let allKeys = matches.compactMap { match -> String? in
        guard let range = Range(match.range(at: 1), in: markdown) else { return nil }
        return String(markdown[range])
    }
    return Array(Set(allKeys))  // Deduplicate
}
```

**Recommendation:** Option 1 is preferred because:
- It preserves the original behavior of `extractCitekeys` (returning all occurrences)
- Other code might rely on knowing citation count or order
- The deduplication is applied at the point where it matters (bibliography generation)

## Verification

After fix:
1. Create document with same citation used multiple times
2. Wait for bibliography to generate (2s debounce)
3. Verify only one bibliography entry appears
4. Test with multiple different citations, some repeated
5. Verify each unique citation appears exactly once in bibliography

## Files to Modify

- `final final/Services/BibliographySyncService.swift` (line 221-226 area)

## Zoom Relationship

The user mentioned zoom might be related. While zoom was initially suspected, this bug occurs regardless of zoom:
- Even without zoom, if `[@smith2023]` appears twice in a document, both occurrences are extracted and processed
- Zoom doesn't exacerbate this particular bug since the core issue is lack of deduplication

However, there may be other zoom-related bibliography bugs worth investigating separately.
