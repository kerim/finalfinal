//
//  FootnoteSyncReconcileMixedOpsTests.swift
//  final finalTests
//
//  Split out of FootnoteSyncTests.swift to keep that file's struct body under SwiftLint's
//  type_body_length limit -- see the header comment there for the full footnote-sync
//  background (reference extraction, definition parsing, Notes section stripping). This file
//  covers reconcileNotesBlocks resolving a mixed insert+delete+rename in a single call.
//

import Testing
import Foundation
import GRDB
@testable import final_final

extension FootnoteSyncTests {

    @Test("reconcileNotesBlocks resolves a mixed insert+delete+rename in a single call")
    @MainActor
    func reconcileNotesBlocksHandlesMixedInsertDeleteRenameInOneCall() throws {
        let seed = """
        Body[^1] and[^2] and[^3] and[^5].

        # Notes

        [^1]: First real text.

        [^2]: Second real text.

        [^3]: Third real text.

        [^5]: Fifth real text.
        """
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let before = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
        let originalOne = try #require(before.first { $0.markdownFragment.hasPrefix("[^1]:") })
        let originalTwo = try #require(before.first { $0.markdownFragment.hasPrefix("[^2]:") })
        let originalThree = try #require(before.first { $0.markdownFragment.hasPrefix("[^3]:") })
        let originalFive = try #require(before.first { $0.markdownFragment.hasPrefix("[^5]:") })

        // A single reconcile call that simultaneously: renames [^2]->[^4], deletes [^5]
        // (no longer in the target set), inserts a brand-new [^6], and leaves [^1]
        // completely untouched.
        try db.write { database in
            try FootnoteSyncService.reconcileNotesBlocks(
                db: database,
                projectId: projectId,
                targetRefs: ["1", "3", "4", "6"],
                renameMap: ["2": "4"]
            )
        }

        let after = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
        #expect(after.count == 4, "Expected [^1], [^3], [^4] (was [^2]), [^6] (new)")

        // Untouched: [^1] was never in the rename map, delete set, or insert set — must
        // be the exact same row, never fetched-for-write.
        let untouchedOne = after.first { $0.id == originalOne.id }
        #expect(untouchedOne?.updatedAt == originalOne.updatedAt, "[^1] must keep its original updatedAt — proves zero writes")
        #expect(untouchedOne?.markdownFragment == originalOne.markdownFragment, "[^1] must keep its original text untouched")

        // Renamed: [^2] survives as [^4] under the same block id, with its original text
        // carried forward.
        let renamedTwo = after.first { $0.id == originalTwo.id }
        #expect(renamedTwo?.markdownFragment == "[^4]: Second real text.", "Original [^2] block survives rename to [^4] with its text intact")

        // Untouched-content: [^3] keeps its id and text even though the rename shuffling
        // [^2]->[^4] past it may bump its sortOrder/updatedAt during renormalization.
        let survivingThree = after.first { $0.id == originalThree.id }
        #expect(survivingThree?.markdownFragment == originalThree.markdownFragment, "[^3] keeps its original label and text")

        // Deleted: [^5] is gone entirely, no longer present under its old id or label.
        #expect(!after.contains { $0.id == originalFive.id }, "[^5] block must be deleted")
        #expect(!after.contains { $0.markdownFragment.hasPrefix("[^5]:") }, "No block should carry the [^5] label anymore")

        // Inserted: [^6] is a genuinely new row (not a reused id) with the expected blank
        // placeholder text.
        let newSix = try #require(after.first { $0.markdownFragment.hasPrefix("[^6]:") })
        #expect(newSix.markdownFragment == "[^6]: ", "New [^6] gets the default blank placeholder text")
        #expect(
            ![originalOne.id, originalTwo.id, originalThree.id, originalFive.id].contains(newSix.id),
            "The new [^6] placeholder is a genuinely new row, not a reused id"
        )
    }
}
