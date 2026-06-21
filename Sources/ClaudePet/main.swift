import AppKit
import Foundation
import Darwin
import UniformTypeIdentifiers

// MARK: - Paths

let home = FileManager.default.homeDirectoryForCurrentUser
let stateDir = home.appendingPathComponent(".claude-pet")
let pidURL = stateDir.appendingPathComponent("pet.pid")
let petsDir = stateDir.appendingPathComponent("pets")
let framesURL = stateDir.appendingPathComponent("frames.json")
let settingsURL = home.appendingPathComponent(".claude/settings.json")
// One state file per Claude Code session -> one session in the stack.
let sessionsDir = stateDir.appendingPathComponent("sessions")
let layoutURL = stateDir.appendingPathComponent("layout.json")   // persisted manual order + selection
func sessionFile(_ id: String) -> URL { sessionsDir.appendingPathComponent(id + ".json") }
let SESSION_STALE_SECONDS: TimeInterval = 12 * 3600
// Active sprite sheet — Codex pets ship a WebP, so .webp is preferred.
let activeNames = ["active.webp", "active.png"]

// MARK: - Theme (Claude Code terminal aesthetic)

enum Theme {
    static let coral  = NSColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1.0)  // #D97757
    static let termBG = NSColor(red: 0.106, green: 0.106, blue: 0.106, alpha: 0.94) // #1B1B1B
    static let termFG = NSColor(red: 0.910, green: 0.902, blue: 0.886, alpha: 1.0)  // #E8E6E3
    static let green  = NSColor(red: 0.310, green: 0.690, blue: 0.435, alpha: 1.0)  // #4FB06D
    static let red    = NSColor(red: 0.851, green: 0.333, blue: 0.290, alpha: 1.0)  // #D9544A
}

// MARK: - Codex atlas contract (8x9, 192x208 cells, WebP) — codex-pets.net compatible

let CODEX_COLUMNS = 8
let CODEX_ROW_SPECS: [(state: String, row: Int, frames: Int)] = [
    ("idle", 0, 6), ("running-right", 1, 8), ("running-left", 2, 8),
    ("waving", 3, 4), ("jumping", 4, 5), ("failed", 5, 8),
    ("waiting", 6, 6), ("running", 7, 6), ("review", 8, 6),
]
func codexAnimations() -> [String: [Int]] {
    var out: [String: [Int]] = [:]
    for spec in CODEX_ROW_SPECS { out[spec.state] = (0..<spec.frames).map { spec.row * CODEX_COLUMNS + $0 } }
    return out
}

// MARK: - Config

struct Frames: Codable {
    var frameWidth = 192
    var frameHeight = 208
    var scale: Double = 0.42
    var fps: Double = 8
    var animations: [String: [Int]]? = nil
}
func loadFrames() -> Frames {
    if let data = try? Data(contentsOf: framesURL),
       let f = try? JSONDecoder().decode(Frames.self, from: data) { return f }
    return Frames()
}

struct PetState: Codable { var state = "idle"; var cwd: String?; var transcript: String?; var detail: String?; var cleared: Bool? }

// Read the session's title from its transcript (JSONL). Two kinds of records
// carry a title: "ai-title" (auto-generated, field "aiTitle") and "custom-title"
// (the user's manual rename, field "customTitle"). For each kind the latest near
// the end wins; a manual rename always takes precedence over the AI title, since
// Claude Code stops auto-titling once the user renames a session. Only the file
// tail is scanned so this stays cheap even for large transcripts.
//
// `ignoreCustom` drops manual-rename records. On `/clear` Claude Code keeps the
// same session_id and re-asserts the pre-clear custom title into the new
// transcript (repeatedly, with no timestamp to distinguish carried-over from
// fresh), so a cleared session would otherwise keep showing its old name. For
// those we ignore custom titles entirely and fall back to a fresh ai-title or
// the project folder, which is what "the name resets on clear" means in practice.
func readAITitle(_ path: String, ignoreCustom: Bool = false) -> String? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
    let chunk = 65536
    if size > chunk { try? fh.seek(toOffset: UInt64(size - chunk)) }
    guard let data = try? fh.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
    var aiTitle: String?, customTitle: String?
    for line in text.split(separator: "\n")
        where line.contains("\"type\":\"ai-title\"") || line.contains("\"type\":\"custom-title\"") {
        if let d = line.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if let t = o["customTitle"] as? String, !t.isEmpty { customTitle = t }
            else if let t = o["aiTitle"] as? String, !t.isEmpty { aiTitle = t }
        }
    }
    if ignoreCustom { return aiTitle }
    return customTitle ?? aiTitle
}

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

