# Review: Enable Word Built-in Captions via `native_numbering`

## Overall Assessment

The plan is well-scoped and the proposed one-line change is in the correct location. However, the review uncovered a pre-existing issue with the `--from markdown` argument that affects both `fig-alt` and `width` attributes on images. This issue exists independently of the `native_numbering` change but is worth surfacing because the plan claims `fig-alt` already works and because `native_numbering` will draw more attention to caption/figure formatting.

---

## 1. Correctness of the Proposed Change

**Verdict: Correct.**

The `pandocFormat` property on `ExportFormat` at line 34 of `ExportSettings.swift` is the single point where the `--to` format string is constructed. The `ExportService.export()` method at line 199 of `ExportService.swift` is the only place `pandocFormat` is consumed:

```swift
"--to", format.pandocFormat,
```

No other code constructs `--to` arguments independently. The proposed switch statement correctly appends `+native_numbering` only for `.word` and `.odt`, excluding `.pdf` (where the extension has no effect).

The change is minimal and well-targeted.

---

## 2. Completeness

**Verdict: Complete.** All export paths flow through a single call chain:

1. `ExportCommands.handleExport()` calls `ExportViewModel.export()`
2. `ExportViewModel.export()` calls `ExportService.export()`
3. `ExportService.export()` reads `format.pandocFormat` at line 199

There are no alternative export paths that bypass `pandocFormat`. The markdown and TextBundle export paths (`exportMarkdownWithImages`, `exportTextBundle`) do not invoke Pandoc at all, so they are unaffected.

Searching the codebase for `pandocFormat` yields exactly two results: its definition (ExportSettings.swift:34) and its single use (ExportService.swift:199). Searching for `--to` in Swift files yields only the same line 199.

---

## 3. Alt Text Claim Validation

**Verdict: The claim that fig-alt "already works" is likely incorrect -- but this is a pre-existing issue, not caused by this plan.**

### What `Block.markdownForExport()` generates (Block.swift:328-363)

The method correctly constructs:
```markdown
![My visible caption](media/img.jpg){fig-alt="Accessibility alt text" width=400px}
```

The code logic is sound: when both `imageCaption` and `imageAlt` are non-empty, the caption goes in `![caption]` and the alt text goes in `{fig-alt="..."}`. Special characters are escaped properly.

### The `link_attributes` extension problem

The `{fig-alt="..." width=400px}` curly-brace attribute syntax requires Pandoc's `link_attributes` extension to be parsed. According to the Pandoc documentation and extension tables:

- `link_attributes` is **disabled by default** in Pandoc's `markdown` format
- The app's `--from markdown` argument (ExportService.swift:198) does not enable it

This means the `{fig-alt="..." width=400px}` text is likely being treated as literal text by Pandoc, not parsed as image attributes. The attributes would appear as visible text in the exported document or be silently dropped.

**To fix this (separate from the current plan)**, the `--from` argument should be changed to:
```
--from markdown+link_attributes
```

or alternatively, the broader `attributes` extension (which subsumes `link_attributes`):
```
--from markdown+attributes
```

**This is a pre-existing issue** that affects width attributes as well as fig-alt. It is not introduced by the `native_numbering` plan, but the plan's claim that "fig-alt already works for DOCX" (section "Alt Text -- Already Working") should be verified by actual testing before this plan is considered complete.

**Recommendation**: Before implementing the `native_numbering` change, verify whether `{fig-alt="..." width=400px}` attributes are actually being parsed by Pandoc in the current export. If they are not, add `+link_attributes` to the `--from` argument as a prerequisite fix.

---

## 4. Reference Document Compatibility

**Verdict: No issue.** The bundled `reference.docx` at `final final/Resources/Export/reference.docx` already contains the following relevant styles:

| Style ID | Style Name |
|----------|-----------|
| `Caption` | caption |
| `CaptionChar` | Caption Char |
| `ImageCaption` | Image Caption |
| `Figure` | Figure |
| `CaptionedFigure` | Captioned Figure |
| `TableCaption` | Table Caption |

The `native_numbering` extension causes Pandoc's DOCX writer to use the "Caption" paragraph style with SEQ fields. Since the reference document already defines a "Caption" style (ID: `Caption`), Pandoc will use it for formatting. If the style were missing, Pandoc would fall back to its built-in default Caption style, which is functional but visually basic. In this case, no fallback is needed because the style exists.

The existing "ImageCaption" style (currently used for figure captions without `native_numbering`) will no longer be used for captioned figures after this change. Captions will use "Caption" instead. If the user has customized the "ImageCaption" style in a custom reference document, they would need to update the "Caption" style instead.

**Recommendation**: Note in the plan or documentation that `native_numbering` changes the caption style from "ImageCaption" to "Caption". Users with custom reference documents should be aware.

---

## 5. Regression Risk

**Verdict: Low risk, with one consideration.**

### Documents without images
`native_numbering` has no effect on documents without images or tables. The extension only activates when Pandoc's DOCX writer encounters Figure or Table elements in its AST. Plain paragraphs, headings, and lists are unaffected.

### Table captions
The `native_numbering` extension affects **both** figures and tables. From the Pandoc documentation: "Enables native numbering of figures and tables." If the exported document contains tables with captions, they will also receive auto-numbering ("Table 1:", "Table 2:", etc.) and use the "TableCaption" style.

This is likely desirable behavior (consistent numbering), but the plan does not mention tables at all. It should acknowledge that table captions will also be affected.

### Images without captions
The plan correctly notes (step 6 of "How It Works End-to-End") that images with empty `![](...)` are not treated as figures by Pandoc's `implicit_figures` extension. This means images without captions will not receive unwanted "Figure N:" numbering. This is the correct behavior.

### The `implicit_figures` dependency
For `native_numbering` to produce figure captions, `implicit_figures` must be enabled (so standalone images with non-empty caption text become Figure elements). `implicit_figures` is enabled by default in Pandoc's `markdown` format, so this works correctly with `--from markdown`.

---

## Summary of Findings

### No Issues (Plan is Sound)
- The `pandocFormat` property is the correct and only place for this change
- All export paths flow through the single `format.pandocFormat` call site
- The reference.docx already contains the required "Caption" style
- `implicit_figures` is enabled by default, so captions will become Figure elements
- No regression risk for documents without images

### Important Issues to Address

1. **Table caption numbering** (should document): The `native_numbering` extension also affects table captions, not just figures. The plan should acknowledge this.

2. **Style change for existing users** (should document): Captions will switch from the "ImageCaption" style to the "Caption" style. Users with custom reference documents may need to adjust.

3. **Pre-existing `link_attributes` issue** (separate fix recommended): The `--from markdown` argument does not enable `link_attributes`, which means `{fig-alt="..." width=400px}` attributes generated by `Block.markdownForExport()` may not be parsed. This is a pre-existing issue that predates this plan, but the plan's claim that "fig-alt already works" should be tested. If it does not work, the `--from` argument needs `+link_attributes` as a prerequisite.

### Recommendation

The `native_numbering` change itself is safe and correct. Implement it as described. Separately, verify whether `fig-alt` and `width` attributes are actually working in current exports (test by exporting a document with a captioned image and checking the resulting DOCX). If they are not, file a follow-up to add `+link_attributes` to the `--from markdown` argument.
