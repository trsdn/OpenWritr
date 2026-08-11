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
}

@MainActor
@Observable
final class AppViewModel {
    private static let keychainService = "com.openwritr.app"
    private static let enhancementAPIKeyAccount = "enhancedOpenAIAPIKey"
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
    var enhancedProvider: EnhancedProvider = .copilot
    var enhancedModel: EnhancedModel = .gpt4_1
    var enhancedOpenAIBaseURL: String = EnhancedProvider.defaultOpenAIBaseURL
    var enhancedOpenAIAPIKey: String = ""
    var selectedOpenAIModel: String = EnhancedProvider.defaultOpenAIModelOverride
    var availableOpenAIModels: [String] = []
    var isRefreshingOpenAIModels = false
    var openAIModelRefreshMessage: String?
    var enhancementPrompt = GrammarEnhancer.defaultCleanupPrompt

    let transcriptionManager = TranscriptionManager()
    let grammarEnhancer: GrammarEnhancer = .init()
    let audioEngine = AudioEngine()
    let hotkeyManager = HotkeyManager()
    let pasteManager = PasteManager()
    let overlayPanel = OverlayPanel()
    let soundManager = SoundManager()
    let permissionsManager = PermissionsManager()

    private let captureDrainIdleDuration: Duration = .milliseconds(70)
    private let captureDrainTimeout: Duration = .milliseconds(350)
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
    @ObservationIgnored private var stoppedCaptureGenerations: Set<UInt64> = []
    @ObservationIgnored private var activeProcessingTask: Task<Void, Never>?
    @ObservationIgnored private var activeProcessingOperationID: UUID?
    @ObservationIgnored private var initializationErrorProcessingTask: Task<Void, Never>?
    @ObservationIgnored private var initializationErrorProcessingOperationID: UUID?
    @ObservationIgnored private var initializationRetryID: UUID?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?

    var displayedOpenAIModels: [String] {
        var models = availableOpenAIModels
        let selected = selectedOpenAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty, !models.contains(selected) { models.insert(selected, at: 0) }
        return models
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
    }

