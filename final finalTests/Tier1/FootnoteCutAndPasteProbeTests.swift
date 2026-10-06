//
//  FootnoteCutAndPasteProbeTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Diagnostic round (Phase 3a-2 Step 5): a PROBE of the trade-off behind the 3 second footnote debounce. Cutting a
//  sentence that contains a footnote and pasting it elsewhere is one delete and one new reference. The judge's
//  prediction: if the paste lands AFTER the debounce has fired (the removal has run), the pasted reference comes
//  back with a BLANK definition, because the undo checkpoint only matches the exact earlier document and a
//  reference typed or pasted elsewhere must never inherit old text (the stale-row rule). If the paste lands
//  BEFORE the removal fires, the equal-refs branch cancels the removal and the definition stays untouched.
//  These tests state the prediction as an assertion; a failure means the trade-off is not real.
//
//  `flushPendingSync()` stands in for the 3 second debounce firing.
//

import Testing
import Foundation
@testable import final_final

private enum CutPasteDoc {
    static let seed = "# A\n\nOne[^1] two.\n\nThree.\n\n# Notes\n\n[^1]: Kept."
    /// The sentence is cut: the reference is gone (the editor still shows the Notes at this point).
    static let afterCut = "# A\n\nThree.\n\n# Notes\n\n[^1]: Kept."
    /// Pasted at the end of the paragraph after the removal fired: the editor has no Notes any more.
    static let pastedAfterRemoval = "# A\n\nThree. One[^1] two."
    /// Pasted before the removal fired: the editor still shows the Notes.
    static let pastedBeforeRemoval = "# A\n\nThree. One[^1] two.\n\n# Notes\n\n[^1]: Kept."
}

private func definitionFragments(_ db: ProjectDatabase) throws -> [String] {
    try TestFixtureFactory.fetchBlocks(from: db)
        .filter { $0.isNotes && $0.blockType == .paragraph }
        .map(\.markdownFragment)
}

@Suite("Footnote cut and paste probe — a sentence with a footnote cut and pasted elsewhere")
@MainActor
struct FootnoteCutAndPasteProbeTests {

    /// Known references established as in U-F2: the first write commits `["1"]`, an ordinary keystroke records the content.
    private func serviceWithKnownReference(db: ProjectDatabase, projectId: String) async -> FootnoteSyncService {
        let service = FootnoteSyncService()
        service.configure(database: db, projectId: projectId)
        service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: projectId, fullContent: CutPasteDoc.seed)
        await service.flushPendingSync()
        service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: projectId, fullContent: CutPasteDoc.seed)
        return service
    }

    @Test("""
        Probe, paste AFTER the removal fired: the pasted reference comes back with a BLANK definition and the cut \
        sentence's text ("Kept.") is gone (prediction; the checkpoint matches only the exact earlier document)
        """)
    func pasteAfterTheRemovalFiredComesBackBlank() async throws {
        let db = try TestFixtureFactory.createTemporary(content: CutPasteDoc.seed)
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        let service = await serviceWithKnownReference(db: db, projectId: projectId)

        // CUT: the reference leaves the document, the debounce fires, the removal runs.
        service.checkAndUpdateFootnotes(footnoteRefs: [], projectId: projectId, fullContent: CutPasteDoc.afterCut)
        await service.flushPendingSync()
        #expect(try definitionFragments(db).isEmpty, "the removal must have run (test setup)")

        // PASTE elsewhere: the same reference is back, but the document is not the one before the cut.
        service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: projectId, fullContent: CutPasteDoc.pastedAfterRemoval)
        await service.flushPendingSync()

        let definitions = try definitionFragments(db)
        #expect(definitions.count == 1, "the pasted reference gets a definition row; got \(definitions)")
        #expect(
            definitions.allSatisfy { FootnoteSyncService.parseNotesLabel(from: $0)?.text.isEmpty == true },
            "PREDICTION: the definition is BLANK; got \(definitions)")
        #expect(!definitions.contains { $0.contains("Kept.") }, "the cut sentence's text must not come back; got \(definitions)")
    }

    @Test("""
        Probe, paste BEFORE the removal fires: the equal-refs branch cancels the removal, so the definition stays \
        "Kept." intact and no checkpoint is made
        """)
    func pasteBeforeTheRemovalFiresKeepsTheDefinition() async throws {
        let db = try TestFixtureFactory.createTemporary(content: CutPasteDoc.seed)
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        let service = await serviceWithKnownReference(db: db, projectId: projectId)

        // CUT: the removal is scheduled but has not fired.
        service.checkAndUpdateFootnotes(footnoteRefs: [], projectId: projectId, fullContent: CutPasteDoc.afterCut)
        #expect(service.testHasPendingUpdate, "the cut must have scheduled the removal (test setup)")

        // PASTE before it fires: the references equal the committed ["1"] again.
        service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: projectId, fullContent: CutPasteDoc.pastedBeforeRemoval)
        #expect(!service.testHasPendingUpdate, "the equal-refs branch must cancel the scheduled removal")
        await service.flushPendingSync()

        let definitions = try definitionFragments(db)
        #expect(
            definitions.contains { $0.hasPrefix("[^1]:") && $0.contains("Kept.") },
            "the definition must be intact; got \(definitions)")
        #expect(service.undoCheckpoints.isEmpty, "nothing was deleted, so no checkpoint")
    }
}
