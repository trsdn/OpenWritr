import SwiftUI
import CoreAudio

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
            return "Ready — Hold \(viewModel.hotkeyChoice.shortLabel) to Speak"
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
    private var settingsSection: some View {
        Picker("Input Device", selection: Binding(
            get: { viewModel.selectedInputDeviceID },
            set: { newID in
                let device = viewModel.availableInputDevices.first { $0.id == newID }
                viewModel.setInputDevice(device)
            }
        )) {
            Text("System Default").tag(AudioDeviceID?.none)
            ForEach(viewModel.availableInputDevices) { device in
                Text(device.name).tag(AudioDeviceID?.some(device.id))
            }
        }
        .onAppear { viewModel.refreshInputDevices() }

        Picker("Push-to-Talk Key", selection: Binding(
            get: { viewModel.hotkeyChoice },
            set: { viewModel.setHotkey($0) }
        )) {
            ForEach(HotkeyChoice.allCases) { choice in
                Text(choice.label).tag(choice)
            }
        }

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

        Toggle("Launch at Login", isOn: Binding(
            get: { viewModel.launchAtLogin },
            set: { _ in viewModel.toggleLaunchAtLogin() }
        ))

        Divider()

        Toggle("Enhanced Mode", isOn: Binding(
            get: { viewModel.enhancedModeEnabled },
            set: {
                viewModel.enhancedModeEnabled = $0
                viewModel.savePreference("enhancedModeEnabled", value: $0)
            }
        ))
        .disabled(!isReady)

        if viewModel.enhancedModeEnabled {
            Picker("Model", selection: Binding(
                get: { viewModel.enhancedModel },
                set: {
                    viewModel.enhancedModel = $0
                    viewModel.savePreference("enhancedModel", value: $0.rawValue)
                }
            )) {
                ForEach(EnhancedModel.allCases) { model in
                    Text(model.displayName).tag(model)
                }
            }
        }
    }
}
