//
//  BlockParserScalingTests.swift
//  final finalTests
//
//  Step 2a-i of the book-length switch plan (plan-book-length-switch.md): how long `BlockParser.parse` takes at one, six and
//  twelve chapters, and in which of its parts, plus the golden rows that a later speed-up of the parser must reproduce exactly.
//  NO parser change is made or assumed here.
//
//  WHY. Every Rich Text <-> Markdown switch re-parses the whole document on the main thread (`flush.parse`: 388 ms at BOOK-6 and
//  about 1,100 ms at BOOK-12 in the VM runs, growing faster than the text). Step 2a-ii makes the parse fast without changing what
//  it returns. Coders cannot run the Swift tests, so this step only MEASURES; the driver runs it once (U1), reads the table, and
//  sets the pass marks (host mark for x6 and x12, the x12 / x6 ratio, the VM mark for `flush.parse`) before 2a-ii starts.
//
//  THE TABLE (lines starting `[SCALING]`). One row per part of `parse`, timed on its own over the same raw blocks the whole
//  parse sees, as median [best] milliseconds of several repetitions, for the x1, x6 and x12 documents of
//  `ComplexDocumentFixture` (the text the VM runs use, with the generated bibliography and its end marker). `parse` repeats some
//  parts on purpose-built copies of the same data: it trims every raw block three times and runs `detectBlockType` on every block
//  three times (the bibliography pre-scan, the Notes pre-scan and the main loop each do their own), so the table gives the cost of
//  ONE pass and the number of passes per parse, then the cost those passes add up to. "Everything else" is the whole parse minus
//  those sums: the loop itself, flag carry-forward, ids (a UUID per block), section-metadata lookups. Two pre-scans are private to
//  `BlockParser`; the test rebuilds their inputs from the same public pieces the private functions call (the unit lists are the
//  ones `selectBibliographyOpeningIndex` and `selectNotesOpeningIndices` build), so a number here is that part's cost, not a
//  re-implementation of what the part decides.
//
//  WHAT THE PASSES MEAN NOW. Step 2a-ii changed the parser: it trims and classifies every raw block ONCE and shares the result
//  between the bibliography pre-scan, the Notes pre-scan and the main loop (before, each of the three did its own trim and its own
//  `detectBlockType`: three passes), the bibliography pre-scan no longer calls `isBibliographyHeading` per block (a marker test
//  plus a lookup of the block in the set of title lines), and the main loop asks `isSectionBreakMarker(ofTrimmed:)`. The table
//  times those, so its "passes" column is 1 for every part and "sum of the parts" is the work the parse really does. Two things it
//  leaves out because they are rare or tiny: a block whose bibliography marker is stripped is classified a second time, and the
//  `isNotesHeading` test per block (a prefix check). Figures quoted earlier in the notes (three passes) were measured before this.
//  Noise: this is a hosted unit test in a Debug build, and other test suites may run at the same time. The best-of figure is the
//  robust one; re-run the suite alone for quiet numbers.
//
//  THE GOLDEN ROWS. `parse` of the x1 and x6 editor text, every field of every row EXCEPT ids and timestamps (id, createdAt,
//  updatedAt), one JSON object per line with sorted keys, in `final finalTests/Fixtures/BlockParserGolden/x1.json` and `x6.json`.
//  Located from `#filePath` (like the committed-fixture generator). The parse must reproduce the file exactly, and a mismatch names
//  the first differing row. A MISSING file is a test FAILURE, not something the test repairs: a test that writes its own expected
//  values when they are gone passes against whatever the parser returns that day, so the rows would pin nothing. Writing happens only
//  on purpose: delete the file, then run the suite once with `FF_REGENERATE_PARSER_GOLDEN=1` in the test process's environment
//  (through xcodebuild: `TEST_RUNNER_FF_REGENERATE_PARSER_GOLDEN=1`). Do that only to deliberately accept a changed parser output,
//  and say so; never to make a failing run pass. Commit the two files with the plan's changes.
//
//  Expected on today's code: both tests pass (the golden files are committed); the scaling table is the product.
//

import Foundation
import Testing
@testable import final_final

@Suite("BlockParser scaling and golden rows (book-length plan, step 2a-i)", .serialized)
struct BlockParserScalingTests {

    // MARK: - The document sizes

    private struct SizeEntry {
        let label: String
        let document: ComplexDocumentFixture.Document
        let repetitions: Int
        let expectedRows: Int
    }

