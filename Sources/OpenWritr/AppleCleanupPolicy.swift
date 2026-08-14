import Foundation

struct AppleCleanupCandidate: Codable, Equatable, Sendable {
    let text: String
    let report: CleanupIntegrityReport
    let durationMilliseconds: Int
}

struct AppleCleanupSelection: Codable, Equatable, Sendable {
    let selected: AppleCleanupCandidate
    let firstPass: AppleCleanupCandidate
    let repair: AppleCleanupCandidate?
    let repairUsed: Bool
}

struct AppleCleanupPolicy: Sendable {
    private let validator = CleanupIntegrityValidator()

    func isFillerOnly(_ text: String) -> Bool {
        let fillers: Set<String> = [
            "ah", "äh", "ähm", "also", "hm", "hmm", "mhm", "uh", "uhm", "um",
        ]
        let tokens = text.lowercased().split { !$0.isLetter }.map(String.init)
        return !tokens.isEmpty && tokens.allSatisfy(fillers.contains)
    }

    func normalizedOutput(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "[[EMPTY]]" { return "" }
        for tag in ["candidate", "transcript", "output", "result"] {
            if let unwrapped = content(of: tag, in: trimmed) {
                return unwrapped
            }
        }
        return trimmed
    }

    func normalizedRepairOutput(source: String, output: String) -> String {
        var repaired = normalizedOutput(output)
        let report = validator.validate(source: source, candidate: repaired)
        let missingProtected = report.violations
            .filter { $0.category == .protectedSpan }
            .flatMap(\.expected)
        var extras = report.candidateProtectedSpans.filter {
            !report.sourceProtectedSpans.contains($0)
        }
        for expected in missingProtected {
            guard let replacement = extras.min(by: {
                editDistance(from: expected, to: $0)
                    < editDistance(from: expected, to: $1)
            }) else { continue }
            repaired = repaired.replacingOccurrences(of: replacement, with: expected)
            extras.removeAll { $0 == replacement }
        }
        for violation in report.violations where violation.category == .listMarker {
            for marker in violation.expected {
                repaired = restoringListMarker(marker, from: source, in: repaired)
            }
        }
        for violation in report.violations where violation.category == .filler {
            for filler in violation.observed {
                repaired = removingWholePhrase(filler, from: repaired)
            }
        }
        repaired = repaired.replacingOccurrences(
            of: #"\s+([,.;:!?])"#,
            with: "$1",
            options: .regularExpression
        )
        repaired = repaired.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if report.violations.contains(where: { $0.category == .terminalPunctuation }),
           !repaired.isEmpty
        {
            repaired += "."
        }
        return repaired
    }

    func firstPassPrompt(for text: String) -> String {
        let language = validator.dominantLanguage(in: text) ?? "undetermined"
        return """
        The transcript's primary language is \(language). The cleaned output must remain in that language. Preserve phrases in other languages exactly; never translate them.

        <transcript>
        \(text)
        </transcript>
        """
    }

    func candidate(
        source: String,
        output: String,
        durationMilliseconds: Int
    ) -> AppleCleanupCandidate {
        let normalized = normalizedRepairOutput(source: source, output: output)
        return AppleCleanupCandidate(
            text: normalized,
            report: validator.validate(source: source, candidate: normalized),
            durationMilliseconds: durationMilliseconds
        )
    }

    func shouldRepair(_ report: CleanupIntegrityReport) -> Bool {
        report.violations.contains { $0.severity == .error }
    }

    var repairInstructions: String {
        """
        You are a constrained transcript integrity repairer. Fix only the listed defects in the supplied candidate. Strings marked as mandatory must appear verbatim, with identical casing, spacing, punctuation, and language. Return only the repaired candidate.
        """
    }

