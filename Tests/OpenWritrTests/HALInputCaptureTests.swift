import CoreAudio
import Foundation
import Testing
@testable import OpenWritr

@Suite("Input sample decoding")
struct HALSampleDecodingTests {
    private func format(
        bits: UInt32,
        flags: AudioFormatFlags,
        id: AudioFormatID = kAudioFormatLinearPCM,
        channels: UInt32 = 1,
        bytesPerFrame: UInt32? = nil
    ) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: id, mFormatFlags: flags, mBytesPerPacket: 0, mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame ?? bits / 8 * channels, mChannelsPerFrame: channels,
            mBitsPerChannel: bits, mReserved: 0
        )
    }

    @Test func recognisesSupportedSampleTypes() {
        #expect(HALSampleKind(format(bits: 32, flags: kAudioFormatFlagIsFloat)) == .float32)
        #expect(HALSampleKind(format(bits: 16, flags: kAudioFormatFlagIsSignedInteger)) == .int16)
        #expect(HALSampleKind(format(bits: 32, flags: kAudioFormatFlagIsSignedInteger)) == .int32)
        #expect(HALSampleKind(format(bits: 16, flags: kAudioFormatFlagIsSignedInteger, channels: 2)) == .int16)
        let nonInterleaved = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved
        #expect(HALSampleKind(format(bits: 32, flags: nonInterleaved, channels: 2, bytesPerFrame: 4)) == .float32)
    }

    @Test func rejectsSamplesPaddedInsideAWiderFrame() {
        #expect(HALSampleKind(format(bits: 16, flags: kAudioFormatFlagIsSignedInteger, bytesPerFrame: 4)) == nil)
        #expect(HALSampleKind(format(bits: 32, flags: kAudioFormatFlagIsSignedInteger, bytesPerFrame: 8)) == nil)
        #expect(HALSampleKind(format(bits: 16, flags: kAudioFormatFlagIsSignedInteger, bytesPerFrame: 0)) == nil)
    }

    @Test func rejectsUnreadableFormats() {
        #expect(HALSampleKind(format(bits: 24, flags: kAudioFormatFlagIsSignedInteger)) == nil)
        #expect(HALSampleKind(format(bits: 64, flags: kAudioFormatFlagIsFloat)) == nil)
        #expect(HALSampleKind(format(bits: 16, flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsBigEndian)) == nil)
        #expect(HALSampleKind(format(bits: 0, flags: 0, id: kAudioFormatMPEG4AAC)) == nil)
    }

    @Test func decodesMonoFloat() {
        let input: [Float] = [0.25, -0.5, 1]
        let output = input.withUnsafeBytes {
            HALSampleConverter.firstChannel(of: $0.baseAddress!, byteCount: $0.count, channels: 1, kind: .float32)
        }
        #expect(output == input)
    }

    @Test func decodesFirstChannelOfInterleavedInt16() {
        let input: [Int16] = [16_384, 1, -16_384, 2, -32_768, 3]
        let output = input.withUnsafeBytes {
            HALSampleConverter.firstChannel(of: $0.baseAddress!, byteCount: $0.count, channels: 2, kind: .int16)
        }
        #expect(output == [0.5, -0.5, -1])
    }

    @Test func decodesFirstChannelOfInterleavedInt32() {
        let input: [Int32] = [1_073_741_824, 7, -1_073_741_824, 8]
        let output = input.withUnsafeBytes {
            HALSampleConverter.firstChannel(of: $0.baseAddress!, byteCount: $0.count, channels: 2, kind: .int32)
        }
        #expect(output == [0.5, -0.5])
    }

    @Test func ignoresATrailingPartialFrame() {
        let input: [Int16] = [100, 200, 300]
        let output = input.withUnsafeBytes {
            HALSampleConverter.firstChannel(of: $0.baseAddress!, byteCount: $0.count, channels: 2, kind: .int16)
        }
        #expect(output.count == 1)
    }

    @Test func emptyInputYieldsNoSamples() {
        let byte: UInt8 = 0
        let output = withUnsafeBytes(of: byte) {
            HALSampleConverter.firstChannel(of: $0.baseAddress!, byteCount: 0, channels: 1, kind: .float32)
        }
        #expect(output.isEmpty)
    }
}

@Suite("Input-only capture")
struct HALInputCaptureTests {
    @Test func startingOnAMissingDeviceFailsAndLeavesNothingRunning() {
        let capture = HALInputCapture(
            deviceID: 999_999,
            handler: { _ in Issue.record("No audio may be delivered for a missing device") },
            deviceLost: {}
        )

        #expect(throws: AudioEngineError.self) {
            try capture.start()
        }
        #expect(!capture.isRunning)
    }

    @Test func stoppingACaptureThatNeverStartedIsSafe() {
        let capture = HALInputCapture(deviceID: 999_999, handler: { _ in }, deviceLost: {})

        capture.stop()
        capture.stop()

        #expect(!capture.isRunning)
    }

    @Test func selectingAMissingDeviceIsRejected() {
        let engine = AudioEngine()
        defer { _ = engine.shutdown() }

        let result = engine.setInputDevice(999_999)

        #expect(throws: AudioEngineError.self) {
            try result.get()
        }
    }

    /// Needs a real microphone and permission, so it only runs when asked for:
    /// `OPENWRITR_HARDWARE_TESTS=1 swift test --filter HALInputCaptureTests`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENWRITR_HARDWARE_TESTS"] == "1"))
    func capturesRealAudioFromTheDefaultInput() async throws {
        let engine = AudioEngine()
        defer { _ = engine.shutdown() }
        let result = await engine.startCapture()
        let handle = try result.get()

        try await Task.sleep(for: .seconds(1.5))
        let samples = try #require(await engine.stopCapture(handle: handle))

        #expect(samples.count > 16_000, "At least one second of 16 kHz audio is expected")
        #expect(samples.contains { $0 != 0 }, "The capture must contain signal, not only zeros")
    }
}
