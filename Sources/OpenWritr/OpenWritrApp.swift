import SwiftUI
import Combine
import CoreAudio
import ServiceManagement
import os.log
import Foundation

private let appLog = Logger(subsystem: "com.openwritr.app", category: "AppViewModel")

enum RuntimeErrorKind: Sendable, Equatable {
    case audio
    case transcription
    case enhancement
    case paste
}

struct AppErrorPresentation: Sendable {
    let kind: RuntimeErrorKind
    let title: String
    let message: String
    let recoverySuggestion: String?
}

enum AppState: Sendable {
    case idle
    case loading
    case downloading(progress: Double)
    case ready
    case preparingMicrophone
    case listening
    case transcribing
    case enhancing
    case initializationError(AppErrorPresentation)
    case runtimeError(AppErrorPresentation)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

@MainActor
@Observable
final class AppViewModel {
    private struct CustomPromptStore: Codable {
        let version: Int
        let prompts: [String: String]
    }

    private static let keychainService = "com.openwritr.app"
    private static let enhancementAPIKeyAccount = "enhancedOpenAIAPIKey"
    private static let customPromptsPreferenceKey = "enhancementCustomPromptsV1"
    private static let customPromptsStoreVersion = 1
    static let defaultDoneDisplayDuration: Duration = .milliseconds(600)
    static let defaultTransientErrorDisplayDuration: Duration = .seconds(2.5)
    var state: AppState = .idle
    var lastTranscription: String = ""
    var lastRawTranscription: String = ""
    var lastWasEnhanced: Bool = false
    var lastEnhancementModel: String = ""
    var lastEnhancementProvider: String = ""
    var lastEnhancementWarning: String?
    var inputDeviceStatusMessage: String = "OpenWritr follows the current macOS system input device."
    var recoverableRawTranscription: String?
    var debugModeEnabled: Bool = false
    var soundEnabled: Bool = true
    var autoPasteEnabled: Bool = true
    var launchAtLogin: Bool = false
    var hotkeyChoice: HotkeyChoice = .fn
    var availableInputDevices: [AudioInputDevice] = []
    var selectedInputDeviceID: AudioDeviceID?
    var enhancedModeEnabled: Bool = false
    var alwaysEnhancedEnabled: Bool = false
    var enhancedProvider: EnhancedProvider = .copilot
    var enhancedModel: EnhancedModel = .luna
    var enhancedOpenAIBaseURL: String = EnhancedProvider.defaultOpenAIBaseURL
    var enhancedOpenAIAPIKey: String = ""
    var selectedOpenAIModel: String = EnhancedProvider.defaultOpenAIModelOverride
    var availableOpenAIModels: [String] = []
    var isRefreshingOpenAIModels = false
    var openAIModelRefreshMessage: String?
    private(set) var customEnhancementPrompts: [String: String] = [:]
    var appleIntelligenceAvailability = AppleIntelligenceEnhancer.currentAvailability()

    let transcriptionManager: any Transcribing
    let grammarEnhancer: any TranscriptEnhancing
    @ObservationIgnored private let injectedAudioEngine: (any AudioCapturing)?
    @ObservationIgnored lazy var audioEngine: any AudioCapturing = injectedAudioEngine ?? AudioEngine()
    let hotkeyManager = HotkeyManager()
    let pasteManager: any TextPasting
    let overlayPanel: any OverlayPresenting
    let soundManager = SoundManager()
    let permissionsManager = PermissionsManager()
    let updateManager = UpdateManager()

    private let captureDrainIdleDuration: Duration = .milliseconds(70)
    private let captureDrainTimeout: Duration = .milliseconds(350)
    private let doneDisplayDuration: Duration
    private let transientErrorDisplayDuration: Duration
    private var didConfigure = false
    private var didAttemptInitialSetup = false
    private var isInitializing = false
    private var modelsLoaded = false
    private var isOperational = false
    private var didShutdown = false
    @ObservationIgnored private var captureOperationID: UUID?
    @ObservationIgnored private var captureHandle: CaptureHandle?
    @ObservationIgnored private var captureTriggerMode: RecordingShortcutMode?
    @ObservationIgnored private var releaseRequested = false
    @ObservationIgnored private var pendingStartTask: Task<Void, Never>?
    @ObservationIgnored private var transientErrorDismissTask: Task<Void, Never>?
    @ObservationIgnored private var stoppedCaptureGenerations: Set<UInt64> = []
    @ObservationIgnored private var activeProcessingTask: Task<Void, Never>?
    @ObservationIgnored private var activeProcessingOperationID: UUID?
    @ObservationIgnored private var initializationErrorProcessingTask: Task<Void, Never>?
    @ObservationIgnored private var initializationErrorProcessingOperationID: UUID?
    @ObservationIgnored private var initializationRetryID: UUID?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var microphoneRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var microphoneRecoveryID: UUID?

    init(
        audioEngine: (any AudioCapturing)? = nil,
        transcriptionManager: any Transcribing = TranscriptionManager(),
        grammarEnhancer: any TranscriptEnhancing = GrammarEnhancer(),
        pasteManager: any TextPasting = PasteManager(),
        overlayPanel: any OverlayPresenting = OverlayPanel(),
        startsOperational: Bool = false,
        doneDisplayDuration: Duration = AppViewModel.defaultDoneDisplayDuration,
        transientErrorDisplayDuration: Duration = AppViewModel.defaultTransientErrorDisplayDuration
    ) {
        injectedAudioEngine = audioEngine
        self.transcriptionManager = transcriptionManager
        self.grammarEnhancer = grammarEnhancer
        self.pasteManager = pasteManager
        self.overlayPanel = overlayPanel
        self.doneDisplayDuration = doneDisplayDuration
        self.transientErrorDisplayDuration = transientErrorDisplayDuration
        if startsOperational {
            configureAudioCallbacks()
            isOperational = true
            state = .ready
        }
    }

    var displayedOpenAIModels: [String] {
        var models = availableOpenAIModels
        let selected = selectedOpenAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty, !models.contains(selected) { models.insert(selected, at: 0) }
        return models
    }

    var enhancementPromptTargetKey: String {
        GrammarEnhancer.promptTargetKey(
            provider: enhancedProvider,
            model: enhancedModel,
            openAIModel: selectedOpenAIModel
        )
    }

    var enhancementPromptTargetDisplayName: String {
        GrammarEnhancer.promptTargetDisplayName(
            provider: enhancedProvider,
            model: enhancedModel,
            openAIModel: selectedOpenAIModel
        )
    }

    var modelDefaultEnhancementPrompt: String {
        GrammarEnhancer.bundledCleanupPrompt(
            provider: enhancedProvider,
            model: enhancedModel,
            openAIModel: selectedOpenAIModel
        )
    }

    var enhancementPrompt: String {
        customEnhancementPrompts[enhancementPromptTargetKey] ?? modelDefaultEnhancementPrompt
    }

