import AppKit
import Testing
@testable import OpenWritr

@MainActor
@Suite("PasteManager")
struct PasteManagerTests {
    @Test func emptyClipboardPastesAndRestoresEmpty() {
        let pasteboard = FakePasteboard(items: [], returnsNilItemsWhenEmpty: true)
        let poster = FakePasteCommandPoster()
        let manager = makeManager(pasteboard: pasteboard, commandPoster: poster)

        manager.pasteText("Synthetic transcript")

        #expect(pasteboard.text == "Synthetic transcript")
        #expect(poster.postCount == 1)

        manager.flushPendingRestore()

        #expect(pasteboard.items.isEmpty)
        #expect(pasteboard.clearCount == 2)
    }

    @Test(arguments: [RecordingOutputDestination.standard, .clipboard])
    func unreadableStringIsNotAssumedEmpty(destination: RecordingOutputDestination) {
        let pasteboard = FakePasteboard(items: [.unreadable(type: .string)])
        let poster = FakePasteCommandPoster()
        let manager = makeManager(pasteboard: pasteboard, commandPoster: poster)

        #expect(manager.outputText(
            "Synthetic transcript",
            destination: destination,
            autoPasteEnabled: true
        ) == .cancelled)
        #expect(manager.lastError == .unreadableRepresentation(NSPasteboard.PasteboardType.string.rawValue))
        #expect(poster.postCount == 0)
        manager.flushPendingRestore()
        #expect(pasteboard.items.count == 1)
        #expect(pasteboard.clearCount == 0)
    }

    @Test func actualAppKitUnwrittenTextIsPreservedWithoutPasting() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.string], owner: nil)
        #expect(pasteboard.pasteboardItems?.count == 1)
        #expect(pasteboard.data(forType: .string) == nil)
        let poster = FakePasteCommandPoster()
        let manager = makeManager(pasteboard: SystemPasteboard(pasteboard), commandPoster: poster)

        let originalChangeCount = pasteboard.changeCount
        #expect(manager.pasteText("Synthetic transcript") == .cancelled)
        #expect(manager.lastError == .unreadableRepresentation(NSPasteboard.PasteboardType.string.rawValue))
        manager.flushPendingRestore()
        #expect(poster.postCount == 0)
        #expect(pasteboard.changeCount == originalChangeCount)
        #expect(pasteboard.pasteboardItems?.count == 1)
        #expect(pasteboard.data(forType: .string) == nil)
    }

    @Test func actualAppKitEmptyClipboardPastesAndRestores() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let poster = FakePasteCommandPoster()
        let manager = makeManager(pasteboard: SystemPasteboard(pasteboard), commandPoster: poster)

        #expect(manager.pasteText("Synthetic transcript") == .pasted)
        manager.flushPendingRestore()
        #expect(poster.postCount == 1)
        #expect((pasteboard.pasteboardItems ?? []).isEmpty)
    }

    @Test func emptyStringIsPreservedAsText() {
        let pasteboard = FakePasteboard(items: [.text("")])
        let manager = makeManager(pasteboard: pasteboard, commandPoster: FakePasteCommandPoster())

        #expect(manager.pasteText("Synthetic transcript") == .pasted)
        manager.flushPendingRestore()
        #expect(pasteboard.text?.isEmpty == true)
        #expect(pasteboard.items.count == 1)
    }

    @Test func allReadableItemsAndRepresentationsArePreserved() {
        let first = FakePasteboardItem(PasteboardItemContent(representations: [
            .init(type: .string, data: Data("Original".utf8)),
            .init(type: .png, data: Data([0, 1, 2, 255]))
        ]))
        let pasteboard = FakePasteboard(items: [first, .text("Second item")])
        let manager = makeManager(pasteboard: pasteboard, commandPoster: FakePasteCommandPoster())

        #expect(manager.pasteText("Synthetic transcript") == .pasted)
        manager.flushPendingRestore()
        #expect(pasteboard.items.count == 2)
        #expect(pasteboard.items[0].data == first.data)
        #expect(pasteboard.items[1].data == [.string: Data("Second item".utf8)])
    }

    @Test(arguments: [false, true])
    func clipboardOnlyIgnoresAutoPaste(autoPasteEnabled: Bool) {
        let pasteboard = FakePasteboard(items: [.text("Original")])
        let poster = FakePasteCommandPoster()
        let manager = makeManager(pasteboard: pasteboard, commandPoster: poster)

        #expect(manager.outputText("Copied result", destination: .clipboard, autoPasteEnabled: autoPasteEnabled) == .copied)
        manager.flushPendingRestore()
        #expect(pasteboard.text == "Copied result")
        #expect(poster.postCount == 0)
    }

    @Test func standardOutputWithAutoPasteOffDoesNotTouchClipboard() {
        let pasteboard = FakePasteboard(items: [.text("Original")])
        let poster = FakePasteCommandPoster()
        let manager = makeManager(pasteboard: pasteboard, commandPoster: poster)

        #expect(manager.outputText("Retained result", destination: .standard, autoPasteEnabled: false) == .retained)
        #expect(pasteboard.text == "Original")
        #expect(pasteboard.clearCount == 0)
        #expect(poster.postCount == 0)
    }

    @Test func oldDelayedRestoresCannotOverwriteCopyOrNewPaste() {
        let pasteboard = FakePasteboard(items: [.text("Original")])
        let scheduler = FakePasteRestoreScheduler()
        let manager = makeManager(
            pasteboard: pasteboard,
            commandPoster: FakePasteCommandPoster(),
            restoreScheduler: scheduler
        )

        #expect(manager.pasteText("First result") == .pasted)
        #expect(manager.pasteText("Second result") == .pasted)
        scheduler.runScheduledRestore()
        #expect(pasteboard.text == "Second result")
        #expect(manager.copyText("Copied result") == .copied)
        scheduler.runScheduledRestore()
        #expect(pasteboard.text == "Copied result")
    }

    @Test func copyPreparationFailureLeavesClipboardUntouched() {
        let pasteboard = FakePasteboard(items: [.text("Original")])
        let manager = makeManager(pasteboard: pasteboard, commandPoster: FakePasteCommandPoster())
        pasteboard.failNextPreparation = true

        #expect(manager.copyText("Copied result") == .cancelled)
        #expect(manager.lastError == .preparationFailed)
        #expect(pasteboard.text == "Original")
        #expect(pasteboard.clearCount == 0)
    }

    @Test func failedWriteRollsBackOriginalAndReportsError() {
        let pasteboard = FakePasteboard(items: [.text("Original")])
        let manager = makeManager(pasteboard: pasteboard, commandPoster: FakePasteCommandPoster())
        pasteboard.failedWritesRemaining = 1

        #expect(manager.copyText("Copied result") == .cancelled)
        #expect(manager.lastError == .writeFailed)
        #expect(pasteboard.text == "Original")
    }

    @Test func failedRollbackIsReported() {
        let pasteboard = FakePasteboard(items: [.text("Original")])
        let manager = makeManager(pasteboard: pasteboard, commandPoster: FakePasteCommandPoster())
        pasteboard.failedWritesRemaining = 2

        #expect(manager.copyText("Copied result") == .cancelled)
        #expect(manager.lastError == .rollbackFailed)
    }

    @Test func delayedRestoreFailureIsReportedImmediately() {
        let pasteboard = FakePasteboard(items: [.text("Original")])
        let scheduler = FakePasteRestoreScheduler()
        let manager = makeManager(
            pasteboard: pasteboard,
            commandPoster: FakePasteCommandPoster(),
            restoreScheduler: scheduler
        )
        var error: PasteManagerError?
        manager.onRestoreFailed = { error = $0 }

        #expect(manager.pasteText("Synthetic transcript") == .pasted)
        pasteboard.failNextPreparation = true
        scheduler.runScheduledRestore()
        #expect(error == .restoreFailed)
    }

    @Test(arguments: [false, true])
    func reportedRestoreFailureDoesNotCancelNextOutput(delayed: Bool) {
        let pasteboard = FakePasteboard(items: [.text("Original")])
        let scheduler = FakePasteRestoreScheduler()
        let manager = makeManager(
            pasteboard: pasteboard,
            commandPoster: FakePasteCommandPoster(),
            restoreScheduler: scheduler
        )
        var error: PasteManagerError?
        manager.onRestoreFailed = { error = $0 }
        #expect(manager.pasteText("First transcript") == .pasted)
        pasteboard.failNextPreparation = true

        if delayed {
            scheduler.runScheduledRestore()
        } else {
            manager.flushPendingRestore()
        }

        #expect(error == .restoreFailed)
        #expect(manager.copyText("Next transcript") == .copied)
        #expect(pasteboard.text == "Next transcript")
    }

    @Test func savesReplacesPastesAndRestoresClipboard() {
        let pasteboard = FakePasteboard(items: [.text("Original clipboard")])
        let poster = FakePasteCommandPoster()
        let manager = makeManager(pasteboard: pasteboard, commandPoster: poster)

        manager.pasteText("Synthetic transcript")

        #expect(pasteboard.text == "Synthetic transcript")
        #expect(poster.postCount == 1)

        manager.flushPendingRestore()

        #expect(pasteboard.text == "Original clipboard")
    }

    @Test func clipboardMutationDuringSaveCancelsPaste() {
        let pasteboard = FakePasteboard(items: [.text("Original clipboard")])
        pasteboard.mutateWhenReading = [.text("External clipboard")]
        let poster = FakePasteCommandPoster()
        let manager = makeManager(pasteboard: pasteboard, commandPoster: poster)

        manager.pasteText("Synthetic transcript")

        #expect(pasteboard.text == "External clipboard")
        #expect(poster.postCount == 0)
    }

    @Test func unreadableRepresentationCancelsPasteToPreserveWholeItem() {
        let pasteboard = FakePasteboard(
            items: [
                .mixed(
                    readableText: "Restorable clipboard",
                    unreadableType: .fileURL
                )
            ]
        )
        let poster = FakePasteCommandPoster()
        let manager = makeManager(pasteboard: pasteboard, commandPoster: poster)

        let outcome = manager.pasteText("Synthetic transcript")

        #expect(outcome == .cancelled)
        #expect(pasteboard.text == "Restorable clipboard")
        #expect(pasteboard.items.first?.pasteboardTypes == [.string, .fileURL])
        #expect(pasteboard.clearCount == 0)
        #expect(poster.postCount == 0)
    }

    @Test func unreadableOnlyClipboardCancelsPasteWithoutClearing() {
        let pasteboard = FakePasteboard(items: [.unreadable(type: .fileURL)])
        let poster = FakePasteCommandPoster()
        let manager = makeManager(pasteboard: pasteboard, commandPoster: poster)

        manager.pasteText("Synthetic transcript")

        #expect(pasteboard.items.first?.pasteboardTypes == [.fileURL])
        #expect(pasteboard.clearCount == 0)
        #expect(poster.postCount == 0)
    }

    @Test func unreadableItemAmongReadableItemsCancelsPasteWithoutClearing() {
        let pasteboard = FakePasteboard(
            items: [
                .text("Restorable clipboard"),
                .unreadable(type: .fileURL)
            ]
        )
        let poster = FakePasteCommandPoster()
        let manager = makeManager(pasteboard: pasteboard, commandPoster: poster)

        manager.pasteText("Synthetic transcript")

        #expect(pasteboard.items.map(\.pasteboardTypes) == [[.string], [.fileURL]])
        #expect(pasteboard.clearCount == 0)
        #expect(poster.postCount == 0)
    }

    @Test func secondPasteRestoresOriginalClipboardAfterPendingRestore() {
        let pasteboard = FakePasteboard(items: [.text("Original clipboard")])
        let poster = FakePasteCommandPoster()
        let manager = makeManager(pasteboard: pasteboard, commandPoster: poster)

        manager.pasteText("First synthetic transcript")
        manager.pasteText("Second synthetic transcript")

        #expect(pasteboard.text == "Second synthetic transcript")
        #expect(poster.postCount == 2)

        manager.flushPendingRestore()

        #expect(pasteboard.text == "Original clipboard")
    }

    @Test func externalClipboardChangePreventsRestoreOverwrite() {
        let pasteboard = FakePasteboard(items: [.text("Original clipboard")])
        let poster = FakePasteCommandPoster()
        let manager = makeManager(pasteboard: pasteboard, commandPoster: poster)

        manager.pasteText("Synthetic transcript")
        pasteboard.replaceExternally(with: [.text("External clipboard")])
        manager.flushPendingRestore()

        #expect(pasteboard.text == "External clipboard")
        #expect(poster.postCount == 1)
    }

    @Test func restorePreparationFailureLeavesCurrentClipboardUntouched() {
        let pasteboard = FakePasteboard(items: [.text("Original clipboard")])
        let poster = FakePasteCommandPoster()
        let errorLogger = RecordingPasteErrorLogger()
        let manager = PasteManager(
            pasteboard: pasteboard,
            commandPoster: poster,
            errorLogger: errorLogger
        )

        manager.pasteText("Synthetic transcript")
        pasteboard.failNextPreparation = true
        manager.flushPendingRestore()

        #expect(pasteboard.text == "Synthetic transcript")
        #expect(pasteboard.clearCount == 1)
        #expect(poster.postCount == 1)
        #expect(errorLogger.messages == ["Failed to prepare clipboard contents for restoration"])
    }

    @Test func priorRestoreFailureCancelsNextPasteWithoutClearing() {
        let pasteboard = FakePasteboard(items: [.text("Original clipboard")])
        let poster = FakePasteCommandPoster()
        let manager = makeManager(pasteboard: pasteboard, commandPoster: poster)

        #expect(manager.pasteText("First synthetic transcript") == .pasted)
        pasteboard.failNextPreparation = true

        let outcome = manager.pasteText("Second synthetic transcript")

        #expect(outcome == .cancelled)
        #expect(pasteboard.text == "First synthetic transcript")
        #expect(pasteboard.clearCount == 1)
        #expect(poster.postCount == 1)
    }

    @Test func delayedRestoreFailureCancelsNextPasteThenAllowsRecovery() {
        let pasteboard = FakePasteboard(items: [.text("Original clipboard")])
        let poster = FakePasteCommandPoster()
        let scheduler = FakePasteRestoreScheduler()
        let manager = makeManager(
            pasteboard: pasteboard,
            commandPoster: poster,
            restoreScheduler: scheduler
        )

        #expect(manager.pasteText("First synthetic transcript") == .pasted)
        pasteboard.failNextPreparation = true
        scheduler.runScheduledRestore()

        #expect(manager.pasteText("Second synthetic transcript") == .cancelled)
        #expect(pasteboard.text == "First synthetic transcript")
        #expect(poster.postCount == 1)

        pasteboard.replaceExternally(with: [.text("Replacement clipboard")])

        #expect(manager.pasteText("Third synthetic transcript") == .pasted)
        manager.flushPendingRestore()

        #expect(pasteboard.text == "Replacement clipboard")
        #expect(poster.postCount == 2)
    }

    private func makeManager(
        pasteboard: any PasteboardManaging,
        commandPoster: any PasteCommandPosting,
        restoreScheduler: any PasteRestoreScheduling = SystemPasteRestoreScheduler()
    ) -> PasteManager {
        PasteManager(
            pasteboard: pasteboard,
            commandPoster: commandPoster,
            restoreScheduler: restoreScheduler,
            errorLogger: NoOpPasteErrorLogger()
        )
    }
}

