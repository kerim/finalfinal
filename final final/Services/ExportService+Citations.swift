//
//  ExportService+Citations.swift
//  final final
//

import Foundation

// MARK: - Citation Detection

extension ExportService {

    /// Detect Pandoc citations in content (skips code blocks and inline code)
    /// Matches any bracketed text containing @ followed by a citekey
    /// Pattern from citation-plugin.ts: \[([^\]]*@[\w:.-][^\]]*)\]
    func hasPandocCitations(in content: String) -> Bool {
        let stripped = MarkdownUtils.stripCodeContent(from: content)
        return stripped.range(
            of: #"\[[^\]]*@[\w:.-]+[^\]]*\]"#,
            options: .regularExpression
        ) != nil
    }

    /// Extract citekeys from markdown content (skips code blocks and inline code).
    /// Two passes: find each complete `[...]` span, then pull every `@citekey` inside it.
    /// This catches the prose-before-@ form (`[see @key]`) and the suppress-author form
    /// (`[-@key]`) alongside `[@key]` / `[@key, p. 21]` -- all genuinely bracketed pandoc
    /// citations. A bare `@key` is deliberately NOT a citation in any format; it is
    /// flattened to literal text by bare-citations-literal.lua on the PDF path, and has
    /// always been literal on the DOCX/ODT path (zotero.lua leaves AuthorInText alone).
    ///
    /// Scoping to a *closed* span matters: `[^\]]` matches newlines, so a single relaxed
    /// pattern with no closing-`]` requirement would let one stray `[` swallow every later
    /// `@token` in the document. Known accepted trade-off: an unmatched `[` still lets a
    /// LATER bare `@token` (anywhere after it, even past the next real `]`) get pulled in
    /// as a spurious citekey lookup -- verified real, deliberately not fixed, because the
    /// alternative (excluding nested `[` entirely, e.g. `[^\[\]]*`) breaks the legitimate
    /// `[see @a [sic]]` shape by turning it into an empty match instead of a resolved
    /// citation. A spurious "not found" warning is judged less bad than a citation that
    /// silently stops resolving.
    ///
    /// The key's character class and the guards around it exist to avoid fetching garbage
    /// keys from Zotero (each bogus key costs a spurious "not found: ..." warning, and can
    /// stop the real key resolving):
    /// - `{`/`}` excluded -- `[@smith2020{p. 21}]` is valid pandoc locator syntax with no
    ///   space, verified against real pandoc; without this the key becomes `smith2020{p.`
    /// - `,` `;` whitespace excluded -- the comma-locator and multi-cite forms.
    /// - `(?<!\w)` -- rejects an email inside brackets (`[contact me@example.com]`).
    /// - `(?<!/)` plus the `(?![^\]{}\s]*/)` lookahead -- reject a URL handle and an npm
    ///   scoped package (`[see bsky.app/@handle]`, `[install @scope/pkg]`).
    /// Deliberately does NOT require a lowercase first character (unlike the deleted
    /// narrative-citation code) -- real citekeys like `[@Smith2020]` work today and must
    /// keep working.
    ///
    /// Three more known, deliberately-accepted trade-offs, alongside the unmatched-`[` one
    /// above:
    /// - `[@some/key]` (a `/`-containing citekey -- legal pandoc syntax) now extracts
    ///   nothing, a real behavior change from the old regex, which did extract it. Accepted
    ///   because BBT/Zotero doesn't actually emit `/` in real citekeys in practice, and `/`
    ///   is excluded specifically to reject npm-scoped-package shapes like `@scope/pkg`,
    ///   which are structurally indistinguishable from a real `/`-containing citekey --
    ///   there is no clean way to keep one and reject the other. Not being fixed.
    /// - `[@{key with spaces}]` (brace-DELIMITED citekey -- a real but rare pandoc syntax)
    ///   also extracts nothing, same as before this round's changes (not a new regression --
    ///   the OLD regex extracted a garbage fragment here instead, arguably worse). The
    ///   `{`/`}` exclusion above serves two purposes, not one: correctly handling the
    ///   no-space brace-LOCATOR syntax (`[@key{p. 21}]`) is the primary reason, and as a
    ///   side effect it also breaks this separate brace-DELIMITER citekey syntax.
    /// - Any closed bracket span is now eligible to yield citekeys, including ones never
    ///   meant to be citations -- e.g. markdown image alt text (`![alt @x](img.png)`) or a
    ///   markdown link whose visible text happens to contain an `@word`
    ///   (`[contact @support](mailto:...)`) can trigger a spurious Zotero lookup and a
    ///   "not found" warning. NEW to this round -- the old, narrower regex couldn't reach
    ///   these shapes. Known, accepted gap for now; a future narrowing (rejecting a span
    ///   immediately followed by `(`, markdown's link/image syntax) is a reasonable
    ///   follow-up, but out of scope for this round.
    func extractCitekeys(from content: String) -> [String] {
        let stripped = MarkdownUtils.stripCodeContent(from: content)
        guard let spanRegex = try? NSRegularExpression(pattern: #"\[[^\]]*\]"#),
              let keyRegex = try? NSRegularExpression(
                  pattern: #"(?<![\w/])@(?![^\]{}\s]*/)([^\]{}/,;\s]+)"#)
        else { return [] }
        let full = NSRange(stripped.startIndex..., in: stripped)
        return spanRegex.matches(in: stripped, range: full).flatMap { span in
            keyRegex.matches(in: stripped, range: span.range).compactMap { match in
                guard let r = Range(match.range(at: 1), in: stripped) else { return nil }
                return String(stripped[r])
            }
        }
    }

    /// Result of `fetchBibliographyJSON`: the resolved bibliography CSL-JSON (nil if nothing
    /// resolved or the fetch failed outright), plus which requested citekeys were skipped —
    /// named separately (not-found vs. ambiguous) so the caller can build a specific warning
    /// instead of dropping the whole bibliography over one bad citekey.
    struct BibliographyFetchResult {
        let json: String?
        let notFoundKeys: Set<String>
        let ambiguousKeys: Set<String>
    }

    /// Fetch bibliography as raw CSL-JSON string from Zotero/BBT for the given citekeys, for
    /// pandoc's `--bibliography` argument.
    ///
    /// Routes through `ZoteroService.fetchRawItemsForCitekeys()` — the shared, library-scoped,
    /// RAW (undecoded) resolver — instead of making its own raw `item.export` JSON-RPC call
    /// (which used to be unscoped, silently "My Library"-only, the same defect as the old
    /// citekey resolver, so PDF export silently dropped group-library citations) and instead
    /// of the typed `fetchItemsForCitekeys()`/`CSLItem` resolver: `CSLItem` only models a
    /// subset of CSL-JSON fields, and re-encoding through it would silently drop every field
    /// it doesn't know about (translator, edition, collection-title, chapter-number, genre,
    /// original-date, etc.) — fields the bundled `chicago-author-date.csl` style actually
    /// uses. The raw resolver shares the exact same two-phase (personal-then-group) resolution
    /// and `item.pandoc_filter`-with-fallback behavior as CAYW/autocomplete, just without the
    /// lossy round trip. Never throws: a batch with some unresolved citekeys still returns a
    /// partial bibliography for the rest, rather than losing `--citeproc` for the whole
    /// document over one bad citekey.
    func fetchBibliographyJSON(for citekeys: [String]) async -> BibliographyFetchResult {
        guard !citekeys.isEmpty else {
            return BibliographyFetchResult(json: nil, notFoundKeys: [], ambiguousKeys: [])
        }

        do {
            let batch = try await ZoteroService.shared.fetchRawItemsForCitekeys(citekeys)
            guard !batch.items.isEmpty else {
                return BibliographyFetchResult(json: nil, notFoundKeys: batch.notFoundKeys, ambiguousKeys: batch.ambiguousKeys)
            }

            let data = try JSONSerialization.data(withJSONObject: batch.items)
            return BibliographyFetchResult(
                json: String(data: data, encoding: .utf8),
                notFoundKeys: batch.notFoundKeys,
                ambiguousKeys: batch.ambiguousKeys
            )
        } catch {
            DebugLog.log(.fileOps, "[ExportService] Failed to fetch bibliography JSON: \(error)")
            return BibliographyFetchResult(json: nil, notFoundKeys: [], ambiguousKeys: [])
        }
    }

    /// The warning to show when `fetchBibliographyJSON` couldn't produce a bibliography at all
    /// (`json` is nil — see that function's doc comment: this only happens when the resolved-
    /// items batch came back empty). Mutually exclusive by construction, unlike the two
    /// messages this replaces being emitted together ever could be: a specific not-found/
    /// ambiguous key list means Zotero WAS reachable and answered, it just couldn't resolve
    /// every requested key, so the specific per-key wording is used instead of also blaming
    /// "could not fetch bibliography data from Zotero" — which would be both wrong (Zotero
    /// didn't fail) and contradictory (there's no bibliography to have "omitted" a key from if
    /// fetching itself had failed). The generic connection-failure wording is reserved for when
    /// there is no per-key information at all (Zotero unreachable, BBT RPC error, etc.).
    func fetchFailureWarning(notFound: Set<String>, ambiguous: Set<String>) -> String {
        guard notFound.isEmpty && ambiguous.isEmpty else {
            return partialBibliographyWarning(notFound: notFound, ambiguous: ambiguous)
        }
        return "Could not fetch bibliography data from Zotero. Citations were not resolved."
    }

    /// Result of `bibliographyWriteArguments`: the Pandoc arguments to append, the temp
    /// bibliography file to clean up afterward (if one was written), and any warnings. A named
    /// struct rather than a 3-member tuple -- mirrors `BibliographyFetchResult` above -- to stay
    /// under SwiftLint's `large_tuple` limit; call sites are unaffected since the property names
    /// (`.arguments`, `.tempBibURL`, `.warnings`) are identical to the tuple's former labels.
    struct BibliographyWriteResult {
        let arguments: [String]
        let tempBibURL: URL?
        let warnings: [String]
    }

    /// Write the resolved bibliography JSON to `tempDir` and build the pandoc
    /// `--citeproc`/`--bibliography`/`--csl` arguments from it. The returned warnings are
    /// mutually exclusive by construction, the same way `fetchFailureWarning`'s are: when the
    /// write succeeds, a still-partial batch (some requested keys not found/ambiguous) gets
    /// `partialBibliographyWarning`; when the write itself fails, only the write-failure
    /// warning is returned — nothing was "omitted from the bibliography" that was never
    /// written and never passed to pandoc, so pairing both would be self-contradictory.
    ///
    /// Factored out of `citationArguments` (its only real call site) so a unit test can
    /// exercise the write-failure branch directly — by pointing `tempDir` at a location that
    /// can't be written to — without needing a live pandoc binary or a live Zotero connection
    /// to reach it through the full `citationArguments`/`export()` pipeline. Mirrors
    /// `preprocessContentForExport`'s existing extraction in `ExportService.swift` for the
    /// same reason.
    func bibliographyWriteArguments(
        bibJSON: String,
        notFoundKeys: Set<String>,
        ambiguousKeys: Set<String>,
        settings: ExportSettings,
        tempDir: URL
    ) -> BibliographyWriteResult {
        var args: [String] = []
        var tempBibURL: URL?
        var warnings: [String] = []

        let bibURL = tempDir.appendingPathComponent(UUID().uuidString + ".json")
        do {
            try bibJSON.write(to: bibURL, atomically: true, encoding: .utf8)
            tempBibURL = bibURL
            args.append(contentsOf: [
                "--citeproc", "--bibliography", bibURL.path,
                "--metadata", "reference-section-title=\(settings.effectiveBibliographyHeaderName)"
            ])
            if let cslPath = ExportService.bundledCSLStylePath {
                args.append(contentsOf: ["--csl", cslPath])
            }
            if !notFoundKeys.isEmpty || !ambiguousKeys.isEmpty {
                warnings.append(partialBibliographyWarning(notFound: notFoundKeys, ambiguous: ambiguousKeys))
            }
        } catch {
            warnings.append("Could not write bibliography data. Citations were not resolved.")
        }

        return BibliographyWriteResult(arguments: args, tempBibURL: tempBibURL, warnings: warnings)
    }

    /// Named warning for citekeys skipped from a partial bibliography — either not found in any
    /// library, or ambiguous across libraries (see `RawCitekeyBatchResult`'s doc comment).
    func partialBibliographyWarning(notFound: Set<String>, ambiguous: Set<String>) -> String {
        var parts: [String] = []
        if !notFound.isEmpty {
            parts.append("not found: \(notFound.sorted().joined(separator: ", "))")
        }
        if !ambiguous.isEmpty {
            parts.append("ambiguous: \(ambiguous.sorted().joined(separator: ", "))")
        }
        return "Some citations could not be resolved and were omitted from the bibliography (\(parts.joined(separator: "; ")))."
    }

    /// Strip annotation HTML comments from markdown content
    /// Matches patterns like <!-- ::task:: text --> or <!-- ::comment:: notes -->
    func stripAnnotations(from content: String) -> String {
        // Match annotation comments: <!-- ::type:: text -->
        // Annotations can span multiple lines and contain various content
        // Use .dotMatchesLineSeparators so .*? can span newlines
        content.replacingOccurrences(
            of: #"<!--\s*::\w+::\s*[\s\S]*?-->"#,
            with: "",
            options: .regularExpression
        )
    }
}