func drawBuddy(in rect: NSRect, accent: NSColor, anim: String, phase: Double, bodyFill: NSColor? = nil) {
    let body = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.32, yRadius: rect.height * 0.32)
    (bodyFill ?? Theme.termBG).setFill(); body.fill()
    accent.setStroke(); body.lineWidth = max(2, rect.width * 0.05); body.stroke()

    let eyeR = rect.width * 0.12, eyeDX = rect.width * 0.19
    let eyeY = rect.midY + rect.height * 0.06, cx = rect.midX
    let mode: String = {
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

// MARK: - PetView (the prominent / primary pet)

final class PetView: NSView {
    var sprite: NSImage?
    var cfg = Frames()
    var anim = "idle"
    var frameIndex = 0
    var bubbleLabel: String?
    var bubbleDot: NSColor?
    var oneShotFallback: String?
    var caption: String?

    private var ticks = 0
    private var spriteAccum = 0.0
    private var oneShotElapsed = 0.0
    private var phase: Double { Double(ticks) / 30.0 }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // container handles mouse
    private func anims() -> [String: [Int]] { cfg.animations ?? codexAnimations() }

    private func currentFrameNumber() -> Int {
        let list = anims()[anim] ?? [0]
        guard !list.isEmpty else { return 0 }
        return list[frameIndex % list.count]
    }

    func setState(_ s: String) {
        let d = describe(s)
        if anim != d.anim { frameIndex = 0; spriteAccum = 0; oneShotElapsed = 0 }
        anim = d.anim; bubbleLabel = d.label; bubbleDot = d.dot; oneShotFallback = d.oneShot
        needsDisplay = true
    }

    // Calm states animate slowly; attention states a touch livelier.
    private func stateFPS() -> Double {
        switch anim {
        case "idle": return 3
        case "running", "running-right", "running-left", "review": return 4
        case "waiting": return 7
        case "failed": return 9
        case "waving": return 10
        case "jumping": return 12
        default: return 6
        }
    }

    func advance() {
        ticks += 1
        if sprite != nil {
            spriteAccum += stateFPS() / 30.0
            while spriteAccum >= 1 {
                spriteAccum -= 1
                let list = anims()[anim] ?? [0]
                if list.count > 1 {
                    frameIndex += 1
                    if frameIndex >= list.count {
                        if let fb = oneShotFallback { setState(fb) } else { frameIndex = 0 }
                    }
                }
            }
        } else if oneShotFallback != nil {
            oneShotElapsed += 1.0 / 30.0
            if oneShotElapsed > 0.7, let fb = oneShotFallback { setState(fb) }
        }
        needsDisplay = true
    }

    // Attention-keyed motion: working/idle barely move; waiting bobs + red halo; failed shakes.
    private func motion() -> (dx: CGFloat, dy: CGFloat, ring: CGFloat) {
        let p = phase
        switch anim {
        case "waiting":
            let s = (sin(p * 2 * .pi * 1.1) + 1) / 2
            return (0, CGFloat(s) * 7, CGFloat(s))
        case "failed":
            return (CGFloat(sin(p * 2 * .pi * 6)) * 2.5, 0, 0)
        case "review", "jumping", "done", "ready":
            return (0, CGFloat((sin(p * 2 * .pi * 0.8) + 1) / 2) * 3, 0)
        case "idle":
            return (0, CGFloat(sin(p * 2 * .pi * 0.25)) * 1.2, 0)
        default:
            return (0, 0, 0)                                   // working: still & busy
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set(); dirtyRect.fill()
        NSGraphicsContext.current?.imageInterpolation = .none

        let fw = CGFloat(cfg.frameWidth), fh = CGFloat(cfg.frameHeight)
        let scale = CGFloat(cfg.scale)
        let drawW = fw * scale, drawH = fh * scale
        let baseX = (bounds.width - drawW) / 2, baseY: CGFloat = 12
        // Code-drawn motion (bob/shake) and the attention halo are part of the
        // built-in mascot's "attention budget" look. A custom sprite ships its own
        // per-state animation, so we render it flat — no bob, no shake, no halo —
        // and let the sprite's own frames carry the context and look its author intended.
        let m = sprite == nil ? motion() : (dx: CGFloat(0), dy: CGFloat(0), ring: CGFloat(0))
        let dest = NSRect(x: baseX + m.dx, y: baseY + m.dy, width: drawW, height: drawH)

        if m.ring > 0 {                                        // pulsing attention halo
            let grow = 3 + m.ring * 6
            let rr = dest.insetBy(dx: -grow, dy: -grow)
            let ring = NSBezierPath(roundedRect: rr, xRadius: rr.width * 0.3, yRadius: rr.height * 0.3)
            Theme.red.withAlphaComponent(0.12 + 0.4 * m.ring).setStroke()
            ring.lineWidth = 2 + 2 * m.ring; ring.stroke()
        }

        if let img = sprite {
            let perRow = max(1, Int(img.size.width.rounded()) / cfg.frameWidth)
            let n = currentFrameNumber()
            let col = n % perRow, row = n / perRow
            let srcY = img.size.height - CGFloat(row + 1) * fh
            img.draw(in: dest, from: NSRect(x: CGFloat(col) * fw, y: srcY, width: fw, height: fh),
                     operation: .sourceOver, fraction: 1.0)
        } else {
            drawBuddy(in: dest, accent: accentFor(anim), anim: anim, phase: phase)
        }

        // Text uses the BASE rect (no bob) so it stays stable: pet -> pill -> caption.
        let textRect = NSRect(x: baseX, y: baseY, width: drawW, height: drawH)
        var topY = textRect.maxY
        if let label = bubbleLabel { topY = drawBubble(label, dot: bubbleDot, above: textRect) }
        if let cap = caption { drawCaption(cap, atY: topY + 5) }
    }

    // Dim project/session label above the pill. Long AI titles wrap to two lines.
    private func drawCaption(_ text: String, atY y: CGFloat) {
        let font: NSFont = NSFont(name: "Menlo", size: 9) ?? NSFont.systemFont(ofSize: 9)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.termFG.withAlphaComponent(0.7)]
        let maxW = bounds.width - 6
        let lines = wrapCaption(text, maxW: maxW, attrs: attrs)
        let lineH = (font.ascender - font.descender) + 1
        for (i, line) in lines.enumerated() {
            let s = line as NSString
            let sz = s.size(withAttributes: attrs)
            let x = min(max(2, (bounds.width - sz.width) / 2), bounds.width - sz.width - 2)
            let ly = y + CGFloat(lines.count - 1 - i) * lineH
            s.draw(at: NSPoint(x: x, y: min(ly, bounds.height - sz.height - 2)), withAttributes: attrs)
        }
    }

    private func wrapCaption(_ text: String, maxW: CGFloat, attrs: [NSAttributedString.Key: Any]) -> [String] {
        func fits(_ s: String) -> Bool { (s as NSString).size(withAttributes: attrs).width <= maxW }
        func ellipsize(_ s: String) -> String {
            if fits(s) { return s }
            var d = s
            while d.count > 1, !fits(d + "…") { d = String(d.dropLast()) }
            return d + "…"
        }
        if fits(text) { return [text] }
        let words = text.split(separator: " ").map(String.init)
        var first = "", rest = ""
        for w in words {
            let candidate = first.isEmpty ? w : first + " " + w
            if rest.isEmpty && fits(candidate) { first = candidate }
            else { rest = rest.isEmpty ? w : rest + " " + w }
        }
        if first.isEmpty { return [ellipsize(text)] }
        return rest.isEmpty ? [first] : [first, ellipsize(rest)]
    }

    @discardableResult
    private func drawBubble(_ label: String, dot: NSColor?, above rect: NSRect) -> CGFloat {
        let font: NSFont = NSFont(name: "Menlo", size: 11) ?? NSFont.boldSystemFont(ofSize: 11)
        let text = label as NSString
        let tAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.termFG]
        let tSize = text.size(withAttributes: tAttrs)
        let dotR: CGFloat = 4, padX: CGFloat = 8, padY: CGFloat = 4, gap: CGFloat = 6
        let bw = padX * 2 + (dot != nil ? dotR * 2 + gap : 0) + tSize.width
        let bh = padY * 2 + max(tSize.height, dotR * 2)
        let bx = min(max(4, rect.midX - bw / 2), bounds.width - bw - 4)
        let br = NSRect(x: bx, y: rect.maxY + 6, width: bw, height: bh)
        let pill = NSBezierPath(roundedRect: br, xRadius: 6, yRadius: 6)
        Theme.termBG.setFill(); pill.fill()
        Theme.coral.withAlphaComponent(0.85).setStroke(); pill.lineWidth = 1; pill.stroke()
        var cursor = br.minX + padX
        if let d = dot {
            d.setFill(); NSBezierPath(ovalIn: NSRect(x: cursor, y: br.midY - dotR, width: dotR * 2, height: dotR * 2)).fill()
            cursor += dotR * 2 + gap
        }
        text.draw(at: NSPoint(x: cursor, y: br.midY - tSize.height / 2), withAttributes: tAttrs)
        return br.maxY
    }
}

