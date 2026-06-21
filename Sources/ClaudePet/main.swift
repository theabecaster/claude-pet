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
// Active sprite. Drop a sheet in ~/.claude-pet/pets/ and select it with
// the loader; falls back to the built-in Claude-styled pet when absent.
let spriteURL = stateDir.appendingPathComponent("active.png")
let framesURL = stateDir.appendingPathComponent("frames.json")
let settingsURL = home.appendingPathComponent(".claude/settings.json")

// MARK: - Theme (Claude Code terminal aesthetic)

enum Theme {
    static let coral   = NSColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1.0)  // #D97757
    static let termBG  = NSColor(red: 0.106, green: 0.106, blue: 0.106, alpha: 0.94) // #1B1B1B
    static let termFG  = NSColor(red: 0.910, green: 0.902, blue: 0.886, alpha: 1.0)  // #E8E6E3
    static let green   = NSColor(red: 0.310, green: 0.690, blue: 0.435, alpha: 1.0)  // #4FB06D
    static let red     = NSColor(red: 0.851, green: 0.333, blue: 0.290, alpha: 1.0)  // #D9544A
}

// MARK: - Config (sprite-sheet layout + animations)

struct Frames: Codable {
    var frameWidth = 16
    var frameHeight = 16
    var scale: Double = 4
    var fps: Double = 8
    var animations: [String: [Int]] = [
        "idle": [0], "running": [1, 2, 3], "waiting": [0], "done": [4]
    ]
}

func loadFrames() -> Frames {
    if let data = try? Data(contentsOf: framesURL),
       let f = try? JSONDecoder().decode(Frames.self, from: data) { return f }
    return Frames()
}

struct PetState: Codable { var state = "idle"; var detail: String? }

// Single source of truth: state -> (animation, status label, status dot).
func mapState(_ s: String) -> (anim: String, label: String?, dot: NSColor?) {
    switch s {
    case "running": return ("running", "working", Theme.green)
    case "waiting": return ("waiting", "needs you", Theme.red)
    case "done":    return ("done", "ready", Theme.green)
    case "idle", "off": return ("idle", nil, nil)
    default:        return ("idle", nil, nil)
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

    private func currentFrameNumber() -> Int {
        let list = cfg.animations[anim] ?? [0]
        guard !list.isEmpty else { return 0 }
        return list[frameIndex % list.count]
    }

    func advance() {
        let list = cfg.animations[anim] ?? [0]
        if list.count > 1 { frameIndex = (frameIndex + 1) % list.count; needsDisplay = true }
    }

    func setAnimation(_ name: String, label: String?, dot: NSColor?) {
        if anim != name { anim = name; frameIndex = 0 }
        bubbleLabel = label; bubbleDot = dot
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill()
        NSGraphicsContext.current?.imageInterpolation = .none

        let fw = CGFloat(cfg.frameWidth), fh = CGFloat(cfg.frameHeight)
        let scale = CGFloat(cfg.scale)
        let drawW = fw * scale, drawH = fh * scale
        let dest = NSRect(x: (bounds.width - drawW) / 2, y: 10, width: drawW, height: drawH)

        if let img = sprite {
            let perRow = max(1, Int(img.size.width) / cfg.frameWidth)
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
            case "running", "done": return Theme.green
            case "waiting": return Theme.red
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
            .font: NSFont.systemFont(ofSize: rect.width * 0.62, weight: .bold),
            .foregroundColor: Theme.coral
        ]
        let sz = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: attrs)
    }

    // Terminal-style status pill: dark bg, coral hairline border, mono label, status dot.
    private func drawBubble(_ label: String, dot: NSColor?, above rect: NSRect) {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let text = label as NSString
        let tAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.termFG]
        let tSize = text.size(withAttributes: tAttrs)
        let dotR: CGFloat = 4
        let padX: CGFloat = 8, padY: CGFloat = 4, gap: CGFloat = 6
        let bw = padX * 2 + (dot != nil ? dotR * 2 + gap : 0) + tSize.width
        let bh = padY * 2 + max(tSize.height, dotR * 2)
        let bx = min(max(4, rect.midX - bw / 2), bounds.width - bw - 4)
        let by = rect.maxY + 6
        let br = NSRect(x: bx, y: by, width: bw, height: bh)
        let pill = NSBezierPath(roundedRect: br, xRadius: 6, yRadius: 6)
        Theme.termBG.setFill(); pill.fill()
        Theme.coral.withAlphaComponent(0.85).setStroke(); pill.lineWidth = 1; pill.stroke()

        var cursor = br.minX + padX
        if let d = dot {
            let dy = br.midY - dotR
            let dotRect = NSRect(x: cursor, y: dy, width: dotR * 2, height: dotR * 2)
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
        menu.addItem(NSMenuItem(title: "Load Sprite…", action: #selector(loadSprite), keyEquivalent: "l"))
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
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a sprite sheet (PNG). Configure layout in ~/.claude-pet/frames.json."
        if panel.runModal() == .OK, let url = panel.url {
            let dest = petsDir.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.createDirectory(at: petsDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: url, to: dest)
            try? FileManager.default.removeItem(at: spriteURL)
            try? FileManager.default.copyItem(at: dest, to: spriteURL)
            reloadSprite()
        }
    }

    @objc func resetSprite() {
        try? FileManager.default.removeItem(at: spriteURL)
        reloadSprite()
    }

    func reloadSprite() {
        view.cfg = loadFrames()
        view.sprite = NSImage(contentsOf: spriteURL)
        view.needsDisplay = true
    }

    @objc func quit() { NSApp.terminate(nil) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: petsDir, withIntermediateDirectories: true)
        try? "\(getpid())".write(to: pidURL, atomically: true, encoding: .utf8)

        view = PetView(frame: NSRect(x: 0, y: 0, width: 130, height: 150))
        view.cfg = loadFrames()
        view.sprite = NSImage(contentsOf: spriteURL)

        window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.contentView = view

        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: vf.maxX - 150, y: vf.minY + 28))
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
        let m = mapState(s.state)
        view.setAnimation(m.anim, label: m.label, dot: m.dot)
        if !window.isVisible { window.orderFrontRegardless() }
    }
}

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
    try? t.run()   // detached GUI instance; persists after we exit
}

