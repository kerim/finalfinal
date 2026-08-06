//
//  PandocCitationParsingTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Characterization tests for `parsePandocCitation` (ZoteroService.swift), written against
//  its pre-refactor behavior before the cyclomatic-complexity cleanup that splits it into
//  several private helper functions. `parsePandocCitation` previously had zero direct test
//  coverage — only the two CAYW call sites exercised it indirectly — so a suite passing
//  "before" and "after" the refactor is the only proof the split preserves every outcome.
//

import Testing
@testable import final_final

@Suite("Pandoc Citation Parsing — Tier 1: Silent Killers")
struct PandocCitationParsingTests {

    @Test("Single bare citekey")
    func singleBareCitekey() {
        let result = parsePandocCitation("[@key]")
        #expect(result?.entries.count == 1)
        let entry = result?.entries.first
        #expect(entry?.citekey == "key")
        #expect(entry?.prefix == nil)
        #expect(entry?.locator == nil)
        #expect(entry?.suffix == nil)
        #expect(entry?.suppressAuthor == false)
    }

    @Test("Citekey with a locator")
    func citekeyWithLocator() {
        let result = parsePandocCitation("[@key, p. 45]")
        #expect(result?.entries.count == 1)
        let entry = result?.entries.first
        #expect(entry?.citekey == "key")
        #expect(entry?.locator == "p. 45")
        #expect(entry?.prefix == nil)
        #expect(entry?.suppressAuthor == false)
    }

    @Test("Suppress-author form")
    func suppressAuthorForm() {
        let result = parsePandocCitation("[-@key]")
        #expect(result?.entries.count == 1)
        let entry = result?.entries.first
        #expect(entry?.citekey == "key")
        #expect(entry?.suppressAuthor == true)
        #expect(entry?.prefix == nil)
    }

    @Test("Multi-entry citation with a prefix on the first entry")
    func multiEntryWithPrefix() {
        let result = parsePandocCitation("[see @a; @b]")
        #expect(result?.entries.count == 2)
        #expect(result?.entries[0].citekey == "a")
        #expect(result?.entries[0].prefix == "see")
        #expect(result?.entries[0].suppressAuthor == false)
        #expect(result?.entries[1].citekey == "b")
        #expect(result?.entries[1].prefix == nil)
        #expect(result?.entries[1].suppressAuthor == false)
    }

    @Test("Prefix combined with suppress-author (\"see -@key\")")
    func prefixWithSuppressAuthor() {
        let result = parsePandocCitation("[see -@key]")
        #expect(result?.entries.count == 1)
        let entry = result?.entries.first
        #expect(entry?.citekey == "key")
        #expect(entry?.prefix == "see")
        #expect(entry?.suppressAuthor == true)
    }

    @Test("Bare non-bracketed string returns nil")
    func bareNonBracketedStringReturnsNil() {
        #expect(parsePandocCitation("@key") == nil)
    }

    @Test("Empty brackets and brackets with no @ return nil")
    func emptyOrNoAtReturnsNil() {
        #expect(parsePandocCitation("[]") == nil)
        #expect(parsePandocCitation("[no at sign here]") == nil)
    }

    @Test("A part with no @ inside a multi-part bracket is skipped, others survive")
    func partWithNoAtIsSkipped() {
        let result = parsePandocCitation("[@a; noAt; @b]")
        #expect(result?.entries.count == 2)
        #expect(result?.entries[0].citekey == "a")
        #expect(result?.entries[1].citekey == "b")
    }

    @Test("Citekey with special characters (:, ., _, -)")
    func citekeyWithSpecialCharacters() {
        let result = parsePandocCitation("[@smith:2020_a.b-c]")
        #expect(result?.entries.count == 1)
        #expect(result?.entries.first?.citekey == "smith:2020_a.b-c")
    }

    @Test("Comma with nothing meaningful after it yields no locator")
    func commaWithNothingMeaningfulAfterYieldsNoLocator() {
        let noSpace = parsePandocCitation("[@key,]")
        #expect(noSpace?.entries.count == 1)
        #expect(noSpace?.entries.first?.citekey == "key")
        #expect(noSpace?.entries.first?.locator == nil)

        let withSpace = parsePandocCitation("[@key, ]")
        #expect(withSpace?.entries.count == 1)
        #expect(withSpace?.entries.first?.citekey == "key")
        #expect(withSpace?.entries.first?.locator == nil)
    }

    @Test("Special-character citekey combined with a locator in one entry")
    func specialCharacterCitekeyWithLocator() {
        let result = parsePandocCitation("[@smith.jones-2020, p. 45]")
        #expect(result?.entries.count == 1)
        let entry = result?.entries.first
        #expect(entry?.citekey == "smith.jones-2020")
        #expect(entry?.locator == "p. 45")
    }
}