@MainActor
private struct NoOpPasteErrorLogger: ErrorLogging {
    func logError(_ message: String) {}
}

@MainActor
private final class RecordingPasteErrorLogger: ErrorLogging {
    private(set) var messages: [String] = []

    func logError(_ message: String) {
        messages.append(message)
    }
}

@MainActor
private final class FakePasteCommandPoster: PasteCommandPosting {
    private(set) var postCount = 0

    func postPasteCommand() {
        postCount += 1
    }
}

@MainActor
private final class FakePasteRestoreScheduler: PasteRestoreScheduling {
    private var scheduledActions: [@MainActor () -> Void] = []

    func scheduleRestore(_ action: @escaping @MainActor () -> Void) {
        scheduledActions.append(action)
    }

    func runScheduledRestore() {
        guard !scheduledActions.isEmpty else { return }
        scheduledActions.removeFirst()()
    }
}

@MainActor
private final class FakePasteboard: PasteboardManaging {
    private(set) var changeCount = 0
    private(set) var clearCount = 0
    private(set) var items: [FakePasteboardItem]
    var mutateWhenReading: [FakePasteboardItem]?
    var failNextPreparation = false
    var failedWritesRemaining = 0
    private let returnsNilItemsWhenEmpty: Bool

    init(
        items: [FakePasteboardItem],
        returnsNilItemsWhenEmpty: Bool = false
    ) {
        self.items = items
        self.returnsNilItemsWhenEmpty = returnsNilItemsWhenEmpty
    }

