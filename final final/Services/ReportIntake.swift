//
//  ReportIntake.swift
//  final final
//
//  Phase 5: the Rich Text page's report configuration. Job B2 built this file as the SHADOW reports' recorder and their comparison
//  with the 2-second poll (`[PUSH-CMP]`); job B3 made the reports the writer's input (`ReportApplier`), and job B4 removed the poll and
//  that comparison with it (b2-b4-design.md 4.2). What is left is the document-start script that turns reporting on in the page and
//  passes the test-only switches (`window.__FF_REPORTS__`, read by web/milkdown/src/report-outbox.ts).
//

import WebKit

enum ReportIntake {
    /// The document-start script that turns the Rich Text page's reports on, with the test-only switches: R
    /// (`FF_UI_TESTING_REPORT_INTERVAL_MS`) and the re-post (`FF_UI_TESTING_PUSH_REPOST_OFF`). Added to every Rich Text page's
    /// configuration (MilkdownEditor.swift, EditorPreloader.swift).
    static func configUserScript() -> WKUserScript {
        let interval = TestMode.uiTestingReportIntervalMs.map { ", intervalMs: \($0)" } ?? ""
        let repost = TestMode.isUITestingPushRepostOff ? ", repost: false" : ""
        return WKUserScript(
            source: "window.__FF_REPORTS__ = { enabled: true\(interval)\(repost) };",
            injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }
}
