import CoreAudio
import Foundation
import Testing
@testable import OpenWritr

@MainActor
@Suite("AppViewModel dictation flow")
struct AppViewModelDictationFlowTests {
    @Test func normalTranscriptionPastesAndShowsDone() async {
        let dependencies = makeDependencies(
            samples: [audibleSamples(count: 16_000)],
            transcriptions: [.success("  Synthetic transcript.  ")]
        )
        let viewModel = dependencies.makeViewModel()
        defer { viewModel.shutdown() }

        await recordAndStop(viewModel)

        #expect(dependencies.paster.pastedTexts == ["Synthetic transcript."])
        #expect(dependencies.overlay.didShowDone)
        #expect(viewModel.lastTranscription == "Synthetic transcript.")
        #expect(viewModel.state.isReady)
    }

    @Test func enhancedFlowAndFallbacksPreserveRawTranscript() async {
        let success = makeDependencies(
            samples: [audibleSamples(count: 16_000)],
            transcriptions: [.success("Synthetic raw transcript.")],
            enhancements: [
                enhancement(text: "Synthetic cleaned transcript.", didSucceed: true)
            ]
        )
        let successfulViewModel = success.makeViewModel()
        defer { successfulViewModel.shutdown() }

        await recordAndStop(successfulViewModel, mode: .enhanced)

        #expect(success.paster.pastedTexts == ["Synthetic cleaned transcript."])
        #expect(successfulViewModel.lastRawTranscription == "Synthetic raw transcript.")
        #expect(successfulViewModel.lastWasEnhanced)

        let failure = makeDependencies(
            samples: [audibleSamples(count: 16_000)],
            transcriptions: [.success("Synthetic fallback transcript.")],
            enhancements: [
                enhancement(text: "Synthetic fallback transcript.", didSucceed: false)
            ]
        )
        let failedViewModel = failure.makeViewModel()
        defer { failedViewModel.shutdown() }

        await recordAndStop(failedViewModel, mode: .enhanced)

        #expect(failure.paster.pastedTexts.isEmpty)
        #expect(isRuntimeError(failedViewModel.state, kind: .enhancement))
        #expect(failedViewModel.recoverableRawTranscription == "Synthetic fallback transcript.")

        failedViewModel.useRawTranscription()

        #expect(failure.paster.pastedTexts == ["Synthetic fallback transcript."])
        #expect(failedViewModel.state.isReady)

        let empty = makeDependencies(
            samples: [audibleSamples(count: 16_000)],
            transcriptions: [.success("Synthetic filler transcript.")],
            enhancements: [enhancement(text: "  ", didSucceed: true)]
        )
        let emptyViewModel = empty.makeViewModel()
        defer { emptyViewModel.shutdown() }

        await recordAndStop(emptyViewModel, mode: .enhanced)

        #expect(empty.paster.pastedTexts.isEmpty)
        #expect(emptyViewModel.state.isReady)
        #expect(emptyViewModel.lastTranscription.isEmpty)
    }

    @Test func shortRecordingIsPaddedBeforeTranscription() async {
        let shortSamples = audibleSamples(count: 6_000)
        let dependencies = makeDependencies(
            samples: [shortSamples],
            transcriptions: [.success("Synthetic short recording.")]
        )
        let viewModel = dependencies.makeViewModel()
        defer { viewModel.shutdown() }

        await recordAndStop(viewModel)

        let received = dependencies.transcriber.receivedSamples.first
        #expect(received?.count == 16_000)
        #expect(Array(received?.prefix(shortSamples.count) ?? []) == shortSamples)
        #expect(received?.suffix(10).allSatisfy { $0 == 0 } == true)
        #expect(dependencies.paster.pastedTexts == ["Synthetic short recording."])
    }

