//
//  LifecycleFBCheckTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  t-94369a83 Phase 3a-2, Step 3 (plan-v2 U-C1, "checked FB", Option A per the user's decision). FB, the queued
//  whole-document save a close, switch or quit takes, now compares the rows it would write with the stored rows
//  inside its own transaction and writes NOTHING when they are identical (`.unchanged`: no row touched, no epoch
//  bump). This file pins the comparison itself, as pure tables over `Block` values
//  (`LifecycleWholeDocumentWrite.rowsMatch`, `hasNearTie`), and the body's three verdicts over a real database.
//
//  What the comparison reads is what a REOPEN reads: block type, heading level (headings only), the fragment
//  trimmed of whitespace on both sides, the bibliography / Notes / section-break flags, in the order a reopen
//  sorts them, with empty-fragment rows dropped on both sides. Ids and `sortOrder` NUMBERS are not compared,
//  except through the separate near-tie rule: FB is the only thing that renumbers `sortOrder`, and the per-edit
//  insert path halves gaps (D2). Several rows below are PINS of a deliberate non-match (the two editor
//  serializers write lists and bibliography text differently, D1/D5): they say "FB still runs there, as today",
//  and the comparison must NOT be loosened to make them match.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Checked FB: the row comparison — Tier 1: Silent Killers")
struct LifecycleFBCheckTests {

    private static let pid = "p"

    private func row(
        _ type: BlockType, _ fragment: String, sort: Double, level: Int? = nil,
        bibliography: Bool = false, notes: Bool = false, pseudo: Bool = false, text: String? = nil
    ) -> Block {
        Block(
            projectId: Self.pid, sortOrder: sort, blockType: type, textContent: text ?? fragment, markdownFragment: fragment,
            headingLevel: level, isBibliography: bibliography, isNotes: notes, isPseudoSection: pseudo)
    }

    /// A small document: heading, paragraph, heading, paragraph.
    private func document(sortStart: Double = 0) -> [Block] {
        [
            row(.heading, "# Alpha", sort: sortStart, level: 1),
            row(.paragraph, "one two three.", sort: sortStart + 1),
            row(.heading, "# Beta", sort: sortStart + 2, level: 1),
            row(.paragraph, "four five six.", sort: sortStart + 3)
        ]
    }

    private func match(_ stored: [Block], _ wouldWrite: [Block]) -> Bool {
        LifecycleWholeDocumentWrite.rowsMatch(stored: stored, wouldWrite: wouldWrite)
    }

    // MARK: - U-C1 table

    @Test("(a) equal documents match, whatever the sortOrder numbers are")
    func equalDocumentsMatch() {
        #expect(match(document(), document()))
        #expect(match(document(sortStart: 100), document()), "sortOrder numbers are not compared")
    }

    @Test("(b) a paragraph row against a list row does not match")
    func paragraphVersusListDoesNotMatch() {
        var wouldWrite = document()
        wouldWrite[1] = row(.bulletList, "one two three.", sort: 1)
        #expect(!match(document(), wouldWrite))
    }

    @Test("(c) swapped order does not match")
    func swappedOrderDoesNotMatch() {
        var swapped = document()
        swapped.swapAt(1, 3)
        #expect(!match(document(), swapped))
    }

    @Test("(d) a missing row does not match, either way round")
    func missingRowDoesNotMatch() {
        var fewer = document()
        fewer.remove(at: 3)
        #expect(!match(document(), fewer))
        #expect(!match(fewer, document()))
    }

    @Test("(e) a doubled row does not match")
    func doubledRowDoesNotMatch() {
        var doubled = document()
        doubled.insert(row(.paragraph, "one two three.", sort: 1.5), at: 2)
        #expect(!match(document(), doubled))
        #expect(!match(doubled, document()))
    }

    @Test("(f) a changed isNotes flag does not match")
    func changedIsNotesDoesNotMatch() {
        var flagged = document()
        flagged[3] = row(.paragraph, "four five six.", sort: 3, notes: true)
        #expect(!match(document(), flagged))
    }

    @Test("(g) a changed heading level does not match; a stray level on a paragraph is not compared")
    func changedHeadingLevelDoesNotMatch() {
        var deeper = document()
        deeper[2] = row(.heading, "# Beta", sort: 2, level: 2)
        #expect(!match(document(), deeper))
        var strayLevel = document()
        strayLevel[1] = row(.paragraph, "one two three.", sort: 1, level: 3)
        #expect(match(document(), strayLevel), "the heading level is compared for headings only")
    }