    var enhancementPromptIsCustomized: Bool {
        customEnhancementPrompts[enhancementPromptTargetKey] != nil
    }

    var canChangeInputDevice: Bool {
        guard isOperational,
              !didShutdown,
              captureOperationID == nil,
              pendingStartTask == nil,
              activeProcessingTask == nil
        else { return false }

        switch state {
        case .ready, .runtimeError:
            return true
        default:
            return false
        }
    }

    func setup() async {
        guard !didAttemptInitialSetup else { return }
        didAttemptInitialSetup = true
        await initialize()
    }

    func retryInitialization() async {
        guard case .initializationError = state,
              initializationRetryID == nil
        else { return }

        let retryID = UUID()
        initializationRetryID = retryID
        defer {
            if initializationRetryID == retryID {
                initializationRetryID = nil
            }
        }

        while let processingTask = initializationErrorProcessingTask,
              let operationID = initializationErrorProcessingOperationID {
            await processingTask.value
            guard initializationErrorProcessingOperationID == operationID else {
                continue
            }

            initializationErrorProcessingTask = nil
            initializationErrorProcessingOperationID = nil
            clearActiveProcessingTask(ifCurrent: operationID)
        }

        guard initializationRetryID == retryID,
              case .initializationError = state,
              !didShutdown
        else { return }
        await initialize()
    }

    private func initialize() async {
        guard !didShutdown, !isInitializing, !isOperational else { return }

        configureIfNeeded()
        isInitializing = true
        state = .loading
        hotkeyManager.stop()
        defer { isInitializing = false }

        let permissions = await permissionsManager.checkAllPermissions()
        guard !Task.isCancelled else {
            presentInitializationError(
                AppErrorPresentation(
                    kind: .transcription,
                    title: "Initialization Interrupted",
                    message: "OpenWritr initialization was interrupted.",
                    recoverySuggestion: "Choose Retry Initialization."
                )
            )
            return
        }
        guard permissions.allGranted else {
            presentInitializationError(permissionError(for: permissions))
            return
        }

        if !modelsLoaded {
            do {
                try await transcriptionManager.loadModels { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.isInitializing, !self.modelsLoaded, progress < 1.0 else {
                            return
                        }
                        self.state = .downloading(progress: progress)
                    }
                }
                modelsLoaded = true
            } catch {
                appLog.error(
                    "Model initialization failed: \(error.localizedDescription, privacy: .public)"
                )
                presentInitializationError(
                    errorPresentation(
                        kind: .transcription,
                        title: "Model Initialization Failed",
                        error: error,
                        defaultRecovery: "Check your network connection, then retry initialization."
                    )
                )
                return
            }
        }

        guard !Task.isCancelled else {
            presentInitializationError(
                AppErrorPresentation(
                    kind: .transcription,
                    title: "Initialization Interrupted",
                    message: "OpenWritr initialization was interrupted.",
                    recoverySuggestion: "Choose Retry Initialization."
                )
            )
            return
        }

        state = .loading
        if case .failure(let error) = prepareAudioForStartup() {
            appLog.error("Audio initialization failed: \(error.localizedDescription, privacy: .public)")
            presentInitializationError(
                errorPresentation(kind: .audio, title: "Microphone Initialization Failed", error: error)
            )
            return
        }
        updateInputDeviceStatusMessage()

        if case .failure(let error) = hotkeyManager.start() {
            appLog.error("Hotkey initialization failed: \(error.localizedDescription, privacy: .public)")
            presentInitializationError(
                errorPresentation(kind: .audio, title: "Push-to-Talk Initialization Failed", error: error)
            )
            return
        }

        isOperational = true
        state = .ready
        updateManager.startAutomaticChecksIfNeeded()
    }

