//
//  AppDelegate+AutosaveKeyTracking.swift
//  final final
//
//  One-time sweep of stale, SwiftUI-derived AppKit autosave keys left behind in UserDefaults by
//  earlier launches whose main-window WindowGroup lacked a stable `id:` (see SceneID.swift for
//  the fix that stops new stale keys from being created going forward). Pure filtering logic
//  lives in AutosaveKeySweep.swift; this file is the AppKit/UserDefaults glue.
//

import AppKit

extension AppDelegate {
    /// Schedules the one-time dead-key sweep ~5 seconds after the main window is first
    /// captured — clear of the launch-critical path. Guarded so it only ever schedules once,
    /// even though this is called from both places `disableFrameAutosave` is (the normal
    /// launch path and the FB15577018 recovery fallback).
    func scheduleAutosaveKeySweep() {
        guard !TestMode.isTesting else { return }
        guard !autosaveKeySweepScheduled else { return }
        autosaveKeySweepScheduled = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.performAutosaveKeySweep()
        }
    }

    private func performAutosaveKeySweep() {
        guard !TestMode.isTesting else { return }
        guard let bundleID = Bundle.main.bundleIdentifier else { return }

        // Read the live autosave names off the actual objects right now — not a name this app
        // merely intended to assign — so the sweep stays correct whether or not
        // SplitViewAutosaveNaming's stabilization attempt held. See that type's doc comment.
        // Kept as two SEPARATE sets, not merged: AutosaveKeySweep.keysToSweep's safety valve is
        // per-namespace, so the split-view set being empty (app still on the picker, project
        // load slower than the 5s sweep delay, or the split-view count check refusing to act)
        // must block ONLY split-view-namespace sweeping, not the window namespace too.
        var liveWindowAutosaveNames: Set<String> = []
        if let capturedWindowFrameAutosaveName, !capturedWindowFrameAutosaveName.isEmpty {
            liveWindowAutosaveNames.insert(capturedWindowFrameAutosaveName)
        }

        var liveSplitViewAutosaveNames: Set<String> = []
        if let mainWindow, let splitViewName = SplitViewAutosaveNaming.currentTopLevelAutosaveName(in: mainWindow) {
            liveSplitViewAutosaveNames.insert(splitViewName)
        }

        DispatchQueue.global(qos: .utility).async {
            guard let domain = UserDefaults.standard.persistentDomain(forName: bundleID) else { return }
            let domainKeys = Set(domain.keys)
            let keysToRemove = AutosaveKeySweep.keysToSweep(
                domainKeys: domainKeys,
                liveWindowAutosaveNames: liveWindowAutosaveNames,
                liveSplitViewAutosaveNames: liveSplitViewAutosaveNames
            )

            DebugLog.log(
                .lifecycle,
                "[AppDelegate] Autosave key sweep: liveWindowAutosaveNames=\(liveWindowAutosaveNames), "
                    + "liveSplitViewAutosaveNames=\(liveSplitViewAutosaveNames), "
                    + "\(keysToRemove.count) stale key(s) to remove: \(keysToRemove)"
            )

            guard !keysToRemove.isEmpty else { return }

            DispatchQueue.main.async {
                Self.removeAutosaveKeys(keysToRemove)
            }
        }
    }

    /// Body is ONLY the deletion loop. Nothing may follow the loop inside this
    /// function, and this call must be the last statement of its dispatch block —
    /// a UserDefaults read in the same run-loop turn after these writes is the
    /// documented ~5s cfprefsd hang (see flushWindowFrame, lines 126-136).
    private static func removeAutosaveKeys(_ keys: [String]) {
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }
}
