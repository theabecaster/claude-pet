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
// One state file per Claude Code session -> one pet per session.
let sessionsDir = stateDir.appendingPathComponent("sessions")
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

// MARK: - Codex atlas contract
// 8 columns x 9 rows, 192x208 cells, transparent unused cells. Matches Codex
// Pets exactly, so any spritesheet.webp from codex-pets.net / hatch-pet works.
// Row order + frame counts are the canonical Codex contract.

let CODEX_COLUMNS = 8
let CODEX_ROW_SPECS: [(state: String, row: Int, frames: Int)] = [
    ("idle", 0, 6),
    ("running-right", 1, 8),
    ("running-left", 2, 8),
    ("waving", 3, 4),
    ("jumping", 4, 5),
    ("failed", 5, 8),
    ("waiting", 6, 6),
    ("running", 7, 6),
    ("review", 8, 6),
]

func codexAnimations() -> [String: [Int]] {
    var out: [String: [Int]] = [:]
    for spec in CODEX_ROW_SPECS {
        out[spec.state] = (0..<spec.frames).map { spec.row * CODEX_COLUMNS + $0 }
    }
    return out
}

// MARK: - Config (sprite-sheet layout + animations)

struct Frames: Codable {
    var frameWidth = 192
    var frameHeight = 208
    var scale: Double = 0.42        // 192x208 -> ~81x87 on screen
    var fps: Double = 8
    var animations: [String: [Int]]? = nil   // nil -> Codex default
}

func loadFrames() -> Frames {
    if let data = try? Data(contentsOf: framesURL),
       let f = try? JSONDecoder().decode(Frames.self, from: data) { return f }
    return Frames()
}

struct PetState: Codable { var state = "idle"; var cwd: String?; var transcript: String?; var detail: String? }

// Read the session's AI-generated title from its transcript (JSONL). Titles are
// appended as records of type "ai-title"; the latest one near the end wins. Only
// the file tail is scanned so this stays cheap even for large transcripts.
func readAITitle(_ path: String) -> String? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
    let chunk = 65536
    if size > chunk { try? fh.seek(toOffset: UInt64(size - chunk)) }
    guard let data = try? fh.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
    var title: String?
    for line in text.split(separator: "\n") where line.contains("\"type\":\"ai-title\"") {
        if let d = line.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let t = o["aiTitle"] as? String, !t.isEmpty { title = t }
    }
    return title
}

// MARK: - State model: Claude Code session state -> Codex animation row

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

func loadActiveSprite() -> NSImage? {
    for name in activeNames {
        let u = stateDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: u.path), let img = NSImage(contentsOf: u) { return img }
    }
    return nil
}

// MARK: - Original mascot ("terminal buddy")
// Fully drawn in code — no external/third-party art, no resemblance to any
// existing logo or character. A rounded terminal-creature with expressive eyes
// and a cursor mouth. Used for the default pet and the app icon.

func drawBuddy(in rect: NSRect, accent: NSColor, anim: String, frame: Int) {
    let body = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.32, yRadius: rect.height * 0.32)
    Theme.termBG.setFill(); body.fill()
    accent.setStroke(); body.lineWidth = max(2, rect.width * 0.05); body.stroke()

    let eyeR = rect.width * 0.12
    let eyeDX = rect.width * 0.19
    let eyeY = rect.midY + rect.height * 0.06
    let cx = rect.midX
    let blink = (frame % 7 == 6)
    let mode: String = {
        switch anim {
        case "review", "jumping": return "happy"
        case "waiting": return "wow"
        case "failed": return "dead"
        case "running", "running-right", "running-left": return "busy"
        default: return "idle"
        }
    }()

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
        let er = (mode == "wow") ? eyeR * 1.15 : eyeR
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - er, y: c.y - er, width: er * 2, height: er * 2)).fill()
        let pr = er * 0.5
        let dy = (mode == "busy") ? -er * 0.3 : 0
        NSColor(white: 0.1, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - pr, y: c.y - pr + dy, width: pr * 2, height: pr * 2)).fill()
    }
    eye(cx - eyeDX); eye(cx + eyeDX)

    let my = rect.midY - rect.height * 0.20
    let mw = rect.width * 0.16
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
        if frame % 2 == 0 {
            accent.setFill()
            NSBezierPath(rect: NSRect(x: cx - mw * 0.5, y: my - mw * 0.25, width: mw, height: mw * 0.5)).fill()
        }
    default:
        mouth.move(to: NSPoint(x: cx - mw * 0.7, y: my)); mouth.line(to: NSPoint(x: cx + mw * 0.7, y: my))
        accent.setStroke(); mouth.stroke()
    }
}

