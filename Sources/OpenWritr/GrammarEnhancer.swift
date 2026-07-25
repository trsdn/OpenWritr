import Darwin
import Foundation
import os.log

private let grammarLog = Logger(subsystem: "com.openwritr.app", category: "GrammarEnhancer")

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



enum EnhancedModel: String, CaseIterable, Identifiable, Sendable {
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

enum GrammarEnhancementResult: Sendable, Equatable {
    case success(String)
    case failure(GrammarEnhancementError)
}

enum GrammarEnhancementError: Error, LocalizedError, Sendable, Equatable {
    case copilotNotFound
    case nodeRuntimeNotFound
    case launchFailed(code: Int32)
    case processMonitoringFailed(code: Int32)
    case timedOut
    case nonzeroExit(status: Int32)
    case outputReadFailed
    case outputTooLarge
    case cancelled
    case alreadyInProgress

    var errorDescription: String? {
        switch self {
        case .copilotNotFound:
            return "GitHub Copilot CLI could not be found."
        case .nodeRuntimeNotFound:
            return "The Node.js runtime for GitHub Copilot CLI could not be found."
        case .launchFailed:
            return "GitHub Copilot CLI could not be started."
        case .processMonitoringFailed:
            return "GitHub Copilot CLI could not be monitored."
        case .timedOut:
            return "GitHub Copilot CLI timed out."
        case .nonzeroExit(let status):
            return "GitHub Copilot CLI exited with status \(status)."
        case .outputReadFailed:
            return "GitHub Copilot CLI output could not be read."
        case .outputTooLarge:
            return "GitHub Copilot CLI returned more text than OpenWritr can process."
        case .cancelled:
            return "GitHub Copilot enhancement was cancelled."
        case .alreadyInProgress:
            return "Another GitHub Copilot enhancement is already in progress."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .copilotNotFound:
            return "Install GitHub Copilot CLI, then restart OpenWritr."
        case .nodeRuntimeNotFound:
            return "Install Node.js alongside GitHub Copilot CLI, then restart OpenWritr."
        case .launchFailed, .processMonitoringFailed:
            return "Verify that GitHub Copilot CLI and Node.js are executable."
        case .timedOut:
            return "Try again, or verify that GitHub Copilot CLI responds in Terminal."
        case .nonzeroExit:
            return "Run copilot in Terminal to verify authentication and configuration."
        case .outputReadFailed, .outputTooLarge:
            return "Try the enhancement again."
        case .cancelled:
            return nil
        case .alreadyInProgress:
            return "Wait for the current enhancement to finish, then try again."
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

    func effectiveModelName(model: EnhancedModel, provider: EnhancedProvider, openAIConfiguration: OpenAIConfiguration) -> String {
        switch provider {
        case .copilot: return model.rawValue
        case .openAICompatible: return normalizedModelName(model, override: openAIConfiguration.modelOverride)
        }
    }

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
                text: output,
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


    private static let pollInterval = Duration.milliseconds(20)
    private static let outputDrainTimeout = Duration.seconds(1)
    private static let maximumOutputBytes = 16 * 1_024 * 1_024

    private let timeout: Duration
    private let terminationGracePeriod: Duration
    private let forcedTerminationWait: Duration
    private let processState: EnhancementProcessState

    init(
        timeout: Duration = .seconds(30),
        terminationGracePeriod: Duration = .seconds(1),
        forcedTerminationWait: Duration = .seconds(1)
    ) {
        self.timeout = max(timeout, .milliseconds(1))
        self.terminationGracePeriod = max(terminationGracePeriod, .zero)
        self.forcedTerminationWait = max(forcedTerminationWait, .zero)
        self.processState = EnhancementProcessState()
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
            let outcome = await runCopilot(text: text, model: model.rawValue, prompt: prompt)
            switch outcome {
            case .success(let output):
                return .init(text: output, effectiveModel: model.rawValue, providerDisplayName: provider.displayName, didSucceed: true, warning: nil)
            case .failure(let error):
                return .init(text: text, effectiveModel: model.rawValue, providerDisplayName: provider.displayName, didSucceed: false, warning: error.localizedDescription)
            }
        case .openAICompatible:
            return await runOpenAICompatible(text: text, model: model, configuration: openAIConfiguration, prompt: prompt)
        }
    }

    /// Closes the launch gate and synchronously force-kills the currently owned process group.
    func cancelActiveEnhancement() {
        processState.cancelAndPreventFutureLaunches { pid in
            Self.signalProcessGroup(pid: pid, signal: SIGKILL)
        }
    }

    // MARK: - Discovery

    private func findCopilotInstallation() -> Result<CopilotInstallation, GrammarEnhancementError> {
        let environment = ProcessInfo.processInfo.environment
        let binPaths = candidateBinPaths(environment: environment)
        let fileManager = FileManager.default
        var copilotBinPaths: [String] = []
        var nodeBinPaths: [String] = []

        for binPath in binPaths {
            if fileManager.isExecutableFile(atPath: "\(binPath)/copilot") {
                copilotBinPaths.append(binPath)
            }
            if fileManager.isExecutableFile(atPath: "\(binPath)/node") {
                nodeBinPaths.append(binPath)
            }
        }

        guard !copilotBinPaths.isEmpty else {
            return .failure(.copilotNotFound)
        }

        if let matchedBinPath = copilotBinPaths.first(where: nodeBinPaths.contains) {
            return .success(
                CopilotInstallation(
                    executablePath: "\(matchedBinPath)/copilot",
                    runtimeBinPath: matchedBinPath
                )
            )
        }

        guard let copilotBinPath = copilotBinPaths.first,
              let nodeBinPath = nodeBinPaths.first
        else {
            return .failure(.nodeRuntimeNotFound)
        }

        return .success(
            CopilotInstallation(
                executablePath: "\(copilotBinPath)/copilot",
                runtimeBinPath: nodeBinPath
            )
        )
    }

    private func candidateBinPaths(environment: [String: String]) -> [String] {
        var paths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/local/lib/nodejs/bin",
        ]

        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        paths.append(contentsOf: [
            "\(home)/.local/bin",
            "\(home)/bin",
        ])

        if let inheritedPath = environment["PATH"] {
            paths.append(contentsOf: inheritedPath.split(separator: ":").map(String.init))
        }

        var nvmRoots = ["\(home)/.nvm/versions/node"]
        if let nvmDirectory = environment["NVM_DIR"], !nvmDirectory.isEmpty {
            nvmRoots.insert(
                "\(NSString(string: nvmDirectory).expandingTildeInPath)/versions/node",
                at: 0
            )
        }
        for root in uniquePaths(nvmRoots) {
            paths.append(contentsOf: versionBinPaths(root: root, suffix: "bin"))
        }

        var fnmRoots: [String] = []
        if let fnmDirectory = environment["FNM_DIR"], !fnmDirectory.isEmpty {
            let expandedDirectory = NSString(string: fnmDirectory).expandingTildeInPath
            fnmRoots.append("\(expandedDirectory)/node-versions")
        }
        if let xdgDataHome = environment["XDG_DATA_HOME"], !xdgDataHome.isEmpty {
            let expandedDataHome = NSString(string: xdgDataHome).expandingTildeInPath
            fnmRoots.append("\(expandedDataHome)/fnm/node-versions")
        }
        fnmRoots.append(contentsOf: [
            "\(home)/.local/share/fnm/node-versions",
            "\(home)/Library/Application Support/fnm/node-versions",
            "\(home)/.fnm/node-versions",
        ])
        for root in uniquePaths(fnmRoots) {
            paths.append(contentsOf: versionBinPaths(root: root, suffix: "installation/bin"))
        }

        return uniquePaths(paths)
    }

