//
//  TestFixtureFactory.swift
//  final finalTests
//
//  Creates .ff test fixtures using ProjectDatabase APIs.
//  Ensures fixtures match the current database schema (all migrations applied).
//

import Foundation
import GRDB
@testable import final_final

enum TestFixtureFactory {
    /// The canonical test content used across all test fixtures
    static let testContent = """
    # Test Document

    This is a test paragraph for automated testing.

    ## Second Section

    More content here.
    """

    // MARK: - Rich Test Content

    /// Rich test content with 3 heading levels, 5+ sections, annotations,
    /// citations, footnotes, highlights, pseudo-section break, images, and captions.
    /// Designed for meaningful reorder, zoom, reconciler, and roundtrip tests.
    static let richTestContent = """
    # Research Paper Draft

    This is the introduction to a research paper about language documentation and \
    digital archiving. The field has evolved significantly over the past two decades, \
    moving from analog tape recordings to born-digital multimedia corpora. Researchers \
    now face new challenges around data preservation, metadata standards, and community \
    access to archived materials. This section provides an overview of the key themes \
    explored throughout the paper.

    <!-- ::task:: [ ] Review introduction for clarity and flow -->

    ## Background and Literature Review

    The study of endangered languages has a long history stretching back to the \
    nineteenth century, when colonial-era linguists first began documenting languages \
    in the Americas, Africa, and the Pacific. Modern language documentation as a \
    distinct subfield emerged in the 1990s with the work of Himmelmann and others \
    who argued for a shift from descriptive grammar to comprehensive corpus creation \
    [@himmelmann1998]. The documentation paradigm emphasizes primary data collection \
    — audio, video, and text — alongside analysis and description.

    ==Recent scholarship has questioned the ethical frameworks== <!-- ::comment:: Needs expanded discussion of CARE principles vs. FAIR principles -->

    Several key frameworks have shaped the field. The FAIR principles (Findable, \
    Accessible, Interoperable, Reusable) were adapted from open science for language \
    archives [@wilkinson2016]. More recently, Indigenous data sovereignty movements \
    have proposed the CARE principles (Collective benefit, Authority to control, \
    Responsibility, Ethics) as a complement to FAIR [@carroll2020, p. 42].

    ### Archival Standards

    Digital archiving requires adherence to metadata standards such as OLAC (Open \
    Language Archives Community) and IMDI (ISLE Metadata Initiative). These standards \
    ensure that archived materials can be discovered and reused by future researchers. \
    The choice of archive — ELAR, PARADISEC, AILLA, or institutional repositories — \
    affects long-term preservation guarantees and access policies. Archive selection \
    should be guided by community preferences and the specific needs of each project[^1].

    <!-- ::reference:: See also Thieberger & Berez 2012 on archival best practices -->

    ### Previous Computational Approaches

    Computational methods have been applied to language documentation since the early \
    2000s. Automatic speech recognition (ASR) for low-resource languages remains an \
    active research area, with recent neural approaches showing promise even for \
    languages with limited training data. Natural language processing tools adapted \
    for endangered languages include morphological analyzers, part-of-speech taggers, \
    and interlinear glossing assistants[^2].

    ---

    ## Methodology

    <!-- ::task:: [x] Finalize participant consent procedures -->

    This study employs a mixed-methods approach combining quantitative corpus analysis \
    with qualitative interviews of language community members and documentation \
    practitioners. The corpus component analyzes metadata completeness across three \
    major language archives, sampling 500 deposits each from ELAR, PARADISEC, and \
    AILLA. The qualitative component draws on semi-structured interviews with 24 \
    practitioners conducted between January and June 2024.

    ![Methodology workflow diagram](media/methodology-workflow.png)

    <!-- ::comment:: Caption: Figure 1. Overview of the mixed-methods research design showing corpus sampling and interview phases. -->

    The interview protocol covered four main themes: (1) documentation planning and \
    workflow, (2) archival deposit practices, (3) community engagement strategies, and \
    (4) perceptions of data reuse and ethical obligations. Interviews were conducted \
    remotely via video call, recorded with participant consent, and transcribed using \
    a combination of automatic speech recognition and manual correction.

    ## Results and Discussion

    Preliminary results indicate significant variation in metadata completeness across \
    archives. PARADISEC deposits showed the highest average metadata completeness \
    (87%), followed by ELAR (72%) and AILLA (65%). However, these figures mask \
    substantial within-archive variation: the standard deviation for all three archives \
    exceeded 15 percentage points. Interview data suggest that metadata completeness \
    correlates strongly with institutional support — practitioners at well-funded \
    universities produced more complete deposits regardless of archive choice.

    ==The correlation between funding and metadata quality== <!-- ::comment:: This finding supports the argument for infrastructure investment -->

    Several practitioners noted tension between the FAIR and CARE principles in \
    practice. One interviewee observed: "Making everything findable and accessible \
    sounds great in theory, but some of our community elders specifically asked that \
    certain ceremony recordings not be publicly available. We need archives that can \
    handle nuanced access controls" [@smith2023]. This tension is particularly acute \
    for ceremonial or sacred content, where open access may conflict with cultural \
    protocols governing knowledge transmission.

    ## Conclusion

    This paper has examined the evolving landscape of language documentation and \
    digital archiving through both quantitative and qualitative lenses. The findings \
    highlight three key areas requiring attention: (1) improved tooling for metadata \
    creation during fieldwork, (2) archive infrastructure that supports graduated \
    access controls aligned with community preferences, and (3) sustained funding \
    models that recognize documentation as ongoing community partnership rather than \
    one-time data extraction. Future work will expand the corpus analysis to include \
    additional archives and develop a metadata completeness scoring tool for \
    practitioners to self-assess their deposits before archival submission.

    <!-- ::task:: [ ] Add limitations subsection before conclusion -->

    # Notes

    [^1]: OLAC metadata standards are maintained at http://www.language-archives.org \
    and provide a Dublin Core-based profile specifically designed for language resources.

    [^2]: See Bird 2009 for an early survey; Vu et al. 2023 for the most recent \
    neural approaches to ASR in documentation contexts.

    # References

    Carroll, S. R., et al. (2020). The CARE Principles for Indigenous Data Governance. *Data Science Journal*, 19(1), 43.

    Himmelmann, N. P. (1998). Documentary and descriptive linguistics. *Linguistics*, 36(1), 161-195.

    Smith, J. (2023). Balancing openness and cultural protocols in language archives. *Journal of Language Documentation*, 15(2), 112-134.

    Wilkinson, M. D., et al. (2016). The FAIR Guiding Principles for scientific data management. *Scientific Data*, 3, 160018.
    """

