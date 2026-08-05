//
//  AutosaveKeySweepTests.swift
//  final finalTests
//

import Testing
@testable import final_final

struct AutosaveKeySweepTests {

    /// Realistic SwiftUI-derived window autosave key, as observed via the diagnostic log
    /// capture referenced in `AppDelegate+WindowFramePersistence.swift`, and matching the real
    /// shape (`...-1-AppWindow-1`) captured from the live `com.kerim.final-final` domain.
    private let swiftUIWindowKey = "NSWindow Frame SwiftUI.ModifiedContent<Placeholder>-1-AppWindow-1"
    private let swiftUIWindowName = "SwiftUI.ModifiedContent<Placeholder>-1-AppWindow-1"

    private let swiftUISplitViewKey = "NSSplitView Subview Frames SwiftUI.NavigationSplitView<Placeholder>-1"
    private let swiftUISplitViewName = "SwiftUI.NavigationSplitView<Placeholder>-1"

    @Test func bothRealPrefixesContainingSwiftUIAreSweptPlainKeysAreNot() {
        let domainKeys: Set<String> = [
            swiftUIWindowKey,
            swiftUISplitViewKey,
            "com.kerim.final-final.mainWindowFrame",
            "isSpellingEnabled",
            "NSWindow Frame AppWindow-1"
        ]
        let result = AutosaveKeySweep.keysToSweep(
            domainKeys: domainKeys,
            liveWindowAutosaveNames: ["some-other-live-window-name"],
            liveSplitViewAutosaveNames: ["some-other-live-splitview-name"]
        )
        #expect(Set(result) == [swiftUIWindowKey, swiftUISplitViewKey])
    }

    @Test func namespaceRegressionWindowKeyProtectedByMatchingLiveName() {
        let domainKeys: Set<String> = [swiftUIWindowKey]
        let result = AutosaveKeySweep.keysToSweep(
            domainKeys: domainKeys,
            liveWindowAutosaveNames: [swiftUIWindowName],
            liveSplitViewAutosaveNames: []
        )
        #expect(result.isEmpty)
    }

    @Test func namespaceRegressionSplitViewKeyProtectedByMatchingLiveName() {
        let domainKeys: Set<String> = [swiftUISplitViewKey]
        let result = AutosaveKeySweep.keysToSweep(
            domainKeys: domainKeys,
            liveWindowAutosaveNames: [],
            liveSplitViewAutosaveNames: [swiftUISplitViewName]
        )
        #expect(result.isEmpty)
    }

    /// A name observed off ONE object (here, only ever passed as the window's live name) still
    /// protects the corresponding key in the OTHER namespace, because the protected set is
    /// built from the union of both live-name sets — a live name is a live name regardless of
    /// which object it was read off. The split-view valve is deliberately left open (a
    /// different, unrelated live split-view name) so this actually exercises protection rather
    /// than the split-view candidate being skipped by the safety valve.
    @Test func bareNameProtectsBothPrefixedFormsSimultaneouslyViaTheUnion() {
        let bareName = "SwiftUI.SharedDerivedName-1-AppWindow-1"
        let windowKey = "NSWindow Frame \(bareName)"
        let splitViewKey = "NSSplitView Subview Frames \(bareName)"
        let domainKeys: Set<String> = [windowKey, splitViewKey]
        let result = AutosaveKeySweep.keysToSweep(
            domainKeys: domainKeys,
            liveWindowAutosaveNames: [bareName],
            liveSplitViewAutosaveNames: ["some-unrelated-live-splitview-name"]
        )
        #expect(result.isEmpty)
    }

    /// (b)-abandoned branch: the split view still carries SwiftUI's own derived name (not
    /// `final-final.mainSplitView`) because (b) either didn't ship or refused to act. That
    /// exact key must survive the sweep, while other SwiftUI.-candidates unrelated to it are
    /// still swept.
    @Test func bAbandonedBranchProtectsSwiftUIsOwnDerivedSplitViewName() {
        let derivedSplitViewName = "SwiftUI.ModifiedContent<NavigationSplitView>-1"
        let liveSplitViewKey = "NSSplitView Subview Frames \(derivedSplitViewName)"
        let staleWindowKey = "NSWindow Frame SwiftUI.ModifiedContent<Other>-2-AppWindow-2"
        let domainKeys: Set<String> = [liveSplitViewKey, staleWindowKey]
        let result = AutosaveKeySweep.keysToSweep(
            domainKeys: domainKeys,
            liveWindowAutosaveNames: ["some-other-live-window-name"],
            liveSplitViewAutosaveNames: [derivedSplitViewName]
        )
        #expect(result == [staleWindowKey])
    }

