//
//  ProjectPackage.swift
//  final final
//

import Foundation

struct ProjectPackage: Sendable {
    let packageURL: URL

    var databaseURL: URL { packageURL.appendingPathComponent("content.sqlite") }
    var referencesURL: URL { packageURL.appendingPathComponent("references") }

    /// Creates a new .ff package at the specified location.
    /// If a package already exists at this URL (e.g., NSSavePanel "Replace"),
    /// the existing package is removed entirely before creating a fresh one.
    static func create(at url: URL, title: String) throws -> ProjectPackage {
        let fm = FileManager.default
        let packageURL = url.pathExtension == "ff" ? url : url.appendingPathExtension("ff")

        // Remove existing package if present (NSSavePanel doesn't delete
        // directory-based packages when user clicks "Replace")
        if fm.fileExists(atPath: packageURL.path) {
            print("[ProjectPackage] Replacing existing package at: \(packageURL.path)")
            try fm.removeItem(at: packageURL)
        }

        // Create fresh package directory
        try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)

        // Create references subdirectory
        let refsURL = packageURL.appendingPathComponent("references")
        try fm.createDirectory(at: refsURL, withIntermediateDirectories: true)

        print("[ProjectPackage] Created package at: \(packageURL.path)")
        return ProjectPackage(packageURL: packageURL)
    }

    /// Opens an existing .ff package
    static func open(at url: URL) throws -> ProjectPackage {
        let fm = FileManager.default
        var isDir: ObjCBool = false

        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw PackageError.notFound(url.path)
        }

        let package = ProjectPackage(packageURL: url)
        try package.validate()
        return package
    }

    /// Validates the package structure
    func validate() throws {
        let fm = FileManager.default

        // Database must exist
        guard fm.fileExists(atPath: databaseURL.path) else {
            throw PackageError.missingDatabase
        }
    }

    enum PackageError: Error, LocalizedError {
        case notFound(String)
        case missingDatabase

        var errorDescription: String? {
            switch self {
            case .notFound(let path): return "Package not found at: \(path)"
            case .missingDatabase: return "Package is missing content.sqlite"
            }
        }
    }
}
