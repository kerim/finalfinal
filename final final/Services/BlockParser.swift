//
//  BlockParser.swift
//  final final
//
//  Parses markdown content into Block structures.
//  Splits by double newlines and detects block types from content.
//
//  Companion files:
//    - BlockParser+Splitting.swift — markdown → raw block strings
//    - BlockParser+Images.swift    — image src/alt/caption/width extraction
//    - BlockParser+Assembly.swift  — blocks → markdown, ProseMirror alignment
//

import Foundation

/// Parser that converts markdown into Block structures
enum BlockParser {

    /// Whether a markdown fragment is effectively empty (no visible content).
    /// Used to filter blocks that produce no ProseMirror node (e.g., section_break with empty fragment).
    static func isEmptyFragment(_ fragment: String) -> Bool {
        fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Parse markdown content into an array of blocks
    /// - Parameters:
    ///   - markdown: The markdown content to parse
    ///   - projectId: The project ID to assign to blocks
    ///   - existingSectionMetadata: Optional metadata from existing sections to preserve
    ///   - strippingBibliographyMarkerFromBlocks: When `true`, the bibliography-opening pre-scan
    ///     still runs against `markdown` UNSTRIPPED (so a genuine legacy
    ///     `<!-- ::auto-bibliography:: -->` marker still fires tier 1), but every PER-BLOCK
    ///     computation below — `detectBlockType`/`extractTextContent` (so `blockType`,
    ///     `headingLevel`, and `textContent`) and the stored `markdownFragment` — runs against
    ///     the marker-stripped text instead. Without stripping before classification too, a
    ///     marker-glued heading (`<!-- ::auto-bibliography:: --># Bibliography`) never matches
    ///     `detectBlockType`'s heading regex (the string starts with `<!--`) and is misclassified
    ///     as `.bibliography`/`headingLevel == nil` rather than `.heading`/`headingLevel == 1` —
    ///     see the classification site below for the full failure mode. Defaults to `false`,
    ///     which makes every existing caller bit-identical to this function's prior behavior.
    ///     The one caller that passes `true` is `ContentView+ProjectLifecycle.swift`'s
    ///     legacy-load branch: with tier 3 deleted, a legacy document — markerless AND
    ///     terminator-less on this path, since the marker used to be stripped BEFORE this call
    ///     ever saw it — would otherwise have no evidence left to select the bibliography
    ///     heading on at all. Stripping the literal out afterward (rather than before, as the
    ///     old call site did) is what lets tier 1 still see it; the end result for a
    ///     marker-glued legacy heading is that it parses EXACTLY as if the heading had no
    ///     marker glued to it at all — `.heading`, level 1, `textContent == "Bibliography"`,
    ///     marker-free `markdownFragment` — except that `isBibliography` still gets set `true`
    ///     via tier 1's marker detection.
    /// - Returns: Array of Block structures
    static func parse(
        markdown: String,
        projectId: String,
        existingSectionMetadata: [String: SectionMetadata]? = nil,
        strippingBibliographyMarkerFromBlocks: Bool = false
    ) -> [Block] {
        guard !markdown.isEmpty else { return [] }

        var blocks: [Block] = []
        var sortOrder: Double = 1.0

        // Split by double newlines (paragraph boundaries)
        // But keep code blocks and other multi-line structures together
        let rawBlocks = splitIntoRawBlocks(markdown)

        // Read once for the whole parse rather than per-block: `isBibliographyHeading`
        // defaults to loading this itself (via `ExportSettings.load()`, a UserDefaults
        // read plus a full JSONDecoder decode) for its other, single-block call sites,
        // but doing that once per raw block in the loop below is wasted work that scales
        // with document size for no benefit -- the setting can't change mid-parse.
        let bibliographyHeaderName = ExportSettings.load().effectiveBibliographyHeaderName

        // Pre-scan: select the ONE raw-block index (if any) that opens the bibliography
        // section, using the two-tier rule documented on `selectBibliographyOpeningIndex`
        // (delegated to the shared `BibliographyOpeningSelector`). Doing this as a pre-scan --
        // rather than an inline per-block `isBibliographyHeading` call below -- is what lets a
        // bare-title user heading that merely equals the bibliography header name, sitting
        // ABOVE the real machine-managed heading, be told apart from the real one: picking the
        // FIRST title match is exactly backwards for that shape of document (the user heading's
        // paragraphs would get flagged isBibliography, dropped from every export, and deleted
        // by the next regeneration).
        //
        // `bibliographyOpening.markerHeadingIndex` is a SECOND index, populated only when tier
        // 1 selected a STANDALONE marker block (the marker occupies its own raw block, glued to
        // nothing) that sits immediately before the real bibliography heading in its own,
        // separate raw block -- `<!-- ::auto-bibliography:: -->` / blank line / `# Bibliography`
        // -- a real, persisted shape (see `BlockParser+Assembly.swift`'s `assembleMarkdownForExport`
        // comment on `headingBlock`, `alignmentPairs`' marker-atom exclusion below, and
        // `BibliographyPlacementExportTests`'s coverage of it). The marker and that heading are
        // ONE opening event split across two raw blocks purely by formatting; without also
        // treating the heading's own index as `opensSection` below, `sectionFlagCarriedForward`'s
        // "any other heading closes the run" rule fires on it -- it isn't `bibliographyOpening.
        // openingIndex`, so from that rule's point of view it looks exactly like an unrelated
        // heading closing an already-open run, dropping isBibliography from the heading and
        // everything after it.
        let bibliographyOpening = selectBibliographyOpeningIndex(
            rawBlocks: rawBlocks,
            bibliographyHeaderName: bibliographyHeaderName
        )

        var inBibliographySection = false
        var inNotesSection = false

        for (index, rawBlock) in rawBlocks.enumerated() {
            let trimmed = rawBlock.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Explicit terminator: closes the bibliography section deterministically,
            // regardless of block count or position — see `bibliographyEndMarker`'s
            // doc comment. Produces ZERO Blocks (stronger than the opening marker,
            // which DOES persist as a `.bibliography`-typed Block).
            if trimmed == bibliographyEndMarker {
                inBibliographySection = false
                // Record the boundary on the block we just emitted, so `replaceBlocks`'
                // carry-forward has an inclusive upper bound (the marker itself produces no
                // Block, by design — see this constant's doc comment).
                //
                // `blocks` is empty when the terminator is the document's very first raw block
                // (a stray paste, or a document truncated above it); the plain `!blocks.isEmpty`
                // check below is what keeps that from being an out-of-bounds write on
                // `blocks[blocks.count - 1]`. Two adjacent terminators simply re-set the same
                // block's flag — idempotent.
                //
                // Deliberately flags the block that PRECEDES the marker in raw-block order, not
                // in visual order.
                if !blocks.isEmpty {
                    blocks[blocks.count - 1].endsBibliographyRun = true
                }
                continue
            }

            // When `strippingBibliographyMarkerFromBlocks` is true, block CLASSIFICATION must
            // run against the STRIPPED text, not the unstripped `trimmed` -- otherwise a
            // legacy marker-glued heading (`<!-- ::auto-bibliography:: --># Bibliography`)
            // never matches `detectBlockType`'s heading regex (the string starts with
            // `<!--`), and falls through to `listTableOrMediaType`'s bibliography-marker rule
            // instead: `.bibliography` type with `headingLevel == nil`, NOT `.heading` with
            // `headingLevel == 1` as intended. See `BlockParser+Assembly.swift`'s "a fragment
            // carrying the marker inline isn't typed `.heading` to begin with" comment -- that
            // classification rule is deliberate for the UNSTRIPPED case (every OTHER existing
            // caller, where the marker literal stays in the stored fragment), but must not
            // apply here, where the marker is about to be stripped from the stored fragment
            // anyway. Tier 1's own marker detection is unaffected: `bibliographyOpening`
            // was already computed above, from `rawBlocks`, before this loop started, so it
            // still sees the marker on the UNSTRIPPED text regardless of what happens to
            // `trimmed` here. Only per-block classification (blockType/headingLevel/
            // textContent) moves to the stripped text.
            let classificationText = strippingBibliographyMarkerFromBlocks
                ? SectionSyncService.stripBibliographyMarker(from: trimmed)
                : trimmed

            let (blockType, headingLevel) = detectBlockType(classificationText)
            let textContent = extractTextContent(from: classificationText, blockType: blockType)
            // wordCount populated below via Block.recalculateWordCount() so the
            // block-type rules (zero for code/image/HR/section break/bibliography)
            // apply uniformly. Initial value 0 is overwritten before append.

            // Both flags run until the next heading that doesn't re-open them.
            // `index == bibliographyOpening.markerHeadingIndex` is the standalone-marker
            // pairing described above -- nil (never matches) except for that one shape.
            inBibliographySection = sectionFlagCarriedForward(
                current: inBibliographySection,
                opensSection: index == bibliographyOpening.openingIndex
                    || index == bibliographyOpening.markerHeadingIndex,
                blockType: blockType
            )
            inNotesSection = sectionFlagCarriedForward(
                current: inNotesSection,
                opensSection: trimmed.lowercased() == "# notes",
                blockType: blockType
            )
            let isPseudoSection = isSectionBreakMarker(trimmed)

            // Look up existing metadata for this heading/section break if available
            let preserved = preservedMetadata(
                in: existingSectionMetadata,
                blockType: blockType,
                textContent: textContent,
                isPseudoSection: isPseudoSection,
                sortOrder: sortOrder
            )

            // Parse image metadata from markdown for image blocks
            let image = imageMetadata(for: trimmed, blockType: blockType)

            // Marker literal removed from the STORED fragment only when opted in -- see
            // `strippingBibliographyMarkerFromBlocks`'s doc comment above. This is the exact
            // same stripped-or-not text `classificationText` above already computed (blockType/
            // headingLevel/textContent are now derived from it too, per the fix described
            // there) -- reused here rather than recomputed, so the fragment that lands in the
            // DB row's `markdownFragment` can never drift from what classification just saw.
            let fragmentForBlock = classificationText

            var block = Block(
                projectId: projectId,
                sortOrder: sortOrder,
                blockType: blockType,
                textContent: textContent,
                markdownFragment: fragmentForBlock,
                headingLevel: headingLevel,
                status: preserved?.status,
                tags: preserved?.tags,
                wordGoal: preserved?.wordGoal,
                imageSrc: image.src,
                imageAlt: image.alt,
                imageCaption: image.caption,
                imageWidth: image.width,
                isBibliography: inBibliographySection,
                isNotes: inNotesSection,
                isPseudoSection: isPseudoSection
            )
            block.recalculateWordCount()

            blocks.append(block)
            sortOrder += 1.0
        }

        return blocks
    }

    // MARK: - Section Flags

    /// A "we are inside section X" flag advanced by one block: an opening heading turns it
    /// on, any *other* heading turns it off, and everything else leaves it as it was.
    ///
    /// For the bibliography flag specifically, this "carry until the next heading" rule has
    /// no way, on its own, to tell "one more bibliography entry" apart from "the user's
    /// first paragraph typed below the references, with no heading in between" — they're
    /// textually identical shapes, and the auto-generated bibliography section
    /// (`BibliographySyncService.updateBibliographyBlock`) can be followed directly by such
    /// trailing user content with no heading in between, whether the section currently sits at
    /// the end of the document or — since `updateBibliographyBlock`'s anchor-based placement —
    /// back at its own prior mid-document position, with no closing heading by construction
    /// either way. Confirmed by direct reproduction
    /// (not inferred from reading this code): calling `parse()` on "# References\n\n<entries>
    /// \n\nA trailing note with no heading after it." flagged that trailing note
    /// `isBibliography = true` — silently dropped from every export (`exportBlocks()`
    /// filters on this flag) and undeletable via the editor (`processEditorDeletes`'s safety
    /// net refuses to remove a flagged block).
    ///
    /// `parse()` closes that gap upstream of this function, via an explicit terminator: see
    /// `bibliographyEndMarker`. The terminator is written into the document's own markdown
    /// (by `BlockParser+Assembly.swift`'s `assembleMarkdownForEditor`) whenever the last
    /// real block is bibliography content, so the closing boundary travels with the text
    /// itself — no count, no per-call-site threading, no dependency on prior DB state. Two
    /// earlier approaches were tried and rejected: a position-bounded self-heal sweep (no
    /// bound could safely distinguish real orphans from real user content — see
    /// `BibliographySyncService.updateBibliographyBlock`'s doc comment) and a block-count
    /// hint threaded into this one function's `parse()` caller (missed every reparse call
    /// site except one, and could misfire under ordinary editing).
    private static func sectionFlagCarriedForward(
        current: Bool,
        opensSection: Bool,
        blockType: BlockType
    ) -> Bool {
        if opensSection { return true }
        // Reset if a non-matching heading follows (user typed below the section in CM)
        if current && blockType == .heading { return false }
        return current
    }

    /// Whether `trimmed` is the heading that opens the bibliography section.
    ///
    /// The configured header name (normally read via the @MainActor
    /// ExportSettingsManager.shared.effectiveBibliographyHeaderName, e.g. a user-set "Works
    /// Cited") must be recognized alongside the built-in References/Bibliography
    /// literals: in Source Mode the <!-- ::auto-bibliography:: --> marker is already
    /// stripped out of editorState.content before this parse ever sees it (see
    /// ContentView+ContentRebuilding.swift), so a custom header name falling through to
    /// "ordinary heading" here would silently drop isBibliography from every entry
    /// paragraph below it -- the heading itself gets re-flagged by title match in
    /// Database+BlocksReplace.swift's replaceBlocks, but the entries don't, leaving stale
    /// entries stranded as duplicate body text on the very next bibliography write.
    /// BlockParser.parse() is a nonisolated static func called from both @MainActor
    /// production call sites AND non-@MainActor test contexts (e.g.
    /// TestFixtureFactory.createFixture, called from Tier1 tests with no @MainActor
    /// annotation) -- MainActor.assumeIsolated crashed there. ExportSettings.load() is
    /// the plain, non-actor-isolated struct method the manager itself is built on (its
    /// `update()` calls `settings.save()` synchronously, so UserDefaults is always in
    /// sync with the manager's cached value): reading straight from UserDefaults here is
    /// thread-safe and avoids threading an @MainActor read through every call site.
    /// `effectiveBibliographyHeaderName` (rather than the raw stored value) trims
    /// surrounding whitespace and falls back to the shipped default when the stored name
    /// is empty or whitespace-only -- see that computed property's doc comment.
    ///
    /// `bibliographyHeaderName` defaults to a fresh `ExportSettings.load()` so this file's own
    /// test suite (which calls this directly, unqualified) is unaffected and keeps reading the
    /// live setting with no call-site change. `parse()` above is the one production caller,
    /// via the pre-scan `selectBibliographyOpeningIndex` below; it computes the header name
    /// ONCE before the loop and passes it explicitly, so a large document doesn't pay a
    /// UserDefaults read + full `ExportSettings` decode per block just to extract this one
    /// string -- the setting can't change mid-parse, so there's nothing to gain from
    /// re-reading it every iteration.
    ///
    /// Not `private`: `selectBibliographyOpeningIndex` below calls this (tier 2's candidate
    /// predicate, the bare-title match), and this file's Tier1 test suite calls it directly to exercise the
    /// bare-title/marker distinction in isolation. Database+BlocksInsert.swift's editor-diff
    /// insert path does NOT call this any more -- both of its call sites
    /// (`resolveInsertPlacement`'s containment-suppression check and `buildInsertedBlock`'s own
    /// flag) now use the narrower, marker-only `hasBibliographyMarker` instead, deliberately:
    /// that single-fragment path has no document context with which to tell the real
    /// bibliography heading apart from a user heading that merely shares its title, so it must
    /// never accept this function's broader bare-title match. See `hasBibliographyMarker`'s own
    /// doc comment for that path's full rationale.
    static func isBibliographyHeading(
        _ trimmed: String,
        bibliographyHeaderName: String = ExportSettings.load().effectiveBibliographyHeaderName
    ) -> Bool {
        if hasBibliographyMarker(trimmed) { return true }
        let titles = ["References", "Bibliography", bibliographyHeaderName]
        return titles.contains { trimmed == "# \($0)" || trimmed == "## \($0)" }
    }

    /// Marker-only bibliography-heading test: does this fragment carry the machine-managed
    /// opening marker? Distinct from `isBibliographyHeading`, which also accepts a bare title
    /// match — a test the single-fragment editor-diff insert path must NOT use, since it has
    /// no document context with which to tell the real bibliography heading from a user
    /// heading that merely shares its title. See `Database+BlocksInsert.swift`'s
    /// `resolveInsertPlacement`/`buildInsertedBlock`, the only other call sites.
    nonisolated static func hasBibliographyMarker(_ trimmed: String) -> Bool {
        trimmed.contains("<!-- ::auto-bibliography:: -->")
    }

    /// Selects the ONE raw-block index (already whitespace-trimmed by the caller into
    /// `rawBlocks`) that opens the bibliography section, or `nil` if none does. Tokenizes
    /// `rawBlocks` into `[BibliographyOpeningSelector.Unit]` using this site's own predicates
    /// and delegates the actual decision to `BibliographyOpeningSelector.select` — see that
    /// type's doc comment for the full two-tier rule, why tier 3 ("last title match anywhere,
    /// no evidence required") was deleted rather than weakened, and the disclosed consequences.
    ///
    /// This site's predicates:
    /// - `isMarker`: `hasBibliographyMarker` (`.contains`, not anchored — a marker mid-block
    ///   still counts here).
    /// - `isTerminator`: exact equality against `bibliographyEndMarker` on the trimmed block,
    ///   never `.contains` — glued/doubled-marker blocks exist that contain but never equal the
    ///   literal; see `BlockParser+Splitting.swift`'s `consumeBibliographyEndMarkerGlue`.
    /// - `isCandidate`: `isBibliographyHeading` (the three-title bare-title match).
    /// - `isHeading`: whatever `detectBlockType` classifies as `.heading`.
    /// - `isEmpty`: the trimmed block's own emptiness.
    ///
    /// Why a pre-scan rather than resolving this inline, per block, in `parse()`'s main loop:
    /// an inline `isBibliographyHeading` call opens the section at the FIRST title match it
    /// encounters, which is exactly backwards for a document containing a user heading that
    /// merely equals the bibliography header name (e.g. a chapter titled "Bibliography") ABOVE
    /// the real, machine-managed heading.
    ///
    /// - Returns: `openingIndex` — the tier-1/tier-2 winner (`nil` if nothing was selected), and
    ///   `markerHeadingIndex` — a second index, populated only when `openingIndex` is a
    ///   STANDALONE marker block (see `standaloneMarkerHeadingIndex` below) immediately
    ///   followed by its own real heading in the next raw block. `nil` for the glued marker
    ///   shape (one raw block already carries both, so there is no separate heading block to
    ///   pair it with) and for tier 2 (the candidate index already IS the heading).
    private static func selectBibliographyOpeningIndex(
        rawBlocks: [String],
        bibliographyHeaderName: String
    ) -> (openingIndex: Int?, markerHeadingIndex: Int?) {
        let trimmedBlocks = rawBlocks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        let units = trimmedBlocks.map { trimmed in
            BibliographyOpeningSelector.Unit(
                isMarker: hasBibliographyMarker(trimmed),
                isTerminator: trimmed == bibliographyEndMarker,
                // Excludes the bare marker literal specifically: `isBibliographyHeading` returns
                // true for anything CONTAINING the marker (it checks `hasBibliographyMarker`
                // first, before its title-match logic), so a standalone orphan marker block
                // would otherwise satisfy `isCandidate` too -- making it eligible to win tier 2's
                // "last candidate before the terminator" scan even after tier 1 correctly judged
                // it unsupported (see `BibliographyOpeningSelector.markerIsSupported`), and
                // making a standalone orphan look like a valid "next unit" pairing for an EARLIER
                // standalone marker in a stacked-orphan shape. A standalone-marker unit must
                // never count as a title candidate; the glued shape
                // (`<!-- ::auto-bibliography:: --># Bibliography`, one block) is unaffected --
                // its trimmed content is never equal to the bare marker literal, so it keeps
                // matching via `isBibliographyHeading`'s marker check exactly as before.
                isCandidate: trimmed != bibliographyStartMarker
                    && isBibliographyHeading(trimmed, bibliographyHeaderName: bibliographyHeaderName),
                isHeading: detectBlockType(trimmed).0 == .heading,
                isEmpty: trimmed.isEmpty,
                isStandaloneMarker: trimmed == bibliographyStartMarker
            )
        }

        switch BibliographyOpeningSelector.select(units) {
        case .marker(let index):
            return (
                index,
                standaloneMarkerHeadingIndex(
                    trimmedBlocks: trimmedBlocks,
                    markerIndex: index,
                    bibliographyHeaderName: bibliographyHeaderName
                )
            )
        case .candidate(let index):
            return (index, nil)
        case .none:
            return (nil, nil)
        }
    }

    /// When the marker at `markerIndex` occupies its own raw block with nothing else in it —
    /// i.e. `trimmedBlocks[markerIndex]` IS the marker literal, not the marker glued to a
    /// heading or to any other text — AND the very next raw block is itself a genuine
    /// bibliography-title candidate (`isBibliographyHeading`, the same three-title bare-title
    /// match tier 2 uses), returns that next index: the marker and this heading are ONE
    /// opening event, split across two raw blocks only because of how the marker happens to
    /// be formatted in this persisted shape (`<!-- ::auto-bibliography:: -->` / blank line /
    /// `# Bibliography`).
    ///
    /// Requiring the next block to be a matching CANDIDATE, not merely `.heading`-typed, is
    /// deliberate: the marker's own generator always writes a heading whose text matches the
    /// configured name, so a real standalone-marker document always satisfies this. A
    /// standalone marker followed by some OTHER, non-matching heading is a synthetic edge case
    /// with no document-context evidence that the two belong together — pairing them anyway
    /// used to also open the section on that non-matching heading's OWN block, silently
    /// overriding `sectionFlagCarriedForward`'s pre-existing "any other heading closes the run"
    /// rule (see `BibliographyCarryForwardRegressionTests.recognisedHeadingNeedsNoCarry`, the
    /// regression this guard restores). Leaving such a heading unpaired lets that pre-existing
    /// rule fire on it exactly as it did before this pairing existed: the heading closes the
    /// section on itself, and nothing after it is flagged either.
    ///
    /// Returns `nil` for:
    /// - The glued shape (`<!-- ::auto-bibliography:: --># Bibliography`, one raw block): the
    ///   marker's own trimmed block already contains the heading text, so it never equals the
    ///   bare marker literal, and there is no separate raw block to pair it with anyway — that
    ///   single block is already `opensSection` on its own via `openingIndex`.
    /// - A standalone marker with no heading immediately after it (e.g. the marker sits
    ///   directly above ordinary entries, or is the document's last block) — nothing to pair.
    /// - A standalone marker immediately followed by unrelated non-heading text.
    /// - A standalone marker immediately followed by a heading that does NOT match a
    ///   recognized bibliography title — see the candidacy note above.
    private static func standaloneMarkerHeadingIndex(
        trimmedBlocks: [String],
        markerIndex: Int,
        bibliographyHeaderName: String
    ) -> Int? {
        guard trimmedBlocks[markerIndex] == "<!-- ::auto-bibliography:: -->" else { return nil }
        let nextIndex = markerIndex + 1
        guard trimmedBlocks.indices.contains(nextIndex) else { return nil }
        let nextBlock = trimmedBlocks[nextIndex]
        guard detectBlockType(nextBlock).0 == .heading else { return nil }
        guard isBibliographyHeading(nextBlock, bibliographyHeaderName: bibliographyHeaderName) else { return nil }
        return nextIndex
    }

    /// Section metadata to carry over from an existing section, matched by heading title
    /// or — for section breaks, which have no title — by sort position.
    private static func preservedMetadata(
        in existing: [String: SectionMetadata]?,
        blockType: BlockType,
        textContent: String,
        isPseudoSection: Bool,
        sortOrder: Double
    ) -> SectionMetadata? {
        guard let existing else { return nil }

        var match: SectionMetadata?
        // Try to match by title
        if blockType == .heading {
            match = existing[textContent] ?? match
        }
        // Section breaks inherit status from section metadata under a special key
        if isPseudoSection {
            match = existing["__break__\(Int(sortOrder))"] ?? match
        }
        return match
    }

    // MARK: - Block Type Detection

    /// Detect the block type from content
    static func detectBlockType(_ content: String) -> (BlockType, Int?) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Heading: starts with # (1-6) — the only type carrying a level
        if let match = trimmed.range(of: "^(#{1,6})\\s+", options: .regularExpression) {
            let hashes = trimmed[match].filter { $0 == "#" }
            return (.heading, hashes.count)
        }

        return (fencedOrQuotedType(trimmed) ?? listTableOrMediaType(trimmed), nil)
    }

