//
//  SplitViewAutosaveNamingLaunchSnapshotTests.swift
//  final finalTests
//
//  Covers the Outline pane's launch step (bt t-218cac62): the launch-time "did a PREVIOUS
//  session save a divider position" snapshot, the pure `launchDecision` rule that consults it,
//  and the landing read-back. The snapshot has to be taken before this launch's own split view
//  can write an autosave key, and it is judged BY NAME against the top-level split view's LIVE
//  autosave name: the nested editor / Annotations split view autosaves under a SwiftUI-derived
//  name of its own, and dead keys linger from old launches, and neither says anything about the
//  Outline's width. Everything decided here is a pure function over plain values, so it is
//  testable without AppKit.
//
//  The capture/consume/restore methods touch PROCESS-GLOBAL state that the real
//  `OutlineSidebarPane` reads, and unit tests are hosted inside the real app process, whose
//  launch already captured a real snapshot -- so every method here restores what it found.
//

import XCTest
@testable import final_final

@MainActor
final class SplitViewAutosaveNamingLaunchSnapshotTests: XCTestCase { // swiftlint:disable:this type_name

    private var priorLaunchKeys: Set<String>?

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        priorLaunchKeys = SplitViewAutosaveNaming.launchSplitViewFrameKeys
    }

    @MainActor
    override func tearDown() async throws {
        SplitViewAutosaveNaming.restoreLaunchSplitViewFrameKeysForTesting(priorLaunchKeys)
        try await super.tearDown()
    }

    let stableName = SplitViewAutosaveNaming.stableName
    let derivedName = "SwiftUI.(unknown context at $1).SplitView"
    let otherDerivedName = "SwiftUI.(unknown context at $2).SplitView"

    func key(_ name: String) -> String {
        AutosaveKeySweep.splitViewPrefix + name
    }

    // MARK: - savedDividerPosition(in:forAutosaveName:)

    func testEmptyDomainHasNoSavedDividerPosition() {
        XCTAssertFalse(SplitViewAutosaveNaming.savedDividerPosition(in: [], forAutosaveName: stableName))
    }

    func testUnrelatedKeysDoNotCountAsASavedDividerPosition() {
        let keys: Set<String> = [
            "NSWindow Frame SwiftUI.(unknown context).AppWindow",
            "com.kerim.final-final.recentProjects",
            "focusModeEnabled"
        ]
        XCTAssertFalse(SplitViewAutosaveNaming.savedDividerPosition(in: keys, forAutosaveName: stableName))
    }

    func testStableNameKeyMatchesWhenStableNameIsTheLiveName() {
        XCTAssertTrue(SplitViewAutosaveNaming.savedDividerPosition(in: [key(stableName)], forAutosaveName: stableName))
    }

    func testKeyUnderAnUnrelatedSwiftUIDerivedNameDoesNotMatchTheStableName() {
        // The nested Annotations split view (or a dead key from an old launch) saved under a
        // derived name. It says nothing about the Outline, so it must not suppress the 300pt
        // positioning of a launch whose live top-level name is `stableName`.
        XCTAssertFalse(SplitViewAutosaveNaming.savedDividerPosition(in: [key(derivedName)], forAutosaveName: stableName))
    }

    func testSwiftUIDerivedKeyMatchesWhenItIsTheLiveName() {
        // When SwiftUI's derived name IS the live top-level name, AppKit restores under it, so a
        // width saved there is authoritative.
        XCTAssertTrue(SplitViewAutosaveNaming.savedDividerPosition(in: [key(derivedName)], forAutosaveName: derivedName))
    }

    func testStableNameKeyDoesNotMatchADifferentLiveName() {
        XCTAssertFalse(SplitViewAutosaveNaming.savedDividerPosition(in: [key(stableName)], forAutosaveName: derivedName))
    }

    func testBarePrefixWithEmptyNameDoesNotMatch() {
        // Prefix + "" is the bare prefix, which is not a key AppKit ever writes; an empty name must
        // never read as "saved".
        XCTAssertFalse(SplitViewAutosaveNaming.savedDividerPosition(
            in: [AutosaveKeySweep.splitViewPrefix], forAutosaveName: ""))
    }

    // MARK: - capture / consume / restore

    func testCaptureKeepsOnlySplitViewFrameKeys() {
        let splitKey = key(stableName)
        SplitViewAutosaveNaming.captureLaunchSplitViewFrameKeys(domainKeys: [
            splitKey,
            "NSWindow Frame SwiftUI.(unknown context).AppWindow",
            "focusModeEnabled"
        ])
        XCTAssertEqual(SplitViewAutosaveNaming.launchSplitViewFrameKeys, Set([splitKey]))
    }

    func testCaptureCalledTwiceReplacesTheFirstSnapshot() {
        SplitViewAutosaveNaming.captureLaunchSplitViewFrameKeys(domainKeys: [key("first")])
        SplitViewAutosaveNaming.captureLaunchSplitViewFrameKeys(domainKeys: [key("second")])
        XCTAssertEqual(SplitViewAutosaveNaming.launchSplitViewFrameKeys, Set([key("second")]))
    }

    func testLaunchSavedDividerPositionAnswersByNameFromTheSnapshot() {
        SplitViewAutosaveNaming.captureLaunchSplitViewFrameKeys(domainKeys: [key(stableName)])
        XCTAssertEqual(SplitViewAutosaveNaming.launchSavedDividerPosition(forAutosaveName: stableName), true)
        XCTAssertEqual(SplitViewAutosaveNaming.launchSavedDividerPosition(forAutosaveName: derivedName), false)
    }

    func testLaunchSavedDividerPositionIsNilWhenThereIsNoSnapshot() {
        SplitViewAutosaveNaming.restoreLaunchSplitViewFrameKeysForTesting(nil)
        XCTAssertNil(SplitViewAutosaveNaming.launchSavedDividerPosition(forAutosaveName: stableName))
    }

    func testConsumeRetiresTheSnapshot() {
        SplitViewAutosaveNaming.captureLaunchSplitViewFrameKeys(domainKeys: [key(stableName)])
        SplitViewAutosaveNaming.consumeLaunchSplitViewFrameKeys()
        XCTAssertNil(SplitViewAutosaveNaming.launchSplitViewFrameKeys)
    }

    func testRestoreBringsBackAnEarlierSnapshot() {
        let earlier: Set<String> = [key(stableName)]
        SplitViewAutosaveNaming.restoreLaunchSplitViewFrameKeysForTesting(earlier)
        SplitViewAutosaveNaming.captureLaunchSplitViewFrameKeys(domainKeys: [])
        SplitViewAutosaveNaming.restoreLaunchSplitViewFrameKeysForTesting(earlier)
        XCTAssertEqual(SplitViewAutosaveNaming.launchSplitViewFrameKeys, earlier)
    }

    // MARK: - captureLaunchSplitViewFrameKeys(fromDomainNamed:domainWasWiped:)

    func testCaptureFromARealDomainReadsItOnlyWhenItWasNotWiped() throws {
        // A real defaults domain seeded with one stableName split-view key, so neither assertion
        // can pass vacuously: a wiped launch must capture the empty set even though the domain
        // holds a key (proving it did not read it back), and an unwiped one must capture exactly
        // that key.
        let suite = "com.kerim.final-final.tests.LaunchSnapshotDomainCapture"
        let seededKey = key(stableName)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(["0.000000, 0.000000, 300.000000, 400.000000, NO, NO"], forKey: seededKey)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        SplitViewAutosaveNaming.captureLaunchSplitViewFrameKeys(fromDomainNamed: suite, domainWasWiped: true)
        XCTAssertEqual(SplitViewAutosaveNaming.launchSplitViewFrameKeys, Set<String>())

        SplitViewAutosaveNaming.captureLaunchSplitViewFrameKeys(fromDomainNamed: suite, domainWasWiped: false)
        XCTAssertEqual(SplitViewAutosaveNaming.launchSplitViewFrameKeys, Set([seededKey]))
    }

    func testAMissingBundleIdentifierLeavesTheSnapshotUncaptured() {
        SplitViewAutosaveNaming.restoreLaunchSplitViewFrameKeysForTesting(nil)
        SplitViewAutosaveNaming.captureLaunchSplitViewFrameKeys(fromDomainNamed: nil, domainWasWiped: false)
        XCTAssertNil(SplitViewAutosaveNaming.launchSplitViewFrameKeys)
    }
}

