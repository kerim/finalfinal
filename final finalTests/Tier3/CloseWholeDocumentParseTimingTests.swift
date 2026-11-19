//
//  CloseWholeDocumentParseTimingTests.swift
//  final finalTests
//
//  Tier 3: timing. t-124a342f ("measure how long closing a 100,000-word document takes").
//
//  WHAT THIS CHECKS. A close, quit or project switch saves the user's last typing as ONE whole-document write ("FB", step 6 of the
//  lifecycle save sequence, `EditorViewState.writeWholeDocumentForLifecycle`). Before it reserves a place in the write queue, FB turns the
//  editor's text into rows with `LifecycleWholeDocumentWrite.prepare`, which is `@MainActor` and runs `BlockParser.parse` over the WHOLE
//  document ("parse before reserve", so a slow parse never sits inside the writer's queue). That parse holds the main thread: the window
//  cannot repaint or take a key until it returns. On the small test documents it is instant; nobody had timed it on a book-length text.
//  The floor ("What every app owes its user", global CLAUDE.md, rule 3) says past about one second the app must show it is working, and
//  a main-thread parse cannot show anything while it runs, so one second is the line: more than that is a stall on every close of a
//  long book.
//
//  THE ENTRY POINT TIMED is the one the close calls, called the way it calls it (`EditorViewState+LifecycleFlush.swift`,
//  `writeWholeDocumentForLifecycle`): `LifecycleWholeDocumentWrite.prepare(content:database:projectId:zoomedRange:zoomedSectionId:
//  skipIfUnchanged:)` with the editor's text as native contiguous UTF-8 (`freshContentForLifecycle` makes it so), a not-zoomed close, the
//  checked-FB flag on (the Rich Text case, the common one), and a database that holds the project (the call reads the Notes heading
//  title from it). Markdown mode parses the same text through the same call.
//
//  THE DOCUMENT is generated in code (`ComplexDocumentFixture`, the deterministic generator of the book-length plan): 14 chapters of
//  headings, paragraphs, citations, footnotes with their `# Notes` section, annotation marks, Chinese sentences and a generated
//  bibliography with its end marker, as the editor holds it. 14 chapters are about 104,000 words and 818,000 characters. The markup
//  density is higher than ordinary prose, so the figure is a fair upper bound for a 100,000-word book.
//
//  HOW THE TIME IS TAKEN. Wall time (`ContinuousClock`) of each call, three runs, and the BEST is compared with the threshold, so a cold
//  start or a load blip on the host does not decide the verdict. All three times are always recorded: in the failure message, and, pass
//  or fail, on stdout and in `<worktree>/.claude/scratch/unit-out/close-timing.txt` (`UnitOutputFile`, the way the other measurement
//  tests of this project publish theirs; run output, never committed). This is a hosted unit test in the `DebugTest` configuration,
//  so unoptimised code: slower than the shipped app, which makes it a conservative check.
//
//  IF THE ASSERTION FAILS the close stalls the window for that long on a book-length project. Do not raise the threshold: the fix is to
//  move the parse off the main thread (a separate task), and this check should then be re-pointed at whatever still holds the main thread.
//
//  The second test only MEASURES. The close also scans the same text on the main thread at step 6b (the annotation parse) and step 7
//  (citation keys, footnote references). Those are not "the whole-document save", so they carry no threshold here; their times are
//  recorded beside the parse so a reader can see the main-thread total.
//

import Foundation
import Testing
@testable import final_final

@MainActor
@Suite("Close-time whole-document parse on a ~100,000-word book (t-124a342f)", .serialized)
struct CloseWholeDocumentParseTimingTests {

    // MARK: - The check's constants

    /// 14 chapters of `ComplexDocumentFixture` are about 104,000 words (13 are about 97,000, 12 about 90,000).
    private static let chapters = 14

    /// The most the main thread may be held by the close's parse, in milliseconds (the floor's "past one second").
    private static let thresholdMilliseconds = 1_000.0

    /// Timed runs of each call; the best one is the figure.
    private static let runs = 3

    /// Where the recorded lines go: `<worktree>/.claude/scratch/unit-out/close-timing.txt` (see `UnitOutputFile`).
    private static let outputName = "close-timing"

    // MARK: - Helpers

    private nonisolated static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// The text the close hands to the parse: the editor's markdown as native, contiguous UTF-8.
    private static func bookText() -> (content: String, words: Int) {
        let document = ComplexDocumentFixture.make(chapters: chapters)
        return (document.editorMarkdown.contiguousUTF8Copy, document.counts.words)
    }

    private struct Measured {
        /// Milliseconds of each run, in run order.
        let samples: [Double]
        /// What the last run returned (a row or hit count), kept so a test can check the call did real work.
        let result: Int

        var best: Double { samples.min() ?? .infinity }

        /// "470.2, 455.9, 449.1", the form used in every message and recorded line.
        var listed: String { samples.map { String(format: "%.1f", $0) }.joined(separator: ", ") }