    // MARK: - Fixture Creation

    /// Creates a fresh .ff fixture at the given URL
    /// - Parameters:
    ///   - url: Directory URL where the .ff package will be created
    ///   - title: Project title (defaults to "Test Project")
    ///   - content: Markdown content (defaults to testContent)
    /// - Returns: The created ProjectDatabase
    @discardableResult
    static func createFixture(
        at url: URL,
        title: String = "Test Project",
        content: String? = nil
    ) throws -> ProjectDatabase {
        let markdown = content ?? testContent
        let package = try ProjectPackage.create(at: url, title: title)
        let db = try ProjectDatabase.create(
            package: package,
            title: title,
            initialContent: markdown
        )

        // Parse markdown into blocks so tests can query block data immediately
        let projectId = try db.dbWriter.read { database in
            try String.fetchOne(database, sql: "SELECT id FROM project LIMIT 1")!
        }
        let blocks = BlockParser.parse(markdown: markdown, projectId: projectId)
        try db.replaceBlocks(blocks, for: projectId)

        return db
    }

    /// Creates a rich .ff fixture with annotations, citations, footnotes, and images
    @discardableResult
    static func createRichFixture(
        at url: URL,
        title: String = "Rich Test Project"
    ) throws -> ProjectDatabase {
        return try createFixture(at: url, title: title, content: richTestContent)
    }

    // MARK: - Shared Test Helpers

    /// Create a temporary test database at a unique path under /tmp/claude/.
    @discardableResult
    static func createTemporary(content: String? = nil) throws -> ProjectDatabase {
        let url = URL(fileURLWithPath: "/tmp/claude/test-\(UUID().uuidString).ff")
        return try createFixture(at: url, content: content)
    }

    /// Fetch all blocks for the single project in a test database, ordered by sortOrder.
    static func fetchBlocks(from db: ProjectDatabase) throws -> [Block] {
        try db.dbWriter.read { database in
            try Block
                .filter(Block.Columns.projectId != "")
                .order(Block.Columns.sortOrder)
                .fetchAll(database)
        }
    }

    /// Get the project ID from a test database (assumes single project).
    static func getProjectId(from db: ProjectDatabase) throws -> String {
        try db.dbWriter.read { database in
            try String.fetchOne(database, sql: "SELECT id FROM project LIMIT 1")!
        }
    }

    /// Filter blocks to just headings.
    static func headingBlocks(_ blocks: [Block]) -> [Block] {
        blocks.filter { $0.blockType == .heading }
    }
}
