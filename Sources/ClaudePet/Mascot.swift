import AppKit

// MARK: - Sprite loading

func loadActiveSprite() -> NSImage? {
    for name in activeNames {
        let u = stateDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: u.path), let img = NSImage(contentsOf: u) { return img }
    }
    return nil
}

// MARK: - Original mascot ("terminal buddy"), fully code-drawn — no third-party art.
// Motion is keyed to attention: calm when working/idle, attention-grabbing when it
// needs you. `phase` is continuous seconds for smooth, paced motion.

func drawBuddy(in rect: NSRect, accent: NSColor, anim: String, phase: Double, bodyFill: NSColor? = nil, sleeping: Bool = false) {
    let body = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.32, yRadius: rect.height * 0.32)
    (bodyFill ?? Theme.termBG).setFill(); body.fill()
    accent.setStroke(); body.lineWidth = max(2, rect.width * 0.05); body.stroke()

    let eyeR = rect.width * 0.12, eyeDX = rect.width * 0.19
    let eyeY = rect.midY + rect.height * 0.06, cx = rect.midX
    let mode: String = {
        if sleeping { return "sleep" }
        switch anim {
        case "review", "jumping", "done", "ready": return "happy"
        case "waiting": return "wow"
        case "failed": return "dead"
        case "running", "running-right", "running-left": return "busy"
        default: return "idle"
        }
    }()
    let blink = (mode == "idle" || mode == "busy") && fmod(phase, 3.6) < 0.13

    func eye(_ ex: CGFloat) {
        let c = NSPoint(x: ex, y: eyeY)
        if mode == "sleep" {                                   // calm closed eyes (gentle down-arc)
            let p = NSBezierPath(); p.lineWidth = max(2, rect.width * 0.035); p.lineCapStyle = .round
            let r = eyeR
            p.move(to: NSPoint(x: c.x - r, y: c.y))
            p.curve(to: NSPoint(x: c.x + r, y: c.y),
                    controlPoint1: NSPoint(x: c.x - r * 0.3, y: c.y - r * 0.7),
                    controlPoint2: NSPoint(x: c.x + r * 0.3, y: c.y - r * 0.7))
            accent.setStroke(); p.stroke(); return
        }
        if mode == "dead" {
            let p = NSBezierPath(); p.lineWidth = max(2, rect.width * 0.035); p.lineCapStyle = .round
            let r = eyeR * 0.8
            p.move(to: NSPoint(x: c.x - r, y: c.y - r)); p.line(to: NSPoint(x: c.x + r, y: c.y + r))
            p.move(to: NSPoint(x: c.x - r, y: c.y + r)); p.line(to: NSPoint(x: c.x + r, y: c.y - r))
            Theme.red.setStroke(); p.stroke(); return
        }
        if blink || mode == "happy" {
            let p = NSBezierPath(); p.lineWidth = max(2, rect.width * 0.035); p.lineCapStyle = .round
            let r = eyeR
            p.move(to: NSPoint(x: c.x - r, y: c.y))
            p.curve(to: NSPoint(x: c.x + r, y: c.y),
                    controlPoint1: NSPoint(x: c.x - r * 0.3, y: c.y + r * 0.95),
                    controlPoint2: NSPoint(x: c.x + r * 0.3, y: c.y + r * 0.95))
            NSColor.white.setStroke(); p.stroke(); return
        }
        let er = (mode == "wow") ? eyeR * 1.18 : eyeR
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - er, y: c.y - er, width: er * 2, height: er * 2)).fill()
        let pr = er * 0.5
        var pdx: CGFloat = 0, pdy: CGFloat = 0
        if mode == "busy" { pdy = -er * 0.35 }                              // focused, looking down
        else if mode == "idle" { pdx = CGFloat(sin(phase * 2 * .pi * 0.15)) * er * 0.18 }
        NSColor(white: 0.1, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - pr + pdx, y: c.y - pr + pdy, width: pr * 2, height: pr * 2)).fill()
    }
    eye(cx - eyeDX); eye(cx + eyeDX)

    let my = rect.midY - rect.height * 0.20, mw = rect.width * 0.16
    let mouth = NSBezierPath(); mouth.lineWidth = max(2, rect.width * 0.04); mouth.lineCapStyle = .round
    switch mode {
    case "sleep":
        mouth.move(to: NSPoint(x: cx - mw * 0.4, y: my)); mouth.line(to: NSPoint(x: cx + mw * 0.4, y: my))
        accent.withAlphaComponent(0.7).setStroke(); mouth.stroke()
    case "happy":
        mouth.move(to: NSPoint(x: cx - mw, y: my + rect.height * 0.02))
        mouth.curve(to: NSPoint(x: cx + mw, y: my + rect.height * 0.02),
                    controlPoint1: NSPoint(x: cx - mw * 0.3, y: my - rect.height * 0.05),
                    controlPoint2: NSPoint(x: cx + mw * 0.3, y: my - rect.height * 0.05))
        accent.setStroke(); mouth.stroke()
    case "wow":
        let o = NSBezierPath(ovalIn: NSRect(x: cx - mw * 0.4, y: my - mw * 0.4, width: mw * 0.8, height: mw * 0.8))
        accent.setStroke(); o.lineWidth = max(2, rect.width * 0.035); o.stroke()
    case "dead":
        mouth.move(to: NSPoint(x: cx - mw, y: my)); mouth.line(to: NSPoint(x: cx + mw, y: my))
        Theme.red.setStroke(); mouth.stroke()
    case "busy":
        if sin(phase * 2 * .pi * 0.8) > -0.1 {                              // mellow blinking cursor — "typing"
            accent.setFill()
            NSBezierPath(rect: NSRect(x: cx - mw * 0.5, y: my - mw * 0.28, width: mw, height: mw * 0.55)).fill()
        }
    default:
        mouth.move(to: NSPoint(x: cx - mw * 0.7, y: my)); mouth.line(to: NSPoint(x: cx + mw * 0.7, y: my))
        accent.setStroke(); mouth.stroke()
    }
}

