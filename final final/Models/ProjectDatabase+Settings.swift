//
//  ProjectDatabase+Settings.swift
//  final final
//
//  Key/value accessors for the per-project `settings` table (created in the
//  `v1` migration of ProjectDatabase.swift).
//
//  Not to be confused with `AppDatabase.getSetting`/`setSetting`/`deleteSetting`
//  (Database.swift), which read and write the APP-level database -- global to the
//  whole app, not stored inside the project package. Values written through these
//  methods travel with the project itself.
//

import Foundation
import GRDB

// MARK: - ProjectDatabase Settings

extension ProjectDatabase {
    func getSetting(key: String) throws -> String? {
        try read { db in
            try Setting.filter(Column("key") == key).fetchOne(db)?.value
        }
    }

    /// Several settings in one read transaction (a consistent snapshot). Keys with no row
    /// are simply absent from the result.
    func getSettings(keys: [String]) throws -> [String: String] {
        try read { db in
            let rows = try Setting.filter(keys.contains(Column("key"))).fetchAll(db)
            return Dictionary(rows.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
        }
    }

    func setSetting(key: String, value: String) throws {
        try write { db in
            let setting = Setting(key: key, value: value)
            try setting.save(db, onConflict: .replace)
        }
    }
}
