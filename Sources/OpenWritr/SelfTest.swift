import AVFoundation
import Foundation

/// Non-interactive check of the shipped transcription pipeline.
///
/// Usage: `OpenWritr --self-test <audio-file> <expected words…>`
///
/// Loads the speech model, transcribes the file with the same code path as a
/// recording, and exits 0 only if every expected word appears in the transcript.
/// It touches no preferences, no microphone, and no other apps.
enum SelfTest {
    static func run(arguments: [String]) -> Never {
        guard let flag = arguments.firstIndex(of: "--self-test"),
              arguments.count > flag + 1
        else {
            fail("usage: OpenWritr --self-test <audio-file> <expected words…>")
        }
        let path = arguments[flag + 1]
        let expected = Array(arguments.dropFirst(flag + 2))

        Task {
            do {
                let samples = try loadSamples(path: path)
                print("self-test: loaded \(samples.count) samples (16 kHz mono)")
                let manager = TranscriptionManager()
                try await manager.loadModels { _ in }
                let transcript = try await manager.transcribe(samples: samples)
                print("self-test: transcript=\"\(transcript)\"")
                let missing = missingWords(expected: expected, in: transcript)
                if missing.isEmpty {
                    print("self-test: PASS")
                    exit(0)
                }
                fail("missing expected words: \(missing.joined(separator: ", "))")
            } catch {
                fail("\(error.localizedDescription)")
            }
        }
        dispatchMain()
    }

    /// Expected words that are absent from the transcript, ignoring case and punctuation.
    static func missingWords(expected: [String], in transcript: String) -> [String] {
        let words = Set(normalizedWords(transcript))
        return expected.map { $0.lowercased() }.filter { !words.contains($0) }
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("self-test: FAIL \(message)\n".utf8))
        exit(1)
    }

    private static func loadSamples(path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: file.processingFormat, to: target),
            let input = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
            )
        else {
            throw SelfTestError.unreadableAudio
        }
        try file.read(into: input)
        let ratio = target.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw SelfTestError.unreadableAudio
        }
        var supplied = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        guard let channel = output.floatChannelData?[0] else { throw SelfTestError.unreadableAudio }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

enum SelfTestError: Error, LocalizedError {
    case unreadableAudio

    var errorDescription: String? { "The audio file could not be read or converted" }
}
