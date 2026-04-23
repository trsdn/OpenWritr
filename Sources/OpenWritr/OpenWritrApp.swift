import SwiftUI
import Combine
import CoreAudio
import ServiceManagement
import os.log
import Foundation

private let appLog = Logger(subsystem: "com.openwritr.app", category: "AppViewModel")

enum AppState: Sendable {
    case idle
    case loading
    case downloading(progress: Double)
    case ready
    case listening
    case transcribing
    case enhancing
    case error(String)
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
    var isRefreshingOpenAIModels: Bool = false
    var openAIModelRefreshMessage: String?
    var enhancementPrompt: String = GrammarEnhancer.defaultCleanupPrompt

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
    private var isFinishingCapture = false

    var displayedOpenAIModels: [String] {
        var models = availableOpenAIModels
        let selected = selectedOpenAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty, !models.contains(selected) {
            models.insert(selected, at: 0)
        }
        return models
    }

    func setup() async {
        // Restore preferences
        let d = UserDefaults.standard
        if d.object(forKey: "soundEnabled") != nil { soundEnabled = d.bool(forKey: "soundEnabled") }
        if d.object(forKey: "autoPasteEnabled") != nil { autoPasteEnabled = d.bool(forKey: "autoPasteEnabled") }
        if let raw = d.string(forKey: "hotkeyChoice"), let c = HotkeyChoice(rawValue: raw) {
            hotkeyChoice = c
        }
        if d.object(forKey: "enhancedModeEnabled") != nil { enhancedModeEnabled = d.bool(forKey: "enhancedModeEnabled") }
        if let providerRaw = d.string(forKey: "enhancedProvider"), let provider = EnhancedProvider(rawValue: providerRaw) {
            enhancedProvider = provider
        }
        if let modelRaw = d.string(forKey: "enhancedModel"), let m = EnhancedModel(rawValue: modelRaw) {
            enhancedModel = m
        }
        if let baseURL = d.string(forKey: "enhancedOpenAIBaseURL"), !baseURL.isEmpty {
            enhancedOpenAIBaseURL = baseURL
        }
        if let apiKey = KeychainStore.loadString(
            service: Self.keychainService,
            account: Self.enhancementAPIKeyAccount
        ) {
            enhancedOpenAIAPIKey = apiKey
        } else if let apiKey = d.string(forKey: "enhancedOpenAIAPIKey") {
            enhancedOpenAIAPIKey = apiKey
            _ = KeychainStore.saveString(
                apiKey,
                service: Self.keychainService,
                account: Self.enhancementAPIKeyAccount
            )
            d.removeObject(forKey: "enhancedOpenAIAPIKey")
        }
        if let selectedModel = d.string(forKey: "selectedOpenAIModel"), !selectedModel.isEmpty {
            selectedOpenAIModel = selectedModel
        } else if let modelOverride = d.string(forKey: "enhancedOpenAIModelOverride"), !modelOverride.isEmpty {
            selectedOpenAIModel = modelOverride
            d.removeObject(forKey: "enhancedOpenAIModelOverride")
        }
        if let savedPrompt = d.string(forKey: "enhancementPrompt"), !savedPrompt.isEmpty {
            enhancementPrompt = savedPrompt
        }
        if d.object(forKey: "debugModeEnabled") != nil { debugModeEnabled = d.bool(forKey: "debugModeEnabled") }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        hotkeyManager.activeFlag = hotkeyChoice.flag

        audioEngine.onDevicesChanged = { [weak self] in
            Task { @MainActor in
                self?.refreshInputDevices()
                // If selected device disappeared, fall back to system default
                if let selectedID = self?.selectedInputDeviceID,
                   !(self?.availableInputDevices.contains { $0.id == selectedID } ?? false) {
                    self?.selectedInputDeviceID = nil
                    UserDefaults.standard.removeObject(forKey: "inputDeviceUID")
                    self?.inputDeviceStatusMessage = "Selected input device is no longer available. OpenWritr is following the macOS system default input."
                } else {
                    self?.updateInputDeviceStatusMessage()
                }
            }
        }

        refreshInputDevices()
        if let savedUID = d.string(forKey: "inputDeviceUID") {
            let match = availableInputDevices.first { $0.uid == savedUID }
            if let match {
                selectedInputDeviceID = match.id
                audioEngine.setInputDevice(match.id)
            }
        }
        updateInputDeviceStatusMessage()
        audioEngine.prepare()
        permissionsManager.requestAccessibilityAccess()

        state = .loading
        do {
            try await transcriptionManager.loadModels { [weak self] progress in
                Task { @MainActor in
                    if progress < 1.0 {
                        self?.state = .downloading(progress: progress)
                    }
                }
            }
            state = .ready

            hotkeyManager.onRecordingStarted = { [weak self] mode in
                Task { @MainActor in
                    self?.startListening(triggerMode: mode)
                }
            }
            hotkeyManager.onRecordingStopped = { [weak self] mode in
                Task { @MainActor in
                    await self?.stopListeningAndTranscribe(triggerMode: mode)
                }
            }
            hotkeyManager.start()
        } catch {
            state = .error(error.localizedDescription)
        }
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
        selectedInputDeviceID = device?.id
        if let device {
            UserDefaults.standard.set(device.uid, forKey: "inputDeviceUID")
        } else {
            UserDefaults.standard.removeObject(forKey: "inputDeviceUID")
        }
        audioEngine.setInputDevice(device?.id)
        updateInputDeviceStatusMessage(for: device)
        audioEngine.prepare()
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
        }
    }

    func startListening(triggerMode: RecordingShortcutMode = .normal) {
        guard case .ready = state else { return }

        refreshInputDevices()
        if let selectedID = selectedInputDeviceID,
           let selectedDevice = availableInputDevices.first(where: { $0.id == selectedID }) {
            appLog.info("Using selected input device: \(selectedDevice.name, privacy: .public) [\(selectedDevice.uid, privacy: .public)]")
        } else {
            appLog.info("Using current system default input device")
        }
        updateInputDeviceStatusMessage()
        audioEngine.restartForCapture()
        appLog.info("startListening mode=\(triggerMode == .enhanced ? "enhanced" : "normal", privacy: .public)")
        appLog.info("startListening state=ready availableInputs=\(self.availableInputDevices.count)")

        state = .listening
        audioEngine.startCapture()
        overlayPanel.show(state: .listening)
        if soundEnabled {
            soundManager.playStartSound()
        }
    }

    func stopListeningAndTranscribe(triggerMode: RecordingShortcutMode = .normal) async {
        guard case .listening = state, !isFinishingCapture else { return }
        isFinishingCapture = true
        defer { isFinishingCapture = false }

        await audioEngine.waitForCaptureToSettle(
            idleWindow: captureDrainIdleDuration,
            maxWait: captureDrainTimeout
        )
        let samples = audioEngine.stopCapture()
        state = .transcribing
        overlayPanel.show(state: .transcribing)
        if soundEnabled {
            soundManager.playStopSound()
        }

        let minSamples = Int(16_000 * 0.3)
        appLog.info("stopListeningAndTranscribe samples=\(samples.count) minSamples=\(minSamples)")
        guard samples.count > minSamples else {
            appLog.warning("Capture rejected: too few samples")
            state = .ready
            overlayPanel.dismiss()
            return
        }

        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        appLog.info("capture rms=\(rms)")
        guard rms > 0.0015 else {
            appLog.warning("Capture rejected: RMS below threshold")
            state = .ready
            overlayPanel.dismiss()
            return
        }

        do {
            let text = try await transcriptionManager.transcribe(samples: samples)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            appLog.info("transcription length=\(trimmed.count)")
            guard !trimmed.isEmpty else {
                appLog.warning("Transcription result was empty")
                state = .ready
                overlayPanel.dismiss()
                return
            }
            var finalText = trimmed
            lastRawTranscription = trimmed
            lastEnhancementWarning = nil
            lastEnhancementModel = ""
            lastEnhancementProvider = ""
            let shouldEnhance = enhancedModeEnabled && triggerMode == .enhanced
            if shouldEnhance {
                state = .enhancing
                overlayPanel.show(state: .enhancing)
                let enhancementResult = await grammarEnhancer.enhance(
                    text: trimmed,
                    model: enhancedModel,
                    provider: enhancedProvider,
                    openAIConfiguration: currentOpenAIConfiguration(),
                    prompt: enhancementPrompt
                )
                finalText = enhancementResult.text
                lastEnhancementModel = enhancementResult.effectiveModel
                lastEnhancementProvider = enhancementResult.providerDisplayName
                lastEnhancementWarning = enhancementResult.warning
                lastWasEnhanced = enhancementResult.didSucceed
                if let warning = enhancementResult.warning {
                    appLog.error("Enhancement fallback: \(warning, privacy: .public)")
                }
            } else {
                lastWasEnhanced = false
                lastEnhancementWarning = nil
                lastEnhancementModel = ""
                lastEnhancementProvider = ""
            }
            lastTranscription = finalText
            if autoPasteEnabled {
                appLog.info("Auto-pasting transcription")
                pasteManager.pasteText(finalText)
            }
            overlayPanel.show(state: .done)
            try? await Task.sleep(for: .milliseconds(600))
            overlayPanel.dismiss()
            state = .ready
        } catch {
            appLog.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            state = .ready
            overlayPanel.dismiss()
        }
    }

    private func currentOpenAIConfiguration() -> GrammarEnhancer.OpenAIConfiguration {
        .init(
            baseURL: enhancedOpenAIBaseURL,
            apiKey: resolvedEnhancedAPIKey(),
            modelOverride: selectedOpenAIModel
        )
    }

    private func resolvedEnhancedAPIKey() -> String? {
        let trimmed = enhancedOpenAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? EnhancedProvider.defaultOpenAIAPIKey : trimmed
    }

    private func updateInputDeviceStatusMessage(for device: AudioInputDevice? = nil) {
        if let device {
            inputDeviceStatusMessage = "Selected input: \(device.name). OpenWritr switches the macOS system input to this device while it is selected."
            return
        }

        if let selectedID = selectedInputDeviceID,
           let selectedDevice = availableInputDevices.first(where: { $0.id == selectedID }) {
            inputDeviceStatusMessage = "Selected input: \(selectedDevice.name). OpenWritr switches the macOS system input to this device while it is selected."
        } else {
            inputDeviceStatusMessage = "Using System Default. OpenWritr follows the current macOS system input device."
        }
    }

    private struct OpenAIModelsResponse: Decodable {
        struct Model: Decodable {
            let id: String
        }

        let data: [Model]
    }

    private func openAIModelsURL(from baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else { return nil }

        let pathParts = components.path.split(separator: "/").map(String.init)
        if pathParts.last == "models" {
            return components.url
        }

        var updatedPathParts = pathParts
        if updatedPathParts.last != "v1" {
            updatedPathParts.append("v1")
        }
        updatedPathParts.append("models")
        components.path = "/" + updatedPathParts.joined(separator: "/")
        return components.url
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
                .task {
                    await viewModel.setup()
                }
        }

        Settings {
            SettingsView(viewModel: viewModel)
        }
    }

    private var menuBarIcon: some View {
        Group {
            switch viewModel.state {
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
            case .error:
                Image(systemName: "exclamationmark.triangle")
            default:
                Image(systemName: "mic")
            }
        }
    }
}
