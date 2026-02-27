# Code Review: Unicode Script Support for PDF Export

**Plan file:** `/Users/niyaro/Documents/Code/ff-dev/pandoc-pdf/docs/plans/mighty-mapping-cookie.md`
**Reviewer:** Code Review Agent
**Status:** Review complete -- issues found (2 critical, 3 important, 4 suggestions)

---

## Overall Assessment

The plan correctly identifies the core problem (XeLaTeX drops characters when the font lacks glyphs) and proposes a sensible architecture: detect languages with NLLanguageRecognizer, map them to macOS system fonts, and pass font names to pandoc via variables. The CJK path using `--variable CJKmainfont=X` is well-supported by pandoc's default template. The plan's desire to minimize bundle size by using macOS system fonts rather than bundling CJK font collections is a sound approach.

However, the plan has two critical issues (RTL approach is broken, font name is wrong), several important gaps, and some factual inaccuracies in the dependency analysis.

---

## 1. CRITICAL: `dir=rtl` Does NOT Work for XeLaTeX in Pandoc's Template

**This is the most serious issue in the plan.**

The plan states:

> Pandoc's XeLaTeX template loads `bidi` when `dir: rtl` is set.

This is **false**. I examined the pandoc 3.9 default LaTeX template (the version installed on this system). The `$if(dir)$` block in `common.latex` only defines `\RL`, `\LR`, `RTL`, and `LTR` macros for **PDFTeX and LuaTeX**:

```latex
$if(dir)$
\ifPDFTeX
  \TeXXeTstate=1
  \newcommand{\RL}[1]{\beginR #1\endR}
  ...
\fi
\ifluatex
  \newcommand{\RL}[1]{\bgroup\textdir TRT#1\egroup}
  ...
\fi
$endif$
```

