//
//  ExportService+Fonts.swift
//  final final
//

import Foundation
import NaturalLanguage

// MARK: - Script Detection & Font Mapping

extension ExportService {

    private struct DetectedScripts: OptionSet, Sendable {
        let rawValue: UInt16
        static let cjk        = DetectedScripts(rawValue: 1 << 0)
        static let hiragana   = DetectedScripts(rawValue: 1 << 1)
        static let katakana   = DetectedScripts(rawValue: 1 << 2)
        static let hangul     = DetectedScripts(rawValue: 1 << 3)
        static let devanagari = DetectedScripts(rawValue: 1 << 4)
        static let thai       = DetectedScripts(rawValue: 1 << 5)
        static let bengali    = DetectedScripts(rawValue: 1 << 6)
        static let tamil      = DetectedScripts(rawValue: 1 << 7)
        static let all: DetectedScripts = [.cjk, .hiragana, .katakana, .hangul,
                                            .devanagari, .thai, .bengali, .tamil]
    }

    /// Single-pass Unicode range scan. Returns which non-Latin scripts are present.
    private func detectScripts(in content: String) -> DetectedScripts {
        var detected: DetectedScripts = []
        for scalar in content.unicodeScalars {
            detected.insert(classifyScript(scalar))
            if detected == .all { break }
        }
        return detected
    }

    /// Classify a single Unicode scalar into the script it belongs to (or none). Extracted
    /// verbatim from `detectScripts`'s former switch body — the 8 Unicode range groups are
    /// pairwise disjoint, so classifying scalar-by-scalar is behavior-identical to the
    /// original inline switch regardless of scan order.
    private func classifyScript(_ scalar: Unicode.Scalar) -> DetectedScripts {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF,
             0x20000...0x2A6DF:
            return .cjk
        case 0x3040...0x309F:
            return .hiragana
        case 0x30A0...0x30FF:
            return .katakana
        case 0xAC00...0xD7AF:
            return .hangul
        case 0x0900...0x097F:
            return .devanagari
        case 0x0E00...0x0E7F:
            return .thai
        case 0x0980...0x09FF:
            return .bengali
        case 0x0B80...0x0BFF:
            return .tamil
        default:
            return []
        }
    }

    /// Returns pandoc font variable arguments for PDF export.
    ///
    /// Uses a two-tier strategy:
    /// - Tier 1: Unicode range scanning determines WHETHER to add font support
    /// - Tier 2: NLLanguageRecognizer disambiguates WHICH CJK font (SC vs TC)
    func fontArguments(for content: String) -> [String] {
        let scripts = detectScripts(in: content)
        var args = cjkFontArguments(for: scripts, content: content)
        args.append(contentsOf: mainFontArguments(for: scripts))
        if !args.isEmpty {
            DebugLog.log(.fileOps, "[ExportService] Font arguments: \(args)")
        }
        return args
    }

    private func cjkFontArguments(for scripts: DetectedScripts, content: String) -> [String] {
        let needsCJK = !scripts.isDisjoint(with: [.cjk, .hiragana, .katakana, .hangul])
        guard needsCJK else { return [] }

        let font: String
        if !scripts.isDisjoint(with: [.hiragana, .katakana]) {
            font = "Hiragino Mincho ProN"
        } else if scripts.contains(.hangul) {
            font = "Apple SD Gothic Neo"
        } else {
            font = disambiguateCJKFont(in: content)
        }
        return ["-V", "CJKmainfont=\(font)"]
    }

    private func mainFontArguments(for scripts: DetectedScripts) -> [String] {
        let mainFontMap: [(script: DetectedScripts, font: String)] = [
            (.devanagari, "Kohinoor Devanagari"),
            (.thai, "Thonburi"),
            (.bengali, "Bangla Sangam MN"),
            (.tamil, "Tamil Sangam MN")
        ]
        guard let match = mainFontMap.first(where: { scripts.contains($0.script) }) else {
            return []
        }
        return ["-V", "mainfont=\(match.font)"]
    }

    /// Use NLLanguageRecognizer on CJK-only text to distinguish Simplified vs Traditional Chinese.
    /// Filtering to CJK characters avoids the recognizer being overwhelmed by English content.
    /// Default: Traditional Chinese (most users writing about Taiwan/HK).
    private func disambiguateCJKFont(in content: String) -> String {
        // Extract only CJK characters for reliable SC vs TC detection
        let cjkText = String(content.unicodeScalars.filter {
            let codePoint = $0.value
            return (0x4E00...0x9FFF).contains(codePoint) ||
                   (0x3400...0x4DBF).contains(codePoint) ||
                   (0xF900...0xFAFF).contains(codePoint) ||
                   (0x20000...0x2A6DF).contains(codePoint)
        })

        guard !cjkText.isEmpty else { return "Songti TC" }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(cjkText)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 10)

        if let scConfidence = hypotheses[.simplifiedChinese],
           let tcConfidence = hypotheses[.traditionalChinese],
           scConfidence > tcConfidence {
            return "Songti SC"
        }
        // Default to Traditional Chinese
        return "Songti TC"
    }
}
