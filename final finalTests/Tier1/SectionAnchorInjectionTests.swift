//
//  SectionAnchorInjectionTests.swift
//  final finalTests
//
//  Step 4a of the book-length switch plan (plan-book-length-switch.md): the section anchors the switch to Markdown writes
//  into the editor text (`SectionSyncService.injectSectionAnchors`), which a coder will rewrite as a single pass.
//
//  WHY. Today the function walks the sections from the end of the text, and for EVERY heading does `result.count` (a walk
//  over the whole text), `index(offsetBy:)` (another walk) and `insert` (a copy of the tail): quadratic by construction. In the
//  VM runs `toMd.anchors` is 153 ms at BOOK-6 and 769 ms at BOOK-12, five times for twice the text. Step 4a does it in one
//  pass; a wrong anchor, even one character off, would break the outline's link to a heading in Markdown mode.
//
//  THIS FILE passes on today's code and is the guard for the rewrite:
//    - `referenceInject` is the old loop, copied here and kept as the reference. The production function must return the
//      same text for the x1 and x6 documents (all sections), for a subset of the sections (the zoomed switch only injects
//      the zoomed sections), for one section at offset 0, for one section past the end of the text (clamped to the end), and
//      for no sections at all. Two sections at the SAME offset, or two past the end, are deliberately not tested: the plan
//      accepts that their order may differ from today's (no user-level trigger).
//    - `extractSectionAnchors(injectSectionAnchors(x))` returns x, and the anchors it finds are the sections that were injected.
//    - `[ANCHORS]` lines print the time of the production function (and of `injectBibliographyMarker`, which the plan changes
//      only if it turns out worse than linear) at x1, x6 and x12 with the x6/x1 and x12/x6 ratios. The driver's first unit run
//      (U1) records today's figures; the run after the rewrite (U4) must show identical output and linear times.
//
//  The sections and offsets come from `ComplexDocumentFixture.switchInputs`, which builds them the way `handleEditorModeToggle`
//  does (character offsets into the text the editor holds). Timings are Debug-build host figures, noisy when other suites run at
//  the same time; the test asserts nothing about a duration.
//

import Foundation
import Testing
@testable import final_final

@Suite("Section anchor injection (book-length plan, step 4a)", .serialized)
struct SectionAnchorInjectionTests {

    // MARK: - The reference (today's loop, kept verbatim)

    /// `injectSectionAnchors` as it was before step 4a: sections from the end, one `count`, one `index(offsetBy:)` and one `insert` each.
    private func referenceInject(markdown: String, sections: [SectionViewModel]) -> String {
        guard !sections.isEmpty else { return markdown }
        var result = markdown
        let sortedSections = sections.sorted { $0.startOffset > $1.startOffset }
        for section in sortedSections {
            let offset = min(section.startOffset, result.count)
            let insertionIndex = result.index(result.startIndex, offsetBy: offset)
            let anchor = "<!-- @sid:\(section.id) -->"
            result.insert(contentsOf: anchor, at: insertionIndex)
        }
        return result
    }

    private func firstDifference(_ left: String, _ right: String) -> String {
        let leftUnits = Array(left.utf16)
        let rightUnits = Array(right.utf16)
        var index = 0
        let common = min(leftUnits.count, rightUnits.count)
        while index < common, leftUnits[index] == rightUnits[index] { index += 1 }
        let from = max(0, index - 30)
        func context(_ units: [UInt16]) -> String { String(decoding: units[from..<min(units.count, index + 60)], as: UTF16.self).debugDescription }
        return "lengths \(leftUnits.count) and \(rightUnits.count), first difference at offset \(index): "
            + "\(context(leftUnits)) vs \(context(rightUnits))"
    }

