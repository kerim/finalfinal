//
//  AnnotationSyncTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for annotation sync: regex matching, parsing, and database reconciliation.
//  Annotations linked to wrong text silently corrupt the document.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Annotation Sync — Tier 1: Silent Killers")
@MainActor
struct AnnotationSyncTests {

    // MARK: - Helpers

    private func getContentId(_ db: ProjectDatabase) throws -> String {
        try db.dbWriter.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT id FROM content LIMIT 1"
            )!
        }
    }

    private func createService(db: ProjectDatabase, contentId: String) -> AnnotationSyncService {
        let service = AnnotationSyncService()
        service.configure(database: db, contentId: contentId)
        return service
    }

    // MARK: - Regex Pattern Tests

    @Test("Regex matches task annotation")
    func regexMatchesTaskAnnotation() {
        let service = AnnotationSyncService()
        let text = "<!-- ::task:: [ ] Review introduction -->"
        let range = NSRange(text.startIndex..., in: text)
        let match = service.annotationPattern.firstMatch(in: text, range: range)
        #expect(match != nil, "Should match task annotation")

        if let match, let typeRange = Range(match.range(at: 1), in: text) {
            #expect(String(text[typeRange]) == "task")
        }
    }

    @Test("Regex matches comment annotation")
    func regexMatchesCommentAnnotation() {
        let service = AnnotationSyncService()
        let text = "<!-- ::comment:: some text -->"
        let range = NSRange(text.startIndex..., in: text)
        let match = service.annotationPattern.firstMatch(in: text, range: range)
        #expect(match != nil, "Should match comment annotation")

        if let match, let typeRange = Range(match.range(at: 1), in: text) {
            #expect(String(text[typeRange]) == "comment")
        }
    }

    @Test("Regex matches reference annotation")
    func regexMatchesReferenceAnnotation() {
        let service = AnnotationSyncService()
        let text = "<!-- ::reference:: See paper -->"
        let range = NSRange(text.startIndex..., in: text)
        let match = service.annotationPattern.firstMatch(in: text, range: range)
        #expect(match != nil, "Should match reference annotation")

        if let match, let typeRange = Range(match.range(at: 1), in: text) {
            #expect(String(text[typeRange]) == "reference")
        }
    }

    // MARK: - parseAnnotations

    @Test("parseAnnotations extracts all annotation types from rich content")
    func parseAnnotationsExtractsAllTypes() {
        let service = AnnotationSyncService()
        let annotations = service.parseAnnotations(from: TestFixtureFactory.richTestContent)

        let types = Set(annotations.map { $0.type })
        #expect(types.contains(.task), "Should find task annotations")
        #expect(types.contains(.comment), "Should find comment annotations")
        #expect(types.contains(.reference), "Should find reference annotations")
    }

    @Test("Task completion state is parsed correctly")
    func taskCompletionStateParsing() {
        let service = AnnotationSyncService()
        let markdown = """
        <!-- ::task:: [x] Completed task -->
        <!-- ::task:: [ ] Incomplete task -->
        """
        let annotations = service.parseAnnotations(from: markdown)
        let tasks = annotations.filter { $0.type == .task }

        #expect(tasks.count == 2)
        let completed = tasks.first { $0.isCompleted }
        let incomplete = tasks.first { !$0.isCompleted }
        #expect(completed != nil, "Should find completed task")
        #expect(incomplete != nil, "Should find incomplete task")
    }

    @Test("Highlight span detected before annotation")
    func highlightSpanDetection() {
        let service = AnnotationSyncService()
        let markdown = "==highlighted text== <!-- ::comment:: A note -->"
        let annotations = service.parseAnnotations(from: markdown)

        #expect(annotations.count == 1)
        #expect(annotations[0].highlightStart != nil, "Should detect highlight start")
        #expect(annotations[0].highlightEnd != nil, "Should detect highlight end")
    }

    // MARK: - Database Sync

    @Test("syncNowSync writes annotations to database")
    func syncNowSyncWritesToDatabase() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let contentId = try getContentId(db)
        let service = createService(db: db, contentId: contentId)

        service.syncNowSync(TestFixtureFactory.richTestContent)

        let annotations = try db.fetchAnnotations(contentId: contentId)
        let inlineAnnotations = annotations.filter { !$0.isDocumentLevel }
        #expect(!inlineAnnotations.isEmpty, "Sync should write annotations to DB")
    }

    @Test("syncNowSync reconciles CRUD on second sync")
    func syncNowSyncReconcilesCRUD() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let contentId = try getContentId(db)
        let service = createService(db: db, contentId: contentId)

        // First sync
        service.syncNowSync(TestFixtureFactory.richTestContent)
        // Modified content: remove the reference annotation, add a new comment
        let modified = TestFixtureFactory.richTestContent
            .replacingOccurrences(
                of: "<!-- ::reference:: See also Thieberger & Berez 2012 on archival best practices -->",
                with: "<!-- ::comment:: New comment replacing reference -->"
            )

        service.resetSyncTracking()
        service.syncNowSync(modified)

        let annotationsAfter = try db.fetchAnnotations(contentId: contentId)
            .filter { !$0.isDocumentLevel }

        // The reference should be gone (or replaced), and a new comment should exist
        let hasNewComment = annotationsAfter.contains { $0.text.contains("New comment replacing reference") }

        #expect(hasNewComment, "New comment should exist after reconciliation")
        // The original reference annotation at that position should be gone
        let oldRef = annotationsAfter.contains {
            $0.type == .reference && $0.text.contains("Thieberger")
        }
        #expect(!oldRef, "Old reference should be removed after reconciliation")
    }
}
