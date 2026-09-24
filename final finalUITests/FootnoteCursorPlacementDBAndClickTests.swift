//
//  FootnoteCursorPlacementDBAndClickTests.swift
//  final finalUITests
//
//  Split out of FootnoteCursorPlacementE2ETests.swift to keep that file under SwiftLint's
//  file_length limit -- see the header comment there for the full footnote-cursor-placement
//  background. This file holds the DB ground-truth query helpers (safe to run while the app is
//  open -- WAL mode, see FixtureDatabase's own doc comment in UITestHelpers.swift) and the fix
//  round (M3) definition-click-to-reference helpers the tests in FootnoteCursorPlacementE2ETests
//  .swift drive through.
//

import XCTest

extension FootnoteCursorPlacementE2ETests {

    // MARK: - DB ground-truth queries (safe to run while the app is open -- WAL mode, see
    // `FixtureDatabase`'s own doc comment in UITestHelpers.swift).

    func notesHeadingCount() -> Int {
        let sql = "SELECT count(*) FROM block WHERE isNotes = 1 AND blockType = 'heading';"
        let stdout = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
        return Int(stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    /// The `headingLevel` of the (first, by `sortOrder`) `isNotes` heading row, or `nil` if none
    /// exists. `editorContainsText("# Notes")` / `"## Notes"` is a CONTAINS scan -- `"## Notes"`
    /// contains `"# Notes"` as a substring, so a text-presence check alone can never actually
    /// discriminate which level is present. This queries the real level directly from the DB.
    func notesHeadingLevel() -> Int? {
        let sql = "SELECT headingLevel FROM block WHERE isNotes = 1 AND blockType = 'heading' ORDER BY sortOrder LIMIT 1;"
        let stdout = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(stdout)
    }

    /// Count of `isNotes` paragraph rows (footnote definitions). Used by
    /// `insertFootnoteAndWaitForLanding` as the footnote-insertion landing signal -- see that
    /// method's doc comment for why the status-bar word count can never serve this purpose.
    func notesDefinitionCount() -> Int {
        let sql = "SELECT count(*) FROM block WHERE isNotes = 1 AND blockType = 'paragraph';"
        let stdout = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
        return Int(stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    /// True when every `isNotes` row's sortOrder is greater than every non-`isNotes` row's
    /// sortOrder -- i.e. the Notes run sits at the true end of the document. Used by scenario 4
    /// to confirm settled decision 1 (an adopted mid-document run is relocated, not left in place).
    func notesRunIsAfterEveryOtherBlock() -> Bool {
        let sql = "SELECT (SELECT MIN(sortOrder) FROM block WHERE isNotes = 1) > " +
            "(SELECT COALESCE(MAX(sortOrder), -1) FROM block WHERE isNotes = 0);"
        let stdout = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stdout == "1"
    }

    /// Finds the (markdownFragment, textContent) of the `isNotes` paragraph block whose
    /// `markdownFragment` CONTAINS `substring` -- used to locate a definition by a unique
    /// phrase in its own text, never by its current `[^N]:` label (labels renumber; see
    /// e2e-verify's "Footnote labels are NOT stable identifiers" gotcha).
    func notesParagraphFragment(containing substring: String) -> (markdownFragment: String, textContent: String)? {
        let sep = "###FF_E2E_FIELD_SEP###"
        let sql = "SELECT markdownFragment || '\(sep)' || textContent FROM block " +
            "WHERE isNotes = 1 AND blockType = 'paragraph' " +
            "AND markdownFragment LIKE '%\(FixtureDatabase.escape(substring))%' LIMIT 1;"
        let stdout = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
        let trimmed = stdout.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty, let range = trimmed.range(of: sep) else { return nil }
        return (String(trimmed[..<range.lowerBound]), String(trimmed[range.upperBound...]))
    }

    /// Sibling of `notesParagraphFragment` WITHOUT the `isNotes = 1` filter -- for content that
    /// is expected to be a real, surviving paragraph row that is correctly no longer flagged
    /// `isNotes` (e.g. user prose left behind once its enclosing Notes section has legitimately
    /// dissolved). Mirrors that helper's field-separator/parsing exactly.
    func paragraphFragment(containing substring: String) -> (markdownFragment: String, textContent: String)? {
        let sep = "###FF_E2E_FIELD_SEP###"
        let sql = "SELECT markdownFragment || '\(sep)' || textContent FROM block " +
            "WHERE blockType = 'paragraph' " +
            "AND markdownFragment LIKE '%\(FixtureDatabase.escape(substring))%' LIMIT 1;"
        let stdout = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
        let trimmed = stdout.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty, let range = trimmed.range(of: sep) else { return nil }
        return (String(trimmed[..<range.lowerBound]), String(trimmed[range.upperBound...]))
    }

    /// Diagnostic dump of every `isNotes` row's id, blockType, headingLevel, markdownFragment,
    /// and textContent -- for a loud failure message (e2e-verify skill: "Helpers must fail
    /// loudly") when a targeted query comes back unexpectedly, so a future diagnosis round has
    /// the full picture (e.g. a duplicate/twin row) instead of just one query's result.
    func allNotesRowsDump() -> String {
        let sep = "###FF_E2E_FIELD_SEP###"
        let sql = "SELECT id || '\(sep)' || blockType || '\(sep)' || COALESCE(headingLevel, -1) || " +
            "'\(sep)' || markdownFragment || '\(sep)' || textContent FROM block " +
            "WHERE isNotes = 1 ORDER BY sortOrder;"
        return FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
    }

    /// Bounded poll (never a fixed sleep) for a `notesParagraphFragment` result that matches
    /// `before` EXACTLY on both `markdownFragment` and `textContent` -- not a substring-of-the-
    /// raw-marker containment check, which can never become true for a marker shape that
    /// `textContent`'s own normalization (e.g. `MarkdownUtils.stripMarkdownSyntax`) legitimately
    /// alters. Guards a project-reopen readback (scenario 5) against a transient startup state
    /// where `markdownFragment` (unchanged since the prior session's parse) already matches the
    /// LIKE query before a still-settling `textContent` has caught up.
    func notesParagraphFragmentSettled(
        containing substring: String,
        before: (markdownFragment: String, textContent: String)?,
        timeout: TimeInterval = 15
    ) -> (markdownFragment: String, textContent: String)? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            let found = notesParagraphFragment(containing: substring)
            if let found, found.markdownFragment == before?.markdownFragment, found.textContent == before?.textContent {
                return found
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        } while Date() < deadline
        return notesParagraphFragment(containing: substring)
    }

    /// T10's position-assertion mechanism. Polls (bounded, never a fixed sleep -- the typed
    /// sentinel's own flush back to the DB still runs on the normal debounced path) for a
    /// definition block containing `sentinel`, then asserts the sentinel sits immediately
    /// after the "]: " label-prefix boundary in `markdownFragment` -- a bare CONTAINS check
    /// would hide exactly the prefix-boundary/positional error class this whole task exists to
    /// close (the "search-and-guess, not content-verified" pattern documented in notes.md's
    /// "Prior attempt" section). `textContent` (prefix-stripped) is asserted too, so the two
    /// fields can never silently drift apart.
    func assertSentinelAtDefinitionStart(
        _ sentinel: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var found: (markdownFragment: String, textContent: String)?
        repeat {
            found = notesParagraphFragment(containing: sentinel)
            if found != nil { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        } while found == nil && Date() < deadline

        guard let row = found else {
            XCTFail("No isNotes paragraph block containing sentinel \"\(sentinel)\" appeared within \(timeout)s", file: file, line: line)
            return
        }

        guard let prefixRange = row.markdownFragment.range(of: "]: ") else {
            XCTFail(
                "markdownFragment \"\(row.markdownFragment)\" does not match the expected \"[^N]: \" definition prefix shape",
                file: file, line: line
            )
            return
        }
        let afterPrefix = row.markdownFragment[prefixRange.upperBound...]
        XCTAssertTrue(
            afterPrefix.hasPrefix(sentinel),
            "markdownFragment's definition text must START with the sentinel immediately after the \"[^N]: \" prefix -- " +
                "got markdownFragment=\"\(row.markdownFragment)\"",
            file: file, line: line
        )
        // CONFIRMED (by reading the source, not guessed): a Milkdown-authored footnote
        // definition's body carries exactly one leading space ahead of its real text in
        // `textContent`, even though `markdownFragment` does not. Root cause traced to
        // `web/milkdown/src/footnote-plugin.ts`'s `remarkFootnotePlugin` (pass 1, ~line 74):
        // parsing a `[^N]: text` GFM footnoteDefinition unconditionally builds the paragraph's
        // text-node sibling to the atomic `footnote_def` pill as `` `${childText}` `` -- a
        // deliberate ONE-space separator, since the pill's own `toMarkdown` emits `[^N]:` with
        // no trailing space (block-sync-plugin.ts:472) and relies on that sibling text node to
        // supply it on re-serialization. `web/milkdown/src/block-sync-plugin.ts`'s block-sync
        // diffing (line 764) captures `Block.textContent` straight from ProseMirror's native
        // `node.textContent` -- which concatenates that same leading-space-bearing text node
        // verbatim, since `footnote_def` is an atom (`.textContent` is `''` for atoms; see the
        // comment beside block-sync-plugin.ts:474) -- so the separator space that's supposed to
        // be purely a markdown-serialization artifact leaks into the stored "body text" field.
        // `markdownFragment` escapes this because the SAME leading space is exactly what
        // supplies the "]: " separator this function already consumed above, leaving nothing
        // extra for the sentinel to be prefixed by there. Out of scope for this test file (a
        // pre-existing Milkdown round-trip quirk, unrelated to Notes H1/H2 unification) --
        // asserting what the app actually and consistently does, not loosening to a bare
        // `contains` that would also swallow a genuine prefix-boundary regression.
        let expectedTextContent = " \(sentinel)"
        XCTAssertTrue(
            row.textContent.hasPrefix(expectedTextContent),
            "textContent (prefix-stripped) must start with the sentinel, prefixed by exactly the one known " +
                "editor-internal separator space (see this assertion's comment) -- got textContent=\"\(row.textContent)\"",
            file: file, line: line
        )
    }

    // MARK: - Fix round (M3) helpers: def -> ref click, both editors

    /// Clicks the footnote_def PILL (Rich Text/Milkdown) for `label` -- the small rounded atom
    /// `footnoteDefNodeView` renders at the start of the definition paragraph
    /// (`.ff-footnote-def` in `web/milkdown/src/styles.css`) -- to trigger
    /// `selectFootnoteReference`'s def->ref jump (M1's fix). Located via the SAME
    /// `editorStaticText(startingWith:)` + dx:0.02 idiom `clickIntoEditorBody` and
    /// `ListNumberingE2ETests` already rely on for "click near the very start of a found
    /// paragraph/line's own AX element" (dx too close to 0 risks the non-editable edge padding,
    /// per `clickIntoEditorBody`'s own doc comment), searching on `label` alone rather than a
    /// prefix of the definition's body text: the pill's own rendered text IS the label digit,
    /// and (per this suite's established heading-container precedent -- "a heading container's
    /// label concatenates all child text") the atom and its text sibling are expected to
    /// concatenate into one paragraph-level AX element beginning with that digit; even if they
    /// instead surface as separate leaves, the pill's own leaf value is just the digit, so
    /// `dx: 0.02` of either shape still lands on the pill. Only safe for a single-digit,
    /// non-renumbering fixture (as these two scenarios use) since it does not disambiguate
    /// multiple footnotes sharing a leading digit.
    func clickFootnoteDefinitionPill(label: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let pillElement = app.editorStaticText(startingWith: label, timeout: 10) else {
            XCTFail("Footnote definition pill for label \"\(label)\" not reachable in the editor", file: file, line: line)
            return
        }
        pillElement.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).click()
        // Small settle for the click handler's synchronous dispatch + `view.focus()` to be
        // observed by the next XCUITest keystroke -- the operation itself is synchronous
        // JS/ProseMirror work, not an async Swift<->JS round trip, so this is a much smaller
        // margin than `insertFootnoteAndWaitForLanding`'s 1.5s settle for that async tail.
        // Matches the established 0.3s post-click settle pattern used pervasively
        // elsewhere in this suite (e.g. editCaption, deleteTargetParagraph).
        // e2e-lint: allow sleep
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// Clicks inside the "[^N]:" definition marker (Markdown/CodeMirror) for `label` --
    /// decorated with the `cm-footnote-def` class by `footnote-decoration-plugin.ts`'s
    /// `buildDecorations` -- to trigger `handleClick`'s def->ref branch (the already-fixed half
    /// of the mirror-image pair M2 also corrects in this same function). `handleClick` only
    /// recognizes a click whose resolved document position falls within the "[^N]:" character
    /// range itself, not the trailing definition text, so this must land inside that literal
    /// substring rather than merely "near the start of the line".
    ///
    /// CONFIRMED live (vmtest, this round): CodeMirror does NOT expose "[^1]:" as one merged AX
    /// leaf, nor does it split it arbitrarily -- it splits at exactly the same boundary as the
    /// bare reference marker "[^1]" (its own separate leaf, per this suite's documented "a line
    /// can split across multiple leaf StaticTexts" gotcha), with the colon landing in its own
    /// immediately-following sibling leaf: three consecutive `staticTexts` leaves
    /// `"[^1]"` | `":"` | `" the definition text."`. So no leaf's own text ever starts with the
    /// literal "[^1]:", which is why `editorStaticText(startingWith: marker)` (prefix-matching a
    /// single element) could never find it -- not a timing issue, a query-shape one.
    ///
    /// A bare `"[^N]"` prefix search is not enough on its own, though: the body's reference
    /// marker for the same label renders as an IDENTICAL leaf text ("[^1]"), and it always
    /// appears earlier in document order (the reference precedes its definition), so the first
    /// "[^1]"-prefixed leaf in the tree is the WRONG one -- clicking it would fire `handleClick`'s
    /// ref->def branch instead of the def->ref branch this helper exists to trigger. The
    /// distinguishing signal is the same one `footnote-decoration-plugin.ts`'s own regexes use:
    /// `FOOTNOTE_DEF_REGEX` requires the marker be immediately followed by ":", while
    /// `FOOTNOTE_REF_REGEX` explicitly excludes it (`(?!:)`). So this scans for a "[^N]"-prefixed
    /// leaf whose immediately-following sibling leaf starts with ":" -- true only for the
    /// definition's marker, never the reference's.
    func clickFootnoteDefinitionMarker(label: String, file: StaticString = #filePath, line: UInt = #line) {
        let markerPrefix = "[^\(label)]"
        let deadline = Date(timeIntervalSinceNow: 10)
        var markerElement: XCUIElement?
        repeat {
            let elements = app.editorArea.staticTexts.allElementsBoundByIndex
            for index in elements.indices {
                let element = elements[index]
                guard element.exists else { continue }
                let text = (element.value as? String) ?? element.label
                guard text.hasPrefix(markerPrefix) else { continue }

                guard index + 1 < elements.count, elements[index + 1].exists else { continue }
                let nextText = (elements[index + 1].value as? String) ?? elements[index + 1].label
                if nextText.hasPrefix(":") {
                    markerElement = element
                    break
                }
            }
            if markerElement != nil { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline

        guard let markerElement else {
            XCTFail("Footnote definition marker \"\(markerPrefix):\" not reachable in the editor", file: file, line: line)
            return
        }
        // The found leaf's own text is just "[^N]" (the colon is a separate sibling leaf), so
        // any point inside it resolves to a document position within the "[^N]:" match range --
        // center (dx: 0.5) keeps the click well clear of the leaf's own edges.
        markerElement.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        // See clickFootnoteDefinitionPill's matching comment on this settle's size.
        // e2e-lint: allow sleep -- same established post-click settle pattern.
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// M3 (fix round for t-fee9dce6): asserts `sentinel` sits immediately after "[^N]" in the
    /// referencing body paragraph's `markdownFragment` -- the M1/M2 regression this pair of
    /// scenarios exists to prove e2e. "Before it" would mean the caret was still landing BEFORE
    /// the "[^N]" marker (the pre-fix bug this replaces: `Selection.near` stopping at the
    /// already-legal position before the atom instead of advancing past it), so this checks the
    /// immediate AFTER-position specifically, not just presence anywhere in the block. Reuses
    /// `paragraphFragment` (no `isNotes` filter, since the target here is the BODY paragraph,
    /// not a Notes definition) rather than a new query.
    func assertSentinelImmediatelyAfterReference(
        _ sentinel: String, label: String, timeout: TimeInterval = 15,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var found: (markdownFragment: String, textContent: String)?
        repeat {
            found = paragraphFragment(containing: sentinel)
            if found != nil { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        } while found == nil && Date() < deadline

        guard let row = found else {
            XCTFail("No body paragraph block containing sentinel \"\(sentinel)\" appeared within \(timeout)s", file: file, line: line)
            return
        }

        guard let refRange = row.markdownFragment.range(of: "[^\(label)]") else {
            XCTFail(
                "markdownFragment \"\(row.markdownFragment)\" does not contain the expected \"[^\(label)]\" reference marker",
                file: file, line: line
            )
            return
        }
        let afterRef = row.markdownFragment[refRange.upperBound...]
        XCTAssertTrue(
            afterRef.hasPrefix(sentinel),
            "sentinel must land immediately AFTER \"[^\(label)]\", not before it (the M1/M2 regression) -- " +
                "got markdownFragment=\"\(row.markdownFragment)\"",
            file: file, line: line
        )
    }
}
