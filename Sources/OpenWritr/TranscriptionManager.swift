import Foundation
import FluidAudio

protocol Transcribing: Sendable {
    func loadModels(progressHandler: @escaping @Sendable (Double) -> Void) async throws
    func transcribe(samples: [Float]) async throws -> String
}

enum TranscriptionInput {
    /// The ASR model rejects input shorter than one second of 16 kHz audio.
    static let minimumSampleCount = 16_000

    static func paddedIfNeeded(_ samples: [Float]) -> [Float] {
        guard samples.count < minimumSampleCount else { return samples }
        return samples + repeatElement(0, count: minimumSampleCount - samples.count)
    }
}

final class TranscriptionManager: Transcribing, @unchecked Sendable {
    private var asrManager: AsrManager?

    func loadModels(progressHandler: @escaping @Sendable (Double) -> Void) async throws {
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        progressHandler(0.7)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.asrManager = manager
        progressHandler(1.0)
    }

    func transcribe(samples: [Float]) async throws -> String {
        guard let manager = asrManager else {
            throw TranscriptionError.notReady
        }
        let input = TranscriptionInput.paddedIfNeeded(samples)
        // Every recording is an independent utterance, so decode from a fresh state.
        var decoderState = TdtDecoderState.make(decoderLayers: 2)
        let result = try await manager.transcribe(input, decoderState: &decoderState)
        return result.text
    }
}

enum TranscriptionError: Error, LocalizedError {
    case notReady

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "Transcription model not loaded yet"
        }
    }
}
