//
//  ZoteroLibraryScopeTests+CaseInsensitivity.swift
//  final finalTests
//
//  Split out of ZoteroLibraryScopeTests.swift to keep that file's struct body under SwiftLint's
//  type_body_length limit (300 lines) after this test was added. Same suite/fixture context
//  applies — see the header comment in ZoteroLibraryScopeTests.swift for the full regression
//  background (the shared/group-library citekey resolve bug, live-captured vs. synthesized
//  fixtures, and the ZoteroNetworkTestLock cross-suite mutex).
//

import Testing
import Foundation
@testable import final_final

extension ZoteroLibraryScopeTests {

    @Test(
        """
        loadItem's offline path has no "requested" citekey to align casing with (unlike the \
        online fetch paths' cacheItems()), so a document citekey differing only in case from \
        the item's id must still resolve via getItem/hasItem/getItems
        """
    )
    @MainActor
    func loadItemResolvesCaseInsensitivelyAgainstDocumentCitekey() throws {
        // citations.json records the id in lower case, but the document text cites it in a
        // different case (e.g. typed by hand, or carried over from before a Zotero rename) —
        // this must still resolve offline instead of showing a red "(key?)" placeholder.
        let itemJSON = """
        {"id":"friedman2010","type":"chapter","title":"Entering the Mountains"}
        """
        let item = try JSONDecoder().decode(CSLItem.self, from: Data(itemJSON.utf8))

        let service = ZoteroService()
        service.loadItem(item)

        #expect(service.getItem(citekey: "Friedman2010") != nil)
        #expect(service.getItem(citekey: "Friedman2010")?.title == "Entering the Mountains")
        #expect(service.getItem(citekey: "FRIEDMAN2010") != nil)
        #expect(service.hasItem(citekey: "Friedman2010"))
        #expect(service.getItems(citekeys: ["Friedman2010"]).count == 1)

        // A genuinely different citekey (not just a case variant) must still miss.
        #expect(service.getItem(citekey: "notFriedman2010") == nil)
    }
}
