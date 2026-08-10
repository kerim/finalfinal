//
//  ExportService+Citations.swift
//  final final
//

import Foundation

// MARK: - Shared citekey regex

/// Single, precompiled source of truth for the span/key regex pair used to extract (and, for
/// `ExportService.canonicalizeCitekeys`, rewrite) pandoc citekeys. Three consumers share this
/// exact pair: `ExportService.extractCitekeys`, `BibliographySyncService.extractCitekeys`
/// (its own copy used to be precompiled separately -- see that type's doc comment on why
/// precompilation matters there, running on every live content change), and
/// `ExportService.canonicalizeCitekeys`. See `ExportService.extractCitekeys`'s doc comment
/// for the full ~40 lines of accept/reject rules these two patterns encode (rejects
/// `[contact me@example.com]`, `[install @scope/pkg]`, `[see bsky.app/@handle]`; handles
/// `[@key{p. 21}]`, `[see @key]`, `[-@key]`). A single shared pair keeps every consumer bound
/// to the exact same behavior instead of three copies that could silently drift apart.
/// Compile-time constant patterns -- a compile failure would be a programming error (a typo),
/// not a runtime condition, matching `MarkdownUtils`'s own `try!` convention for precompiled
/// patterns.
enum ExportCitationRegex {
    /// Matches each complete `[...]` bracket span.
    // swiftlint:disable:next force_try
    static let span = try! NSRegularExpression(pattern: #"\[[^\]]*\]"#)
    /// Matches each `@citekey` inside a span found by `span`, capturing the key in group 1.
    // swiftlint:disable:next force_try
    static let key = try! NSRegularExpression(
        pattern: #"(?<![\w/])@(?![^\]{}\s]*/)([^\]{}/,;\s]+)"#
    )
}

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
        let full = NSRange(stripped.startIndex..., in: stripped)
        return ExportCitationRegex.span.matches(in: stripped, range: full).flatMap { span in
            ExportCitationRegex.key.matches(in: stripped, range: span.range).compactMap { match in
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
        /// The CSL `id` of every resolved item backing `json` that is SAFE to use as a
        /// citekey-case rewrite target, deduped and in the same stable order `json` was
        /// serialized in (see `fetchBibliographyJSON`'s dedupe step). Feeds
        /// `canonicalCitekeyMap`'s collision guard — never re-derived by re-parsing `json`.
        ///
        /// "Safe" excludes any item whose `citation-key` field is present AND differs from its
        /// `id` (the legacy Zotero "Extra"-field shape — see `parsePandocFilterResponseRaw`'s
        /// doc comment). PDF's `--citeproc` matches bibliography entries by `id`, but DOCX/ODT's
        /// `zotero.lua` does its own live BBT lookup keyed by `citation-key`, not `id`. An item
        /// with a divergent `citation-key` can have that field differ from `id` by nothing more
        /// than case (e.g. `citation-key: "Smith2020"`, `id: "smith2020"`) — a shape indistinguishable
        /// from a genuine pure-case rename target by `canonicalCitekeyMap`'s rule alone. Rewriting
        /// the document's citekey text to the `id` spelling would fix PDF but break DOCX/ODT: the
        /// literal string zotero.lua looks up would no longer match the item's `citation-key` at
        /// all. So such an item is dropped from `resolvedIDs` entirely -- never proposed as a
        /// rewrite target for ANY format -- leaving both PDF and DOCX/ODT at today's
        /// unresolved-if-miscased behavior for it, rather than fixing one format by breaking the
        /// other.
        let resolvedIDs: [String]
        /// See `RawCitekeyBatchResult.rawAmbiguousKeys`'s doc comment — a plain union that
        /// survives even when `ambiguousKeys` above gets cleared. Feeds `canonicalCitekeyMap`'s
        /// ambiguity veto.
        let rawAmbiguousKeys: Set<String>
        /// See `RawCitekeyBatchResult.supportsAmbiguityReporting`'s doc comment: false whenever
        /// this batch resolved via the `item.export` fallback (no ambiguity information of any
        /// kind available), in which case `canonicalCitekeyMap` must never be called at all —
        /// see `ExportService.swift`'s sequencing for where this is enforced.
        let supportsAmbiguityReporting: Bool
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
            return BibliographyFetchResult(
                json: nil, notFoundKeys: [], ambiguousKeys: [], resolvedIDs: [], rawAmbiguousKeys: [],
                supportsAmbiguityReporting: true
            )
        }

        do {
            let batch = try await ZoteroService.shared.fetchRawItemsForCitekeys(citekeys)
            guard !batch.items.isEmpty else {
                return BibliographyFetchResult(
                    json: nil,
                    notFoundKeys: batch.notFoundKeys,
                    ambiguousKeys: batch.ambiguousKeys,
                    resolvedIDs: [],
                    rawAmbiguousKeys: batch.rawAmbiguousKeys,
                    supportsAmbiguityReporting: batch.supportsAmbiguityReporting
                )
            }

            // Dedupe by CSL `id` (first occurrence wins, stable order) BEFORE serializing to
            // JSON. Needed because the `item.export` fallback path doesn't dedupe on its own,
            // and a document that cites the same work under two casings requests BOTH
            // spellings in the same batch, before the citekey-case rewrite (which runs after
            // this fetch -- see ExportService.swift's sequencing) has a chance to collapse
            // them to one. Without this, the same work could appear twice in the PDF
            // reference list.
            var seenIDs = Set<String>()
            var dedupedItems: [[String: Any]] = []
            dedupedItems.reserveCapacity(batch.items.count)
            for item in batch.items {
                guard let id = item["id"] as? String else {
                    dedupedItems.append(item)
                    continue
                }
                guard seenIDs.insert(id).inserted else { continue }
                dedupedItems.append(item)
            }

            let data = try JSONSerialization.data(withJSONObject: dedupedItems)
            return BibliographyFetchResult(
                json: String(data: data, encoding: .utf8),
                notFoundKeys: batch.notFoundKeys,
                ambiguousKeys: batch.ambiguousKeys,
                // See BibliographyFetchResult.resolvedIDs's doc comment: an item whose
                // citation-key diverges from its id (even by case alone) is never a safe
                // rewrite target -- DOCX/ODT's zotero.lua looks items up by citation-key, not
                // id, so rewriting the document's citekey text to the id spelling would break
                // that lookup for this item even though it fixes PDF's --citeproc matching.
                resolvedIDs: dedupedItems.compactMap { item -> String? in
                    guard let id = item["id"] as? String else { return nil }
                    if let citationKey = item["citation-key"] as? String, citationKey != id {
                        return nil
                    }
                    return id
                },
                rawAmbiguousKeys: batch.rawAmbiguousKeys,
                supportsAmbiguityReporting: batch.supportsAmbiguityReporting
            )
        } catch {
            DebugLog.log(.fileOps, "[ExportService] Failed to fetch bibliography JSON: \(error)")
            // Unknown failure -- treat as "ambiguity information not available" so the caller
            // never proposes a rewrite off a batch we know nothing about.
            return BibliographyFetchResult(
                json: nil, notFoundKeys: [], ambiguousKeys: [], resolvedIDs: [], rawAmbiguousKeys: [],
                supportsAmbiguityReporting: false
            )
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

    // MARK: - Citekey case canonicalization

    /// Propose a `requested -> canonical` rewrite map for citekeys whose exact spelling
    /// differs ONLY in case from a citekey Zotero/BBT actually resolved (an item's CSL `id`
    /// field in `resolvedIDs` — never `citation-key`, which can diverge from `id` for a
    /// legacy Zotero "Extra" field shape; see `parsePandocFilterResponseRaw`'s doc comment).
    /// This is the mechanism behind rewriting a miscased citation (`[@smith2020]` when the
    /// document elsewhere also cites `[@Smith2020]`) so it resolves in the exported PDF's
    /// case-sensitive `--citeproc` matching and in DOCX/ODT's `zotero.lua`, which does its own
    /// live BBT lookup keyed by the exact literal citekey string.
    ///
    /// A rename `requested -> canonical` is proposed only when ALL of:
    /// 1. `requested` and `canonical` are case-folds of each other but not identical -- a
    ///    PURE case difference. This is what protects the legacy-Extra-field shape: if a
    ///    citekey's resolved `id` differs from `requested` for some unrelated reason (not a
    ///    case fold), no rename is proposed for it, and `citation-key` is never consulted at
    ///    all -- renames are always pinned to `id`.
    /// 2. `requested` is not in `rawAmbiguousKeys` -- never rename off an arbitrary winner
    ///    among 2+ real BBT matches for the exact spelling requested.
    /// 3. Collision guard: `resolvedIDs` is grouped by its lowercased fold; any fold-group
    ///    with 2+ DISTINCT ids is dropped from consideration entirely, so two genuinely
    ///    different works whose ids happen to differ only by case are never merged into one
    ///    canonical spelling.
    nonisolated static func canonicalCitekeyMap(
        requested: [String],
        resolvedIDs: [String],
        rawAmbiguousKeys: Set<String>
    ) -> [String: String] {
        // Group resolved ids by lowercased fold. A fold-group with 2+ DISTINCT ids means two
        // real, different works differ only by case -- never safe to canonicalize onto either.
        var idsByFold: [String: Set<String>] = [:]
        for id in resolvedIDs {
            idsByFold[id.lowercased(), default: []].insert(id)
        }

        var map: [String: String] = [:]
        for key in requested {
            guard !rawAmbiguousKeys.contains(key) else { continue }
            guard let idsInFold = idsByFold[key.lowercased()],
                  idsInFold.count == 1,
                  let canonical = idsInFold.first,
                  canonical != key
            else { continue }
            map[key] = canonical
        }
        return map
    }

    /// Rewrite every citekey occurrence in `content` that matches a `map` key to its
    /// canonical spelling. Returns `content` unchanged when `map` is empty.
    ///
    /// Implementation: mask out code fences/inline code via `MarkdownUtils.maskCodeContent`
    /// (offset-preserving), scan the MASK with the shared `ExportCitationRegex` span/key
    /// pattern pair to find every `@key` match whose captured text is a `map` key, then apply
    /// the replacements to the ORIGINAL `content` in REVERSE document order (last match
    /// first).
    ///
    /// Reverse order is load-bearing for two independent reasons:
    /// 1. Masking is only offset-safe for READING (finding where each match is) -- once an
    ///    edit is applied, it shifts every later offset unless replacements are applied
    ///    back-to-front.
    /// 2. "Differs only in case" does NOT guarantee equal length: a Turkish İ (U+0130)
    ///    lowercases to a two-UTF-16-unit sequence, so a length-changing replacement earlier
    ///    in the document would corrupt every subsequent match's offset if applied forward.
    func canonicalizeCitekeys(in content: String, using map: [String: String]) -> String {
        guard !map.isEmpty else { return content }

        let masked = MarkdownUtils.maskCodeContent(in: content)
        let nsContent = content as NSString
        let full = NSRange(location: 0, length: (masked as NSString).length)

        var replacements: [(range: NSRange, replacement: String)] = []
        for span in ExportCitationRegex.span.matches(in: masked, range: full) {
            for match in ExportCitationRegex.key.matches(in: masked, range: span.range) {
                let keyRange = match.range(at: 1)
                guard keyRange.location != NSNotFound else { continue }
                let keyText = nsContent.substring(with: keyRange)
                guard let canonical = map[keyText] else { continue }
                replacements.append((keyRange, canonical))
            }
        }

        guard !replacements.isEmpty else { return content }

        var result = content
        for (range, replacement) in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            guard let swiftRange = Range(range, in: result) else { continue }
            result.replaceSubrange(swiftRange, with: replacement)
        }
        return result
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
