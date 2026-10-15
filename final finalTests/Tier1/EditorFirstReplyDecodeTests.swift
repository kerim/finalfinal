//
//  EditorFirstReplyDecodeTests.swift
//  final finalTests
//
//  Tier 1 (t-94369a83 Phase 4b slice 2a fix round, item 17 / finding W12): the cross-language contract of Delete Section's one
//  JavaScript call. The Swift side used to be tested only against JSON that Swift itself encoded, so a renamed or reshaped field
//  in the editor's reply would have passed every Swift test. Here Swift decodes the reply the editor's OWN function produced.
//
//  `webFixture` is copied verbatim from `EDITOR_FIRST_DELETE_REPLY_FIXTURE` in
//  web/milkdown/src/__tests__/delete-section-editor-first.test.ts (test W12), where the real `deleteSectionEditorFirst` is run and
//  its reply is asserted equal to that string. If either side changes a field, the web test fails first; this copy then has to be
//  updated by hand to the new literal, and the decode below shows whether Swift still understands it.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import Testing
@testable import final_final

@Suite("Editor-first delete reply — Tier 1: Swift decodes the editor's own JSON (W12)")
struct EditorFirstReplyDecodeTests {

    /// The web test's `EDITOR_FIRST_DELETE_REPLY_FIXTURE`, character for character.
    /// Split into pieces only to stay under the line-length limit; the pieces join to exactly the web literal.
    private static let webFixture: String =
        #"{"batch":{"updates":[{"id":"a-p1","textContent":"Alpha one. TYPED-FIXTURE","# +
        #""markdownFragment":"Alpha one. TYPED-FIXTURE","blockType":"paragraph"}],"inserts":[],"deletes":[]},"# +
        #""ok":true,"removedIds":["brk","brk-p1","brk-1","brk-1-p1"],"removedLeaderIds":["brk","brk-1"],"# +
        #""predecessorId":"a-p1","removedSectionsSnapshot":[{"id":"brk","kind":"section_break","level":1,"title":""},"# +
        #"{"id":"brk-1","kind":"heading","level":2,"title":"Under the break"}]}"#

    @Test("the reply the editor's real function produced decodes: the batch, ok, the removed ids and the removed leaders")
    func testDecodesTheReplyTheEditorProduced() throws {
        let reply = try JSONDecoder().decode(EditorFirstDeleteReply.self, from: Data(Self.webFixture.utf8))

        #expect(reply.succeeded, "the editor's `ok` is Swift's `succeeded`")
        #expect(reply.reason == nil)
        #expect(reply.batch.updates.count == 1)
        #expect(reply.batch.updates.first?.id == "a-p1")
        #expect(reply.batch.updates.first?.textContent == "Alpha one. TYPED-FIXTURE", "the typing the call consumed travels in the batch")
        #expect(reply.batch.inserts.isEmpty && reply.batch.deletes.isEmpty)
        #expect(!reply.batch.isEmpty)
        #expect(reply.removedIds == ["brk", "brk-p1", "brk-1", "brk-1-p1"], "every block the removal deleted, in document order")
        #expect(reply.removedLeaderIds == ["brk", "brk-1"], "the headings and section breaks among them")
    }

    @Test("a reply without `removedIds` (an older editor) still decodes: the list is optional, no comparison is made")
    func testDecodesAReplyWithoutRemovedIds() throws {
        let withoutRemovedIds = #"{"batch":{"updates":[],"inserts":[],"deletes":[]},"ok":true,"removedLeaderIds":["h1"]}"#

        let reply = try JSONDecoder().decode(EditorFirstDeleteReply.self, from: Data(withoutRemovedIds.utf8))

        #expect(reply.succeeded)
        #expect(reply.removedIds == nil)
        #expect(reply.removedLeaderIds == ["h1"])
        #expect(reply.batch.isEmpty)
    }

    @Test("a refusal decodes with its reason, and the batch is still there to be applied")
    func testDecodesARefusalWithItsBatch() throws {
        let refusal = #"{"batch":{"updates":[{"id":"p","textContent":"typed","markdownFragment":"typed"}],"inserts":[],"deletes":[]},"# +
            #""ok":false,"reason":"noEditor","removedIds":[],"removedLeaderIds":[],"predecessorId":null,"removedSectionsSnapshot":[]}"#

        let reply = try JSONDecoder().decode(EditorFirstDeleteReply.self, from: Data(refusal.utf8))

        #expect(!reply.succeeded)
        #expect(reply.reason == "noEditor")
        #expect(reply.batch.updates.first?.id == "p", "the batch is applied even when the removal is refused")
    }
}