// MARK: - StackView
// The selected session's pet shows large in the corner. All sessions appear in a
// fixed-order list above it (selected one highlighted). Order is STABLE — it only
// changes when the user drags a row. Click a row to select; scroll to step
// through; drag the pet (or empty area) to move the whole widget.

struct SessionItem { let id: String; let state: String; let label: String }

final class StackView: NSView {
    let primary = PetView(frame: .zero)
    var items: [SessionItem] = []          // ALL sessions, in stable display order
    var selectedID: String?
    var onSelect: ((String) -> Void)?
    var onReorder: (([String]) -> Void)?
    var onCycle: ((Int) -> Void)?

    let W: CGFloat = 232, PETH: CGFloat = 158
    let rowH: CGFloat = 26, innerPad: CGFloat = 7, margin: CGFloat = 8, gap: CGFloat = 6
    private var downInWin = NSPoint.zero    // mouse-down point in view coords
    private var lastScreen = NSPoint.zero   // for window dragging (screen coords)
    private var moved: CGFloat = 0
    private var dragIndex: Int? = nil       // row being dragged (reorder)
    private var dragging = false            // a reorder drag is in progress
    private var dragCursorY: CGFloat = 0    // cursor Y so the lifted row follows
    private var windowDrag = false
    private var hoveredRow = -1
    private var scrollAccum: CGFloat = 0

    var showList: Bool { items.count > 1 }

    override init(frame f: NSRect) { super.init(frame: f); addSubview(primary) }
    required init?(coder: NSCoder) { fatalError() }

