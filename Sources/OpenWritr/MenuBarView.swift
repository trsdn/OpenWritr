import SwiftUI

struct MenuBarView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            statusSection
            Divider()
            settingsSection
            Divider()
            Button("Quit OpenWritr") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Text(statusText)
            .font(.headline)
            .padding(.horizontal, 4)
    }

    private var statusText: String {
        switch viewModel.state {
        case .idle:
            return "Initializing…"
        case .loading:
            return "Loading Model…"
        case .downloading(let progress):
            return "Downloading Model (\(Int(progress * 100))%)…"
        case .ready:
            return "Ready — Hold 🌐 to Speak"
        case .listening:
            return "Listening…"
        case .transcribing:
            return "Transcribing…"
        case .error(let msg):
            return "Error: \(msg)"
        }
    }

    private var isReady: Bool {
        if case .ready = viewModel.state { return true }
        return false
    }

    @ViewBuilder
    private var settingsSection: some View {
        Toggle("Auto-Paste", isOn: $viewModel.autoPasteEnabled)
            .disabled(!isReady)
        Toggle("Sound Effects", isOn: $viewModel.soundEnabled)
            .disabled(!isReady)
        Toggle("Launch at Login", isOn: $viewModel.launchAtLogin)
    }
}
