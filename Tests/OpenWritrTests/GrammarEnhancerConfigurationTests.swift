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
            "--model", "gpt-6-luna",
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

    @Test(arguments: EnhancedModel.allCases)
    func currentAndPreviousSelectionsRestore(model: EnhancedModel) {
        #expect(EnhancedModel.restored(from: model.rawValue) == model)
        if let previousID = model.previousModelID {
            #expect(EnhancedModel.restored(from: previousID) == model)
            let original = ["copilot:\(previousID)": "Synthetic custom prompt"]
            let migrated = EnhancedModel.migratingCopilotPrompts(original)
            #expect(migrated["copilot:\(model.rawValue)"] == "Synthetic custom prompt")
            #expect(migrated["copilot:\(previousID)"] == "Synthetic custom prompt")
        }
        #expect(EnhancedModel.restored(from: "unknown-model") == nil)
    }

    @Test func promptMigrationPreservesExistingTargetsAndOtherProviders() {
        let original = [
            "copilot:gpt-5.6-luna": "Old Luna custom prompt",
            "copilot:claude-haiku-4.5": "Old Haiku custom prompt",
            "copilot:claude-haiku-5.5": "New Haiku custom prompt",
            "openAICompatible:gpt-5-mini": "Endpoint custom prompt"
        ]
        let migrated = EnhancedModel.migratingCopilotPrompts(original)
        #expect(migrated["copilot:gpt-6-luna"] == original["copilot:gpt-5.6-luna"])
        for (key, value) in original {
            #expect(migrated[key] == value)
        }
        #expect(migrated["openAICompatible:gpt-5.4-mini"] == nil)
        #expect(EnhancedModel.migratingCopilotPrompts(migrated) == migrated)
    }

    @Test func currentStandardContextPricing() {
        #expect(EnhancedModel.luna.pricingSummary == "$0.10 input / $0.50 output")
        #expect(EnhancedModel.claudeHaiku.pricingSummary == "$0.10 input / $0.50 output")
        #expect(EnhancedModel.geminiFlash.pricingSummary == "$0.75 input / $3.75 output")
        #expect(EnhancedModel.gptMini.pricingSummary == "$0.75 input / $4.50 output")
        #expect(EnhancedModel.maiFlash.pricingSummary == "$0.20 input / $1.20 output")
        #expect(EnhancedModel.claudeHaiku.priceIndicator == "$")
        #expect(EnhancedModel.gptMini.priceIndicator == "$$")
    }
}
