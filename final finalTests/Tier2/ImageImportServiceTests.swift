//
//  ImageImportServiceTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//  Tests for ImageImportService: extension validation, filename sanitization,
//  collision handling, format/size validation, and error descriptions.
//

import Testing
import Foundation
@testable import final_final

@Suite("Image Import Service — Tier 2: Visible Breakage")
struct ImageImportServiceTests {

    // MARK: - Allowed Extensions

    @Test("allowedExtensions contains all 10 expected extensions")
    func allowedExtensionsComplete() {
        let expected: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "svg", "bmp"]
        #expect(ImageImportService.allowedExtensions == expected)
    }

    // MARK: - Filename Sanitization

    @Test("uniqueFilename sanitizes spaces and special chars to lowercase-hyphenated")
    func uniqueFilenameSanitizes() {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("img-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Spaces → hyphens, uppercase → lowercase
        let result1 = ImageImportService.uniqueFilename(for: "My Photo.PNG", in: tempDir)
        #expect(result1 == "my-photo.png")

        // Underscores → hyphens
        let result2 = ImageImportService.uniqueFilename(for: "test_image_2.jpg", in: tempDir)
        #expect(result2 == "test-image-2.jpg")

        // Special chars removed
        let result3 = ImageImportService.uniqueFilename(for: "image@#$.png", in: tempDir)
        #expect(result3 == "image.png")
    }

    @Test("uniqueFilename adds -1, -2 suffixes on collision")
    func uniqueFilenameCollision() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("img-collision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create existing files to cause collision
        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent("photo.png").path,
            contents: Data()
        )
        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent("photo-1.png").path,
            contents: Data()
        )

        let result = ImageImportService.uniqueFilename(for: "photo.png", in: tempDir)
        #expect(result == "photo-2.png")
    }

    // MARK: - Format Validation

    @Test(".txt extension throws unsupportedFormat")
    @MainActor
    func unsupportedFormatThrows() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("img-format-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let txtFile = tempDir.appendingPathComponent("test.txt")
        FileManager.default.createFile(atPath: txtFile.path, contents: Data(repeating: 0, count: 10))

        do {
            _ = try ImageImportService.importFromURL(txtFile, mediaDir: tempDir)
            Issue.record("Expected ImportError.unsupportedFormat to be thrown")
        } catch is ImageImportService.ImportError {
            // Expected
        }
    }

    // MARK: - Size Validation

    @Test("blockSizeBytes is 25MB")
    func blockSizeConstant() {
        #expect(ImageImportService.blockSizeBytes == 25 * 1024 * 1024)
    }

    @Test("warnSizeBytes is 10MB")
    func warnSizeConstant() {
        #expect(ImageImportService.warnSizeBytes == 10 * 1024 * 1024)
    }

    // MARK: - ImportError descriptions

    @Test("ImportError.errorDescription produces non-nil strings for all cases")
    func importErrorDescriptions() {
        let cases: [ImageImportService.ImportError] = [
            .unsupportedFormat("xyz"),
            .fileTooLarge(30_000_000),
            .noMediaDirectory,
            .copyFailed(NSError(domain: "test", code: 0))
        ]

        for error in cases {
            #expect(error.errorDescription != nil, "errorDescription should be non-nil for \(error)")
            #expect(!error.errorDescription!.isEmpty, "errorDescription should be non-empty for \(error)")
        }
    }

    // MARK: - Successful Import

    @Test("Successful import of small PNG to temp media dir")
    @MainActor
    func successfulImport() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("img-import-\(UUID().uuidString)")
        let mediaDir = tempDir.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a small "PNG" file (just needs valid extension, content doesn't matter for copy)
        let sourceFile = tempDir.appendingPathComponent("test-image.png")
        // Minimal PNG: 8-byte signature + minimal IHDR + IEND
        let pngData = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,  // PNG signature
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,  // IHDR chunk
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,  // 1x1
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
            0xDE, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,  // IEND chunk
            0x44, 0xAE, 0x42, 0x60, 0x82
        ])
        try pngData.write(to: sourceFile)

        let relativePath = try ImageImportService.importFromURL(sourceFile, mediaDir: mediaDir)
        #expect(relativePath == "media/test-image.png")
        #expect(FileManager.default.fileExists(atPath: mediaDir.appendingPathComponent("test-image.png").path))
    }
}
