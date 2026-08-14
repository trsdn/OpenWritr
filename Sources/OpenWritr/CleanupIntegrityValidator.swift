import Foundation

enum CleanupIntegrityCategory: String, Codable, CaseIterable, Sendable {
    case factualToken
    case negation
    case listMarker
    case protectedSpan
    case languageDrift
    case terminalPunctuation
    case filler
    case repetition
}

enum CleanupIntegritySeverity: String, Codable, Sendable {
    case warning
    case error
}

struct CleanupIntegrityViolation: Codable, Equatable, Sendable {
    let category: CleanupIntegrityCategory
    let severity: CleanupIntegritySeverity
    let message: String
    let expected: [String]
    let observed: [String]
}

struct CleanupIntegrityReport: Codable, Equatable, Sendable {
    let violations: [CleanupIntegrityViolation]
    let sourceDominantLanguage: String?
    let candidateDominantLanguage: String?
    let sourceProtectedSpans: [String]
    let candidateProtectedSpans: [String]

    var isValid: Bool {
        !violations.contains { $0.severity == .error }
    }

    var weightedRisk: Int {
        violations.reduce(into: 0) {
            $0 += $1.severity == .error ? 10 : 1
        }
    }
}

struct CleanupIntegrityValidator: Sendable {
    func validate(source: String, candidate: String) -> CleanupIntegrityReport {
        let sourceFacts = factualTokens(in: source)
        let candidateFacts = factualTokens(in: candidate)
        let sourceNegations = matchedTerms(in: source, terms: Self.negationTerms)
        let candidateNegations = matchedTerms(in: candidate, terms: Self.negationTerms)
        let sourceMarkers = matchedTerms(in: source, terms: Self.listMarkers)
        let candidateMarkers = matchedTerms(in: candidate, terms: Self.listMarkers)
        let sourceSpans = protectedSpans(in: source)
        let candidateSpans = protectedSpans(in: candidate)
        let sourceLanguage = dominantLanguage(in: source)
        let candidateLanguage = dominantLanguage(in: candidate)
        var violations: [CleanupIntegrityViolation] = []

        appendMissing(
            sourceFacts,
            from: candidateFacts,
            category: .factualToken,
            message: "Numbers, dates, times, or versions changed or disappeared.",
            to: &violations
        )
        appendMissing(
            sourceNegations,
            from: candidateNegations,
            category: .negation,
            message: "Negation changed or disappeared.",
            to: &violations
        )
        appendMissing(
            sourceMarkers,
            from: candidateMarkers,
            category: .listMarker,
            message: "A list marker changed or disappeared.",
            to: &violations
        )
        appendMissing(
            sourceSpans,
            from: candidateSpans,
            category: .protectedSpan,
            message: "A command, acronym, product name, or technical span changed.",
            caseSensitive: true,
            to: &violations
        )

        if let sourceLanguage,
           let candidateLanguage,
           sourceLanguage != candidateLanguage
        {
            violations.append(
                CleanupIntegrityViolation(
                    category: .languageDrift,
                    severity: .error,
                    message: "The candidate's dominant language differs from the transcript.",
                    expected: [sourceLanguage],
                    observed: [candidateLanguage]
                )
            )
        }

        if !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           requiresTerminalPunctuation(source),
           !hasTerminalPunctuation(candidate)
        {
            violations.append(
                CleanupIntegrityViolation(
                    category: .terminalPunctuation,
                    severity: .warning,
                    message: "Meaningful output is missing terminal punctuation.",
                    expected: [".", "!", "?", "…"],
                    observed: []
                )
            )
        }

        let retainedFillers = removableFillers(in: candidate)
        if !retainedFillers.isEmpty {
            violations.append(
                CleanupIntegrityViolation(
                    category: .filler,
                    severity: .warning,
                    message: "Speech fillers remain in the candidate.",
                    expected: [],
                    observed: retainedFillers
                )
            )
        }

        let repetitions = accidentalRepetitions(in: candidate)
        if !repetitions.isEmpty {
            violations.append(
                CleanupIntegrityViolation(
                    category: .repetition,
                    severity: .warning,
                    message: "Accidental word or phrase repetition remains.",
                    expected: [],
                    observed: repetitions
                )
            )
        }

        return CleanupIntegrityReport(
            violations: violations,
            sourceDominantLanguage: sourceLanguage,
            candidateDominantLanguage: candidateLanguage,
            sourceProtectedSpans: sourceSpans,
            candidateProtectedSpans: candidateSpans
        )
    }

