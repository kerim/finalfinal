//
//  StringExtensions.swift
//  final final
//
//  Shared string extension for JavaScript template literal escaping.
//

import Foundation

extension String {
    /// Escapes string for use in JavaScript template literals
    var escapedForJSTemplateLiteral: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "${", with: "\\${")
            .replacingOccurrences(of: "\r\n", with: "\n")  // Normalize Windows line endings
            .replacingOccurrences(of: "\r", with: "\n")    // Normalize old Mac line endings
            .replacingOccurrences(of: "\0", with: "")      // Remove null bytes
    }

    /// The same characters held as Swift's own contiguous UTF-8 storage.
    ///
    /// The whole-document text a web editor hands back (`evaluateJavaScript(...) as? String`) is an `NSString` bridged lazily into a
    /// `String`: `isContiguousUTF8` is false, and every `String.count` or `String.index(_:offsetBy:)` on it walks the text through
    /// CoreFoundation instead of over UTF-8 bytes (about 35 ms per `count` at 350,000 characters, against 0.8 ms on native text;
    /// t-94369a83, close-time section sync). One copy here, where the text arrives, makes every later reader native. A string that is
    /// already contiguous is returned as it is (no copy).
    var contiguousUTF8Copy: String {
        var copy = self
        copy.makeContiguousUTF8()
        return copy
    }
}