func installHooks() {
    let exe = selfExecPath()
    try? FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    var root: [String: Any] = [:]
    if let d = try? Data(contentsOf: settingsURL),
       let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { root = o }
    var hooks = (root["hooks"] as? [String: Any]) ?? [:]
    // Append our group to each event WITHOUT disturbing existing hooks.
    // Idempotent: any previous Claude Pet entry (command contains "--state")
    // is dropped first, so re-running install never duplicates.
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
    appendGroup("SessionStart", "idle", matcher: false)
    appendGroup("UserPromptSubmit", "running", matcher: false)
    appendGroup("PreToolUse", "running", matcher: true)
    appendGroup("Notification", "waiting", matcher: false)
    appendGroup("Stop", "done", matcher: false)
    appendGroup("SessionEnd", "off", matcher: false)
    root["hooks"] = hooks
    if let out = try? JSONSerialization.data(withJSONObject: root,
                                             options: [.prettyPrinted, .sortedKeys]) {
        try? out.write(to: settingsURL)
        print("✳ Claude Pet hooks installed → \(settingsURL.path)")
    }
}

func uninstallHooks() {
    guard let d = try? Data(contentsOf: settingsURL),
          var root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          var hooks = root["hooks"] as? [String: Any] else { return }
    for key in ["SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SessionEnd"] {
        if let groups = hooks[key] as? [[String: Any]] {
            let kept = groups.filter { g in
                let cmds = (g["hooks"] as? [[String: Any]]) ?? []
                return !cmds.contains { ($0["command"] as? String)?.contains("--state") ?? false }
            }
            if kept.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = kept }
        }
    }
    root["hooks"] = hooks
    if let out = try? JSONSerialization.data(withJSONObject: root,
                                             options: [.prettyPrinted, .sortedKeys]) {
        try? out.write(to: settingsURL)
        print("✳ Claude Pet hooks removed.")
    }
}

func renderState(_ state: String, to path: String) {
    _ = NSApplication.shared
    let v = PetView(frame: NSRect(x: 0, y: 0, width: 130, height: 150))
    v.cfg = loadFrames()
    v.sprite = NSImage(contentsOf: spriteURL)
    let m = mapState(state)
    v.setAnimation(m.anim, label: m.label, dot: m.dot)
    v.frameIndex = 1
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
    v.cacheDisplay(in: v.bounds, to: rep)
    let img = NSImage(size: v.bounds.size)
    img.lockFocus()
    Theme.termBG.withAlphaComponent(1).setFill(); v.bounds.fill()  // terminal backdrop
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
        writeState(args.count >= 3 ? args[2] : "idle")
        ensureRunning()
        exit(0)
    case "--install-hooks":  installHooks(); exit(0)
    case "--uninstall-hooks": uninstallHooks(); exit(0)
    case "--render":
        renderState(args.count >= 3 ? args[2] : "running",
                    to: args.count >= 4 ? args[3] : "/tmp/pet.png")
        exit(0)
    default: break
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
