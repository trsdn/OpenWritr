import AppKit
import Testing
@testable import OpenWritr

@MainActor
@Suite("PasteManager")
struct PasteManagerTests {
    @Test func emptyClipboardPastesAndRestoresEmpty() {
        let pasteboard = FakePasteboard(items: [], returnsNilItemsWhenEmpty: true)
        let poster = FakePasteCommandPoster()
        let manager = PasteManager(pasteboard: pasteboard, commandPoster: poster)

        manager.pasteText("Synthetic transcript")

        #expect(pasteboard.text == "Synthetic transcript")
        #expect(poster.postCount == 1)

        manager.flushPendingRestore()

        #expect(pasteboard.items.isEmpty)
        #expect(pasteboard.clearCount == 2)
    }

    @Test func savesReplacesPastesAndRestoresClipboard() {
        let pasteboard = FakePasteboard(items: [.text("Original clipboard")])
        let poster = FakePasteCommandPoster()
        let manager = PasteManager(pasteboard: pasteboard, commandPoster: poster)

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
        let manager = PasteManager(pasteboard: pasteboard, commandPoster: poster)

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
        let manager = PasteManager(pasteboard: pasteboard, commandPoster: poster)

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
        let manager = PasteManager(pasteboard: pasteboard, commandPoster: poster)

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
        let manager = PasteManager(pasteboard: pasteboard, commandPoster: poster)

        manager.pasteText("Synthetic transcript")

        #expect(pasteboard.items.map(\.pasteboardTypes) == [[.string], [.fileURL]])
        #expect(pasteboard.clearCount == 0)
        #expect(poster.postCount == 0)
    }

    @Test func secondPasteRestoresOriginalClipboardAfterPendingRestore() {
        let pasteboard = FakePasteboard(items: [.text("Original clipboard")])
        let poster = FakePasteCommandPoster()
        let manager = PasteManager(pasteboard: pasteboard, commandPoster: poster)

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
        let manager = PasteManager(pasteboard: pasteboard, commandPoster: poster)

        manager.pasteText("Synthetic transcript")
        pasteboard.replaceExternally(with: [.text("External clipboard")])
        manager.flushPendingRestore()

        #expect(pasteboard.text == "External clipboard")
        #expect(poster.postCount == 1)
    }

    @Test func restorePreparationFailureLeavesCurrentClipboardUntouched() {
        let pasteboard = FakePasteboard(items: [.text("Original clipboard")])
        let poster = FakePasteCommandPoster()
        let manager = PasteManager(pasteboard: pasteboard, commandPoster: poster)

        manager.pasteText("Synthetic transcript")
        pasteboard.failNextPreparation = true
        manager.flushPendingRestore()

        #expect(pasteboard.text == "Synthetic transcript")
        #expect(pasteboard.clearCount == 1)
        #expect(poster.postCount == 1)
    }

    @Test func priorRestoreFailureCancelsNextPasteWithoutClearing() {
        let pasteboard = FakePasteboard(items: [.text("Original clipboard")])
        let poster = FakePasteCommandPoster()
        let manager = PasteManager(pasteboard: pasteboard, commandPoster: poster)

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
        let manager = PasteManager(
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
    private var scheduledAction: (@MainActor () -> Void)?

    func scheduleRestore(_ action: @escaping @MainActor () -> Void) {
        scheduledAction = action
    }

    func runScheduledRestore() {
        let action = scheduledAction
        scheduledAction = nil
        action?()
    }
}

@MainActor
private final class FakePasteboard: PasteboardManaging {
    private(set) var changeCount = 0
    private(set) var clearCount = 0
    private(set) var items: [FakePasteboardItem]
    var mutateWhenReading: [FakePasteboardItem]?
    var failNextPreparation = false
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
