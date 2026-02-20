# Deferred: Replace LanguageTool with Built-In Grammar Check

## Motivation

macOS has built-in grammar checking via `NSSpellChecker.checkGrammarOfString` and `NSTextCheckingResult.resultType == .grammar`. If Apple improves the quality and coverage of this API, it could replace LanguageTool for grammar checking — removing the dependency on an external service entirely.

## Current State

During initial development, `NSSpellChecker.check(_:range:types:options:...)` with `NSTextCheckingAllTypes` was tested. Results:
- **Spelling**: Works reliably and is used as the primary spelling provider.
- **Grammar**: Returns `.grammar` results inconsistently. TextEdit's grammar checking (which users see when editing rich text) appears to use a different, higher-quality pipeline that is not fully exposed through `NSSpellChecker`'s public API.

The `.grammar` results that do come back are sparse and miss many issues that LanguageTool catches.

## When to Revisit

- If Apple announces improvements to `NSSpellChecker` grammar checking (WWDC, release notes)
- If a new Apple framework for text proofing appears (e.g., via Foundation Models or Writing Tools API)
- If `NSTextCheckingResult` gains new result types for style suggestions

## Migration Path

The `ProofingProvider` protocol already abstracts the provider interface. Replacing LanguageTool would mean:
1. Enhancing `BuiltInProvider` to also return grammar/style results
2. Adding a new `ProofingMode` case or modifying `builtIn` to include grammar
3. Removing the LanguageTool dependency from `SpellCheckService.check()` dispatch logic

## Status

Deferred — blocked on Apple improving the public grammar checking API.
