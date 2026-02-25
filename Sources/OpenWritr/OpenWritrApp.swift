import SwiftUI
import Combine
import CoreAudio
import ServiceManagement

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
    var state: AppState = .idle
    var lastTranscription: String = ""
    var lastRawTranscription: String = ""
    var lastWasEnhanced: Bool = false
    var debugModeEnabled: Bool = false
    var soundEnabled: Bool = true
    var autoPasteEnabled: Bool = true
    var launchAtLogin: Bool = false
    var hotkeyChoice: HotkeyChoice = .fn
    var availableInputDevices: [AudioInputDevice] = []
    var selectedInputDeviceID: AudioDeviceID?
    var enhancedModeEnabled: Bool = false
    var enhancedModel: EnhancedModel = .gpt4_1

    let transcriptionManager = TranscriptionManager()
    let grammarEnhancer: GrammarEnhancer = .init()
    let audioEngine = AudioEngine()
    let hotkeyManager = HotkeyManager()
    let pasteManager = PasteManager()
    let overlayPanel = OverlayPanel()
    let soundManager = SoundManager()
    let permissionsManager = PermissionsManager()

    func setup() async {
        // Restore preferences
        let d = UserDefaults.standard
        if d.object(forKey: "soundEnabled") != nil { soundEnabled = d.bool(forKey: "soundEnabled") }
        if d.object(forKey: "autoPasteEnabled") != nil { autoPasteEnabled = d.bool(forKey: "autoPasteEnabled") }
        if let raw = d.string(forKey: "hotkeyChoice"), let c = HotkeyChoice(rawValue: raw) {
            hotkeyChoice = c
        }
        if d.object(forKey: "enhancedModeEnabled") != nil { enhancedModeEnabled = d.bool(forKey: "enhancedModeEnabled") }
        if let modelRaw = d.string(forKey: "enhancedModel"), let m = EnhancedModel(rawValue: modelRaw) {
            enhancedModel = m
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
                }
            }
        }

        refreshInputDevices()
        if let savedUID = d.string(forKey: "inputDeviceUID") {
            let match = availableInputDevices.first { $0.uid == savedUID }
            if let match {
                selectedInputDeviceID = match.id
                audioEngine.setInputDevice(match.id)
            } else {
                audioEngine.prepare()
            }
        } else {
            audioEngine.prepare()
        }
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

            hotkeyManager.onRecordingStarted = { [weak self] in
                Task { @MainActor in
                    self?.startListening()
                }
            }
            hotkeyManager.onRecordingStopped = { [weak self] in
                Task { @MainActor in
                    await self?.stopListeningAndTranscribe()
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

    func startListening() {
        guard case .ready = state else { return }
        state = .listening
        audioEngine.startCapture()
        overlayPanel.show(state: .listening)
        if soundEnabled {
            soundManager.playStartSound()
        }
    }

    func stopListeningAndTranscribe() async {
        guard case .listening = state else { return }
        let samples = audioEngine.stopCapture()
        state = .transcribing
        overlayPanel.show(state: .transcribing)
        if soundEnabled {
            soundManager.playStopSound()
        }

        let minSamples = Int(16_000 * 0.3)
        guard samples.count > minSamples else {
            state = .ready
            overlayPanel.dismiss()
            return
        }

        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        guard rms > 0.005 else {
            state = .ready
            overlayPanel.dismiss()
            return
        }

        do {
            let text = try await transcriptionManager.transcribe(samples: samples)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                state = .ready
                overlayPanel.dismiss()
                return
            }
            var finalText = trimmed
            lastRawTranscription = trimmed
            if enhancedModeEnabled {
                state = .enhancing
                overlayPanel.show(state: .enhancing)
                finalText = await grammarEnhancer.enhance(text: trimmed, model: enhancedModel)
                lastWasEnhanced = true
            } else {
                lastWasEnhanced = false
            }
            lastTranscription = finalText
            if autoPasteEnabled {
                pasteManager.pasteText(finalText)
            }
            overlayPanel.show(state: .done)
            try? await Task.sleep(for: .milliseconds(600))
            overlayPanel.dismiss()
            state = .ready
        } catch {
            state = .ready
            overlayPanel.dismiss()
        }
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
