import SwiftUI
import Combine
import ServiceManagement

enum AppState: Sendable {
    case idle
    case loading
    case downloading(progress: Double)
    case ready
    case listening
    case transcribing
    case error(String)
}

@MainActor
@Observable
final class AppViewModel {
    var state: AppState = .idle
    var lastTranscription: String = ""
    var soundEnabled: Bool = true
    var autoPasteEnabled: Bool = true
    var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }
    let transcriptionManager = TranscriptionManager()
    let audioEngine = AudioEngine()
    let hotkeyManager = HotkeyManager()
    let pasteManager = PasteManager()
    let overlayPanel = OverlayPanel()
    let soundManager = SoundManager()
    let permissionsManager = PermissionsManager()

    func setup() async {
        audioEngine.prepare()
        permissionsManager.requestAccessibilityAccess()

        state = .loading
        do {
            try await transcriptionManager.loadModels { [weak self] progress in
                Task { @MainActor in
                    // Only show download progress if actually downloading (progress < 1.0)
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

        // Ignore very short recordings (<0.3s) or silence
        let minSamples = Int(16_000 * 0.3) // 0.3 seconds at 16kHz
        guard samples.count > minSamples else {
            state = .ready
            overlayPanel.dismiss()
            return
        }

        // Check if audio is mostly silence (RMS below threshold)
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
            lastTranscription = trimmed
            if autoPasteEnabled {
                pasteManager.pasteText(trimmed)
            }
            overlayPanel.show(state: .done)
            try? await Task.sleep(for: .milliseconds(600))
            overlayPanel.dismiss()
            state = .ready
        } catch {
            // Silently go back to ready — don't show errors for transcription failures
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
