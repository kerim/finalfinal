# Export Architecture

Pandoc-based export pipeline for DOCX, PDF, and ODT. Non-Pandoc export for Markdown with Images and TextBundle. Handles citations, non-Latin font detection, image conversion, and bundled TinyTeX.

---

## ExportService Overview

`ExportService` is a Swift actor that builds pandoc arguments, runs the conversion, and returns results with warnings. It also handles non-Pandoc exports (Markdown with Images, TextBundle).

**Pandoc formats:**
- **DOCX** — pandoc with Lua filter for Zotero field codes + reference document + `native_numbering`
- **PDF** — pandoc with XeLaTeX engine, `--citeproc` for citations, auto-detected font variables, image conversion for unsupported formats
- **ODT** — same pipeline as DOCX (Lua filter + reference doc + `native_numbering`)

**Non-Pandoc formats:**
- **Markdown with Images** — standard markdown `.md` file + `<name>_images/` folder with copied image files
- **TextBundle** — `.textbundle` package containing `text.md`, `info.json`, and `assets/` folder

**Key files:**
- `final final/Services/ExportService.swift` — export logic
- `final final/Commands/FileCommands.swift` — Markdown/TextBundle export UI (save panels)
- `final final/Commands/ExportCommands.swift` — Pandoc export UI (save panels)

---

## Pandoc Export Pipeline

```
Content (markdown, Pandoc-flavored via markdownForExport())
    │
    ├── Strip annotations (if setting disabled)
    │
    ├── PDF only: convert unsupported images (WebP, HEIC, GIF, TIFF, SVG) → PNG
    │   └── Uses NSImage → NSBitmapImageRep → PNG (no main thread required)
    │
    ├── Build pandoc arguments:
    │   ├── --from markdown --to FORMAT+native_numbering --output PATH
    │   ├── --resource-path PROJECT_URL (for media/ image resolution)
    │   ├── PDF: --pdf-engine xelatex (bundled TinyTeX)
    │   ├── PDF: --pdf-engine-opt -output-driver=WRAPPER (spaces workaround)
    │   ├── PDF: font variables via Unicode script detection
    │   ├── DOCX/ODT: --reference-doc PATH
    │   ├── PDF + citations: --citeproc --bibliography FILE --csl STYLE
    │   └── DOCX/ODT + citations: --lua-filter zotero.lua
    │
    └── Run pandoc → ExportResult (outputURL, warnings)
```

## Markdown / TextBundle Export Pipeline

```
Content (standard markdown via markdownForStandardExport())
    │
    ├── Blocks fetched from DB, bibliography filtered out
    ├── Image filenames extracted from image blocks
    │
    ├── Markdown with Images:
    │   ├── Save panel → <name>.md
    │   ├── Copy images to <name>_images/ (sibling folder)
    │   └── Rewrite paths: media/X → <name>_images/X
    │
    └── TextBundle:
        ├── Save panel → <name>.textbundle
        ├── Copy images to assets/ (inside bundle)
        ├── Rewrite paths: media/X → assets/X
        ├── Write text.md (rewritten content)
        └── Write info.json (version 2, markdown type)
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
| `export(content:to:format:settings:projectURL:)` | Main Pandoc export entry point |
| `exportMarkdownWithImages(content:imageFilenames:projectURL:outputURL:)` | Markdown + images folder export |
| `exportTextBundle(content:imageFilenames:projectURL:outputURL:)` | TextBundle package export |
| `prepareImagesForPDF(content:projectURL:)` | Convert unsupported images → PNG for xelatex |
| `convertImageToPNG(at:)` | NSImage → PNG via NSBitmapImageRep |
| `fontArguments(for:)` | Unicode script detection → pandoc font variables |
| `disambiguateCJKFont(in:)` | NLLanguageRecognizer SC vs TC disambiguation |
| `prepareBundledTinyTeX()` | Symlink + wrapper script for spaces workaround |
| `fetchBibliographyJSON(for:)` | Zotero JSON-RPC → CSL-JSON for `--citeproc` |
| `extractCitekeys(from:)` | Regex extraction of `@citekey` from markdown (strips code first) |
| `stripAnnotations(from:)` | Remove `<!-- ::type:: -->` annotation comments |
| `MarkdownUtils.stripCodeContent(from:)` | Remove fenced code blocks and inline code before citekey extraction |

---

## Image Handling

### Two Markdown Renderers

Image blocks have two export representations in `Block`:

- **`markdownForExport()`** — Pandoc-flavored: uses `fig-alt` attribute to separate visible caption from alt text, includes `width=Npx` attribute. Caption goes in `![caption](src){fig-alt="alt" width=Npx}`.
- **`markdownForStandardExport()`** — Standard markdown: alt text in `![alt](src)`, caption as italic paragraph below (`*caption*`).

Corresponding assembly functions in `BlockParser`:
- `assembleMarkdownForExport(from:)` — Pandoc pipeline
- `assembleStandardMarkdownForExport(from:)` — Markdown/TextBundle pipeline

### PDF Image Conversion

xelatex only supports PNG, JPG, JPEG, BMP, and PDF images natively. For PDF export, `prepareImagesForPDF()` converts unsupported formats (WebP, HEIC, GIF, TIFF, SVG) to PNG:

1. Scan markdown for `![...](media/filename)` references
2. If any filename has an unsupported extension, create a temp directory
3. Symlink supported images; convert unsupported ones via `NSImage` → `NSBitmapImageRep` → PNG
4. Handle filename collisions (e.g., `photo.webp` → `photo.png` but `photo.png` already exists → `photo-converted.png`)
5. Rewrite markdown content with new filenames
6. Pass temp directory as `--resource-path` to pandoc
7. Clean up temp directory after export

### TextBundle Format

Registered `org.textbundle.package` UTType in Info.plist and project.yml. The bundle structure follows the [TextBundle spec v2](https://textbundle.org):

```
document.textbundle/
├── info.json          (version: 2, type: net.daringfireball.markdown)
├── text.md            (markdown with paths rewritten to assets/)
└── assets/
    ├── image1.png
    └── image2.jpg
```

---

## Opening Settings Programmatically

The "Export Preferences..." menu item uses `@Environment(\.openSettings)` (the official SwiftUI API, macOS 14+) via an `OpenExportPreferencesListener` view in `FinalFinalApp.swift`. This replaced the previous approach of calling the private `showSettingsWindow:` selector through `NSApp.sendAction`, which was unreliable. `NSApp.activate()` is called after a short delay to ensure the Settings window comes to front even when the main window is fullscreen. `PreferencesView` listens for the same `.showExportPreferences` notification to switch to the Export tab.
