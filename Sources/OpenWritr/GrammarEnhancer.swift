import Foundation

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

    func enhance(text: String, model: EnhancedModel) async -> String {
        await Task.detached {
            self.runCopilot(text: text, model: model.rawValue)
        }.value
    }

    // MARK: - Private

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

    private func runCopilot(text: String, model: String) -> String {
        guard let bin = findCopilotBinary() else { return text }

        let prompt = "Fix grammar, spelling, and punctuation. Remove filler words and hesitation sounds in any language. Keep the original meaning and tone. Return only the corrected text. Do not add explanations.\n\n\(text)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = [
            "-p", prompt,
            "-s",
            "--model", model,
            "--no-custom-instructions",
        ]
        process.environment = ProcessInfo.processInfo.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return text
        }

        // Enforce a timeout so the app doesn't hang
        let timeout = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)

        process.waitUntilExit()
        timeout.cancel()

        guard process.terminationStatus == 0 else { return text }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.isEmpty ? text : output
    }
}
