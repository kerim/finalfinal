# Review: Chinese Text Missing from PDF Exports

## Review of Diagnosis and Proposed Fix

### Reviewed Files
- `final final/Services/ExportService.swift` (current implementation)
- `docs/plans/mighty-mapping-cookie.md` (proposed fix plan)
- `final final/Resources/TinyTeX/texmf-dist/ls-R` (ls-R database)
- `final final/Resources/TinyTeX/texmf-dist/tex/xelatex/xecjk/xeCJK.sty`
- `final final/Resources/TinyTeX/texmf-dist/tex/latex/ctex/ctexhook.sty`
- `final final/Resources/TinyTeX/texmf.cnf` and `texmf-dist/web2c/texmf.cnf`

---

## 1. Is the Diagnosis Correct?

**Yes, the diagnosis is correct.** The root cause is confirmed by reading the code.

The current `detectLanguages()` method (line 492-497) uses `NLLanguageRecognizer` with a 5% confidence threshold. For a predominantly English document with scattered Chinese terms, the Chinese content falls below 5%, so no `CJKmainfont` variable is passed to pandoc. Without `CJKmainfont`, pandoc/xelatex does not load xeCJK, and Chinese characters are silently dropped from the PDF output.

**No other causes are blocking this.** See verification details below.

---

## 2. TinyTeX xeCJK Setup: Verified Correct

### ls-R format: CORRECT
The ls-R entries follow the standard kpathsea format:
- Line 1: `% ls-R -- filename database for kpathsea; do not change this line.` (required header)
- Directory entries use `./relative/path:` format followed by file listings
- The xecjk directory entry (line 8006) and ctex directory entry (line 7160) are properly formatted

### xeCJK files: ALL PRESENT
Found at `texmf-dist/tex/xelatex/xecjk/`:
- `xeCJK.sty` (main package)
- `xeCJK.cfg`
- `xeCJKfntef.sty`
- `xeCJK-listings.sty`
- `xunicode-addon.sty`
- `xunicode-extra.def`

### xeCJK dependencies: ALL PRESENT
Traced from `xeCJK.sty` line 54: `\RequirePackage { ctexhook }` -- xeCJK depends on `ctexhook` (not full `ctex.sty`):
- `ctexhook.sty` -- present at `texmf-dist/tex/latex/ctex/ctexhook.sty`, standalone (only requires `expl3`)
- `expl3.sty` -- present at `texmf-dist/tex/latex/l3kernel/expl3.sty`
- `xtemplate.sty` -- present at `texmf-dist/tex/latex/l3packages/xtemplate/xtemplate.sty`
- `xparse.sty` -- present at `texmf-dist/tex/latex/l3packages/xparse/xparse.sty`
- `fontspec.sty` -- present at `texmf-dist/tex/latex/fontspec/fontspec.sty`

### Path resolution: CORRECT
The symlink trick in `prepareBundledTinyTeX()` creates `/tmp/.../TinyTeX -> [real app bundle path]`. Since kpathsea uses `SELFAUTOPARENT` (grandparent of the binary), and the binary is at `TinyTeX/bin/universal-darwin/xelatex`, `SELFAUTOPARENT` resolves to the `TinyTeX` symlink. This means:
- `TEXMFROOT = $SELFAUTOPARENT` = `/tmp/.../TinyTeX`
- `TEXMFDIST = $TEXMFROOT/texmf-dist` = `/tmp/.../TinyTeX/texmf-dist`
- `TEXINPUTS.xelatex = ... $TEXMF/tex/{xelatex,latex,xetex,generic,}//` -- includes the `xelatex/` subtree where xeCJK lives

The custom `texmf.cnf` at the TinyTeX root also overrides `TEXMFLOCAL = $SELFAUTOPARENT/texmf-local` and `TEXMFHOME = $TEXMFLOCAL`, keeping everything within the bundle.

### Environment variables: NOT NEEDED
The `runPandoc()` method does not set any environment variables on the Process, which is fine. Kpathsea resolves all paths from `SELFAUTO*` variables based on the binary location (the symlink), so no `TEXMFHOME`, `TEXMFDIST`, or `TEXINPUTS` environment variables are needed.

**Conclusion: The TinyTeX setup is correct. The only problem is that `CJKmainfont` is never passed to pandoc.**