    private func configureIfNeeded() {
        guard !didConfigure else { return }
        didConfigure = true

        restorePreferences()
        refreshAppleIntelligenceAvailability()

        updateManager.onWillInstall = { [weak self] in
            self?.quiesceForUpdateInstall()
        }

        configureAudioCallbacks()

        hotkeyManager.onRecordingStarted = { [weak self] mode in
            Task { @MainActor [weak self] in
                self?.startListening(triggerMode: mode)
            }
        }
        hotkeyManager.onRecordingModeChanged = { [weak self] mode in
            Task { @MainActor [weak self] in
                self?.updateRecordingMode(shortcutMode: mode)
            }
        }
        hotkeyManager.onRecordingStopped = { [weak self] mode in
            Task { @MainActor [weak self] in
                self?.startProcessingStoppedRecording(triggerMode: mode)
            }
        }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: NSApplication.shared,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.shutdown()
            }
        }
    }

    private func configureAudioCallbacks() {
        audioEngine.onDevicesChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleInputDevicesChanged()
            }
        }
        audioEngine.onFailure = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.handleAudioFailure(error)
            }
        }
        audioEngine.onAudioLevel = { [weak self] level, generation in
            Task { @MainActor [weak self] in
                guard let self,
                      case .listening = self.state,
                      self.captureHandle?.generation == generation
                else { return }
                self.overlayPanel.updateAudioLevel(level)
            }
        }
    }

    private func restorePreferences() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "soundEnabled") != nil {
            soundEnabled = defaults.bool(forKey: "soundEnabled")
        }
        if defaults.object(forKey: "autoPasteEnabled") != nil {
            autoPasteEnabled = defaults.bool(forKey: "autoPasteEnabled")
        }
        if let raw = defaults.string(forKey: "hotkeyChoice"),
           let choice = HotkeyChoice(rawValue: raw) {
            hotkeyChoice = choice
        }
        if defaults.object(forKey: "enhancedModeEnabled") != nil {
            enhancedModeEnabled = defaults.bool(forKey: "enhancedModeEnabled")
        }
        if defaults.object(forKey: "alwaysEnhancedEnabled") != nil {
            alwaysEnhancedEnabled = defaults.bool(forKey: "alwaysEnhancedEnabled")
        }
        if let raw = defaults.string(forKey: "enhancedProvider"),
           let provider = EnhancedProvider(rawValue: raw) {
            if provider == .appleIntelligence,
               !AppleIntelligenceEnhancer.currentAvailability().isAvailable {
                enhancedProvider = .copilot
                defaults.set(EnhancedProvider.copilot.rawValue, forKey: "enhancedProvider")
            } else {
                enhancedProvider = provider
            }
        }
        if let baseURL = defaults.string(forKey: "enhancedOpenAIBaseURL"), !baseURL.isEmpty {
            enhancedOpenAIBaseURL = baseURL
        }
        if let apiKey = KeychainStore.loadString(service: Self.keychainService, account: Self.enhancementAPIKeyAccount) {
            enhancedOpenAIAPIKey = apiKey
        } else if let apiKey = defaults.string(forKey: "enhancedOpenAIAPIKey") {
            enhancedOpenAIAPIKey = apiKey
            _ = KeychainStore.saveString(apiKey, service: Self.keychainService, account: Self.enhancementAPIKeyAccount)
            defaults.removeObject(forKey: "enhancedOpenAIAPIKey")
        }
        if let selectedModel = defaults.string(forKey: "selectedOpenAIModel"), !selectedModel.isEmpty {
            selectedOpenAIModel = selectedModel
        } else if let modelOverride = defaults.string(forKey: "enhancedOpenAIModelOverride"), !modelOverride.isEmpty {
            selectedOpenAIModel = modelOverride
            defaults.removeObject(forKey: "enhancedOpenAIModelOverride")
        }
        if let raw = defaults.string(forKey: "enhancedModel"),
           let model = EnhancedModel(rawValue: raw) {
            enhancedModel = model
        }
        restoreCustomEnhancementPrompts(defaults: defaults)
        if defaults.object(forKey: "debugModeEnabled") != nil {
            debugModeEnabled = defaults.bool(forKey: "debugModeEnabled")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        hotkeyManager.activeFlag = hotkeyChoice.flag
        hotkeyManager.activeKeyCode = hotkeyChoice.keyCode
    }

    private func prepareAudioForStartup() -> Result<Void, AudioEngineError> {
        refreshInputDevices()

        if let selectedInputDeviceID,
           !availableInputDevices.contains(where: { $0.id == selectedInputDeviceID }) {
            clearSelectedInputDevice()
        }

        if selectedInputDeviceID == nil {
            if let savedUID = UserDefaults.standard.string(forKey: "inputDeviceUID") {
                guard let savedDevice = availableInputDevices.first(where: { $0.uid == savedUID }) else {
                    clearSelectedInputDevice()
                    return prepareAudioUsingSystemDefault()
                }

                switch audioEngine.setInputDevice(savedDevice.id) {
                case .success:
                    selectedInputDeviceID = savedDevice.id
                case .failure(let error):
                    return .failure(error)
                }
            } else {
                return prepareAudioUsingSystemDefault()
            }
        }

        return audioEngine.prepare()
    }

    private func prepareAudioUsingSystemDefault() -> Result<Void, AudioEngineError> {
        if case .failure(let error) = audioEngine.setInputDevice(nil) {
            return .failure(error)
        }
        return audioEngine.prepare()
    }

    private func permissionError(for status: PermissionStatus) -> AppErrorPresentation {
        let missing: String
        switch (status.microphone, status.accessibility) {
        case (false, false):
            missing = "Microphone and Accessibility permissions are required."
        case (false, true):
            missing = "Microphone permission is required."
        case (true, false):
            missing = "Accessibility permission is required for the push-to-talk key."
        case (true, true):
            missing = "Required permissions could not be verified."
        }

        return AppErrorPresentation(
            kind: .audio,
            title: "Permissions Required",
            message: missing,
            recoverySuggestion: "Grant access in System Settings > Privacy & Security, then choose Retry Initialization."
        )
    }

    private func errorPresentation(
        kind: RuntimeErrorKind,
        title: String,
        error: any Error,
        defaultRecovery: String? = nil
    ) -> AppErrorPresentation {
        let localizedError = error as? any LocalizedError
        return AppErrorPresentation(
            kind: kind,
            title: title,
            message: localizedError?.errorDescription ?? error.localizedDescription,
            recoverySuggestion: localizedError?.recoverySuggestion ?? defaultRecovery
        )
    }

    private func presentInitializationError(_ error: AppErrorPresentation) {
        isOperational = false
        cancelActiveProcessingForInitializationError()
        pendingStartTask?.cancel()
        invalidateCaptureOperation()
        hotkeyManager.stop()
        transitionToErrorState(.initializationError(error))
    }

    private func cancelActiveProcessingForInitializationError() {
        guard let processingTask = activeProcessingTask,
              let operationID = activeProcessingOperationID
        else { return }

        initializationErrorProcessingTask = processingTask
        initializationErrorProcessingOperationID = operationID
        processingTask.cancel()
    }

    private func presentRuntimeError(
        _ error: AppErrorPresentation,
        overlayMessage: String,
        recoverableRawTranscription: String? = nil
    ) {
        guard isOperational else {
            presentInitializationError(error)
            return
        }
        self.recoverableRawTranscription = recoverableRawTranscription
        transitionToErrorState(.runtimeError(error))
        overlayPanel.show(state: .error(overlayMessage))
        if error.kind == .transcription || error.kind == .paste {
            scheduleTransientErrorDismissal()
        }
    }

    /// Transcription failures (e.g. after a silent recording) are informational:
    /// flash the overlay, then return to `.ready` without requiring a menu action.
    private func scheduleTransientErrorDismissal() {
        transientErrorDismissTask?.cancel()
        let displayDuration = transientErrorDisplayDuration
        transientErrorDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: displayDuration)
            } catch {
                return
            }
            guard let self, self.isTransientErrorState else { return }
            self.transientErrorDismissTask = nil
            self.overlayPanel.dismiss()
            self.state = .ready
        }
    }

    private var isTransientErrorState: Bool {
        if case .runtimeError(let error) = state,
           error.kind == .transcription || error.kind == .paste {
            return true
        }
        return false
    }

    private func cancelTransientErrorDismissal() {
        transientErrorDismissTask?.cancel()
        transientErrorDismissTask = nil
    }

    private func transitionToErrorState(_ errorState: AppState) {
        state = errorState
    }

    func dismissRuntimeError() {
        guard case .runtimeError(let error) = state, isOperational else { return }
        cancelTransientErrorDismissal()
        if error.kind == .audio {
            retryMicrophone()
            return
        }
        overlayPanel.dismiss()
        state = .ready
    }

    func retryEnhancement() async {
        guard case .runtimeError(let error) = state,
              error.kind == .enhancement,
              isOperational,
              let rawText = recoverableRawTranscription
        else { return }

        state = .enhancing
        overlayPanel.show(state: .enhancing)
        await enhanceAndComplete(rawText: rawText)
    }

    func useRawTranscription() {
        guard case .runtimeError(let error) = state,
              error.kind == .enhancement,
              isOperational,
              let rawText = recoverableRawTranscription
        else { return }

        lastTranscription = rawText
        lastRawTranscription = ""
        lastWasEnhanced = false
        recoverableRawTranscription = nil
        if autoPasteEnabled, pasteManager.pasteText(rawText) == .cancelled {
            presentPasteCancelledError()
            return
        }
        overlayPanel.dismiss()
        state = .ready
    }

    // MARK: - Updates

    func checkForUpdates() {
        Task { await updateManager.checkForUpdates(userInitiated: true) }
    }

    func installAvailableUpdate() {
        Task { await updateManager.installPreparedUpdate() }
    }

    func dismissAvailableUpdate() {
        Task { await updateManager.discardPreparedUpdate() }
    }

    /// Stops recording/hotkey/paste activity before AppUpdater replaces the
    /// app bundle. Mirrors `shutdown()` but keeps `didShutdown` false so the
    /// (about-to-be-replaced) process can still report failures if the
    /// install itself fails partway through.
    private func quiesceForUpdateInstall() {
        grammarEnhancer.cancelActiveEnhancement()
        cancelMicrophoneRecovery()
        pendingStartTask?.cancel()
        activeProcessingTask?.cancel()
        invalidateCaptureOperation()
        hotkeyManager.stop()
        pasteManager.flushPendingRestore()
        overlayPanel.dismiss()
        updateManager.stopAutomaticChecks()
    }

    func savePreference(_ key: String, value: Any) {
        UserDefaults.standard.set(value, forKey: key)
    }

    func setEnhancedProvider(_ provider: EnhancedProvider) {
        if provider == .appleIntelligence {
            refreshAppleIntelligenceAvailability()
            guard appleIntelligenceAvailability.isAvailable else { return }
        }
        enhancedProvider = provider
        savePreference("enhancedProvider", value: provider.rawValue)
    }

    func setEnhancedModel(_ model: EnhancedModel) {
        enhancedModel = model
        savePreference("enhancedModel", value: model.rawValue)
    }

    func refreshAppleIntelligenceAvailability() {
        appleIntelligenceAvailability = AppleIntelligenceEnhancer.currentAvailability()
        if enhancedProvider == .appleIntelligence,
           !appleIntelligenceAvailability.isAvailable {
            enhancedProvider = .copilot
            savePreference("enhancedProvider", value: EnhancedProvider.copilot.rawValue)
        }
    }

    func setHotkey(_ choice: HotkeyChoice) {
        hotkeyChoice = choice
        hotkeyManager.activeFlag = choice.flag
        hotkeyManager.activeKeyCode = choice.keyCode
        UserDefaults.standard.set(choice.rawValue, forKey: "hotkeyChoice")
    }

    func refreshInputDevices() {
        availableInputDevices = audioEngine.availableInputDevices()
    }

    func setInputDevice(_ device: AudioInputDevice?) {
        guard canChangeInputDevice else {
            appLog.notice("Ignoring input device change while microphone work is active")
            return
        }

        cancelMicrophoneRecovery()
        switch audioEngine.setInputDevice(device?.id) {
        case .success:
            selectedInputDeviceID = device?.id
            if let device {
                UserDefaults.standard.set(device.uid, forKey: "inputDeviceUID")
            } else {
                UserDefaults.standard.removeObject(forKey: "inputDeviceUID")
            }
            updateInputDeviceStatusMessage(for: device)
            switch audioEngine.prepare() {
            case .success:
                if case .runtimeError(let presentation) = state,
                   presentation.kind == .audio {
                    appLog.notice("Microphone validation succeeded after input selection")
                    overlayPanel.dismiss()
                    state = .ready
                }
            case .failure(let error):
                appLog.error("Input device validation failed: \(error.localizedDescription, privacy: .public)")
                if device == nil {
                    scheduleSystemDefaultRecovery(showTransientError: true, initialError: error)
                } else {
                    presentRuntimeError(
                        errorPresentation(kind: .audio, title: "Microphone Selection Failed", error: error),
                        overlayMessage: "Microphone unavailable"
                    )
                }
            }
        case .failure(let error):
            if device == nil {
                clearSelectedInputDevice()
                inputDeviceStatusMessage = "The previous macOS system input could not be restored."
            }
            appLog.error("Input device selection failed: \(error.localizedDescription, privacy: .public)")
            if device == nil {
                scheduleSystemDefaultRecovery(showTransientError: true, initialError: error)
            } else {
                presentRuntimeError(
                    errorPresentation(kind: .audio, title: "Microphone Selection Failed", error: error),
                    overlayMessage: "Microphone change failed"
                )
            }
        }
    }

    private func handleInputDevicesChanged() {
        refreshInputDevices()
        if let selectedInputDeviceID,
           !availableInputDevices.contains(where: { $0.id == selectedInputDeviceID }) {
            clearSelectedInputDevice()
            appLog.notice("The selected input device disappeared; following System Default")
            inputDeviceStatusMessage = "Selected input device is no longer available. Waiting for the macOS system default input."
        }

        guard selectedInputDeviceID == nil,
              captureOperationID == nil,
              pendingStartTask == nil,
              activeProcessingTask == nil
        else {
            return
        }
        scheduleSystemDefaultRecovery(showTransientError: false)
    }

    private func clearSelectedInputDevice() {
        selectedInputDeviceID = nil
        UserDefaults.standard.removeObject(forKey: "inputDeviceUID")
    }

    private func handleAudioFailure(_ error: AudioEngineError) {
        guard !didShutdown, isOperational else { return }

        if let operationID = captureOperationID, captureHandle == nil {
            appLog.error(
                "Runtime audio failure invalidated pending capture: \(error.localizedDescription, privacy: .public)"
            )
            pendingStartTask?.cancel()
            invalidateCaptureOperation(ifCurrent: operationID)
            if selectedInputDeviceID == nil {
                scheduleSystemDefaultRecovery(showTransientError: true, initialError: error)
            } else {
                presentRuntimeError(
                    errorPresentation(kind: .audio, title: "Microphone Became Unavailable", error: error),
                    overlayMessage: "Microphone unavailable"
                )
            }
            return
        }

        guard let operationID = captureOperationID,
              let handle = captureHandle
        else {
            appLog.error("Runtime audio failure: \(error.localizedDescription, privacy: .public)")
            inputDeviceStatusMessage = "The microphone configuration failed: \(error.localizedDescription)"
            if selectedInputDeviceID == nil {
                scheduleSystemDefaultRecovery(showTransientError: true, initialError: error)
            } else {
                presentRuntimeError(
                    errorPresentation(kind: .audio, title: "Microphone Became Unavailable", error: error),
                    overlayMessage: "Microphone unavailable"
                )
            }
            return
        }

        appLog.error(
            "Runtime audio failure invalidated capture generation \(handle.generation): \(error.localizedDescription, privacy: .public)"
        )
        activeProcessingTask?.cancel()
        pendingStartTask?.cancel()
        invalidateCaptureOperation(ifCurrent: operationID)
        overlayPanel.dismiss()
        presentRuntimeError(
            errorPresentation(kind: .audio, title: "Microphone Became Unavailable", error: error),
            overlayMessage: "Microphone unavailable"
        )
        Task { @MainActor [weak self] in
            _ = await self?.stopCaptureOnce(handle)
            guard let self, self.selectedInputDeviceID == nil else { return }
            self.scheduleSystemDefaultRecovery(showTransientError: true, initialError: error)
        }
    }

    func retryMicrophone() {
        guard case .runtimeError(let presentation) = state,
              presentation.kind == .audio,
              isOperational,
              !didShutdown
        else { return }

        cancelMicrophoneRecovery()
        refreshInputDevices()
        if let selectedInputDeviceID,
           !availableInputDevices.contains(where: { $0.id == selectedInputDeviceID }) {
            appLog.notice("Clearing unavailable input selection before microphone retry")
        }

        switch prepareAudioForStartup() {
        case .success:
            appLog.notice("Microphone retry validation succeeded")
            updateInputDeviceStatusMessage()
            overlayPanel.dismiss()
            state = .ready
        case .failure(let error):
            appLog.error("Microphone retry validation failed: \(error.localizedDescription, privacy: .public)")
            if selectedInputDeviceID == nil {
                scheduleSystemDefaultRecovery(showTransientError: true, initialError: error)
            } else {
                presentRuntimeError(
                    errorPresentation(kind: .audio, title: "Microphone Still Unavailable", error: error),
                    overlayMessage: "Microphone unavailable"
                )
            }
        }
    }

    private func scheduleSystemDefaultRecovery(
        showTransientError: Bool,
        initialError: AudioEngineError? = nil
    ) {
        guard selectedInputDeviceID == nil,
              isOperational,
              !didShutdown,
              captureOperationID == nil,
              pendingStartTask == nil,
              activeProcessingTask == nil,
              microphoneRecoveryTask == nil
        else { return }

        let recoveryID = UUID()
        microphoneRecoveryID = recoveryID
        if showTransientError, let initialError {
            presentRuntimeError(
                errorPresentation(
                    kind: .audio,
                    title: "Microphone Temporarily Unavailable",
                    error: initialError,
                    defaultRecovery: "OpenWritr is waiting for the macOS system input to become available."
                ),
                overlayMessage: "Reconnecting microphone"
            )
        }
        inputDeviceStatusMessage = "Waiting for the macOS system default input to become available."

        microphoneRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let delays: [Duration] = [
                .milliseconds(250),
                .milliseconds(500),
                .seconds(1),
                .seconds(2),
            ]
            var lastError = initialError

            for delay in delays {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard self.microphoneRecoveryID == recoveryID,
                      self.selectedInputDeviceID == nil,
                      self.isOperational,
                      !self.didShutdown,
                      self.captureOperationID == nil,
                      self.pendingStartTask == nil,
                      self.activeProcessingTask == nil
                else { return }

                self.refreshInputDevices()
                switch self.prepareAudioUsingSystemDefault() {
                case .success:
                    appLog.notice("System Default microphone recovered automatically")
                    self.inputDeviceStatusMessage = "Using System Default. OpenWritr follows the current macOS system input device."
                    self.microphoneRecoveryTask = nil
                    self.microphoneRecoveryID = nil
                    if case .runtimeError(let presentation) = self.state,
                       presentation.kind == .audio {
                        self.overlayPanel.dismiss()
                        self.state = .ready
                    }
                    return
                case .failure(let error):
                    lastError = error
                    appLog.debug("System Default recovery attempt failed: \(error.localizedDescription, privacy: .public)")
                }
            }

            guard self.microphoneRecoveryID == recoveryID,
                  self.captureOperationID == nil,
                  self.pendingStartTask == nil,
                  self.activeProcessingTask == nil
            else { return }
            self.microphoneRecoveryTask = nil
            self.microphoneRecoveryID = nil
            let error = lastError ?? .noDefaultInputDevice
            self.inputDeviceStatusMessage = "The macOS system input is still unavailable: \(error.localizedDescription)"
            self.presentRuntimeError(
                self.errorPresentation(
                    kind: .audio,
                    title: "Microphone Still Unavailable",
                    error: error
                ),
                overlayMessage: "Microphone unavailable"
            )
        }
    }

    private func cancelMicrophoneRecovery() {
        microphoneRecoveryTask?.cancel()
        microphoneRecoveryTask = nil
        microphoneRecoveryID = nil
    }

    func setEnhancedOpenAIAPIKey(_ value: String) {
        enhancedOpenAIAPIKey = value
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = KeychainStore.deleteValue(
                service: Self.keychainService,
                account: Self.enhancementAPIKeyAccount
            )
        } else {
            _ = KeychainStore.saveString(
                value,
                service: Self.keychainService,
                account: Self.enhancementAPIKeyAccount
            )
        }
        UserDefaults.standard.removeObject(forKey: "enhancedOpenAIAPIKey")
    }

    func setSelectedOpenAIModel(_ value: String) {
        selectedOpenAIModel = value
        UserDefaults.standard.set(value, forKey: "selectedOpenAIModel")
        UserDefaults.standard.removeObject(forKey: "enhancedOpenAIModelOverride")
    }

    func refreshOpenAIModels() async {
        guard !isRefreshingOpenAIModels else { return }

        isRefreshingOpenAIModels = true
        openAIModelRefreshMessage = nil
        defer { isRefreshingOpenAIModels = false }

        guard let url = openAIModelsURL(from: enhancedOpenAIBaseURL) else {
            openAIModelRefreshMessage = "Base URL is invalid."
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        if let apiKey = resolvedEnhancedAPIKey(), !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                openAIModelRefreshMessage = "Models endpoint returned an invalid response."
                return
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                openAIModelRefreshMessage = "Models endpoint failed with HTTP \(httpResponse.statusCode)."
                return
            }

            let decoded = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
            let models = Array(Set(decoded.data.map(\ .id))).sorted()
            availableOpenAIModels = models

            if models.isEmpty {
                openAIModelRefreshMessage = "No models returned by the endpoint."
                return
            }

            openAIModelRefreshMessage = "Loaded \(models.count) models."
        } catch {
            openAIModelRefreshMessage = "Failed to refresh models: \(error.localizedDescription)"
        }
    }

    func setEnhancementPrompt(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed == modelDefaultEnhancementPrompt {
            customEnhancementPrompts.removeValue(forKey: enhancementPromptTargetKey)
        } else {
            customEnhancementPrompts[enhancementPromptTargetKey] = trimmed
        }
        persistCustomEnhancementPrompts()
    }

    func resetEnhancementPrompt() {
        customEnhancementPrompts.removeValue(forKey: enhancementPromptTargetKey)
        persistCustomEnhancementPrompts()
    }

    func hasCustomEnhancementPrompt(
        provider: EnhancedProvider,
        model: EnhancedModel,
        openAIModel: String
    ) -> Bool {
        customEnhancementPrompts[
            GrammarEnhancer.promptTargetKey(
                provider: provider,
                model: model,
                openAIModel: openAIModel
            )
        ] != nil
    }

    func copyCurrentEnhancementPrompt(
        to provider: EnhancedProvider,
        model: EnhancedModel,
        openAIModel: String
    ) {
        let key = GrammarEnhancer.promptTargetKey(
            provider: provider,
            model: model,
            openAIModel: openAIModel
        )
        customEnhancementPrompts[key] = enhancementPrompt
        persistCustomEnhancementPrompts()
    }

    private func restoreCustomEnhancementPrompts(defaults: UserDefaults) {
        if let data = defaults.data(forKey: Self.customPromptsPreferenceKey) {
            if let store = try? JSONDecoder().decode(CustomPromptStore.self, from: data),
               store.version <= Self.customPromptsStoreVersion {
                customEnhancementPrompts = store.prompts
                if store.version < Self.customPromptsStoreVersion {
                    persistCustomEnhancementPrompts()
                }
            } else if let legacyDictionary = try? JSONDecoder().decode(
                [String: String].self,
                from: data
            ) {
                customEnhancementPrompts = legacyDictionary
                persistCustomEnhancementPrompts()
            }
        }

        guard let legacyPrompt = defaults.string(forKey: "enhancementPrompt") else { return }
        let trimmed = legacyPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let migratedPrompt = GrammarEnhancer.migrateLegacyCleanupPrompt(
            trimmed,
            provider: enhancedProvider,
            model: enhancedModel,
            openAIModel: selectedOpenAIModel
        )
        if !trimmed.isEmpty,
           migratedPrompt != modelDefaultEnhancementPrompt,
           customEnhancementPrompts[enhancementPromptTargetKey] == nil {
            customEnhancementPrompts[enhancementPromptTargetKey] = migratedPrompt
            persistCustomEnhancementPrompts()
        }
        defaults.removeObject(forKey: "enhancementPrompt")
    }

    private func persistCustomEnhancementPrompts() {
        let store = CustomPromptStore(
            version: Self.customPromptsStoreVersion,
            prompts: customEnhancementPrompts
        )
        guard let data = try? JSONEncoder().encode(store) else {
            appLog.error("Failed to encode custom enhancement prompts")
            return
        }
        UserDefaults.standard.set(data, forKey: Self.customPromptsPreferenceKey)
    }


    func toggleLaunchAtLogin() {
        guard case .ready = state, isOperational else { return }

        do {
            if launchAtLogin {
                try SMAppService.mainApp.unregister()
                launchAtLogin = false
            } else {
                try SMAppService.mainApp.register()
                launchAtLogin = true
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            appLog.error(
                "Launch-at-login update failed: \(error.localizedDescription, privacy: .public)"
            )
            if isOperational {
                presentRuntimeError(
                    errorPresentation(
                        kind: .transcription,
                        title: "Launch at Login Could Not Be Changed",
                        error: error,
                        defaultRecovery: "Check Login Items in System Settings, then try again."
                    ),
                    overlayMessage: "Setting could not be changed"
                )
            }
        }
    }

    private func startProcessingStoppedRecording(triggerMode: RecordingShortcutMode) {
        guard isOperational,
              !didShutdown,
              let operationID = captureOperationID
        else { return }

        captureTriggerMode = resolvedRecordingMode(for: triggerMode)
        if case .preparingMicrophone = state {
            releaseRequested = true
            appLog.debug("Retained release for pending microphone operation")
            return
        }

        guard case .listening = state,
              let handle = captureHandle,
              handle.generation == captureHandle?.generation,
              activeProcessingTask == nil
        else { return }

        activeProcessingOperationID = operationID
        activeProcessingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.clearActiveProcessingTask(ifCurrent: operationID)
            }
            await self.stopListeningAndTranscribe(
                operationID: operationID,
                handle: handle,
                triggerMode: self.captureTriggerMode ?? triggerMode,
                expectedState: .listening
            )
        }
    }

    private func clearActiveProcessingTask(ifCurrent operationID: UUID) {
        guard activeProcessingOperationID == operationID else { return }
        activeProcessingTask = nil
        activeProcessingOperationID = nil
    }

    private func resolvedRecordingMode(
        for shortcutMode: RecordingShortcutMode
    ) -> RecordingShortcutMode {
        guard enhancedModeEnabled else { return .normal }
        if alwaysEnhancedEnabled {
            return shortcutMode == .enhanced ? .normal : .enhanced
        }
        return shortcutMode
    }

    private func updateRecordingMode(shortcutMode: RecordingShortcutMode) {
        guard captureOperationID != nil else { return }
        let mode = resolvedRecordingMode(for: shortcutMode)
        captureTriggerMode = mode
        if case .listening = state {
            overlayPanel.show(state: .listening(enhanced: mode == .enhanced))
        }
    }

    func startListening(triggerMode: RecordingShortcutMode = .normal) {
        guard state.isReady || isTransientErrorState,
              isOperational,
              !didShutdown,
              activeProcessingTask == nil,
              pendingStartTask == nil,
              captureOperationID == nil
        else { return }

        cancelTransientErrorDismissal()
        cancelMicrophoneRecovery()
        recoverableRawTranscription = nil
        let operationID = UUID()
        captureOperationID = operationID
        captureHandle = nil
        captureTriggerMode = resolvedRecordingMode(for: triggerMode)
        releaseRequested = false
        state = .preparingMicrophone
        appLog.debug("Starting asynchronous microphone preparation")

        pendingStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.completeCaptureStart(operationID: operationID)
        }
    }

    func stopListeningAndTranscribe(triggerMode: RecordingShortcutMode = .normal) async {
        guard case .listening = state,
              isOperational,
              !didShutdown,
              let operationID = captureOperationID,
              let handle = captureHandle
        else { return }
        await stopListeningAndTranscribe(
            operationID: operationID,
            handle: handle,
            triggerMode: captureTriggerMode ?? triggerMode,
            expectedState: .listening
        )
    }

    private enum CaptureStopExpectedState {
        case preparingMicrophone
        case listening
    }

    private func completeCaptureStart(operationID: UUID) async {
        let result = await audioEngine.startCapture()

        switch result {
        case .failure(let error):
            let operationIsCurrent = captureOperationID == operationID
            clearPendingStartTask(ifCurrent: operationID)
            guard operationIsCurrent else { return }
            invalidateCaptureOperation(ifCurrent: operationID)

            if case .captureCancelled = error,
               didShutdown || Task.isCancelled {
                appLog.debug("Ignoring cancelled microphone start for invalidated operation")
                return
            }
            guard isOperational,
                  !didShutdown,
                  !Task.isCancelled,
                  case .preparingMicrophone = state
            else { return }
            appLog.error("Microphone start failed: \(error.localizedDescription, privacy: .public)")
            if selectedInputDeviceID == nil {
                scheduleSystemDefaultRecovery(showTransientError: true, initialError: error)
            } else {
                presentRuntimeError(
                    errorPresentation(kind: .audio, title: "Microphone Preparation Failed", error: error),
                    overlayMessage: "Microphone unavailable"
                )
            }

        case .success(let handle):
            guard captureOperationID == operationID,
                  isOperational,
                  !didShutdown,
                  !Task.isCancelled,
                  case .preparingMicrophone = state
            else {
                clearPendingStartTask(ifCurrent: operationID)
                appLog.debug("Stopping stale successful capture generation \(handle.generation)")
                _ = await stopCaptureOnce(handle)
                return
            }

            captureHandle = handle
            guard captureOperationID == operationID,
                  captureHandle?.generation == handle.generation,
                  isOperational,
                  !didShutdown,
                  !Task.isCancelled,
                  case .preparingMicrophone = state
            else {
                clearPendingStartTask(ifCurrent: operationID)
                _ = await stopCaptureOnce(handle)
                return
            }

            if releaseRequested {
                await stopListeningAndTranscribe(
                    operationID: operationID,
                    handle: handle,
                    triggerMode: captureTriggerMode ?? .normal,
                    expectedState: .preparingMicrophone
                )
                clearPendingStartTask(ifCurrent: operationID)
                return
            }

            clearPendingStartTask(ifCurrent: operationID)
            state = .listening
            overlayPanel.show(
                state: .listening(
                    enhanced: captureTriggerMode == .enhanced
                )
            )
            if soundEnabled {
                soundManager.playStartSound()
            }
        }
    }

    private func stopListeningAndTranscribe(
        operationID: UUID,
        handle: CaptureHandle,
        triggerMode: RecordingShortcutMode,
        expectedState: CaptureStopExpectedState
    ) async {
        guard captureOperationIsCurrent(
            operationID: operationID,
            handle: handle,
            expectedState: expectedState
        ) else { return }

        await audioEngine.waitForCaptureToSettle(
            handle: handle,
            idleWindow: captureDrainIdleDuration,
            maxWait: captureDrainTimeout,
            pollInterval: .milliseconds(10)
        )
        guard captureOperationIsCurrent(
            operationID: operationID,
            handle: handle,
            expectedState: expectedState
        ) else { return }

        let samples = await stopCaptureOnce(handle)
        guard captureOperationIsCurrent(
            operationID: operationID,
            handle: handle,
            expectedState: expectedState
        ) else { return }
        guard let samples else {
            appLog.error("Capture generation \(handle.generation) stopped without samples")
            invalidateCaptureOperation(ifCurrent: operationID)
            presentRuntimeError(
                AppErrorPresentation(
                    kind: .audio,
                    title: "Microphone Capture Failed",
                    message: "The active microphone capture became unavailable.",
                    recoverySuggestion: "Reconnect the input device, then retry the microphone."
                ),
                overlayMessage: "Microphone unavailable"
            )
            return
        }

        state = .transcribing
        overlayPanel.show(state: .transcribing)
        if soundEnabled {
            soundManager.playStopSound()
        }

        let minSamples = Int(16_000 * 0.3)
        guard samples.count > minSamples else {
            returnToReady(operationID: operationID)
            return
        }

        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        guard rms > 0.005 else {
            returnToReady(operationID: operationID)
            return
        }

        do {
            let transcriptionSamples = TranscriptionInput.paddedIfNeeded(samples)
            let text = try await transcriptionManager.transcribe(samples: transcriptionSamples)
            guard captureOperationIsCurrent(
                operationID: operationID,
                handle: handle,
                expectedState: .transcribing
            ) else { return }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                returnToReady(operationID: operationID)
                return
            }

            if triggerMode == .enhanced {
                state = .enhancing
                overlayPanel.show(state: .enhancing)
                await enhanceAndComplete(
                    rawText: trimmed,
                    captureOperation: (operationID, handle)
                )
            } else {
                await finishSuccessfulOutput(
                    trimmed,
                    rawText: nil,
                    wasEnhanced: false,
                    captureOperation: (operationID, handle)
                )
            }
        } catch {
            guard captureOperationIsCurrent(
                operationID: operationID,
                handle: handle,
                expectedState: .transcribing
            ) else { return }
            appLog.error(
                "Transcription failed for \(samples.count) captured samples: \(error.localizedDescription, privacy: .public)"
            )
            clearCaptureOperation(ifCurrent: operationID)
            presentRuntimeError(
                errorPresentation(
                    kind: .transcription,
                    title: "Transcription Failed",
                    error: error,
                    defaultRecovery: "Dismiss this error, then try recording again."
                ),
                overlayMessage: "Transcription failed"
            )
        }
    }

    private func enhanceAndComplete(
        rawText: String,
        captureOperation: (UUID, CaptureHandle)? = nil
    ) async {
        let result = await grammarEnhancer.enhance(
            text: rawText,
            model: enhancedModel,
            provider: enhancedProvider,
            openAIConfiguration: currentOpenAIConfiguration(),
            prompt: enhancementPrompt
        )
        if let (operationID, handle) = captureOperation {
            guard captureOperationIsCurrent(
                operationID: operationID,
                handle: handle,
                expectedState: .enhancing
            ) else { return }
        } else {
            guard case .enhancing = state, isOperational, !didShutdown else { return }
        }

        lastEnhancementModel = result.effectiveModel
        lastEnhancementProvider = result.providerDisplayName
        lastEnhancementWarning = result.warning
        guard result.didSucceed else {
            if let (operationID, _) = captureOperation {
                clearCaptureOperation(ifCurrent: operationID)
            }
            presentRuntimeError(
                AppErrorPresentation(
                    kind: .enhancement,
                    title: "Enhancement Failed",
                    message: result.warning ?? "The enhancement provider did not return a result.",
                    recoverySuggestion: "Retry enhancement or use the raw transcript."
                ),
                overlayMessage: "Enhancement failed",
                recoverableRawTranscription: rawText
            )
            return
        }

        let output = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            recoverableRawTranscription = nil
            if let (operationID, _) = captureOperation {
                returnToReady(operationID: operationID)
            } else {
                returnToReady()
            }
            return
        }
        await finishSuccessfulOutput(
            output,
            rawText: rawText,
            wasEnhanced: true,
            captureOperation: captureOperation
        )
    }

    private func finishSuccessfulOutput(
        _ text: String,
        rawText: String?,
        wasEnhanced: Bool,
        captureOperation: (UUID, CaptureHandle)? = nil
    ) async {
        recoverableRawTranscription = nil
        lastTranscription = text
        lastRawTranscription = rawText ?? ""
        lastWasEnhanced = wasEnhanced

        if autoPasteEnabled, pasteManager.pasteText(text) == .cancelled {
            if let (operationID, _) = captureOperation {
                clearCaptureOperation(ifCurrent: operationID)
            }
            presentPasteCancelledError()
            return
        }

        overlayPanel.show(state: .done)
        do {
            try await Task.sleep(for: doneDisplayDuration)
        } catch is CancellationError {
            return
        } catch {
            appLog.error("Done overlay delay failed: \(error.localizedDescription, privacy: .public)")
        }

        guard isOperational, !didShutdown else { return }
        if let (operationID, handle) = captureOperation {
            guard captureOperationIsCurrent(
                operationID: operationID,
                handle: handle,
                expectedState: wasEnhanced ? .enhancing : .transcribing
            ) else { return }
        }
        if wasEnhanced {
            guard case .enhancing = state else { return }
        } else {
            guard case .transcribing = state else { return }
        }
        overlayPanel.dismiss()
        if let (operationID, _) = captureOperation {
            clearCaptureOperation(ifCurrent: operationID)
        }
        state = .ready
    }

    private func presentPasteCancelledError() {
        presentRuntimeError(
            AppErrorPresentation(
                kind: .paste,
                title: "Paste Cancelled",
                message: "OpenWritr could not preserve the clipboard, so the transcript was not pasted.",
                recoverySuggestion: "Replace or clear the clipboard contents, then record again."
            ),
            overlayMessage: "Clipboard could not be preserved; paste cancelled"
        )
    }

    private func returnToReady(operationID: UUID? = nil) {
        guard isOperational else { return }
        if let operationID {
            guard captureOperationID == operationID else { return }
            clearCaptureOperation(ifCurrent: operationID)
        }
        overlayPanel.dismiss()
        state = .ready
    }

    private enum CaptureOperationExpectedState {
        case preparingMicrophone
        case listening
        case transcribing
        case enhancing
    }

    private func captureOperationIsCurrent(
        operationID: UUID,
        handle: CaptureHandle,
        expectedState: CaptureOperationExpectedState
    ) -> Bool {
        guard captureOperationID == operationID,
              captureHandle?.generation == handle.generation,
              isOperational,
              !didShutdown,
              !Task.isCancelled
        else { return false }

        switch (expectedState, state) {
        case (.preparingMicrophone, .preparingMicrophone),
             (.listening, .listening),
             (.transcribing, .transcribing),
             (.enhancing, .enhancing):
            return true
        default:
            return false
        }
    }

    private func captureOperationIsCurrent(
        operationID: UUID,
        handle: CaptureHandle,
        expectedState: CaptureStopExpectedState
    ) -> Bool {
        switch expectedState {
        case .preparingMicrophone:
            return captureOperationIsCurrent(
                operationID: operationID,
                handle: handle,
                expectedState: CaptureOperationExpectedState.preparingMicrophone
            )
        case .listening:
            return captureOperationIsCurrent(
                operationID: operationID,
                handle: handle,
                expectedState: CaptureOperationExpectedState.listening
            )
        }
    }

    private func stopCaptureOnce(_ handle: CaptureHandle) async -> [Float]? {
        guard stoppedCaptureGenerations.insert(handle.generation).inserted else {
            return nil
        }
        return await audioEngine.stopCapture(handle: handle)
    }

    private func clearPendingStartTask(ifCurrent operationID: UUID) {
        guard captureOperationID == operationID else { return }
        pendingStartTask = nil
    }

    private func clearCaptureOperation(ifCurrent operationID: UUID) {
        guard captureOperationID == operationID else { return }
        captureOperationID = nil
        captureHandle = nil
        captureTriggerMode = nil
        releaseRequested = false
        pendingStartTask = nil
        clearActiveProcessingTask(ifCurrent: operationID)
    }

    private func invalidateCaptureOperation(ifCurrent operationID: UUID? = nil) {
        if let operationID, captureOperationID != operationID { return }
        if let handle = captureHandle {
            appLog.debug("Invalidating capture generation \(handle.generation)")
        }
        captureOperationID = nil
        captureHandle = nil
        captureTriggerMode = nil
        releaseRequested = false
        pendingStartTask = nil
        activeProcessingTask = nil
        activeProcessingOperationID = nil
    }


    private func currentOpenAIConfiguration() -> GrammarEnhancer.OpenAIConfiguration {
        .init(baseURL: enhancedOpenAIBaseURL, apiKey: resolvedEnhancedAPIKey(), modelOverride: selectedOpenAIModel)
    }

    private func resolvedEnhancedAPIKey() -> String? {
        let trimmed = enhancedOpenAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? EnhancedProvider.defaultOpenAIAPIKey : trimmed
    }

    private func updateInputDeviceStatusMessage(for device: AudioInputDevice? = nil) {
        if let device {
            inputDeviceStatusMessage = "Selected input: \(device.name). OpenWritr records directly from this device without changing the macOS system input."
        } else if let selectedID = selectedInputDeviceID, let device = availableInputDevices.first(where: { $0.id == selectedID }) {
            inputDeviceStatusMessage = "Selected input: \(device.name). OpenWritr records directly from this device without changing the macOS system input."
        } else {
            inputDeviceStatusMessage = "Using System Default. OpenWritr follows the current macOS system input device."
        }
    }

    private struct OpenAIModelsResponse: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    private func openAIModelsURL(from baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else { return nil }
        let pathParts = components.path.split(separator: "/").map(String.init)
        if pathParts.last == "models" { return components.url }
        var updatedPathParts = pathParts
        if updatedPathParts.last != "v1" { updatedPathParts.append("v1") }
        updatedPathParts.append("models")
        components.path = "/" + updatedPathParts.joined(separator: "/")
        return components.url
    }

    func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        isOperational = false

        grammarEnhancer.cancelActiveEnhancement()
        cancelMicrophoneRecovery()
        pendingStartTask?.cancel()
        activeProcessingTask?.cancel()
        invalidateCaptureOperation()
        hotkeyManager.stop()
        pasteManager.flushPendingRestore()
        overlayPanel.dismiss()
        updateManager.stopAutomaticChecks()

        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }

        audioEngine.onDevicesChanged = nil
        audioEngine.onFailure = nil
        audioEngine.onAudioLevel = nil
        hotkeyManager.onRecordingStarted = nil
        hotkeyManager.onRecordingModeChanged = nil
        hotkeyManager.onRecordingStopped = nil

        _ = audioEngine.shutdown()
    }
}

