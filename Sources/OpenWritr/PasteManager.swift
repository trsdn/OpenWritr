import Cocoa
import os.log

private let pasteLog = Logger(subsystem: "com.openwritr.app", category: "PasteManager")

struct PasteboardItemContent {
    struct Representation {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    let representations: [Representation]
}

@MainActor
protocol PasteboardItemReading {
    var pasteboardTypes: [NSPasteboard.PasteboardType] { get }

    func pasteboardData(forType type: NSPasteboard.PasteboardType) -> Data?
}

@MainActor
protocol PasteboardManaging: AnyObject {
    var changeCount: Int { get }
    var pasteboardItems: [any PasteboardItemReading]? { get }

    @discardableResult
    func clearContents() -> Int

    func writeItems(_ items: [PasteboardItemContent]) -> Bool
}

@MainActor
protocol PasteCommandPosting {
    func postPasteCommand()
}

@MainActor
protocol TextPasting {
    func pasteText(_ text: String)
    func flushPendingRestore()
}

extension NSPasteboardItem: PasteboardItemReading {
    var pasteboardTypes: [NSPasteboard.PasteboardType] {
        types
    }

    func pasteboardData(forType type: NSPasteboard.PasteboardType) -> Data? {
        data(forType: type)
    }
}

@MainActor
final class SystemPasteboard: PasteboardManaging {
    private let pasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int {
        pasteboard.changeCount
    }

    var pasteboardItems: [any PasteboardItemReading]? {
        pasteboard.pasteboardItems
    }

    @discardableResult
    func clearContents() -> Int {
        pasteboard.clearContents()
    }

    func writeItems(_ items: [PasteboardItemContent]) -> Bool {
        let pasteboardItems = items.compactMap { item -> NSPasteboardItem? in
            let pasteboardItem = NSPasteboardItem()
            for representation in item.representations {
                guard pasteboardItem.setData(representation.data, forType: representation.type) else {
                    return nil
                }
            }
            return pasteboardItem
        }
        guard pasteboardItems.count == items.count else {
            return false
        }
        return pasteboard.writeObjects(pasteboardItems)
    }
}

struct SystemPasteCommandPoster: PasteCommandPosting {
    func postPasteCommand() {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        keyDown?.flags = .maskCommand

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }
}

@MainActor
final class PasteManager: TextPasting {
    private struct PasteboardSnapshot {
        let items: [PasteboardItemContent]
    }

    private struct PendingRestore {
        let id: UUID
        let snapshot: PasteboardSnapshot
        let expectedChangeCount: Int
    }

    private var pendingRestore: PendingRestore?
    private let pasteboard: any PasteboardManaging
    private let commandPoster: any PasteCommandPosting

    init(
        pasteboard: any PasteboardManaging = SystemPasteboard(),
        commandPoster: any PasteCommandPosting = SystemPasteCommandPoster()
    ) {
        self.pasteboard = pasteboard
        self.commandPoster = commandPoster
    }

    func pasteText(_ text: String) {
        guard flushPendingRestore(matching: nil) else {
            return
        }

        let originalChangeCount = pasteboard.changeCount

        guard let snapshot = snapshot(of: pasteboard) else {
            return
        }

        let transcriptItem = PasteboardItemContent(
            representations: [
                .init(type: .string, data: Data(text.utf8))
            ]
        )

        guard pasteboard.changeCount == originalChangeCount else {
            pasteLog.notice("Clipboard changed while it was being saved; cancelling paste")
            return
        }

        let transcriptOwnershipChangeCount = pasteboard.clearContents()
        guard pasteboard.writeItems([transcriptItem]) else {
            pasteLog.error("Failed to write transcript to the pasteboard")
            _ = restore(snapshot, to: pasteboard, ifUnchangedSince: transcriptOwnershipChangeCount)
            return
        }

        let transcriptChangeCount = pasteboard.changeCount
        let transactionID = UUID()
        pendingRestore = .init(
            id: transactionID,
            snapshot: snapshot,
            expectedChangeCount: transcriptChangeCount
        )
        commandPoster.postPasteCommand()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            _ = self.flushPendingRestore(matching: transactionID)
        }
    }

    func flushPendingRestore() {
        _ = flushPendingRestore(matching: nil)
    }

    private func flushPendingRestore(matching transactionID: UUID?) -> Bool {
        guard let pendingRestore else {
            return true
        }
        guard transactionID == nil || pendingRestore.id == transactionID else {
            return true
        }

        self.pendingRestore = nil
        return restore(
            pendingRestore.snapshot,
            to: pasteboard,
            ifUnchangedSince: pendingRestore.expectedChangeCount
        )
    }

    private func snapshot(of pasteboard: any PasteboardManaging) -> PasteboardSnapshot? {
        let pasteboardItems = pasteboard.pasteboardItems ?? []
        var snapshotItems: [PasteboardItemContent] = []

        for item in pasteboardItems {
            var representations: [PasteboardItemContent.Representation] = []

            for type in item.pasteboardTypes {
                // Some representations cannot be read: protected content (e.g. from
                // managed apps) or promised data that never materialises. Cancel the
                // paste rather than restore an incomplete version of the clipboard.
                guard let data = item.pasteboardData(forType: type) else {
                    pasteLog.notice(
                        "Clipboard representation \(type.rawValue, privacy: .public) could not be preserved; cancelling paste"
                    )
                    return nil
                }

                representations.append(.init(type: type, data: data))
            }

            guard !representations.isEmpty else {
                pasteLog.notice("Clipboard item has no restorable representations; cancelling paste")
                return nil
            }

            snapshotItems.append(PasteboardItemContent(representations: representations))
        }

        return PasteboardSnapshot(items: snapshotItems)
    }

    private func restore(
        _ snapshot: PasteboardSnapshot,
        to pasteboard: any PasteboardManaging,
        ifUnchangedSince expectedChangeCount: Int
    ) -> Bool {
        guard pasteboard.changeCount == expectedChangeCount else {
            return true
        }

        pasteboard.clearContents()

        guard snapshot.items.isEmpty || pasteboard.writeItems(snapshot.items) else {
            pasteLog.error("Failed to restore clipboard contents")
            return false
        }

        return true
    }
}