---

## 3. Review of the Proposed Fix

### Assessment: SOUND APPROACH, with minor refinements needed

The Unicode character range scanning approach is the right solution. It directly addresses the failure mode (NLLanguageRecognizer missing low-percentage languages) and is more deterministic -- if CJK characters are present, CJK font support is added.

### What the plan gets right:
- Two-tier approach (Unicode scan for detection, NLLanguageRecognizer only for disambiguation) is well-designed
- CJK Unified Ideographs range (U+4E00-U+9FFF) plus Extension A (U+3400-U+4DBF) and CJK Compatibility (U+F900-U+FAFF) covers the vast majority of real-world content
- Using Hiragana/Katakana as unambiguous Japanese markers is correct
- Defaulting to Traditional Chinese for SC/TC disambiguation makes sense for the primary user's context (Taiwan/HK)
- Diagnostic logging is included

### Issues and Suggestions:

**IMPORTANT -- Missing CJK Extension B+ ranges:**
The proposed code scans U+4E00-U+9FFF, U+3400-U+4DBF, and U+F900-U+FAFF. This covers the Basic Multilingual Plane (BMP). However, CJK Unified Ideographs Extension B and beyond (U+20000-U+2A6DF, U+2A700-U+2B73F, etc.) are on the Supplementary Ideographic Plane. These are rare characters, but some are used in names and historical texts. For academic documents (which this app appears to target), consider adding at least Extension B. That said, this is a "nice to have" -- the BMP ranges cover >99% of real-world Chinese text.

**SUGGESTION -- Early exit optimization:**
The proposed `for scalar in content.unicodeScalars` loop scans the entire document. For large documents, consider breaking out early once all script flags have been set. For example:

```swift
// After the switch, check if we can stop scanning
if hasCJK && hasHiragana && hasKatakana && hasHangul &&
   hasDevanagari && hasThai && hasBengali && hasTamil {
    break
}
```

This is a minor optimization but worth including since academic documents can be quite long.

**SUGGESTION -- Method signature change:**
The plan changes `fontArguments(for:)` from taking `[NLLanguage: Double]` to taking `String`. The call site update in section 2 of the plan is correct. Just make sure the old `detectLanguages()` method AND the old `fontArguments(for:)` overload are both removed so there are no orphaned methods.

**SUGGESTION -- Consider CJK Punctuation range:**
CJK documents often contain CJK punctuation marks (U+3000-U+303F), such as ideographic comma, ideographic period, left/right corner brackets, etc. These alone should probably not trigger CJK font loading (since they can appear in English documents about CJK topics), but they could supplement the detection. The current plan does not scan for these, which is fine -- the ideograph ranges are sufficient.

---

## 4. Is Anything Else Broken?

**No other blocking issues found.** Specifically:

- The pandoc command construction is correct -- `-V CJKmainfont=<font>` is the standard way to pass this to the default LaTeX template
- The `--pdf-engine` and `--pdf-engine-opt` arguments are correctly constructed via `prepareBundledTinyTeX()`
- The symlink approach correctly solves the spaces-in-path problem for both xelatex and xdvipdfmx
- Citation handling, annotation stripping, and format branching all look correct
- The `processedContent` variable (post-annotation-stripping) is correctly passed to both language detection and the temp file, so language detection operates on the same content that gets exported

**One non-blocking observation:** The `runPandoc` method captures stderr but does not log it on success. If xelatex emits warnings (like font substitution warnings), they are silently discarded. For debugging CJK font issues in the future, it might be useful to log stderr even on success (at least in debug builds). This is not blocking and can be deferred.

---

## Summary

| Item | Status |
|------|--------|
| Diagnosis (NLLanguageRecognizer threshold) | Confirmed correct |
| TinyTeX xeCJK bundle | All files present, ls-R format correct |
| TinyTeX path resolution via symlink | Working correctly |
| Environment variables | Not needed (kpathsea self-resolves) |
| Proposed Unicode scanning approach | Sound, recommended to proceed |
| Other blocking issues | None found |

**Recommendation: Proceed with the fix as planned.** The proposed changes are well-scoped, low-risk (only affects the font detection path for PDF exports), and directly address the confirmed root cause. The minor suggestions above (Extension B ranges, early exit, stderr logging) can be incorporated during implementation or deferred.
