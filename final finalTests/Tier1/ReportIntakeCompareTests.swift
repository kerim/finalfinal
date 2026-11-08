//
//  ReportIntakeCompareTests.swift
//  final finalTests
//
//  Phase 5 job B4: `ReportIntake`'s B2 comparison (`[PUSH-CMP]`) was removed with the poll it compared against (b2-b4-design.md
//  4.2); what is left of `ReportIntake` is the page's report configuration, tested here. The file keeps its old name because
//  deleting or renaming it was not in the job's approved list (reported as CLEANUP-NEEDED in b4-notes.md).
//

import Testing
import WebKit
@testable import final_final

@Suite("ReportIntake: the Rich Text page's report configuration (Phase 5 B4)")
@MainActor
struct ReportIntakeCompareTests {
    @Test("the document-start script turns reporting on, before the page's own scripts run, in the main frame only")
    func configScriptTurnsReportingOn() {
        let script = ReportIntake.configUserScript()
        #expect(script.source.hasPrefix("window.__FF_REPORTS__ = { enabled: true"))
        #expect(script.injectionTime == .atDocumentStart)
        #expect(script.isForMainFrameOnly)
        // Outside UI testing the test-only switches add nothing (no interval override, the re-post stays on).
        #expect(!script.source.contains("repost: false"))
        #expect(!script.source.contains("intervalMs"))
    }
}