    /// Fence-, rule- and quote-style types, or nil if `trimmed` is none of them.
    /// ORDER IS LOAD-BEARING: `$$` and ``` must be tested before the `---` horizontal-rule
    /// pattern, and the section-break comment before the `>` blockquote prefix.
    private static func fencedOrQuotedType(_ trimmed: String) -> BlockType? {
        // Display math block: starts with $$ (either $$...$$ on one line or multi-line).
        // Checked against the block's FIRST LINE only, via the exact same opener
        // predicate `RawBlockSplitter.consumeDisplayMath` (BlockParser+Splitting.swift)
        // used to bound this block in the first place — see `mathDisplayFenceLineRole`.
        // Sharing the predicate means this classifier and the splitter that already
        // produced the block can never disagree about what counts as "math" the way
        // they once did: a naive `trimmed.hasPrefix("$$")` here used to relabel a block
        // the splitter correctly left as an ordinary paragraph (e.g.
        // "$$E = mc^2$$ is the famous equation." — a legitimate embedded closing `$$`
        // followed by trailing prose, never a genuine fence opener) as `.mathDisplay`
        // just because its content happened to start with `$$`.
        let firstLine = trimmed.components(separatedBy: "\n").first ?? trimmed
        if mathDisplayFenceLineRole(firstLine.trimmingCharacters(in: .whitespaces)).isOpener {
            return .mathDisplay
        }
        // Code block: starts with ```
        if trimmed.hasPrefix("```") { return .codeBlock }
        // Horizontal rule: ---, ***, ___
        if trimmed.range(of: "^[-*_]{3,}$", options: .regularExpression) != nil { return .horizontalRule }
        // Section break: <!-- ::break:: -->
        if isSectionBreakMarker(trimmed) { return .sectionBreak }
        // Blockquote: starts with >
        if trimmed.hasPrefix(">") { return .blockquote }
        return nil
    }