    func listPanelH() -> CGFloat { showList ? CGFloat(items.count) * rowH + innerPad * 2 : 0 }
    func desiredHeight() -> CGFloat { showList ? margin * 2 + PETH + gap + listPanelH() : margin * 2 + PETH }
    func panelRect() -> NSRect { NSRect(x: margin, y: margin + PETH + gap, width: W - margin * 2, height: listPanelH()) }
    func layoutContents() {
        primary.frame = NSRect(x: 0, y: margin, width: W, height: PETH)   // pet anchored in the corner
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    private func rowIndex(at p: NSPoint, clamp: Bool = false) -> Int? {
        guard showList else { return nil }
        let panel = panelRect()
        if !clamp && !panel.contains(p) { return nil }
        var i = Int((panel.maxY - innerPad - p.y) / rowH)
        if clamp { i = max(0, min(items.count - 1, i)) }
        return (i >= 0 && i < items.count) ? i : nil
    }

    private func drawRow(_ it: SessionItem, in row: NSRect, selected: Bool, hovered: Bool, lifted: Bool, font: NSFont) {
        let inner = row.insetBy(dx: 3, dy: 1)
        if lifted {                                            // the row being dragged: pops out
            Theme.termBG.setFill()
            let p = NSBezierPath(roundedRect: inner, xRadius: 6, yRadius: 6); p.fill()
            Theme.coral.setStroke(); p.lineWidth = 1.5; p.stroke()
        } else if selected {
            Theme.coral.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: inner, xRadius: 6, yRadius: 6).fill()
            Theme.coral.setFill()
            NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: 3, height: inner.height), xRadius: 1.5, yRadius: 1.5).fill()
        } else if hovered {
            Theme.coral.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: inner, xRadius: 6, yRadius: 6).fill()
        }
        // grip dots — signals the row is draggable (brighter on hover/lift)
        NSColor.white.withAlphaComponent(hovered || lifted ? 0.55 : 0.28).setFill()
        for r in 0..<2 { for dy in [-3.5, 0.0, 3.5] {
            NSBezierPath(ovalIn: NSRect(x: row.minX + 8 + CGFloat(r) * 3.2, y: row.midY + CGFloat(dy) - 0.85, width: 1.7, height: 1.7)).fill()
        } }
        let dotR: CGFloat = 4
        accentFor(it.state).setFill()
        NSBezierPath(ovalIn: NSRect(x: row.minX + 20, y: row.midY - dotR, width: dotR * 2, height: dotR * 2)).fill()
        let stStr = shortStatus(it.state) as NSString
        let stAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: accentFor(it.state)]
        let stSize = stStr.size(withAttributes: stAttrs)
        let stX = row.maxX - 12 - stSize.width
        stStr.draw(at: NSPoint(x: stX, y: row.midY - stSize.height / 2), withAttributes: stAttrs)
        let nameX = row.minX + 32
        let nmCol = selected ? Theme.termFG : Theme.termFG.withAlphaComponent(0.85)
        let nmAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: nmCol]
        let nm = truncated(it.label, font: font, maxW: stX - nameX - 8) as NSString
        nm.draw(at: NSPoint(x: nameX, y: row.midY - nm.size(withAttributes: nmAttrs).height / 2), withAttributes: nmAttrs)
    }

    override func draw(_ r: NSRect) {
        NSColor.clear.set(); r.fill()
        guard showList else { return }
        let panel = panelRect()
        let bg = NSBezierPath(roundedRect: panel, xRadius: 10, yRadius: 10)
        Theme.termBG.setFill(); bg.fill()
        Theme.coral.withAlphaComponent(0.7).setStroke(); bg.lineWidth = 1; bg.stroke()

        let font = NSFont(name: "Menlo", size: 10) ?? .systemFont(ofSize: 10)
        for (i, it) in items.enumerated() {
            if dragging && i == dragIndex { continue }          // leave a gap; drawn floating below
            let rowY = panel.maxY - innerPad - CGFloat(i + 1) * rowH
            let row = NSRect(x: panel.minX, y: rowY, width: panel.width, height: rowH)
            drawRow(it, in: row, selected: it.id == selectedID, hovered: !dragging && i == hoveredRow, lifted: false, font: font)
        }
        if dragging, let di = dragIndex {                       // the lifted row follows the cursor
            let cy = min(max(dragCursorY, panel.minY + rowH / 2), panel.maxY - rowH / 2)
            let row = NSRect(x: panel.minX, y: cy - rowH / 2, width: panel.width, height: rowH)
            drawRow(items[di], in: row, selected: items[di].id == selectedID, hovered: false, lifted: true, font: font)
        }
    }

    override func mouseMoved(with e: NSEvent) {
        let i = rowIndex(at: convert(e.locationInWindow, from: nil)) ?? -1
        if i != hoveredRow { hoveredRow = i; needsDisplay = true }
    }
    override func mouseExited(with e: NSEvent) { if hoveredRow != -1 { hoveredRow = -1; needsDisplay = true } }

    override func mouseDown(with e: NSEvent) {
        downInWin = convert(e.locationInWindow, from: nil)
        lastScreen = NSEvent.mouseLocation; moved = 0
        if let i = rowIndex(at: downInWin) { dragIndex = i; windowDrag = false }
        else { dragIndex = nil; windowDrag = true }            // pet/empty -> move the widget
    }
    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        moved = max(moved, hypot(p.x - downInWin.x, p.y - downInWin.y))
        if windowDrag {
            let now = NSEvent.mouseLocation
            if let win = window { var o = win.frame.origin; o.x += now.x - lastScreen.x; o.y += now.y - lastScreen.y; win.setFrameOrigin(o) }
            lastScreen = now
        } else if let di = dragIndex, moved > 3 {               // reorder this row live
            dragging = true; dragCursorY = p.y
            if let t = rowIndex(at: p, clamp: true), t != di {
                let it = items.remove(at: di); items.insert(it, at: t); dragIndex = t
            }
            needsDisplay = true
        }
    }
    override func mouseUp(with e: NSEvent) {
        if let di = dragIndex {
            if moved > 3 { onReorder?(items.map { $0.id }) }    // committed a manual reorder
            else { onSelect?(items[di].id) }                   // a click -> select
        }
        dragIndex = nil; windowDrag = false; dragging = false; needsDisplay = true
    }

    // Scroll over the widget to step the selection through sessions.
    override func scrollWheel(with e: NSEvent) {
        guard showList else { return }
        scrollAccum += e.scrollingDeltaY
        if scrollAccum > 6 { onCycle?(-1); scrollAccum = 0 }
        else if scrollAccum < -6 { onCycle?(1); scrollAccum = 0 }
    }
}

