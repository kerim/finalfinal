//
//  ProjectDatabase+Observation.swift
//  final final
//
//  Read/write passthroughs and reactive ValueObservation streams for ProjectDatabase,
//  split out of ProjectDatabase.swift to keep that class's body under SwiftLint's
//  type_body_length limit. Mechanical move only -- no behavior change.
//

import Foundation
import GRDB

extension ProjectDatabase {
    func read<T>(_ block: (Database) throws -> T) throws -> T {
        try dbWriter.read(block)
    }

    func write<T>(_ block: (Database) throws -> T) throws -> T {
        try dbWriter.write(block)
    }

    // MARK: - Reactive Observation

    /// Returns an async sequence of annotation updates for reactive UI
    /// Uses ValueObservation to automatically push updates when annotations change
    func observeAnnotations(for contentId: String) -> AsyncThrowingStream<[Annotation], Error> {
        let observation = ValueObservation
            .tracking { db in
                try Annotation
                    .filter(Annotation.Columns.contentId == contentId)
                    .order(Annotation.Columns.charOffset)
                    .fetchAll(db)
            }
            .removeDuplicates()

        return AsyncThrowingStream { continuation in
            let cancellable = observation.start(
                in: dbWriter,
                scheduling: .async(onQueue: .main)
            ) { error in
                continuation.finish(throwing: error)
            } onChange: { annotations in
                continuation.yield(annotations)
            }

            continuation.onTermination = { _ in
                cancellable.cancel()
            }
        }
    }
}
