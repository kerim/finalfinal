//
//  DraggableCardRebuildTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Round 14c (speed): after an editor-first Delete Section the Outline sidebar's ~190 cards all ran
//  `DraggableCardView.updateNSView` (a structural change flips `structuralSignature`, which is part of
//  `==`), and every one of them reassigned its hosting view's `rootView` -- a full SwiftUI rebuild and
//  Auto Layout re-measure per card, about 1.1 s of main thread. A leftover card only needed its drag
//  context (`coordinator.parent`, which carries the `collectSubtreeIds` snapshot) refreshed.
//  `Coordinator.refresh(parent:inputs:)` is the decision `updateNSView` now makes on every pass:
//  refresh the parent always, rebuild the hosted card only when its `RenderInputs` changed.
//
//  What these tests DO cover: that decision and the `RenderInputs` mapping, in isolation, with no
//  SwiftUI view hierarchy.
//
//  What they do NOT and CANNOT cover: that SwiftUI calls `updateNSView` when it should, and that the
//  hosted card re-renders on a content edit through `@Observable` tracking. That second half is not
//  new (`DraggableCardView.==` already skipped `updateNSView` for a title or word-count edit, so the
//  card has always relied on it -- see `OutlineSidebarRenderKeyTests`); the live proof is the
//  twelve-chapter delete run (`WriteQueuePhase4bDeleteE2ETests.testDeleteSpeedOnly_book12`).
//

import Testing
import Foundation
import SwiftUI
@testable import final_final

@MainActor
@Suite("DraggableCardView hosted-card rebuild — Tier 1: Silent Killers")
struct DraggableCardRebuildTests {

    // MARK: - Helpers

    private func makeSection(title: String = "Introduction", status: SectionStatus = .next, wordCount: Int = 0) -> SectionViewModel {
        SectionViewModel(from: Section(
            projectId: "test-project", sortOrder: 0, headerLevel: 1, title: title, status: status, wordCount: wordCount))
    }

    private func makeCard(
        section: SectionViewModel,
        isGhost: Bool = false,
        isActive: Bool = false,
        isZoomed: Bool = false,
        structuralSignature: Int = 1,
        subtree: [String] = []
    ) -> DraggableCardView {
        DraggableCardView(
            section: section,
            collectSubtreeIds: { _ in subtree },
            isGhost: isGhost,
            isActive: isActive,
            structuralSignature: structuralSignature,
            onDragStarted: { _ in },
            onDragEnded: {},
            onSingleClick: {},
            onDoubleClick: { _ in },
            onSectionUpdated: nil,
            isZoomed: isZoomed
        )
    }

    private func inputs(of card: DraggableCardView) -> DraggableCardView.RenderInputs {
        card.renderInputs(themeManager: ThemeManager.shared)
    }

    /// A coordinator that has built its hosted card from `card` (what `makeNSView` leaves behind).
    private func builtCoordinator(from card: DraggableCardView) -> DraggableCardView.Coordinator {
        let coordinator = DraggableCardView.Coordinator(card)
        coordinator.renderedInputs = inputs(of: card)
        return coordinator
    }

    // MARK: - The structural change: drag context refreshed, card not rebuilt