// MARK: - App (single stacked overlay)

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var stack: StackView!
    var statusItem: NSStatusItem!
    var hidden = false
    var order: [String] = []               // stable display order of session ids
    var selectedID: String?
    var appliedKey = ""
    var menuIconKey = ""
    var titleCache: [String: (mtime: Date?, title: String?)] = [:]

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarIcon("idle")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show / Hide", action: #selector(toggleVisibility), keyEquivalent: "p"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Load Pet… (Codex .webp or folder)", action: #selector(loadSprite), keyEquivalent: "l"))
        menu.addItem(NSMenuItem(title: "Reset to Default Pet", action: #selector(resetSprite), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Claude Pet", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    // Reflect the selected session's state in the menu bar (state in the key so a
    // sprite swap or state change re-renders, but steady state is a no-op).
    func updateMenuBarIcon(_ state: String) {
        let sprite = stack?.primary.sprite
        let key = state + "|" + (sprite != nil ? "sprite" : "buddy")
        guard key != menuIconKey else { return }
        menuIconKey = key
        statusItem.button?.image = menuBarImage(state: state, sprite: sprite, cfg: stack?.primary.cfg ?? Frames())
    }

    @objc func toggleVisibility() {
        hidden.toggle()
        if hidden { window.orderOut(nil) } else { window.orderFrontRegardless() }
    }
    @objc func loadSprite() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, UTType("org.webmproject.webp") ?? .image, .folder]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.message = "Choose a Codex pet: a spritesheet.webp, a .png sheet, or a pet folder."
        if panel.runModal() == .OK, let url = panel.url { importPet(url) }
    }
    func importPet(_ url: URL) {
        var sheet = url
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            guard let found = ["spritesheet.webp", "spritesheet.png"].map({ url.appendingPathComponent($0) })
                    .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
            sheet = found
        }
        let ext = sheet.pathExtension.lowercased() == "png" ? "png" : "webp"
        for name in activeNames { try? FileManager.default.removeItem(at: stateDir.appendingPathComponent(name)) }
        try? FileManager.default.copyItem(at: sheet, to: stateDir.appendingPathComponent("active.\(ext)"))
        reloadSprite()
    }
    @objc func resetSprite() {
        for name in activeNames { try? FileManager.default.removeItem(at: stateDir.appendingPathComponent(name)) }
        reloadSprite()
    }
    func reloadSprite() {
        stack.primary.cfg = loadFrames(); stack.primary.sprite = loadActiveSprite(); stack.primary.needsDisplay = true
        menuIconKey = ""; updateMenuBarIcon(stack.primary.anim)   // re-render the menu bar from the new sprite
    }
    @objc func quit() { NSApp.terminate(nil) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: petsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try? "\(getpid())".write(to: pidURL, atomically: true, encoding: .utf8)
        setupMenu()

        stack = StackView(frame: NSRect(x: 0, y: 0, width: 232, height: 200))
        stack.primary.cfg = loadFrames(); stack.primary.sprite = loadActiveSprite()
        stack.onSelect = { [weak self] id in self?.selectedID = id; self?.sync() }
        stack.onReorder = { [weak self] ids in self?.order = ids; self?.sync() }
        stack.onCycle = { [weak self] d in self?.cycleSelection(d) }

        window = NSWindow(contentRect: stack.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.contentView = stack
        if let vf = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: vf.maxX - stack.W - 16, y: vf.minY + 28))
        }
        stack.layoutContents()
        loadLayout()
        sync()

        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.stack.primary.advance()
        }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.sync() }
    }

    private var lastSavedLayout = ""
    private func loadLayout() {
        if let d = try? Data(contentsOf: layoutURL),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            order = (o["order"] as? [String]) ?? []
            selectedID = o["selected"] as? String
        }
    }
    private func saveLayoutIfChanged() {
        let key = order.joined(separator: ",") + "|" + (selectedID ?? "")
        guard key != lastSavedLayout else { return }
        lastSavedLayout = key
        var obj: [String: Any] = ["order": order]
        if let s = selectedID { obj["selected"] = s }
        if let d = try? JSONSerialization.data(withJSONObject: obj) { try? d.write(to: layoutURL) }
    }

    private func cycleSelection(_ d: Int) {
        guard !order.isEmpty else { return }
        let cur = selectedID ?? order[0]
        let i = order.firstIndex(of: cur) ?? 0
        selectedID = order[((i + d) % order.count + order.count) % order.count]
        sync()
    }

    private func sessionTitle(_ id: String, _ st: PetState) -> String? {
        guard let tp = st.transcript else { return nil }
        let m = (try? FileManager.default.attributesOfItem(atPath: tp))?[.modificationDate] as? Date
        if titleCache[id]?.mtime != m { titleCache[id] = (m, readAITitle(tp, ignoreCustom: st.cleared == true)) }
        return titleCache[id]?.title
    }
    private func folderName(_ st: PetState) -> String? { st.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } }
    private func label(_ id: String, _ st: PetState) -> String? { sessionTitle(id, st) ?? folderName(st) }

    private func sync() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []

        var live: [String: (st: PetState, mtime: Date)] = [:]
        for f in files {
            let id = f.deletingPathExtension().lastPathComponent
            let m = (try? fm.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
            if -m.timeIntervalSinceNow > SESSION_STALE_SECONDS { try? fm.removeItem(at: f); continue }
            if let data = try? Data(contentsOf: f), let st = try? JSONDecoder().decode(PetState.self, from: data) {
                live[id] = (st, m)
            }
        }
        for id in titleCache.keys where live[id] == nil { titleCache[id] = nil }

        // Maintain a STABLE order: keep existing positions, append new sessions
        // (oldest-first), drop ended ones. Never reorder on state change.
        order.removeAll { live[$0] == nil }
        let newIDs = live.keys.filter { !order.contains($0) }.sorted { live[$0]!.mtime < live[$1]!.mtime }
        order.append(contentsOf: newIDs)

        if order.isEmpty { window.orderOut(nil); appliedKey = ""; selectedID = nil; updateMenuBarIcon("idle"); return }
        if selectedID == nil || live[selectedID!] == nil { selectedID = order.first }

        let sel = live[selectedID!]!
        stack.items = order.compactMap { id in live[id].map { SessionItem(id: id, state: $0.st.state, label: label(id, $0.st) ?? String(id.prefix(6))) } }
        stack.selectedID = selectedID
        stack.primary.caption = label(selectedID!, sel.st)     // shown for single AND multi (wraps to 2 lines)
        let key = selectedID! + "|" + sel.st.state
        if appliedKey != key { appliedKey = key; stack.primary.setState(sel.st.state) }
        updateMenuBarIcon(sel.st.state)

        // Resize bottom-anchored (the corner stays put; the list grows upward).
        let h = stack.desiredHeight()
        var f = window.frame
        f.origin.y = f.minY; f.size = NSSize(width: stack.W, height: h)
        window.setFrame(f, display: true)
        stack.frame = NSRect(origin: .zero, size: f.size)
        stack.layoutContents()
        stack.needsDisplay = true
        if !hidden { window.orderFrontRegardless() }
        saveLayoutIfChanged()
    }
}

