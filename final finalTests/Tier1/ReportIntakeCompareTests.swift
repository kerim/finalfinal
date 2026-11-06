//
//  ReportIntakeCompareTests.swift
//  final finalTests
//
//  Phase 5 job B2 (docs/architecture/write-queue-plan/phase5/b2-b4-design.md, section 2.3): the receiver of the editor's shadow block
//  reports and its comparison with the poll's fetch. Agree, disagree, gap; the plugin's merge rules in the fold; ids resolved through
//  the writer's temp-id map; a compare that waits for its drain report; the restarts (a rebase, another drain).
//

import Foundation
import Testing
@testable import final_final

@Suite("ReportIntake: recording and comparing shadow block reports (Phase 5 B2)")
@MainActor
struct ReportIntakeCompareTests {
    private let session = "s1"

    private func update(_ id: String, _ text: String) -> BlockUpdate {
        BlockUpdate(id: id, textContent: text, markdownFragment: text, headingLevel: nil, blockType: "paragraph")
    }

    private func insert(_ id: String, _ text: String, after: String?) -> BlockInsert {
        BlockInsert(tempId: id, blockType: "paragraph", textContent: text, markdownFragment: text, headingLevel: nil, afterBlockId: after)
    }

    private func report(_ number: Int, _ kind: RecordedReport.Kind, _ changes: BlockChanges = BlockChanges()) -> RecordedReport {
        RecordedReport(sequence: number, kind: kind, changes: changes, detectedAt: 0, receivedAt: Date())
    }

    private func intake() -> ReportIntake {
        let intake = ReportIntake()
        intake.isDisabled = false
        return intake
    }

    @Test("reports that fold to the polled batch agree (an update replaced, a delete removing an update, an update merged into an insert)")
    func agree() {
        let intake = intake()
        intake.receive(report(1, .changes, BlockChanges(updates: [update("a", "one")])), session: session)
        intake.receive(report(2, .changes, BlockChanges(updates: [update("a", "one two"), update("b", "gone soon")],
                                                         inserts: [insert("temp-x", "", after: "a")])), session: session)
        intake.receive(report(3, .drain, BlockChanges(updates: [update("temp-x", "typed")], deletes: ["b"])), session: session)
        let polled = BlockChanges(updates: [update("a", "one two")], inserts: [insert("temp-x", "typed", after: "a")], deletes: ["b"])
        intake.compare(drained: polled, through: 3, session: session, idMap: [:])
        #expect(intake.results == [.agree(fromEs: 1, throughEs: 3, reports: 3)])
    }

    @Test("a report that differs from the batch is a disagreement, with a digest of ids and lengths and no text")
    func disagree() {
        let intake = intake()
        intake.receive(report(1, .drain, BlockChanges(updates: [update("block-aaaa", "secret words")])), session: session)
        intake.compare(drained: BlockChanges(updates: [update("block-aaaa", "secret words!")]), through: 1, session: session, idMap: [:])
        guard case .disagree(_, _, _, let digest) = intake.results.first else {
            Issue.record("expected a disagreement, got \(intake.results)")
            return
        }
        #expect(digest.contains("differ u:block-aaaa"))
        #expect(digest.contains("len12"))
        #expect(digest.contains("len13"))
        #expect(!digest.contains("secret"))
    }

    @Test("a missing report is a gap and gives no verdict")
    func gap() {
        let intake = intake()
        intake.receive(report(1, .changes, BlockChanges(updates: [update("a", "x")])), session: session)
        intake.receive(report(3, .drain), session: session)
        intake.compare(drained: BlockChanges(updates: [update("a", "x")]), through: 3, session: session, idMap: [:])
        #expect(intake.results == [.gap(fromEs: 1, throughEs: 3, missing: [2])])
    }

    @Test("a gap before a rebase is explained: the fold starts at the rebase and still gets a verdict")
    func gapBeforeRebase() {
        let intake = intake()
        intake.receive(report(2, .rebase), session: session)   // es 1 never arrived (posted before the handler existed)
        intake.receive(report(3, .drain, BlockChanges(updates: [update("a", "x")])), session: session)
        intake.compare(drained: BlockChanges(updates: [update("a", "x")]), through: 3, session: session, idMap: [:])
        #expect(intake.results == [.agree(fromEs: 1, throughEs: 3, reports: 2)])
    }

