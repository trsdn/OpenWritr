import Foundation

struct EnhancementResult: Sendable {
    let text: String
    let effectiveModel: String
    let providerDisplayName: String
    let didSucceed: Bool
    let warning: String?
}

enum EnhancedProvider: String, CaseIterable, Identifiable {
    case copilot = "copilot"
    case openAICompatible = "openai-compatible"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .copilot: return "GitHub Copilot"
        case .openAICompatible: return "OpenAI-Compatible API"
        }
    }

    static var defaultOpenAIBaseURL: String {
        let env = ProcessInfo.processInfo.environment
        for key in ["LLM_OPENAI_BASE_URL", "OPENAI_BASE_URL", "OPENAI_API_BASE"] {
            if let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return "http://127.0.0.1:8080/v1"
    }

    static var defaultOpenAIAPIKey: String? {
        let env = ProcessInfo.processInfo.environment
        for key in ["LLM_OPENAI_API_KEY", "OPENAI_API_KEY"] {
            if let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static let defaultOpenAIModelOverride = "accounts/msft/routers/fmfeto88"
}

enum EnhancedModel: String, CaseIterable, Identifiable {
    case gpt4_1 = "gpt-4.1"
    case claudeHaiku = "claude-haiku-4.5"
    case gptMini = "gpt-5-mini"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gpt4_1: return "GPT-4.1"
        case .claudeHaiku: return "Claude Haiku 4.5"
        case .gptMini: return "GPT-5 Mini"
        }
    }
}

struct GrammarEnhancer: Sendable {
    static let defaultCleanupPrompt = "Clean up this speech transcript: fix grammar, spelling, and punctuation. Remove fillers, hesitations, and stuttering. Every sentence must end with proper punctuation. Preserve meaning, tone, and language. If the input mixes German and English, keep the original language of each word or phrase and do not translate technical terms, product names, commands, or domain-specific wording. If the input contains only filler words or hesitations with no meaningful content, return an empty string. Return only the corrected text."

    struct OpenAIConfiguration: Sendable {
        let baseURL: String
        let apiKey: String?
        let modelOverride: String?
    }

    func effectiveModelName(
        model: EnhancedModel,
        provider: EnhancedProvider,
        openAIConfiguration: OpenAIConfiguration
    ) -> String {
        switch provider {
        case .copilot:
            return model.rawValue
        case .openAICompatible:
            return normalizedModelName(model, override: openAIConfiguration.modelOverride)
        }
    }

    func enhance(
        text: String,
        model: EnhancedModel,
        provider: EnhancedProvider,
        openAIConfiguration: OpenAIConfiguration,
        prompt: String
    ) async -> EnhancementResult {
        switch provider {
        case .copilot:
            return await Task.detached {
                self.runCopilot(text: text, model: model.rawValue, prompt: prompt)
            }.value
        case .openAICompatible:
            return await runOpenAICompatible(text: text, model: model, configuration: openAIConfiguration, prompt: prompt)
        }
    }

    // MARK: - Private

