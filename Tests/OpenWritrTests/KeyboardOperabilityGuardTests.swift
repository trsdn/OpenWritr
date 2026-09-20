import Foundation
import Testing

/// Guards criterion X01 by construction: every interactive element is a platform
/// control (`Button`, `Toggle`, `Picker`, `Link`, `TextEditor`, `SettingsLink`),
/// which macOS makes keyboard-operable and gives a focus ring. Interaction that
/// only a pointer can trigger, or that hides the focus ring, would break that.
@Suite("Keyboard operability guard")
struct KeyboardOperabilityGuardTests {
    private static let pointerOnlyPatterns = [
        "onTapGesture", "TapGesture", "DragGesture", "LongPressGesture",
        "MagnifyGesture", ".onHover", ".focusable(false)", ".focusEffectDisabled",
    ]

    /// File name → number of occurrences that were reviewed and accepted.
    private static let reviewedExceptions: [String: Int] = [:]

    private static var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OpenWritrTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("Sources/OpenWritr")
    }

    @Test func noPointerOnlyInteractionBeyondReviewedExceptions() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: Self.sourcesDirectory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "source directory not found at \(Self.sourcesDirectory.path)")

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            // Count lines, so "onTapGesture" is not also counted as "TapGesture".
            let lines = text.split(separator: "\n").filter { line in
                Self.pointerOnlyPatterns.contains { line.contains($0) }
            }.count
            let allowed = Self.reviewedExceptions[file.lastPathComponent] ?? 0
            #expect(
                lines == allowed,
                "\(file.lastPathComponent) has \(lines) pointer-only construct(s), \(allowed) reviewed. Use a platform control, or review and add an exception."
            )
        }
    }
}
