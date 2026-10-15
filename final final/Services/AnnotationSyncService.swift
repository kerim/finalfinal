//
//  AnnotationSyncService.swift
//  final final
//

import Foundation

/// Service to sync editor content with annotations database
/// Parses markdown for annotation comments and reconciles with database
/// Uses position-based reconciliation with surgical database updates
@MainActor
@Observable
class AnnotationSyncService {
    private var debounceTask: Task<Void, Never>?
    private let debounceInterval: Duration = .milliseconds(500)
    private var debounceGeneration: Int = 0

    private var projectDatabase: ProjectDatabase?
    private var contentId: String?

    /// Reference to editor state for checking content transitions
    weak var editorState: EditorViewState?

    /// Content we last synced - prevents feedback loop from ValueObservation
    private var lastSyncedContent: String = ""

    /// The newest sync in line (see `syncContent(_:)`). Every sync (debounced or forced) waits for this one to finish,
    /// write included, before it starts, so two syncs never overlap even though the database write suspends the main
    /// actor instead of blocking it. Never cancelled: a sync that has been queued or started runs to the end.
    private var syncChain: Task<Void, Never>?

    // MARK: - Regex Patterns

    /// Pattern to match annotation comments: <!-- ::type:: content -->
    /// Groups: 1=type, 2=content (may include [ ] or [x] for tasks)
    /// Note: (.*?) allows empty content for newly created annotations
    let annotationPattern: NSRegularExpression = {
        do {
            return try NSRegularExpression(
                pattern: #"<!--\s*::(\w+)::\s*(.*?)\s*-->"#,
                options: [.dotMatchesLineSeparators]
            )
        } catch {
            fatalError("Invalid regex pattern: \(error)")
        }
    }()

    /// Pattern to match highlight spans: ==text==
    private let highlightPattern: NSRegularExpression = {
        do {
            return try NSRegularExpression(
                pattern: #"==([^=]+)==\s*$"#,
                options: []
            )
        } catch {
            fatalError("Invalid regex pattern: \(error)")
        }
    }()

    /// Pattern to match task checkbox: [ ] or [x] at start of annotation content
    private let taskCheckboxPattern: NSRegularExpression = {
        do {
            return try NSRegularExpression(
                pattern: #"^\s*\[([ xX])\]\s*(.*)$"#,
                options: []
            )
        } catch {
            fatalError("Invalid regex pattern: \(error)")
        }
    }()

    // MARK: - Public API

    /// Configure the service for a specific project
    func configure(database: ProjectDatabase, contentId: String) {
        self.projectDatabase = database
        self.contentId = contentId
    }

    /// Cancel any pending debounced sync operation (the debounce timer only). A sync that has already started, or is
    /// queued behind one that has, is not cancelled: a database write that has begun must finish.
    func cancelPendingSync() {
        debounceTask?.cancel()
        debounceTask = nil
        debounceGeneration += 1
    }