    @Test("a changed bibliography flag or section-break flag does not match")
    func changedBibliographyOrPseudoSectionDoesNotMatch() {
        var bibliography = document()
        bibliography[3] = row(.paragraph, "four five six.", sort: 3, bibliography: true)
        #expect(!match(document(), bibliography))
        var pseudo = document()
        pseudo[1] = row(.sectionBreak, "one two three.", sort: 1, pseudo: true)
        #expect(!match(document(), pseudo))
    }

    @Test("(h) PIN, D1/D13: the same list as `- x` (per-block serializer) against `* x` (whole-document serializer) does NOT match")
    func bulletMarkerDifferenceDoesNotMatch() {
        let stored = [row(.bulletList, "- listword", sort: 0)]
        let wouldWrite = [row(.bulletList, "* listword", sort: 0)]
        #expect(!match(stored, wouldWrite), "FB still runs after a list edit: the serializers differ. Do not loosen this.")
    }

    @Test("(i) PIN, D12/D13: one tight list row against the same list as two loose rows does NOT match (the row count differs)")
    func tightListAgainstLooseRowsDoesNotMatch() {
        let stored = [row(.bulletList, "- one\n- two", sort: 0)]
        let wouldWrite = [row(.bulletList, "* one", sort: 0), row(.bulletList, "* two", sort: 1)]
        #expect(!match(stored, wouldWrite))
        #expect(!match(wouldWrite, stored))
    }

    @Test("(j) D7/D13: leading and trailing whitespace on a fragment, on either side, still matches")
    func whitespaceAroundAFragmentMatches() {
        var padded = document()
        padded[1] = row(.paragraph, "\n  one two three.\n\n", sort: 1)
        #expect(match(padded, document()))
        #expect(match(document(), padded))
    }

    @Test("(k) D7/D13: a heading and a paragraph with equal sortOrder are compared heading-first, the order a reopen reads; it is also a near tie")
    func equalSortOrderIsComparedHeadingFirst() {
        let stored = [
            row(.paragraph, "para", sort: 5),                       // listed first, but a reopen sorts the heading ahead
            row(.heading, "# Head", sort: 5, level: 1)
        ]
        let wouldWrite = [row(.heading, "# Head", sort: 0, level: 1), row(.paragraph, "para", sort: 1)]
        #expect(match(stored, wouldWrite))
        #expect(LifecycleWholeDocumentWrite.hasNearTie(BlockParser.assemblySorted(stored)),
                "equal sortOrder is a near tie, so the check still sends FB to renumber")
    }

    @Test("(l) D2/D13: adjacent sortOrder 5.0 and 5.0000000001 is a near tie; a gap of 1e-3 or 1 is not")
    func nearTieThreshold() {
        func rows(_ second: Double) -> [Block] { [row(.paragraph, "a", sort: 5), row(.paragraph, "b", sort: second)] }
        #expect(LifecycleWholeDocumentWrite.hasNearTie(rows(5.0000000001)))
        #expect(LifecycleWholeDocumentWrite.hasNearTie(rows(5)))
        #expect(!LifecycleWholeDocumentWrite.hasNearTie(rows(5.001)))
        #expect(!LifecycleWholeDocumentWrite.hasNearTie(rows(6)))
        #expect(!LifecycleWholeDocumentWrite.hasNearTie([]))
        #expect(!LifecycleWholeDocumentWrite.hasNearTie([row(.paragraph, "only", sort: 0)]))
    }

    @Test("(m) PIN, D5/D13: a bibliography entry in citeproc form against remark's form does NOT match")
    func bibliographyCiteprocFormAgainstRemarkFormDoesNotMatch() {
        let citeproc = "Smith, A. & Jones, B. (2020). _A Title_. Press."
        let remark = "Smith, A. \\& Jones, B. (2020). *A Title*. Press."
        let stored = [row(.paragraph, citeproc, sort: 0, bibliography: true)]
        let wouldWrite = [row(.paragraph, remark, sort: 0, bibliography: true)]
        #expect(!match(stored, wouldWrite), "FB runs for such a document, as today; the comparison is not loosened")
        #expect(match(stored, [row(.paragraph, citeproc, sort: 0, bibliography: true)]))
    }

    @Test("(n) rows whose fragment is empty after trimming are ignored on either side")
    func emptyFragmentRowsAreIgnored() {
        var withEmpties = document()
        withEmpties.insert(row(.paragraph, "", sort: 1.5), at: 2)
        withEmpties.append(row(.paragraph, " \n ", sort: 9))
        #expect(match(withEmpties, document()), "empty stored rows are not compared")
        #expect(match(document(), withEmpties), "nor are empty would-write rows")
    }

    // Code review X1: the sidebar's word counts and goal progress come from `textContent` (`wordCount` is derived from
    // it). The per-edit path stores ProseMirror's `node.textContent`, which drops inline atoms (citations, footnote
    // references, inline math) and joins table / quote child text with no separator; FB used to re-derive it from the
    // whole-document parse. A skip that ignored it would leave a different stored text (and, before t-0b70d1e9, LOWER
    // counts: the per-edit update now counts its words from its markdown fragment, so the counts agree), so the text is
    // part of the comparison.
    @Test("(o) X1: the same fragment with a different textContent does NOT match (the editor's text dropped an inline atom)")
    func differentTextContentDoesNotMatch() {
        let stored = [row(.paragraph, "Cited[@key] here.", sort: 0, text: "Cited here.")]
        let wouldWrite = [row(.paragraph, "Cited[@key] here.", sort: 0, text: "Cited [@key] here.")]
        #expect(!match(stored, wouldWrite), "FB still runs for a paragraph holding a citation, footnote reference or inline math")
        #expect(match(stored, [row(.paragraph, "Cited[@key] here.", sort: 0, text: "Cited here.")]))
    }

    @Test("(p) X1: textContent is trimmed of whitespace and newlines on both sides, like the fragment")
    func textContentIsTrimmedOnBothSides() {
        var padded = document()
        padded[1] = row(.paragraph, "one two three.", sort: 1, text: "\n  one two three.\n ")
        #expect(match(padded, document()))
        #expect(match(document(), padded))
    }

    @Test("the difference report names textContent when only the text differs")
    func differenceReportNamesTextContent() throws {
        var wouldWrite = document()
        wouldWrite[1] = row(.paragraph, "one two three.", sort: 1, text: "one two three plus an atom")
        let report = try #require(LifecycleWholeDocumentWrite.firstDifference(stored: document(), wouldWrite: wouldWrite))
        #expect(report.contains("row 2"))
        #expect(report.contains("textContent"))
        #expect(!report.contains("markdownFragment"), "the fragments are equal: \(report)")
    }

    @Test("an empty document matches an empty document, and a stored document against nothing does not")
    func emptyAgainstEmpty() {
        #expect(match([], []))
        #expect(!match(document(), []))
    }

    @Test("the difference report names the row and the differing fields, for the failure message of the editor tests")
    func differenceReportNamesTheFields() throws {
        var wouldWrite = document()
        wouldWrite[1] = row(.bulletList, "* one two three.", sort: 1)
        let report = try #require(LifecycleWholeDocumentWrite.firstDifference(stored: document(), wouldWrite: wouldWrite))
        #expect(report.contains("row 2"))
        #expect(report.contains("blockType"))
        #expect(report.contains("markdownFragment"))
        #expect(LifecycleWholeDocumentWrite.firstDifference(stored: document(), wouldWrite: document()) == nil)
    }
}