    var pasteboardItems: [any PasteboardItemReading]? {
        if returnsNilItemsWhenEmpty, items.isEmpty {
            return nil
        }
        let currentItems = items
        if let mutation = mutateWhenReading {
            mutateWhenReading = nil
            replaceExternally(with: mutation)
        }
        return currentItems
    }

    var text: String? {
        guard let data = items.first?.data[.string] else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func prepareWrite(_ items: [PasteboardItemContent]) -> (any PreparedPasteboardWrite)? {
        if failNextPreparation {
            failNextPreparation = false
            return nil
        }
        return FakePreparedPasteboardWrite(pasteboard: self, items: items)
    }

    func replaceExternally(with items: [FakePasteboardItem]) {
        self.items = items
        changeCount += 1
    }

    @discardableResult
    func clearContents() -> Int {
        items = []
        clearCount += 1
        changeCount += 1
        return changeCount
    }

    fileprivate func writeItems(_ items: [PasteboardItemContent]) -> Bool {
        if failedWritesRemaining > 0 {
            failedWritesRemaining -= 1
            return false
        }
        self.items = items.map(FakePasteboardItem.init)
        changeCount += 1
        return true
    }
}

@MainActor
private final class FakePreparedPasteboardWrite: PreparedPasteboardWrite {
    private unowned let pasteboard: FakePasteboard
    private let items: [PasteboardItemContent]