// A tiny version of the current pet for the menu bar, so the app stays usable when
// the overlay is hidden. Colored by state (not a dark template) so it pops on both
// light and dark menu bars and conveys session state at a glance. Falls back to a
// solid accent-filled mascot when no custom sprite is loaded.
func menuBarImage(state: String, sprite: NSImage?, cfg: Frames) -> NSImage {
    let side: CGFloat = 18
    let img = NSImage(size: NSSize(width: side, height: side))
    img.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: side, height: side)
    if let sheet = sprite {
        NSGraphicsContext.current?.imageInterpolation = .none
        let fw = CGFloat(cfg.frameWidth), fh = CGFloat(cfg.frameHeight)
        let anim = describe(state).anim
        let n = ((cfg.animations ?? codexAnimations())[anim] ?? [0]).first ?? 0
        let perRow = max(1, Int(sheet.size.width.rounded()) / cfg.frameWidth)
        let col = n % perRow, row = n / perRow
        let srcY = sheet.size.height - CGFloat(row + 1) * fh
        let s = min(side / fw, side / fh)
        let dw = fw * s, dh = fh * s
        let dest = NSRect(x: (side - dw) / 2, y: (side - dh) / 2, width: dw, height: dh)
        sheet.draw(in: dest, from: NSRect(x: CGFloat(col) * fw, y: srcY, width: fw, height: fh),
                   operation: .sourceOver, fraction: 1.0)
    } else {
        NSGraphicsContext.current?.imageInterpolation = .high
        let accent = accentFor(state)
        drawBuddy(in: rect.insetBy(dx: 1.5, dy: 1.5), accent: .white, anim: describe(state).anim,
                  phase: 0, bodyFill: accent)
    }
    img.unlockFocus()
    img.isTemplate = false        // keep state color; do NOT let the system monochrome it
    return img
}