        /// The best run in the same form, "449.1".
        var bestText: String { String(format: "%.1f", best) }
    }

    /// One recorded line for a measured scan: what it is, what it found, every run, the best in brackets.
    private static func scanLine(_ label: String, found: String, _ measured: Measured) -> String {
        "[CLOSE-TIMING] \(label) (\(measured.result) \(found)): \(measured.listed) [\(measured.bestText)]"
    }

    /// Runs `work` `runs` times (no untimed warm-up: the best-of takes care of a cold first run) and records each wall time.
    private static func measure(_ work: () -> Int) -> Measured {
        var samples: [Double] = []
        var result = 0
        for _ in 0..<runs {
            let started = ContinuousClock.now
            result = work()
            samples.append(milliseconds(ContinuousClock.now - started))
        }
        return Measured(samples: samples, result: result)
    }

    // MARK: - The check

    @Test("Closing a ~100,000-word book: the whole-document parse the close runs on the main thread takes under one second (best of 3)",
          .timeLimit(.minutes(2)))
    func closeParseOfAHundredThousandWordsStaysUnderOneSecond() throws {
        let book = Self.bookText()
        #expect(book.words >= 100_000, "the generated book must hold about 100,000 words (it holds \(book.words)); raise `chapters`")

        // The project the close would be saving: it holds the book, so the Notes heading title is read from a real row.
        let database = try TestFixtureFactory.createTemporary(content: book.content)
        let projectId = try TestFixtureFactory.getProjectId(from: database)

        let measured = Self.measure {
            let prepared = LifecycleWholeDocumentWrite.prepare(
                content: book.content, database: database, projectId: projectId,
                zoomedRange: nil, zoomedSectionId: nil, skipIfUnchanged: true)
            return prepared?.blocks.count ?? 0
        }

        UnitOutputFile.emit(Self.outputName, [
            "[CLOSE-TIMING] whole-document parse of a close (LifecycleWholeDocumentWrite.prepare -> BlockParser.parse, main thread), "
                + "DebugTest build, host machine",
            "[CLOSE-TIMING] book: \(Self.chapters) chapters, \(book.words) words, \(book.content.utf8.count) UTF-8 bytes, "
                + "\(measured.result) rows after the parse",
            "[CLOSE-TIMING] parse runs in ms: \(measured.listed); best \(measured.bestText); "
                + "threshold \(Int(Self.thresholdMilliseconds))"
        ])

        #expect(measured.result >= 1_000, "the parse must have produced the book's rows (got \(measured.result)); it timed nothing real")
        let stall = "closing a \(book.words)-word book holds the main thread in LifecycleWholeDocumentWrite.prepare (BlockParser.parse) for "
            + "\(measured.bestText) ms at best (runs: \(measured.listed) ms); the line is \(Int(Self.thresholdMilliseconds)) ms. "
            + "That is a stall on every close of a long book: open a bug to move the parse off the main thread, "
            + "do not raise this number."
        #expect(measured.best < Self.thresholdMilliseconds, Comment(rawValue: stall))
    }

    // MARK: - Measurement only

    @Test("Measurement only: the other whole-text scans a close runs on the main thread (annotations, citations, footnotes), same book",
          .timeLimit(.minutes(2)))
    func otherCloseScansAreMeasured() {
        let book = Self.bookText()
        let annotations = AnnotationSyncService()

        // Step 6b (`annotationSyncService?.syncNow`): the annotation parse runs on the main actor.
        let annotationScan = Self.measure { annotations.parseAnnotations(from: book.content).count }
        // Step 7 (`rederiveForLifecycle`): both scans run on the main actor over the fresh text, and so does the emptiness test.
        let citationScan = Self.measure { BibliographySyncService.extractCitekeys(from: book.content).count }
        let footnoteScan = Self.measure { FootnoteSyncService.extractFootnoteRefs(from: book.content).count }
        let emptinessTest = Self.measure { book.content.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count }

        UnitOutputFile.emit(Self.outputName, [
            "[CLOSE-TIMING] the other main-thread whole-text scans of a close, same book (\(book.words) words), runs in ms, best in brackets",
            Self.scanLine("step 6b annotation parse", found: "marks", annotationScan),
            Self.scanLine("step 7 citation keys", found: "keys", citationScan),
            Self.scanLine("step 7 footnote references", found: "refs", footnoteScan),
            Self.scanLine("step 7 emptiness test (trim)", found: "UTF-8 bytes kept", emptinessTest)
        ])

        // No timing assertion: these are not the whole-document save. The counts only prove each scan read the text and did real work.
        #expect(annotationScan.result > 0, "the annotation scan found no marks in a book full of them")
        #expect(citationScan.result > 0, "the citation scan found no keys in a book full of citations")
        #expect(footnoteScan.result > 0, "the footnote scan found no references in a book full of footnotes")
        #expect(emptinessTest.result > 0, "the trim must leave the text")
    }
}
