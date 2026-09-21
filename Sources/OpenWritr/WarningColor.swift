import AppKit
import SwiftUI

extension Color {
    /// Colour for attention text. System orange is about 2.2:1 on a light
    /// window, too low for small text, so light mode uses a darker orange
    /// (about 6:1 on white). Dark mode keeps system orange (about 8:1).
    static let warningText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .systemOrange
            : NSColor(srgbRed: 0.62, green: 0.29, blue: 0, alpha: 1)
    })
}
