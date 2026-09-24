import Foundation
import Testing
@testable import OpenWritr

@Suite("App presence")
@MainActor
struct AppPresenceTests {
    @Test func modesExposeExpectedSurfaces() {
        #expect(AppPresence.menuBarOnly.showsMenuBar)
        #expect(!AppPresence.menuBarOnly.showsDock)
        #expect(!AppPresence.dockOnly.showsMenuBar)
        #expect(AppPresence.dockOnly.showsDock)
        #expect(AppPresence.dockAndMenuBar.showsMenuBar)
        #expect(AppPresence.dockAndMenuBar.showsDock)
    }

    @Test func invalidStoredValueFallsBackToMenuBar() {
        #expect(AppPresence.restored(from: "unknown") == .menuBarOnly)
        #expect(AppPresence.restored(from: nil) == .menuBarOnly)
    }

    @Test func validStoredValueRestoresMode() {
        #expect(AppPresence.restored(from: "dockOnly") == .dockOnly)
        #expect(AppPresence.restored(from: "dockAndMenuBar") == .dockAndMenuBar)
    }

    @Test func changingPresenceAppliesAndPersistsMode() {
        let dependencies = makeDependencies()
        defer { dependencies.defaults.removePersistentDomain(forName: dependencies.suiteName) }
        let viewModel = dependencies.makeViewModel()

        viewModel.setAppPresence(.dockAndMenuBar)

        #expect(viewModel.appPresence == .dockAndMenuBar)
        #expect(dependencies.controller.appliedModes == [.dockAndMenuBar])
        #expect(dependencies.defaults.string(forKey: "appPresence") == "dockAndMenuBar")
    }

    @Test func failedPresenceChangeKeepsReachableMode() {
        let dependencies = makeDependencies()
        defer { dependencies.defaults.removePersistentDomain(forName: dependencies.suiteName) }
        dependencies.controller.shouldSucceed = false
        let viewModel = dependencies.makeViewModel()

        viewModel.setAppPresence(.dockOnly)

        #expect(viewModel.appPresence == .menuBarOnly)
        #expect(dependencies.defaults.string(forKey: "appPresence") == nil)
        #expect(dependencies.errorLogger.messages == [
            "Failed to apply app presence mode dockOnly",
        ])
    }

    private func makeDependencies() -> PresenceDependencies {
        let suiteName = "AppPresenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return PresenceDependencies(
            suiteName: suiteName,
            defaults: defaults,
            controller: RecordingPresenceController(),
            errorLogger: PresenceErrorLogger()
        )
    }
}

@MainActor
private struct PresenceDependencies {
    let suiteName: String
    let defaults: UserDefaults
    let controller: RecordingPresenceController
    let errorLogger: PresenceErrorLogger

    func makeViewModel() -> AppViewModel {
        AppViewModel(
            errorLogger: errorLogger,
            applicationPresenceController: controller,
            appPresenceDefaults: defaults
        )
    }
}

@MainActor
private final class RecordingPresenceController: ApplicationPresenceControlling {
    var shouldSucceed = true
    private(set) var appliedModes: [AppPresence] = []

    func apply(_ presence: AppPresence) -> Bool {
        appliedModes.append(presence)
        return shouldSucceed
    }
}

@MainActor
private final class PresenceErrorLogger: ErrorLogging {
    private(set) var messages: [String] = []

    func logError(_ message: String) {
        messages.append(message)
    }
}