    @Test("a rebase restarts the fold from the maps it carries; another drain's report restarts it empty")
    func restarts() {
        let intake = intake()
        intake.receive(report(1, .changes, BlockChanges(updates: [update("a", "discarded")])), session: session)
        intake.receive(report(2, .rebase, BlockChanges(updates: [update("c", "kept by the reset")])), session: session)
        intake.receive(report(3, .changes, BlockChanges(updates: [update("b", "taken by a route")])), session: session)
        intake.receive(report(4, .drain), session: session)   // an editor-first route drained here
        intake.receive(report(5, .drain, BlockChanges(updates: [update("d", "after the route")])), session: session)
        intake.compare(drained: BlockChanges(updates: [update("d", "after the route")]), through: 5, session: session, idMap: [:])
        #expect(intake.results == [.agree(fromEs: 1, throughEs: 5, reports: 5)])
    }

    @Test("ids are resolved through the writer's temp-id map, so a confirmation between report and poll does not matter")
    func tempIdsResolved() {
        let intake = intake()
        intake.receive(report(1, .changes, BlockChanges(updates: [update("temp-1", "early")])), session: session)
        intake.receive(report(2, .drain, BlockChanges(updates: [update("perm-1", "late")])), session: session)
        intake.compare(drained: BlockChanges(updates: [update("perm-1", "late")]), through: 2, session: session,
                       idMap: ["temp-1": "perm-1"])
        #expect(intake.results == [.agree(fromEs: 1, throughEs: 2, reports: 2)])
    }

    @Test("a compare whose drain report has not arrived yet waits for it; arrival order does not change the verdict")
    func compareWaitsForItsReport() {
        let intake = intake()
        intake.receive(report(1, .changes, BlockChanges(updates: [update("a", "x")])), session: session)
        intake.compare(drained: BlockChanges(updates: [update("a", "x y")]), through: 2, session: session, idMap: [:])
        #expect(intake.results.isEmpty)
        intake.receive(report(2, .drain, BlockChanges(updates: [update("a", "x y")])), session: session)
        #expect(intake.results == [.agree(fromEs: 1, throughEs: 2, reports: 2)])
        // The next window starts after it.
        intake.receive(report(3, .drain), session: session)
        intake.compare(drained: BlockChanges(), through: 3, session: session, idMap: [:])
        #expect(intake.results.last == .agree(fromEs: 3, throughEs: 3, reports: 1))
    }

    @Test("sessions never mix, and a disabled intake (FF_UI_TESTING_LEGACY_POLL) records nothing")
    func sessionsAndDisabled() {
        let intake = intake()
        intake.receive(report(1, .drain, BlockChanges(updates: [update("a", "page one")])), session: "p1")
        intake.receive(report(1, .drain, BlockChanges(updates: [update("a", "page two")])), session: "p2")
        intake.compare(drained: BlockChanges(updates: [update("a", "page two")]), through: 1, session: "p2", idMap: [:])
        #expect(intake.results == [.agree(fromEs: 1, throughEs: 1, reports: 1)])

        let off = ReportIntake()
        off.isDisabled = true
        off.receive(body: ["es": 1, "session": "p", "kind": "drain", "json": "{\"updates\":[],\"inserts\":[],\"deletes\":[]}"])
        off.compare(drained: BlockChanges(), through: 1, session: "p", idMap: [:])
        #expect(off.receivedCount == 0)
        #expect(off.results.isEmpty)
    }

    @Test("a message body from the page is decoded (the wire shape report-outbox.ts posts)")
    func decodesWireShape() {
        let intake = intake()
        let json = "{\"updates\":[{\"id\":\"a\",\"textContent\":\"hi\",\"markdownFragment\":\"hi\",\"blockType\":\"paragraph\"}],"
            + "\"inserts\":[],\"deletes\":[]}"
        intake.receive(body: ["es": 1, "session": "w", "kind": "drain", "json": json, "detectedAt": 1.0, "postedAt": 2.0])
        intake.compare(drained: BlockChanges(updates: [update("a", "hi")]), through: 1, session: "w", idMap: [:])
        #expect(intake.receivedCount == 1)
        #expect(intake.results == [.agree(fromEs: 1, throughEs: 1, reports: 1)])
    }
}