    /// Classifies a single already-whitespace-trimmed line's role in a display-math
    /// `$$` fence, matching micromark's own math-flow "meta" bail rule exactly: a
    /// fence only opens when there is NO other `$` anywhere after the leading `$$` —
    /// not merely "doesn't end with $$". Shared by `RawBlockSplitter.consumeDisplayMath`
    /// (BlockParser+Splitting.swift, which uses `isOpener`/`isSingleLineMath` to decide
    /// whether and how a fence opens while splitting) and `fencedOrQuotedType` above
    /// (which uses `isOpener` to classify an already-split block's type) — factored out
    /// as the single source of truth so the two can never disagree, which is exactly
    /// how the two-classifier bug this fixes was possible: `fencedOrQuotedType` used to
    /// run its own, more permissive `hasPrefix("$$")` check independent of this one.
    static func mathDisplayFenceLineRole(_ trimmedLine: String) -> (isOpener: Bool, isSingleLineMath: Bool) {
        let hasOpenPrefix = trimmedLine.hasPrefix("$$")
        let hasCloseSuffix = trimmedLine.hasSuffix("$$")
        let isSingleLineMath = hasOpenPrefix && hasCloseSuffix && trimmedLine.count > 4
        let remainderAfterOpenPrefix = hasOpenPrefix ? String(trimmedLine.dropFirst(2)) : ""
        let opensGluedOnly = hasOpenPrefix && !remainderAfterOpenPrefix.contains("$")
        let isOpener = trimmedLine == "$$" || isSingleLineMath || opensGluedOnly
        return (isOpener, isSingleLineMath)
    }