    init(pasteboard: FakePasteboard, items: [PasteboardItemContent]) {
        self.pasteboard = pasteboard
        self.items = items
    }

    func write() -> Bool {
        pasteboard.writeItems(items)
    }
}

@MainActor
private struct FakePasteboardItem: PasteboardItemReading {
    let declaredTypes: [NSPasteboard.PasteboardType]
    let data: [NSPasteboard.PasteboardType: Data]

    var pasteboardTypes: [NSPasteboard.PasteboardType] {
        declaredTypes
    }

    init(_ content: PasteboardItemContent) {
        declaredTypes = content.representations.map(\.type)
        data = Dictionary(
            uniqueKeysWithValues: content.representations.map { ($0.type, $0.data) }
        )
    }

    private init(
        declaredTypes: [NSPasteboard.PasteboardType],
        data: [NSPasteboard.PasteboardType: Data]
    ) {
        self.declaredTypes = declaredTypes
        self.data = data
    }

    static func text(_ value: String) -> FakePasteboardItem {
        FakePasteboardItem(
            declaredTypes: [.string],
            data: [.string: Data(value.utf8)]
        )
    }

    static func unreadable(type: NSPasteboard.PasteboardType) -> FakePasteboardItem {
        FakePasteboardItem(declaredTypes: [type], data: [:])
    }

    static func mixed(
        readableText: String,
        unreadableType: NSPasteboard.PasteboardType
    ) -> FakePasteboardItem {
        FakePasteboardItem(
            declaredTypes: [.string, unreadableType],
            data: [.string: Data(readableText.utf8)]
        )
    }

    func pasteboardData(forType type: NSPasteboard.PasteboardType) -> Data? {
        data[type]
    }
}
