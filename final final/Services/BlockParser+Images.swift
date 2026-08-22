//
//  BlockParser+Images.swift
//  final final
//
//  Image fragment parsing: src, alt, caption and width. Extracted from BlockParser.swift.
//

import Foundation

extension BlockParser {

    // MARK: - Image Metadata

    /// Image fields for one parsed block. All nil for a non-image block.
    struct ParsedImageMeta {
        var src: String?
        var alt: String?
        var caption: String?
        var width: Int?
    }

    /// Every image field `parse()` needs for a single block fragment.
    static func imageMetadata(for trimmed: String, blockType: BlockType) -> ParsedImageMeta {
        guard blockType == .image else { return ParsedImageMeta() }

        let meta = parseImageFragmentMeta(from: trimmed)
        // Parse {width=N%} from Pandoc attributes
        let width = parseImageWidthPercent(from: trimmed)
        if width != nil {
            DebugLog.log(.image, "[BlockParser] Parsed width=\(width ?? -1) from fragment: \(trimmed.prefix(60))")
        }
        return ParsedImageMeta(src: meta.src, alt: meta.alt, caption: meta.caption, width: width)
    }

    /// Extract integer percentage from a `{width=N%}` Pandoc attribute in a markdown fragment.
    /// Returns nil if no width attribute is present.
    static func parseImageWidthPercent(from fragment: String) -> Int? {
        guard let attrMatch = fragment.range(
            of: #"\{[^}]*width=(\d+)%[^}]*\}"#, options: .regularExpression
        ) else { return nil }
        let attrStr = String(fragment[attrMatch])
        guard let numRange = attrStr.range(
            of: #"(?<=width=)\d+(?=%)"#, options: .regularExpression
        ) else { return nil }
        return Int(attrStr[numRange])
    }

    // MARK: - Image Caption/Alt Parsing

    /// Extracted alt/caption/src for an image markdown fragment's `![...](...)` syntax.
    struct ImageFragmentMeta {
        let src: String?
        let alt: String?
        let caption: String?
    }

    /// Parses `![bracket-text](src){...attrs...}`, separating caption from accessibility alt
    /// text using the SAME self-marking rule as the editor's `image-plugin.ts`: the presence
    /// of an `alt="..."` attribute (even empty) signals the CURRENT format, where bracket text
    /// is the caption and the attribute is the alt. Its absence signals a pre-fix document,
    /// where bracket text is (as before) the alt — any caption for that case lives in the
    /// legacy `<!-- caption: ... -->` comment, recovered separately by
    /// `Database+BlocksReplace.swift`'s gap-fill (not here).
    static func parseImageFragmentMeta(from fragment: String) -> ImageFragmentMeta {
        // Bracket text uses an escape-aware character class (`(?:[^\]\\]|\\.)*`, not a bare
        // `[^\]]*`) so a caption containing an escaped bracket (`\]`) doesn't prematurely end
        // the match — a caption is user-typed free text, unlike the old format's auto-filled
        // filename, so it's meaningfully more likely to contain "]" in practice.
        guard let imageMatch = fragment.range(
            of: #"!\[(?:[^\]\\]|\\.)*\]\([^)]+\)"#, options: .regularExpression
        ) else { return ImageFragmentMeta(src: nil, alt: nil, caption: nil) }

        let matchStr = String(fragment[imageMatch])
        guard let bracketRange = matchStr.range(of: #"(?<=!\[)(?:[^\]\\]|\\.)*(?=\])"#, options: .regularExpression),
              let srcRange = matchStr.range(of: #"(?<=\()[^)]+(?=\))"#, options: .regularExpression) else {
            return ImageFragmentMeta(src: nil, alt: nil, caption: nil)
        }

        let bracketText = String(matchStr[bracketRange])
        let src = String(matchStr[srcRange])

        if let rawAltValue = extractAltAttributeValue(from: fragment) {
            // Current format: bracket text is the caption; the attribute carries the real
            // accessibility alt text. One more unescape pass recovers image-plugin.ts's own
            // manual escaping layer — extractAltAttributeValue has already normalized away the
            // OTHER (automatic, library-added) layer while locating the value's boundaries.
            return ImageFragmentMeta(
                src: src,
                alt: unescapeBackslashOnce(rawAltValue),
                caption: unescapeCaptionBracketText(bracketText)
            )
        } else {
            // Pre-fix format: bracket text is the alt (unchanged from historical behavior).
            return ImageFragmentMeta(src: src, alt: bracketText, caption: nil)
        }
    }

    /// Extracts the value of an `alt="..."` attribute from the fragment's trailing `{...}`
    /// block, or nil if no `alt=` key exists at all — the self-marking "old format" signal
    /// (distinct from returning "" for an explicit but empty `alt=""`).
    ///
    /// The on-disk attribute block has TWO layers of backslash-escaping baked in:
    /// `image-plugin.ts`'s own `escapeAltAttr` (one manual layer, e.g. `"` → `\"`) PLUS a second
    /// layer that mdast-util-to-markdown's serializer adds automatically on top when writing a
    /// value that would otherwise misparse on the next read (confirmed empirically: a value
    /// with no backslash of its own still comes out with 2 backslashes per quote in the
    /// persisted markdownFragment). On the JS/remark-parse side, remark's own automatic
    /// CommonMark unescaping consumes exactly that second layer — scoped to this exact text
    /// run, since remark tokenizes it as its own text node — before `image-plugin.ts`'s own
    /// extraction regex ever looks for the `alt="..."` boundary. This regex-based Swift parser
    /// reads the raw, unprocessed bytes directly, so it must replicate that same normalization
    /// itself, scoped to the isolated attribute block ONLY (not the whole fragment, which would
    /// also wrongly strip the caption's own single-layer bracket escaping — see
    /// unescapeCaptionBracketText), before it can unambiguously locate the closing quote: a raw
    /// `\\"` is genuinely ambiguous between "escaped backslash then a bare terminating quote"
    /// and "one double-escaped quote" without this normalization first.
    private static func extractAltAttributeValue(from fragment: String) -> String? {
        guard let attrBlockRange = fragment.range(
            of: #"\{[^{]*\}\s*$"#, options: [.regularExpression, .backwards]
        ) else { return nil }
        let normalizedBlock = unescapeBackslashOnce(String(fragment[attrBlockRange]))

        guard let regex = try? NSRegularExpression(pattern: #"alt="((?:[^"\\]|\\.)*)""#) else { return nil }
        let range = NSRange(normalizedBlock.startIndex..., in: normalizedBlock)
        guard let match = regex.firstMatch(in: normalizedBlock, range: range),
              let valueRange = Range(match.range(at: 1), in: normalizedBlock) else { return nil }
        return String(normalizedBlock[valueRange])
    }

    /// Reverses one layer of backslash-escaping (`\X` → `X` for any `X`).
    private static func unescapeBackslashOnce(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\\(.)"#) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
    }

    /// Reverses the single layer of backslash-escaping that mdast-util-to-markdown's own image
    /// serializer applies to bracket/description text (e.g. `]` → `\]`) — standard CommonMark
    /// escaping, not something `image-plugin.ts` adds manually, so (unlike the alt attribute)
    /// only one unescape pass is needed here.
    private static func unescapeCaptionBracketText(_ text: String) -> String {
        unescapeBackslashOnce(text)
    }
}
