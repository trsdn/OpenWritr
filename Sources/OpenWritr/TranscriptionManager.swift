import Foundation
import FluidAudio

final class TranscriptionManager: @unchecked Sendable {
    private var asrManager: AsrManager?

    func loadModels(progressHandler: @escaping @Sendable (Double) -> Void) async throws {
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        progressHandler(0.7)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.asrManager = manager
        progressHandler(1.0)
    }

    /// The ASR model rejects input shorter than one second of 16 kHz audio.
    private static let minimumSampleCount = 16_000

    func transcribe(samples: [Float]) async throws -> String {
        guard let manager = asrManager else {
            throw TranscriptionError.notReady
        }
        var input = samples
        if input.count < Self.minimumSampleCount {
            input.append(contentsOf: repeatElement(0, count: Self.minimumSampleCount - input.count))
        }
        let result = try await manager.transcribe(input, source: .microphone)
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
