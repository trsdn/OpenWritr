import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

enum AppleIntelligenceAvailability: Sendable, Equatable {
    case available
    case unavailable(String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .available:
            return "Runs locally on this Mac using Apple Intelligence."
        case .unavailable(let reason):
            return reason
        }
    }
}

struct AppleIntelligenceEnhancer: Sendable {
    static let modelName = "Apple On-Device Foundation Model"
    private let cleanupPolicy = AppleCleanupPolicy()

    static func currentAvailability() -> AppleIntelligenceAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return availabilityOnSupportedOS()
        }
        #endif
        return .unavailable("Apple Intelligence cleanup requires macOS 26 or later.")
    }

    func enhance(text: String, prompt: String) async -> EnhancementResult {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return await enhanceOnSupportedOS(text: text, prompt: prompt)
        }
        #endif
        return failure(text: text, warning: "Apple Intelligence cleanup requires macOS 26 or later.")
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func availabilityOnSupportedOS() -> AppleIntelligenceAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable("Apple Intelligence is not supported on this Mac.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Enable Apple Intelligence in System Settings to use local cleanup.")
        case .unavailable(.modelNotReady):
            return .unavailable("The Apple Intelligence model is still downloading or preparing.")
        case .unavailable:
            return .unavailable("Apple Intelligence is currently unavailable.")
        }
    }

    @available(macOS 26.0, *)
    private func enhanceOnSupportedOS(text: String, prompt: String) async -> EnhancementResult {
        guard Self.currentAvailability().isAvailable else {
            return failure(text: text, warning: Self.currentAvailability().message)
        }
        if cleanupPolicy.isFillerOnly(text) {
            return EnhancementResult(
                text: "",
                effectiveModel: Self.modelName,
                providerDisplayName: EnhancedProvider.appleIntelligence.displayName,
                didSucceed: true,
                warning: nil
            )
        }

        do {
            let session = LanguageModelSession(instructions: prompt)
            let firstStart = ContinuousClock.now
            let response = try await session.respond(
                to: cleanupPolicy.firstPassPrompt(for: text)
            )
            let firstPass = cleanupPolicy.candidate(
                source: text,
                output: response.content,
                durationMilliseconds: elapsedMilliseconds(since: firstStart)
            )
            var repair: AppleCleanupCandidate?
            if cleanupPolicy.shouldRepair(firstPass.report) {
                do {
                    let repairStart = ContinuousClock.now
                    let repairSession = LanguageModelSession(
                        instructions: cleanupPolicy.repairInstructions
                    )
                    let repairedResponse = try await repairSession.respond(
                        to: cleanupPolicy.repairPrompt(source: text, candidate: firstPass)
                    )
                    repair = cleanupPolicy.candidate(
                        source: text,
                        output: cleanupPolicy.normalizedRepairOutput(
                            source: text,
                            output: repairedResponse.content
                        ),
                        durationMilliseconds: elapsedMilliseconds(since: repairStart)
                    )
                } catch {
                    repair = nil
                }
            }
            let selection = cleanupPolicy.select(
                source: text,
                firstPass: firstPass,
                repair: repair
            )
            return EnhancementResult(
                text: selection.selected.text,
                effectiveModel: Self.modelName,
                providerDisplayName: EnhancedProvider.appleIntelligence.displayName,
                didSucceed: true,
                warning: integrityWarning(for: selection.selected.report)
            )
        } catch {
            return failure(
                text: text,
                warning: "Apple Intelligence cleanup failed: \(error.localizedDescription)"
            )
        }
    }
    #endif

    private func failure(text: String, warning: String) -> EnhancementResult {
        EnhancementResult(
            text: text,
            effectiveModel: Self.modelName,
            providerDisplayName: EnhancedProvider.appleIntelligence.displayName,
            didSucceed: false,
            warning: warning
        )
    }

    private func integrityWarning(for report: CleanupIntegrityReport) -> String? {
        guard !report.isValid else { return nil }
        let categories = Set(report.violations.map(\.category.rawValue)).sorted()
        return "Apple Intelligence cleanup retained integrity risks: \(categories.joined(separator: ", "))."
    }

    private func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now)
        return Int(duration.components.seconds * 1_000)
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