    @Test("LOAD-BEARING: a structural change alone refreshes the drag context but does not rebuild the hosted card")
    func structuralChangeRefreshesParentWithoutRebuilding() {
        let section = makeSection()
        let before = makeCard(section: section, structuralSignature: 100, subtree: ["old-child"])
        let coordinator = builtCoordinator(from: before)

        // A delete elsewhere in the outline: this card is untouched, but the list around it changed, so its
        // signature and its subtree snapshot are different now.
        let after = makeCard(section: section, structuralSignature: 200, subtree: ["new-child-1", "new-child-2"])
        let rebuild = coordinator.refresh(parent: after, inputs: inputs(of: after))

        #expect(rebuild == false, "nothing the hosted card renders changed, so it must not be rebuilt")
        #expect(coordinator.parent.structuralSignature == 200, "the coordinator's parent is the new pass's card")
        #expect(coordinator.parent.collectSubtreeIds("any") == ["new-child-1", "new-child-2"],
                "the drag payload's subtree snapshot is the new pass's, not the one the card was built with")
    }

    @Test("nothing changed: no rebuild")
    func nothingChangedDoesNotRebuild() {
        let section = makeSection()
        let card = makeCard(section: section)
        let coordinator = builtCoordinator(from: card)

        #expect(coordinator.refresh(parent: makeCard(section: section), inputs: inputs(of: makeCard(section: section))) == false)
    }

    @Test("editing the same section object's title, status, word count and tags does not rebuild: the hosted card observes the object")
    func contentEditsOnTheSameObjectDoNotRebuild() {
        let section = makeSection(title: "Before", status: .next, wordCount: 10)
        let coordinator = builtCoordinator(from: makeCard(section: section))

        section.title = "After"
        section.status = .writing
        section.wordCount = 500
        section.tags = ["research"]
        let card = makeCard(section: section)

        #expect(coordinator.refresh(parent: card, inputs: inputs(of: card)) == false,
                "the card reads these live off the @Observable object; reassigning rootView would add nothing")
    }

    // MARK: - What does rebuild the card

    @Test("a different section object for the same id (a put-back, a rebuilt list) rebuilds the card")
    func differentSectionObjectRebuilds() {
        let coordinator = builtCoordinator(from: makeCard(section: makeSection()))

        let replacement = makeCard(section: makeSection())
        #expect(coordinator.refresh(parent: replacement, inputs: inputs(of: replacement)) == true)
        #expect(coordinator.refresh(parent: replacement, inputs: inputs(of: replacement)) == false,
                "once rebuilt from the new object, the same object again needs nothing")
    }

    @Test("ghost, active and zoomed changes each rebuild the card")
    func renderFlagChangesRebuild() {
        let section = makeSection()
        let variants: [(String, DraggableCardView)] = [
            ("isGhost", makeCard(section: section, isGhost: true)),
            ("isActive", makeCard(section: section, isActive: true)),
            ("isZoomed", makeCard(section: section, isZoomed: true))
        ]
        for (name, changed) in variants {
            let coordinator = builtCoordinator(from: makeCard(section: section))
            #expect(coordinator.refresh(parent: changed, inputs: inputs(of: changed)) == true, "\(name) changed")
        }
    }

    @Test("a different theme object rebuilds the card")
    func themeChangeRebuilds() {
        let section = makeSection()
        let card = makeCard(section: section)
        let coordinator = builtCoordinator(from: card)
        let current = inputs(of: card)

        // Only one ThemeManager exists in the app (`ThemeManager.shared`, private init), so a stand-in object gives the second identity.
        let otherTheme = DraggableCardView.RenderInputs(
            sectionIdentity: current.sectionIdentity, isGhost: current.isGhost, isActive: current.isActive,
            isZoomed: current.isZoomed, themeManagerIdentity: ObjectIdentifier(NSObject()))

        #expect(coordinator.refresh(parent: card, inputs: otherTheme) == true)
    }

    @Test("a card whose hosted view was never built is built on the first update")
    func neverBuiltRebuilds() {
        let card = makeCard(section: makeSection())
        #expect(DraggableCardView.Coordinator.needsRebuild(rendered: nil, current: inputs(of: card)) == true)
        #expect(DraggableCardView.Coordinator(card).refresh(parent: card, inputs: inputs(of: card)) == true)
    }

    @Test("a rebuild records what the card was built from: ghost on, the same again, ghost off")
    func rebuildRecordsTheNewInputs() {
        let section = makeSection()
        let coordinator = builtCoordinator(from: makeCard(section: section))
        let ghost = makeCard(section: section, isGhost: true)
        let plain = makeCard(section: section)

        #expect(coordinator.refresh(parent: ghost, inputs: inputs(of: ghost)) == true, "ghost state began")
        #expect(coordinator.refresh(parent: ghost, inputs: inputs(of: ghost)) == false, "still ghost: already rendered")
        #expect(coordinator.refresh(parent: plain, inputs: inputs(of: plain)) == true, "ghost state ended: back to the plain card")
    }

    // MARK: - The mapping

    @Test("the render inputs carry the section's identity, not its content, and each flag")
    func renderInputsMapping() {
        let section = makeSection(title: "One")
        let base = inputs(of: makeCard(section: section))

        #expect(base == inputs(of: makeCard(section: section, structuralSignature: 999, subtree: ["x"])),
                "the structural signature and the subtree snapshot are not render inputs")
        #expect(base.sectionIdentity == ObjectIdentifier(section))
        #expect(base != inputs(of: makeCard(section: makeSection(title: "One"))), "an equal-looking but different object differs")
        #expect(base != inputs(of: makeCard(section: section, isGhost: true)))
        #expect(base != inputs(of: makeCard(section: section, isActive: true)))
        #expect(base != inputs(of: makeCard(section: section, isZoomed: true)))
    }
}