    private func versionBinPaths(root: String, suffix: String) -> [String] {
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            return []
        }

        return versions
            .sorted { lhs, rhs in
                lhs.compare(rhs, options: .numeric) == .orderedDescending
            }
            .map { "\(root)/\($0)/\(suffix)" }
    }

    private func uniquePaths(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.compactMap { path in
            let normalizedPath = NSString(string: path).standardizingPath
            guard !normalizedPath.isEmpty, seen.insert(normalizedPath).inserted else {
                return nil
            }
            return normalizedPath
        }
    }

    // MARK: - Process execution

    private func runCopilot(text: String, model: String, prompt: String) async -> GrammarEnhancementResult {
        let operationID: UInt64
        switch processState.beginEnhancement(taskIsCancelled: Task.isCancelled) {
        case .started(let startedOperationID):
            operationID = startedOperationID
        case .cancelled:
            return .failure(.cancelled)
        case .alreadyInProgress:
            return .failure(.alreadyInProgress)
        }
        defer { processState.finishPendingLaunch(operationID: operationID) }

        let installation: CopilotInstallation
        switch findCopilotInstallation() {
        case .success(let discoveredInstallation):
            installation = discoveredInstallation
        case .failure(let error):
            return .failure(error)
        }

        guard !Task.isCancelled else {
            return .failure(.cancelled)
        }

        let requestPrompt = "\(prompt)\n\n\(text)"
        let arguments = [
            installation.executablePath,
            "-p", requestPrompt,
            "-s",
            "--model", model,
            "--no-custom-instructions",
            "--disable-builtin-mcps",
        ]
        let environment = installation.processEnvironment(
            basedOn: ProcessInfo.processInfo.environment
        )

        let launchedProcess: LaunchedProcess
        let taskWasCancelledAfterLaunch: Bool
        let launchResult = processState.launch(
            operationID: operationID,
            taskIsCancelled: { Task.isCancelled }
        ) {
            Self.launch(
                executablePath: installation.executablePath,
                arguments: arguments,
                environment: environment
            )
        }
        switch launchResult {
        case .launched(let process, let taskWasCancelled):
            launchedProcess = process
            taskWasCancelledAfterLaunch = taskWasCancelled
        case .failure(let code):
            return .failure(.launchFailed(code: code))
        case .cancelled:
            return .failure(.cancelled)
        }

        let collector = ProcessOutputCollector(maximumOutputBytes: Self.maximumOutputBytes)
        let outputQueue = DispatchQueue(
            label: "com.openwritr.grammar-enhancer.output",
            qos: .utility,
            attributes: .concurrent
        )
        let stdoutChannel = Self.startDraining(
            descriptor: launchedProcess.stdoutDescriptor,
            stream: .standardOutput,
            collector: collector,
            queue: outputQueue
        )
        let stderrChannel = Self.startDraining(
            descriptor: launchedProcess.stderrDescriptor,
            stream: .standardError,
            collector: collector,
            queue: outputQueue
        )

        let waitResult: ProcessWaitResult
        if taskWasCancelledAfterLaunch || Task.isCancelled {
            waitResult = .cancelled
        } else {
            waitResult = await waitForProcess(
                launchedProcess.pid,
                operationID: operationID
            )
        }

        let result: GrammarEnhancementResult
        let cleanupMode: ProcessCleanupMode?
        var outputWasDrained = false

        switch waitResult {
        case .timedOut:
            result = .failure(.timedOut)
            cleanupMode = .graceful
        case .cancelled:
            result = .failure(.cancelled)
            cleanupMode = .graceful
        case .monitoringFailed(let code, let groupIsOwned):
            result = .failure(.processMonitoringFailed(code: code))
            cleanupMode = groupIsOwned ? .graceful : nil
        case .exited(let status):
            if status != 0 {
                result = .failure(.nonzeroExit(status: status))
                cleanupMode = .graceful
            } else {
                outputWasDrained = await waitForOutputDrain(collector)

                if !outputWasDrained {
                    result = .failure(Task.isCancelled ? .cancelled : .timedOut)
                    cleanupMode = .graceful
                } else if Task.isCancelled {
                    result = .failure(.cancelled)
                    cleanupMode = .graceful
                } else {
                    let output = collector.snapshot()
                    if output.readFailed {
                        result = .failure(.outputReadFailed)
                        cleanupMode = .graceful
                    } else if output.exceededLimit {
                        result = .failure(.outputTooLarge)
                        cleanupMode = .graceful
                    } else if let enhancedText = String(
                        data: output.standardOutput,
                        encoding: .utf8
                    ) {
                        result = .success(
                            enhancedText.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        cleanupMode = .forced
                    } else {
                        result = .failure(.outputReadFailed)
                        cleanupMode = .graceful
                    }
                }
            }
        }

        let cleanupError: GrammarEnhancementError?
        if let cleanupMode {
            cleanupError = await terminateGroupAndReapLeader(
                pid: launchedProcess.pid,
                operationID: operationID,
                mode: cleanupMode
            )
        } else {
            cleanupError = nil
        }

        stdoutChannel.close(flags: outputWasDrained ? [] : .stop)
        stderrChannel.close(flags: outputWasDrained ? [] : .stop)

        if let cleanupError {
            if case .success = result {
                grammarLog.error(
                    "Copilot process cleanup failed after successful output: \(cleanupError.localizedDescription, privacy: .public)"
                )
                return result
            }
            return .failure(cleanupError)
        }
        return result
    }

    private func waitForProcess(
        _ pid: pid_t,
        operationID: UInt64
    ) async -> ProcessWaitResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while true {
            let observation = processState.observeOwnedLeader(
                operationID: operationID,
                pid: pid
            ) {
                Self.observe(pid: pid)
            }
            switch observation {
            case .exited(let status):
                return .exited(status: status)
            case .failed(let code, let groupIsOwned):
                return .monitoringFailed(code: code, groupIsOwned: groupIsOwned)
            case .running:
                break
            }

            if Task.isCancelled {
                return .cancelled
            }
            if clock.now >= deadline {
                return .timedOut
            }

            do {
                try await Task.sleep(for: Self.pollInterval)
            } catch {
                return .cancelled
            }
        }
    }