    /// The exact literal `RawBlockSplitter` (BlockParser+Splitting.swift) and
    /// `isSectionBreakMarker` both compare against. Deliberately EXACT spacing —
    /// no whitespace tolerance — so the splitter's flush guard and this
    /// classifier can never disagree about what counts as "the marker line".
    /// (A separate, more permissive whitespace-tolerant regex exists in
    /// MarkdownUtils.swift for a different purpose — stripping the marker out
    /// of already-composed display text — and must stay separate; see that
    /// call site's comment.)
    static let sectionBreakMarker = "<!-- ::break:: -->"

    /// Explicit, invisible terminator marking the end of the auto-generated bibliography
    /// section. Written into `editorState.content` by `BlockParser+Assembly.swift`'s
    /// `assembleMarkdownForEditor` whenever the last real block is bibliography content, so
    /// every subsequent full reparse (Source Mode's debounced re-parse, and critically the
    /// reparse that runs immediately before every PDF export) has a deterministic,
    /// position-independent signal that the section has ended — see
    /// `sectionFlagCarriedForward`'s doc comment for the bug this closes and the two
    /// rejected approaches that preceded it.
    ///
    /// The `-end` sits BEFORE the closing `::` (`...-end:: -->`, not `...:: -end -->`)
    /// deliberately: `isBibliographyHeading` checks `trimmed.contains("<!-- ::auto-
    /// bibliography:: -->")` and `listTableOrMediaType` checks the same substring, so a
    /// terminator spelled `...:: -end -->` would still contain the opening marker's exact
    /// text and get misclassified as opening (or re-opening) the section it's meant to
    /// close. Spelling the suffix inside the marker's own `::...::` delimiters instead means
    /// neither check's substring can ever match this string. See
    /// `isBibliographyHeading(bibliographyEndMarker) == false` in
    /// BibliographyTerminatorTests.swift for the regression guard.
    static let bibliographyEndMarker = "<!-- ::auto-bibliography-end:: -->"

