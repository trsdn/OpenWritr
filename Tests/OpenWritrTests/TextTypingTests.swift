import AppKit
import Testing
@testable import OpenWritr

@Suite("Text typing plan")
struct TextTypingPlanTests {
    private let layout: [Character: KeyStroke] = {
        var map: [Character: KeyStroke] = [:]
        map["a"] = KeyStroke(keyCode: 0, shift: false)
        map["A"] = KeyStroke(keyCode: 0, shift: true)
        map["b"] = KeyStroke(keyCode: 11, shift: false)
        map["ä"] = KeyStroke(keyCode: 39, shift: false)
        map[" "] = KeyStroke(keyCode: 49, shift: false)
        map["\""] = KeyStroke(keyCode: 19, shift: true)
        map["'"] = KeyStroke(keyCode: 42, shift: true)
        map["-"] = KeyStroke(keyCode: 44, shift: false)
        map["."] = KeyStroke(keyCode: 47, shift: false)
        return map
    }()

    @Test func charactersMapToTheirKeysInOrder() {
        let plan = TextTypingPlanner.plan(for: "aAb ä", layout: layout)

        #expect(plan.strokes == [
            KeyStroke(keyCode: 0, shift: false),
            KeyStroke(keyCode: 0, shift: true),
            KeyStroke(keyCode: 11, shift: false),
            KeyStroke(keyCode: 49, shift: false),
            KeyStroke(keyCode: 39, shift: false),
        ])
        #expect(plan.skippedCharacters == 0)
    }

    @Test func newlinesAndTabsBecomeKeyPresses() {
        let plan = TextTypingPlanner.plan(for: "a\nb\r\nc\rd\te", layout: layout)

        #expect(plan.strokes.filter { $0 == TextTypingPlanner.returnStroke }.count == 3)
        #expect(plan.strokes.filter { $0 == TextTypingPlanner.tabStroke }.count == 1)
        #expect(plan.skippedCharacters == 3, "c, d and e are not in the synthetic layout")
    }

    @Test func typographicCharactersAreReplacedByPlainOnes() {
        let plan = TextTypingPlanner.plan(for: "\u{201E}a\u{201C} \u{2013} \u{2019}\u{2026}", layout: layout)
        let quote = layout["\""]!
        let apostrophe = layout["'"]!
        let dash = layout["-"]!
        let dot = layout["."]!
        let space = layout[" "]!
        let a = layout["a"]!

        #expect(plan.strokes == [quote, a, quote, space, dash, space, apostrophe, dot, dot, dot])
        #expect(plan.skippedCharacters == 0)
    }

    @Test func untypeableCharactersAreSkippedAndCounted() {
        let plan = TextTypingPlanner.plan(for: "a😀b€", layout: layout)

        #expect(plan.strokes == [layout["a"]!, layout["b"]!])
        #expect(plan.skippedCharacters == 2)
    }

    @Test func replacementIsSkippedWhenTheLayoutLacksItsCharacters() {
        var small = layout
        small["\""] = nil

        let plan = TextTypingPlanner.plan(for: "\u{201C}", layout: small)

        #expect(plan.strokes.isEmpty)
        #expect(plan.skippedCharacters == 1)
    }

    @Test func decomposedAccentsAreComposedBeforeMapping() {
        let plan = TextTypingPlanner.plan(for: "a\u{0308}", layout: layout)

        #expect(plan.strokes == [layout["ä"]!])
        #expect(plan.skippedCharacters == 0)
    }

    @Test func onlyTheWindowsAppIsTreatedAsRemoteDesktop() {
        #expect(SystemRemoteDesktopDetector.bundleIdentifiers == ["com.microsoft.rdc.macos"])
    }
}

@MainActor
@Suite("System keyboard layout")
struct SystemKeyboardLayoutTests {
    @Test func everyMappedCharacterRoundTripsThroughTheRealLayout() throws {
        let map = try #require(SystemKeyboardLayout.currentCharacterMap())

        #expect(map.count > 40)
        for (character, stroke) in map {
            #expect(
                SystemKeyboardLayout.character(forKeyCode: stroke.keyCode, shift: stroke.shift) == character,
                "Key \(stroke.keyCode) shift \(stroke.shift) does not type \(character)"
            )
        }
    }

    @Test func lettersUseTheUnshiftedKeyAndCapitalsAddShift() throws {
        let map = try #require(SystemKeyboardLayout.currentCharacterMap())
        let lower = try #require(map["e"])
        let upper = try #require(map["E"])

        #expect(!lower.shift)
        #expect(upper.shift)
        #expect(lower.keyCode == upper.keyCode)
    }

    @Test func controlCharactersAreNeverMapped() throws {
        let map = try #require(SystemKeyboardLayout.currentCharacterMap())

        for character in map.keys {
            let value = try #require(character.unicodeScalars.first?.value)
            #expect(value >= 0x20 && value != 0x7F)
        }
    }
}

@MainActor
@Suite("Typing into remote desktop apps")
struct RemoteDesktopTypingTests {
    @Test func typesWhenARemoteDesktopIsFrontmostWithoutTouchingTheClipboard() {
        let setup = makeSetup(remote: true)

        #expect(setup.manager.typeTextIfRemoteDesktop("Synthetic text.") == .pasted)

        #expect(setup.typer.typedTexts == ["Synthetic text."])
        #expect(setup.poster.postCount == 0)
        #expect(setup.pasteboard.changeCount == setup.initialChangeCount)
        #expect(setup.manager.lastError == nil)
    }

