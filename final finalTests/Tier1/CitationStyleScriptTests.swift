//
//  CitationStyleScriptTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  The JavaScript call that pushes a CSL style into a Rich Text page
//  (`MilkdownEditor.Coordinator.setCitationStyleScript`, shared by the live view's
//  `setCitationStyle` and by `EditorPreloader`'s push into the standby page) must hand the
//  page exactly the style text it was given. Two things depend on that:
//
//  1. A style containing a backtick, a backslash or `${` must not break out of the JS
//     template literal (the original bug the shared `escapedForJSTemplateLiteral` helper
//     exists for).
//  2. The page skips a push whose text is identical to the style it already runs
//     (`CiteprocEngine.setStyle`), and a fresh page runs the bundled Chicago style. So the
//     bundled `.csl` file must arrive byte-for-byte unchanged, or every default-style user
//     would pay the engine rebuild again at every Rich Text mount.
//
//  The script is evaluated in JavaScriptCore against a stub `window.FinalFinal` that
//  records what `setCitationStyle` received, so the real escaping is exercised end to end.
//

import Foundation
import JavaScriptCore
import Testing
@testable import final_final

@Suite("Citation style push script")
@MainActor
struct CitationStyleScriptTests {

    /// What a page's `window.FinalFinal.setCitationStyle` receives when it is sent `setCitationStyleScript(styleXML)`;
    /// nil if the script threw (its exception is recorded as a test issue).
    private func received(_ styleXML: String) -> String? {
        guard let context = JSContext() else {
            Issue.record("JavaScriptCore could not create a context")
            return nil
        }
        context.evaluateScript("var received = null; var window = { FinalFinal: { setCitationStyle: function (s) { received = s; } } };")
        context.evaluateScript(MilkdownEditor.Coordinator.setCitationStyleScript(styleXML))
        if let exception = context.exception {
            Issue.record("The script threw: \(exception)")
            return nil
        }
        return context.objectForKeyedSubscript("received")?.toString()
    }

    @Test("Backticks, backslashes and ${ arrive unchanged")
    func templateLiteralSpecialsRoundTrip() {
        let style = "<style a=\"`tick`\" b=\"back\\slash\\\\double\" c=\"${notInterpolated}\" d=\"\\`escaped\\${also}\">end</style>"
        #expect(received(style) == style)
    }

    @Test("Line endings are normalised to newlines and NUL bytes dropped, as the shared escaper documents")
    func lineEndingsAndNulNormalised() {
        #expect(received("one\r\ntwo\rthree\0four") == "one\ntwo\nthreefour")
    }

    @Test("The bundled Chicago style arrives byte-for-byte unchanged")
    func bundledStyleArrivesUnchanged() throws {
        guard let url = Bundle.main.url(forResource: "chicago-author-date", withExtension: "csl", subdirectory: "Export") else {
            Issue.record("The bundled chicago-author-date.csl is not in the app bundle")
            return
        }
        let style = try String(contentsOf: url, encoding: .utf8)
        #expect(!style.isEmpty)
        #expect(received(style) == style)
    }
}
