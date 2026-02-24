enum HotkeyChoice: String, CaseIterable, Identifiable, Sendable {
    case fn = "fn"
    case rightOption = "rightOption"
    case rightCommand = "rightCommand"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fn: return "🌐 Fn (Globe)"
        case .rightOption: return "⌥ Right Option"
        case .rightCommand: return "⌘ Right Command"
        }
    }

    var shortLabel: String {
        switch self {
        case .fn: return "🌐"
        case .rightOption: return "⌥"
        case .rightCommand: return "⌘"
        }
    }

    var flag: UInt64 {
        switch self {
        case .fn: return 0x800000
        case .rightOption: return 0x40
        case .rightCommand: return 0x10
        }
    }
}
