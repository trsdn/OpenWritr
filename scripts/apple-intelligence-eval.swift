import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

struct Request: Decodable {
    let id: String
    let prompt: String
    let text: String
}

struct Response: Encodable {
    let id: String
    let output: String
    let error: String?
    let durationMilliseconds: Int
    let firstPassDurationMilliseconds: Int
    let repairDurationMilliseconds: Int?
    let repairAttempted: Bool
    let repairUsed: Bool
    let report: CleanupIntegrityReport?
    let firstPassReport: CleanupIntegrityReport?
    let repairReport: CleanupIntegrityReport?
}

@main
struct AppleIntelligenceEval {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: apple-intelligence-eval <requests.json>\n", stderr)
            exit(2)
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let requests = try JSONDecoder().decode([Request].self, from: data)
            let responses = await evaluate(requests)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(responses))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func evaluate(_ requests: [Request]) async -> [Response] {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else {
                return requests.map { failure(id: $0.id, error: "Apple Intelligence is unavailable.") }
            }
            var responses: [Response] = []
            for request in requests {
                responses.append(await evaluate(request))
            }
            return responses
        }
        #endif
        return requests.map {
            failure(id: $0.id, error: "Apple Intelligence requires macOS 26 or later.")
        }
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func evaluate(_ request: Request) async -> Response {
        let policy = AppleCleanupPolicy()
        let totalStart = ContinuousClock.now
        if policy.isFillerOnly(request.text) {
            let candidate = policy.candidate(
                source: request.text,
                output: "",
                durationMilliseconds: elapsedMilliseconds(since: totalStart)
            )
            return response(
                request: request,
                selection: policy.select(source: request.text, firstPass: candidate, repair: nil),
                repairAttempted: false,
                totalStart: totalStart
            )
        }

        do {
            let session = LanguageModelSession(instructions: request.prompt)
            let firstStart = ContinuousClock.now
            let firstResponse = try await session.respond(
                to: policy.firstPassPrompt(for: request.text)
            )
            let firstPass = policy.candidate(
                source: request.text,
                output: firstResponse.content,
                durationMilliseconds: elapsedMilliseconds(since: firstStart)
            )
            var repair: AppleCleanupCandidate?
            let repairAttempted = policy.shouldRepair(firstPass.report)
            if repairAttempted {
                do {
                    let repairStart = ContinuousClock.now
                    let repairSession = LanguageModelSession(
                        instructions: policy.repairInstructions
                    )
                    let repairedResponse = try await repairSession.respond(
                        to: policy.repairPrompt(source: request.text, candidate: firstPass)
                    )
                    repair = policy.candidate(
                        source: request.text,
                        output: policy.normalizedRepairOutput(
                            source: request.text,
                            output: repairedResponse.content
                        ),
                        durationMilliseconds: elapsedMilliseconds(since: repairStart)
                    )
                } catch {
                    repair = nil
                }
            }
            return response(
                request: request,
                selection: policy.select(
                    source: request.text,
                    firstPass: firstPass,
                    repair: repair
                ),
                repairAttempted: repairAttempted,
                totalStart: totalStart
            )
        } catch {
            return failure(
                id: request.id,
                error: error.localizedDescription,
                durationMilliseconds: elapsedMilliseconds(since: totalStart)
            )
        }
    }
    #endif

    private static func response(
        request: Request,
        selection: AppleCleanupSelection,
        repairAttempted: Bool,
        totalStart: ContinuousClock.Instant
    ) -> Response {
        Response(
            id: request.id,
            output: selection.selected.text,
            error: nil,
            durationMilliseconds: elapsedMilliseconds(since: totalStart),
            firstPassDurationMilliseconds: selection.firstPass.durationMilliseconds,
            repairDurationMilliseconds: selection.repair?.durationMilliseconds,
            repairAttempted: repairAttempted,
            repairUsed: selection.repairUsed,
            report: selection.selected.report,
            firstPassReport: selection.firstPass.report,
            repairReport: selection.repair?.report
        )
    }

    private static func failure(
        id: String,
        error: String,
        durationMilliseconds: Int = 0
    ) -> Response {
        Response(
            id: id,
            output: "",
            error: error,
            durationMilliseconds: durationMilliseconds,
            firstPassDurationMilliseconds: 0,
            repairDurationMilliseconds: nil,
            repairAttempted: false,
            repairUsed: false,
            report: nil,
            firstPassReport: nil,
            repairReport: nil
        )
    }

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now)
        return Int(duration.components.seconds * 1_000)
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