    @Test func transcriptionErrorDismissesAndAllowsAnotherRecording() async {
        #expect(AppViewModel.defaultTransientErrorDisplayDuration == .seconds(2.5))
        let dependencies = makeDependencies(
            samples: [
                audibleSamples(count: 16_000),
                audibleSamples(count: 16_000)
            ],
            transcriptions: [
                .failure(TestFailure.expected),
                .success("Synthetic recovered transcript.")
            ]
        )
        let viewModel = dependencies.makeViewModel(transientErrorDisplayDuration: .milliseconds(10))
        defer { viewModel.shutdown() }

        await recordAndStop(viewModel)

        #expect(isRuntimeError(viewModel.state, kind: .transcription))
        #expect(dependencies.overlay.didShowError("Transcription failed"))

        await waitUntil { viewModel.state.isReady }

        await recordAndStop(viewModel)

        #expect(dependencies.paster.pastedTexts == ["Synthetic recovered transcript."])
        #expect(viewModel.state.isReady)
    }

    @Test func staleCaptureGenerationCannotOverwriteNewerOutput() async {
        let dependencies = makeDependencies(
            samples: [
                audibleSamples(count: 16_000),
                audibleSamples(count: 16_000)
            ],
            transcriptions: [
                .suspended,
                .success("Synthetic current transcript.")
            ]
        )
        dependencies.audio.devices = [
            AudioInputDevice(id: 42, name: "Synthetic microphone", uid: "synthetic-microphone")
        ]
        let viewModel = dependencies.makeViewModel()
        defer { viewModel.shutdown() }
        viewModel.selectedInputDeviceID = 42

        viewModel.startListening()
        await waitUntil { isListening(viewModel.state) }
        let staleTask = Task { @MainActor in
            await viewModel.stopListeningAndTranscribe()
        }
        await waitUntil { dependencies.transcriber.callCount == 1 }

        dependencies.audio.onFailure?(.inputDeviceUnavailable(42))
        await waitUntil { isRuntimeError(viewModel.state, kind: .audio) }
        viewModel.retryMicrophone()
        #expect(viewModel.state.isReady)

        await recordAndStop(viewModel)
        dependencies.transcriber.resumeSuspended(with: .success("Synthetic stale transcript."))
        await staleTask.value

        #expect(dependencies.paster.pastedTexts == ["Synthetic current transcript."])
        #expect(viewModel.lastTranscription == "Synthetic current transcript.")
        #expect(viewModel.state.isReady)
    }

    @Test func autoPasteDisabledLeavesPastingUntouched() async {
        let dependencies = makeDependencies(
            samples: [audibleSamples(count: 16_000)],
            transcriptions: [.success("Synthetic transcript without paste.")]
        )
        let viewModel = dependencies.makeViewModel()
        defer { viewModel.shutdown() }
        viewModel.autoPasteEnabled = false

        await recordAndStop(viewModel)

        #expect(dependencies.paster.pastedTexts.isEmpty)
        #expect(viewModel.lastTranscription == "Synthetic transcript without paste.")
        #expect(dependencies.overlay.didShowDone)
    }

    @Test func unreadableClipboardCancellationSurfacesTransientError() async {
        let dependencies = makeDependencies(
            samples: [
                audibleSamples(count: 16_000),
                audibleSamples(count: 16_000)
            ],
            transcriptions: [
                .success("Synthetic preserved transcript."),
                .success("Synthetic recovered transcript.")
            ],
            pasteOutcomes: [.cancelled, .pasted]
        )
        let viewModel = dependencies.makeViewModel()
        defer { viewModel.shutdown() }

        await recordAndStop(viewModel)

        #expect(dependencies.paster.pastedTexts.isEmpty)
        #expect(!dependencies.overlay.didShowDone)
        #expect(isRuntimeError(viewModel.state, kind: .paste))
        #expect(dependencies.overlay.didShowError("Clipboard could not be preserved; paste cancelled"))
        #expect(viewModel.lastTranscription == "Synthetic preserved transcript.")
        #expect(pasteErrorRecoverySuggestion(viewModel.state) == "Replace or clear the clipboard contents, then record again.")

        await waitUntil { viewModel.state.isReady }
        await recordAndStop(viewModel)

        #expect(dependencies.paster.pastedTexts == ["Synthetic recovered transcript."])
        #expect(viewModel.state.isReady)
    }

