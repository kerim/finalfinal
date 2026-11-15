//
//  DuplicateSectionSortOrderRoomPrimitivesTests.swift
//  final finalTests
//
//  Tier 1 (t-bf66e4ee): the old whole-document Duplicate Section path (`ProjectDatabase.duplicateSections(rootId:projectId:)`, still the
//  fallback) and "Replace Current Section" (`replaceFlatSectionRange`) re-space the saved positions inside their own write when the room
//  is used up, and log it. The editor-first entries are DuplicateSectionSortOrderRoomTests (Tier 2).
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@MainActor
@Suite("Duplicate and section-restore primitives keep room between saved positions — Tier 1 (t-bf66e4ee)")
struct DuplicateSectionSortOrderRoomPrimitivesTests { // swiftlint:disable:this type_name

    private static func heading(_ id: String, _ text: String, at sort: Double) -> Block {
        Block(id: id, projectId: "p", sortOrder: sort, blockType: .heading, textContent: text, markdownFragment: "# " + text,
              headingLevel: 1)
    }

    private static func paragraph(_ id: String, _ text: String, at sort: Double) -> Block {
        Block(id: id, projectId: "p", sortOrder: sort, blockType: .paragraph, textContent: text, markdownFragment: text)
    }

    private func makeDatabase(_ blocks: [Block]) throws -> (db: ProjectDatabase, pid: String) {
        let db = try TestFixtureFactory.createTemporary(content: "# Seed")
        let pid = try TestFixtureFactory.getProjectId(from: db)
        try db.dbWriter.write { database in
            try Block.filter(Block.Columns.projectId == pid).deleteAll(database)
            for var block in blocks {
                block.projectId = pid
                try block.insert(database)
            }
        }
        return (db, pid)
    }

    private func tightPairs(_ blocks: [Block]) -> [(Double, Double)] {
        let positions = BlockParser.assemblySorted(blocks).map(\.sortOrder)
        return zip(positions, positions.dropFirst()).filter { $1 - $0 < ProjectDatabase.crowdedSortOrderGap }
    }

    @Test("T4: ten duplicates through the old whole-document path keep order and room, and log the re-spacing")
    func tenOldPathDuplicatesKeepOrder() throws {
        let paragraphs = (1...100).map { String(format: "Paragraph %03d.", $0) }
        let markdown = (["# Chapter One"] + paragraphs + ["# Chapter Two", "Two body."]).joined(separator: "\n\n")
        let db = try TestFixtureFactory.createTemporary(content: markdown)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        func title(_ generation: Int) -> String { "Chapter One" + String(repeating: " copy", count: generation) }

        for generation in 1...10 {
            let root = try #require(try db.fetchBlocks(projectId: pid).first {
                $0.blockType == .heading && $0.textContent == title(generation - 1)
            })
            #expect(try db.duplicateSections(rootId: root.id, projectId: pid) != nil, "duplicate \(generation) was refused")
        }

        let rows = BlockParser.assemblySorted(try db.fetchBlocks(projectId: pid))
        var want = ["Chapter One"] + paragraphs
        for generation in 1...10 { want += [title(generation)] + paragraphs }
        want += ["Chapter Two", "Two body."]
        #expect(rows.map(\.textContent).filter { !$0.isEmpty } == want, "the copies do not read back in order")
        let tight = tightPairs(rows)
        #expect(tight.isEmpty, "saved positions do not strictly increase with room between them: \(tight.count) tight pair(s)")
        #expect(db.sortOrderRenumberLog.generation > 0, "no duplicate re-spaced the saved positions (or the re-spacing was not logged)")
    }

    @Test("T5: Replace Current Section into a section squeezed to almost no room re-spaces first: rows in order, room, logged")
    func replaceIntoACrowdedRangeRespacesFirst() throws {
        let start = 2.0
        let squeezedBody = start.nextUp
        let next = squeezedBody.nextUp
        let (db, pid) = try makeDatabase([
            Self.heading("h-one", "Chapter One", at: 1.0), Self.paragraph("p-one", "One body.", at: 1.5),
            Self.heading("h-x", "Squeezed", at: start), Self.paragraph("p-x", "Squeezed body.", at: squeezedBody),
            Self.heading("h-two", "Chapter Two", at: next), Self.paragraph("p-two", "Two body.", at: 3.0)
        ])
        let newIds = (1...10).map { "r-\($0)" }
        let rows = [Self.heading("h-x", "Restored", at: 0)] + newIds.map { Self.paragraph($0, "Restored \($0).", at: 0) }
        let log = SortOrderRenumberLog()

        let replaced = try db.dbWriter.write { database in
            try ProjectDatabase.replaceFlatSectionRange(db: database, projectId: pid, headingId: "h-x", rows: rows, renumberLog: log)
        }
        #expect(replaced, "the squeezed heading was not a replaceable section")

        let after = BlockParser.assemblySorted(try db.fetchBlocks(projectId: pid))
        #expect(after.map(\.id) == ["h-one", "p-one", "h-x"] + newIds + ["h-two", "p-two"], "rows out of order: \(after.map(\.id))")
        let tight = tightPairs(after)
        #expect(tight.isEmpty, "saved positions do not strictly increase with room between them: \(tight.count) tight pair(s)")
        #expect(log.generation == 1, "the re-spacing was not logged on commit: generation \(log.generation)")
    }
}