// MARK: - launchDecision: the whole rule table

extension SplitViewAutosaveNamingLaunchSnapshotTests {

    /// One `launchDecision` call. Defaults describe an ordinary first tick: a window, a readable
    /// `stableName`, an EMPTY snapshot (what a wiped UI-test launch captures), a divider at
    /// AppKit's 400pt, a visible pane, and not the final attempt.
    private func decision(
        snapshot: Set<String>? = [],
        hasWindow: Bool = true,
        liveName: String? = SplitViewAutosaveNaming.stableName,
        liveKeyPresent: Bool = false,
        position: CGFloat? = 400,
        visible: Bool = true,
        isFinalAttempt: Bool = false
    ) -> SplitViewAutosaveNaming.LaunchDecision {
        SplitViewAutosaveNaming.launchDecision(SplitViewAutosaveNaming.LaunchInputs(
            snapshotKeys: snapshot,
            hasWindow: hasWindow,
            liveName: liveName,
            liveKeyPresent: liveKeyPresent,
            currentPosition: position,
            paneIsVisible: visible,
            isFinalAttempt: isFinalAttempt
        ))
    }

    // Rule 1: no window.

    func testNoWindowWaitsEvenWhenTheRestIsReadable() {
        XCTAssertEqual(decision(snapshot: [key(stableName)], hasWindow: false), .wait(.noWindow))
    }