    @Test func priorRestoreFailureDoesNotSilentlyShowDone() async {
        let dependencies = makeDependencies(
            samples: [
                audibleSamples(count: 16_000),
                audibleSamples(count: 16_000)
            ],
            transcriptions: [
                .success("First synthetic transcript."),
                .success("Second synthetic transcript.")
            ],
            pasteOutcomes: [.pasted, .cancelled]
        )
        let viewModel = dependencies.makeViewModel()
        defer { viewModel.shutdown() }

        await recordAndStop(viewModel)
        let doneCountAfterFirstPaste = dependencies.overlay.doneCount

        await recordAndStop(viewModel)

        #expect(doneCountAfterFirstPaste == 1)
        #expect(dependencies.overlay.doneCount == doneCountAfterFirstPaste)
        #expect(isRuntimeError(viewModel.state, kind: .paste))
        #expect(dependencies.paster.pastedTexts == ["First synthetic transcript."])

        await waitUntil { viewModel.state.isReady }
    }

    private func recordAndStop(
        _ viewModel: AppViewModel,
        mode: RecordingShortcutMode = .normal
    ) async {
        viewModel.soundEnabled = false
        if mode == .enhanced {
            viewModel.enhancedModeEnabled = true
        }
        viewModel.startListening(triggerMode: mode)
        await waitUntil { isListening(viewModel.state) }
        await viewModel.stopListeningAndTranscribe(triggerMode: mode)
    }

    private func makeDependencies(
        samples: [[Float]],
        transcriptions: [FakeTranscriber.Behavior],
        enhancements: [EnhancementResult] = [],
        pasteOutcomes: [PasteOutcome] = []
    ) -> DictationDependencies {
        DictationDependencies(
            audio: FakeAudioCapture(samples: samples),
            transcriber: FakeTranscriber(behaviors: transcriptions),
            enhancer: FakeEnhancer(results: enhancements),
            paster: FakeTextPaster(outcomes: pasteOutcomes),
            overlay: FakeOverlayPresenter()
        )
    }

    private func enhancement(text: String, didSucceed: Bool) -> EnhancementResult {
        EnhancementResult(
            text: text,
            effectiveModel: "synthetic-model",
            providerDisplayName: "Synthetic Provider",
            didSucceed: didSucceed,
            warning: didSucceed ? nil : "Synthetic enhancement failure."
        )
    }

    private func audibleSamples(count: Int) -> [Float] {
        [Float](repeating: 0.1, count: count)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<1_000 {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for the expected dictation state.")
    }

    private func isListening(_ state: AppState) -> Bool {
        if case .listening = state {
            return true
        }
        return false
    }

    private func isRuntimeError(_ state: AppState, kind: RuntimeErrorKind) -> Bool {
        if case .runtimeError(let presentation) = state {
            return presentation.kind == kind
        }
        return false
    }

    private func pasteErrorRecoverySuggestion(_ state: AppState) -> String? {
        guard case .runtimeError(let presentation) = state,
              presentation.kind == .paste
        else { return nil }
        return presentation.recoverySuggestion
    }
}

@MainActor
private struct DictationDependencies {
    let audio: FakeAudioCapture
    let transcriber: FakeTranscriber
    let enhancer: FakeEnhancer
    let paster: FakeTextPaster
    let overlay: FakeOverlayPresenter

    func makeViewModel(
        transientErrorDisplayDuration: Duration = .milliseconds(10)
    ) -> AppViewModel {
        AppViewModel(
            audioEngine: audio,
            transcriptionManager: transcriber,
            grammarEnhancer: enhancer,
            pasteManager: paster,
            overlayPanel: overlay,
            startsOperational: true,
            doneDisplayDuration: .milliseconds(1),
            transientErrorDisplayDuration: transientErrorDisplayDuration
        )
    }
}

private final class FakeAudioCapture: AudioCapturing, @unchecked Sendable {
    var onDevicesChanged: (@Sendable () -> Void)?
    var onFailure: (@Sendable (AudioEngineError) -> Void)?
    var onAudioLevel: (@Sendable (Float, UInt64) -> Void)?
    var devices: [AudioInputDevice] = []

    private var sampleQueue: [[Float]]
    private var nextGeneration: UInt64 = 0

    init(samples: [[Float]]) {
        sampleQueue = samples
    }

    func availableInputDevices() -> [AudioInputDevice] {
        devices
    }

