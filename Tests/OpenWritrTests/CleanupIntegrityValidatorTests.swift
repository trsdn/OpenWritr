import Testing
@testable import OpenWritr

@Suite("CleanupIntegrityValidator")
struct CleanupIntegrityValidatorTests {
    private let validator = CleanupIntegrityValidator()

    private func categories(source: String, candidate: String) -> Set<CleanupIntegrityCategory> {
        Set(validator.validate(source: source, candidate: candidate).violations.map(\.category))
    }

    @Test func identicalCleanTextIsValid() {
        let report = validator.validate(
            source: "Wir treffen uns am Montag im Büro.",
            candidate: "Wir treffen uns am Montag im Büro."
        )
        #expect(report.isValid)
        #expect(report.weightedRisk == 0)
    }

    @Test func changedNumberIsAnError() {
        let report = validator.validate(
            source: "The meeting is at 15:30 in room 42.",
            candidate: "The meeting is at 16:30 in room 42."
        )
        #expect(!report.isValid)
        #expect(report.violations.contains { $0.category == .factualToken && $0.severity == .error })
    }

    @Test func droppedNumberIsAnError() {
        #expect(categories(source: "We shipped version 1.6.4 today.", candidate: "We shipped it today.")
            .contains(.factualToken))
    }

    @Test func droppedNegationIsAnError() {
        let report = validator.validate(
            source: "I do not want to send it.",
            candidate: "I want to send it."
        )
        #expect(!report.isValid)
        #expect(report.violations.contains { $0.category == .negation })
    }

    @Test func languageDriftIsAnError() {
        let report = validator.validate(
            source: "Das ist ein kurzer Test für die Diktierfunktion.",
            candidate: "This is a short test for the dictation feature."
        )
        #expect(!report.isValid)
        #expect(report.violations.contains { $0.category == .languageDrift })
    }

    @Test func missingTerminalPunctuationIsOnlyAWarning() {
        let report = validator.validate(
            source: "Please send me the report tomorrow morning.",
            candidate: "Please send me the report tomorrow morning"
        )
        #expect(report.isValid)
        #expect(report.violations.contains { $0.category == .terminalPunctuation && $0.severity == .warning })
    }

    @Test func remainingFillerIsAWarning() {
        let report = validator.validate(
            source: "Ähm, wir starten morgen.",
            candidate: "Ähm, wir starten morgen."
        )
        #expect(report.violations.contains { $0.category == .filler && $0.severity == .warning })
        #expect(report.isValid)
    }

    @Test func riskWeightsErrorsAboveWarnings() {
        let clean = validator.validate(source: "Call me at 10.", candidate: "Call me at 10.")
        let broken = validator.validate(source: "Call me at 10.", candidate: "Call me at 11.")
        #expect(broken.weightedRisk > clean.weightedRisk)
    }
}
