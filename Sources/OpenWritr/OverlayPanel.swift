import Cocoa
import SwiftUI

enum OverlayState {
    case listening
    case transcribing
    case enhancing
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
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 84),
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

        // Position at top-center of main screen, respecting safe area (notch)
        if let screen = NSScreen.main {
            let safeFrame = screen.visibleFrame
            let x = safeFrame.midX - 160
            let y = safeFrame.maxY - 92
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.panel = panel
    }
}

private struct OverlayContentView: View {
    let state: OverlayState

    var body: some View {
        HStack(spacing: 14) {
            iconBadge
            headline
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(width: 300, height: 58)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(accentColor.opacity(0.18))
                }
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(accentColor.opacity(0.55), lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 10)
    }

    private var accentColor: Color {
        switch state {
        case .listening:
            return .red
        case .transcribing:
            return .orange
        case .enhancing:
            return .blue
        case .done:
            return .green
        }
    }

    private var title: String {
        switch state {
        case .listening:
            return "Listening"
        case .transcribing:
            return "Transcribing"
        case .enhancing:
            return "Enhancement"
        case .done:
            return "Ready"
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .listening:
            Image(systemName: "mic.fill")
                .symbolEffect(.pulse)
        case .transcribing:
            Image(systemName: "waveform")
                .symbolEffect(.pulse)
        case .enhancing:
            Image(systemName: "sparkles")
                .symbolEffect(.pulse)
        case .done:
            Image(systemName: "checkmark")
        }
    }

    private var iconBadge: some View {
        ZStack {
            Circle()
                .fill(accentColor.gradient)
            Circle()
                .strokeBorder(.white.opacity(0.22), lineWidth: 1)

            icon
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 38, height: 38)
    }

    private var headline: some View {
        Text(title)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.primary)
    }
}