    @Test func fallsBackToPastingWhenAnotherAppIsFrontmost() {
        let setup = makeSetup(remote: false)

        #expect(setup.manager.typeTextIfRemoteDesktop("Synthetic text.") == nil)
        #expect(setup.typer.typedTexts.isEmpty)

        #expect(setup.manager.outputText(
            "Synthetic text.",
            destination: .standard,
            autoPasteEnabled: true,
            typeIntoRemoteDesktops: true
        ) == .pasted)
        #expect(setup.poster.postCount == 1)
        #expect(setup.typer.typedTexts.isEmpty)
    }

    @Test func failureCancelsWithATypingErrorAndKeepsTheClipboard() {
        let setup = makeSetup(remote: true)
        setup.typer.succeeds = false

        #expect(setup.manager.typeTextIfRemoteDesktop("Synthetic text.") == .cancelled)

        #expect(setup.manager.lastError == .typingFailed)
        #expect(setup.poster.postCount == 0)
        #expect(setup.pasteboard.changeCount == setup.initialChangeCount)
    }

    @Test(arguments: [
        (RecordingOutputDestination.standard, true, true, "typed"),
        (.standard, true, false, "pasted"),
        (.standard, false, true, "retained"),
        (.clipboard, true, true, "copied"),
    ])
    func outputRoutingRespectsTheOptionAndDestination(
        destination: RecordingOutputDestination,
        autoPaste: Bool,
        typeOption: Bool,
        expected: String
    ) {
        let setup = makeSetup(remote: true)

        let outcome = setup.manager.outputText(
            "Synthetic text.",
            destination: destination,
            autoPasteEnabled: autoPaste,
            typeIntoRemoteDesktops: typeOption
        )

        switch expected {
        case "typed":
            #expect(outcome == .pasted)
            #expect(setup.typer.typedTexts == ["Synthetic text."])
            #expect(setup.poster.postCount == 0)
        case "pasted":
            #expect(outcome == .pasted)
            #expect(setup.typer.typedTexts.isEmpty)
            #expect(setup.poster.postCount == 1)
        case "retained":
            #expect(outcome == .retained)
            #expect(setup.typer.typedTexts.isEmpty)
            #expect(setup.poster.postCount == 0)
        default:
            #expect(outcome == .copied)
            #expect(setup.typer.typedTexts.isEmpty)
            #expect(setup.poster.postCount == 0)
        }
    }

    @Test func pendingClipboardRestoreIsFlushedBeforeTyping() {
        let setup = makeSetup(remote: false)
        setup.pasteboard.clearContents()
        #expect(setup.manager.pasteText("Earlier paste.") == .pasted)
        #expect(setup.pasteboard.string(forType: .string) == "Earlier paste.")

        setup.detector.isRemote = true
        #expect(setup.manager.typeTextIfRemoteDesktop("Synthetic text.") == .pasted)

        #expect(setup.pasteboard.string(forType: .string) != "Earlier paste.")
    }

    private func makeSetup(remote: Bool) -> TypingSetup {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("Original clipboard", forType: .string)
        let typer = RecordingTextTyper()
        let detector = StubRemoteDesktopDetector(isRemote: remote)
        let poster = CountingPasteCommandPoster()
        let manager = PasteManager(
            pasteboard: SystemPasteboard(pasteboard),
            commandPoster: poster,
            restoreScheduler: NeverRunsRestoreScheduler(),
            errorLogger: SilentErrorLogger(),
            textTyper: typer,
            remoteDesktopDetector: detector
        )
        return TypingSetup(
            manager: manager,
            pasteboard: pasteboard,
            typer: typer,
            detector: detector,
            poster: poster,
            initialChangeCount: pasteboard.changeCount
        )
    }
}

@MainActor
private struct TypingSetup {
    let manager: PasteManager
    let pasteboard: NSPasteboard
    let typer: RecordingTextTyper
    let detector: StubRemoteDesktopDetector
    let poster: CountingPasteCommandPoster
    let initialChangeCount: Int
}

@MainActor
private final class RecordingTextTyper: TextTyping {
    var succeeds = true
    private(set) var typedTexts: [String] = []

    func typeText(_ text: String) -> Bool {
        guard succeeds else { return false }
        typedTexts.append(text)
        return true
    }
}

@MainActor
private final class StubRemoteDesktopDetector: RemoteDesktopDetecting {
    var isRemote: Bool

    init(isRemote: Bool) {
        self.isRemote = isRemote
    }

    func isRemoteDesktopFrontmost() -> Bool { isRemote }
}

@MainActor
private final class CountingPasteCommandPoster: PasteCommandPosting {
    private(set) var postCount = 0

    func postPasteCommand() {
        postCount += 1
    }
}

@MainActor
private struct NeverRunsRestoreScheduler: PasteRestoreScheduling {
    func scheduleRestore(_ action: @escaping @MainActor () -> Void) {}
}

@MainActor
private struct SilentErrorLogger: ErrorLogging {
    func logError(_ message: String) {}
}