    /// The literal opening marker itself, as its own named constant — previously only ever
    /// spelled out inline at each call site (`hasBibliographyMarker`'s `.contains` check,
    /// `standaloneMarkerHeadingIndex`'s exact-equality check, and the equivalent checks in
    /// `SectionSyncService+Parsing.swift`/`SectionSyncService+Anchors.swift`). Introduced for
    /// `BibliographyOpeningSelector.Unit.isStandaloneMarker`'s three call sites, which all need
    /// the SAME "is this unit's content the bare marker literal and nothing else" test — see
    /// that field's doc comment. Not a repo-wide literal sweep: existing inline literals
    /// elsewhere are left as-is, out of scope for this fix.
    static let bibliographyStartMarker = "<!-- ::auto-bibliography:: -->"

    /// Pandoc's `--citeproc` generated-bibliography placement marker (the `::: {#refs}\n:::`
    /// fenced-div shorthand for `<div id="refs">...</div>`). Emitted by
    /// `assembleMarkdownForExport(from:bibliographyPlaceholder:)` in place of the document's
    /// bibliography section, at the position that section occupied, so pandoc's citeproc
    /// filter inserts its freshly-generated bibliography there instead of appending it to the
    /// very end of the document — the fix for text typed after the bibliography rendering
    /// BEFORE it in PDF/print output. See that function's doc comment for the full mechanism.
    static let bibliographyPlacementMarker = "::: {#refs}\n:::"