    private func terminateGroupAndReapLeader(
        pid: pid_t,
        operationID: UInt64,
        mode: ProcessCleanupMode
    ) async -> GrammarEnhancementError? {
        let gracePeriod = terminationGracePeriod
        let forcedWait = forcedTerminationWait
        let processState = processState
        let cleanup = Task.detached(priority: .utility) { () -> GrammarEnhancementError? in
            // The unreaped leader anchors its process-group ID until the final signal.
            if mode == .graceful {
                processState.signalOwnedLeader(
                    operationID: operationID,
                    pid: pid
                ) {
                    Self.signalProcessGroup(pid: pid, signal: SIGTERM)
                }
                try? await Task.sleep(for: gracePeriod)
            }

            processState.signalOwnedLeader(
                operationID: operationID,
                pid: pid
            ) {
                Self.signalProcessGroup(pid: pid, signal: SIGKILL)
            }
            switch await Self.reapLeaderAndWaitForGroup(
                pid: pid,
                operationID: operationID,
                processState: processState,
                for: forcedWait
            ) {
            case .finished:
                return nil
            case .failed(let code):
                return .processMonitoringFailed(code: code)
            case .timedOut:
                return .timedOut
            }
        }
        return await cleanup.value
    }

    private func waitForOutputDrain(_ collector: ProcessOutputCollector) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.outputDrainTimeout)

        while !collector.finished {
            guard !Task.isCancelled, clock.now < deadline else {
                return false
            }
            do {
                try await Task.sleep(for: Self.pollInterval)
            } catch {
                return false
            }
        }
        return true
    }

    private static func reapLeaderAndWaitForGroup(
        pid: pid_t,
        operationID: UInt64,
        processState: EnhancementProcessState,
        for duration: Duration
    ) async -> ProcessCleanupResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        var leaderWasReaped = false

        while clock.now < deadline {
            if !leaderWasReaped {
                let reapResult = processState.reapOwnedLeader(
                    operationID: operationID,
                    pid: pid
                ) {
                    reap(pid: pid)
                }
                switch reapResult {
                case .exited:
                    leaderWasReaped = true
                case .failed(let code):
                    return .failed(code: code)
                case .running:
                    break
                }
            }

            if leaderWasReaped {
                switch processGroupPresence(pid: pid) {
                case .absent:
                    return .finished
                case .failed(let code):
                    return .failed(code: code)
                case .present:
                    break
                }
            }

            try? await Task.sleep(for: pollInterval)
        }

        if !leaderWasReaped {
            let reapResult = processState.reapOwnedLeader(
                operationID: operationID,
                pid: pid
            ) {
                reap(pid: pid)
            }
            switch reapResult {
            case .exited:
                leaderWasReaped = true
            case .failed(let code):
                return .failed(code: code)
            case .running:
                return .timedOut
            }
        }

        switch processGroupPresence(pid: pid) {
        case .absent:
            return .finished
        case .failed(let code):
            return .failed(code: code)
        case .present:
            return .timedOut
        }
    }

    private static func signalProcessGroup(pid: pid_t, signal: Int32) {
        guard pid > 0 else { return }

        if Darwin.kill(-pid, signal) == 0 || errno != ESRCH {
            return
        }

        _ = Darwin.kill(pid, signal)
    }

    private static func startDraining(
        descriptor: Int32,
        stream: ProcessOutputStream,
        collector: ProcessOutputCollector,
        queue: DispatchQueue
    ) -> DispatchIO {
        let channel = DispatchIO(
            type: .stream,
            fileDescriptor: descriptor,
            queue: queue
        ) { _ in
            Darwin.close(descriptor)
        }
        channel.setLimit(lowWater: 1)
        channel.read(offset: 0, length: Int.max, queue: queue) { done, data, error in
            if stream == .standardOutput, let data, !data.isEmpty {
                collector.appendStandardOutput(Data(data))
            }
            if done {
                collector.finish(stream: stream, error: error)
            }
        }
        return channel
    }

    private static func launch(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) -> LaunchResult {
        guard !executablePath.contains("\0"),
              !arguments.contains(where: { $0.contains("\0") }),
              !environment.contains(where: { $0.key.contains("\0") || $0.value.contains("\0") })
        else {
            return .failure(EINVAL)
        }

        var stdoutDescriptors = [Int32](repeating: -1, count: 2)
        guard stdoutDescriptors.withUnsafeMutableBufferPointer({
            Darwin.pipe($0.baseAddress!)
        }) == 0 else {
            return .failure(errno)
        }

        var stderrDescriptors = [Int32](repeating: -1, count: 2)
        guard stderrDescriptors.withUnsafeMutableBufferPointer({
            Darwin.pipe($0.baseAddress!)
        }) == 0 else {
            let code = errno
            stdoutDescriptors.forEach { Darwin.close($0) }
            return .failure(code)
        }

        var descriptorsAreOwned = true
        defer {
            if descriptorsAreOwned {
                (stdoutDescriptors + stderrDescriptors)
                    .filter { $0 >= 0 }
                    .forEach { Darwin.close($0) }
            }
        }

        for index in stdoutDescriptors.indices {
            guard Self.moveAboveStandardDescriptors(&stdoutDescriptors[index]) else {
                return .failure(errno)
            }
        }
        for index in stderrDescriptors.indices {
            guard Self.moveAboveStandardDescriptors(&stderrDescriptors[index]) else {
                return .failure(errno)
            }
        }

        for descriptor in stdoutDescriptors + stderrDescriptors {
            let descriptorFlags = Darwin.fcntl(descriptor, F_GETFD)
            guard descriptorFlags >= 0,
                  Darwin.fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0
            else {
                return .failure(errno)
            }
        }

        var fileActions: posix_spawn_file_actions_t?
        var spawnAttributes: posix_spawnattr_t?

        var code = posix_spawn_file_actions_init(&fileActions)
        guard code == 0 else {
            return .failure(code)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        code = posix_spawnattr_init(&spawnAttributes)
        guard code == 0 else {
            return .failure(code)
        }
        defer { posix_spawnattr_destroy(&spawnAttributes) }

        let actionResults = [
            posix_spawn_file_actions_addopen(
                &fileActions,
                STDIN_FILENO,
                "/dev/null",
                O_RDONLY,
                0
            ),
            posix_spawn_file_actions_adddup2(
                &fileActions,
                stdoutDescriptors[1],
                STDOUT_FILENO
            ),
            posix_spawn_file_actions_adddup2(
                &fileActions,
                stderrDescriptors[1],
                STDERR_FILENO
            ),
            posix_spawn_file_actions_addclose(&fileActions, stdoutDescriptors[0]),
            posix_spawn_file_actions_addclose(&fileActions, stderrDescriptors[0]),
            posix_spawn_file_actions_addclose(&fileActions, stdoutDescriptors[1]),
            posix_spawn_file_actions_addclose(&fileActions, stderrDescriptors[1]),
        ]
        if let actionFailure = actionResults.first(where: { $0 != 0 }) {
            return .failure(actionFailure)
        }

        code = posix_spawnattr_setpgroup(&spawnAttributes, 0)
        guard code == 0 else {
            return .failure(code)
        }
        let spawnFlags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        code = posix_spawnattr_setflags(&spawnAttributes, spawnFlags)
        guard code == 0 else {
            return .failure(code)
        }

        guard var argumentPointers = duplicateCStringArray(arguments) else {
            return .failure(ENOMEM)
        }
        defer { freeCStringArray(argumentPointers) }

        guard var environmentPointers = duplicateCStringArray(
            environment
                .map { "\($0.key)=\($0.value)" }
                .sorted()
        ) else {
            return .failure(ENOMEM)
        }
        defer { freeCStringArray(environmentPointers) }

        var pid = pid_t()
        code = executablePath.withCString { executablePointer in
            argumentPointers.withUnsafeMutableBufferPointer { argumentBuffer in
                environmentPointers.withUnsafeMutableBufferPointer { environmentBuffer in
                    posix_spawn(
                        &pid,
                        executablePointer,
                        &fileActions,
                        &spawnAttributes,
                        argumentBuffer.baseAddress!,
                        environmentBuffer.baseAddress!
                    )
                }
            }
        }
        guard code == 0 else {
            return .failure(code)
        }

        Darwin.close(stdoutDescriptors[1])
        Darwin.close(stderrDescriptors[1])
        stdoutDescriptors[1] = -1
        stderrDescriptors[1] = -1
        descriptorsAreOwned = false

        return .success(
            LaunchedProcess(
                pid: pid,
                stdoutDescriptor: stdoutDescriptors[0],
                stderrDescriptor: stderrDescriptors[0]
            )
        )
    }

    private static func moveAboveStandardDescriptors(_ descriptor: inout Int32) -> Bool {
        guard descriptor <= STDERR_FILENO else {
            return true
        }

        let duplicatedDescriptor = Darwin.fcntl(
            descriptor,
            F_DUPFD_CLOEXEC,
            STDERR_FILENO + 1
        )
        guard duplicatedDescriptor >= 0 else {
            return false
        }
        Darwin.close(descriptor)
        descriptor = duplicatedDescriptor
        return true
    }

    private static func duplicateCStringArray(
        _ strings: [String]
    ) -> [UnsafeMutablePointer<CChar>?]? {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        pointers.reserveCapacity(strings.count + 1)

        for string in strings {
            guard let pointer = strdup(string) else {
                freeCStringArray(pointers)
                return nil
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return pointers
    }

    private static func freeCStringArray(_ pointers: [UnsafeMutablePointer<CChar>?]) {
        for pointer in pointers {
            free(pointer)
        }
    }

    private static func observe(pid: pid_t) -> ProcessObservation {
        var info = siginfo_t()
        let result = Darwin.waitid(
            P_PID,
            id_t(pid),
            &info,
            WEXITED | WNOHANG | WNOWAIT
        )

        if result == 0 {
            guard info.si_pid != 0 else {
                return .running
            }

            switch info.si_code {
            case CLD_EXITED:
                return .exited(status: info.si_status)
            case CLD_KILLED, CLD_DUMPED:
                return .exited(status: 128 + info.si_status)
            default:
                return .running
            }
        }
        if errno == EINTR {
            return .running
        }
        return .failed(code: errno, groupIsOwned: errno != ECHILD)
    }

    private static func reap(pid: pid_t) -> ReapResult {
        var status: Int32 = 0
        let result = Darwin.waitpid(pid, &status, WNOHANG)

        if result == pid {
            return .exited(status: status)
        }
        if result == 0 || (result == -1 && errno == EINTR) {
            return .running
        }
        return .failed(code: result == -1 ? errno : ECHILD)
    }

    private static func processGroupPresence(pid: pid_t) -> ProcessGroupPresence {
        if Darwin.kill(-pid, 0) == 0 || errno == EPERM {
            return .present
        }
        if errno == ESRCH {
            return .absent
        }
        return .failed(code: errno)
    }
}

// MARK: - Supporting types

private struct CopilotInstallation: Sendable {
    let executablePath: String
    let runtimeBinPath: String

    func processEnvironment(basedOn environment: [String: String]) -> [String: String] {
        var environment = environment
        let executableBinPath = URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
            .path
        let inheritedPaths = environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        let preferredPaths = [
            runtimeBinPath,
            executableBinPath,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/local/lib/nodejs/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]

        var seen: Set<String> = []
        environment["PATH"] = (preferredPaths + inheritedPaths)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
        return environment
    }
}

private struct LaunchedProcess: Sendable {
    let pid: pid_t
    let stdoutDescriptor: Int32
    let stderrDescriptor: Int32
}

private enum LaunchResult {
    case success(LaunchedProcess)
    case failure(Int32)
}

private enum EnhancementStartResult {
    case started(UInt64)
    case cancelled
    case alreadyInProgress
}

private enum CoordinatedLaunchResult {
    case launched(LaunchedProcess, taskWasCancelled: Bool)
    case failure(Int32)
    case cancelled
}

private final class EnhancementProcessState: @unchecked Sendable {
    private enum Phase {
        case idle
        case starting(operationID: UInt64)
        case owned(operationID: UInt64, pid: pid_t)
    }

    private let lock = NSLock()
    private var phase = Phase.idle
    private var nextOperationID: UInt64 = 0
    private var preventsFutureLaunches = false

    func beginEnhancement(taskIsCancelled: Bool) -> EnhancementStartResult {
        lock.lock()
        defer { lock.unlock() }

        guard !preventsFutureLaunches, !taskIsCancelled else {
            return .cancelled
        }
        guard case .idle = phase else {
            return .alreadyInProgress
        }

        nextOperationID &+= 1
        phase = .starting(operationID: nextOperationID)
        return .started(nextOperationID)
    }

    func finishPendingLaunch(operationID: UInt64) {
        lock.lock()
        defer { lock.unlock() }

        guard case .starting(let currentOperationID) = phase,
              currentOperationID == operationID
        else {
            return
        }
        phase = .idle
    }

    func launch(
        operationID: UInt64,
        taskIsCancelled: () -> Bool,
        _ launchProcess: () -> LaunchResult
    ) -> CoordinatedLaunchResult {
        lock.lock()
        defer { lock.unlock() }

        guard case .starting(let currentOperationID) = phase,
              currentOperationID == operationID
        else {
            return .cancelled
        }
        guard !preventsFutureLaunches, !taskIsCancelled() else {
            phase = .idle
            return .cancelled
        }

        switch launchProcess() {
        case .success(let process):
            phase = .owned(operationID: operationID, pid: process.pid)
            return .launched(
                process,
                taskWasCancelled: taskIsCancelled()
            )
        case .failure(let code):
            phase = .idle
            return .failure(code)
        }
    }

    func cancelAndPreventFutureLaunches(_ signal: (pid_t) -> Void) {
        lock.lock()
        defer { lock.unlock() }

        preventsFutureLaunches = true
        guard case .owned(_, let pid) = phase else {
            return
        }
        signal(pid)
    }

    func signalOwnedLeader(
        operationID: UInt64,
        pid: pid_t,
        _ signal: () -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard ownsLeader(operationID: operationID, pid: pid) else {
            return
        }
        signal()
    }

    func observeOwnedLeader(
        operationID: UInt64,
        pid: pid_t,
        _ observe: () -> ProcessObservation
    ) -> ProcessObservation {
        lock.lock()
        defer { lock.unlock() }

        guard ownsLeader(operationID: operationID, pid: pid) else {
            return .failed(code: ECHILD, groupIsOwned: false)
        }

        let result = observe()
        if case .failed(_, let groupIsOwned) = result, !groupIsOwned {
            phase = .idle
        }
        return result
    }

    func reapOwnedLeader(
        operationID: UInt64,
        pid: pid_t,
        _ reap: () -> ReapResult
    ) -> ReapResult {
        lock.lock()
        defer { lock.unlock() }

        guard ownsLeader(operationID: operationID, pid: pid) else {
            return .failed(code: ECHILD)
        }

        let result = reap()
        switch result {
        case .exited:
            phase = .idle
        case .failed(let code) where code == ECHILD:
            phase = .idle
        case .running, .failed:
            break
        }
        return result
    }

    private func ownsLeader(operationID: UInt64, pid: pid_t) -> Bool {
        guard case .owned(let currentOperationID, let currentPID) = phase else {
            return false
        }
        return currentOperationID == operationID && currentPID == pid
    }
}

private enum ProcessWaitResult {
    case exited(status: Int32)
    case timedOut
    case cancelled
    case monitoringFailed(code: Int32, groupIsOwned: Bool)
}

private enum ProcessObservation {
    case running
    case exited(status: Int32)
    case failed(code: Int32, groupIsOwned: Bool)
}

private enum ProcessCleanupMode: Sendable {
    case graceful
    case forced
}

private enum ProcessCleanupResult {
    case finished
    case timedOut
    case failed(code: Int32)
}

private enum ProcessGroupPresence {
    case present
    case absent
    case failed(code: Int32)
}

private enum ReapResult {
    case running
    case exited(status: Int32)
    case failed(code: Int32)
}

private enum ProcessOutputStream: Sendable {
    case standardOutput
    case standardError
}

private final class ProcessOutputCollector: @unchecked Sendable {
    struct Snapshot: Sendable {
        let standardOutput: Data
        let readFailed: Bool
        let exceededLimit: Bool
    }

    private let lock = NSLock()
    private let maximumOutputBytes: Int
    private var standardOutput = Data()
    private var standardOutputFinished = false
    private var standardErrorFinished = false
    private var readFailed = false
    private var exceededLimit = false

    init(maximumOutputBytes: Int) {
        self.maximumOutputBytes = maximumOutputBytes
    }

    var finished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return standardOutputFinished && standardErrorFinished
    }

    func appendStandardOutput(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }

        let remainingCapacity = maximumOutputBytes - standardOutput.count
        if remainingCapacity <= 0 {
            exceededLimit = true
            return
        }
        if data.count > remainingCapacity {
            standardOutput.append(data.prefix(remainingCapacity))
            exceededLimit = true
        } else {
            standardOutput.append(data)
        }
    }

    func finish(stream: ProcessOutputStream, error: Int32) {
        lock.lock()
        defer { lock.unlock() }

        if error != 0 {
            readFailed = true
        }
        switch stream {
        case .standardOutput:
            standardOutputFinished = true
        case .standardError:
            standardErrorFinished = true
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            standardOutput: standardOutput,
            readFailed: readFailed,
            exceededLimit: exceededLimit
        )
    }
}
