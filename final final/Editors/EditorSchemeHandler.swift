//
//  EditorSchemeHandler.swift
//  final final
//
//  Custom URL scheme handler for serving bundled web editor assets.
//  Uses editor:// scheme to load HTML, JS, CSS from the app bundle.
//

import WebKit
import UniformTypeIdentifiers

final class EditorSchemeHandler: NSObject, WKURLSchemeHandler {
    private let resourceSubdirectory = "editor"

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(SchemeError.invalidURL)
            return
        }

        guard let fileURL = bundleURL(for: url) else {
            print("[EditorSchemeHandler] File not found: \(url)")
            urlSchemeTask.didFailWithError(SchemeError.fileNotFound)
            return
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            print("[EditorSchemeHandler] Failed to read: \(fileURL)")
            urlSchemeTask.didFailWithError(SchemeError.readError)
            return
        }

        let mimeType = self.mimeType(for: fileURL)

        let response = HTTPURLResponse(
            url: url,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        )

        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()

        print("[EditorSchemeHandler] Served: \(url.path) (\(mimeType), \(data.count) bytes)")
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func bundleURL(for url: URL) -> URL? {
        // URL format: editor://milkdown/milkdown.html
        // - host = "milkdown" (editor type)
        // - path = "/milkdown.html" (filename)
        // Bundle path: editor/milkdown/milkdown.html

        var pathComponents = url.pathComponents.filter { $0 != "/" }

        // Include host as first path component (editor type: milkdown, codemirror)
        if let host = url.host, !host.isEmpty {
            pathComponents.insert(host, at: 0)
        }

        guard !pathComponents.isEmpty else { return nil }

        let filename = pathComponents.last!
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension

        // Build subdirectory path: "editor/milkdown" (for folder references)
        let subfolders = pathComponents.dropLast()
        let subdirectory: String
        if subfolders.isEmpty {
            subdirectory = resourceSubdirectory
        } else {
            subdirectory = resourceSubdirectory + "/" + subfolders.joined(separator: "/")
        }

        // Try folder reference structure first: editor/milkdown/milkdown.html
        if let url = Bundle.main.url(
            forResource: name,
            withExtension: ext.isEmpty ? nil : ext,
            subdirectory: subdirectory
        ) {
            return url
        }

        // Fall back to flat resources (for groups/legacy structure)
        return Bundle.main.url(forResource: name, withExtension: ext.isEmpty ? nil : ext)
    }

    private func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()

        if let utType = UTType(filenameExtension: ext),
           let mimeType = utType.preferredMIMEType {
            return mimeType
        }

        switch ext {
        case "html", "htm": return "text/html"
        case "js", "mjs": return "application/javascript"
        case "css": return "text/css"
        case "json", "map": return "application/json"
        case "svg": return "image/svg+xml"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        default: return "application/octet-stream"
        }
    }

    enum SchemeError: Error, LocalizedError {
        case invalidURL, fileNotFound, readError

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid URL in editor:// scheme request"
            case .fileNotFound: return "Requested file not found in bundle"
            case .readError: return "Failed to read file data"
            }
        }
    }
}
