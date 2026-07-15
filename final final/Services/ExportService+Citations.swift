//
//  ExportService+Citations.swift
//  final final
//

import Foundation

// MARK: - Citation Detection

extension ExportService {

    /// Detect Pandoc citations in content (skips code blocks and inline code)
    /// Matches any bracketed text containing @ followed by a citekey
    /// Pattern from citation-plugin.ts: \[([^\]]*@[\w:.-][^\]]*)\]
    func hasPandocCitations(in content: String) -> Bool {
        let stripped = MarkdownUtils.stripCodeContent(from: content)
        return stripped.range(
            of: #"\[[^\]]*@[\w:.-]+[^\]]*\]"#,
            options: .regularExpression
        ) != nil
    }

    /// Extract citekeys from markdown content (skips code blocks and inline code).
    /// Duplicates BibliographySyncService.extractCitekeys regex to avoid @MainActor isolation.
    func extractCitekeys(from content: String) -> [String] {
        let stripped = MarkdownUtils.stripCodeContent(from: content)
        let pattern = #"(?:\[|; )@([^\],;\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(stripped.startIndex..., in: stripped)
        return regex.matches(in: stripped, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: stripped) else { return nil }
            return String(stripped[r])
        }
    }

    /// Fetch bibliography as raw CSL-JSON string from Zotero/BBT for the given citekeys.
    /// Uses the same JSON-RPC endpoint as ZoteroService.fetchItemsForCitekeys()
    /// but returns the raw JSON string for pandoc to consume directly.
    func fetchBibliographyJSON(for citekeys: [String]) async -> String? {
        guard !citekeys.isEmpty else { return nil }

        let url = URL(string: "http://127.0.0.1:23119/better-bibtex/json-rpc")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "item.export",
            "params": [citekeys, "Better CSL JSON"]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            // item.export returns JSON-RPC wrapper; extract the result
            guard let jsonObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            // Result may be a JSON string or an array
            if let resultString = jsonObj["result"] as? String, !resultString.isEmpty {
                return resultString
            } else if let resultArray = jsonObj["result"] as? [[String: Any]], !resultArray.isEmpty {
                let resultData = try JSONSerialization.data(withJSONObject: resultArray)
                return String(data: resultData, encoding: .utf8)
            }
            return nil
        } catch {
            DebugLog.log(.fileOps, "[ExportService] Failed to fetch bibliography JSON: \(error)")
            return nil
        }
    }

    /// Strip annotation HTML comments from markdown content
    /// Matches patterns like <!-- ::task:: text --> or <!-- ::comment:: notes -->
    func stripAnnotations(from content: String) -> String {
        // Match annotation comments: <!-- ::type:: text -->
        // Annotations can span multiple lines and contain various content
        // Use .dotMatchesLineSeparators so .*? can span newlines
        content.replacingOccurrences(
            of: #"<!--\s*::\w+::\s*[\s\S]*?-->"#,
            with: "",
            options: .regularExpression
        )
    }
}
