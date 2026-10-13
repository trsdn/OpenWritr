import Foundation

/// How long and how often the audio engine rebuilds itself after a configuration change.
///
/// A Bluetooth headset switches to its microphone profile when capture starts, which can change
/// the format several times over a few seconds. Giving up after three quick attempts made
/// dictation fail on such devices, so attempts back off and are counted per burst of changes
/// rather than per capture.
struct MicrophoneRecoveryPolicy: Equatable, Sendable {
    var maximumAttempts = 6
    var baseDelay: Duration = .milliseconds(250)
    var delayStep: Duration = .milliseconds(250)
    var maximumDelay: Duration = .milliseconds(1500)
    /// A recovered engine that then runs this long without another change ends the burst.
    var stableAfter: Duration = .seconds(3)

    /// The wait before judging a configuration change, growing with each recovery in the burst.
    func delay(afterAttempts attempts: Int) -> Duration {
        min(baseDelay + delayStep * max(attempts, 0), maximumDelay)
    }

    func delayMilliseconds(afterAttempts attempts: Int) -> Int {
        let parts = delay(afterAttempts: attempts).components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }

    func allowsAnotherAttempt(after attempts: Int) -> Bool {
        attempts < maximumAttempts
    }

    /// The attempts still counted against the burst: none once the engine has been stable.
    func attemptsCounted(_ attempts: Int, sinceLastRecovery elapsed: Duration?) -> Int {
        guard let elapsed, elapsed >= stableAfter else { return attempts }
        return 0
    }
}
