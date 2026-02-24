import Cocoa
import SwiftUI

enum OverlayState {
    case listening
    case transcribing
    case done
}

@MainActor
final class OverlayPanel {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<OverlayContentView>?
    func show(state: OverlayState) {
        if panel == nil {
            createPanel()
        }

        hostingView?.rootView = OverlayContentView(state: state)
        panel?.orderFrontRegardless()
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 56),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = OverlayContentView(state: .listening)
        let hostingView = NSHostingView(rootView: content)
        panel.contentView = hostingView
        self.hostingView = hostingView

        // Position at top-center of main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 120
            let y = screenFrame.maxY - 80
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.panel = panel
    }
}

private struct OverlayContentView: View {
    let state: OverlayState

    var body: some View {
        HStack(spacing: 8) {
            icon
            text
        }
        .font(.system(size: 15, weight: .medium))
        .frame(width: 200, height: 44)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .listening:
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
                .symbolEffect(.pulse)
        case .transcribing:
            ProgressView()
                .controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var text: some View {
        switch state {
        case .listening:
            Text("Listening...")
                .font(.system(size: 13, weight: .medium))
        case .transcribing:
            Text("Transcribing...")
                .font(.system(size: 13, weight: .medium))
        case .done:
            Text("Done")
                .font(.system(size: 13, weight: .medium))
        }
    }
}