    /// Called when editor content changes
    /// Debounces and triggers sync after delay
    func contentChanged(_ markdown: String) {
        // Skip if content transition is in progress
        guard !(editorState?.isBusy ?? false) else { return }

        // Idempotent check: skip if this is content we just synced
        guard markdown != lastSyncedContent else { return }

        debounceTask?.cancel()
        debounceGeneration += 1
        let myGeneration = debounceGeneration
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: self?.debounceInterval ?? .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            // Double-check: if another contentChanged fired during sleep, skip
            guard self.debounceGeneration == myGeneration else { return }
            await self.syncContent(markdown)
        }
    }

    /// Reset sync tracking (call when manually setting content)
    func resetSyncTracking() {
        lastSyncedContent = ""
    }

    /// Force immediate sync (e.g., before app quit). Returns only after every sync already started or queued has
    /// finished and this one has too (they run in order, see `syncContent(_:)`).
    func syncNow(_ markdown: String) async {
        let traceSpan = StructuralTrace.span("annotationSync.syncNow") // slice 0 measurement; silent unless tracing is on
        defer { traceSpan.end() }
        debounceTask?.cancel()
        await syncContent(markdown)
    }

    /// Synchronous annotation sync for app termination / project close.
    func syncNowSync(_ markdown: String) {
        cancelPendingSync()
        guard let db = projectDatabase, let cid = contentId else { return }
        do {
            let parsed = parseAnnotationsFromMarkdown(markdown)

            let allAnnotations = try db.fetchAnnotations(contentId: cid)
            let dbAnnotations = allAnnotations.filter { !$0.isDocumentLevel }

            let changes = reconcile(
                parsed: parsed,
                dbAnnotations: dbAnnotations,
                contentId: cid
            )

            if !changes.isEmpty {
                try db.applyAnnotationChanges(changes, for: cid)
            }
        } catch {
            DebugLog.log(.sync, "[AnnotationSyncService] syncNowSync error: \(error)")
        }

        lastSyncedContent = markdown
    }

    /// Load annotations from database
    func loadAnnotations() async -> [Annotation] {
        guard let db = projectDatabase, let cid = contentId else { return [] }

        do {
            return try db.fetchAnnotations(contentId: cid)
        } catch {
            DebugLog.log(.editor, "[AnnotationSyncService] Error loading annotations: \(error.localizedDescription)")
            return []
        }
    }

    /// Parse markdown and return annotations without saving to database
    func parseAnnotations(from markdown: String) -> [ParsedAnnotation] {
        return parseAnnotationsFromMarkdown(markdown)
    }

    // MARK: - Private Methods

    /// Core sync method: queues one sync behind the one before it, and returns when this one has finished.
    ///
    /// The database write inside a sync runs off the main thread and is awaited (see `performSync`), so the main actor
    /// is free while a long write elsewhere (a section delete's version snapshot, a restore) holds the database's one
    /// writer. That makes a suspension point inside a sync, so two syncs could interleave: a second one would read the
    /// annotation rows before the first one's write landed and insert or delete the wrong rows. Each sync therefore
    /// waits for the previous one (including its write) first, in call order; none is dropped and none runs twice.
    ///
    /// `db` and `cid` are captured when the sync is queued, so a sync queued for one project never writes to the
    /// database a later `configure(database:contentId:)` sets.
    private func syncContent(_ markdown: String) async {
        guard let db = projectDatabase, let cid = contentId else {
            DebugLog.log(.editor, "[AnnotationSyncService] syncContent skipped - database not configured")
            return
        }

        let previous = syncChain
        // Unstructured on purpose: the caller (the debounce task) may be cancelled while this runs, and a started
        // write must not be. Strong `self`: the chain is finite, and a queued sync must run even if the owner lets go.
        let sync = Task { [self] in
            await previous?.value
            await performSync(markdown, database: db, contentId: cid)
        }
        syncChain = sync
        await sync.value
    }

    /// One sync, run only when the previous one has finished (`syncContent(_:)`): position-based reconciliation.
    private func performSync(_ markdown: String, database db: ProjectDatabase, contentId cid: String) async {
        // 1. Parse annotations from markdown
        let parsed = parseAnnotationsFromMarkdown(markdown)

        // 2. Get current DB annotations (exclude document-level — they have no markdown counterpart)
        let dbAnnotations: [Annotation]
        do {
            let allAnnotations = try db.fetchAnnotations(contentId: cid)
            dbAnnotations = allAnnotations.filter { !$0.isDocumentLevel }
        } catch {
            DebugLog.log(.editor, "[AnnotationSyncService] Error fetching annotations: \(error.localizedDescription)")
            return
        }

        // 3. Reconcile to find minimal changes
        let changes = reconcile(parsed: parsed, dbAnnotations: dbAnnotations, contentId: cid)

        // 4. Apply changes to database (if any). Off the main thread and awaited: the database has one writer, and a long
        // write elsewhere (a section delete's version snapshot and row deletes on a book) holds it for seconds. A
        // synchronous write here parked the main thread behind it, so the window froze (the removal was not painted and
        // typing was not echoed). Detached so the write also finishes if the awaiting task is cancelled. The reads above
        // stay on the main actor: a read does not wait for the writer.
        if !changes.isEmpty {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try db.applyAnnotationChanges(changes, for: cid)
                }.value
            } catch {
                DebugLog.log(.editor, "[AnnotationSyncService] Error applying changes: \(error.localizedDescription)")
            }
        }

        // Track synced content to prevent feedback loops
        lastSyncedContent = markdown
    }

    /// Parse markdown content to extract annotations
    private func parseAnnotationsFromMarkdown(_ markdown: String) -> [ParsedAnnotation] {
        var annotations: [ParsedAnnotation] = []
        let nsMarkdown = markdown as NSString
        let fullRange = NSRange(location: 0, length: nsMarkdown.length)

        // Find all annotation comments
        let matches = annotationPattern.matches(in: markdown, options: [], range: fullRange)

        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }

            let typeRange = match.range(at: 1)
            let contentRange = match.range(at: 2)

            guard typeRange.location != NSNotFound,
                  contentRange.location != NSNotFound else { continue }

            let typeString = nsMarkdown.substring(with: typeRange)
            let contentString = nsMarkdown.substring(with: contentRange)

            // Parse type
            guard let type = AnnotationType(rawValue: typeString) else { continue }

            // Parse completion status for tasks
            var text = contentString
            var isCompleted = false

            if type == .task {
                let checkboxMatches = taskCheckboxPattern.matches(
                    in: contentString,
                    options: [],
                    range: NSRange(location: 0, length: (contentString as NSString).length)
                )

                if let checkboxMatch = checkboxMatches.first, checkboxMatch.numberOfRanges >= 3 {
                    let checkboxRange = checkboxMatch.range(at: 1)
                    let textRange = checkboxMatch.range(at: 2)

                    if checkboxRange.location != NSNotFound {
                        let checkbox = (contentString as NSString).substring(with: checkboxRange)
                        isCompleted = (checkbox.lowercased() == "x")
                    }

                    if textRange.location != NSNotFound {
                        text = (contentString as NSString).substring(with: textRange)
                    }
                }
            }

            let charOffset = match.range.location

            // Look backward for highlight span
            let (highlightStart, highlightEnd) = findPrecedingHighlight(
                in: markdown,
                before: charOffset
            )

            annotations.append(ParsedAnnotation(
                type: type,
                text: text.trimmingCharacters(in: .whitespaces),
                isCompleted: isCompleted,
                charOffset: charOffset,
                highlightStart: highlightStart,
                highlightEnd: highlightEnd
            ))
        }

        return annotations
    }

    /// Look backward from annotation position to find a preceding ==highlight== span
    private func findPrecedingHighlight(in markdown: String, before position: Int) -> (Int?, Int?) {
        // Look at the text immediately before the annotation
        // We're looking for ==text== right before the annotation comment
        let lookbackLength = min(position, 500)  // Don't look back too far
        let startPos = position - lookbackLength
        let lookbackRange = NSRange(location: startPos, length: lookbackLength)

        let nsMarkdown = markdown as NSString
        let lookbackText = nsMarkdown.substring(with: lookbackRange)

        // Find the last highlight in the lookback region
        let matches = highlightPattern.matches(
            in: lookbackText,
            options: [],
            range: NSRange(location: 0, length: (lookbackText as NSString).length)
        )

        guard let lastMatch = matches.last else { return (nil, nil) }

        // The highlight must be immediately before the annotation (allowing only whitespace)
        let textAfterHighlight = (lookbackText as NSString).substring(
            from: lastMatch.range.location + lastMatch.range.length
        )

        // Only allow whitespace between highlight and annotation
        if textAfterHighlight.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Calculate absolute positions
            let highlightStart = startPos + lastMatch.range.location
            let highlightEnd = startPos + lastMatch.range.location + lastMatch.range.length
            return (highlightStart, highlightEnd)
        }

        return (nil, nil)
    }

    /// Reconcile parsed annotations with database annotations to find minimal changes
    private func reconcile(
        parsed: [ParsedAnnotation],
        dbAnnotations: [Annotation],
        contentId: String
    ) -> [AnnotationChange] {
        var changes: [AnnotationChange] = []

        // Build lookup by approximate position and type (tolerance for small edits).
        // Uses a plural bucket so two DB rows sharing (type, bucket) both survive
        // instead of the second overwriting the first in a singular [String: Annotation].
        // GRDB returns rows ORDER BY charOffset (see Database+Annotations.swift:55),
        // so each bucket's array is already sorted by offset — deterministic fallback order.
        var dbLookup: [String: [Annotation]] = [:]  // key = "type:offset_bucket"
        for annotation in dbAnnotations {
            let key = "\(annotation.type.rawValue):\(annotation.charOffset / 50)"
            dbLookup[key, default: []].append(annotation)
        }

        var matchedDbIds = Set<String>()

        // Process parsed annotations
        for parsed in parsed {
            let bucketKey = "\(parsed.type.rawValue):\(parsed.charOffset / 50)"

            guard var candidates = dbLookup[bucketKey], !candidates.isEmpty else {
                // No DB candidates in this bucket — new annotation, insert it
                let annotation = parsed.toAnnotation(contentId: contentId)
                changes.append(.insert(annotation))
                continue
            }

            let existing = bestCandidate(among: candidates, for: parsed)

            // Consume the chosen candidate so the next parsed annotation cannot also match it
            candidates.removeAll { $0.id == existing.id }
            if candidates.isEmpty {
                dbLookup.removeValue(forKey: bucketKey)
            } else {
                dbLookup[bucketKey] = candidates
            }

            // Found potential match - check if it needs updating
            matchedDbIds.insert(existing.id)

            if let updates = changedFields(from: existing, to: parsed) {
                changes.append(.update(id: existing.id, updates: updates))
            }
        }

        // Delete annotations that no longer exist in markdown
        for annotation in dbAnnotations where !matchedDbIds.contains(annotation.id) {
            changes.append(.delete(id: annotation.id))
        }

        return changes
    }

    /// Pick the best DB candidate for `parsed` using tie-breakers (in order):
    /// 1. Exact charOffset match (steady state — nothing moved).
    /// 2. Exact text match (prevents UUID swaps when offsets shift asymmetrically
    ///    within a bucket but the text uniquely identifies each annotation).
    /// 3. Smallest absolute offset distance (closest in position).
    /// 4. First in array order (deterministic fallback; ORDER BY charOffset from GRDB).
    private func bestCandidate(among candidates: [Annotation], for parsed: ParsedAnnotation) -> Annotation {
        if let exactOffset = candidates.first(where: { $0.charOffset == parsed.charOffset }) {
            return exactOffset
        } else if let exactText = candidates.first(where: { $0.text == parsed.text }) {
            return exactText
        }
        return candidates.min(by: {
            abs($0.charOffset - parsed.charOffset) < abs($1.charOffset - parsed.charOffset)
        }) ?? candidates[0]
    }

    /// The fields of `existing` that differ from `parsed`, or nil if none do (nothing to update).
    private func changedFields(from existing: Annotation, to parsed: ParsedAnnotation) -> AnnotationUpdates? {
        var needsUpdate = false
        var updates = AnnotationUpdates()

        if existing.text != parsed.text {
            updates.text = parsed.text
            needsUpdate = true
        }
        if existing.isCompleted != parsed.isCompleted {
            updates.isCompleted = parsed.isCompleted
            needsUpdate = true
        }
        if existing.charOffset != parsed.charOffset {
            updates.charOffset = parsed.charOffset
            needsUpdate = true
        }
        if existing.highlightStart != parsed.highlightStart {
            updates.highlightStart = parsed.highlightStart
            needsUpdate = true
        }
        if existing.highlightEnd != parsed.highlightEnd {
            updates.highlightEnd = parsed.highlightEnd
            needsUpdate = true
        }

        return needsUpdate ? updates : nil
    }

}
