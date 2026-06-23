import AppKit

// MARK: - State model

struct StateDesc { let anim: String; let label: String?; let dot: NSColor?; let oneShot: String? }

func describe(_ s: String) -> StateDesc {
    switch s {
    case "waving":                          return StateDesc(anim: "waving",  label: "hello",     dot: Theme.coral, oneShot: "idle")
    case "running-right", "running-left", "running":
                                            return StateDesc(anim: s,         label: "working",   dot: Theme.green, oneShot: nil)
    case "waiting":                         return StateDesc(anim: "waiting", label: "needs you", dot: Theme.red,   oneShot: nil)
    case "jumping", "done":                 return StateDesc(anim: "jumping", label: "done!",     dot: Theme.green, oneShot: "review")
    case "review", "ready":                 return StateDesc(anim: "review",  label: "ready",     dot: Theme.green, oneShot: nil)
    case "failed", "error":                 return StateDesc(anim: "failed",  label: "error",     dot: Theme.red,   oneShot: nil)
    case "idle", "off":                     return StateDesc(anim: "idle",    label: nil,         dot: nil,         oneShot: nil)
    default:                                return StateDesc(anim: "idle",    label: nil,         dot: nil,         oneShot: nil)
    }
}

func accentFor(_ state: String) -> NSColor {
    switch state {
    case "running", "running-right", "running-left", "jumping", "review", "done", "ready": return Theme.green
    case "waiting", "failed", "error": return Theme.red
    default: return Theme.coral
    }
}
func shortStatus(_ state: String) -> String {
    switch state {
    case "waiting": return "needs you"
    case "failed", "error": return "error"
    case "jumping", "done", "review", "ready": return "ready"
    case "running", "running-right", "running-left": return "working"
    case "waving": return "hi"
    default: return "idle"
    }
}
func truncated(_ text: String, font: NSFont, maxW: CGFloat) -> String {
    let a: [NSAttributedString.Key: Any] = [.font: font]
    if (text as NSString).size(withAttributes: a).width <= maxW { return text }
    var s = text
    while s.count > 1, ((s + "…") as NSString).size(withAttributes: a).width > maxW { s = String(s.dropLast()) }
    return s + "…"
}
