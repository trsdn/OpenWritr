import AppKit
import Testing
@testable import OpenWritr

@Suite("Text typing plan")
struct TextTypingPlanTests {
    @Test func plainTextIsOneChunk() {
        #expect(TextTypingPlan.units(for: "Hello world.") == [.text("Hello world.")])
        #expect(TextTypingPlan.units(for: "").isEmpty)
    }

    @Test func newlinesAndTabsBecomeKeyPresses() {
        #expect(TextTypingPlan.units(for: "a\nb\r\nc\rd\te") == [
            .text("a"), .returnKey, .text("b"), .returnKey, .text("c"), .returnKey,
            .text("d"), .tabKey, .text("e"),
        ])
        #expect(TextTypingPlan.units(for: "\n\n") == [.returnKey, .returnKey])
    }

    @Test func longTextIsSplitWithoutLosingOrReorderingCharacters() {
        let text = "Ein längerer Satz mit Umlauten: äöü ß, and some English words."
        let units = TextTypingPlan.units(for: text)

        #expect(units.count > 1)
        var rebuilt = ""
        for unit in units {
            guard case .text(let chunk) = unit else {
                Issue.record("Unexpected key press in plain text")
                return
            }
            #expect(chunk.utf16.count <= TextTypingPlan.maximumChunkUTF16Units)
            rebuilt += chunk
        }
        #expect(rebuilt == text)
    }

    @Test func chunksNeverSplitEmojiOrCombiningCharacters() {
        let family = "👨‍👩‍👧‍👦"
        let combining = "e\u{0301}"
        let text = String(repeating: "x", count: 14) + family + combining + "tail"
        let chunks = TextTypingPlan.units(for: text).compactMap { unit -> String? in
            if case .text(let chunk) = unit { return chunk }
            return nil
        }

        #expect(chunks.joined() == text)
        #expect(chunks.contains { $0.contains(family) })
        #expect(chunks.contains { $0.contains(combining) })
        for chunk in chunks {
            #expect(chunk.utf16.count <= TextTypingPlan.maximumChunkUTF16Units
                || chunk.count == 1)
        }
    }

    @Test func onlyTheWindowsAppIsTreatedAsRemoteDesktop() {
        #expect(SystemRemoteDesktopDetector.bundleIdentifiers == ["com.microsoft.rdc.macos"])
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
