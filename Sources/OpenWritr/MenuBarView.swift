import SwiftUI

struct MenuBarView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            statusSection
            Divider()
            quickControlsSection
            Divider()
            updateSection
            SettingsLink {
                Label("Settings…", systemImage: "gearshape")
            }
            Button {
                openWindow(id: "about")
            } label: {
                Label("About OpenWritr…", systemImage: "info.circle")
            }
            Divider()
            Button("Quit OpenWritr") {
                viewModel.shutdown()
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

            if let error = currentError {
                Text(error.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
                if let recoverySuggestion = error.recoverySuggestion {
                    Text(recoverySuggestion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                errorActions
            } else if let warning = viewModel.lastEnhancementWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(Color.warningText)
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
            return "Ready — Hold \(viewModel.hotkeyChoice.shortLabel) to Speak"
        case .preparingMicrophone:
            return "Preparing Microphone…"
        case .listening:
            return "Listening…"
        case .transcribing:
            return "Transcribing…"
        case .enhancing:
            return "Enhancing…"
        case .initializationError(let error), .runtimeError(let error):
            return error.title
        }
    }

    private var currentError: AppErrorPresentation? {
        switch viewModel.state {
        case .initializationError(let error), .runtimeError(let error): return error
        default: return nil
        }
    }

    @ViewBuilder
    private var errorActions: some View {
        switch viewModel.state {
        case .initializationError:
            Button("Retry Initialization") { Task { await viewModel.retryInitialization() } }
        case .runtimeError(let error):
            switch error.kind {
            case .audio:
                Button("Retry Microphone") {
                    viewModel.retryMicrophone()
                }
                Button("Dismiss Error") {
                    viewModel.dismissRuntimeError()
                }
            case .enhancement:
                Button("Retry Enhancement") { Task { await viewModel.retryEnhancement() } }
                if viewModel.recoverableRawTranscription != nil {
                    Button(viewModel.autoPasteEnabled ? "Use & Paste Raw Transcript" : "Use Raw Transcript") {
                        viewModel.useRawTranscription()
                    }
                }
                Button("Dismiss Error") { viewModel.dismissRuntimeError() }
            case .transcription, .paste:
                Button("Dismiss Error") { viewModel.dismissRuntimeError() }
            }
        default:
            EmptyView()
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

    @ViewBuilder
    private var updateSection: some View {
        switch viewModel.updateManager.state {
        case .idle, .upToDate:
            Button("Check for Updates…") {
                viewModel.checkForUpdates()
            }
            if case .upToDate = viewModel.updateManager.state {
                Text("OpenWritr is up to date.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            Divider()
        case .checking:
            Label("Checking for Updates…", systemImage: "arrow.triangle.2.circlepath")
            Divider()
        case .updateAvailable(let version), .downloading(let version):
            Label("Downloading OpenWritr \(version)…", systemImage: "arrow.down.circle")
            Divider()
        case .readyToInstall(let version):
            Text("OpenWritr \(version) is ready to install.")
                .font(.caption)
                .padding(.horizontal, 4)
            Button("Install & Relaunch…") {
                viewModel.installAvailableUpdate()
            }
            Button("Later") {
                viewModel.dismissAvailableUpdate()
            }
            Divider()
        case .installing:
            Label("Installing Update…", systemImage: "hourglass")
            Divider()
        case .failed(let message):
            Text("Update check failed: \(message)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .fixedSize(horizontal: false, vertical: true)
            Button("Check for Updates…") {
                viewModel.checkForUpdates()
            }
            Divider()
        }
    }
}