    @Test func emptyLiveAutosaveNamesReturnsEmptyEvenWithManyCandidates() {
        let domainKeys: Set<String> = [
            swiftUIWindowKey,
            swiftUISplitViewKey,
            "NSWindow Frame SwiftUI.Another-3-AppWindow-3",
            "NSSplitView Subview Frames SwiftUI.Another-4"
        ]
        let result = AutosaveKeySweep.keysToSweep(
            domainKeys: domainKeys,
            liveWindowAutosaveNames: [],
            liveSplitViewAutosaveNames: []
        )
        #expect(result.isEmpty)
    }

    @Test func domainWithNoCandidatesReturnsEmpty() {
        let domainKeys: Set<String> = [
            "com.kerim.final-final.mainWindowFrame",
            "isSpellingEnabled"
        ]
        let result = AutosaveKeySweep.keysToSweep(
            domainKeys: domainKeys,
            liveWindowAutosaveNames: ["live-window-name"],
            liveSplitViewAutosaveNames: ["live-splitview-name"]
        )
        #expect(result.isEmpty)
    }

    @Test func idempotencyFeedingPostSweepDomainBackInReturnsEmptyAgain() {
        let liveWindowAutosaveNames: Set<String> = ["live-window-name"]
        let liveSplitViewAutosaveNames: Set<String> = ["live-splitview-name"]
        let initialDomainKeys: Set<String> = [
            swiftUIWindowKey,
            swiftUISplitViewKey,
            "com.kerim.final-final.mainWindowFrame"
        ]
        let firstSweep = AutosaveKeySweep.keysToSweep(
            domainKeys: initialDomainKeys,
            liveWindowAutosaveNames: liveWindowAutosaveNames,
            liveSplitViewAutosaveNames: liveSplitViewAutosaveNames
        )
        #expect(Set(firstSweep) == [swiftUIWindowKey, swiftUISplitViewKey])

        var postSweepDomainKeys = initialDomainKeys
        for key in firstSweep { postSweepDomainKeys.remove(key) }

        let secondSweep = AutosaveKeySweep.keysToSweep(
            domainKeys: postSweepDomainKeys,
            liveWindowAutosaveNames: liveWindowAutosaveNames,
            liveSplitViewAutosaveNames: liveSplitViewAutosaveNames
        )
        #expect(secondSweep.isEmpty)
    }

    @Test func stableNamedSplitViewKeyIsNeverSwept() {
        let stableKey = "NSSplitView Subview Frames final-final.mainSplitView"
        let domainKeys: Set<String> = [stableKey]
        let result = AutosaveKeySweep.keysToSweep(
            domainKeys: domainKeys,
            liveWindowAutosaveNames: [],
            liveSplitViewAutosaveNames: ["final-final.mainSplitView"]
        )
        #expect(result.isEmpty)
    }

    // MARK: - MF1: per-namespace safety valve

    /// The core MF1 regression test: an unobserved (empty) split-view live-name set must block
    /// sweeping ONLY `NSSplitView Subview Frames ` candidates — window-namespace sweeping must
    /// proceed normally alongside it. Before this fix, a single global valve gated on "either
    /// name present" never actually fired (the window name is essentially always observed), so
    /// a genuinely-unobserved split-view name never protected anything.
    @Test func emptySplitViewLiveNameBlocksSplitViewSweepButWindowSweepStillProceeds() {
        let domainKeys: Set<String> = [swiftUIWindowKey, swiftUISplitViewKey]
        let result = AutosaveKeySweep.keysToSweep(
            domainKeys: domainKeys,
            liveWindowAutosaveNames: ["some-other-live-window-name"],
            liveSplitViewAutosaveNames: []
        )
        #expect(result == [swiftUIWindowKey])
    }