    func dominantLanguage(in text: String) -> String? {
        let words = normalizedWords(in: text)
        guard words.count >= 3 else { return nil }
        let german = words.filter(Self.germanIndicators.contains).count
        let english = words.filter(Self.englishIndicators.contains).count
        guard max(german, english) >= 2, german != english else { return nil }
        return german > english ? "de" : "en"
    }

    private func appendMissing(
        _ expected: [String],
        from observed: [String],
        category: CleanupIntegrityCategory,
        message: String,
        caseSensitive: Bool = false,
        to violations: inout [CleanupIntegrityViolation]
    ) {
        let observedCounts = occurrenceCounts(observed, caseSensitive: caseSensitive)
        let expectedCounts = occurrenceCounts(expected, caseSensitive: caseSensitive)
        let missing = expectedCounts.flatMap { value, count -> [String] in
            Array(
                repeating: expected.first {
                    caseSensitive ? $0 == value : $0.lowercased() == value
                } ?? value,
                count: max(0, count - observedCounts[value, default: 0])
            )
        }.sorted()
        guard !missing.isEmpty else { return }
        violations.append(
            CleanupIntegrityViolation(
                category: category,
                severity: .error,
                message: message,
                expected: missing,
                observed: observed
            )
        )
    }

    private func factualTokens(in text: String) -> [String] {
        regexMatches(
            pattern: #"(?<![\p{L}\p{N}])(?:\d{1,2}\.?\s+(?:Januar|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember|January|February|March|May|June|July|October|December)\s+\d{4}|\d{1,2}[:.]\d{2}(?:\s*(?:Uhr|am|pm))?|\d{1,2}\s*Uhr|\d+(?:\.\d+){1,3}|\d{1,2}[./-]\d{1,2}[./-]\d{2,4}|\d+(?:[.,]\d+)?%?)(?![\p{L}\p{N}])"#,
            in: text
        )
    }

    private func protectedSpans(in text: String) -> [String] {
        var spans = Set<String>()
        let words = text.split(whereSeparator: \.isWhitespace).map {
            String($0).trimmingCharacters(in: .punctuationCharacters)
        }

        for word in words where shouldProtectWord(word) {
            spans.insert(word)
        }

        for command in regexMatches(
            pattern: #"(?:^|[\s„“"'`])((?:git|gh|copilot|swift|xcodebuild|npm|pnpm|yarn|python3?|pip3?|docker|kubectl|brew)(?:\s+[-\w./]+)?)"#,
            in: text,
            captureGroup: 1
        ) {
            spans.insert(command)
        }

        for phrase in Self.technicalPhrases {
            if let matched = matchedWholePhrase(phrase, in: text) {
                spans.insert(matched)
            }
        }
        return spans.sorted()
    }

