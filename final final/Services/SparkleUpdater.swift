//
//  SparkleUpdater.swift
//  final final
//

import Combine
import Sparkle

// Must be app-scoped (@State on the App struct). Moving to a view-scoped @State
// will deallocate the controller mid-session and break background update checks.
@MainActor
@Observable
final class SparkleUpdater {
    private let controller: SPUStandardUpdaterController
    private(set) var canCheckForUpdates = false
    private var cancellable: AnyCancellable?

    init() {
        // Skip starting the updater in test mode to avoid live network I/O during test runs
        controller = SPUStandardUpdaterController(
            startingUpdater: !TestMode.isTesting,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        canCheckForUpdates = controller.updater.canCheckForUpdates
        cancellable = controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                // .receive(on: DispatchQueue.main) guarantees main-thread delivery;
                // assumeIsolated makes the @MainActor isolation explicit.
                MainActor.assumeIsolated {
                    self?.canCheckForUpdates = value
                }
            }
    }

    func checkForUpdates() {
        // Use the controller entry point so userDriverDelegate hooks are honoured
        controller.checkForUpdates(nil)
    }
}
