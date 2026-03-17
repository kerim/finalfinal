//
//  SectionMetadataTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//  Tests for section status cycle, display names, Codable encoding,
//  and GoalStatus calculation with configurable thresholds.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Section Metadata — Tier 2: Visible Breakage")
struct SectionMetadataTests {

    // MARK: - SectionStatus Cycle

    @Test("nextStatus cycles: next → writing → waiting → review → final → next")
    func nextStatusFullCycle() {
        #expect(SectionStatus.next.nextStatus == .writing)
        #expect(SectionStatus.writing.nextStatus == .waiting)
        #expect(SectionStatus.waiting.nextStatus == .review)
        #expect(SectionStatus.review.nextStatus == .final_)
        #expect(SectionStatus.final_.nextStatus == .next)
    }

    @Test("displayName is correct for all 5 statuses")
    func displayNameAllStatuses() {
        #expect(SectionStatus.next.displayName == "Next")
        #expect(SectionStatus.writing.displayName == "Writing")
        #expect(SectionStatus.waiting.displayName == "Waiting")
        #expect(SectionStatus.review.displayName == "Review")
        #expect(SectionStatus.final_.displayName == "Final")
    }

    // MARK: - SectionStatus Codable

    @Test("SectionStatus.final_ encodes as 'final' and decodes back")
    func finalCodableRoundtrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Encode .final_ → should produce "final" (not "final_")
        let data = try encoder.encode(SectionStatus.final_)
        let jsonString = String(data: data, encoding: .utf8)!
        #expect(jsonString.contains("final"))
        #expect(!jsonString.contains("final_"))