    func testNoWindowWaitsEvenWithAnEmptySnapshot() {
        // Rule 1 comes before the empty-snapshot rule: there is no split view to position yet.
        XCTAssertEqual(decision(snapshot: [], hasWindow: false), .wait(.noWindow))
        XCTAssertEqual(decision(snapshot: [], hasWindow: false, liveName: nil), .wait(.noWindow))
    }

    // Rule 2: an existing, EMPTY snapshot -- nothing AppKit could restore under ANY name.

    func testAnEmptySnapshotPositionsEvenWhenTheNameIsUnreadable() {
        // Under UI test the capture is the empty set and `stabilize(for:)`, the only assigner of the
        // top-level split view's name, never runs: the name is nil for the whole process. The
        // answer the name was needed for is already in hand, so waiting on it would block the
        // positioning the gating test measures. No key is matched, so this is not a `stableName`
        // fallback.
        XCTAssertEqual(decision(snapshot: [], liveName: nil), .positionAtLaunchWidth)
        XCTAssertEqual(decision(snapshot: [], liveName: ""), .positionAtLaunchWidth)
    }

    func testAnEmptySnapshotPositionsOnTheFirstTickWhateverTheReadableName() {
        XCTAssertEqual(decision(snapshot: [], liveName: derivedName), .positionAtLaunchWidth)
        XCTAssertEqual(decision(snapshot: []), .positionAtLaunchWidth)
    }

    // Rule 3: live name unreadable -- no `stableName` fallback, and only an EMPTY snapshot bypasses.

    func testAnUnreadableNameWaitsInsteadOfBeingTakenForStableName() {
        // The snapshot holds a previous session's stableName key. Substituting `stableName` for
        // "cannot read the name" would answer "saved" before any split view exists.
        XCTAssertEqual(decision(snapshot: [key(stableName)], liveName: nil), .wait(.nameUnreadable))
    }

    func testAnEmptyNameIsUnreadable() {
        XCTAssertEqual(decision(snapshot: [key(stableName)], liveName: ""), .wait(.nameUnreadable))
    }

