//
//  AutosaveKeySweep.swift
//  final final
//
//  Pure logic for identifying stale, SwiftUI-derived AppKit autosave keys left behind in
//  UserDefaults. No UserDefaults access, no AppKit dependency — trivially unit-testable.
//

enum AutosaveKeySweep {
    static let windowPrefix = "NSWindow Frame "
    static let splitViewPrefix = "NSSplitView Subview Frames "

    /// Returns the subset of `domainKeys` that are dead, SwiftUI-derived AppKit autosave keys —
    /// i.e. candidate keys whose bare autosave name is NOT among the corresponding live set.
    ///
    /// A key is only ever a CANDIDATE for sweeping if it has one of the two prefixes above AND
    /// contains `"SwiftUI."` — the marker of a SwiftUI-derived mangled type name, never a name
    /// this app assigns itself. `NSWindow Frame ` candidates must ADDITIONALLY contain
    /// `SceneID.mainWindow` ("AppWindow"): every stale window key observed in the wild already
    /// carries this suffix, so this is currently-redundant, cheap insurance rather than a fix
    /// for an observed bug — it makes it structurally impossible for the sweep to ever touch
    /// some other app-owned `NSWindow Frame SwiftUI....` key unrelated to the main window scene
    /// (e.g. a future secondary SwiftUI window). Split-view candidates carry no equivalent
    /// requirement: unlike the window case, there is no evidence every split-view-namespace key
    /// reliably contains that substring, so narrowing that filter risks under-sweeping instead.
    ///
    /// `liveWindowAutosaveNames`/`liveSplitViewAutosaveNames` are BARE AppKit autosave names as
    /// READ off the live objects (window.frameAutosaveName, splitView.autosaveName) — never
    /// prefixed defaults keys, and never a name this app merely intended to assign. Both
    /// prefixes are applied internally when building the protected set, so the caller cannot
    /// supply the wrong namespace.
    ///
    /// The safety valve is PER NAMESPACE, not global: an empty `liveWindowAutosaveNames` blocks
    /// sweeping `NSWindow Frame ` candidates ONLY, and an empty `liveSplitViewAutosaveNames`
    /// blocks sweeping `NSSplitView Subview Frames ` candidates ONLY — each namespace's
    /// candidates are only ever considered when THAT namespace's own live-name set is
    /// non-empty. This matters because the window's live name is essentially always observed
    /// (so a single *global* valve gated on "either name present" would never actually fire),
    /// while the split view's live name can legitimately be unobserved (app launched into the
    /// picker with no project restored yet, a slow project load past the sweep's 5s mark, or
    /// the split-view count check finding something other than exactly one) — a global valve
    /// would silently let the sweep delete a split-view key AppKit might still be actively
    /// using for the real sidebar divider position. Once a namespace's valve is open, its
    /// candidates are still protected against ANY observed live name (window or split-view) —
    /// see the union below — not just a same-namespace one, since a live name is a live name
    /// regardless of which object it was read off.
    static func keysToSweep(domainKeys: Set<String>,
                            liveWindowAutosaveNames: Set<String>,
                            liveSplitViewAutosaveNames: Set<String>) -> [String] {
        let allLiveNames = liveWindowAutosaveNames.union(liveSplitViewAutosaveNames)
        let protected = Set(allLiveNames.flatMap { [windowPrefix + $0, splitViewPrefix + $0] })

        var swept: [String] = []

        if !liveWindowAutosaveNames.isEmpty {
            let windowCandidates = domainKeys.filter {
                $0.hasPrefix(windowPrefix) && $0.contains("SwiftUI.") && $0.contains(SceneID.mainWindow)
            }
            swept += windowCandidates.filter { !protected.contains($0) }
        }

        if !liveSplitViewAutosaveNames.isEmpty {
            let splitViewCandidates = domainKeys.filter {
                $0.hasPrefix(splitViewPrefix) && $0.contains("SwiftUI.")
            }
            swept += splitViewCandidates.filter { !protected.contains($0) }
        }

        return swept
    }
}
