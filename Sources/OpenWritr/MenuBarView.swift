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
        HStack {
            statusIcon
            Text(statusText)
                .font(.headline)
        }
        .padding(.horizontal, 4)
    }

    private var statusIcon: some View {
        Group {
            switch viewModel.state {
            case .idle, .ready:
                Image(systemName: "mic")
                    .foregroundStyle(.secondary)
            case .downloading(let progress):
                ProgressView(value: progress)
                    .frame(width: 16)
            case .listening:
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var statusText: String {
        switch viewModel.state {
        case .idle:
            return "Initializing..."
        case .downloading(let progress):
            return "Downloading model (\(Int(progress * 100))%)"
        case .ready:
            return "Ready — Hold Fn to speak"
        case .listening:
            return "Listening..."
        case .transcribing:
            return "Transcribing..."
        case .error(let msg):
            return "Error: \(msg)"
        }
    }

    @ViewBuilder
    private var settingsSection: some View {
        Toggle("Auto-paste", isOn: $viewModel.autoPasteEnabled)
        Toggle("Sound effects", isOn: $viewModel.soundEnabled)
    }
}
