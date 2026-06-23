import AppKit

// MARK: - Theme (swappable color palettes; default = Claude Code terminal aesthetic)
//
// `Theme.coral` etc. stay the API everywhere; they read from the currently selected
// `Palette`. Switching themes (menu / prefs) just swaps `Theme.current` and triggers
// a redraw — every call site (pet, pills, rows, menu-bar icon) picks up the new colors.

struct Palette {
    let id: String
    let name: String
    let coral: NSColor    // primary accent
    let termBG: NSColor   // panel / body fill
    let termFG: NSColor   // text
    let green: NSColor    // positive / working
    let red: NSColor      // attention / error
}

extension Palette {
    static let claude = Palette(
        id: "claude", name: "Claude",
        coral:  NSColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1.0),   // #D97757
        termBG: NSColor(red: 0.106, green: 0.106, blue: 0.106, alpha: 0.94),  // #1B1B1B
        termFG: NSColor(red: 0.910, green: 0.902, blue: 0.886, alpha: 1.0),   // #E8E6E3
        green:  NSColor(red: 0.310, green: 0.690, blue: 0.435, alpha: 1.0),   // #4FB06D
        red:    NSColor(red: 0.851, green: 0.333, blue: 0.290, alpha: 1.0))   // #D9544A
    static let midnight = Palette(
        id: "midnight", name: "Midnight",
        coral:  NSColor(red: 0.553, green: 0.612, blue: 0.965, alpha: 1.0),   // periwinkle
        termBG: NSColor(red: 0.078, green: 0.086, blue: 0.137, alpha: 0.95),  // deep navy
        termFG: NSColor(red: 0.886, green: 0.910, blue: 0.969, alpha: 1.0),
        green:  NSColor(red: 0.376, green: 0.788, blue: 0.690, alpha: 1.0),   // teal
        red:    NSColor(red: 0.953, green: 0.451, blue: 0.529, alpha: 1.0))   // rose
    static let grove = Palette(
        id: "grove", name: "Grove",
        coral:  NSColor(red: 0.831, green: 0.690, blue: 0.216, alpha: 1.0),   // amber
        termBG: NSColor(red: 0.090, green: 0.114, blue: 0.094, alpha: 0.95),  // forest
        termFG: NSColor(red: 0.894, green: 0.910, blue: 0.882, alpha: 1.0),
        green:  NSColor(red: 0.420, green: 0.776, blue: 0.408, alpha: 1.0),
        red:    NSColor(red: 0.890, green: 0.486, blue: 0.337, alpha: 1.0))
    static let mono = Palette(
        id: "mono", name: "Mono",
        coral:  NSColor(white: 0.78, alpha: 1.0),
        termBG: NSColor(white: 0.10, alpha: 0.95),
        termFG: NSColor(white: 0.93, alpha: 1.0),
        green:  NSColor(white: 0.86, alpha: 1.0),
        red:    NSColor(white: 0.66, alpha: 1.0))
    static let all: [Palette] = [.claude, .midnight, .grove, .mono]
    static func byID(_ id: String) -> Palette { all.first { $0.id == id } ?? .claude }
}

enum Theme {
    static var current: Palette = .claude
    static var coral:  NSColor { current.coral }
    static var termBG: NSColor { current.termBG }
    static var termFG: NSColor { current.termFG }
    static var green:  NSColor { current.green }
    static var red:    NSColor { current.red }
}