    func testAnUnreadableNameStillWaitsOnTheFinalAttempt() {
        XCTAssertEqual(decision(snapshot: [key(stableName)], liveName: nil, isFinalAttempt: true), .wait(.nameUnreadable))
    }

    func testANonEmptySnapshotOfForeignKeysStillWaitsOnAnUnreadableName() {
        // Not empty, so rule 2 does not apply; and a foreign key says nothing either way, but the
        // name is still the precondition for asking the snapshot.
        XCTAssertEqual(decision(snapshot: [key(otherDerivedName)], liveName: nil), .wait(.nameUnreadable))
    }

    func testANilSnapshotIsNotAnEmptyOneAndWaitsOnAnUnreadableName() {
        // Never captured, or consumed by an earlier pane: no known-empty answer to bypass with.
        XCTAssertEqual(decision(snapshot: nil, liveName: nil), .wait(.nameUnreadable))
    }

    // Rule 4a: the snapshot holds the key under the live name.

    func testASavedKeyUnderTheLiveStableNameWins() {
        XCTAssertEqual(decision(snapshot: [key(stableName)], position: 340), .savedPositionWins)
    }

    func testASavedKeyUnderALiveDerivedNameWins() {
        XCTAssertEqual(decision(snapshot: [key(derivedName)], liveName: derivedName), .savedPositionWins)
    }

    func testAKeyUnderTheLiveDerivedNameBeatsTheWaitForStabilization() {
        let snapshot: Set<String> = [key(stableName), key(derivedName)]
        XCTAssertEqual(decision(snapshot: snapshot, liveName: derivedName), .savedPositionWins)
    }

    func testAHiddenAtQuitSavedPositionIsPositionedAtTheLaunchWidth() {
        // The Outline was hidden when the user quit, so AppKit autosaved ~0. The pane opens
        // visible, so a divider reading below the floor is not a width worth restoring.
        let snapshot: Set<String> = [key(stableName)]
        XCTAssertEqual(decision(snapshot: snapshot, position: 0), .positionAtLaunchWidth)
        XCTAssertEqual(decision(snapshot: snapshot, position: OutlineSidebarWidth.minWidth - 0.1), .positionAtLaunchWidth)
    }

    func testASavedPositionAtExactlyTheFloorIsStillAWidthWorthRestoring() {
        XCTAssertEqual(
            decision(snapshot: [key(stableName)], position: OutlineSidebarWidth.minWidth), .savedPositionWins)
    }

    func testASubFloorPositionOfAPaneThatIsNotVisibleStillWins() {
        XCTAssertEqual(decision(snapshot: [key(stableName)], position: 0, visible: false), .savedPositionWins)
    }

    func testAnUnreadablePositionCannotShowHiddenAtQuit() {
        XCTAssertEqual(decision(snapshot: [key(stableName)], position: nil), .savedPositionWins)
    }

    // Rule 4b: a stableName key while the live name is still derived -- stabilization pending.

    func testAStableNameKeyWithADerivedLiveNameWaitsForStabilization() {
        // The case that has now bitten twice: the previous session saved under `stableName`, but
        // `stabilize(for:)` has not landed, so the live name is still SwiftUI-derived. Answering
        // "nothing saved" here would force 300pt over the user's remembered width.
        XCTAssertEqual(decision(snapshot: [key(stableName)], liveName: derivedName), .wait(.stabilizationPending))
    }

    func testTheSameInputsOnTheFinalAttemptPositionAtTheLaunchWidth() {
        XCTAssertEqual(
            decision(snapshot: [key(stableName)], liveName: derivedName, isFinalAttempt: true), .positionAtLaunchWidth)
    }

    func testTheStabilizationWaitNeedsAStableNameKeyInTheSnapshot() {
        // Only a key under `stableName` can still be restored once stabilization lands. Another
        // split view's key neither suppresses the positioning nor delays it.
        XCTAssertEqual(decision(snapshot: [key(otherDerivedName)], liveName: derivedName), .positionAtLaunchWidth)
    }

