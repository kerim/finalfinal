//
//  BibliographyRegenerationPositionTestSupport.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//
//  Shared Zotero-item-loading fixture for the bibliography-regeneration-position regression
//  suite (BibliographyRegenerationPositionTests.swift, BibliographyRegenerationEdgeCaseTests.swift,
//  and BibliographyRegenerationAnchorHijackTests.swift) -- factored out so each concern's test
//  file doesn't duplicate this lookup logic. See BibliographyRegenerationPositionTests.swift for
//  the full feature background comment shared by every file in this suite.
//

import Foundation
@testable import final_final

@MainActor
enum BibliographyRegenerationFixtures {
    static func loadItem(citekey: String, family: String, given: String, year: Int) throws {
        let json = """
        {"id":"\(citekey)","type":"book","title":"Title \(citekey)",
        "author":[{"family":"\(family)","given":"\(given)"}],"issued":{"date-parts":[[\(year)]]}}
        """
        let item = try JSONDecoder().decode(CSLItem.self, from: Data(json.utf8))
        ZoteroService.shared.loadItem(item)
    }
}
