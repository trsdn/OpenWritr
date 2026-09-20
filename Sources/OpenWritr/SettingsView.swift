import SwiftUI
import CoreAudio
import CoreGraphics
import IOKit.hidsystem

private enum PromptTargetChange {
    case provider(EnhancedProvider)
    case model(EnhancedModel)
    case openAIModel(String)
}

/// Keeps the hosting window above other windows, including the floating
/// recording overlay, and brings it to the front whenever it is shown.
/// An `LSUIElement` app is never active on its own, so it also activates the app
/// here rather than in a tap gesture, which keyboard activation would skip.
private struct KeepWindowOnTop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            window.collectionBehavior.insert(.moveToActiveSpace)
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct SettingsView: View {
    @Bindable var viewModel: AppViewModel
    @State private var isEditingPrompt = false
    @State private var promptDraft = ""
    @State private var pendingPromptTargetChange: PromptTargetChange?
    @State private var showPromptSwitchConfirmation = false
    @State private var showPromptOverwriteConfirmation = false
    @State private var showPromptResetConfirmation = false

    var body: some View {
        Form {
            Section("Recording") {
                Picker("Input Device", selection: inputDeviceSelection) {
                    Text("System Default").tag(kAudioObjectUnknown)
                    ForEach(viewModel.availableInputDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .disabled(!viewModel.canChangeInputDevice)

                Text(inputDeviceStatusMessage)
                    .font(.caption)
                    .foregroundStyle(inputDeviceStatusNeedsAttention ? Color.warningText : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Push-to-Talk Key", selection: Binding(
                    get: { viewModel.hotkeyChoice },
                    set: { viewModel.setHotkey($0) }
                )) {
                    ForEach(HotkeyChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }

                Text(recordingModeHelpText)
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

                Toggle("Always Enhance Recordings", isOn: Binding(
                    get: { viewModel.alwaysEnhancedEnabled },
                    set: {
                        viewModel.alwaysEnhancedEnabled = $0
                        viewModel.savePreference("alwaysEnhancedEnabled", value: $0)
                    }
                ))
                .disabled(!viewModel.enhancedModeEnabled)

                Text(enhancementActivationHelpText)
                .font(.caption)
                .foregroundStyle(.secondary)

                Picker("Provider", selection: Binding(
                    get: { viewModel.enhancedProvider },
                    set: { requestPromptTargetChange(.provider($0)) }
                )) {
                    ForEach(EnhancedProvider.allCases) { provider in
                        Text(provider.displayName)
                            .tag(provider)
                            .disabled(
                                provider == .appleIntelligence
                                    && !viewModel.appleIntelligenceAvailability.isAvailable
                            )
                    }
                }
                .disabled(isEditingPrompt)

                if viewModel.enhancedProvider == .appleIntelligence
                    || !viewModel.appleIntelligenceAvailability.isAvailable
                {
                    Text(viewModel.appleIntelligenceAvailability.message)
                        .font(.caption)
                        .foregroundStyle(
                            viewModel.appleIntelligenceAvailability.isAvailable
                                ? Color.secondary
                                : Color.warningText
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }

                if viewModel.enhancedProvider == .copilot {
                    Picker("Model", selection: Binding(
                        get: { viewModel.enhancedModel },
                        set: { requestPromptTargetChange(.model($0)) }
                    )) {
                        ForEach(EnhancedModel.allCases) { model in
                            Text("\(model.displayName)  \(model.priceIndicator)")
                                .tag(model)
                        }
                    }
                    .disabled(isEditingPrompt)

                    HStack(alignment: .firstTextBaseline) {
                        Text("\(viewModel.enhancedModel.pricingSummary) per 1M tokens")
                        Spacer()
                        Link(
                            "GitHub pricing (Aug 14, 2026)",
                            destination: EnhancedModel.pricingURL
                        )
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                        set: { requestPromptTargetChange(.openAIModel($0)) }
                    )) {
                        ForEach(viewModel.displayedOpenAIModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("OpenAI-compatible model")
                    .disabled(isEditingPrompt)

                    if let message = viewModel.openAIModelRefreshMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(viewModel.enhancementPromptIsCustomized ? "Custom prompt" : "Tuned prompt")
                                .font(.subheadline.weight(.medium))
                            Text(
                                viewModel.enhancementPromptIsCustomized
                                    ? "Saved for \(viewModel.enhancementPromptTargetDisplayName)"
                                    : "Tuned for \(viewModel.enhancementPromptTargetDisplayName)"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isEditingPrompt {
                            Button("Cancel") {
                                isEditingPrompt = false
                                promptDraft = ""
                            }
                            Button("Save") {
                                viewModel.setEnhancementPrompt(promptDraft)
                                isEditingPrompt = false
                                promptDraft = ""
                            }
                            .disabled(promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        } else {
                            if viewModel.enhancementPromptIsCustomized {
                                Button("Restore Default") {
                                    showPromptResetConfirmation = true
                                }
                                .buttonStyle(.link)
                            }
                            Button("Edit") {
                                promptDraft = viewModel.enhancementPrompt
                                isEditingPrompt = true
                            }
                        }
                    }

                    if isEditingPrompt {
                        TextEditor(text: $promptDraft)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .frame(minHeight: 150)
                    } else {
                        ScrollView {
                            Text(viewModel.enhancementPrompt)
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(minHeight: 130, maxHeight: 190)
                        .background(.background.secondary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                    }

                    Text("Bundled defaults can improve in app updates. Your custom prompt is stored separately for this provider and model.")
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
                        .foregroundStyle(Color.warningText)
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

            Section("Updates") {
                Toggle("Automatically Check for Updates", isOn: Binding(
                    get: { viewModel.updateManager.automaticCheckEnabled },
                    set: { viewModel.updateManager.automaticCheckEnabled = $0 }
                ))

                Button("Check for Updates Now…") {
                    viewModel.checkForUpdates()
                }

                Text(updateStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 520)
        .background(KeepWindowOnTop())
        .onAppear {
            viewModel.refreshInputDevices()
            viewModel.refreshAppleIntelligenceAvailability()
        }
        .confirmationDialog(
            "Switch cleanup target?",
            isPresented: $showPromptSwitchConfirmation,
            titleVisibility: .visible
        ) {
            Button("Use destination prompt") {
                applyPendingPromptTargetChange()
            }
            Button("Copy current custom prompt") {
                prepareToCopyCurrentPrompt()
            }
            Button("Cancel", role: .cancel) {
                pendingPromptTargetChange = nil
            }
        } message: {
            Text("The current prompt is customized. The destination has its own model-tuned default and may also have a saved custom prompt.")
        }
        .alert("Replace destination custom prompt?", isPresented: $showPromptOverwriteConfirmation) {
            Button("Replace", role: .destructive) {
                copyCurrentPromptAndApplyPendingChange()
            }
            Button("Cancel", role: .cancel) {
                pendingPromptTargetChange = nil
            }
        } message: {
            Text("A custom prompt is already saved for the destination. Replacing it cannot be undone.")
        }
        .alert("Restore model default?", isPresented: $showPromptResetConfirmation) {
            Button("Restore", role: .destructive) {
                viewModel.resetEnhancementPrompt()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the custom prompt only for \(viewModel.enhancementPromptTargetDisplayName).")
        }
    }

    private func requestPromptTargetChange(_ change: PromptTargetChange) {
        if case .provider(.appleIntelligence) = change,
           !viewModel.appleIntelligenceAvailability.isAvailable {
            return
        }
        guard targetKey(for: change) != viewModel.enhancementPromptTargetKey else { return }
        if viewModel.enhancementPromptIsCustomized {
            pendingPromptTargetChange = change
            showPromptSwitchConfirmation = true
        } else {
            apply(change)
        }
    }

    private func prepareToCopyCurrentPrompt() {
        guard let change = pendingPromptTargetChange else { return }
        let destination = targetValues(for: change)
        if viewModel.hasCustomEnhancementPrompt(
            provider: destination.provider,
            model: destination.model,
            openAIModel: destination.openAIModel
        ) {
            DispatchQueue.main.async {
                showPromptOverwriteConfirmation = true
            }
        } else {
            copyCurrentPromptAndApplyPendingChange()
        }
    }

    private func copyCurrentPromptAndApplyPendingChange() {
        guard let change = pendingPromptTargetChange else { return }
        let destination = targetValues(for: change)
        viewModel.copyCurrentEnhancementPrompt(
            to: destination.provider,
            model: destination.model,
            openAIModel: destination.openAIModel
        )
        applyPendingPromptTargetChange()
    }

    private func applyPendingPromptTargetChange() {
        guard let change = pendingPromptTargetChange else { return }
        pendingPromptTargetChange = nil
        apply(change)
    }

    private func apply(_ change: PromptTargetChange) {
        switch change {
        case .provider(let provider):
            viewModel.setEnhancedProvider(provider)
        case .model(let model):
            viewModel.setEnhancedModel(model)
        case .openAIModel(let model):
            viewModel.setSelectedOpenAIModel(model)
        }
    }

    private func targetKey(for change: PromptTargetChange) -> String {
        let values = targetValues(for: change)
        return GrammarEnhancer.promptTargetKey(
            provider: values.provider,
            model: values.model,
            openAIModel: values.openAIModel
        )
    }

    private func targetValues(
        for change: PromptTargetChange
    ) -> (provider: EnhancedProvider, model: EnhancedModel, openAIModel: String) {
        switch change {
        case .provider(let provider):
            return (provider, viewModel.enhancedModel, viewModel.selectedOpenAIModel)
        case .model(let model):
            return (viewModel.enhancedProvider, model, viewModel.selectedOpenAIModel)
        case .openAIModel(let model):
            return (viewModel.enhancedProvider, viewModel.enhancedModel, model)
        }
    }

    private var inputDeviceSelection: Binding<AudioDeviceID> {
        Binding(
            get: { viewModel.selectedInputDeviceID ?? kAudioObjectUnknown },
            set: { newID in
                let device = viewModel.availableInputDevices.first { $0.id == newID }
                viewModel.setInputDevice(device)
            }
        )
    }

    private var recordingModeHelpText: String {
        guard viewModel.enhancedModeEnabled else {
            return "Enhanced Mode is off; all recordings use normal transcription."
        }
        if viewModel.alwaysEnhancedEnabled {
            return "\(viewModel.hotkeyChoice.shortLabel) = enhanced, Shift + \(viewModel.hotkeyChoice.shortLabel) = normal"
        }
        return "\(viewModel.hotkeyChoice.shortLabel) = normal, Shift + \(viewModel.hotkeyChoice.shortLabel) = enhanced"
    }

    private var enhancementActivationHelpText: String {
        guard viewModel.enhancedModeEnabled else {
            return "Turn on Enhanced Mode to use model cleanup."
        }
        if viewModel.alwaysEnhancedEnabled {
            return "The hotkey enhances every recording. Hold Shift to bypass enhancement once."
        }
        return "Hold Shift with the hotkey to enhance only that recording."
    }

    private var updateStatusMessage: String {
        switch viewModel.updateManager.state {
        case .idle:
            return "Updates are downloaded from signed GitHub releases and verified before install."
        case .checking:
            return "Checking GitHub for a newer release…"
        case .upToDate:
            return "You're on the latest release."
        case .updateAvailable(let version):
            return "OpenWritr \(version) is available and is being downloaded."
        case .downloading(let version):
            return "Downloading OpenWritr \(version)…"
        case .readyToInstall(let version):
            return "OpenWritr \(version) is ready. Use the menu bar item to install & relaunch."
        case .installing:
            return "Installing update and relaunching…"
        case .failed(let message):
            return "Last update check failed: \(message)"
        }
    }

    private var isAudioRuntimeError: Bool {
        guard case .runtimeError(let error) = viewModel.state,
              case .audio = error.kind
        else { return false }
        return true
    }

    private var selectedInputDeviceIsDisconnected: Bool {
        guard let selectedID = viewModel.selectedInputDeviceID else { return false }
        return !viewModel.availableInputDevices.contains { $0.id == selectedID }
    }

    private var inputDeviceStatusNeedsAttention: Bool {
        selectedInputDeviceIsDisconnected || isAudioRuntimeError
    }

    private var inputDeviceStatusMessage: String {
        if selectedInputDeviceIsDisconnected {
            return "The selected input device is disconnected. OpenWritr will fall back to the macOS system default after validation."
        }
        if isAudioRuntimeError {
            return "\(viewModel.inputDeviceStatusMessage) Microphone validation is required before recording."
        }
        return viewModel.inputDeviceStatusMessage
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
        case .fn: return CGEventFlags.maskSecondaryFn.rawValue
        case .rightOption: return UInt64(NX_DEVICERALTKEYMASK)
        case .rightCommand: return UInt64(NX_DEVICERCMDKEYMASK)
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