        // Decode "final" → should produce .final_
        let decoded = try decoder.decode(SectionStatus.self, from: data)
        #expect(decoded == .final_)
    }

    @Test("SectionStatus round-trips all cases through Codable")
    func allStatusesCodableRoundtrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for status in SectionStatus.allCases {
            let data = try encoder.encode(status)
            let decoded = try decoder.decode(SectionStatus.self, from: data)
            #expect(decoded == status, "Round-trip failed for \(status)")
        }
    }

    // MARK: - GoalStatus.calculate — .min

    @Test("GoalStatus.calculate .min: below warning → .notMet, in warning → .warning, at 100% → .met")
    func goalStatusMin() {
        // 100 word goal, default thresholds (minWarning = 80%)
        // 50 words = 50% → notMet
        #expect(GoalStatus.calculate(wordCount: 50, goal: 100, goalType: .min) == .notMet)
        // 85 words = 85% → warning (≥80% but <100%)
        #expect(GoalStatus.calculate(wordCount: 85, goal: 100, goalType: .min) == .warning)
        // 100 words = 100% → met
        #expect(GoalStatus.calculate(wordCount: 100, goal: 100, goalType: .min) == .met)
        // 120 words = 120% → met (over goal is fine for min)
        #expect(GoalStatus.calculate(wordCount: 120, goal: 100, goalType: .min) == .met)
    }

    // MARK: - GoalStatus.calculate — .max

    @Test("GoalStatus.calculate .max: at 100% → .met, slightly over → .warning, far over → .notMet")
    func goalStatusMax() {
        // 100 word goal, default thresholds (maxWarning = 105%)
        // 90 words = 90% → met (under max)
        #expect(GoalStatus.calculate(wordCount: 90, goal: 100, goalType: .max) == .met)
        // 100 words = 100% → met (at max)
        #expect(GoalStatus.calculate(wordCount: 100, goal: 100, goalType: .max) == .met)
        // 103 words = 103% → warning (>100% but ≤105%)
        #expect(GoalStatus.calculate(wordCount: 103, goal: 100, goalType: .max) == .warning)
        // 110 words = 110% → notMet (>105%)
        #expect(GoalStatus.calculate(wordCount: 110, goal: 100, goalType: .max) == .notMet)
    }

    // MARK: - GoalStatus.calculate — .approx

    @Test("GoalStatus.calculate .approx: within 5% → .met, within 8% → .warning, beyond → .notMet")
    func goalStatusApprox() {
        // 100 word goal, default thresholds (green ±5%, orange ±8%)
        // 100 words = 0% deviation → met
        #expect(GoalStatus.calculate(wordCount: 100, goal: 100, goalType: .approx) == .met)
        // 96 words = 4% deviation → met
        #expect(GoalStatus.calculate(wordCount: 96, goal: 100, goalType: .approx) == .met)
        // 93 words = 7% deviation → warning
        #expect(GoalStatus.calculate(wordCount: 93, goal: 100, goalType: .approx) == .warning)
        // 85 words = 15% deviation → notMet
        #expect(GoalStatus.calculate(wordCount: 85, goal: 100, goalType: .approx) == .notMet)
        // 108 words = 8% deviation → warning (at boundary)
        #expect(GoalStatus.calculate(wordCount: 108, goal: 100, goalType: .approx) == .warning)
    }

    // MARK: - GoalStatus.calculate — edge cases

    @Test("GoalStatus.calculate with nil goal → .noGoal")
    func goalStatusNilGoal() {
        #expect(GoalStatus.calculate(wordCount: 50, goal: nil, goalType: .min) == .noGoal)
    }

    @Test("GoalStatus.calculate with zero goal → .noGoal")
    func goalStatusZeroGoal() {
        #expect(GoalStatus.calculate(wordCount: 50, goal: 0, goalType: .min) == .noGoal)
    }

    // MARK: - GoalThresholds

    @Test("GoalThresholds.defaults has expected values (80, 105, 5, 8)")
    func goalThresholdsDefaults() {
        let defaults = GoalThresholds.defaults
        #expect(defaults.minWarningPercent == 80)
        #expect(defaults.maxWarningPercent == 105)
        #expect(defaults.approxGreenPercent == 5)
        #expect(defaults.approxOrangePercent == 8)
    }

    @Test("Custom thresholds change GoalStatus behavior")
    func customThresholdsChangeBehavior() {
        // With stricter min threshold (90% instead of 80%)
        let strict = GoalThresholds(
            minWarningPercent: 90,
            maxWarningPercent: 105,
            approxGreenPercent: 5,
            approxOrangePercent: 8
        )

        // 85% with default (80%) → .warning; with strict (90%) → .notMet
        #expect(GoalStatus.calculate(wordCount: 85, goal: 100, goalType: .min) == .warning)
        #expect(GoalStatus.calculate(wordCount: 85, goal: 100, goalType: .min, thresholds: strict) == .notMet)
    }

    // MARK: - Status persistence through block replacement

    @Test("Section status survives block replacement")
    @MainActor
    func statusPersistsThroughBlockReplacement() throws {
        let url = URL(fileURLWithPath: "/tmp/claude/section-meta-\(UUID().uuidString).ff")
        let db = try TestFixtureFactory.createFixture(at: url)
        let pid = try db.dbWriter.read { database in
            try String.fetchOne(database, sql: "SELECT id FROM project LIMIT 1")!
        }

        // Fetch heading blocks and set a status on the first heading
        let blocks = try db.dbWriter.read { database in
            try Block.filter(Block.Columns.projectId == pid)
                .order(Block.Columns.sortOrder)
                .fetchAll(database)
        }
        let heading = blocks.first { $0.blockType == .heading }!

        try db.dbWriter.write { database in
            try database.execute(
                sql: "UPDATE block SET status = ? WHERE id = ?",
                arguments: [SectionStatus.review.rawValue, heading.id]
            )
        }

        // Verify status was set
        let statusBefore = try db.dbWriter.read { database in
            try Block.filter(Block.Columns.id == heading.id).fetchOne(database)!.status
        }
        #expect(statusBefore == .review)

        // Replace blocks with same content
        let newBlocks = BlockParser.parse(markdown: TestFixtureFactory.testContent, projectId: pid)
        try db.replaceBlocks(newBlocks, for: pid)

        // Status should be preserved (replaceBlocks matches headings by title)
        let blocksAfter = try db.dbWriter.read { database in
            try Block.filter(Block.Columns.projectId == pid)
                .order(Block.Columns.sortOrder)
                .fetchAll(database)
        }
        let headingAfter = blocksAfter.first { $0.textContent == heading.textContent }
        #expect(headingAfter?.status == .review, "Section status should survive block replacement")
    }
}