    func repairPrompt(
        source: String,
        candidate: AppleCleanupCandidate
    ) -> String {
        let mandatory = candidate.report.violations
            .flatMap(\.expected)
            .filter { !$0.isEmpty }
            .map { "- \($0)" }
            .joined(separator: "\n")
        let findings = candidate.report.violations.map { violation in
            let details = violation.expected.isEmpty
                ? violation.observed.joined(separator: ", ")
                : violation.expected.joined(separator: ", ")
            return "- \(violation.category.rawValue): \(violation.message) \(details)"
        }.joined(separator: "\n")
        return """
        Repair only the concrete integrity defects listed below. Do not paraphrase or translate.

        Mandatory verbatim strings:
        \(mandatory.isEmpty ? "- none" : mandatory)

        Defects:
        \(findings)

        <original>
        \(source)
        </original>

        <candidate>
        \(candidate.text)
        </candidate>
        """
    }

    func select(
        source: String,
        firstPass: AppleCleanupCandidate,
        repair: AppleCleanupCandidate?
    ) -> AppleCleanupSelection {
        guard let repair else {
            return AppleCleanupSelection(
                selected: firstPass,
                firstPass: firstPass,
                repair: nil,
                repairUsed: false
            )
        }

        let firstPassErrors = violationCount(in: firstPass, severity: .error)
        let repairErrors = violationCount(in: repair, severity: .error)
        let firstPassWarnings = violationCount(in: firstPass, severity: .warning)
        let repairWarnings = violationCount(in: repair, severity: .warning)

        let useRepair: Bool
        if repairErrors != firstPassErrors {
            useRepair = repairErrors < firstPassErrors
        } else if repairWarnings != firstPassWarnings {
            useRepair = repairWarnings < firstPassWarnings
        } else {
            useRepair = editDistance(from: source, to: repair.text)
                < editDistance(from: source, to: firstPass.text)
        }
        return AppleCleanupSelection(
            selected: useRepair ? repair : firstPass,
            firstPass: firstPass,
            repair: repair,
            repairUsed: useRepair
        )
    }

    private func editDistance(from source: String, to candidate: String) -> Int {
        let left = Array(source.lowercased())
        let right = Array(candidate.lowercased())
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, rightCharacter) in right.enumerated() {
                current.append(
                    min(
                        current[rightIndex] + 1,
                        previous[rightIndex + 1] + 1,
                        previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                    )
                )
            }
            previous = current
        }
        return previous[right.count]
    }

    private func violationCount(
        in candidate: AppleCleanupCandidate,
        severity: CleanupIntegritySeverity
    ) -> Int {
        candidate.report.violations.count { $0.severity == severity }
    }

    private func content(of tag: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(tag)>", options: .backwards),
              let end = text.range(
                  of: "</\(tag)>",
                  options: .backwards,
                  range: start.upperBound..<text.endIndex
              )
        else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func restoringListMarker(
        _ marker: String,
        from source: String,
        in candidate: String
    ) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: marker)
        guard let expression = try? NSRegularExpression(
            pattern: #"(?i)(?<![\p{L}\p{N}])\#(escaped)\s+([\p{L}\p{N}_-]+)"#
        ) else { return candidate }
        let sourceRange = NSRange(source.startIndex..., in: source)
        guard let match = expression.firstMatch(in: source, range: sourceRange),
              let wordRange = Range(match.range(at: 1), in: source)
        else { return candidate }
        let followingWord = String(source[wordRange])
        guard !candidate.localizedCaseInsensitiveContains(marker) else { return candidate }
        let wordPattern = #"(?<![\p{L}\p{N}])\#(NSRegularExpression.escapedPattern(for: followingWord))(?![\p{L}\p{N}])"#
        guard let wordExpression = try? NSRegularExpression(
            pattern: wordPattern,
            options: .caseInsensitive
        ) else { return candidate }
        let candidateRange = NSRange(candidate.startIndex..., in: candidate)
        guard let wordMatch = wordExpression.firstMatch(in: candidate, range: candidateRange),
              let replacementRange = Range(wordMatch.range, in: candidate)
        else { return candidate }
        var result = candidate
        result.replaceSubrange(
            replacementRange,
            with: "\(marker) \(candidate[replacementRange])"
        )
        return result
    }

    private func removingWholePhrase(_ phrase: String, from text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        guard let expression = try? NSRegularExpression(
            pattern: #"(?i)(?<![\p{L}\p{N}])\#(escaped)(?![\p{L}\p{N}])"#
        ) else { return text }
        return expression.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
    }
}