// MARK: - Hook wiring (Claude Code session state -> animation)

let HOOK_WIRING: [(event: String, state: String, matcher: Bool)] = [
    ("SessionStart",     "waving",        false),
    ("UserPromptSubmit", "running-right", false),
    ("PreToolUse",       "running",       true),
    ("PostToolUse",      "running-left",  true),
    ("Notification",     "waiting",       false),
    ("PermissionRequest","waiting",       false),
    ("Stop",             "jumping",       false),
    ("StopFailure",      "failed",        false),
    ("SessionEnd",       "off",           false),
]

// MARK: - CLI helpers (no GUI)

func selfExecPath() -> String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

// Claude Code delivers event JSON on stdin. Read it without ever blocking the
// session: every read is gated by poll with a hard time cap, so a hook can never
// hang (e.g. if the writer keeps the pipe open).
func readHookInput() -> (session: String, cwd: String?, transcript: String?, source: String?) {
    var session = "default"; var cwd: String? = nil; var transcript: String? = nil; var source: String? = nil
    let fd: Int32 = 0
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while data.count < 1 << 20 {
        var fds = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let r = poll(&fds, 1, data.isEmpty ? 50 : 0)
        if r <= 0 { break }
        if (fds.revents & Int16(POLLIN)) == 0 { break }
        let n = read(fd, &buf, buf.count)
        if n > 0 { data.append(buf, count: n) } else { break }
    }
    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let s = obj["session_id"] as? String, !s.isEmpty { session = s }
        cwd = obj["cwd"] as? String
        transcript = obj["transcript_path"] as? String
        source = obj["source"] as? String      // SessionStart only: "startup"|"resume"|"clear"|"compact"
    }
    return (session, cwd, transcript, source)
}

func writeState(_ state: String) {
    try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    let info = readHookInput()
    let file = sessionFile(info.session)
    if state == "off" { try? FileManager.default.removeItem(at: file); return }
    var obj: [String: Any] = ["state": state]
    if let c = info.cwd { obj["cwd"] = c }
    if let t = info.transcript { obj["transcript"] = t }
    // A `/clear` reuses the session_id but starts a fresh conversation; sticky
    // once set so later state writes (running, waiting…) don't drop it. The flag
    // dies with the session file on SessionEnd ("off").
    let wasCleared = (try? Data(contentsOf: file))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["cleared"] as? Bool ?? false
    if info.source == "clear" || wasCleared { obj["cleared"] = true }
    if let data = try? JSONSerialization.data(withJSONObject: obj) { try? data.write(to: file) }
}

var singletonLockFD: Int32 = -1
func acquireSingletonOrExit() {
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    let lockPath = stateDir.appendingPathComponent("pet.lock").path
    singletonLockFD = open(lockPath, O_CREAT | O_RDWR, 0o644)
    if singletonLockFD >= 0, flock(singletonLockFD, LOCK_EX | LOCK_NB) != 0 { exit(0) }
}

func guiAlive() -> Bool {
    guard let s = try? String(contentsOf: pidURL, encoding: .utf8),
          let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
    return kill(pid, 0) == 0
}

func ensureRunning() {
    guard !guiAlive() else { return }
    let t = Process()
    t.executableURL = URL(fileURLWithPath: selfExecPath())
    t.arguments = []
    t.standardInput = FileHandle.nullDevice
    t.standardOutput = FileHandle.nullDevice
    t.standardError = FileHandle.nullDevice
    try? t.run()
}