// MARK: - View

final class PetView: NSView {
    var sprite: NSImage?
    var cfg = Frames()
    var anim = "idle"
    var frameIndex = 0
    var bubbleLabel: String?
    var bubbleDot: NSColor?
    var oneShotFallback: String?
    var caption: String?   // project / session label (shown when set)

    private func anims() -> [String: [Int]] { cfg.animations ?? codexAnimations() }

    private func currentFrameNumber() -> Int {
        let list = anims()[anim] ?? [0]
        guard !list.isEmpty else { return 0 }
        return list[frameIndex % list.count]
    }

    func setState(_ s: String) {
        let d = describe(s)
        if anim != d.anim { frameIndex = 0 }
        anim = d.anim
        bubbleLabel = d.label
        bubbleDot = d.dot
        oneShotFallback = d.oneShot
        needsDisplay = true
    }

    func advance() {
        let list = anims()[anim] ?? [0]
        guard list.count > 1 else { return }
        frameIndex += 1
        if frameIndex >= list.count {
            if let fb = oneShotFallback { setState(fb); return }   // one-shot finished
            frameIndex = 0
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set(); dirtyRect.fill()
        NSGraphicsContext.current?.imageInterpolation = .none

        let fw = CGFloat(cfg.frameWidth), fh = CGFloat(cfg.frameHeight)
        let scale = CGFloat(cfg.scale)
        let drawW = fw * scale, drawH = fh * scale
        let dest = NSRect(x: (bounds.width - drawW) / 2, y: 10, width: drawW, height: drawH)

        if let img = sprite {
            let perRow = max(1, Int(img.size.width.rounded()) / cfg.frameWidth)
            let n = currentFrameNumber()
            let col = n % perRow, row = n / perRow
            let srcY = img.size.height - CGFloat(row + 1) * fh
            let src = NSRect(x: CGFloat(col) * fw, y: srcY, width: fw, height: fh)
            img.draw(in: dest, from: src, operation: .sourceOver, fraction: 1.0)
        } else {
            drawPlaceholder(in: dest)
        }
        // Stack upward from the pet: pet -> status pill -> caption.
        var topY = dest.maxY
        if let label = bubbleLabel { topY = drawBubble(label, dot: bubbleDot, above: dest) }
        if let cap = caption { drawCaption(cap, atY: topY + 5) }
    }

    // Small dim project label sitting just above the status pill so pets from
    // different sessions are distinguishable at a glance.
    private func drawCaption(_ text: String, atY y: CGFloat) {
        let font: NSFont = NSFont(name: "Menlo", size: 9) ?? NSFont.systemFont(ofSize: 9)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.termFG.withAlphaComponent(0.7)]
        let maxW = bounds.width - 6
        // Truncate long session titles with an ellipsis so they fit the pet width.
        var display = text
        if (display as NSString).size(withAttributes: attrs).width > maxW {
            while display.count > 1,
                  ((display + "…") as NSString).size(withAttributes: attrs).width > maxW {
                display = String(display.dropLast())
            }
            display += "…"
        }
        let s = display as NSString
        let sz = s.size(withAttributes: attrs)
        let x = min(max(2, (bounds.width - sz.width) / 2), bounds.width - sz.width - 2)
        s.draw(at: NSPoint(x: x, y: min(y, bounds.height - sz.height - 2)), withAttributes: attrs)
    }

