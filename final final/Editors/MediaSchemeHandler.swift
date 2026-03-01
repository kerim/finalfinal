//
//  MediaSchemeHandler.swift
//  final final
//
//  Custom URL scheme handler for serving project media files (images).
//  Uses projectmedia:// scheme to load images from the .ff package's media/ directory.
//

import WebKit
import UniformTypeIdentifiers

final class MediaSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    static let shared = MediaSchemeHandler()

    private let lock = NSLock()
    private var _mediaDirectoryURL: URL?

    /// The current project's media directory URL.
    /// Thread-safe: protected by NSLock since WKURLSchemeHandler methods may be called off-main.
    var mediaDirectoryURL: URL? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _mediaDirectoryURL
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _mediaDirectoryURL = newValue
        }
    }

    private override init() {
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(SchemeError.invalidURL)
            return
        }

        guard let mediaDir = mediaDirectoryURL else {
            print("[MediaSchemeHandler] No media directory set (no project open)")
            urlSchemeTask.didFailWithError(SchemeError.noProjectOpen)
            return
        }

        // URL format: projectmedia://filename.png
        // The host is the filename
        let filename: String
        if let host = url.host, !host.isEmpty {
            // Append path components if any (e.g., projectmedia://subdir/file.png)
            var components = [host]
            let pathParts = url.pathComponents.filter { $0 != "/" }
            components.append(contentsOf: pathParts)
            filename = components.joined(separator: "/")
        } else {
            print("[MediaSchemeHandler] No filename in URL: \(url)")
            urlSchemeTask.didFailWithError(SchemeError.fileNotFound)
            return
        }

        let fileURL = mediaDir.appendingPathComponent(filename)

        // Security: ensure the resolved path is within the media directory
        let resolvedPath = fileURL.standardizedFileURL.path
        let mediaDirPath = mediaDir.standardizedFileURL.path
        guard resolvedPath.hasPrefix(mediaDirPath) else {
            print("[MediaSchemeHandler] Path traversal attempt blocked: \(filename)")
            urlSchemeTask.didFailWithError(SchemeError.fileNotFound)
            return
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("[MediaSchemeHandler] File not found: \(fileURL.path)")
            urlSchemeTask.didFailWithError(SchemeError.fileNotFound)
            return
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            print("[MediaSchemeHandler] Failed to read: \(fileURL.path)")
            urlSchemeTask.didFailWithError(SchemeError.readError)
            return
        }

        let mimeType = self.mimeType(for: fileURL)

        let response = HTTPURLResponse(
            url: url,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: nil
        )

        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()

        if let utType = UTType(filenameExtension: ext),
           let mimeType = utType.preferredMIMEType {
            return mimeType
        }

        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "heic": return "image/heic"
        case "tiff", "tif": return "image/tiff"
        case "bmp": return "image/bmp"
        default: return "application/octet-stream"
        }
    }

    enum SchemeError: Error, LocalizedError {
        case invalidURL
        case noProjectOpen
        case fileNotFound
        case readError

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid URL in projectmedia:// scheme request"
            case .noProjectOpen: return "No project open — cannot serve media"
            case .fileNotFound: return "Requested media file not found"
            case .readError: return "Failed to read media file data"
            }
        }
    }
}