    func testTheStabilizationWaitDoesNotApplyWhenTheLiveNameIsStableName() {
        XCTAssertEqual(decision(snapshot: [key(otherDerivedName)]), .positionAtLaunchWidth)
        XCTAssertEqual(decision(snapshot: []), .positionAtLaunchWidth)
    }

    // Rule 4c: otherwise position at the launch width.

    func testAWipedUITestLaunchPositionsOnTheFirstTickTheSplitViewIsReadable() {
        // A launch that captured the empty set and whose split view carries a readable SwiftUI-derived
        // name: the stabilization wait needs a `stableName` key in the snapshot, so it never applies.
        XCTAssertEqual(decision(snapshot: [], liveName: derivedName), .positionAtLaunchWidth)
    }

    func testUnrelatedKeysInTheSnapshotNeverSuppressThePositioning() {
        let snapshot: Set<String> = [key(derivedName), key(otherDerivedName)]
        XCTAssertEqual(decision(snapshot: snapshot), .positionAtLaunchWidth)
    }

    // Rule 5: no snapshot -- the live check stands in, with no stabilization wait.

    func testWithNoSnapshotALiveKeyUnderTheLiveNameWins() {
        XCTAssertEqual(decision(snapshot: nil, liveKeyPresent: true, position: 340), .savedPositionWins)
    }

    func testWithNoSnapshotAndNoLiveKeyThePaneIsPositioned() {
        XCTAssertEqual(decision(snapshot: nil, liveKeyPresent: false), .positionAtLaunchWidth)
    }

    func testWithNoSnapshotThereIsNoStabilizationWait() {
        XCTAssertEqual(decision(snapshot: nil, liveName: derivedName, liveKeyPresent: false), .positionAtLaunchWidth)
    }

    func testWithNoSnapshotAHiddenAtQuitLiveKeyIsPositioned() {
        XCTAssertEqual(decision(snapshot: nil, liveKeyPresent: true, position: 0), .positionAtLaunchWidth)
    }

    func testWithNoSnapshotTheWindowAndNameAreStillPreconditions() {
        XCTAssertEqual(decision(snapshot: nil, hasWindow: false), .wait(.noWindow))
        XCTAssertEqual(decision(snapshot: nil, liveName: nil), .wait(.nameUnreadable))
    }

    func testAPresentSnapshotIsNotOverriddenByTheLiveKeyFlag() {
        // `liveKeyPresent` is only consulted when there is no snapshot; an empty snapshot that
        // says "nothing saved" stands even if a live key has since appeared (this launch's own
        // autosave write).
        XCTAssertEqual(decision(snapshot: [], liveKeyPresent: true), .positionAtLaunchWidth)
    }

    // MARK: - landedPosition(_:target:floor:)

    func testLandedPositionAcceptsWhereTheDividerReadsBackWithinOnePoint() {
        let target = OutlineSidebarWidth.idealWidth
        let floor = OutlineSidebarWidth.minWidth
        XCTAssertEqual(SplitViewAutosaveNaming.landedPosition(300, target: target, floor: floor), 300)
        XCTAssertEqual(SplitViewAutosaveNaming.landedPosition(300.9, target: target, floor: floor), 300.9)
        XCTAssertEqual(SplitViewAutosaveNaming.landedPosition(250, target: target, floor: floor), 250)
    }

    func testLandedPositionRejectsAnythingElse() {
        let target = OutlineSidebarWidth.idealWidth
        let floor = OutlineSidebarWidth.minWidth
        XCTAssertNil(SplitViewAutosaveNaming.landedPosition(301.5, target: target, floor: floor))
        XCTAssertNil(SplitViewAutosaveNaming.landedPosition(260, target: target, floor: floor))
        XCTAssertNil(SplitViewAutosaveNaming.landedPosition(nil, target: target, floor: floor))
    }
}