    private func stateAccent() -> NSColor {
        switch anim {
        case "running", "running-right", "running-left", "jumping", "review": return Theme.green
        case "waiting", "failed": return Theme.red
        default: return Theme.coral
        }
    }

    // Built-in default pet: our original code-drawn terminal buddy.
    private func drawPlaceholder(in rect: NSRect) {
        let bounce = CGFloat((frameIndex % 2) * 4)
        var r = rect; r.origin.y += bounce
        drawBuddy(in: r, accent: stateAccent(), anim: anim, frame: frameIndex)
    }

    // Terminal-style status pill: dark bg, coral hairline border, mono label, status dot.
    // Returns the pill's top Y so callers can stack content above it.
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
            let dotRect = NSRect(x: cursor, y: br.midY - dotR, width: dotR * 2, height: dotR * 2)
            d.setFill(); NSBezierPath(ovalIn: dotRect).fill()
            cursor += dotR * 2 + gap
        }
        text.draw(at: NSPoint(x: cursor, y: br.midY - tSize.height / 2), withAttributes: tAttrs)
        return br.maxY
    }
}

// MARK: - App (one pet window per Claude Code session)

// A single floating pet window bound to one session.
final class PetWindow {
    let window: NSWindow
    let view: PetView
    var appliedState = ""
    var titleMtime: Date?
    var cachedTitle: String?

    init() {
        view = PetView(frame: NSRect(x: 0, y: 0, width: 170, height: 210))
        view.cfg = loadFrames()
        view.sprite = loadActiveSprite()
        window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.contentView = view
        window.orderFrontRegardless()
    }

    func reloadSprite() {
        view.cfg = loadFrames()
        view.sprite = loadActiveSprite()
        view.needsDisplay = true
    }

    func place(_ origin: NSPoint) { window.setFrameOrigin(origin) }
    func close() { window.orderOut(nil) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var pets: [String: PetWindow] = [:]   // sessionID -> window
    var hidden = false
    var statusItem: NSStatusItem!

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐾"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show / Hide Pets", action: #selector(toggleVisibility), keyEquivalent: "p"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Load Pet… (Codex .webp or folder)", action: #selector(loadSprite), keyEquivalent: "l"))
        menu.addItem(NSMenuItem(title: "Reset to Default Pet", action: #selector(resetSprite), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Claude Pet", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func toggleVisibility() {
        hidden.toggle()
        for (_, p) in pets { if hidden { p.close() } else { p.window.orderFrontRegardless() } }
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
            let candidates = ["spritesheet.webp", "spritesheet.png"]
            guard let found = candidates.map({ url.appendingPathComponent($0) })
                    .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
            sheet = found
        }
        let ext = sheet.pathExtension.lowercased() == "png" ? "png" : "webp"
        for name in activeNames { try? FileManager.default.removeItem(at: stateDir.appendingPathComponent(name)) }
        try? FileManager.default.copyItem(at: sheet, to: stateDir.appendingPathComponent("active.\(ext)"))
        for (_, p) in pets { p.reloadSprite() }
    }

    @objc func resetSprite() {
        for name in activeNames { try? FileManager.default.removeItem(at: stateDir.appendingPathComponent(name)) }
        for (_, p) in pets { p.reloadSprite() }
    }

    @objc func quit() { NSApp.terminate(nil) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: petsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try? "\(getpid())".write(to: pidURL, atomically: true, encoding: .utf8)
        setupMenu()
        sync()

        let fps = loadFrames().fps
        Timer.scheduledTimer(withTimeInterval: 1.0 / max(1.0, fps), repeats: true) { [weak self] _ in
            self?.pets.values.forEach { $0.view.advance() }
        }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.sync()
        }
    }