func installHooks() {
    let exe = selfExecPath()
    try? FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var root: [String: Any] = [:]
    if let d = try? Data(contentsOf: settingsURL),
       let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { root = o }
    var hooks = (root["hooks"] as? [String: Any]) ?? [:]
    func appendGroup(_ event: String, _ state: String, matcher: Bool) {
        var arr = (hooks[event] as? [[String: Any]]) ?? []
        arr = arr.filter { g in
            let cmds = (g["hooks"] as? [[String: Any]]) ?? []
            return !cmds.contains { ($0["command"] as? String)?.contains("--state") ?? false }
        }
        let cmd: [String: Any] = ["type": "command", "command": "\"\(exe)\" --state \(state)"]
        var g: [String: Any] = ["hooks": [cmd]]
        if matcher { g["matcher"] = "*" }
        arr.append(g); hooks[event] = arr
    }
    for w in HOOK_WIRING { appendGroup(w.event, w.state, matcher: w.matcher) }
    root["hooks"] = hooks
    if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
        try? out.write(to: settingsURL)
        print("🐾 Claude Pet hooks installed (\(HOOK_WIRING.count) events) → \(settingsURL.path)")
    }
}

func uninstallHooks() {
    guard let d = try? Data(contentsOf: settingsURL),
          var root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          var hooks = root["hooks"] as? [String: Any] else { return }
    for event in Set(HOOK_WIRING.map { $0.event }) {
        if let groups = hooks[event] as? [[String: Any]] {
            let kept = groups.filter { g in
                let cmds = (g["hooks"] as? [[String: Any]]) ?? []
                return !cmds.contains { ($0["command"] as? String)?.contains("--state") ?? false }
            }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
    }
    root["hooks"] = hooks
    if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
        try? out.write(to: settingsURL)
        print("🐾 Claude Pet hooks removed.")
    }
}

func renderIcon(to path: String, size: Int = 1024) {
    _ = NSApplication.shared
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    let inset = s * 0.055
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let corner = rect.width * 0.2237
    let bg = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
    NSGradient(colors: [NSColor(red: 0.93, green: 0.56, blue: 0.42, alpha: 1),
                        Theme.coral,
                        NSColor(red: 0.78, green: 0.40, blue: 0.28, alpha: 1)])?.draw(in: bg, angle: -90)
    let side = rect.width * 0.58
    drawBuddy(in: NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side),
              accent: .white, anim: "review", phase: 0)
    img.unlockFocus()
    if let tiff = img.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
       let png = bmp.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path)); print("icon -> \(path)")
    }
}

// Drives REAL NSEvents through StackView's actual mouse handlers and asserts the
// interaction outcomes (click selects; drag reorders; click-pet does not select).
func selfTest() -> Bool {
    _ = NSApplication.shared
    let sv = StackView(frame: NSRect(x: 0, y: 0, width: 232, height: 200))
    let items = [SessionItem(id: "a", state: "running", label: "alpha"),
                 SessionItem(id: "b", state: "waiting", label: "bravo"),
                 SessionItem(id: "c", state: "idle", label: "charlie")]
    sv.items = items; sv.selectedID = "a"
    let h = sv.desiredHeight()
    sv.frame = NSRect(x: 0, y: 0, width: sv.W, height: h)
    let win = NSWindow(contentRect: sv.frame, styleMask: .borderless, backing: .buffered, defer: false)
    win.contentView = sv
    sv.layoutContents()

    var selected: String? = nil
    var reordered: [String]? = nil
    sv.onSelect = { selected = $0 }
    sv.onReorder = { reordered = $0 }

    func rowCenter(_ i: Int) -> NSPoint {
        let panel = sv.panelRect()
        return NSPoint(x: panel.midX, y: panel.maxY - sv.innerPad - (CGFloat(i) + 0.5) * sv.rowH)
    }
    func evt(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0,
                           windowNumber: win.windowNumber, context: nil, eventNumber: 0,
                           clickCount: 1, pressure: 1)!
    }
    func click(_ p: NSPoint) { sv.mouseDown(with: evt(.leftMouseDown, p)); sv.mouseUp(with: evt(.leftMouseUp, p)) }
    func drag(_ from: NSPoint, _ via: [NSPoint], _ to: NSPoint) {
        sv.mouseDown(with: evt(.leftMouseDown, from))
        for v in via { sv.mouseDragged(with: evt(.leftMouseDragged, v)) }
        sv.mouseDragged(with: evt(.leftMouseDragged, to))
        sv.mouseUp(with: evt(.leftMouseUp, to))
    }

    var ok = true
    func check(_ name: String, _ cond: Bool) { print("  [\(cond ? "PASS" : "FAIL")] \(name)"); ok = ok && cond }

    // 1) Click row 1 ("bravo") -> selects "b", order unchanged.
    selected = nil; reordered = nil
    click(rowCenter(1))
    check("click row selects that session", selected == "b")
    check("click does NOT reorder", reordered == nil)

    // 2) Click the pet area (below the list) -> no selection change.
    selected = nil
    click(NSPoint(x: sv.W / 2, y: sv.margin + 10))
    check("click on pet does not select a row", selected == nil)

    // 3) Drag row 0 ("a") down to the bottom -> order changes, "a" moves off the top.
    sv.items = items; sv.selectedID = "a"; reordered = nil
    drag(rowCenter(0), [rowCenter(1)], rowCenter(2))
    check("drag reorders the list", reordered != nil)
    check("dragged row left the top slot", (reordered?.first ?? "a") != "a")

    print(ok ? "SELFTEST: ALL PASS" : "SELFTEST: FAILURES")
    return ok
}

