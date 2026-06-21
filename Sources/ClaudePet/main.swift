import AppKit
import Foundation
import Darwin
import UniformTypeIdentifiers

// MARK: - Paths

let home = FileManager.default.homeDirectoryForCurrentUser
let stateDir = home.appendingPathComponent(".claude-pet")
let stateFileURL = stateDir.appendingPathComponent("state.json")
let pidURL = stateDir.appendingPathComponent("pet.pid")
let petsDir = stateDir.appendingPathComponent("pets")
let framesURL = stateDir.appendingPathComponent("frames.json")
let settingsURL = home.appendingPathComponent(".claude/settings.json")
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

struct PetState: Codable { var state = "idle"; var detail: String? }

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

// MARK: - View

final class PetView: NSView {
    var sprite: NSImage?
    var cfg = Frames()
    var anim = "idle"
    var frameIndex = 0
    var bubbleLabel: String?
    var bubbleDot: NSColor?
    var oneShotFallback: String?

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
        if let label = bubbleLabel { drawBubble(label, dot: bubbleDot, above: dest) }
    }

    // Built-in fallback pet: a dark terminal token with the Claude coral "✳".
    private func drawPlaceholder(in rect: NSRect) {
        let accent: NSColor = {
            switch anim {
            case "running", "running-right", "running-left", "jumping", "review": return Theme.green
            case "waiting", "failed": return Theme.red
            default: return Theme.coral
            }
        }()
        let bounce = CGFloat((frameIndex % 2) * 5)
        var r = rect; r.origin.y += bounce
        let path = NSBezierPath(roundedRect: r, xRadius: r.width * 0.28, yRadius: r.height * 0.28)
        Theme.termBG.setFill(); path.fill()
        accent.setStroke(); path.lineWidth = 2.5; path.stroke()
        let s = "✳" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: rect.width * 0.55, weight: .bold),
            .foregroundColor: Theme.coral]
        let sz = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: attrs)
    }

    // Terminal-style status pill: dark bg, coral hairline border, mono label, status dot.
    private func drawBubble(_ label: String, dot: NSColor?, above rect: NSRect) {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
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
    }
}

// MARK: - App (GUI overlay)

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var view: PetView!
    var lastMTime: Date?
    var statusItem: NSStatusItem!

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "✳"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show / Hide Pet", action: #selector(toggleVisibility), keyEquivalent: "p"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Load Pet… (Codex .webp or folder)", action: #selector(loadSprite), keyEquivalent: "l"))
        menu.addItem(NSMenuItem(title: "Reset to Default Pet", action: #selector(resetSprite), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Claude Pet", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func toggleVisibility() {
        if window.isVisible { window.orderOut(nil) } else { window.orderFrontRegardless() }
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
            // Codex pet folder: find the spritesheet inside.
            let candidates = ["spritesheet.webp", "spritesheet.png"]
            guard let found = candidates.map({ url.appendingPathComponent($0) })
                    .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
            sheet = found
        }
        let ext = sheet.pathExtension.lowercased() == "png" ? "png" : "webp"
        // Clear any previous active sprite, then install the new one.
        for name in activeNames { try? FileManager.default.removeItem(at: stateDir.appendingPathComponent(name)) }
        let dest = stateDir.appendingPathComponent("active.\(ext)")
        try? FileManager.default.copyItem(at: sheet, to: dest)
        reloadSprite()
    }

    @objc func resetSprite() {
        for name in activeNames { try? FileManager.default.removeItem(at: stateDir.appendingPathComponent(name)) }
        reloadSprite()
    }

    func reloadSprite() {
        view.cfg = loadFrames()
        view.sprite = loadActiveSprite()
        view.needsDisplay = true
    }

    @objc func quit() { NSApp.terminate(nil) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: petsDir, withIntermediateDirectories: true)
        try? "\(getpid())".write(to: pidURL, atomically: true, encoding: .utf8)

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
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: vf.maxX - 190, y: vf.minY + 28))
        }
        window.orderFrontRegardless()
        setupMenu()
        applyState()

        Timer.scheduledTimer(withTimeInterval: 1.0 / max(1.0, view.cfg.fps), repeats: true) { [weak self] _ in
            self?.view.advance()
        }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.pollState()
        }
    }

    private func pollState() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: stateFileURL.path)
        let m = attrs?[.modificationDate] as? Date
        if m != lastMTime { lastMTime = m; applyState() }
    }

    private func applyState() {
        var s = PetState()
        if let data = try? Data(contentsOf: stateFileURL),
           let decoded = try? JSONDecoder().decode(PetState.self, from: data) { s = decoded }
        if s.state == "off" { window.orderOut(nil); return }
        view.setState(s.state)
        if !window.isVisible { window.orderFrontRegardless() }
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

func writeState(_ state: String) {
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    try? "{\"state\":\"\(state)\"}\n".write(to: stateFileURL, atomically: true, encoding: .utf8)
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
        print("✳ Claude Pet hooks installed (\(HOOK_WIRING.count) events) → \(settingsURL.path)")
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
        print("✳ Claude Pet hooks removed.")
    }
}

func renderState(_ state: String, to path: String) {
    _ = NSApplication.shared
    let v = PetView(frame: NSRect(x: 0, y: 0, width: 170, height: 210))
    v.cfg = loadFrames()
    v.sprite = loadActiveSprite()
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
    default: break
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
