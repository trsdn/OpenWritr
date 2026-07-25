import Cocoa
import os.log

private let pasteLog = Logger(subsystem: "com.openwritr.app", category: "PasteManager")

@MainActor
final class PasteManager {
    private struct PasteboardSnapshot {
        struct Item {
            struct Representation {
                let type: NSPasteboard.PasteboardType
                let data: Data
            }

            let representations: [Representation]
        }

        let items: [Item]
    }

    private struct PendingRestore {
        let id: UUID
        let snapshot: PasteboardSnapshot
        let expectedChangeCount: Int
    }

    private var pendingRestore: PendingRestore?

    func pasteText(_ text: String) {
        guard flushPendingRestore(matching: nil) else {
            return
        }

        let pasteboard = NSPasteboard.general
        let originalChangeCount = pasteboard.changeCount

        guard let snapshot = snapshot(of: pasteboard) else {
            return
        }

        let transcriptItem = NSPasteboardItem()
        guard transcriptItem.setString(text, forType: .string) else {
            pasteLog.error("Failed to prepare transcript for the pasteboard")
            return
        }

        guard pasteboard.changeCount == originalChangeCount else {
            pasteLog.notice("Clipboard changed while it was being saved; cancelling paste")
            return
        }

        let transcriptOwnershipChangeCount = pasteboard.clearContents()
        guard pasteboard.writeObjects([transcriptItem]) else {
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
        simulatePaste()

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
            to: NSPasteboard.general,
            ifUnchangedSince: pendingRestore.expectedChangeCount
        )
    }

    private func snapshot(of pasteboard: NSPasteboard) -> PasteboardSnapshot? {
        var snapshotItems: [PasteboardSnapshot.Item] = []

        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [PasteboardSnapshot.Item.Representation] = []

            for type in item.types {
                guard let data = item.data(forType: type) else {
                    pasteLog.error("Failed to read clipboard representation \(type.rawValue, privacy: .public)")
                    return nil
                }

                representations.append(.init(type: type, data: data))
            }

            snapshotItems.append(.init(representations: representations))
        }

        return PasteboardSnapshot(items: snapshotItems)
    }

    private func restore(
        _ snapshot: PasteboardSnapshot,
        to pasteboard: NSPasteboard,
        ifUnchangedSince expectedChangeCount: Int
    ) -> Bool {
        var restoredItems: [NSPasteboardItem] = []

        for snapshotItem in snapshot.items {
            let restoredItem = NSPasteboardItem()

            for representation in snapshotItem.representations {
                guard restoredItem.setData(representation.data, forType: representation.type) else {
                    pasteLog.error(
                        "Failed to prepare clipboard representation \(representation.type.rawValue, privacy: .public)"
                    )
                    return false
                }
            }

            restoredItems.append(restoredItem)
        }

        guard pasteboard.changeCount == expectedChangeCount else {
            return true
        }

        pasteboard.clearContents()

        guard restoredItems.isEmpty || pasteboard.writeObjects(restoredItems) else {
            pasteLog.error("Failed to restore clipboard contents")
            return false
        }

        return true
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // 0x09 = 'v'
        keyDown?.flags = .maskCommand

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
