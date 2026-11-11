//
//  BibliographySyncService+ZoteroReady.swift
//  final final
//
//  Phase 7 (t-94369a83), board t-a54c1950: the part of `performBibliographyUpdate` that makes sure Zotero is reachable, split out so
//  the update itself stays inside SwiftLint's complexity and body-length limits. Design and proof:
//  docs/architecture/document-writer.md, "The first bibliography check asks Zotero itself (Phase 7)".
//

import Foundation

extension BibliographySyncService {
    /// The default answer of `connectToZotero`: ping Better BibTeX, which also marks the shared service connected. A unit-test run
    /// (`TestMode.isUnitTesting`) never reaches the network: a Zotero running on the developer's Mac would answer and change what every rig
    /// that leaves Zotero disconnected on purpose (no bibliography rebuild) expects.
    static func askZoteroByPing() async -> Bool {
        if TestMode.isUnitTesting { return false }
        return await ZoteroService.shared.ping()
    }

    /// Whether this bibliography run may go on, as far as Zotero is concerned.
    ///
    /// "Not marked connected" can simply mean the open-time connection (`ContentView.connectToZotero`) has not finished yet, for example
    /// on a big book whose open keeps the main thread busy. The run used to return at that point with nothing to retry it, so such a
    /// book opened with no Bibliography until the first edit. Now the run asks Zotero itself, so it no longer depends on which of the two
    /// ran first. Zotero genuinely not running still ends the run here, as before (`lastKnownCitekeys` stays uncommitted, so the next
    /// change of the citekeys schedules it again). A connected Zotero returns at once, with no suspension and no request.
    ///
    /// `isStillWanted` is evaluated after the question came back: it suspended this run, so a newer schedule, a lifecycle suspension or
    /// a manual regenerate may have superseded it meanwhile (the caller passes the same cancellation, generation and idle-state guard it
    /// uses before its first suspension).
    func zoteroIsReadyForThisRun(isStillWanted: () -> Bool) async -> Bool {
        if ZoteroService.shared.isConnected { return true }
        DebugLog.log(.zotero, "[BibliographySyncService] Zotero is not marked connected at the bibliography check; asking it now")
        guard await connectToZotero() else {
            DebugLog.log(.zotero, "[BibliographySyncService] Zotero did not answer; the bibliography check ends "
                + "(the next change of the citations tries again)")
            return false
        }
        return isStillWanted()
    }

    /// Fetches from Zotero the items of `uniqueCitekeys` that its cache does not hold yet, so the bibliography generated next from the
    /// cache is complete. A failed fetch is logged and the run goes on with what the cache has (moved here unchanged from
    /// `performBibliographyUpdate`).
    func fetchMissingZoteroItems(for uniqueCitekeys: [String]) async {
        let zoteroService = ZoteroService.shared
        let missingKeys = uniqueCitekeys.filter { !zoteroService.hasItem(citekey: $0) }
        guard !missingKeys.isEmpty else { return }
        do {
            _ = try await zoteroService.fetchItemsForCitekeys(missingKeys)
        } catch {
            DebugLog.log(.bib, "[BibliographySyncService] Failed to fetch items: \(error)")
        }
    }

    /// UI-test seam (`TestMode.isUITestingZoteroConnectHeld`): returns once the first bibliography update has made its attempt, or after
    /// `timeoutSeconds` so a document with nothing to check can never hold the connection back for good.
    func waitForFirstUpdateAttempt(timeoutSeconds: Double = 180) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while updateAttemptCount == 0, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
