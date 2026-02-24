import Foundation
import FluidAudio

final class TranscriptionManager: @unchecked Sendable {
    private var asrManager: AsrManager?

    func loadModels(progressHandler: @escaping @Sendable (Double) -> Void) async throws {
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        progressHandler(0.7)
        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
        self.asrManager = manager
        progressHandler(1.0)
    }

    func transcribe(samples: [Float]) async throws -> String {
        guard let manager = asrManager else {
            throw TranscriptionError.notReady
        }
        let result = try await manager.transcribe(samples, source: .microphone)
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