    private func shouldProtectWord(_ word: String) -> Bool {
        guard word.count >= 2 else { return false }
        if Self.knownProducts.contains(word) { return true }
        if word.range(of: #"^[A-Z][A-Z0-9]{1,}$"#, options: .regularExpression) != nil {
            return true
        }
        if word.range(of: #"[a-z][A-Z]|[A-Z].*[A-Z]"#, options: .regularExpression) != nil {
            return true
        }
        return word.range(of: #"^[A-Za-z]+(?:[-_/][A-Za-z0-9]+)+$"#, options: .regularExpression) != nil
    }

    private func removableFillers(in text: String) -> [String] {
        normalizedWords(in: text)
            .filter(Self.unambiguousFillers.contains)
            .sorted()
    }

    private func accidentalRepetitions(in text: String) -> [String] {
        let words = normalizedWords(in: text)
        var found = Set<String>()
        for index in words.indices.dropFirst() where words[index] == words[index - 1] {
            found.insert("\(words[index]) \(words[index])")
        }
        guard words.count >= 4 else { return found.sorted() }
        for length in 2...min(4, words.count / 2) {
            for start in 0...(words.count - length * 2) {
                let first = Array(words[start..<(start + length)])
                let second = Array(words[(start + length)..<(start + length * 2)])
                if first == second {
                    found.insert(first.joined(separator: " "))
                }
            }
        }
        return found.sorted()
    }

    private func matchedTerms(in text: String, terms: Set<String>) -> [String] {
        var matches = terms.flatMap { matchedWholePhrases($0, in: text) }
        if terms == Self.listMarkers {
            matches.append(
                contentsOf: regexMatches(
                    pattern: #"(?:^|\s)(\d+[.)]|[-•])(?=\s)"#,
                    in: text,
                    captureGroup: 1
                )
            )
        }
        return matches.sorted()
    }

    private func containsWholePhrase(_ phrase: String, in text: String) -> Bool {
        matchedWholePhrase(phrase, in: text) != nil
    }

    private func matchedWholePhrase(_ phrase: String, in text: String) -> String? {
        matchedWholePhrases(phrase, in: text).first
    }

    private func matchedWholePhrases(_ phrase: String, in text: String) -> [String] {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        guard let expression = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}])\#(escaped)(?![\p{L}\p{N}])"#,
            options: .caseInsensitive
        ) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private func regexMatches(
        pattern: String,
        in text: String,
        captureGroup: Int = 0
    ) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap {
            guard captureGroup < $0.numberOfRanges,
                  let swiftRange = Range($0.range(at: captureGroup), in: text)
            else { return nil }
            return String(text[swiftRange])
        }
    }

    private func normalizedWords(in text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private func occurrenceCounts(
        _ values: [String],
        caseSensitive: Bool
    ) -> [String: Int] {
        values.reduce(into: [:]) {
            $0[caseSensitive ? $1 : $1.lowercased(), default: 0] += 1
        }
    }

    private func requiresTerminalPunctuation(_ source: String) -> Bool {
        !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func hasTerminalPunctuation(_ candidate: String) -> Bool {
        var trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let closingCharacters: Set<Character> = [
            "\"", "'", "”", "’", "»", "›", ")", "]", "}",
        ]
        while let last = trimmed.last, closingCharacters.contains(last) {
            trimmed.removeLast()
        }
        guard let last = trimmed.last else {
            return false
        }
        return ".!?…".contains(last)
    }

    private static let negationTerms: Set<String> = [
        "kein", "keine", "keinen", "keinem", "keiner", "keines", "nicht", "nie",
        "niemals", "noch nicht", "no", "not", "never", "don't", "doesn't", "didn't",
        "can't", "cannot", "won't", "shouldn't", "mustn't",
    ]
    private static let listMarkers: Set<String> = [
        "erstens", "zweitens", "drittens", "viertens", "fünftens",
        "first", "second", "third", "fourth", "fifth",
    ]
    private static let unambiguousFillers: Set<String> = [
        "ah", "äh", "ähm", "hm", "hmm", "mhm", "uh", "uhm", "umm",
    ]
    private static let knownProducts: Set<String> = [
        "AirPods", "Apple", "Backend", "ChatGPT", "Claude", "Copilot", "GitHub",
        "macOS", "OpenAI", "OpenWritr", "SwiftUI", "Xcode",
    ]
    private static let technicalPhrases: Set<String> = [
        "backward compatible", "feature flag", "health check", "pull request",
        "staging environment",
    ]
    private static let germanIndicators: Set<String> = [
        "aber", "als", "am", "auch", "auf", "das", "den", "der", "die", "ein",
        "eine", "für", "ich", "im", "ist", "mit", "nach", "nicht", "noch",
        "oder", "sondern", "und", "vom", "von", "wir", "zu",
    ]
    private static let englishIndicators: Set<String> = [
        "a", "and", "are", "as", "at", "but", "by", "for", "from", "in", "is",
        "it", "not", "of", "on", "or", "that", "the", "this", "to", "we", "with",
    ]
}