    private func configureIfNeeded() {
        guard !didConfigure else { return }
        didConfigure = true

        restorePreferences()

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
        hotkeyManager.onRecordingStarted = { [weak self] mode in
            Task { @MainActor [weak self] in
                self?.startListening(triggerMode: mode)
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
        if let raw = defaults.string(forKey: "enhancedProvider"), let provider = EnhancedProvider(rawValue: raw) {
            enhancedProvider = provider
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
        if let savedPrompt = defaults.string(forKey: "enhancementPrompt"), !savedPrompt.isEmpty {
            enhancementPrompt = savedPrompt
        }
        if let raw = defaults.string(forKey: "enhancedModel"),
           let model = EnhancedModel(rawValue: raw) {
            enhancedModel = model
        }
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
    }

    private func transitionToErrorState(_ errorState: AppState) {
        state = errorState
    }

    func dismissRuntimeError() {
        guard case .runtimeError(let error) = state, isOperational else { return }
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
        if autoPasteEnabled {
            pasteManager.pasteText(rawText)
        }
        overlayPanel.dismiss()
        state = .ready
    }

    func savePreference(_ key: String, value: Any) {
        UserDefaults.standard.set(value, forKey: key)
    }

    func setHotkey(_ choice: HotkeyChoice) {
        hotkeyChoice = choice
        hotkeyManager.activeFlag = choice.flag
        hotkeyManager.activeKeyCode = choice.keyCode
        UserDefaults.standard.set(choice.rawValue, forKey: "hotkeyChoice")
    }

    func refreshInputDevices() {
        availableInputDevices = AudioEngine.availableInputDevices()
    }

    func setInputDevice(_ device: AudioInputDevice?) {
        guard canChangeInputDevice else {
            appLog.notice("Ignoring input device change while microphone work is active")
            return
        }

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
                presentRuntimeError(
                    errorPresentation(kind: .audio, title: "Microphone Selection Failed", error: error),
                    overlayMessage: "Microphone unavailable"
                )
            }
        case .failure(let error):
            if device == nil {
                clearSelectedInputDevice()
                inputDeviceStatusMessage = "The previous macOS system input could not be restored."
            }
            appLog.error("Input device selection failed: \(error.localizedDescription, privacy: .public)")
            presentRuntimeError(
                errorPresentation(kind: .audio, title: "Microphone Selection Failed", error: error),
                overlayMessage: "Microphone change failed"
            )
        }
    }

    private func handleInputDevicesChanged() {
        refreshInputDevices()
        guard let selectedInputDeviceID,
              !availableInputDevices.contains(where: { $0.id == selectedInputDeviceID })
        else { return }

        clearSelectedInputDevice()
        if case .runtimeError(let presentation) = state,
           presentation.kind == .audio {
            appLog.error("The selected input device disappeared and default restoration failed")
            return
        }
        appLog.notice("The selected input device disappeared; using the restored system default")
        inputDeviceStatusMessage = "Selected input device is no longer available. OpenWritr is following the macOS system default input."
    }

    private func clearSelectedInputDevice() {
        selectedInputDeviceID = nil
        UserDefaults.standard.removeObject(forKey: "inputDeviceUID")
    }

    private func handleAudioFailure(_ error: AudioEngineError) {
        guard !didShutdown, isOperational else { return }

        guard let operationID = captureOperationID,
              let handle = captureHandle
        else {
            appLog.error("Runtime audio failure: \(error.localizedDescription, privacy: .public)")
            inputDeviceStatusMessage = "The microphone configuration failed: \(error.localizedDescription)"
            presentRuntimeError(
                errorPresentation(kind: .audio, title: "Microphone Became Unavailable", error: error),
                overlayMessage: "Microphone unavailable"
            )
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
        }
    }

    func retryMicrophone() {
        guard case .runtimeError(let presentation) = state,
              presentation.kind == .audio,
              isOperational,
              !didShutdown
        else { return }

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
            presentRuntimeError(
                errorPresentation(kind: .audio, title: "Microphone Still Unavailable", error: error),
                overlayMessage: "Microphone unavailable"
            )
        }
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

            if !models.contains(selectedOpenAIModel) {
                setSelectedOpenAIModel(models[0])
            }
            openAIModelRefreshMessage = "Loaded \(models.count) models."
        } catch {
            openAIModelRefreshMessage = "Failed to refresh models: \(error.localizedDescription)"
        }
    }

    func setEnhancementPrompt(_ value: String) {
        enhancementPrompt = value
        UserDefaults.standard.set(value, forKey: "enhancementPrompt")
    }

    func resetEnhancementPrompt() {
        setEnhancementPrompt(GrammarEnhancer.defaultCleanupPrompt)
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

    func startListening(triggerMode: RecordingShortcutMode = .normal) {
        guard case .ready = state,
              isOperational,
              !didShutdown,
              activeProcessingTask == nil,
              pendingStartTask == nil,
              captureOperationID == nil
        else { return }

        recoverableRawTranscription = nil
        let operationID = UUID()
        captureOperationID = operationID
        captureHandle = nil
        captureTriggerMode = triggerMode
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
            presentRuntimeError(
                errorPresentation(kind: .audio, title: "Microphone Preparation Failed", error: error),
                overlayMessage: "Microphone unavailable"
            )

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
            overlayPanel.show(state: .listening)
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
            let text = try await transcriptionManager.transcribe(samples: samples)
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

            if enhancedModeEnabled && triggerMode == .enhanced {
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

        if autoPasteEnabled {
            pasteManager.pasteText(text)
        }

        overlayPanel.show(state: .done)
        do {
            try await Task.sleep(for: .milliseconds(600))
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
            inputDeviceStatusMessage = "Selected input: \(device.name). OpenWritr switches the macOS system input to this device while it is selected."
        } else if let selectedID = selectedInputDeviceID, let device = availableInputDevices.first(where: { $0.id == selectedID }) {
            inputDeviceStatusMessage = "Selected input: \(device.name). OpenWritr switches the macOS system input to this device while it is selected."
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
        pendingStartTask?.cancel()
        activeProcessingTask?.cancel()
        invalidateCaptureOperation()
        hotkeyManager.stop()
        pasteManager.flushPendingRestore()
        overlayPanel.dismiss()

        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }

        audioEngine.onDevicesChanged = nil
        audioEngine.onFailure = nil
        hotkeyManager.onRecordingStarted = nil
        hotkeyManager.onRecordingStopped = nil

        _ = audioEngine.shutdown()
    }
}

@main
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
