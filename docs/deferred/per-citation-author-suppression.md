# Fix Per-Citation Author Suppression Bug

## Problem

Per-citation locators (page numbers) now work correctly, but **author suppression** still applies to all citations when only one should be suppressed.

**Example:**
- Input: `[-@smith2023; @jones2024]` (suppress only first author)
- Current (wrong): `(2023; 2024)` - both authors suppressed
- Expected: `(2023; Jones 2024)` - only first author suppressed

## Root Cause

The data model stores `suppressAuthor` as a **single boolean** rather than a per-citation array like `locators`. When any citation has `-@`, the boolean is set to `true` and applied to all citations.

**Affected locations in `citation-plugin.ts`:**
1. `CitationAttrs.suppressAuthor: boolean` (line 23) - single value, not array
2. `ParsedCitation.suppressAuthor: boolean` (line 78) - collapses per-citation info
3. `parseCitationBracket()` (lines 109-110) - sets single boolean if ANY has `-`
4. `parseEditedCitation()` (lines 353-354) - same collapsing behavior
5. `serializeCitation()` (line 137) - only adds `-` to first citation
6. Node attrs, parseDOM, toDOM - all use single boolean

## Solution

Mirror the locators pattern: store `suppressAuthors` as a JSON-encoded boolean array.

### Changes Required

#### 1. Update `CitationAttrs` interface (line 22-23)

```typescript
// Change from:
suppressAuthor: boolean;
// To:
suppressAuthors: string;  // JSON array of booleans, e.g., '["true","false"]'
```

#### 2. Update `ParsedCitation` interface (line 78)

```typescript
// Change from:
suppressAuthor: boolean;
// To:
suppressAuthors: boolean[];
```

#### 3. Update `parseCitationBracket()` (lines 82-125)

Store per-citation suppress flags:
```typescript
const suppressAuthors: boolean[] = [];
// ... in the loop:
suppressAuthors.push(suppress === '-');
// ... return:
return { citekeys, locators, prefix, suffix, suppressAuthors, rawSyntax };
```

#### 4. Update `parseEditedCitation()` (lines 309-366)

Same pattern - return `suppressAuthors: boolean[]` array.

#### 5. Update `serializeCitation()` (lines 128-154)

Read from array:
```typescript
const suppressAuthors = attrs.suppressAuthors ? JSON.parse(attrs.suppressAuthors) : [];
// ... in loop:
const suppressPrefix = suppressAuthors[i] ? '-' : '';
```

#### 6. Update `citationNode` attrs (lines 232-239)

```typescript
attrs: {
  // ... other attrs
  suppressAuthors: { default: '[]' },  // Changed from suppressAuthor: false
}
```

#### 7. Update `parseDOM` (lines 241-252)

```typescript
suppressAuthors: dom.dataset.suppressauthors || '[]',
```

#### 8. Update `toDOM` (lines 255-276)

```typescript
'data-suppressauthors': attrs.suppressAuthors,
```

#### 9. Update `parseMarkdown` runner (lines 280-289)

```typescript
suppressAuthors: node.data.suppressAuthors,
```

#### 10. Update remarkCitationPlugin data (lines 194-204)

```typescript
suppressAuthors: JSON.stringify(m.parsed.suppressAuthors),
```

#### 11. Update CitationNodeView display (lines 748-753)

```typescript
suppressAuthors: attrs.suppressAuthors ? JSON.parse(attrs.suppressAuthors) : undefined,
```

#### 12. Update edit preview (lines 580-585)

```typescript
suppressAuthors: parsed.suppressAuthors,
```

#### 13. Update commitEdit (lines 661-668)

```typescript
suppressAuthors: JSON.stringify(parsed.suppressAuthors),
```

### Files to Modify

| File | Changes |
|------|---------|
| `web/milkdown/src/citation-plugin.ts` | All changes above (13 locations) |

Note: `citeproc-engine.ts` already supports `suppressAuthors: boolean[]` from the previous fix.

## Verification

1. Build: `cd web && pnpm build`
2. Rebuild Xcode: `xcodegen generate && xcodebuild -scheme "final final" -destination 'platform=macOS' build`
3. Test cases:
   - `[-@a; @b]` → only first author suppressed: `(2023; Smith 2024)`
   - `[@a; -@b]` → only second author suppressed: `(Jones 2023; 2024)`
   - `[-@a; -@b]` → both suppressed: `(2023; 2024)`
   - `[@a; @b]` → neither suppressed: `(Jones 2023; Smith 2024)`
   - `[-@a,23; @b]` → combined with locator: `(2023, 23; Smith 2024)`
