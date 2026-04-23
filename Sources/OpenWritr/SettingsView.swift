import SwiftUI
import CoreAudio

struct SettingsView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        Form {
            Section("Recording") {
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

                Text(viewModel.inputDeviceStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Push-to-Talk Key", selection: Binding(
                    get: { viewModel.hotkeyChoice },
                    set: { viewModel.setHotkey($0) }
                )) {
                    ForEach(HotkeyChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }

                Text("\(viewModel.hotkeyChoice.shortLabel) = normal, Shift + \(viewModel.hotkeyChoice.shortLabel) = enhanced")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Auto-Paste", isOn: Binding(
                    get: { viewModel.autoPasteEnabled },
                    set: {
                        viewModel.autoPasteEnabled = $0
                        viewModel.savePreference("autoPasteEnabled", value: $0)
                    }
                ))

                Toggle("Sound Effects", isOn: Binding(
                    get: { viewModel.soundEnabled },
                    set: {
                        viewModel.soundEnabled = $0
                        viewModel.savePreference("soundEnabled", value: $0)
                    }
                ))
            }

            Section("Enhancement") {
                Toggle("Enhanced Mode", isOn: Binding(
                    get: { viewModel.enhancedModeEnabled },
                    set: {
                        viewModel.enhancedModeEnabled = $0
                        viewModel.savePreference("enhancedModeEnabled", value: $0)
                    }
                ))

                Picker("Provider", selection: Binding(
                    get: { viewModel.enhancedProvider },
                    set: {
                        viewModel.enhancedProvider = $0
                        viewModel.savePreference("enhancedProvider", value: $0.rawValue)
                    }
                )) {
                    ForEach(EnhancedProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }

                if viewModel.enhancedProvider == .copilot {
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

                if viewModel.enhancedProvider == .openAICompatible {
                    TextField("Base URL", text: Binding(
                        get: { viewModel.enhancedOpenAIBaseURL },
                        set: {
                            viewModel.enhancedOpenAIBaseURL = $0
                            viewModel.savePreference("enhancedOpenAIBaseURL", value: $0)
                        }
                    ))

                    SecureField("API Key (optional)", text: Binding(
                        get: { viewModel.enhancedOpenAIAPIKey },
                        set: { viewModel.setEnhancedOpenAIAPIKey($0) }
                    ))

                    Text("Stored in Keychain. Leave empty to use environment variables.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("Model")
                        Spacer()
                        Button(viewModel.isRefreshingOpenAIModels ? "Refreshing..." : "Refresh Models") {
                            Task {
                                await viewModel.refreshOpenAIModels()
                            }
                        }
                        .disabled(viewModel.isRefreshingOpenAIModels)
                    }

                    Picker("", selection: Binding(
                        get: { viewModel.selectedOpenAIModel },
                        set: { viewModel.setSelectedOpenAIModel($0) }
                    )) {
                        ForEach(viewModel.displayedOpenAIModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()

                    if let message = viewModel.openAIModelRefreshMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Prompt")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Button("Reset") {
                            viewModel.resetEnhancementPrompt()
                        }
                        .buttonStyle(.link)
                    }

                    TextEditor(text: Binding(
                        get: { viewModel.enhancementPrompt },
                        set: { viewModel.setEnhancementPrompt($0) }
                    ))
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .frame(minHeight: 130)

                    Text("Used by both GitHub Copilot and OpenAI-compatible enhancement requests.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !viewModel.lastEnhancementModel.isEmpty {
                    LabeledContent("Last Request") {
                        Text("\(viewModel.lastEnhancementProvider) -> \(viewModel.lastEnhancementModel)")
                            .textSelection(.enabled)
                    }
                }

                if let warning = viewModel.lastEnhancementWarning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("App") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { viewModel.launchAtLogin },
                    set: { _ in viewModel.toggleLaunchAtLogin() }
                ))

                Toggle("Debug Mode", isOn: Binding(
                    get: { viewModel.debugModeEnabled },
                    set: {
                        viewModel.debugModeEnabled = $0
                        viewModel.savePreference("debugModeEnabled", value: $0)
                    }
                ))
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 520)
        .onAppear {
            viewModel.refreshInputDevices()
        }
    }
}

enum HotkeyChoice: String, CaseIterable, Identifiable, Sendable {
    case fn = "fn"
    case rightOption = "rightOption"
    case rightCommand = "rightCommand"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fn: return "🌐 Fn (Globe)"
        case .rightOption: return "⌥ Right Option"
        case .rightCommand: return "⌘ Right Command"
        }
    }

    var shortLabel: String {
        switch self {
        case .fn: return "🌐"
        case .rightOption: return "⌥"
        case .rightCommand: return "⌘"
        }
    }

    var flag: UInt64 {
        switch self {
        case .fn: return 0x800000
        case .rightOption: return 0x40
        case .rightCommand: return 0x10
        }
    }

    var keyCode: Int64 {
        switch self {
        case .fn: return 63
        case .rightOption: return 61
        case .rightCommand: return 54
        }
    }
}