    // Reconcile windows with the per-session state files on disk.
    private func sync() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension == "json" } ?? []

        var live: [String: PetState] = [:]
        for f in files {
            let id = f.deletingPathExtension().lastPathComponent
            // Prune crashed/stale sessions that never sent SessionEnd.
            if let attrs = try? fm.attributesOfItem(atPath: f.path),
               let m = attrs[.modificationDate] as? Date, -m.timeIntervalSinceNow > SESSION_STALE_SECONDS {
                try? fm.removeItem(at: f); continue
            }
            if let data = try? Data(contentsOf: f),
               let st = try? JSONDecoder().decode(PetState.self, from: data) { live[id] = st }
        }

        // Remove pets whose session ended/disappeared.
        for id in pets.keys where live[id] == nil { pets[id]?.close(); pets[id] = nil }

        // Add/refresh pets for live sessions.
        var changed = false
        for (id, st) in live {
            let pet: PetWindow
            if let existing = pets[id] { pet = existing }
            else { pet = PetWindow(); pets[id] = pet; changed = true; if hidden { pet.close() } }
            // Prefer Claude Code's AI-generated session title (cached, refreshed
            // when the transcript changes); fall back to the project folder name
            // when there are multiple sessions.
            if let tp = st.transcript {
                let m = (try? fm.attributesOfItem(atPath: tp))?[.modificationDate] as? Date
                if pet.titleMtime != m { pet.titleMtime = m; pet.cachedTitle = readAITitle(tp) }
            }
            let folder = st.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            let cap = pet.cachedTitle ?? (live.count > 1 ? folder : nil)
            if pet.view.caption != cap { pet.view.caption = cap; pet.view.needsDisplay = true }
            if pet.appliedState != st.state {          // only apply on change (preserve one-shots)
                pet.appliedState = st.state
                pet.view.setState(st.state)
                if !hidden { pet.window.orderFrontRegardless() }
            }
        }
        if changed { relayout() }
    }

    // Lay pets out along the bottom-right, marching left as more appear.
    private func relayout() {
        guard let vf = NSScreen.main?.visibleFrame else { return }
        for (i, id) in pets.keys.sorted().enumerated() {
            pets[id]?.place(NSPoint(x: vf.maxX - 190 - CGFloat(i) * 185, y: vf.minY + 28))
        }
    }
}

// MARK: - Hook wiring (Claude Code session state -> Codex animation)

let HOOK_WIRING: [(event: String, state: String, matcher: Bool)] = [
    ("SessionStart",     "waving",        false),  // greet, then settle to idle
    ("UserPromptSubmit", "running-right", false),  // new turn — trot in
    ("PreToolUse",       "running",       true),   // actively working
    ("PostToolUse",      "running-left",  true),   // step done — trot back
    ("Notification",     "waiting",       false),  // needs your input/approval
    ("PermissionRequest","waiting",       false),
    ("Stop",             "jumping",       false),  // celebrate, then ready/review
    ("StopFailure",      "failed",        false),  // turn errored
    ("SessionEnd",       "off",           false),  // hide
]

// MARK: - CLI helpers (no GUI)

func selfExecPath() -> String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

// Claude Code delivers event JSON on stdin. Read it without ever blocking the
// session: stdin is switched to non-blocking and drained with a hard time cap,
// so a hook can never hang (e.g. if the writer keeps the pipe open).
func readHookInput() -> (session: String, cwd: String?, transcript: String?) {
    var session = "default"; var cwd: String? = nil; var transcript: String? = nil
    let fd: Int32 = 0
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    // Every read is gated by poll, so we only read when bytes are guaranteed
    // ready — read() then can't block. Wait up to 50ms for the first bytes;
    // once draining, stop the instant nothing more is immediately available.
    while data.count < 1 << 20 {
        var fds = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let r = poll(&fds, 1, data.isEmpty ? 50 : 0)
        if r <= 0 { break }                       // timeout / nothing more ready
        if (fds.revents & Int16(POLLIN)) == 0 { break }
        let n = read(fd, &buf, buf.count)
        if n > 0 { data.append(buf, count: n) } else { break }   // EOF or error
    }
    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let s = obj["session_id"] as? String, !s.isEmpty { session = s }
        cwd = obj["cwd"] as? String
        transcript = obj["transcript_path"] as? String
    }
    return (session, cwd, transcript)
}

