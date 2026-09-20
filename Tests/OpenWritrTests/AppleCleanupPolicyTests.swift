import Testing
@testable import OpenWritr

@Suite("AppleCleanupPolicy")
struct AppleCleanupPolicyTests {
    private let policy = AppleCleanupPolicy()

    @Test func fillerOnlyTextIsDetected() {
        #expect(policy.isFillerOnly("äh ähm"))
        #expect(!policy.isFillerOnly("äh, wir starten morgen"))
    }

    @Test func repairIsOnlyRequestedForInvalidReports() {
        let validator = CleanupIntegrityValidator()
        let good = validator.validate(source: "It is 5 pm.", candidate: "It is 5 pm.")
        let bad = validator.validate(source: "It is 5 pm.", candidate: "It is 6 pm.")
        #expect(!policy.shouldRepair(good))
        #expect(policy.shouldRepair(bad))
    }
}