    /// The mirror case (not the live risk today, per the review, but explicitly required as a
    /// "confirm the reverse doesn't regress" check): an unobserved window live-name set must
    /// block ONLY window-namespace sweeping, while split-view-namespace sweeping still proceeds.
    @Test func emptyWindowLiveNameBlocksWindowSweepButSplitViewSweepStillProceeds() {
        let domainKeys: Set<String> = [swiftUIWindowKey, swiftUISplitViewKey]
        let result = AutosaveKeySweep.keysToSweep(
            domainKeys: domainKeys,
            liveWindowAutosaveNames: [],
            liveSplitViewAutosaveNames: ["some-other-live-splitview-name"]
        )
        #expect(result == [swiftUISplitViewKey])
    }

    /// Confirms both namespaces active simultaneously still protect independently and correctly
    /// (not a regression from splitting the valve): each namespace's own matching live name
    /// protects its own key, with both valves open.
    @Test func bothNamespacesActiveSimultaneouslyEachProtectedIndependently() {
        let domainKeys: Set<String> = [swiftUIWindowKey, swiftUISplitViewKey]
        let result = AutosaveKeySweep.keysToSweep(
            domainKeys: domainKeys,
            liveWindowAutosaveNames: [swiftUIWindowName],
            liveSplitViewAutosaveNames: [swiftUISplitViewName]
        )
        #expect(result.isEmpty)
    }

    // MARK: - MF3: window-namespace candidates must also contain SceneID.mainWindow

    /// A key with the window prefix and `"SwiftUI."` but WITHOUT `SceneID.mainWindow`
    /// ("AppWindow") in it must not be swept, even with the window valve open and no live name
    /// matching it — this is deliberately-narrower-than-necessary insurance, not a fix for an
    /// observed bug (every real stale window key seen in the wild already carries this
    /// suffix — see the real-domain capture cited in `AutosaveKeySweep`'s doc comment).
    @Test func windowCandidateWithoutSceneIDSubstringIsNotSwept() {
        let keyWithoutAppWindow = "NSWindow Frame SwiftUI.SomeOtherWindowScene-1"
        #expect(!keyWithoutAppWindow.contains(SceneID.mainWindow))
        let domainKeys: Set<String> = [keyWithoutAppWindow]
        let result = AutosaveKeySweep.keysToSweep(
            domainKeys: domainKeys,
            liveWindowAutosaveNames: ["some-other-live-window-name"],
            liveSplitViewAutosaveNames: []
        )
        #expect(result.isEmpty)
    }

    /// Regression check against the exact key shapes captured from the real, live
    /// `com.kerim.final-final` domain before this task's fix landed (44 split-view + 53 window
    /// stale keys, all window keys tailed `...-1-AppWindow-1`, all split-view keys tailed
    /// `...-1-AppWindow-1, SidebarNavigationSplitView`) — confirms the added
    /// `contains(SceneID.mainWindow)` requirement on the window namespace does not shrink the
    /// real-world candidate set: both real-shaped keys are still swept when unobserved by a
    /// live name.
    @Test func realCapturedKeyShapesStillSweptUnderTheSceneIDRequirement() {
        let realWindowKeyShape =
            "NSWindow Frame SwiftUI.ModifiedContent<SwiftUI._ValueActionModifier2<final_final.AppViewState>>, "
                + "SwiftUI._AppearanceActionModifier>-1-AppWindow-1"
        let realSplitViewKeyShape =
            "NSSplitView Subview Frames SwiftUI.ModifiedContent<SwiftUI._AppearanceActionModifier>-1-AppWindow-1, "
                + "SidebarNavigationSplitView"
        let domainKeys: Set<String> = [realWindowKeyShape, realSplitViewKeyShape]
        let result = AutosaveKeySweep.keysToSweep(
            domainKeys: domainKeys,
            liveWindowAutosaveNames: ["this-launch-s-own-live-window-name"],
            liveSplitViewAutosaveNames: ["this-launch-s-own-live-splitview-name"]
        )
        #expect(Set(result) == [realWindowKeyShape, realSplitViewKeyShape])
    }
}