func writeState(_ state: String) {
    try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    let info = readHookInput()
    let file = sessionFile(info.session)
    if state == "off" {
        try? FileManager.default.removeItem(at: file)   // session ended -> remove its pet
        return
    }
    var obj: [String: Any] = ["state": state]
    if let c = info.cwd { obj["cwd"] = c }
    if let t = info.transcript { obj["transcript"] = t }
    if let data = try? JSONSerialization.data(withJSONObject: obj) {
        try? data.write(to: file)
    }
}

// Hard single-instance guarantee for the GUI: hold an exclusive advisory lock
// for the process lifetime. Races where several --state calls each spawn a GUI
// resolve cleanly — only the lock holder survives, the rest exit immediately.
var singletonLockFD: Int32 = -1
func acquireSingletonOrExit() {
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    let lockPath = stateDir.appendingPathComponent("pet.lock").path
    singletonLockFD = open(lockPath, O_CREAT | O_RDWR, 0o644)
    if singletonLockFD >= 0, flock(singletonLockFD, LOCK_EX | LOCK_NB) != 0 {
        exit(0)   // another GUI already owns the overlay
    }
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
    // Fully detach: never inherit the caller's stdio, or the caller (a hook, a
    // shell) would block until the long-lived GUI exits. Own session too.
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
    // Append-only + idempotent: drop any prior Claude Pet entry first.
    func appendGroup(_ event: String, _ state: String, matcher: Bool) {
        var arr = (hooks[event] as? [[String: Any]]) ?? []
        arr = arr.filter { g in
            let cmds = (g["hooks"] as? [[String: Any]]) ?? []
            return !cmds.contains { ($0["command"] as? String)?.contains("--state") ?? false }
        }
        let cmd: [String: Any] = ["type": "command", "command": "\"\(exe)\" --state \(state)"]
        var g: [String: Any] = ["hooks": [cmd]]
        if matcher { g["matcher"] = "*" }
        arr.append(g)
        hooks[event] = arr
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

// Draws the app icon: a Claude-coral squircle with a white sunburst mark.
func renderIcon(to path: String, size: Int = 1024) {
    _ = NSApplication.shared
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high

    let inset = s * 0.055
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let corner = rect.width * 0.2237   // Apple icon-grid corner ratio
    let bg = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
    let grad = NSGradient(colors: [
        NSColor(red: 0.93, green: 0.56, blue: 0.42, alpha: 1.0),
        Theme.coral,
        NSColor(red: 0.78, green: 0.40, blue: 0.28, alpha: 1.0)])
    grad?.draw(in: bg, angle: -90)

    // Our original mascot, smiling, centered.
    let side = rect.width * 0.58
    let bRect = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
    drawBuddy(in: bRect, accent: .white, anim: "review", frame: 0)

    img.unlockFocus()
    if let tiff = img.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
       let png = bmp.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
        print("icon -> \(path)")
    }
}

func renderState(_ state: String, to path: String) {
    _ = NSApplication.shared
    let v = PetView(frame: NSRect(x: 0, y: 0, width: 170, height: 210))
    v.cfg = loadFrames()
    v.sprite = loadActiveSprite()
    v.caption = ProcessInfo.processInfo.environment["CLAUDEPET_CAPTION"]   // QA preview only
    v.setState(state)
    v.frameIndex = 1
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
    v.cacheDisplay(in: v.bounds, to: rep)
    let img = NSImage(size: v.bounds.size)
    img.lockFocus()
    Theme.termBG.withAlphaComponent(1).setFill(); v.bounds.fill()
    rep.draw(in: v.bounds)
    img.unlockFocus()
    if let tiff = img.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
       let png = bmp.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
        print("rendered \(state) -> \(path)")
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
        renderState(args.count >= 3 ? args[2] : "running",
                    to: args.count >= 4 ? args[3] : "/tmp/pet.png"); exit(0)
    case "--make-icon":
        renderIcon(to: args.count >= 3 ? args[2] : "/tmp/AppIcon.png"); exit(0)
    case "--aititle":
        print(readAITitle(args.count >= 3 ? args[2] : "") ?? "(no title)"); exit(0)
    default: break
    }
}

acquireSingletonOrExit()   // only one overlay process survives
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
