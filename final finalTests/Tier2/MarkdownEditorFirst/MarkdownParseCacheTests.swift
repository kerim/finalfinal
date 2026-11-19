//
//  MarkdownParseCacheTests.swift
//  final finalTests
//
//  t-2fbe4c9b Phase 4c job 3, round C1a (plan v2 section 3(A), amendments A1 and A6): the writer's PARSE MEMO
//  (`MarkdownParseCache`, ViewState/MarkdownParseCache.swift) and the way `MarkdownBlockWriter.prepare` uses it. The tests of the
//  prewarm TRIGGERS (a click's step 8 and the debounce fire hitting) come with the triggers in a later round.
//
//  Texts: the generated six-chapter book (`POCComplexGenerator`: citations, footnotes, headings, a Notes section) for the key tests,
//  and the generated article (66 citation groups, nine footnotes, a Notes section, 58,600 characters) for the writer tests, which use
//  the real writer, a real database and the real `BlockSyncService` (`MarkdownWriterRig`). Nothing is mocked.
//
//  `prepare` reads `ExportSettings.load()` itself, and `ExportSettings.userDefaults` is a process-wide static that other suites swap
//  while they run. A prewarm in these tests is given its names explicitly (`names:`), and every `prepare` call (a `fire`, a
//  `prepareAndStart`) sits in a SYNCHRONOUS window under `exportSettingsTestLock` (no suspension while it is held), so a hit or miss can
//  never be caused by another suite's swap. (Test 7 prewarms through the REAL scheduler, which cannot be given names; it reads the
//  settings on the main actor, where no swapper's synchronous window can be interrupted.)
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//
//  Break patches (a 1-5 line change in production code that must make the test fail), and the failure each shows. Every function named
//  here exists in MarkdownParseCache.swift, MarkdownScanMemo.swift, MarkdownBlockWriter.swift or the file named. The tests of what the
//  background work does with its requests (17 to 24) are in MarkdownParseCacheTests+Background.swift, with their own list.
//
//   1   testCachedParseEqualsDirectParse
//       BREAK: in `MarkdownParseCache.parse(_:)` pass `notesHeaderName: nil` instead of `key.notesTitle` (the "Notes heading that is not
//       'Notes'" scenario), or in `MarkdownParseCache.scan(_:)` build the key from `job.raw` instead of `recordText(fromRaw: job.raw)`
//       (the page-text scenario).
//       FAILS with: "prewarmed blocks differ from a direct parse: a Notes heading that is not 'Notes'" / "...: a page text with anchors...".
//   2   testHitAndMissGiveIdenticalChanges
//       BREAK: in `MarkdownBlockWriter.prepare` make the hit branch `parsed = Array(cached.blocks.dropLast())`.
//       FAILS with: "the hit gave different changes than the miss". (With the lookup returning nil: "the second writer did not hit".)
//   3   testAnyKeyChangeMisses
//       BREAK: in `MarkdownParseCache.Key.matches` drop the `projectId` (or `notesTitle`, header name, grace list) comparison.
//       FAILS with: "a key that differs in <part> was a hit".
//   4   testRecordTextEqualsOnContentChangeStrip
//       The oracle is a LITERAL expected string, independent of the code under test.
//       BREAK: in `SectionSyncService.anchorPattern` make the pattern `[0-9a-f-]+` (lowercase only) or drop the `-` from its class.
//       FAILS with: "recordText of the fixture is not the literal expected text".
//   5   testPrewarmAfterResetIsNotStored
//       BREAK: in `MarkdownParseCache.finish` make `let wanted = true`.
//       FAILS with: "a prewarm that finished after reset() was stored".
//   7   testDebounceFireHitsAfterSettledPrewarm
//       BREAK: delete the `prewarmParseAfterTypingPause(...)` line in `scheduleFullDocumentReparse` (ViewNotificationModifiers.swift).
//       FAILS with: "the scheduler did not ask the memo for the text".
//   8   testHandlerMemoGivesSameRefsAndKeys
//       BREAK: in `MarkdownScanMemo.entry(forStripped:projectId:)` drop the `$0.projectId == projectId` test; or in
//       `MarkdownParseCache.publishScans` delete the `if requestGeneration == generation` condition; or in `MarkdownScanMemo.makeEntry`
//       store `stripped: rawText` instead of the stripped text.
//       FAILS with: "another project's text was a hit" / "a scan result that finished after reset() was stored" /
//       "the memo's stripped text differs from onContentChange's".
//   9   testCanonicallyEquivalentTextsMiss
//       BREAK: in `MarkdownParseCache.Key.matches` replace `Self.sameBytes(text, other.text)` with `text == other.text`.
//       FAILS with: "canonically equivalent text was a hit".
//   10  testRecordTextIsIdempotent
//       BREAK: in `MarkdownLeaderMap.recordText` strip only the first anchor (replace the matches of `firstMatch(in:)` only).
//       FAILS with: "recordText is not idempotent".
//   11  testRecordTextOffMainMatchesMainActorVersion
//       BREAK: in `MarkdownLeaderMap.recordText` skip the anchor strip when `!Thread.isMainThread`.
//       FAILS with: "the background strip differs from the main-actor strip".
//   12  testLatestWinsPrewarm
//       BREAK: in `MarkdownParseCache.prewarm` replace `pending = request` by `if pending == nil { pending = request }` (the first request wins).
//       FAILS with: "the newest request was not the one that ran" (a burst of delayed requests) / "the request that started at once or the
//       newest one was lost" (undelayed).
//   13  testLRUEvictsOldest
//       BREAK: in `MarkdownParseCache.store(_:)` remove the `entries.removeFirst(...)` line.
//       FAILS with: "the oldest entry was not evicted".
//   14  testMissStoresEntryForNextPrepare
//       BREAK: delete the `parseCache.store(key, ...)` line in `MarkdownBlockWriter.prepare`.
//       FAILS with: "the second prepare of the same text did not hit".
//   15  testMissUsesExplicitBibliographyNames
//       BREAK: in `MarkdownBlockWriter.prepare` build the key with `bibliographyHeaderName: "Bibliography"` instead of `names.headerName`.
//       FAILS with: "a changed bibliography name was a stale hit".
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Markdown parse memo — Tier 2 (t-2fbe4c9b Phase 4c job 3, round C1a)", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct MarkdownParseCacheTests {

    typealias Key = MarkdownParseCache.Key
    static let defaultNames: (headerName: String, graceNames: [String]) = ("Bibliography", [])

    static let article = POCComplexGenerator.make(id: "article", title: "Article", chapters: 1)
    static let book6 = POCComplexGenerator.make(id: "book6", title: "Six chapters", chapters: 6)

    // MARK: - Helpers

    /// Runs `body` with no other suite swapping `ExportSettings.userDefaults`. Synchronous: nothing may suspend while the lock is held.
    @discardableResult
    func underStableSettings<T>(_ body: () throws -> T) rethrows -> T {
        exportSettingsTestLock.lock()
        defer { exportSettingsTestLock.unlock() }
        return try body()
    }

    /// A temporary project database (for the Notes title read and the project id). `notesTitle`: its Notes heading is renamed to this
    /// (the database then names a Notes title other than the parser's default "Notes").
    func makeProject(notesTitle: String? = nil) throws -> (db: ProjectDatabase, pid: String) {
        let db = try TestFixtureFactory.createTemporary(content: Self.article.markdown)
        if let notesTitle {
            try db.write { database in
                try database.execute(
                    sql: "UPDATE block SET textContent = ?, markdownFragment = ? WHERE isNotes = 1 AND blockType = 'heading'",
                    arguments: [notesTitle, "# \(notesTitle)"])
            }
        }
        return (db, try TestFixtureFactory.getProjectId(from: db))
    }

    /// The blocks with everything that varies from one parse to the next removed: the ids (and the ids other fields name, mapped to
    /// their block's position) and the two timestamps.
    private static func normalized(_ blocks: [Block]) -> [Block] {
        let ordinal = Dictionary(uniqueKeysWithValues: blocks.enumerated().map { ($1.id, "block-\($0)") })
        return blocks.map { block in
            var copy = block
            copy.id = ordinal[block.id] ?? ""
            copy.parentId = block.parentId.map { ordinal[$0] ?? $0 }
            copy.sectionParentId = block.sectionParentId.map { ordinal[$0] ?? $0 }
            copy.createdAt = .distantPast
            copy.updatedAt = .distantPast
            return copy
        }
    }

    /// The page text for `markdown`: a section anchor in front of every heading line, and the bibliography opening marker with a
    /// Bibliography section (and its end marker) at the end, as the page holds a book.
    static func pageText(from markdown: String) -> String {
        var headings = 0
        let lines = markdown.components(separatedBy: "\n").map { line -> String in
            guard line.hasPrefix("# ") || line.hasPrefix("## ") || line.hasPrefix("### ") else { return line }
            headings += 1
            return String(format: "<!-- @sid:%08X-1111-4222-8333-%012X -->", headings, headings * 7919) + line
        }
        return lines.joined(separator: "\n")
            + "\n\n<!-- ::auto-bibliography:: -->\n\n# Bibliography\n\nSmith, J. 2020. A title.\n\n<!-- ::auto-bibliography-end:: -->\n"
    }

    /// The article with one sentence typed at the end of a long cited paragraph and one new paragraph after it: one update and
    /// one insert against the stored rows.
    static func typedEdit(of loaded: String, rows: [Block]) throws -> String {
        let target = try #require(rows.first {
            $0.blockType == .paragraph && !$0.isNotes && !$0.isBibliography
                && $0.markdownFragment.contains("[@") && $0.markdownFragment.count > 200
                && loaded.components(separatedBy: $0.markdownFragment).count == 2
        })
        return loaded.replacingOccurrences(
            of: target.markdownFragment, with: target.markdownFragment + " A typed sentence.\n\nA brand new paragraph, unlike any other.")
    }

    /// `text` with one ASCII letter at the middle changed to another (the same number of bytes).
    static func changingOneLetterInTheMiddle(of text: String) throws -> String {
        var scalars = Array(text.unicodeScalars)
        let index = try #require(scalars[(scalars.count / 2)...].firstIndex { $0.isASCII && $0.properties.isAlphabetic })
        scalars[index] = scalars[index] == "z" ? "y" : "z"
        var result = String.UnicodeScalarView()
        result.append(contentsOf: scalars)
        return String(result)
    }

    final class TempIds {
        private var next = 0
        func make() -> String {
            next += 1
            return "temp-md-fixed-\(next)"
        }
    }

    /// Asks `cache` to prewarm `raw` (with the default bibliography names unless given) and waits for it.
    private func prewarmed(
        _ cache: MarkdownParseCache, raw: String, project: (db: ProjectDatabase, pid: String),
        names: (headerName: String, graceNames: [String]) = ("Bibliography", [])
    ) async {
        cache.prewarm(raw: raw, projectId: project.pid, database: project.db, names: names)
        await cache.settled()
    }

    /// One text for test 1 and the bibliography names it is parsed with.
    private struct Scenario {
        let label: String
        let raw: String
        let names: (headerName: String, graceNames: [String])
        let project: (db: ProjectDatabase, pid: String)
    }
}