    /// Whether `trimmed` (an already-whitespace-trimmed raw block string) IS a
    /// section-break marker: either the marker alone, or the marker as the
    /// block's FIRST LINE with body content on the line(s) after it.
    ///
    /// Why first-line, not whole-string equality: this predicate is shared by
    /// two different call sites with two different input shapes.
    ///
    /// On the `parse()` path (BlockParser.swift's `parse()`/`detectBlockType()`),
    /// `RawBlockSplitter` (BlockParser+Splitting.swift) now ALSO flushes the
    /// marker as its own block the moment it sees the marker line sitting alone
    /// in `currentBlock`, before appending whatever content line comes next —
    /// so `<!-- ::break:: -->\nBody text` (no blank line) splits into TWO raw
    /// blocks there, and this predicate only ever sees the marker by itself on
    /// that path. (It used to reach here as one combined string; the fix for
    /// the "combined block's text gets wiped to empty" bug moved that split
    /// earlier, into the splitter, rather than patching it after the fact here.)
    ///
    /// On the separate editor-sync path (`Database+Blocks.swift`'s
    /// `applyDetectedTypeFromContent`, NOT touched by that fix), `trimmed` is a
    /// single already-existing ProseMirror block's own serialized markdown
    /// fragment being checked for an in-place paragraph → section-break
    /// conversion. That fragment can genuinely be marker-plus-body as ONE
    /// string — it isn't multi-block raw markdown running through
    /// `RawBlockSplitter` at all, so the splitter's new guard never sees it,
    /// and first-line matching (not whole-string equality) is still needed
    /// there to classify it correctly.
    ///
    /// Why not a substring/`.contains` check either: that was this fix's
    /// original bug — a marker appearing mid-sentence inside unrelated prose
    /// (e.g. "...text <!-- ::break:: --> more text...") must NOT match, since
    /// it isn't a section break at all. Anchoring to the first line rejects
    /// that case (the marker isn't at the very start) while still accepting
    /// the marker followed by its own body content on subsequent lines.
    ///
    /// The marker's own line is trimmed of surrounding whitespace before the
    /// comparison, so straggling whitespace around it (e.g.
    /// `"<!-- ::break:: --> \nBody"`, one trailing space before the newline)
    /// still counts as the marker. This isn't a hypothetical: it's only
    /// reachable via Source-Mode hand-editing or pasting text shaped that
    /// way (the app's own slash-command marker insertion never produces it),
    /// but when it IS reached, this must agree with
    /// `SectionReconciler.strippingLeadingBreakMarker`, which trims the same
    /// way — otherwise the two would classify the identical shape
    /// differently and silently disagree on whether it's a section break.
    static func isSectionBreakMarker(_ trimmed: String) -> Bool {
        guard let newline = trimmed.firstIndex(of: "\n") else {
            return trimmed.trimmingCharacters(in: .whitespaces) == sectionBreakMarker
        }
        return trimmed[trimmed.startIndex..<newline]
            .trimmingCharacters(in: .whitespaces) == sectionBreakMarker
    }

