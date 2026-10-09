import Testing
@testable import OpenWritr

@Suite("Copilot cleanup configuration")
struct GrammarEnhancerConfigurationTests {
    @Test func lunaUsesExplicitLowReasoning() {
        #expect(GrammarEnhancer.copilotArguments(
            executablePath: "/synthetic/bin/copilot",
            requestPrompt: "Synthetic cleanup request",
            model: EnhancedModel.luna.rawValue
        ) == [
            "/synthetic/bin/copilot",
            "-p", "Synthetic cleanup request",
            "-s",
            "--model", "gpt-5.6-luna",
            "--no-custom-instructions",
            "--disable-builtin-mcps",
            "--reasoning-effort", "low"
        ])
    }

    @Test(arguments: EnhancedModel.allCases.filter { $0 != .luna })
    func otherModelsRetainExistingArguments(model: EnhancedModel) {
        #expect(GrammarEnhancer.copilotArguments(
            executablePath: "/synthetic/bin/copilot",
            requestPrompt: "Synthetic cleanup request",
            model: model.rawValue
        ) == [
            "/synthetic/bin/copilot",
            "-p", "Synthetic cleanup request",
            "-s",
            "--model", model.rawValue,
            "--no-custom-instructions",
            "--disable-builtin-mcps"
        ])
    }

    @Test func copilotDeadlineAccommodatesSlowStartupButRemainsBounded() {
        #expect(GrammarEnhancer.defaultCopilotTimeout == .seconds(90))
    }
}