    private struct ChatCompletionRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let temperature: Double
    }

    private struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: MessageContent
            }

            let message: Message
        }

        struct MessageContent: Decodable {
            struct Part: Decodable {
                let text: String?
            }

            let text: String

            init(from decoder: Decoder) throws {
                let singleValue = try decoder.singleValueContainer()
                if let string = try? singleValue.decode(String.self) {
                    text = string
                    return
                }
                if let parts = try? singleValue.decode([Part].self) {
                    text = parts.compactMap(\ .text).joined(separator: "\n")
                    return
                }
                text = ""
            }
        }

        let choices: [Choice]
    }

    private func normalizedModelName(_ model: EnhancedModel, override: String?) -> String {
        let override = override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return override.isEmpty ? model.rawValue : override
    }

    private func chatCompletionsURL(from baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else { return nil }

        let pathParts = components.path.split(separator: "/").map(String.init)
        if Array(pathParts.suffix(2)) == ["chat", "completions"] {
            return components.url
        }

        var updatedPathParts = pathParts
        if updatedPathParts.last != "v1" {
            updatedPathParts.append("v1")
        }
        updatedPathParts.append(contentsOf: ["chat", "completions"])
        components.path = "/" + updatedPathParts.joined(separator: "/")
        return components.url
    }

    private func runOpenAICompatible(
        text: String,
        model: EnhancedModel,
        configuration: OpenAIConfiguration,
        prompt: String
    ) async -> EnhancementResult {
        let effectiveModel = normalizedModelName(model, override: configuration.modelOverride)
        guard let url = chatCompletionsURL(from: configuration.baseURL) else {
            return EnhancementResult(
                text: text,
                effectiveModel: effectiveModel,
                providerDisplayName: EnhancedProvider.openAICompatible.displayName,
                didSucceed: false,
                warning: "OpenAI-compatible enhancement is misconfigured. Using raw transcript."
            )
        }

        let requestBody = ChatCompletionRequest(
            model: effectiveModel,
            messages: [
                .init(role: "system", content: prompt),
                .init(role: "user", content: text),
            ],
            temperature: 0.2
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = configuration.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return EnhancementResult(
                    text: text,
                    effectiveModel: effectiveModel,
                    providerDisplayName: EnhancedProvider.openAICompatible.displayName,
                    didSucceed: false,
                    warning: "OpenAI-compatible enhancement returned an invalid response. Using raw transcript."
                )
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                return EnhancementResult(
                    text: text,
                    effectiveModel: effectiveModel,
                    providerDisplayName: EnhancedProvider.openAICompatible.displayName,
                    didSucceed: false,
                    warning: "OpenAI-compatible enhancement failed with HTTP \(httpResponse.statusCode). Using raw transcript."
                )
            }

            guard let decoded = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data) else {
                return EnhancementResult(
                    text: text,
                    effectiveModel: effectiveModel,
                    providerDisplayName: EnhancedProvider.openAICompatible.displayName,
                    didSucceed: false,
                    warning: "OpenAI-compatible enhancement returned unreadable data. Using raw transcript."
                )
            }

            let output = decoded.choices.first?.message.content.text
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return EnhancementResult(
                text: output.isEmpty ? text : output,
                effectiveModel: effectiveModel,
                providerDisplayName: EnhancedProvider.openAICompatible.displayName,
                didSucceed: true,
                warning: nil
            )
        } catch {
            return EnhancementResult(
                text: text,
                effectiveModel: effectiveModel,
                providerDisplayName: EnhancedProvider.openAICompatible.displayName,
                didSucceed: false,
                warning: "OpenAI-compatible enhancement failed: \(error.localizedDescription). Using raw transcript."
            )
        }
    }

    private func findCopilotBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/copilot",
            "/usr/local/bin/copilot",
        ]
        for p in candidates {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            for suffix in ["/.local/bin/copilot", "/bin/copilot"] {
                let p = home + suffix
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        // Fallback: which
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", "copilot"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        do {
            try which.run()
            which.waitUntilExit()
            let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) { return path }
        } catch {}
        return nil
    }

    private func runCopilot(text: String, model: String, prompt: String) -> EnhancementResult {
        guard let bin = findCopilotBinary() else {
            return EnhancementResult(
                text: text,
                effectiveModel: model,
                providerDisplayName: EnhancedProvider.copilot.displayName,
                didSucceed: false,
                warning: "Copilot CLI was not found. Using raw transcript."
            )
        }

        let requestPrompt = "\(prompt)\n\n\(text)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = [
            "-p", requestPrompt,
            "-s",
            "--model", model,
            "--no-custom-instructions",
            "--disable-builtin-mcps",
        ]
        process.environment = ProcessInfo.processInfo.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return EnhancementResult(
                text: text,
                effectiveModel: model,
                providerDisplayName: EnhancedProvider.copilot.displayName,
                didSucceed: false,
                warning: "Copilot enhancement could not start: \(error.localizedDescription). Using raw transcript."
            )
        }

        // Enforce a timeout so the app doesn't hang
        let timeout = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)

        process.waitUntilExit()
        timeout.cancel()

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            let detail = stderrText.isEmpty ? "Copilot exited with code \(process.terminationStatus)." : stderrText
            return EnhancementResult(
                text: text,
                effectiveModel: model,
                providerDisplayName: EnhancedProvider.copilot.displayName,
                didSucceed: false,
                warning: "Copilot enhancement failed: \(detail) Using raw transcript."
            )
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return EnhancementResult(
            text: output.isEmpty ? text : output,
            effectiveModel: model,
            providerDisplayName: EnhancedProvider.copilot.displayName,
            didSucceed: true,
            warning: nil
        )
    }
}