// The tests sit in an extension so the struct body above stays under SwiftLint's type-body-length.
extension MarkdownParseCacheTests {

    // MARK: - 1

    @Test("1: a prewarm stores the blocks and open-fence answer of a direct parse (book, open fence, page text with anchors, custom names)")
    func testCachedParseEqualsDirectParse() async throws {
        let project = try makeProject()
        let endnotesProject = try makeProject(notesTitle: "Endnotes")
        let book = Self.book6.markdown
        let custom: (headerName: String, graceNames: [String]) = ("Works Cited", ["Old Sources"])
        // A terminator-bounded run under a title heading: a bibliography only while "Works Cited" is the configured (or a grace) name.
        let customBibliography = book + "\n\n# Works Cited\n\nSmith, J. 2020. A title.\n\n" + BlockParser.bibliographyEndMarker + "\n"
        // A Notes heading that is not "Notes": the parse recognizes it only when the database's title ("Endnotes") is passed to it.
        let endnotes = book.replacingOccurrences(of: "\n# Notes\n", with: "\n# Endnotes\n")
        let scenarios = [
            Scenario(label: "the book", raw: book, names: Self.defaultNames, project: project),
            Scenario(
                label: "an open fence at the end", raw: book + "\n\n```swift\nlet openAtTheEnd = true\n", names: Self.defaultNames,
                project: project),
            Scenario(
                label: "a page text with anchors and the marker", raw: Self.pageText(from: book), names: Self.defaultNames, project: project),
            Scenario(label: "custom bibliography names", raw: customBibliography, names: custom, project: project),
            Scenario(label: "a Notes heading that is not 'Notes'", raw: endnotes, names: Self.defaultNames, project: endnotesProject)
        ]
        for scenario in scenarios {
            let cache = MarkdownParseCache()
            let project = scenario.project
            let notesTitle = try project.db.fetchNotesHeadingTitle(projectId: project.pid)
            await prewarmed(cache, raw: scenario.raw, project: project, names: scenario.names)
            let record = MarkdownLeaderMap.recordText(fromRaw: scenario.raw)
            let key = Key(
                text: record, projectId: project.pid, notesTitle: notesTitle,
                bibliographyHeaderName: scenario.names.headerName, graceNames: scenario.names.graceNames)
            let entry = try #require(cache.lookup(key), "no memo entry for the record text: \(scenario.label)")
            let direct = BlockParser.parse(
                markdown: record, projectId: project.pid, bibliographyHeaderName: scenario.names.headerName,
                graceNames: scenario.names.graceNames, notesHeaderName: notesTitle)
            #expect(entry.blocks.count == direct.count, "block count: \(scenario.label)")
            #expect(Self.normalized(entry.blocks) == Self.normalized(direct), "prewarmed blocks differ from a direct parse: \(scenario.label)")
            #expect(entry.endsOpen == BlockParser.endsInsideOpenFenceOrMath(record), "the open-fence answer differs: \(scenario.label)")
        }
        // The open fence case really ends open, and the names and the Notes title really matter (otherwise the cases above prove little).
        let open = BlockParser.endsInsideOpenFenceOrMath(book + "\n\n```swift\nlet openAtTheEnd = true\n")
        #expect(open, "premise: an unclosed fence ends open")
        let withCustomNames = BlockParser.parse(
            markdown: customBibliography, projectId: project.pid, bibliographyHeaderName: custom.headerName,
            graceNames: custom.graceNames, notesHeaderName: nil)
        let withDefaultNames = BlockParser.parse(
            markdown: customBibliography, projectId: project.pid, bibliographyHeaderName: "Bibliography", graceNames: [],
            notesHeaderName: nil)
        #expect(Self.normalized(withCustomNames) != Self.normalized(withDefaultNames), "premise: the bibliography names change the parse")
        #expect(
            try endnotesProject.db.fetchNotesHeadingTitle(projectId: endnotesProject.pid) == "Endnotes",
            "premise: the second project's database names the Notes title 'Endnotes'")
        let knowingTheTitle = BlockParser.parse(
            markdown: endnotes, projectId: project.pid, bibliographyHeaderName: "Bibliography", graceNames: [], notesHeaderName: "Endnotes")
        let notKnowingIt = BlockParser.parse(
            markdown: endnotes, projectId: project.pid, bibliographyHeaderName: "Bibliography", graceNames: [], notesHeaderName: nil)
        #expect(endnotes != book, "premise: the Notes heading was renamed")
        #expect(Self.normalized(knowingTheTitle) != Self.normalized(notKnowingIt), "premise: the Notes title changes the parse")
    }

    // MARK: - 2

    @Test("2: a prepare that hits the memo and a prepare that parses reserve the same changes (same temp ids), and the line says hit or miss")
    func testHitAndMissGiveIdenticalChanges() async throws {
        let rig = try MarkdownWriterRig(content: Self.article.markdown)
        let loaded = try rig.storedText()
        let typed = try Self.typedEdit(of: loaded, rows: try rig.rows())
        let missingWriter = rig.markdownWriter
        let hittingWriter = MarkdownBlockWriter()
        missingWriter.noteLoaded(text: loaded, pid: rig.pid)   // the app loads the editor from the stored rows
        hittingWriter.noteLoaded(text: loaded, pid: rig.pid)
        var missChanges: BlockChanges?
        var hitChanges: BlockChanges?
        let missIds = TempIds()
        let hitIds = TempIds()
        missingWriter.testMakeTempId = { missIds.make() }
        hittingWriter.testMakeTempId = { hitIds.make() }
        missingWriter.testChangesObserver = { missChanges = $0 }
        hittingWriter.testChangesObserver = { hitChanges = $0 }

        // The second writer's memo is prepared in the background first, as a trigger would; the first writer has nothing. The names are
        // read ONCE, under the lock, and given to the prewarm, so what `prepare` reads below (also under the lock) is the same.
        let names = underStableSettings { BlockParser.bibliographyNames(from: ExportSettings.load()) }
        hittingWriter.parseCache.prewarm(raw: typed, projectId: rig.pid, database: rig.db, names: names)
        await hittingWriter.parseCache.settled()
        #expect(hittingWriter.parseCache.entries.count == 1, "premise: the prewarm stored the text")

        // A held system sequence keeps both reserved turns unapplied, so both diffs are made against the same stored rows.
        let held = rig.hold()
        let dispositions = underStableSettings {
            (
                missingWriter.prepareAndStart(text: typed, database: rig.db, projectId: rig.pid, service: rig.sync, refire: {}),
                hittingWriter.prepareAndStart(text: typed, database: rig.db, projectId: rig.pid, service: rig.sync, refire: {})
            )
        }
        #expect(dispositions.0 == .started && dispositions.1 == .started, "premise: both writers reserved a turn")
        await rig.release(held)
        for writer in [missingWriter, hittingWriter] {
            while let pending = writer.inFlight { await pending.value }
        }

        let missing = try #require(missChanges, "the first writer reserved no changes")
        let hitting = try #require(hitChanges, "the second writer reserved no changes")
        #expect(!missing.updates.isEmpty && !missing.inserts.isEmpty, "premise: the edit is an update and an insert")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(missing) == encoder.encode(hitting), "the hit gave different changes than the miss")
        #expect(missingWriter.lastTimingLine?.contains("cache=miss") == true, "got \(missingWriter.lastTimingLine ?? "nil")")
        let hitLine = hittingWriter.lastTimingLine ?? "nil"
        #expect(hitLine.contains("cache=hit"), "the second writer did not hit: \(hitLine)")
        #expect(hittingWriter.lastTimingLine?.contains("parse=0.0ms") == true, "a hit parses nothing: \(hittingWriter.lastTimingLine ?? "nil")")
    }

    // MARK: - 3

    @Test("3: a key that differs in the text, the project, the Notes title, the bibliography name or the grace list is a miss")
    func testAnyKeyChangeMisses() throws {
        let book = Self.book6.markdown
        let blocks = BlockParser.parse(
            markdown: book, projectId: "p1", bibliographyHeaderName: "Bibliography", graceNames: ["Old"], notesHeaderName: "Notes")
        func key(
            text: String? = nil, project: String = "p1", notes: String? = "Notes", header: String = "Bibliography", grace: [String] = ["Old"]
        ) -> Key {
            Key(text: text ?? book, projectId: project, notesTitle: notes, bibliographyHeaderName: header, graceNames: grace)
        }
        let cache = MarkdownParseCache()
        cache.store(key(), blocks: blocks, endsOpen: false)
        #expect(cache.lookup(key()) != nil, "premise: an identical key (built separately) hits")

        let variants: [(String, Key)] = [
            ("one letter in the middle of the text", key(text: try Self.changingOneLetterInTheMiddle(of: book))),
            ("the last character of the text", key(text: String(book.dropLast()) + "!")),
            ("the text one character longer", key(text: book + "x")),
            ("the project", key(project: "p2")),
            ("the Notes title", key(notes: "Endnotes")),
            ("no Notes title", key(notes: nil)),
            ("the bibliography name", key(header: "References2")),
            ("one letter of the grace name", key(grace: ["Olf"])),
            ("an extra grace name", key(grace: ["Old", "Older"])),
            ("no grace names", key(grace: []))
        ]
        for (label, variant) in variants {
            #expect(cache.lookup(variant) == nil, "a key that differs in \(label) was a hit")
        }
        #expect(cache.lookup(key()) != nil, "the original entry is still there")
        #expect(cache.entries.count == 1)
    }

    // MARK: - 4

    @Test("4: recordText of a page text is the literal expected text, and equals what onContentChange does to it")
    func testRecordTextEqualsOnContentChangeStrip() throws {
        // An oracle that shares no code with what it tests: a fixture with KNOWN anchors and marker and a LITERAL expected output. The
        // anchor pattern is hexadecimal digits and dashes, so "not-hex" is no anchor and stays; a plain comment stays; the bibliography
        // OPENING marker goes, the END marker stays (as in `editorState.content`).
        let fixture = [
            "<!-- @sid:0F3A9C12-7d4e-4b8a-9c1d-2e5f6a7b8c9d -->## Chapter One", "", "Body text with a citation [@smith2020].", "",
            "<!-- @sid:ab-12 -->### Section", "", "<!-- ::auto-bibliography:: -->## Bibliography", "", "Smith, J. 2020. A title.", "",
            "<!-- ::auto-bibliography-end:: -->", "", "<!-- @sid:not-hex -->This stays: the id is not hexadecimal.", "<!-- a plain comment stays -->"
        ].joined(separator: "\n")
        let expected = [
            "## Chapter One", "", "Body text with a citation [@smith2020].", "", "### Section", "", "## Bibliography", "",
            "Smith, J. 2020. A title.", "", "<!-- ::auto-bibliography-end:: -->", "",
            "<!-- @sid:not-hex -->This stays: the id is not hexadecimal.", "<!-- a plain comment stays -->"
        ].joined(separator: "\n")
        #expect(Key.sameBytes(MarkdownLeaderMap.recordText(fromRaw: fixture), expected), "recordText of the fixture is not the literal expected text")

        let raw = Self.pageText(from: Self.article.markdown)
        #expect(raw.contains("@sid:") && raw.contains("<!-- ::auto-bibliography:: -->"), "premise: the fixture has anchors and the marker")
        // ContentView+EditorPresentation.swift onContentChange: `stripSectionAnchors`, then `stripBibliographyMarker`.
        let stripped = SectionSyncService.stripBibliographyMarker(from: SectionSyncService().stripSectionAnchors(from: raw))
        let record = MarkdownLeaderMap.recordText(fromRaw: raw)
        #expect(Key.sameBytes(record, stripped), "recordText differs from the onContentChange strip")
        #expect(!record.contains("@sid:") && !record.contains("<!-- ::auto-bibliography:: -->"), "the anchors and the opening marker are gone")
        #expect(record.contains("<!-- ::auto-bibliography-end:: -->"), "the end marker stays, as in editorState.content")
    }

    // MARK: - 5

    @Test("5: a prewarm that finishes after reset() is not stored; one asked for after the reset is")
    func testPrewarmAfterResetIsNotStored() async throws {
        let project = try makeProject()
        let cache = MarkdownParseCache()
        let text = Self.article.markdown

        // The reset comes while the background parse is done and about to be stored (the main actor runs this hook first).
        cache.testBeforeStore = { cache.reset() }
        await prewarmed(cache, raw: text, project: project)
        cache.testBeforeStore = nil
        #expect(cache.generation == 1)
        #expect(cache.entries.isEmpty, "a prewarm that finished after reset() was stored")

        // An UNDELAYED request starts at once, so a reset right after it finds the job running: its result is dropped when it arrives.
        cache.prewarm(raw: text + "\n\nOne.", projectId: project.pid, database: project.db, names: Self.defaultNames)
        #expect(cache.isRunning, "premise: an undelayed request has started")
        cache.reset()
        await cache.settled()
        #expect(cache.entries.isEmpty, "a request made before reset() ran and was stored")

        // A DELAYED request has not started: the reset takes it back, nothing runs, nothing is stored.
        let startedBefore = cache.startedCount
        cache.prewarm(raw: text + "\n\nOne again.", projectId: project.pid, database: project.db, names: Self.defaultNames, after: .seconds(60))
        cache.reset()
        await cache.settled()
        #expect(cache.startedCount == startedBefore && cache.entries.isEmpty, "a delayed request that a reset took back ran")

        // A request made after the reset is stored.
        await prewarmed(cache, raw: text + "\n\nTwo.", project: project)
        #expect(cache.entries.count == 1, "a prewarm asked for after the reset was not stored")
    }

    // MARK: - 7

    @Test("7: typing arms the REAL debounced re-parse, whose scheduler also asks the memo for the text after a 300 ms pause; the fire then hits")
    func testDebounceFireHitsAfterSettledPrewarm() async throws {
        let rig = try MarkdownWriterRig(content: Self.article.markdown)
        rig.editorState.sourceReparseDebounce = .seconds(60)   // the fire itself is played by hand below; the real one must not come first
        let loaded = try rig.storedText()
        let typed = try Self.typedEdit(of: loaded, rows: try rig.rows())
        let cache = rig.markdownWriter.parseCache

        // The content changed: the real scheduler (`scheduleFullDocumentReparse`) arms the debounce and asks the memo, O(1), for later.
        let debounce = underStableSettings { rig.schedule(typed) }
        #expect(debounce != nil, "premise: the scheduler armed the debounce")
        #expect(cache.entries.isEmpty && cache.missCount == 0, "the prewarm did work at schedule time instead of after the typing pause")
        await cache.settled()   // the pause (300 ms) is over and the background parse is done
        #expect(cache.entries.count == 1, "the scheduler did not ask the memo for the text")
        debounce?.cancel()
        rig.editorState.blockReparseTask = nil

        // The debounce fire's synchronous step on the same content.
        underStableSettings { rig.fire(typed) }
        await rig.settle()
        let line = rig.markdownWriter.lastTimingLine ?? "nil"
        #expect(line.contains("cache=hit"), "the debounce fire did not hit the memo: \(line)")
        #expect(cache.hitCount == 1 && cache.missCount == 0)
        #expect(line.contains("outcome=applied"), "premise: the fire wrote the typing: \(line)")
    }

    // MARK: - 8

    /// Strings equal element by element and byte for byte (an array `==` would use Swift's canonical-equivalence `String ==`).
    static func sameStrings(_ left: [String], _ right: [String]) -> Bool {
        left.count == right.count && zip(left, right).allSatisfy { Key.sameBytes($0, $1) }
    }

    @Test("8: the handler scan memo's stripped text, citation keys and footnote references are exactly the direct scans'; anything else misses")
    func testHandlerMemoGivesSameRefsAndKeys() async throws {
        let project = try makeProject()
        let otherProject = try makeProject()
        let book = Self.book6.markdown
        let page = Self.pageText(from: book)
        func prewarm(_ raw: String, into cache: MarkdownParseCache) async {
            cache.prewarm(raw: raw, projectId: project.pid, database: project.db, names: Self.defaultNames)
            await cache.settled()
        }

        // The book text, and a page text with section anchors and the bibliography marker.
        let cache = MarkdownParseCache()
        await prewarm(book, into: cache)
        await prewarm(page, into: cache)
        let directKeys = BibliographySyncService.extractCitekeys(from: book)
        let directRefs = FootnoteSyncService.extractFootnoteRefs(from: book)
        #expect(!directKeys.isEmpty && !directRefs.isEmpty, "premise: the book has citations and footnotes")
        let bookEntry = try #require(cache.scans.entry(forStripped: book, projectId: project.pid), "the book's scans were not stored")
        #expect(Self.sameStrings(bookEntry.citekeys, directKeys), "the memo's citation keys differ from the direct scan")
        #expect(Self.sameStrings(bookEntry.footnoteRefs, directRefs), "the memo's footnote references differ from the direct scan")
        #expect(Key.sameBytes(bookEntry.stripped, book))

        let strippedPage = SectionSyncService.stripBibliographyMarker(from: SectionSyncService().stripSectionAnchors(from: page))
        #expect(strippedPage != page, "premise: the page text has something to strip")
        let pageEntry = try #require(cache.scans.entry(forRaw: page), "the page text's scans were not stored")
        #expect(Key.sameBytes(pageEntry.stripped, strippedPage), "the memo's stripped text differs from onContentChange's")
        #expect(Self.sameStrings(pageEntry.citekeys, BibliographySyncService.extractCitekeys(from: strippedPage)))
        #expect(Self.sameStrings(pageEntry.footnoteRefs, FootnoteSyncService.extractFootnoteRefs(from: strippedPage)))
        // The consumers' entry points serve the stored values, counted as hits.
        let hitsBefore = cache.scans.hitCount
        #expect(cache.scans.stripped(forRaw: page).map { Key.sameBytes($0, strippedPage) } == true)
        #expect(Self.sameStrings(cache.scans.citekeys(for: strippedPage, projectId: project.pid), pageEntry.citekeys))
        #expect(Self.sameStrings(cache.scans.footnoteRefs(for: strippedPage, projectId: project.pid), pageEntry.footnoteRefs))
        #expect(cache.scans.hitCount == hitsBefore + 3, "the consumers' lookups were not hits")

        // One changed letter, and another project, miss; the answer a miss gives is the direct scan of the text asked about.
        let changed = try Self.changingOneLetterInTheMiddle(of: book)
        #expect(cache.scans.entry(forStripped: changed, projectId: project.pid) == nil, "a text one letter different was a hit")
        #expect(cache.scans.entry(forRaw: try Self.changingOneLetterInTheMiddle(of: page)) == nil, "a raw text one letter different was a hit")
        #expect(cache.scans.entry(forStripped: book, projectId: otherProject.pid) == nil, "another project's text was a hit")
        let missesBefore = cache.scans.missCount
        #expect(Self.sameStrings(cache.scans.citekeys(for: changed, projectId: project.pid), BibliographySyncService.extractCitekeys(from: changed)))
        #expect(cache.scans.missCount == missesBefore + 1)

        // Canonically equivalent forms miss: precomposed against decomposed (other lengths), and combining marks in the other order (same length).
        for (left, right) in [("caf\u{E9}", "cafe\u{301}"), ("a\u{323}\u{301}", "a\u{301}\u{323}")] {
            let equivalents = MarkdownParseCache()
            let (stored, equivalent) = (book + "\n\n" + left, book + "\n\n" + right)
            await prewarm(stored, into: equivalents)
            #expect(equivalents.scans.entry(forStripped: stored, projectId: project.pid) != nil, "premise: the same bytes hit")
            #expect(equivalents.scans.entry(forStripped: equivalent, projectId: project.pid) == nil, "a canonically equivalent form was a hit")
            #expect(equivalents.scans.entry(forRaw: equivalent) == nil, "a canonically equivalent raw form was a hit")
        }

        // A reset empties the memo, and a result the background task finishes after a reset is not stored.
        cache.reset()
        #expect(cache.scans.entries.isEmpty && cache.scans.entry(forStripped: book, projectId: project.pid) == nil, "reset() left scans behind")
        let stale = MarkdownParseCache()
        stale.testAfterScan = {
            stale.testAfterScan = nil
            stale.reset()
        }
        await prewarm(book, into: stale)
        #expect(stale.scans.entries.isEmpty, "a scan result that finished after reset() was stored")
        #expect(stale.scans.entry(forStripped: book, projectId: project.pid) == nil, "a stale scan result was served")
    }

    // MARK: - 9

    @Test("9: canonically equivalent texts are different keys (Swift's String == would call them equal)")
    func testCanonicallyEquivalentTextsMiss() throws {
        let pairs: [(String, String)] = [
            ("caf\u{E9}", "cafe\u{301}"),                    // precomposed against decomposed (different byte counts)
            ("a\u{323}\u{301}", "a\u{301}\u{323}")           // combining marks in the other order (the same byte count)
        ]
        for (left, right) in pairs {
            #expect(left == right, "premise: Swift treats \(left.unicodeScalars.count)- and \(right.unicodeScalars.count)-scalar forms as equal")
            let book = Self.book6.markdown
            let stored = Key(text: book + "\n\n" + left, projectId: "p", notesTitle: nil, bibliographyHeaderName: "B", graceNames: [])
            let cache = MarkdownParseCache()
            cache.store(stored, blocks: [], endsOpen: false)
            let equivalent = Key(text: book + "\n\n" + right, projectId: "p", notesTitle: nil, bibliographyHeaderName: "B", graceNames: [])
            #expect(cache.lookup(equivalent) == nil, "canonically equivalent text was a hit")
            #expect(cache.lookup(stored) != nil, "premise: the same bytes hit")
        }
    }

    // MARK: - 10

    @Test("10: recordText is idempotent: the content record (already stripped) gives itself back")
    func testRecordTextIsIdempotent() throws {
        for markdown in [Self.article.markdown, Self.book6.markdown] {
            let raw = Self.pageText(from: markdown)
            let once = MarkdownLeaderMap.recordText(fromRaw: raw)
            let twice = MarkdownLeaderMap.recordText(fromRaw: once)
            #expect(once != raw, "premise: the strip changed the page text")
            #expect(Key.sameBytes(once, twice), "recordText is not idempotent")
            #expect(Key.sameBytes(MarkdownLeaderMap.recordText(fromRaw: markdown), markdown), "a text with nothing to strip changed")
        }
    }

    // MARK: - 11

    @Test("11: stripping a page text from a detached task and on the main actor gives the same text (and the main-actor service's strip)")
    func testRecordTextOffMainMatchesMainActorVersion() async throws {
        let raw = Self.pageText(from: Self.book6.markdown)
        #expect(raw.contains("@sid:") && raw.contains("<!-- ::auto-bibliography:: -->"), "premise: the fixture has anchors and the marker")
        let onMain = MarkdownLeaderMap.recordText(fromRaw: raw)
        let offMain = await Task.detached(priority: .userInitiated) { MarkdownLeaderMap.recordText(fromRaw: raw) }.value
        #expect(Key.sameBytes(onMain, offMain), "the background strip differs from the main-actor strip")
        let service = SectionSyncService().stripSectionAnchors(from: raw)
        #expect(Key.sameBytes(offMain, SectionSyncService.stripBibliographyMarker(from: service)), "the strip differs from the service's own")
        #expect(!offMain.contains("@sid:") && !offMain.contains("<!-- ::auto-bibliography:: -->"), "the background strip left anchors behind")
    }

    // MARK: - 12

    @Test("12: latest wins: a burst of delayed requests parses only the newest; an undelayed one starts at once, a waiting one is replaced")
    func testLatestWinsPrewarm() async throws {
        let project = try makeProject()
        let base = Self.article.markdown
        func texts(_ suffix: String) -> String { base + "\n\n" + suffix }
        func cached(_ cache: MarkdownParseCache, _ suffix: String) -> Bool {
            cache.entries.contains { Key.sameBytes($0.key.text, texts(suffix)) }
        }
        func ask(_ cache: MarkdownParseCache, _ suffix: String, after delay: Duration? = nil) {
            cache.prewarm(raw: texts(suffix), projectId: project.pid, database: project.db, names: Self.defaultNames, after: delay)
        }

        // (a) Three DELAYED requests in one turn (a typing burst): only the newest is ever parsed.
        let quick = MarkdownParseCache()
        ask(quick, "one", after: .milliseconds(50))
        ask(quick, "two", after: .milliseconds(50))
        ask(quick, "three", after: .milliseconds(50))
        await quick.settled()
        #expect(cached(quick, "three") && !cached(quick, "one") && !cached(quick, "two"), "the newest request was not the one that ran")
        // A later request still runs.
        ask(quick, "four")
        await quick.settled()
        #expect(cached(quick, "four") && cached(quick, "three"), "a later request did not run")

        // (a2) Three UNDELAYED requests in one turn: the first starts at once (round C4), the second is replaced by the third, which
        // runs when the first one's result is stored.
        let immediate = MarkdownParseCache()
        ask(immediate, "one")
        ask(immediate, "two")
        ask(immediate, "three")
        await immediate.settled()
        #expect(cached(immediate, "one") && cached(immediate, "three"), "the request that started at once or the newest one was lost")
        #expect(!cached(immediate, "two"), "the replaced request ran")

        // (b) Two requests made while one is running: the running one finishes, the older waiting one is replaced, the newest runs next.
        // The hook runs when the first parse is done and `isRunning` is still true, so the two requests arrive "while it runs", for sure.
        let overlapping = MarkdownParseCache()
        overlapping.testBeforeStore = {
            overlapping.testBeforeStore = nil
            #expect(overlapping.isRunning, "premise: the first request is still running when the hook runs")
            ask(overlapping, "two")
            ask(overlapping, "three")
        }
        ask(overlapping, "one")
        await overlapping.settled()
        #expect(cached(overlapping, "one") && cached(overlapping, "three"), "the running request or the newest one was lost")
        #expect(!cached(overlapping, "two"), "the replaced request ran")

        // (c) A request waiting out its delay is replaced by a newer one; a delayed request nobody replaces still runs.
        let delayed = MarkdownParseCache()
        ask(delayed, "slow", after: .seconds(120))
        ask(delayed, "now")
        await delayed.settled()
        #expect(cached(delayed, "now") && !cached(delayed, "slow"), "the delayed request was not replaced")
        ask(delayed, "later", after: .milliseconds(50))
        await delayed.settled()
        #expect(cached(delayed, "later"), "a delayed request did not run")
    }

    // MARK: - 13

    @Test("13: a fourth entry evicts the oldest; a lookup makes an entry the newest")
    func testLRUEvictsOldest() throws {
        func key(_ name: String) -> Key {
            Key(text: "text of \(name)", projectId: "p", notesTitle: nil, bibliographyHeaderName: "B", graceNames: [])
        }
        func texts(_ cache: MarkdownParseCache) -> [String] { cache.entries.map(\.key.text) }

        let plain = MarkdownParseCache()
        for name in ["one", "two", "three", "four"] { plain.store(key(name), blocks: [], endsOpen: false) }
        #expect(texts(plain) == ["text of two", "text of three", "text of four"], "the oldest entry was not evicted")

        let touched = MarkdownParseCache()
        for name in ["one", "two", "three"] { touched.store(key(name), blocks: [], endsOpen: false) }
        #expect(touched.lookup(key("one")) != nil)
        touched.store(key("four"), blocks: [], endsOpen: false)
        #expect(texts(touched) == ["text of three", "text of one", "text of four"], "the least recently USED entry was not the one evicted")

        touched.store(key("three"), blocks: [], endsOpen: false)   // the same key again replaces, it does not add
        #expect(texts(touched).count == 3 && texts(touched).last == "text of three")
    }

    // MARK: - 14

    @Test("14: a prepare that had to parse stores the result, so a second prepare of the same text hits")
    func testMissStoresEntryForNextPrepare() async throws {
        let rig = try MarkdownWriterRig(content: Self.article.markdown)
        let loaded = try rig.storedText()
        let typed = try Self.typedEdit(of: loaded, rows: try rig.rows())
        let cache = rig.markdownWriter.parseCache
        #expect(cache.entries.isEmpty, "premise: nothing was prepared in the background")

        underStableSettings { rig.fire(typed) }
        await rig.settle()
        #expect(rig.markdownWriter.lastTimingLine?.contains("cache=miss") == true, "got \(rig.markdownWriter.lastTimingLine ?? "nil")")
        #expect(cache.entries.count == 1 && cache.missCount == 1 && cache.hitCount == 0)

        underStableSettings { rig.fire(typed) }
        await rig.settle()
        #expect(rig.markdownWriter.lastTimingLine?.contains("cache=hit") == true, "the second prepare of the same text did not hit")
        #expect(cache.hitCount == 1 && cache.missCount == 1)
    }

    // MARK: - 15

    /// Three prepares of one text under three bibliography settings, in ONE synchronous window (`prepare` reads `ExportSettings.load()`
    /// itself): the counters after each. Restores the settings before it returns.
    private func prepareUnderSettings(_ rig: MarkdownWriterRig, text: String, headers: [String]) -> [(hits: Int, misses: Int)] {
        exportSettingsTestLock.lock()
        let previousStore = ExportSettings.userDefaults
        let suiteName = "MarkdownParseCacheTests.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            exportSettingsTestLock.unlock()
            return []
        }
        ExportSettings.userDefaults = suite
        defer {
            ExportSettings.userDefaults = previousStore
            suite.removePersistentDomain(forName: suiteName)
            exportSettingsTestLock.unlock()
        }
        let cache = rig.markdownWriter.parseCache
        return headers.map { header in
            var settings = ExportSettings.default
            settings.bibliographyHeaderName = header
            settings.save()
            rig.fire(text)
            return (cache.hitCount, cache.missCount)
        }
    }

    @Test("15: prepare keys the memo on the bibliography names it read: changing them between two prepares is a miss, not a stale hit")
    func testMissUsesExplicitBibliographyNames() async throws {
        let rig = try MarkdownWriterRig(content: Self.article.markdown)
        let loaded = try rig.storedText()
        let typed = try Self.typedEdit(of: loaded, rows: try rig.rows())

        let counts = prepareUnderSettings(rig, text: typed, headers: ["Works Cited", "References Cited", "References Cited"])
        await rig.settle()
        try #require(counts.count == 3, "the settings suite could not be created")
        #expect(counts[0].hits == 0 && counts[0].misses == 1, "the first prepare parses")
        #expect(counts[1].hits == 0 && counts[1].misses == 2, "a changed bibliography name was a stale hit")
        #expect(counts[2].hits == 1 && counts[2].misses == 2, "the same names a second time should hit")
        let names = rig.markdownWriter.parseCache.entries.map(\.key.bibliographyHeaderName)
        #expect(names == ["Works Cited", "References Cited"], "each entry is keyed by the names it was parsed with: \(names)")
    }
}