func renderStack(to path: String) {
    _ = NSApplication.shared
    let sv = StackView(frame: NSRect(x: 0, y: 0, width: 232, height: 200))
    sv.primary.cfg = loadFrames(); sv.primary.sprite = loadActiveSprite()
    sv.primary.caption = "Validate race prediction methodology"
    sv.primary.setState("waiting")
    sv.selectedID = "sel"
    sv.items = [
        SessionItem(id: "sel", state: "waiting", label: "Validate race prediction methodology"),
        SessionItem(id: "a", state: "running", label: "api-service"),
        SessionItem(id: "b", state: "review", label: "Refactor architecture and files"),
        SessionItem(id: "c", state: "failed", label: "data-pipeline"),
        SessionItem(id: "d", state: "idle", label: "docs-site"),
    ]
    let h = sv.desiredHeight()
    sv.frame = NSRect(x: 0, y: 0, width: sv.W, height: h)
    sv.layoutContents()
    for _ in 0..<8 { sv.primary.advance() }
    guard let rep = sv.bitmapImageRepForCachingDisplay(in: sv.bounds) else { return }
    sv.cacheDisplay(in: sv.bounds, to: rep)
    let img = NSImage(size: sv.bounds.size)
    img.lockFocus()
    NSColor(white: 0.5, alpha: 1).setFill(); sv.bounds.fill()
    rep.draw(in: sv.bounds)
    img.unlockFocus()
    if let tiff = img.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
       let png = bmp.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path)); print("rendered stack -> \(path)")
    }
}

func renderState(_ state: String, to path: String) {
    _ = NSApplication.shared
    let v = PetView(frame: NSRect(x: 0, y: 0, width: 232, height: 200))
    v.cfg = loadFrames(); v.sprite = loadActiveSprite()
    v.caption = ProcessInfo.processInfo.environment["CLAUDEPET_CAPTION"]   // QA preview only
    v.setState(state)
    for _ in 0..<8 { v.advance() }                            // settle into a representative frame
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
    v.cacheDisplay(in: v.bounds, to: rep)
    let img = NSImage(size: v.bounds.size)
    img.lockFocus()
    Theme.termBG.withAlphaComponent(1).setFill(); v.bounds.fill()
    rep.draw(in: v.bounds)
    img.unlockFocus()
    if let tiff = img.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
       let png = bmp.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path)); print("rendered \(state) -> \(path)")
    }
}

// Preview the menu-bar icon for each state on both a light and a dark bar so its
// visibility can be eyeballed (the whole point: legible in dark mode).
func renderMenuBar(to path: String) {
    _ = NSApplication.shared
    let cfg = loadFrames(); let sprite = loadActiveSprite()
    let states = ["idle", "running", "waiting", "review", "failed", "waving"]
    let cell: CGFloat = 18, pad: CGFloat = 8, scale: CGFloat = 4
    let cols = states.count
    let w = (CGFloat(cols) * (cell + pad) + pad) * scale
    let h = (cell + pad) * 2 * scale
    let img = NSImage(size: NSSize(width: w, height: h))
    img.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .none
    // top row: dark bar (dark mode), bottom row: light bar (light mode)
    NSColor(white: 0.13, alpha: 1).setFill(); NSRect(x: 0, y: h / 2, width: w, height: h / 2).fill()
    NSColor(white: 0.96, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: w, height: h / 2).fill()
    for (i, s) in states.enumerated() {
        let icon = menuBarImage(state: s, sprite: sprite, cfg: cfg)
        let x = (pad + CGFloat(i) * (cell + pad)) * scale
        for (band, _) in [(h / 2, "dark"), (CGFloat(0), "light")].enumerated() {
            let y = (band == 0 ? h / 2 : 0) + (pad / 2) * scale
            icon.draw(in: NSRect(x: x, y: y, width: cell * scale, height: cell * scale),
                      from: .zero, operation: .sourceOver, fraction: 1.0)
        }
    }
    img.unlockFocus()
    if let tiff = img.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
       let png = bmp.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path)); print("rendered menubar -> \(path)")
    }
}

// MARK: - Entry point

let args = CommandLine.arguments
if args.count >= 2 {
    switch args[1] {
    case "--state":
        writeState(args.count >= 3 ? args[2] : "idle"); ensureRunning(); exit(0)
    case "--install-hooks":   installHooks(); exit(0)
    case "--uninstall-hooks": uninstallHooks(); exit(0)
    case "--render":
        renderState(args.count >= 3 ? args[2] : "running", to: args.count >= 4 ? args[3] : "/tmp/pet.png"); exit(0)
    case "--make-icon":
        renderIcon(to: args.count >= 3 ? args[2] : "/tmp/AppIcon.png"); exit(0)
    case "--render-stack":
        renderStack(to: args.count >= 3 ? args[2] : "/tmp/stack.png"); exit(0)
    case "--render-menubar":
        renderMenuBar(to: args.count >= 3 ? args[2] : "/tmp/menubar.png"); exit(0)
    case "--selftest":
        exit(selfTest() ? 0 : 1)
    case "--aititle":
        print(readAITitle(args.count >= 3 ? args[2] : "") ?? "(no title)"); exit(0)
    default: break
    }
}

acquireSingletonOrExit()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
