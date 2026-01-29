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

    private var projectDatabase: ProjectDatabase?
    private var contentId: String?

    /// When true, suppresses sync operations
    var isSyncSuppressed: Bool = false

    /// Content we last synced - prevents feedback loop from ValueObservation
    private var lastSyncedContent: String = ""

    // MARK: - Regex Patterns

    /// Pattern to match annotation comments: <!-- ::type:: content -->
    /// Groups: 1=type, 2=content (may include [ ] or [x] for tasks)
    private let annotationPattern = try! NSRegularExpression(
        pattern: #"<!--\s*::(\w+)::\s*(.+?)\s*-->"#,
        options: [.dotMatchesLineSeparators]
    )

    /// Pattern to match highlight spans: ==text==
    private let highlightPattern = try! NSRegularExpression(
        pattern: #"==([^=]+)==\s*$"#,
        options: []
    )

    /// Pattern to match task checkbox: [ ] or [x] at start of annotation content
    private let taskCheckboxPattern = try! NSRegularExpression(
        pattern: #"^\s*\[([ xX])\]\s*(.*)$"#,
        options: []
    )

    // MARK: - Public API

    /// Configure the service for a specific project
    func configure(database: ProjectDatabase, contentId: String) {
        self.projectDatabase = database
        self.contentId = contentId
    }

    /// Cancel any pending debounced sync operation
    func cancelPendingSync() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    /// Called when editor content changes
    /// Debounces and triggers sync after delay
    func contentChanged(_ markdown: String) {
        // Skip if suppressed
        guard !isSyncSuppressed else { return }

        // Idempotent check: skip if this is content we just synced
        guard markdown != lastSyncedContent else { return }

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: self?.debounceInterval ?? .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            await self.syncContent(markdown)
        }
    }

    /// Reset sync tracking (call when manually setting content)
    func resetSyncTracking() {
        lastSyncedContent = ""
    }

    /// Force immediate sync (e.g., before app quit)
    func syncNow(_ markdown: String) async {
        debounceTask?.cancel()
        await syncContent(markdown)
    }

    /// Load annotations from database
    func loadAnnotations() async -> [Annotation] {
        guard let db = projectDatabase, let cid = contentId else { return [] }

        do {
            return try db.fetchAnnotations(contentId: cid)
        } catch {
            print("[AnnotationSyncService] Error loading annotations: \(error.localizedDescription)")
            return []
        }
    }

    /// Parse markdown and return annotations without saving to database
    func parseAnnotations(from markdown: String) -> [ParsedAnnotation] {
        return parseAnnotationsFromMarkdown(markdown)
    }

    // MARK: - Private Methods

    /// Core sync method using position-based reconciliation
    private func syncContent(_ markdown: String) async {
        guard let db = projectDatabase, let cid = contentId else {
            print("[AnnotationSyncService] syncContent skipped - database not configured")
            return
        }

        // 1. Parse annotations from markdown
        let parsed = parseAnnotationsFromMarkdown(markdown)

        // 2. Get current DB annotations
        let dbAnnotations: [Annotation]
        do {
            dbAnnotations = try db.fetchAnnotations(contentId: cid)
        } catch {
            print("[AnnotationSyncService] Error fetching annotations: \(error.localizedDescription)")
            return
        }

        // 3. Reconcile to find minimal changes
        let changes = reconcile(parsed: parsed, dbAnnotations: dbAnnotations, contentId: cid)

        // 4. Apply changes to database (if any)
        if !changes.isEmpty {
            do {
                try db.applyAnnotationChanges(changes, for: cid)
            } catch {
                print("[AnnotationSyncService] Error applying changes: \(error.localizedDescription)")
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
        if textAfterHighlight.trimmingCharacters(in: .whitespaces).isEmpty {
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

        // Build lookup by approximate position and type (tolerance for small edits)
        var dbLookup: [String: Annotation] = [:]  // key = "type:offset_bucket"
        for annotation in dbAnnotations {
            let key = "\(annotation.type.rawValue):\(annotation.charOffset / 50)"
            dbLookup[key] = annotation
        }

        var matchedDbIds = Set<String>()

        // Process parsed annotations
        for parsed in parsed {
            let bucketKey = "\(parsed.type.rawValue):\(parsed.charOffset / 50)"

            if let existing = dbLookup[bucketKey] {
                // Found potential match - check if it needs updating
                matchedDbIds.insert(existing.id)

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

                if needsUpdate {
                    changes.append(.update(id: existing.id, updates: updates))
                }
            } else {
                // New annotation - insert
                let annotation = parsed.toAnnotation(contentId: contentId)
                changes.append(.insert(annotation))
            }
        }

        // Delete annotations that no longer exist in markdown
        for annotation in dbAnnotations where !matchedDbIds.contains(annotation.id) {
            changes.append(.delete(id: annotation.id))
        }

        return changes
    }

    // MARK: - Markdown Generation

    /// Generate markdown syntax for an annotation
    static func generateMarkdown(for annotation: Annotation) -> String {
        return annotation.markdownSyntax
    }

    /// Result of replacing annotation text in markdown
    struct AnnotationReplaceResult {
        let markdown: String
        let newCharOffset: Int
    }

    /// Replace annotation text in markdown and return updated markdown with new offset
    /// This is used when editing annotations from the sidebar
    func replaceAnnotationText(
        in markdown: String,
        annotationId: String,
        oldCharOffset: Int,
        annotationType: AnnotationType,
        oldText: String,
        newText: String,
        isCompleted: Bool
    ) -> AnnotationReplaceResult {
        let nsMarkdown = markdown as NSString
        let fullRange = NSRange(location: 0, length: nsMarkdown.length)
        let targetBucket = oldCharOffset / 50

        let matches = annotationPattern.matches(in: markdown, options: [], range: fullRange)

        for match in matches {
            // Use bucket matching for tolerance (same as reconciliation)
            let matchBucket = match.range.location / 50
            guard abs(matchBucket - targetBucket) <= 1 else { continue }

            guard match.numberOfRanges >= 3 else { continue }

            let typeRange = match.range(at: 1)
            guard typeRange.location != NSNotFound else { continue }

            let typeString = nsMarkdown.substring(with: typeRange)
            guard typeString == annotationType.rawValue else { continue }

            // Found the annotation - build new markdown syntax
            let newAnnotation: String
            switch annotationType {
            case .task:
                let checkbox = isCompleted ? "[x]" : "[ ]"
                newAnnotation = "<!-- ::\(annotationType.rawValue):: \(checkbox) \(newText) -->"
            case .comment, .reference:
                newAnnotation = "<!-- ::\(annotationType.rawValue):: \(newText) -->"
            }

            // Replace the old annotation with the new one
            let newMarkdown = nsMarkdown.replacingCharacters(in: match.range, with: newAnnotation)

            // Calculate new char offset (position in new markdown)
            // The offset is the same as before since we're replacing at the same position
            return AnnotationReplaceResult(
                markdown: newMarkdown,
                newCharOffset: match.range.location
            )
        }

        // No match found - return original
        print("[AnnotationSyncService] Warning: No annotation found near offset \(oldCharOffset) for replacement")
        return AnnotationReplaceResult(markdown: markdown, newCharOffset: oldCharOffset)
    }

    /// Update annotation completion in markdown string
    /// Returns the updated markdown
    /// Uses bucket matching (offset / 50) for tolerance to small edits
    func updateTaskCompletion(in markdown: String, at offset: Int, isCompleted: Bool) -> String {
        let nsMarkdown = markdown as NSString
        let fullRange = NSRange(location: 0, length: nsMarkdown.length)
        let targetBucket = offset / 50

        let matches = annotationPattern.matches(in: markdown, options: [], range: fullRange)

        for match in matches {
            // Use bucket matching for tolerance (same as reconciliation)
            let matchBucket = match.range.location / 50
            guard abs(matchBucket - targetBucket) <= 1 else { continue }

            guard match.numberOfRanges >= 3 else { continue }

            let typeRange = match.range(at: 1)
            guard typeRange.location != NSNotFound else { continue }

            let typeString = nsMarkdown.substring(with: typeRange)
            guard typeString == "task" else { continue }

            // Found the task - update only the checkbox using regex
            // This prevents accidentally replacing [ ] or [x] in the task text
            let annotationText = nsMarkdown.substring(with: match.range)
            let newCheckbox = isCompleted ? "[x]" : "[ ]"

            // Pattern matches the checkbox right after ::task::
            let checkboxPattern = try! NSRegularExpression(
                pattern: #"(::task::\s*)\[([ xX])\]"#,
                options: []
            )
            let annotationNS = annotationText as NSString
            let annotationRange = NSRange(location: 0, length: annotationNS.length)

            let updatedText = checkboxPattern.stringByReplacingMatches(
                in: annotationText,
                options: [],
                range: annotationRange,
                withTemplate: "$1\(newCheckbox)"
            )

            return nsMarkdown.replacingCharacters(in: match.range, with: updatedText)
        }

        print("[AnnotationSyncService] Warning: No task annotation found near offset \(offset)")
        return markdown
    }
}
