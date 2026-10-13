import Testing
@testable import OpenWritr

@Suite("Microphone recovery policy")
struct MicrophoneRecoveryPolicyTests {
    private let policy = MicrophoneRecoveryPolicy()

    @Test func waitsLongerAfterEachRecoveryUpToACap() {
        let delays = (0...8).map { policy.delayMilliseconds(afterAttempts: $0) }

        #expect(delays == [250, 500, 750, 1000, 1250, 1500, 1500, 1500, 1500])
        #expect(policy.delayMilliseconds(afterAttempts: -3) == 250)
    }

    @Test func givesBluetoothHeadsetsSeveralSecondsToSettle() {
        // The first three attempts used to be the whole budget (about 0.75 s of waiting).
        let total = (0..<policy.maximumAttempts).reduce(0) {
            $0 + policy.delayMilliseconds(afterAttempts: $1)
        }

        #expect(policy.maximumAttempts == 6)
        #expect(total >= 5_000)
    }

    @Test func allowsAttemptsOnlyBelowTheMaximum() {
        #expect(policy.allowsAnotherAttempt(after: 0))
        #expect(policy.allowsAnotherAttempt(after: policy.maximumAttempts - 1))
        #expect(!policy.allowsAnotherAttempt(after: policy.maximumAttempts))
    }

    @Test func aStableEngineStartsAFreshBurst() {
        #expect(policy.attemptsCounted(4, sinceLastRecovery: .seconds(3)) == 0)
        #expect(policy.attemptsCounted(4, sinceLastRecovery: .seconds(10)) == 0)
    }

    @Test func anUnstableEngineKeepsItsCount() {
        #expect(policy.attemptsCounted(4, sinceLastRecovery: .milliseconds(900)) == 4)
        #expect(policy.attemptsCounted(2, sinceLastRecovery: nil) == 2)
    }

    @Test func deviceFormatSummaryNeverContainsNamesOrUIDs() {
        for device in AudioEngine.availableInputDevices() {
            let summary = AudioDiagnostics.deviceFormatSummary(for: device.id)

            #expect(summary.hasPrefix("transport="))
            #expect(summary.contains("channels="))
            #expect(summary.contains("rate="))
            #expect(!summary.contains(device.name))
            #expect(!summary.contains(device.uid))
        }
    }
}
