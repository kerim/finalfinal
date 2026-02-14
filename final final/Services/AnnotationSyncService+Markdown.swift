//
//  AnnotationSyncService+Markdown.swift
//  final final
//

import Foundation

// MARK: - Markdown Generation

extension AnnotationSyncService {

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
        // Normalize and sanitize the new text
        let normalizedText = normalizeAnnotationText(newText)

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
                newAnnotation = "<!-- ::\(annotationType.rawValue):: \(checkbox) \(normalizedText) -->"
            case .comment, .reference:
                newAnnotation = "<!-- ::\(annotationType.rawValue):: \(normalizedText) -->"
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

    /// Normalize annotation text for safe storage in HTML comment syntax
    /// - Converts newlines to spaces (multi-line to single line)
    /// - Escapes --> sequences that would break HTML comment
    /// - Normalizes multiple spaces to single space
    func normalizeAnnotationText(_ text: String) -> String {
        var normalized = text

        // Convert all line endings to spaces (Windows \r\n, Unix \n, old Mac \r)
        normalized = normalized
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")

        // Escape --> sequences that would prematurely close the HTML comment
        // Use a Unicode lookalike dash (en-dash) to preserve visual appearance
        normalized = normalized.replacingOccurrences(of: "-->", with: "–->")

        // Normalize multiple consecutive spaces to single space
        while normalized.contains("  ") {
            normalized = normalized.replacingOccurrences(of: "  ", with: " ")
        }

        return normalized.trimmingCharacters(in: .whitespaces)
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
            let checkboxPattern: NSRegularExpression
            do {
                checkboxPattern = try NSRegularExpression(
                    pattern: #"(::task::\s*)\[([ xX])\]"#,
                    options: []
                )
            } catch {
                fatalError("Invalid regex pattern: \(error)")
            }
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
