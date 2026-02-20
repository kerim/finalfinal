//
//  ProofingProvider.swift
//  final final
//
//  Protocol for proofing backends (NSSpellChecker, LanguageTool, etc.)
//

import Foundation

@MainActor
protocol ProofingProvider {
    func check(segments: [SpellCheckService.TextSegment]) async -> [SpellCheckService.SpellCheckResult]
    func learnWord(_ word: String)
    func ignoreWord(_ word: String)
}