    @MainActor
    private func expectSameAsReference(_ label: String, content: String, sections: [SectionViewModel], service: SectionSyncService) {
        let expected = referenceInject(markdown: content, sections: sections)
        let actual = service.injectSectionAnchors(markdown: content, sections: sections)
        #expect(
            actual == expected,
            "\(label): injectSectionAnchors must return exactly what the reference loop returns (\(firstDifference(expected, actual)))")
    }

    // MARK: - Same output as the reference

    @MainActor
    private func checkSameOutput(_ label: String, _ document: ComplexDocumentFixture.Document) {
        let inputs = ComplexDocumentFixture.switchInputs(for: document)
        let content = inputs.content
        let sections = inputs.adjustedSections
        let service = SectionSyncService()
        #expect(sections.count >= 18, "\(label): the fixture must have its headings as sections (\(sections.count))")

        // All sections: the ordinary switch.
        expectSameAsReference("\(label), all \(sections.count) sections", content: content, sections: sections, service: service)

        // A subset: the zoomed switch only injects the zoomed sections (here every third one, and one contiguous run).
        let everyThird = sections.enumerated().filter { $0.offset % 3 == 0 }.map(\.element)
        expectSameAsReference("\(label), every third section", content: content, sections: everyThird, service: service)
        let run = Array(sections[min(5, sections.count - 1)..<min(12, sections.count)])
        expectSameAsReference("\(label), a run of \(run.count) sections", content: content, sections: run, service: service)

        // Offset 0: the first section at the very start of the text.
        if let first = sections.first {
            #expect(first.startOffset == 0, "\(label): the first section starts at offset 0")
            expectSameAsReference("\(label), one section at offset 0", content: content, sections: [first], service: service)
            let injected = service.injectSectionAnchors(markdown: content, sections: [first])
            #expect(injected.hasPrefix("<!-- @sid:\(first.id) -->"), "\(label): an offset-0 anchor is the first thing in the text")
        }

        // An offset past the end (a stale offset after a shorter flush): clamped to the end, exactly one anchor there.
        if let last = sections.last {
            let pastEnd = last.withUpdates(startOffset: content.count + 50)
            expectSameAsReference("\(label), one section past the end", content: content, sections: [pastEnd], service: service)
            let injected = service.injectSectionAnchors(markdown: content, sections: [pastEnd])
            #expect(injected == content + "<!-- @sid:\(pastEnd.id) -->", "\(label): a past-the-end anchor lands at the very end")
            let withOthers = Array(sections.dropLast()) + [pastEnd]
            expectSameAsReference("\(label), all sections with the last one past the end", content: content, sections: withOthers, service: service)
        }

        // No sections: the text comes back untouched.
        #expect(service.injectSectionAnchors(markdown: content, sections: []) == content, "\(label): no sections, no change")

        // Extracting what was injected gives the original text and the injected sections.
        let injected = service.injectSectionAnchors(markdown: content, sections: sections)
        let (cleaned, anchors) = service.extractSectionAnchors(markdown: injected)
        #expect(cleaned == content, "\(label): extractSectionAnchors(injectSectionAnchors(x)) must return x (\(firstDifference(content, cleaned)))")
        #expect(Set(anchors.map(\.sectionId)) == Set(sections.map(\.id)), "\(label): the anchors found are exactly the sections injected")
        #expect(anchors.count == sections.count, "\(label): one anchor per section")
        let offsetsByAnchor = Dictionary(uniqueKeysWithValues: anchors.map { ($0.sectionId, $0.headerOffset) })
        for section in sections {
            #expect(
                offsetsByAnchor[section.id] == section.startOffset,
                "\(label): the anchor of \(section.id) is found at the section's own offset in the clean text")
        }
    }

    @Test("x1: the production function returns what the reference loop returns, and extraction undoes it")
    @MainActor
    func sameOutputX1() {
        checkSameOutput("x1", ComplexDocumentFixture.article)
    }

    @Test("x6: the production function returns what the reference loop returns, and extraction undoes it")
    @MainActor
    func sameOutputX6() {
        checkSameOutput("x6", ComplexDocumentFixture.book6)
    }

    // MARK: - Timings

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// The median of `repetitions` timed runs, in milliseconds (after one untimed warm-up when `repetitions` > 1).
    private static func medianTime(_ repetitions: Int, _ work: () -> Void) -> Double {
        if repetitions > 1 { work() }
        var samples: [Double] = []
        for _ in 0..<repetitions { samples.append(milliseconds(ContinuousClock().measure(work))) }
        samples.sort()
        return samples[samples.count / 2]
    }

    private struct TimedSize {
        let label: String
        let document: ComplexDocumentFixture.Document
        let repetitions: Int
    }

    @Test("Timing: injectSectionAnchors and injectBibliographyMarker at x1, x6 and x12 (printed; x12 also checked against the reference)")
    @MainActor
    func timings() {
        var report: [String] = []
        let service = SectionSyncService()
        let entries = [
            TimedSize(label: "x1", document: ComplexDocumentFixture.article, repetitions: 5),
            TimedSize(label: "x6", document: ComplexDocumentFixture.book6, repetitions: 3),
            TimedSize(label: "x12", document: ComplexDocumentFixture.book12, repetitions: 3)
        ]
        var anchorTimes: [String: Double] = [:]
        var markerTimes: [String: Double] = [:]
        var lines: [String] = []
        var sink = 0
        for entry in entries {
            let inputs = ComplexDocumentFixture.switchInputs(for: entry.document)
            let content = inputs.content
            anchorTimes[entry.label] = Self.medianTime(entry.repetitions) {
                sink &+= service.injectSectionAnchors(markdown: content, sections: inputs.adjustedSections).count
            }
            let withAnchors = service.injectSectionAnchors(markdown: content, sections: inputs.adjustedSections)
            markerTimes[entry.label] = Self.medianTime(entry.repetitions) {
                sink &+= service.injectBibliographyMarker(markdown: withAnchors, sections: inputs.sectionsToInject).count
            }
            let reference = referenceInject(markdown: content, sections: inputs.adjustedSections)
            #expect(
                withAnchors == reference,
                "\(entry.label): the production function must return what the reference loop returns (\(firstDifference(reference, withAnchors)))")
            lines.append("[ANCHORS] \(entry.label): \(content.count) characters, \(inputs.adjustedSections.count) sections")
        }
        func ratio(_ high: String, _ low: String, _ times: [String: Double]) -> String {
            guard let high = times[high], let low = times[low], low > 0 else { return "-" }
            return String(format: "%.2f", high / low)
        }
        report.append(
            "[ANCHORS] section anchors, Debug build, host machine; median milliseconds (x1: 5, x6 and x12: 3 repetitions); "
                + "other tests may be running")
        report += lines
        for (name, times) in [("injectSectionAnchors", anchorTimes), ("injectBibliographyMarker", markerTimes)] {
            let cells = entries.map { String(format: "%@ %.1f ms", $0.label, times[$0.label] ?? 0) }.joined(separator: ", ")
            report.append(
                "[ANCHORS] \(name): \(cells); x6/x1 \(ratio("x6", "x1", times)), x12/x6 \(ratio("x12", "x6", times)) (linear would be about 6 and 2)")
        }
        report.append(
            "[ANCHORS] the VM runs measured `toMd.anchors` (both functions together): 153 ms at BOOK-6, 769 ms at BOOK-12; "
                + "the plan's marks are at most 15 ms and 30 ms")
        UnitOutputFile.emit("anchors", report)
        #expect(sink != -1)
    }
}
