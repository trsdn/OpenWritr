import SwiftUI

struct MenuBarView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            statusSection
            Divider()
            quickControlsSection
            Divider()
            SettingsLink {
                Label("Settings…", systemImage: "gearshape")
            }
            Divider()
            Button("Quit OpenWritr") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(statusText)
                .font(.headline)
                .padding(.horizontal, 4)

            if let warning = viewModel.lastEnhancementWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if viewModel.debugModeEnabled && !viewModel.lastTranscription.isEmpty {
            Divider()
            if viewModel.lastWasEnhanced {
                Text("Raw:")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                Text(viewModel.lastRawTranscription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .textSelection(.enabled)
                Text("Enhanced:")
                    .font(.caption.bold())
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 4)
                Text(viewModel.lastTranscription)
                    .font(.caption)
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 4)
                    .textSelection(.enabled)
            } else {
                Text("Output:")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                Text(viewModel.lastTranscription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .textSelection(.enabled)
            }
        }
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
            return "Ready"
        case .listening:
            return "Listening…"
        case .transcribing:
            return "Transcribing…"
        case .enhancing:
            return "Enhancing…"
        case .error(let msg):
            return "Error: \(msg)"
        }
    }

    private var isReady: Bool {
        if case .ready = viewModel.state { return true }
        return false
    }

    @ViewBuilder
    private var quickControlsSection: some View {
        Toggle("Auto-Paste", isOn: Binding(
            get: { viewModel.autoPasteEnabled },
            set: {
                viewModel.autoPasteEnabled = $0
                viewModel.savePreference("autoPasteEnabled", value: $0)
            }
        ))
        .disabled(!isReady)

        Toggle("Sound Effects", isOn: Binding(
            get: { viewModel.soundEnabled },
            set: {
                viewModel.soundEnabled = $0
                viewModel.savePreference("soundEnabled", value: $0)
            }
        ))
        .disabled(!isReady)

        Toggle("Enhanced Mode", isOn: Binding(
            get: { viewModel.enhancedModeEnabled },
            set: {
                viewModel.enhancedModeEnabled = $0
                viewModel.savePreference("enhancedModeEnabled", value: $0)
            }
        ))
        .disabled(!isReady)
    }
}
