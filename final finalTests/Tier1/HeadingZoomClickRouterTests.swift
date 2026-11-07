//
//  HeadingZoomClickRouterTests.swift
//  final finalTests
//
//  Tier 1: pure decision-logic coverage for Cmd-click-a-heading-to-zoom.
//  Deliberately no Focus Mode setup anywhere in this file -- the feature is
//  always-on, and HeadingZoomClickRouter.decide has no Focus Mode parameter
//  at all. The only gate is contentState == .idle.
//

import Testing
@testable import final_final

@Suite("HeadingZoomClickRouter.decide")
struct HeadingZoomClickRouterTests {

    private func section(
        _ id: String, isBibliography: Bool = false, isNotes: Bool = false, isPseudoSection: Bool = false
    ) -> HeadingZoomClickSectionInfo {
        HeadingZoomClickSectionInfo(id: id, isBibliography: isBibliography, isNotes: isNotes, isPseudoSection: isPseudoSection)
    }

    @Test("idle state + known section zooms in with full mode")
    func zoomsInToKnownSection() {
        let action = HeadingZoomClickRouter.decide(
            blockId: "h1",
            zoomedSectionId: nil,
            contentState: .idle,
            sections: [section("h1"), section("h2")]
        )
        #expect(action == .zoomIn(id: "h1", mode: .full))
    }

    @Test("clicking the currently-zoomed heading again zooms out")
    func clickingZoomedHeadingZoomsOut() {
        let action = HeadingZoomClickRouter.decide(
            blockId: "h1",
            zoomedSectionId: "h1",
            contentState: .idle,
            sections: [section("h1"), section("h2")]
        )
        #expect(action == .zoomOut)
    }

    @Test("non-idle content state drops the click")
    func nonIdleStateDrops() {
        let action = HeadingZoomClickRouter.decide(
            blockId: "h1",
            zoomedSectionId: nil,
            contentState: .zoomTransition,
            sections: [section("h1"), section("h2")]
        )
        guard case .drop = action else {
            Issue.record("expected .drop, got \(action)")
            return
        }
    }

    @Test("a still-temporary block id is dropped even while idle")
    func temporaryBlockIdDrops() {
        let action = HeadingZoomClickRouter.decide(
            blockId: "temp-abc123",
            zoomedSectionId: nil,
            contentState: .idle,
            sections: [section("temp-abc123")]
        )
        guard case .drop = action else {
            Issue.record("expected .drop, got \(action)")
            return
        }
    }

    @Test("a block id with no matching outline section is dropped")
    func unknownSectionDrops() {
        let action = HeadingZoomClickRouter.decide(
            blockId: "does-not-exist",
            zoomedSectionId: nil,
            contentState: .idle,
            sections: [section("h1"), section("h2")]
        )
        guard case .drop = action else {
            Issue.record("expected .drop, got \(action)")
            return
        }
    }

    @Test("Cmd-clicking the Notes heading is dropped — zoom would destroy it on flush")
    func notesSectionDrops() {
        let action = HeadingZoomClickRouter.decide(
            blockId: "notes-heading",
            zoomedSectionId: nil,
            contentState: .idle,
            sections: [section("h1"), section("notes-heading", isNotes: true)]
        )
        guard case .drop(let reason) = action else {
            Issue.record("expected .drop, got \(action)")
            return
        }
        #expect(reason.contains("managed section"))
    }

    @Test("Cmd-clicking the Bibliography heading is dropped — zoom would destroy it on flush")
    func bibliographySectionDrops() {
        let action = HeadingZoomClickRouter.decide(
            blockId: "bib-heading",
            zoomedSectionId: nil,
            contentState: .idle,
            sections: [section("h1"), section("bib-heading", isBibliography: true)]
        )
        guard case .drop(let reason) = action else {
            Issue.record("expected .drop, got \(action)")
            return
        }
        #expect(reason.contains("managed section"))
    }
}