    func setInputDevice(_ deviceID: AudioDeviceID?) -> Result<Void, AudioEngineError> {
        .success(())
    }

    func prepare() -> Result<Void, AudioEngineError> {
        .success(())
    }

    func startCapture() async -> Result<CaptureHandle, AudioEngineError> {
        nextGeneration += 1
        return .success(CaptureHandle(generation: nextGeneration))
    }

    func waitForCaptureToSettle(
        handle: CaptureHandle,
        idleWindow: Duration,
        maxWait: Duration,
        pollInterval: Duration
    ) async {}

    func stopCapture(handle: CaptureHandle) async -> [Float]? {
        guard !sampleQueue.isEmpty else { return nil }
        return sampleQueue.removeFirst()
    }

    func shutdown() -> Result<Void, AudioEngineError> {
        .success(())
    }
}

private final class FakeTranscriber: Transcribing, @unchecked Sendable {
    enum Behavior {
        case success(String)
        case failure(any Error)
        case suspended
    }

    private var behaviors: [Behavior]
    private var suspendedContinuation: CheckedContinuation<String, any Error>?
    private(set) var receivedSamples: [[Float]] = []

    init(behaviors: [Behavior]) {
        self.behaviors = behaviors
    }

    var callCount: Int {
        receivedSamples.count
    }

    func loadModels(progressHandler: @escaping @Sendable (Double) -> Void) async throws {
        progressHandler(1)
    }

    func transcribe(samples: [Float]) async throws -> String {
        receivedSamples.append(samples)
        guard !behaviors.isEmpty else {
            throw TestFailure.missingBehavior
        }

        switch behaviors.removeFirst() {
        case .success(let text):
            return text
        case .failure(let error):
            throw error
        case .suspended:
            return try await withCheckedThrowingContinuation { continuation in
                suspendedContinuation = continuation
            }
        }
    }

    func resumeSuspended(with result: Result<String, any Error>) {
        let continuation = suspendedContinuation
        suspendedContinuation = nil
        continuation?.resume(with: result)
    }
}

private final class FakeEnhancer: TranscriptEnhancing, @unchecked Sendable {
    private var results: [EnhancementResult]
    private(set) var receivedTexts: [String] = []

    init(results: [EnhancementResult]) {
        self.results = results
    }

    func enhance(
        text: String,
        model: EnhancedModel,
        provider: EnhancedProvider,
        openAIConfiguration: GrammarEnhancer.OpenAIConfiguration,
        prompt: String
    ) async -> EnhancementResult {
        receivedTexts.append(text)
        guard !results.isEmpty else {
            return EnhancementResult(
                text: text,
                effectiveModel: model.rawValue,
                providerDisplayName: provider.displayName,
                didSucceed: false,
                warning: "Missing synthetic enhancement result."
            )
        }
        return results.removeFirst()
    }

    func cancelActiveEnhancement() {}
}

@MainActor
private final class FakeTextPaster: TextPasting {
    private(set) var pastedTexts: [String] = []
    private var outcomes: [PasteOutcome]

    init(outcomes: [PasteOutcome]) {
        self.outcomes = outcomes
    }

    func pasteText(_ text: String) -> PasteOutcome {
        let outcome = outcomes.isEmpty ? .pasted : outcomes.removeFirst()
        if outcome == .pasted {
            pastedTexts.append(text)
        }
        return outcome
    }

    func flushPendingRestore() {}
}

@MainActor
private final class FakeOverlayPresenter: OverlayPresenting {
    private(set) var shownStates: [OverlayState] = []

    var didShowDone: Bool {
        shownStates.contains {
            if case .done = $0 {
                return true
            }
            return false
        }
    }

    var doneCount: Int {
        shownStates.count {
            if case .done = $0 {
                return true
            }
            return false
        }
    }

    func didShowError(_ message: String) -> Bool {
        shownStates.contains {
            if case .error(let actualMessage) = $0 {
                return actualMessage == message
            }
            return false
        }
    }

    func show(state: OverlayState) {
        shownStates.append(state)
    }

    func updateAudioLevel(_ level: Float) {}

    func dismiss() {}
}

private enum TestFailure: Error {
    case expected
    case missingBehavior
}