    private static let sizes: [SizeEntry] = [
        SizeEntry(label: "x1", document: ComplexDocumentFixture.article, repetitions: 7, expectedRows: 138),
        SizeEntry(label: "x6", document: ComplexDocumentFixture.book6, repetitions: 5, expectedRows: 573),
        SizeEntry(label: "x12", document: ComplexDocumentFixture.book12, repetitions: 3, expectedRows: 1095)
    ]

    // MARK: - Golden rows

    /// One JSON line per row: every field except the ids and timestamps, keys sorted. `endsBibliographyRun` is a transient parse output
    /// (never persisted, so absent from the coding keys) that `replaceBlocks` reads; it is added by hand.
    private static func goldenLines(for blocks: [Block]) throws -> [String] {
        let encoder = JSONEncoder()
        return try blocks.map { block in
            let data = try encoder.encode(block)
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.coderReadCorrupt)
            }
            for key in ["id", "createdAt", "updatedAt"] { object.removeValue(forKey: key) }
            object["endsBibliographyRun"] = block.endsBibliographyRun
            let line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            return String(bytes: line, encoding: .utf8) ?? ""
        }
    }

    /// Environment variable that lets a run WRITE a missing golden file. Unset (the normal case), a missing file fails the test.
    private static let regenerateVariable = "FF_REGENERATE_PARSER_GOLDEN"

    private static func goldenURL(_ label: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tier1
            .deletingLastPathComponent()   // final finalTests
            .appendingPathComponent("Fixtures/BlockParserGolden/\(label).json")
    }

    private func checkGolden(_ entry: SizeEntry) throws {
        let blocks = ComplexDocumentFixture.parse(entry.document.editorMarkdown)
        #expect(
            blocks.count == entry.expectedRows,
            "the \(entry.label) fixture must parse to the \(entry.expectedRows) rows the VM runs stored (text blocks plus the 36 bibliography rows)")
        let lines = try Self.goldenLines(for: blocks)
        let text = "[\n" + lines.joined(separator: ",\n") + "\n]\n"
        let url = Self.goldenURL(entry.label)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard ProcessInfo.processInfo.environment[Self.regenerateVariable] == "1" else {
                let missing: [String] = [
                    "the golden rows file \(url.lastPathComponent) is missing (\(url.path)).",
                    "A missing file is a failure: the rows pin nothing without it.",
                    "Recover it from version control (it is committed with the change that added it).",
                    "Writing it anew records whatever the CURRENT parser returns, so do that only to accept a deliberately changed parser output:",
                    "run this suite once with \(Self.regenerateVariable)=1 in the test process's environment",
                    "(xcodebuild: TEST_RUNNER_\(Self.regenerateVariable)=1)."
                ]
                let message = missing.joined(separator: " ")
                Issue.record("\(message)")
                return
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            let wrote = "WROTE \(lines.count) rows (\(text.utf8.count) bytes) to \(url.path)"
            let why = "file was absent and \(Self.regenerateVariable)=1 was set"
            UnitOutputFile.emit("scaling", ["[SCALING] golden rows \(entry.label): \(why), \(wrote)"])
            return
        }
        let stored = try String(contentsOf: url, encoding: .utf8)
        if stored == text {
            UnitOutputFile.emit("scaling", ["[SCALING] golden rows \(entry.label): \(lines.count) rows identical to \(url.lastPathComponent)"])
            return
        }
        let storedLines = stored.components(separatedBy: "\n")
        let currentLines = text.components(separatedBy: "\n")
        let firstDifferingLine = zip(storedLines, currentLines).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        let index = firstDifferingLine ?? min(storedLines.count, currentLines.count)
        let storedRow = index < storedLines.count ? String(storedLines[index].prefix(400)) : "(no such line)"
        let currentRow = index < currentLines.count ? String(currentLines[index].prefix(400)) : "(no such line)"
        let location = "at line \(index + 1) (stored \(storedLines.count) lines, now \(currentLines.count))"
        let header = "the parse of \(entry.label) differs from the golden rows in \(url.lastPathComponent) \(location)."
        Issue.record("\(header)\n  golden: \(storedRow)\n  now:    \(currentRow)")
    }

    @Test("Golden rows: the x1 editor text parses to exactly the rows in Fixtures/BlockParserGolden/x1.json (a missing file fails)")
    func goldenRowsX1() throws {
        try checkGolden(Self.sizes[0])
    }

    @Test("Golden rows: the x6 editor text parses to exactly the rows in Fixtures/BlockParserGolden/x6.json (a missing file fails)")
    func goldenRowsX6() throws {
        try checkGolden(Self.sizes[1])
    }

    // MARK: - Timing

    private struct Timing {
        let median: Double
        let best: Double
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// Runs `work` `repetitions` times (after one untimed warm-up) and returns the median and the best time in milliseconds.
    private static func time(_ repetitions: Int, _ work: () -> Void) -> Timing {
        work()
        var samples: [Double] = []
        for _ in 0..<repetitions { samples.append(milliseconds(ContinuousClock().measure(work))) }
        samples.sort()
        return Timing(median: samples[samples.count / 2], best: samples[0])
    }

    private struct PartRow {
        let name: String
        let passes: Int
        var timings: [String: Timing] = [:]
    }

    /// One document's part timings plus the whole parse, by size label.
    private static func measure(_ entry: SizeEntry, into rows: inout [PartRow], total: inout [String: Timing]) {
        let markdown = entry.document.editorMarkdown
        let label = entry.label
        let reps = entry.repetitions
        var sink = 0

        // The data every part works on, built once and untimed.
        let raw = BlockParser.splitIntoRawBlocks(markdown)
        let trimmed = raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let types = trimmed.map { BlockParser.detectBlockType($0) }
        let texts = zip(trimmed, types).map { BlockParser.extractTextContent(from: $0.0, blockType: $0.1.0) }
        let bibliographyUnits = trimmed.enumerated().map { index, text in
            BibliographyOpeningSelector.Unit(
                isMarker: BlockParser.hasBibliographyMarker(text),
                isTerminator: text == BlockParser.bibliographyEndMarker,
                isCandidate: text != BlockParser.bibliographyStartMarker
                    && BlockParser.isBibliographyHeading(text, bibliographyHeaderName: "Bibliography", graceNames: []),
                isHeading: types[index].0 == .heading,
                isEmpty: text.isEmpty,
                isStandaloneMarker: text == BlockParser.bibliographyStartMarker)
        }
        let notesUnits = trimmed.enumerated().map { index, text in
            NotesOpeningSelector.Unit(
                isCandidateHeading: BlockParser.isNotesHeading(text, notesHeaderName: "Notes"),
                isAnyHeading: types[index].0 == .heading,
                isEvidence: FootnoteSyncService.parseNotesLabel(from: text) != nil)
        }

        func record(_ index: Int, _ timing: Timing) { rows[index].timings[label] = timing }

        record(0, time(reps) { sink &+= BlockParser.splitIntoRawBlocks(markdown).count })
        record(1, time(reps) { sink &+= raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.count })
        record(2, time(reps) { for text in trimmed { sink &+= BlockParser.detectBlockType(text).0 == .heading ? 1 : 0 } })
        // What the parse's bibliography pre-scan asks of each block since 2a-ii: the marker test, and (only for text that starts with
        // "#") a lookup in the set of `# T` / `## T` lines for the two built-in titles and the configured name (here the default,
        // "Bibliography"). `isBibliographyHeading` is no longer called per block.
        let titleLines = Set(["References", "Bibliography"].flatMap { ["# \($0)", "## \($0)"] })
        record(3, time(reps) {
            for text in trimmed {
                sink &+= (BlockParser.hasBibliographyMarker(text) || (text.hasPrefix("#") && titleLines.contains(text))) ? 1 : 0
            }
        })
        record(4, time(reps) { if case .candidate = BibliographyOpeningSelector.select(bibliographyUnits) { sink &+= 1 } })
        record(5, time(reps) {
            for text in trimmed { sink &+= FootnoteSyncService.parseNotesLabel(from: text) == nil ? 0 : 1 }
        })
        record(6, time(reps) { sink &+= NotesOpeningSelector.select(notesUnits).count })
        record(7, time(reps) {
            for (text, type) in zip(trimmed, types) { sink &+= BlockParser.extractTextContent(from: text, blockType: type.0).count }
        })
        record(8, time(reps) {
            for (text, type) in zip(trimmed, types) { sink &+= BlockParser.imageMetadata(for: text, blockType: type.0).width ?? 0 }
        })
        record(9, time(reps) { for text in trimmed { sink &+= BlockParser.isSectionBreakMarker(ofTrimmed: text) ? 1 : 0 } })
        record(10, time(reps) {
            var order = 1.0
            for (index, text) in trimmed.enumerated() {
                var block = Block(
                    projectId: "scaling", sortOrder: order, blockType: types[index].0, textContent: texts[index],
                    markdownFragment: text, headingLevel: types[index].1)
                block.recalculateWordCount()
                sink &+= block.wordCount
                order += 1
            }
        })
        total[label] = time(reps) {
            sink &+= BlockParser.parse(
                markdown: markdown, projectId: "scaling", bibliographyHeaderName: "Bibliography", graceNames: [], notesHeaderName: "Notes").count
        }
        #expect(sink != -1)
    }

    @Test("Scaling table: BlockParser.parse and its parts at x1, x6 and x12 (printed; no parser change)")
    func scalingTable() {
        var report: [String] = []
        var rows = [
            PartRow(name: "split into raw blocks", passes: 1),
            PartRow(name: "trim every raw block", passes: 1),
            PartRow(name: "detectBlockType on every block", passes: 1),
            PartRow(name: "bibliography candidate test (marker test + title-line lookup)", passes: 1),
            PartRow(name: "bibliography selector (select over the units)", passes: 1),
            PartRow(name: "Notes evidence (parseNotesLabel, one regex per block)", passes: 1),
            PartRow(name: "Notes selector (select over the units)", passes: 1),
            PartRow(name: "text extraction (extractTextContent)", passes: 1),
            PartRow(name: "image metadata (imageMetadata)", passes: 1),
            PartRow(name: "section-break test (isSectionBreakMarker(ofTrimmed:))", passes: 1),
            PartRow(name: "Block creation (UUID) + word count", passes: 1)
        ]
        var totals: [String: Timing] = [:]
        for entry in Self.sizes { Self.measure(entry, into: &rows, total: &totals) }

        func cell(_ timing: Timing?) -> String {
            timing.map { String(format: "%7.1f [%6.1f]", $0.median, $0.best) } ?? "-"
        }
        func ratio(_ high: Double?, _ low: Double?) -> String {
            guard let high, let low, low > 0 else { return "-" }
            return String(format: "%.2f", high / low)
        }
        func pad(_ text: String, _ width: Int) -> String { text.count >= width ? text : text + String(repeating: " ", count: width - text.count) }
        let labels = Self.sizes.map(\.label)
        let repetitions = Self.sizes.map { "\($0.label): \($0.repetitions)" }.joined(separator: ", ")
        report.append(
            "[SCALING] BlockParser.parse and its parts, Debug build, host machine; median [best] milliseconds over \(repetitions) repetitions;")
        report.append("[SCALING] other tests may be running at the same time (re-run this suite alone for quiet figures)")
        for entry in Self.sizes {
            report.append("[SCALING] \(entry.label): \(entry.document.counts.summary); \(entry.expectedRows) rows after parse")
        }
        report.append("[SCALING] " + pad("part (cost of ONE pass)", 66) + pad("passes", 8) + labels.map { pad($0, 18) }.joined()
            + "x6/x1  x12/x6 (medians of one pass)")
        var summed: [String: Double] = [:]
        for row in rows {
            let cells = labels.map { pad(cell(row.timings[$0]), 18) }.joined()
            report.append("[SCALING] " + pad(row.name, 66) + pad(String(row.passes), 8) + cells
                + pad(ratio(row.timings["x6"]?.median, row.timings["x1"]?.median), 7) + ratio(row.timings["x12"]?.median, row.timings["x6"]?.median))
            for label in labels { summed[label, default: 0] += (row.timings[label]?.median ?? 0) * Double(row.passes) }
        }
        report.append("[SCALING] " + pad("sum of the parts, each times its passes", 74)
            + labels.map { pad(String(format: "%7.1f", summed[$0] ?? 0), 18) }.joined()
            + pad(ratio(summed["x6"], summed["x1"]), 7) + ratio(summed["x12"], summed["x6"]))
        report.append("[SCALING] " + pad("everything else (loop, flags, metadata lookups): total minus sum", 74)
            + labels.map { pad(String(format: "%7.1f", (totals[$0]?.median ?? 0) - (summed[$0] ?? 0)), 18) }.joined())
        report.append("[SCALING] " + pad("WHOLE parse", 74) + labels.map { pad(cell(totals[$0]), 18) }.joined()
            + pad(ratio(totals["x6"]?.median, totals["x1"]?.median), 7) + ratio(totals["x12"]?.median, totals["x6"]?.median))
        report.append("[SCALING] reading it: x6/x1 and x12/x6 near 6 and 2 mean linear growth; the plan's mark for x12/x6 is at most 2.3.")
        report.append("[SCALING] the VM figure to compare with is flush.parse (388 ms at BOOK-6, about 1,100 ms at BOOK-12).")

        UnitOutputFile.emit("scaling", report)

        // Sanity only: a measurement run, nothing asserted on a duration.
        #expect(totals.count == Self.sizes.count)
    }
}