    /// List, table, image and bibliography types, falling back to `.paragraph`.
    /// Only reached when `fencedOrQuotedType` found no match.
    private static func listTableOrMediaType(_ trimmed: String) -> BlockType {
        // Bullet list: starts with - * +
        if trimmed.range(of: "^\\s*[-*+]\\s+", options: .regularExpression) != nil { return .bulletList }
        // Ordered list: starts with 1. 2. etc
        if trimmed.range(of: "^\\s*\\d+\\.\\s+", options: .regularExpression) != nil { return .orderedList }
        // Table: starts with |
        if trimmed.hasPrefix("|") { return .table }
        // Caption + Image: <!-- caption: text -->\n...\n![alt](url)
        if trimmed.hasPrefix("<!--"), trimmed.contains("caption:"),
           trimmed.range(of: "!\\[", options: .regularExpression) != nil { return .image }
        // Image: ![alt](url)
        if trimmed.range(of: "^!\\[", options: .regularExpression) != nil { return .image }
        // Bibliography marker
        if trimmed.contains("<!-- ::auto-bibliography:: -->") { return .bibliography }
        // Default: paragraph
        return .paragraph
    }

    /// Whether `trimmedLine` looks like the start of a bullet ("-"/"*"/"+ ") or
    /// ordered ("1. ") list item, and which kind. Returns nil for anything else.
    /// Single-line check — used to detect a list "interrupting" non-list
    /// content with no blank line in between (see the call site in
    /// `RawBlockSplitter.consumeContentLine` for why this matters).
    static func listMarkerKind(_ trimmedLine: String) -> BlockType? {
        if trimmedLine.range(of: "^[-*+]\\s+", options: .regularExpression) != nil {
            return .bulletList
        }
        if trimmedLine.range(of: "^\\d+\\.\\s+", options: .regularExpression) != nil {
            return .orderedList
        }
        return nil
    }

