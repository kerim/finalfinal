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
}
