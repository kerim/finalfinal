# Export Architecture

Pandoc-based export pipeline for DOCX, PDF, and ODT. Handles citations, non-Latin font detection, and bundled TinyTeX.

---

## ExportService Overview

`ExportService` is a Swift actor that builds pandoc arguments, runs the conversion, and returns results with warnings.

**Supported formats:**
- **DOCX** — pandoc with Lua filter for Zotero field codes + reference document
- **PDF** — pandoc with XeLaTeX engine, `--citeproc` for citations, auto-detected font variables
- **ODT** — same pipeline as DOCX (Lua filter + reference doc)

**Key file:** `final final/Services/ExportService.swift`

---

## Export Pipeline

```
Content (markdown)
    │
    ├── Strip annotations (if setting disabled)
    │
    ├── Build pandoc arguments:
    │   ├── --from markdown --to FORMAT --output PATH
    │   ├── PDF: --pdf-engine xelatex (bundled TinyTeX)
    │   ├── PDF: --pdf-engine-opt -output-driver=WRAPPER (spaces workaround)
    │   ├── PDF: font variables via Unicode script detection
    │   ├── DOCX/ODT: --reference-doc PATH
    │   ├── PDF + citations: --citeproc --bibliography FILE --csl STYLE
    │   └── DOCX/ODT + citations: --lua-filter zotero.lua
    │
    └── Run pandoc → ExportResult (outputURL, warnings)
```

---

## Citation Processing

Two distinct citation pipelines depending on format:

### PDF Citations (--citeproc)

1. Detect pandoc-style citations: `[@citekey]`, `[@key1; @key2]`
2. Check Zotero + Better BibTeX availability
3. Extract citekeys via regex
4. Fetch CSL-JSON bibliography from Zotero's JSON-RPC endpoint (`item.export`)
5. Write to temp `.json` file
6. Pass `--citeproc --bibliography FILE.json --csl chicago-author-date.csl` to pandoc
7. Pandoc resolves citations and generates bibliography section

### DOCX/ODT Citations (Lua filter)

1. Pass `--lua-filter zotero.lua` to pandoc
2. Lua filter converts `[@citekey]` to Zotero field codes
3. Word/LibreOffice resolves citations when document is opened

### Bundled Resources

| Resource | Path | Purpose |
|----------|------|---------|
| `zotero.lua` | `Export/zotero.lua` | Lua filter for DOCX/ODT citation field codes |
| `reference.docx` | `Export/reference.docx` | DOCX/ODT formatting template |
| `chicago-author-date.csl` | `Export/chicago-author-date.csl` | CSL citation style for PDF |

---

## Non-Latin Font Detection

PDF export automatically detects non-Latin scripts and passes appropriate font variables to pandoc/XeLaTeX.

### Two-Tier Detection Strategy

**Tier 1 — Unicode range scanning** (determines WHETHER to add font support):

Scans `content.unicodeScalars` for character ranges. If ANY character in a range is found, that script's font is needed. No threshold, no confidence score — a single character triggers detection.

| Script | Unicode Range | Pandoc Variable |
|--------|---------------|-----------------|
| CJK Ideographs | U+4E00–9FFF, U+3400–4DBF, U+F900–FAFF, U+20000–2A6DF | `CJKmainfont` |
| Hiragana | U+3040–309F | `CJKmainfont` (Japanese) |
| Katakana | U+30A0–30FF | `CJKmainfont` (Japanese) |
| Hangul | U+AC00–D7AF | `CJKmainfont` (Korean) |
| Devanagari | U+0900–097F | `mainfont` |
| Thai | U+0E00–0E7F | `mainfont` |
| Bengali | U+0980–09FF | `mainfont` |
| Tamil | U+0B80–0BFF | `mainfont` |

**Tier 2 — NLLanguageRecognizer** (determines WHICH CJK font):

Only invoked when CJK ideographs are detected without Hiragana/Katakana/Hangul (which are unambiguous). Extracts only CJK characters from the content and runs NLLanguageRecognizer on that filtered text to distinguish Simplified vs Traditional Chinese. Defaults to Traditional Chinese (Songti TC).

### Font Selection Logic

```
Has Hiragana or Katakana?  → CJKmainfont = Hiragino Mincho ProN (Japanese)
Has Hangul?                → CJKmainfont = Apple SD Gothic Neo (Korean)
Has CJK ideographs only?   → CJKmainfont = disambiguate SC vs TC
  SC confidence > TC?       → Songti SC
  Otherwise (default)?      → Songti TC
```

Non-CJK scripts use `mainfont` (first match wins; only one can be set):
- Devanagari → Kohinoor Devanagari
- Thai → Thonburi
- Bengali → Bangla Sangam MN
- Tamil → Tamil Sangam MN

### Why Not NLLanguageRecognizer Alone

The previous approach used `NLLanguageRecognizer` with a 5% confidence threshold. This fails for documents that are predominantly English with scattered non-Latin terms (e.g., an English academic paper with Chinese terms like `九年一貫課程`). The Chinese content at ~3-5% falls right at or below the threshold, so the recognizer classifies the document as English-only.

Unicode range scanning has no threshold — even a single CJK character triggers font support.

---

## Bundled TinyTeX

PDF export uses a bundled TinyTeX distribution for XeLaTeX. See [misc-patterns.md](../lessons/misc-patterns.md#xetex--pdf-export) for the `-output-driver` workaround for paths with spaces.

### CJK Package Support

The bundled TinyTeX includes the `xecjk` package and its dependency `ctex` for CJK font support:
- `texmf-dist/tex/xelatex/xecjk/` — xeCJK package files
- `texmf-dist/tex/latex/ctex/` — ctex dependency
- `texmf-dist/ls-R` — Updated with package entries for kpathsea discovery

### Key Methods

| Method | Purpose |
|--------|---------|
| `export(content:to:format:settings:)` | Main entry point |
| `fontArguments(for:)` | Unicode script detection → pandoc font variables |
| `disambiguateCJKFont(in:)` | NLLanguageRecognizer SC vs TC disambiguation |
| `prepareBundledTinyTeX()` | Symlink + wrapper script for spaces workaround |
| `fetchBibliographyJSON(for:)` | Zotero JSON-RPC → CSL-JSON for `--citeproc` |
| `extractCitekeys(from:)` | Regex extraction of `@citekey` from markdown |
| `stripAnnotations(from:)` | Remove `<!-- ::type:: -->` annotation comments |
