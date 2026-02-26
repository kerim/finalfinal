//
//  MarkdownRenderer.swift
//  QuickLook Extension
//
//  Pre-processes markdown (strips annotations/footnotes), parses with
//  AttributedString(markdown:), then walks PresentationIntent attributes
//  to apply visual styling for Quick Look preview.
//

import AppKit
import Foundation

enum MarkdownRenderer {
    // MARK: - Public

    static func render(title: String, markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()

        // Title
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 26, weight: .bold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: {
                let style = NSMutableParagraphStyle()
                style.paragraphSpacingBefore = 0
                style.paragraphSpacing = 16
                return style
            }()
        ]
        result.append(NSAttributedString(string: title + "\n", attributes: titleAttrs))

        // Separator
        let separatorAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8),
            .foregroundColor: NSColor.separatorColor,
            .paragraphStyle: {
                let style = NSMutableParagraphStyle()
                style.paragraphSpacing = 12
                return style
            }()
        ]
        result.append(NSAttributedString(string: "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\n", attributes: separatorAttrs))

        let cleaned = preprocess(markdown)

        if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let emptyAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 14), toHaveTrait: .italicFontMask),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            result.append(NSAttributedString(string: "Empty document", attributes: emptyAttrs))
            return result
        }

        let styledBody = parseAndStyle(cleaned)
        result.append(styledBody)

        return result
    }

    static func renderError() -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        return NSAttributedString(string: "Unable to preview this document", attributes: attrs)
    }

    // MARK: - Pre-processing

    private static func preprocess(_ markdown: String) -> String {
        var result = markdown

        // Strip annotations: <!-- ::type:: content -->
        if let regex = try? NSRegularExpression(pattern: "<!--\\s*::\\w+::\\s*[\\s\\S]*?-->") {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        // Strip footnote references: [^1], [^2] etc. (but not definitions)
        if let regex = try? NSRegularExpression(pattern: "\\[\\^\\d+\\](?!:)") {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        // Strip footnote definitions: entire [^1]: ... lines
        if let regex = try? NSRegularExpression(pattern: "^\\[\\^\\d+\\]:.*$", options: .anchorsMatchLines) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        return result
    }

    // MARK: - Parsing & Styling

    private static func parseAndStyle(_ markdown: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full
        )

        guard var attributed = try? AttributedString(markdown: markdown, options: options) else {
            // Fallback: render as plain text
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.labelColor
            ]
            return NSAttributedString(string: markdown, attributes: attrs)
        }

        // Insert newlines between block-level elements.
        // AttributedString(markdown:) strips original whitespace and uses
        // PresentationIntent as metadata only — without explicit newlines,
        // NSTextView renders everything on one line.
        // Iterate in reversed order so earlier indices stay valid.
        for (intent, range) in attributed.runs[\.presentationIntent].reversed() {
            guard intent != nil, range.lowerBound != attributed.startIndex else { continue }
            attributed.characters.insert(contentsOf: "\n", at: range.lowerBound)
        }

        // Apply base style
        attributed.font = .systemFont(ofSize: 14)
        attributed.foregroundColor = .labelColor

        // Walk presentation intents for block-level styling
        var offset = attributed.startIndex
        while offset < attributed.endIndex {
            let run = attributed.runs[offset]
            let range = run.range

            if let intent = run.presentationIntent {
                for component in intent.components {
                    switch component.kind {
                    case .header(let level):
                        let sizes: [Int: CGFloat] = [1: 24, 2: 20, 3: 17, 4: 15, 5: 14, 6: 13]
                        let size = sizes[level] ?? 14
                        let weight: NSFont.Weight = level <= 2 ? .bold : .semibold
                        attributed[range].font = .systemFont(ofSize: size, weight: weight)
                        let paraStyle = NSMutableParagraphStyle()
                        paraStyle.paragraphSpacingBefore = level == 1 ? 20 : 14
                        paraStyle.paragraphSpacing = 6
                        attributed[range].paragraphStyle = paraStyle

                    case .codeBlock:
                        attributed[range].font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
                        attributed[range].foregroundColor = .secondaryLabelColor
                        attributed[range].backgroundColor = .quaternaryLabelColor
                        let paraStyle = NSMutableParagraphStyle()
                        paraStyle.headIndent = 12
                        paraStyle.firstLineHeadIndent = 12
                        paraStyle.paragraphSpacing = 4
                        attributed[range].paragraphStyle = paraStyle

                    case .blockQuote:
                        attributed[range].foregroundColor = .secondaryLabelColor
                        let paraStyle = NSMutableParagraphStyle()
                        paraStyle.headIndent = 24
                        paraStyle.firstLineHeadIndent = 24
                        paraStyle.paragraphSpacing = 4
                        attributed[range].paragraphStyle = paraStyle

                    case .orderedList, .unorderedList:
                        let paraStyle = NSMutableParagraphStyle()
                        paraStyle.headIndent = 24
                        paraStyle.firstLineHeadIndent = 12
                        paraStyle.paragraphSpacing = 2
                        attributed[range].paragraphStyle = paraStyle

                    default:
                        break
                    }
                }
            }

            // Inline styles
            if run.inlinePresentationIntent?.contains(.code) == true {
                attributed[range].font = .monospacedSystemFont(ofSize: 13, weight: .regular)
                attributed[range].backgroundColor = .quaternaryLabelColor
            }

            if let link = run.link {
                attributed[range].foregroundColor = .linkColor
                attributed[range].link = link
            }

            offset = run.range.upperBound
        }

        return try! NSAttributedString(attributed, including: \.appKit)
    }
}
