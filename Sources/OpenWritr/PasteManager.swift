import Cocoa

@MainActor
final class PasteManager {
    private struct PasteboardSnapshot {
        struct Item {
            let representations: [(type: NSPasteboard.PasteboardType, data: Data)]
        }

        let items: [Item]
    }

    func pasteText(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previousSnapshot = snapshot(of: pasteboard)

        // Set our text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let temporaryChangeCount = pasteboard.changeCount

        // Simulate Cmd+V
        simulatePaste()

        // Restore previous clipboard after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard pasteboard.changeCount == temporaryChangeCount else {
                return
            }

            self.restore(previousSnapshot, to: pasteboard)
        }
    }

    private func snapshot(of pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items: [PasteboardSnapshot.Item] = pasteboard.pasteboardItems?.map { item in
            let representations = item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
            return PasteboardSnapshot.Item(representations: representations)
        } ?? []

        return PasteboardSnapshot(items: items)
    }

    private func restore(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()

        guard !snapshot.items.isEmpty else {
            return
        }

        let restoredItems = snapshot.items.compactMap { snapshotItem -> NSPasteboardItem? in
            let item = NSPasteboardItem()
            var wroteRepresentation = false

            for representation in snapshotItem.representations {
                wroteRepresentation = item.setData(representation.data, forType: representation.type) || wroteRepresentation
            }

            return wroteRepresentation ? item : nil
        }

        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
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