// MARK: - The body's verdicts over a real database

@Suite("Checked FB: the write body, three verdicts — Tier 1: Silent Killers")
struct LifecycleFBCheckBodyTests {

    private static let seed = "# Alpha\n\none two three.\n\n# Beta\n\nfour five six.\n"

    private struct Snapshot: Equatable {
        let rows: [Block]
        let epoch: Int64
    }

    private func snapshot(_ db: ProjectDatabase, _ pid: String) throws -> Snapshot {
        Snapshot(rows: try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder },
                 epoch: try db.currentBlockWriteEpoch(projectId: pid))
    }

    @MainActor
    private func run(
        _ content: String, skip: Bool, db: ProjectDatabase, pid: String
    ) throws -> LifecycleWholeDocumentWriteValue {
        let prepared = try #require(LifecycleWholeDocumentWrite.prepare(
            content: content, database: db, projectId: pid, zoomedRange: nil, zoomedSectionId: nil,
            skipIfUnchanged: skip))
        let body = LifecycleWholeDocumentWrite.body(prepared)
        return try db.dbWriter.write { try body($0) }.value
    }

    @Test("matching rows and the flag on: `.unchanged`, and NOTHING moves: same rows, same ids, same sortOrders, same epoch")
    @MainActor
    func matchingRowsWriteNothing() throws {
        let db = try TestFixtureFactory.createTemporary(content: Self.seed)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let before = try snapshot(db, pid)

        let verdict = try run(Self.seed, skip: true, db: db, pid: pid)

        #expect(verdict == .unchanged(rowCount: 4))
        #expect(try snapshot(db, pid) == before, "an unchanged FB writes nothing: no row touched, no epoch bump")
    }

    @Test("rows that differ and the flag on: the replace runs as today (`.written`, new epoch, the new text)")
    @MainActor
    func differingRowsRunTheReplace() throws {
        let db = try TestFixtureFactory.createTemporary(content: Self.seed)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let before = try snapshot(db, pid)

        let verdict = try run("# Alpha\n\nchanged words.\n\n# Beta\n\nfour five six.\n", skip: true, db: db, pid: pid)

        guard case .written = verdict else {
            Issue.record("expected .written, got \(verdict)")
            return
        }
        let after = try snapshot(db, pid)
        #expect(after.epoch == before.epoch + 1)
        #expect(after.rows.contains { $0.markdownFragment == "changed words." })
    }

    @Test("matching rows with the flag OFF still write (the direct-write fallback and every non-gated caller)")
    @MainActor
    func flagOffAlwaysWrites() throws {
        let db = try TestFixtureFactory.createTemporary(content: Self.seed)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let before = try snapshot(db, pid)

        let verdict = try run(Self.seed, skip: false, db: db, pid: pid)

        guard case .written = verdict else {
            Issue.record("expected .written, got \(verdict)")
            return
        }
        #expect(try snapshot(db, pid).epoch == before.epoch + 1)
    }

    @Test("`forcingWrite()` clears the skip flag and keeps everything else (what the direct-write fallback writes with)")
    @MainActor
    func forcingWriteClearsTheFlag() throws {
        let db = try TestFixtureFactory.createTemporary(content: Self.seed)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let prepared = try #require(LifecycleWholeDocumentWrite.prepare(
            content: Self.seed, database: db, projectId: pid, zoomedRange: nil, zoomedSectionId: nil, skipIfUnchanged: true))
        #expect(prepared.skipIfUnchanged)
        let forced = prepared.forcingWrite()
        #expect(!forced.skipIfUnchanged)
        #expect(forced.blocks.map(\.markdownFragment) == prepared.blocks.map(\.markdownFragment))
        #expect(forced.projectId == prepared.projectId)
    }

    @Test("a stored near tie forces the rebuild even when every row matches, and the rebuild renumbers (strictly increasing, gaps of 1)")
    @MainActor
    func nearTieForcesTheRebuildAndRenumbers() throws {
        let db = try TestFixtureFactory.createTemporary(content: Self.seed)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        // Squeeze the last paragraph against the Beta heading: one ten-billionth apart.
        let beta = try #require(try TestFixtureFactory.fetchBlocks(from: db).first { $0.textContent == "Beta" })
        try db.dbWriter.write { database in
            try database.execute(
                sql: "UPDATE block SET sortOrder = ? WHERE projectId = ? AND markdownFragment = ?",
                arguments: [beta.sortOrder + 0.0000000001, pid, "four five six."])
        }
        let squeezed = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(LifecycleWholeDocumentWrite.hasNearTie(BlockParser.assemblySorted(squeezed)), "precondition: a near tie")
        let epochBefore = try db.currentBlockWriteEpoch(projectId: pid)

        let verdict = try run(Self.seed, skip: true, db: db, pid: pid)

        guard case .written = verdict else {
            Issue.record("a near tie must not be skipped, got \(verdict)")
            return
        }
        let after = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }
        #expect(try db.currentBlockWriteEpoch(projectId: pid) == epochBefore + 1)
        #expect(zip(after, after.dropFirst()).allSatisfy { $1.sortOrder - $0.sortOrder >= 1 }, "renumbered: gaps of at least 1")
        #expect(!LifecycleWholeDocumentWrite.hasNearTie(BlockParser.assemblySorted(after)))
    }

    @Test("a zoomed body always writes, whatever the skip flag says")
    @MainActor
    func zoomedBodyIgnoresTheFlag() throws {
        let db = try TestFixtureFactory.createTemporary(content: Self.seed)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let rows = try TestFixtureFactory.fetchBlocks(from: db)
        let alpha = try #require(rows.first { $0.blockType == .heading && $0.textContent == "Alpha" })
        let beta = try #require(rows.first { $0.blockType == .heading && $0.textContent == "Beta" })
        let epochBefore = try db.currentBlockWriteEpoch(projectId: pid)
        // The zoomed section's own rows, unchanged: a whole-document body would call this a match.
        let prepared = try #require(LifecycleWholeDocumentWrite.prepare(
            content: "# Alpha\n\none two three.\n", database: db, projectId: pid,
            zoomedRange: (start: alpha.sortOrder, end: beta.sortOrder), zoomedSectionId: alpha.id, skipIfUnchanged: true))
        let body = LifecycleWholeDocumentWrite.body(prepared)

        let verdict = try db.dbWriter.write { try body($0) }.value

        guard case .written = verdict else {
            Issue.record("a zoomed write is never skipped, got \(verdict)")
            return
        }
        #expect(try db.currentBlockWriteEpoch(projectId: pid) == epochBefore + 1, "the zoomed replace ran and stamped")
    }
}
