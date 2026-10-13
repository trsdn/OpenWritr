import CoreAudio
import Foundation
import Testing
@testable import OpenWritr

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