There is **no XeTeX branch**. The `bidi` package is never loaded by the default template for XeLaTeX. This is a [known, unresolved issue](https://github.com/jgm/pandoc/issues/8460) -- the `RTL` environment is undefined when using XeLaTeX with `dir=rtl`.

The plan also proposes manually bundling `bidi` .sty files (~1.6 MB). Even if bundled, `bidi` would never be loaded because the template has no `\usepackage{bidi}` call for XeTeX.

**Consequence:** Setting `--variable dir=rtl` will NOT enable RTL text rendering for Arabic/Hebrew with XeLaTeX. The text will render left-to-right, which is incorrect.

**Recommendation:** For RTL support with XeLaTeX, the plan needs one of these approaches:

- **Option A (simplest):** Use `--variable lang=ar` (or `he`) plus `--variable dir=rtl` combined with `--variable header-includes="\usepackage{bidi}"`. This injects bidi via the header-includes mechanism. However, this requires the `bidi` package to actually be in TinyTeX (currently it is NOT).
- **Option B (babel):** Use `--variable lang=ar` which triggers babel with `bidi=default` for XeLaTeX (see the `$if(lang)$` block in `common.latex`). Babel handles RTL natively. However, this requires the Arabic babel locale, which is also NOT currently in TinyTeX (only `hebrew.sty` is present, not `arabic.sty`).
- **Option C (custom template):** Provide a modified LaTeX template via `--template` that adds `\usepackage{bidi}` for XeTeX when `dir` is set. This is the most robust but adds maintenance burden.
- **Option D (defer RTL):** Acknowledge RTL support as a future phase and implement only the CJK + Indic/Thai font mapping now, which does work via `CJKmainfont` and `mainfont` variables.

---

## 2. CRITICAL: "Myriad Arabic" Font Does Not Exist on macOS

The plan maps `.arabic` to font "Myriad Arabic":

| NLLanguage | Font |
|------------|------|
| `.arabic` | Myriad Arabic |

I checked the system font list with `fc-list` and there is **no "Myriad Arabic" font** on this macOS system. The available Arabic-capable fonts are:

- `Geeza Pro` (the standard macOS Arabic serif/body font)
- `.SF Arabic` (system UI font, not available to apps by name)

The correct font name for Arabic body text on macOS is **"Geeza Pro"**, not "Myriad Arabic". Myriad Arabic was an Adobe font that was never part of macOS system fonts.

**Recommendation:** Replace "Myriad Arabic" with "Geeza Pro" in the font mapping table.

---

## 3. IMPORTANT: Japanese Font Name Needs Qualification

The plan maps `.japanese` to "Hiragino Mincho". The actual font names on macOS are:

- `Hiragino Mincho Pro` (legacy JIS character set)
- `Hiragino Mincho ProN` (JIS2004 character set -- preferred)

"Hiragino Mincho" by itself is not a valid font family name. XeLaTeX may or may not resolve it. The correct name to use is **"Hiragino Mincho ProN"** which uses the newer JIS2004 character set.

**Recommendation:** Change the font name from "Hiragino Mincho" to "Hiragino Mincho ProN".

---

## 4. IMPORTANT: TinyTeX Bundle State is Inconsistent with Plan Step 1

The plan's step 1 says to revert TinyTeX to its pre-xeCJK state (270 MB). However, the current TinyTeX bundle is **503 MB** and already contains:

- xeCJK .sty files at `texmf-dist/tex/xelatex/xecjk/` (325 KB total, all files)
- Full ctex at `texmf-dist/tex/latex/ctex/` (740 KB)
- Fandol CJK fonts at `texmf-dist/fonts/opentype/public/fandol/` (33 MB)
- CJK, cjkpunct, xcjk2uni packages (3.3 MB combined)
- TIPA phonetics package (156 KB)
- Thai fonts (fonts-tlwg, 3.2 MB)
- 265 MB total in `texmf-dist/fonts/`

The plan says to `git checkout HEAD -- "final final/Resources/TinyTeX/"` to restore the 270 MB bundle, then manually add back only the .sty files. This means **the xeCJK install has already been done but not reverted**, and step 1 must be executed before step 2, or the plan's size estimates are wrong.

**Recommendation:** Clarify whether the revert has been done or still needs to be done. If the current 503 MB state is what's in the working tree, the `git checkout` in step 1 should restore the committed state. Verify that `HEAD` has the clean 270 MB bundle (i.e., the bloated install was never committed). If it was committed, a different approach is needed.

---

## 5. IMPORTANT: xeCJK Dependency Analysis is Incomplete

The plan states xeCJK needs only `ctexhook.sty` beyond `l3kernel` and `fontspec`. I examined the actual `\RequirePackage` calls in `xeCJK.sty`:

```
Line 31:  \RequirePackage{expl3}           -- provided by l3kernel (present)
Line 54:  \RequirePackage { ctexhook }     -- plan accounts for this (present at ctex/ctexhook.sty)
Line 78:  \RequirePackage { xparse }       -- provided by l3packages (present)
Line 79:  \RequirePackage { xtemplate }    -- provided by l3packages (present)
Line 4550: \RequirePackage { l3keys2e }    -- provided by l3packages (present)
Line 4553: \RequirePackage { fontspec }    -- present
Line 4875: \RequirePackage { xunicode-addon } -- BUNDLED WITH xeCJK (present in xecjk/)
Line 5072: \RequirePackage { xeCJK-listings } -- BUNDLED WITH xeCJK (present in xecjk/)
```

All dependencies are satisfied by the current TinyTeX bundle. If the plan reverts to the 270 MB bundle and re-adds only the xeCJK .sty files, the dependencies (`l3kernel`, `l3packages/xparse`, `l3packages/xtemplate`, `l3packages/l3keys2e`, `fontspec`) should all be present in the base TinyTeX install. The plan's claim that only `ctexhook.sty` is needed beyond the pre-existing packages appears correct -- but only if the base TinyTeX bundle has all of the above. This should be verified after the revert.

**Recommendation:** After performing step 1 (revert), verify that `l3packages/xtemplate/`, `l3packages/l3keys2e/`, and `l3packages/xparse/` still exist. They likely do (they're part of the base LaTeX3 kernel), but this should be confirmed.

---

## 6. Pandoc CJKmainfont Variable: CONFIRMED Working

The pandoc `font-settings.latex` partial contains:

```latex
$if(CJKmainfont)$
  \ifXeTeX
    \usepackage{xeCJK}
    \setCJKmainfont[$for(CJKoptions)$$CJKoptions$$sep$,$endfor$]{$CJKmainfont$}
  \fi
$endif$
```

This confirms that `--variable CJKmainfont=X` will:
1. Load xeCJK automatically
2. Set the CJK main font

The plan's CJK approach is correctly validated. No bidi or manual xeCJK loading is needed for CJK scripts -- pandoc handles it.

---

## 7. NLLanguageRecognizer in an Actor: CONFIRMED Safe

`ExportService` is declared as `actor ExportService`. The plan proposes adding `import NaturalLanguage` and using `NLLanguageRecognizer` inside the actor.

`NLLanguageRecognizer` is a plain NSObject subclass with no `@MainActor` annotation. It performs no UI work. Creating an instance, calling `processString()`, and reading `languageHypotheses(withMaximum:)` are all synchronous, non-UI operations. They will run on the actor's serial executor, which is correct and safe.

There are no concurrency issues with this approach.

---

## 8. Edge Cases: Short Documents and Low Confidence

The plan uses a 0.05 (5%) confidence threshold:

```swift
let hypotheses = recognizer.languageHypotheses(withMaximum: 10)
return hypotheses.filter { $0.value > 0.05 }.map { $0.key }
```

**Concerns:**

- **Very short documents** (1-3 sentences): NLLanguageRecognizer may return low confidence or incorrect results. For example, a single Chinese sentence embedded in English might not reach the 5% threshold, or might be misclassified.
- **Mixed Simplified/Traditional Chinese**: As noted in [hanzidentifier research](https://github.com/tsroten/hanzidentifier), the Simplified and Traditional character sets overlap significantly. Short passages may be misclassified. NLLanguageRecognizer is ML-based and handles this better than character-set analysis, but accuracy degrades with short inputs.
- **Fallback behavior**: If no language is detected above threshold, no font variables are added, and the document renders with the default Latin Modern font. CJK characters would still be silently dropped. There is no user feedback that detection failed.

**Recommendation:**
- Add a fallback: if the document contains CJK Unicode ranges (U+4E00-U+9FFF, U+3040-U+309F, U+30A0-U+30FF, U+AC00-U+D7AF) but NLLanguageRecognizer returns no CJK language above threshold, default to "Songti SC" for CJK (covers most CJK characters) and log a warning.
- Consider lowering the threshold for CJK detection specifically, or using Unicode range detection as a supplement.
- Add a user-visible warning in ExportResult.warnings when language detection confidence is low, so the user knows font selection may be incorrect.

---

## 9. SUGGESTION: Korean Font Choice

The plan maps `.korean` to "Apple SD Gothic Neo", which is a **sans-serif (gothic)** font. All other CJK mappings use serif fonts (Songti, Hiragino Mincho). For typographic consistency in PDF documents, a Korean serif font would be more appropriate.

Unfortunately, macOS does not ship a Korean serif font. "Apple SD Gothic Neo" is the only Korean font available. The choice is therefore correct for macOS, but worth noting that the typographic style will differ from Chinese and Japanese text in the same document.

---

## 10. SUGGESTION: mainfont Conflict with Multiple Non-CJK Scripts

The plan states:

> Other scripts set `mainfont` (first detected wins if multiple)

The `mainfont` variable in pandoc's template calls `\setmainfont{...}`, which sets the **entire document's main font**. If a document contains Hindi and Thai text, only one can "win" the mainfont slot. The other script's characters will be rendered in the winning font, which likely lacks the needed glyphs.

This is acknowledged implicitly in the plan ("first detected wins"), but the consequence is that **multi-script documents beyond CJK will have broken rendering for the second script**. CJK avoids this because xeCJK uses a separate font slot (`\setCJKmainfont`).

**Recommendation:** For a future improvement, consider using pandoc's `mainfontfallback` variable (supported in LuaTeX only, not XeTeX) or a custom LaTeX template with `ucharclasses` package for per-Unicode-block font switching. For now, the "first detected wins" approach is acceptable as an initial implementation, but document this limitation.

---

## 11. SUGGESTION: bidi Bundle is Unnecessary Given the RTL Issues

Since `dir=rtl` does not trigger bidi loading in the XeLaTeX template (see Issue 1), bundling the bidi .sty files (~1.6 MB) provides no benefit in the current plan. The `zref` dependency mentioned in the plan (~149 KB) would also be unnecessary.

If RTL support is deferred (as recommended in Issue 1, Option D), the entire bidi bundling step can be removed, simplifying the plan and saving ~1.75 MB.

---

## 12. SUGGESTION: XeLaTeX Missing Glyph Behavior

The plan states:

> XeLaTeX silently drops characters it can't render.

This is confirmed by research. XeLaTeX produces a **warning** in the log ("Missing character: There is no X in font Y") but the character is **omitted** from the PDF output. It does not substitute a replacement glyph (like the `.notdef` tofu box) or raise an error. The diagnosis in the plan is correct.

Source: [XeTeX using fonts with missing glyphs](https://texhax.tug.narkive.com/acJ622rm/xetex-using-fonts-with-missing-glyphs)

---

## Summary of Issues

| # | Severity | Issue | Section |
|---|----------|-------|---------|
| 1 | Critical | `dir=rtl` does NOT enable bidi/RTL for XeLaTeX -- pandoc template has no XeTeX branch | 1 |
| 2 | Critical | "Myriad Arabic" font does not exist on macOS; should be "Geeza Pro" | 2 |
| 3 | Important | "Hiragino Mincho" is not a valid font name; needs "Hiragino Mincho ProN" | 3 |
| 4 | Important | TinyTeX bundle state (503 MB) is inconsistent with plan's starting point (270 MB) | 4 |
| 5 | Important | No fallback for short documents where NLLanguageRecognizer returns low confidence | 8 |
| 6 | Suggestion | Korean font is sans-serif while all other CJK fonts are serif | 9 |
| 7 | Suggestion | `mainfont` variable cannot handle multiple non-CJK scripts simultaneously | 10 |
| 8 | Suggestion | bidi bundle is unnecessary since RTL approach is broken | 11 |
| 9 | Suggestion | Add Arabic babel locale file if pursuing babel-based RTL approach | 1 |

---

## Recommendation

The plan should NOT be implemented as-is. The two critical issues must be resolved first:

1. **RTL approach must be redesigned.** The simplest path forward is to defer RTL support entirely (Option D from section 1) and implement only the CJK + Indic/Thai font mapping, which works correctly via pandoc's existing template. RTL can be added in a follow-up phase once the template/bidi approach is sorted out.

2. **Font names must be corrected** -- "Geeza Pro" instead of "Myriad Arabic", "Hiragino Mincho ProN" instead of "Hiragino Mincho".

3. **Add a Unicode-range fallback** for CJK detection to handle short documents where NLLanguageRecognizer may not return confident results.

If RTL is deferred, the plan becomes significantly simpler: no bidi bundling, no `dir=rtl` variables, just CJK fonts (via `CJKmainfont`) and Indic/Thai fonts (via `mainfont`). The xeCJK .sty bundling (step 2) and language detection (step 4) remain valid as designed.
