import AppUpdater
import Foundation
import os.log

private let updateLog = Logger(subsystem: "com.openwritr.app", category: "UpdateManager")

/// Snapshot of the in-app auto-update flow, driving the "Check for Updates…" UI.
enum UpdateState: Sendable, Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable(version: String)
    case downloading(version: String)
    case readyToInstall(version: String)
    case installing
    case failed(message: String)
}

/// Wraps `AppUpdater` (mxcl/AppUpdater) to check GitHub Releases for newer,
/// Developer ID-signed builds of OpenWritr and install them in place.
///
/// OpenWritr is distributed outside the Mac App Store, so this is the only
/// mechanism that keeps installs current without asking users to manually
/// re-download a DMG from GitHub.
@MainActor
@Observable
final class UpdateManager {
    /// Owner/repo hosting the signed release DMGs consulted by AppUpdater.
    private static let repositoryOwner = "trsdn"
    private static let repositoryName = "OpenWritr"

    /// UserDefaults key for the "automatically check for updates" preference.
    static let automaticCheckPreferenceKey = "automaticUpdateCheckEnabled"

    /// How often an automatic background check is allowed to run.
    private static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    private(set) var state: UpdateState = .idle

    /// True while an install is armed; callers should quiesce audio/hotkey
    /// state and must not tear the app down themselves once this flips.
    private(set) var isInstalling = false

    private let updater: AppUpdater
    private var preparedUpdate: PreparedUpdate?
    private var lastAutomaticCheck: Date?
    private var automaticCheckTask: Task<Void, Never>?

    /// Invoked immediately before `installAndRelaunch()` so the host app can
    /// stop recording/hotkey/paste activity before AppUpdater replaces the bundle.
    var onWillInstall: (() -> Void)?

    /// No `GitHubAttestationPolicy`, for two reasons (see #31):
    ///
    /// - Release signing runs in `trsdn/macos-notarization-broker`, not this source
    ///   repository, so broker provenance cannot satisfy a source-repository policy.
    ///   The broker also deliberately never attests either OpenWritr DMG: the updater
    ///   alias and versioned DMG share one digest, and 1.6.0 can crash if that digest
    ///   has an attestation.
    /// - It loads its Sigstore trust roots through SwiftPM's `Bundle.module`, which, in a
    ///   `swift build` product, only looks at the `.app` root and the build machine's
    ///   `.build` path, never at `Contents/Resources`. Verifying an attestation therefore
    ///   hits `fatalError` in the shipped app.
    ///
    /// The Developer ID check still applies: the downloaded app must carry the same Team ID,
    /// signing identifier and bundle identifier as the installed one.
    init() {
        updater = AppUpdater(owner: Self.repositoryOwner, repo: Self.repositoryName)
    }

    var automaticCheckEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.automaticCheckPreferenceKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Self.automaticCheckPreferenceKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.automaticCheckPreferenceKey)
        }
    }

    /// Kicks off a background check on launch (and periodically thereafter)
    /// if the user has not disabled automatic checks.
    func startAutomaticChecksIfNeeded() {
        automaticCheckTask?.cancel()
        automaticCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.automaticCheckEnabled, self.shouldRunAutomaticCheck() {
                    await self.checkForUpdates(userInitiated: false)
                }
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    func stopAutomaticChecks() {
        automaticCheckTask?.cancel()
        automaticCheckTask = nil
    }

    private func shouldRunAutomaticCheck() -> Bool {
        guard let lastAutomaticCheck else { return true }
        return Date().timeIntervalSince(lastAutomaticCheck) >= Self.automaticCheckInterval
    }

    /// Checks GitHub Releases for a newer, signature-validated build.
    /// Safe to call repeatedly (e.g. from a menu item); results are reflected in `state`.
    func checkForUpdates(userInitiated: Bool) async {
        guard !isInstalling else { return }
        if userInitiated {
            state = .checking
        } else {
            lastAutomaticCheck = Date()
        }

        do {
            guard let update = try await updater.check() else {
                updateLog.info("No update available")
                if userInitiated { state = .upToDate }
                return
            }

            updateLog.notice("Update available: \(update.version, privacy: .public)")
            state = .updateAvailable(version: update.version)
            state = .downloading(version: update.version)
            let prepared = try await update.prepareInstallation()
            preparedUpdate = prepared
            state = .readyToInstall(version: update.version)
        } catch is CancellationError {
            state = .idle
        } catch {
            updateLog.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(message: error.localizedDescription)
        }
    }

    /// Installs a previously prepared update and relaunches the app.
    /// Calls `onWillInstall` first so the host can stop recording/hotkey work.
    func installPreparedUpdate() async {
        guard let prepared = preparedUpdate else { return }
        isInstalling = true
        state = .installing
        onWillInstall?()

        do {
            try await prepared.installAndRelaunch()
            // installAndRelaunch() terminates this process on success; if we
            // reach this line the relaunch itself failed after replacement.
        } catch {
            updateLog.error("Install failed: \(error.localizedDescription, privacy: .public)")
            isInstalling = false
            preparedUpdate = nil
            state = .failed(message: error.localizedDescription)
        }
    }

    /// Discards a prepared update without installing it (e.g. user dismissed the prompt).
    func discardPreparedUpdate() async {
        guard let prepared = preparedUpdate else { return }
        preparedUpdate = nil
        await prepared.discard()
        state = .idle
    }

    func dismissFailure() {
        if case .failed = state {
            state = .idle
        }
    }
}