struct OpenWritrApp: App {
    @State private var viewModel = AppViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
        } label: {
            menuBarIcon
                .task { await viewModel.setup() }
        }

        Settings {
            SettingsView(viewModel: viewModel)
        }

        Window("About OpenWritr", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
    }

    private var menuBarIcon: some View {
        Group {
            switch viewModel.state {
            case .preparingMicrophone:
                Image(systemName: "mic.badge.plus")
            case .listening:
                Image(systemName: "mic.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.red)
            case .transcribing:
                Image(systemName: "ellipsis.circle")
            case .enhancing:
                Image(systemName: "sparkles")
            case .loading:
                Image(systemName: "circle.dashed")
            case .downloading:
                Image(systemName: "arrow.down.circle")
            case .initializationError, .runtimeError:
                Image(systemName: "exclamationmark.triangle")
            default:
                Image(systemName: "mic")
            }
        }
    }
}

/// Process entry point. Internal command-line modes exercise production code
/// without starting the menu bar app or requesting interactive permissions.
@main
enum OpenWritrEntry {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--self-test") {
            SelfTest.run(arguments: arguments)
        } else if arguments.contains("--render-ui-snapshots") {
            UISnapshotRenderer.run(arguments: arguments)
        } else {
            OpenWritrApp.main()
        }
    }
}
