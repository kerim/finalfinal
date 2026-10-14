//
//  BlockParser.swift
//  final final
//
//  Parses markdown content into Block structures.
//  Splits by double newlines and detects block types from content.
//
//  Companion files:
//    - BlockParser+Splitting.swift      — markdown → raw block strings
//    - BlockParser+Images.swift         — image src/alt/caption/width extraction
//    - BlockParser+Assembly.swift       — blocks → markdown, ProseMirror alignment
//    - BlockParser+Classification.swift — block-type detection, plain-text extraction
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
    ///   - bibliographyHeaderName: Explicit override for the configured bibliography heading
    ///     name, bypassing `ExportSettings.load()` entirely for this value when supplied
    ///     together with `graceNames` (both must be non-nil to skip the load -- see below).
    ///     Defaults to `nil`, which makes every existing caller bit-identical to this
    ///     function's prior behavior (always reading `ExportSettings.load()`). Exists so a
    ///     caller that already has the settings in hand -- notably a test isolating itself
    ///     from the process-wide `ExportSettings.userDefaults` static (see
    ///     `BibliographyRenameGraceNameTests.swift`'s doc comment on the cross-suite race
    ///     over that static) -- can drive a real parse without ever touching the global.
    ///   - graceNames: Explicit override for the grace list (see `isBibliographyHeading`'s
    ///     `graceNames` parameter doc comment); same override contract as
    ///     `bibliographyHeaderName` above -- both must be supplied together to skip the load.
    ///   - notesHeaderName: C2/C4 -- the currently-recognized Notes heading title, normally
    ///     `Database+Blocks.swift`'s `fetchNotesHeadingTitle(projectId:)` (the DB-authoritative
    ///     title of whatever heading is ALREADY flagged `isNotes`, if any), falling back to the
    ///     literal `"Notes"` when `nil` (no Notes section recognized yet, or the caller has no DB
    ///     handle -- e.g. this file's own unqualified Tier1 test-suite callers). Unlike
    ///     `bibliographyHeaderName`, there is no settings-driven configured name and no grace
    ///     list to join it with -- Notes has no rename UI (see `NotesOpeningSelector`'s doc
    ///     comment and bt t-412c9fab) -- so this is a single, optional string, not a
    ///     both-or-neither pair. Threaded into the H1-or-H2, evidence-gated pre-scan
    ///     (`selectNotesOpeningIndices`, delegating to the shared `NotesOpeningSelector`) that
    ///     replaces the old exact-H1-literal-only `# notes` check below.
    /// - Returns: Array of Block structures
    static func parse(
        markdown: String,
        projectId: String,
        existingSectionMetadata: [String: SectionMetadata]? = nil,
        strippingBibliographyMarkerFromBlocks: Bool = false,
        bibliographyHeaderName explicitBibliographyHeaderName: String? = nil,
        graceNames explicitGraceNames: [String]? = nil,
        notesHeaderName explicitNotesHeaderName: String? = nil
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
        // with document size for no benefit -- the setting can't change mid-parse. One
        // `ExportSettings.load()` call supplies both `bibliographyHeaderName` AND
        // `graceNames` below -- the grace list (`previousBibliographyHeaderNames`, names
        // this document set has used before a rename) gets the exact same once-per-parse
        // hoist treatment for the exact same reason: without it, a document whose heading
        // text still reads an OLDER configured name would need a per-block re-check against
        // the full grace list, undoing the point of hoisting `bibliographyHeaderName` at
        // all. See `isBibliographyHeading`'s `graceNames` parameter doc comment.
        //
        // When BOTH `explicitBibliographyHeaderName` and `explicitGraceNames` are supplied,
        // `ExportSettings.load()` is never called at all -- not just superseded by the
        // explicit values, genuinely skipped -- so a caller that passes both is fully
        // immune to whatever the process-wide `ExportSettings.userDefaults` static currently
        // points at. Falling back to a load when only one of the two is supplied keeps that
        // one-call-per-parse invariant for the common (both-nil) case while still letting a
        // caller override just one value if it ever needs to.
        let bibliographyHeaderName: String
        let bibliographyGraceNames: [String]
        if let explicitBibliographyHeaderName, let explicitGraceNames {
            bibliographyHeaderName = explicitBibliographyHeaderName
            bibliographyGraceNames = explicitGraceNames
        } else {
            let derived = bibliographyNames(from: ExportSettings.load())
            bibliographyHeaderName = explicitBibliographyHeaderName ?? derived.headerName
            bibliographyGraceNames = explicitGraceNames ?? derived.graceNames
        }

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
            bibliographyHeaderName: bibliographyHeaderName,
            graceNames: bibliographyGraceNames
        )

        // C4: pre-scan every raw-block index that opens a Notes run, via the shared
        // `NotesOpeningSelector` (H1-or-H2 title match + real `[^N]:` evidence beneath,
        // no marker/terminator -- see that type's doc comment for the full rule and why
        // it deliberately returns every confirmed opening rather than one winner).
        // Replaces the old inline `trimmed.lowercased() == "# notes"` exact-H1-literal
        // check, which is why this widens recognition from "exact H1 only" to
        // "H1 or H2, with evidence" -- the actual point of Stage C.
        let notesHeaderName = explicitNotesHeaderName ?? "Notes"
        let notesOpeningIndices = selectNotesOpeningIndices(
            rawBlocks: rawBlocks,
            notesHeaderName: notesHeaderName
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
                opensSection: notesOpeningIndices.contains(index),
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
    ///
    /// `graceNames` — heading names this document set has used before (see
    /// `ExportSettings.previousBibliographyHeaderNames`'s doc comment) — join the two
    /// built-ins and the current name in the title-match list below. Without them, renaming
    /// the configured header name makes every document whose heading text still reads the
    /// OLD name unrecognizable on its next re-parse: `isBibliography` drops off the heading
    /// and every entry beneath it, and the next regeneration appends a duplicate
    /// bibliography beside the now-orphaned one. Defaults to a fresh `ExportSettings.load()`
    /// for the same reason `bibliographyHeaderName` does — this file's own test suite calls
    /// this directly, unqualified — but `parse()`'s pre-scan passes both explicitly, hoisted
    /// once before its loop; see that hoist's comment for why a per-block call here is
    /// exactly the cost that hoist exists to avoid.
    ///
    /// Must-fix (judge round): `bibliographyHeaderName`/`graceNames` used to each default via
    /// their OWN independent `ExportSettings.load()` call -- Swift evaluates default-argument
    /// expressions separately per parameter, so a call landing exactly between two default
    /// evaluations (racing a `setBibliographyHeaderName` commit) could observe the NEW name
    /// paired with the PRE-rename grace list, plus doubling the UserDefaults-read+decode cost
    /// for every unqualified call site. Both now default to `nil` and share exactly ONE
    /// `ExportSettings.load()` snapshot below when either is omitted -- the same
    /// explicit-both-or-fallback-to-one-load shape `parse()`'s own hoist already uses.
    static func isBibliographyHeading(
        _ trimmed: String,
        bibliographyHeaderName: String? = nil,
        graceNames: [String]? = nil
    ) -> Bool {
        if hasBibliographyMarker(trimmed) { return true }
        let effectiveHeaderName: String
        let effectiveGraceNames: [String]
        if let bibliographyHeaderName, let graceNames {
            effectiveHeaderName = bibliographyHeaderName
            effectiveGraceNames = graceNames
        } else {
            let derived = bibliographyNames(from: ExportSettings.load())
            effectiveHeaderName = bibliographyHeaderName ?? derived.headerName
            effectiveGraceNames = graceNames ?? derived.graceNames
        }
        let titles = ["References", "Bibliography", effectiveHeaderName] + effectiveGraceNames
        return titles.contains { trimmed == "# \($0)" || trimmed == "## \($0)" }
    }

    /// Derives the effective bibliography header name and grace-name list from an already-loaded
    /// `ExportSettings` value -- the exact pair `parse`'s once-per-parse hoist and
    /// `isBibliographyHeading`'s own default-argument fallback each need from a fresh
    /// `ExportSettings.load()`, in one place instead of inlined separately at both call sites.
    /// Trivial today (`effectiveBibliographyHeaderName` already trims/defaults;
    /// `previousBibliographyHeaderNames` is returned as-is), but existing purely so the two
    /// fallback sites above can call one shared derivation rather than duplicate it -- keeping
    /// them identical by construction rather than by two authors independently getting it
    /// right. Not `private`: this file's own Tier1 test suite
    /// (`BlockParserBibliographyHeaderNameTests`) calls it directly to exercise the derivation
    /// in isolation, without touching `ExportSettings.load()`/`UserDefaults` at all.
    static func bibliographyNames(from settings: ExportSettings) -> (headerName: String, graceNames: [String]) {
        (settings.effectiveBibliographyHeaderName, settings.previousBibliographyHeaderNames)
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
        bibliographyHeaderName: String,
        graceNames: [String]
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
                    && isBibliographyHeading(
                        trimmed, bibliographyHeaderName: bibliographyHeaderName, graceNames: graceNames
                    ),
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
                    bibliographyHeaderName: bibliographyHeaderName,
                    graceNames: graceNames
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
        bibliographyHeaderName: String,
        graceNames: [String]
    ) -> Int? {
        guard trimmedBlocks[markerIndex] == "<!-- ::auto-bibliography:: -->" else { return nil }
        let nextIndex = markerIndex + 1
        guard trimmedBlocks.indices.contains(nextIndex) else { return nil }
        let nextBlock = trimmedBlocks[nextIndex]
        guard detectBlockType(nextBlock).0 == .heading else { return nil }
        guard isBibliographyHeading(
            nextBlock, bibliographyHeaderName: bibliographyHeaderName, graceNames: graceNames
        ) else { return nil }
        return nextIndex
    }

    /// Whether `trimmed` is a heading (level 1 or 2 only, mirroring `isBibliographyHeading`'s
    /// own H1-or-H2 acceptance) whose title matches `notesHeaderName` case-insensitively.
    /// Title match ALONE is not evidence a real Notes section opens here -- see
    /// `NotesOpeningSelector`'s doc comment; this is only the CANDIDATE half of that shared
    /// rule's two conditions, mirroring `isBibliographyHeading`'s own role as tier 2's
    /// candidate predicate for `BibliographyOpeningSelector`. Not `private`: this file's own
    /// Tier1 test suite exercises it directly.
    static func isNotesHeading(_ trimmed: String, notesHeaderName: String = "Notes") -> Bool {
        let lowered = trimmed.lowercased()
        let name = notesHeaderName.lowercased()
        return lowered == "# \(name)" || lowered == "## \(name)"
    }

    /// Selects every raw-block index that opens a confirmed Notes run, delegating to the
    /// shared `NotesOpeningSelector.select` -- see that type's doc comment for the full rule
    /// (H1-or-H2 title match + `[^N]:` evidence beneath, no marker/terminator, multiple runs
    /// supported).
    ///
    /// This site's predicates:
    /// - `isCandidateHeading`: `isNotesHeading` above.
    /// - `isAnyHeading`: whatever `detectBlockType` classifies as `.heading` (any level).
    /// - `isEvidence`: `FootnoteSyncService.parseNotesLabel` finds a genuine `[^N]:`
    ///   definition line inside this raw block -- the same regex-anchored parse every other
    ///   Notes-evidence check in the codebase already shares (`confirmNotesCandidates`,
    ///   `notesOwnershipMap`, `reconcileNotesBlocks`).
    private static func selectNotesOpeningIndices(
        rawBlocks: [String],
        notesHeaderName: String
    ) -> Set<Int> {
        let trimmedBlocks = rawBlocks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let units = trimmedBlocks.map { trimmed in
            NotesOpeningSelector.Unit(
                isCandidateHeading: isNotesHeading(trimmed, notesHeaderName: notesHeaderName),
                isAnyHeading: detectBlockType(trimmed).0 == .heading,
                isEvidence: FootnoteSyncService.parseNotesLabel(from: trimmed) != nil
            )
        }
        return Set(NotesOpeningSelector.select(units))
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

    // detectBlockType(_:), fencedOrQuotedType(_:), mathDisplayFenceLineRole(_:),
    // sectionBreakMarker/bibliographyEndMarker/bibliographyStartMarker/
    // bibliographyPlacementMarker, isSectionBreakMarker(_:), listTableOrMediaType(_:),
    // listMarkerKind(_:), extractTextContent(from:blockType:), and its stripping helpers --
    // block-type detection and plain-text extraction -- live in
    // BlockParser+Classification.swift, moved there to keep this enum's body under
    // SwiftLint's type_body_length limit.
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