    // MARK: - Text Extraction

    /// Extract plain text content from markdown block
    static func extractTextContent(from content: String, blockType: BlockType) -> String {
        var text = content

        switch blockType {
        case .heading:
            // Remove # markers
            if let range = text.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                text.removeSubrange(range)
            }

        case .blockquote:
            text = strippingBlockquoteMarkers(text)

        case .bulletList, .orderedList:
            text = strippingListMarkers(text)

        case .codeBlock:
            text = codeInsideFences(text)

        case .sectionBreak, .horizontalRule:
            text = ""

        default:
            break
        }

        text = strippingFootnoteDefinitionPrefixes(text)

        // Strip remaining markdown syntax. Headings and code blocks can
        // never actually BE a markdown list, so text in either of those
        // block types that literally starts with "3. " (typed, pasted, or
        // a numbered step inside a code sample) must not have that prefix
        // mistaken for an ordered-list marker and stripped. Blockquotes are
        // different: "> 1. First item" is a completely normal markdown
        // shape — an ordered list nested inside a blockquote — so this
        // regex genuinely can't tell a quoted list from quoted text that
        // merely looks like one. Preserving the literal text is still the
        // safer default for blockquotes: it keeps textContent (search)
        // matching what was actually typed instead of guessing. See
        // MarkdownUtils.stripMarkdownSyntax's `stripListMarkers` doc
        // comment.
        let blockTypeCannotBeAList = blockType == .heading || blockType == .codeBlock || blockType == .blockquote
        text = MarkdownUtils.stripMarkdownSyntax(from: text, stripListMarkers: !blockTypeCannotBeAList)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes every leading `>` marker (and the space after it) from each line.
    private static func strippingBlockquoteMarkers(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { line in
                var l = line
                while l.hasPrefix(">") {
                    l.removeFirst()
                    l = l.trimmingCharacters(in: .init(charactersIn: " "))
                }
                return l
            }
            .joined(separator: "\n")
    }

    /// Removes the leading bullet or ordinal marker from each line.
    private static func strippingListMarkers(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { line in
                var l = line.trimmingCharacters(in: .whitespaces)
                if let range = l.range(of: "^[-*+]\\s+|^\\d+\\.\\s+", options: .regularExpression) {
                    l.removeSubrange(range)
                }
                return l
            }
            .joined(separator: "\n")
    }

    /// Keeps only the lines between ``` fences, dropping the fence markers themselves.
    private static func codeInsideFences(_ text: String) -> String {
        var inFence = false
        var codeLines: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence {
                codeLines.append(line)
            }
        }
        return codeLines.joined(separator: "\n")
    }

    /// Strips footnote definition prefixes: `[^N]:` at line start.
    private static func strippingFootnoteDefinitionPrefixes(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"^\[\^\d+\]:\s*"#, options: .anchorsMatchLines
        ) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }
}

// MARK: - Section Metadata for Migration

/// Metadata from existing sections to preserve during migration
struct SectionMetadata {
    let status: SectionStatus?
    let tags: [String]?
    let wordGoal: Int?

    init(status: SectionStatus? = nil, tags: [String]? = nil, wordGoal: Int? = nil) {
        self.status = status
        self.tags = tags
        self.wordGoal = wordGoal
    }

    init(from section: Section) {
        self.status = section.status
        self.tags = section.tags.isEmpty ? nil : section.tags
        self.wordGoal = section.wordGoal
    }
}
