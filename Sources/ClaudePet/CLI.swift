import AppKit
import Foundation

// MARK: - Terminal status report + offscreen renderers + selftest (no persistent GUI)

// A terminal-friendly health + session report (reads only; never starts the GUI).
// Handy for debugging and for users who live in the terminal.
func statusReport() {
    let fm = FileManager.default
    let prefs = Prefs.load()
    print("Claude Pet — status")
    print("  overlay running : \(guiAlive() ? "yes" : "no")")
    print("  hooks wired     : \(hooksPointToSelf() ? "yes (this build)" : "no / different build")")
    print("  statusline      : \(statusLineState())")
    print("  custom sprite   : \(loadActiveSprite() != nil ? "loaded" : "default mascot")")
    print("  theme           : \(prefs.theme)")
    print("  alerts          : sound=\(prefs.soundOnAttention) bounce=\(prefs.bounceOnAttention) muted=\(prefs.muted)")

    let files = (try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil))?
        .filter { $0.pathExtension == "json" } ?? []
    if files.isEmpty { print("  sessions        : none"); return }
    print("  sessions        : \(files.count)")
    for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        guard let data = try? Data(contentsOf: f),
              let st = try? JSONDecoder().decode(PetState.self, from: data) else { continue }
        let id = f.deletingPathExtension().lastPathComponent
        let meta = st.transcript.map { readTranscriptMeta($0, ignoreCustom: st.cleared == true) } ?? SessionMeta()
        let name = meta.title ?? st.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? String(id.prefix(8))
        var line = "    • \(name)  [\(st.state)]"
        if let d = st.detail { line += " — \(d)" }
        print(line)
        var bits: [String] = []
        if let m = meta.model { bits.append(shortModel(m)) }
        if let t = meta.ctxTokens { bits.append(compactTokens(t) + " ctx") }
        if let b = meta.branch { bits.append(b) }
        if let badge = modeBadge(st.mode) { bits.append(badge) }
        if !bits.isEmpty { print("        \(bits.joined(separator: " · "))") }
        // Cumulative totals (full transcript scan): turns, tokens, est. cost, duration.
        if let tp = st.transcript {
            let t = readTranscriptTotals(tp)
            if t.turns > 0 {
                var totals = "turns \(t.turns) · in \(compactTokens(t.inputTokens)) · out \(compactTokens(t.outputTokens)) · ~\(compactUSD(t.costUSD))"
                if let dur = t.duration { totals += " · up \(compactElapsed(dur))" }
                print("        \(totals)")
            }
        }
    }
    print("  cost figures are rough estimates (public per-token prices).")
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
    sv.primary.hovering = true                  // reveal the picker so rows are interactive
    sv.listExpanded = true                      // expand so individual rows are clickable/draggable
    for _ in 0..<60 { sv.advanceExpand() }      // settle the grow ease so all rows are laid out
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

    // 1b) Collapsed picker: a click expands (no selection), not a select.
    sv.listExpanded = false; selected = nil
    click(rowCenter(0))
    check("collapsed click expands the picker", sv.listExpanded && selected == nil)
    sv.listExpanded = true

    // 2) Click the pet (now above the picker) -> no selection change, but it pokes the pet.
    selected = nil
    var poked = false
    sv.onPetTapped = { poked = true }
    click(NSPoint(x: sv.W / 2, y: sv.primary.frame.midY))
    check("click on pet does not select a row", selected == nil)
    check("tap on pet triggers a reaction", poked)

    // 3) Drag row 0 ("a") down to the bottom -> order changes, "a" moves off the top.
    sv.items = items; sv.selectedID = "a"; reordered = nil; sv.listExpanded = true
    drag(rowCenter(0), [rowCenter(1)], rowCenter(2))
    check("drag reorders the list", reordered != nil)
    check("dragged row left the top slot", (reordered?.first ?? "a") != "a")

    // 4) Mid-drag, isReordering is true so the timer's sync() won't rebuild `items`
    //    from the uncommitted `order` and snap the grabbed row back (the reorder bug).
    sv.items = items; sv.selectedID = "a"; sv.listExpanded = true
    sv.mouseDown(with: evt(.leftMouseDown, rowCenter(0)))
    sv.mouseDragged(with: evt(.leftMouseDragged, rowCenter(1)))
    check("isReordering guards sync mid-drag", sv.isReordering)
    sv.mouseUp(with: evt(.leftMouseUp, rowCenter(1)))
    check("isReordering clears after drag", !sv.isReordering)

    // 5) Data humanizers used to surface what Claude Code exposes.
    check("toolVerb maps edit tools", toolVerb("Edit") == "editing" && toolVerb("Bash") == "running")
    check("toolVerb handles mcp + unknown", toolVerb("mcp__x__y") == "calling tool")
    check("shortModel parses family + version", shortModel("claude-opus-4-8") == "opus 4.8")
    check("compactTokens humanizes", compactTokens(43958) == "43k" && compactTokens(1_200_000) == "1.2M")
    check("compactElapsed humanizes", compactElapsed(90) == "1m" && compactElapsed(5) == "5s")
    check("errorReason maps types", errorReason("rate_limit") == "rate limited")
    check("detailFor reads hook payload", detailFor(state: "running", { var h = HookInput(); h.toolName = "Read"; return h }()) == "reading")
    check("toolTarget pulls file basename",
          toolTarget("Edit", ["file_path": "/a/b/main.swift"]) == "main.swift")
    check("toolTarget pulls bash program",
          toolTarget("Bash", ["command": "npm test --silent"]) == "npm")
    check("detailFor folds verb + target",
          detailFor(state: "running", { var h = HookInput(); h.toolName = "Edit"; h.toolInput = ["file_path": "/x/y/app.ts"]; return h }()) == "editing app.ts")
    check("detailFor handles PreCompact",
          detailFor(state: "running", { var h = HookInput(); h.event = "PreCompact"; h.trigger = "auto"; return h }()) == "auto-compacting")
    check("modeBadge maps plan, hides default", modeBadge("plan") == "plan" && modeBadge("default") == nil)

    // 6) Theme palettes resolve and are swappable.
    check("palette lookup falls back", Palette.byID("nope").id == "claude" && Palette.byID("midnight").id == "midnight")

    // 7) Prefs round-trip (in-memory; never touches the user's prefs.json).
    var p = Prefs(); p.theme = "grove"; p.muted = true; p.pinDetails = true; p.renudge = false
    if let d = try? JSONEncoder().encode(p), let r = try? JSONDecoder().decode(Prefs.self, from: d) {
        check("prefs round-trip", r.theme == "grove" && r.muted && r.pinDetails && !r.renudge)
    } else { check("prefs round-trip", false) }
    check("contextLimit infers window", contextLimitFor(tokens: 50_000) == 200_000 && contextLimitFor(tokens: 260_000) == 1_000_000)

    // 8) Cost / totals helpers.
    check("compactUSD formats", compactUSD(0.004) == "<$0.01" && compactUSD(0.42) == "$0.42" && compactUSD(13.0) == "$13")
    check("modelPrices vary by family", modelPrices("claude-opus-4-8").out == 75 && modelPrices("claude-haiku-4-5").out == 4)

    // 9) Full-transcript totals on a synthesized JSONL (temp file; cleaned up).
    let tmp = NSTemporaryDirectory() + "claudepet-selftest-\(getpid()).jsonl"
    let sample = """
    {"type":"assistant","timestamp":"2026-01-01T00:00:00.000Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
    {"type":"user","timestamp":"2026-01-01T00:05:00.000Z","message":{}}
    {"type":"assistant","timestamp":"2026-01-01T00:10:00.000Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":2000,"output_tokens":300,"cache_read_input_tokens":500,"cache_creation_input_tokens":0}}}
    """
    try? sample.write(toFile: tmp, atomically: true, encoding: .utf8)
    let totals = readTranscriptTotals(tmp)
    try? FileManager.default.removeItem(atPath: tmp)
    check("totals count turns", totals.turns == 2)
    check("totals sum tokens", totals.inputTokens == 3000 && totals.outputTokens == 500)
    check("totals span duration", Int(totals.duration ?? 0) == 600)
    check("totals estimate cost", totals.costUSD > 0)

    // 10) statusLine claim is only-if-empty-or-ours — never clobbers a user's own.
    var slEmpty: [String: Any] = [:]
    check("statusline claims empty slot", installStatusLineInto(&slEmpty, exe: "/x") &&
          (((slEmpty["statusLine"] as? [String: Any])?["command"] as? String)?.contains("--statusline") ?? false))
    var slForeign: [String: Any] = ["statusLine": ["type": "command", "command": "starship prompt"]]
    check("statusline leaves user's own", !installStatusLineInto(&slForeign, exe: "/x") &&
          ((slForeign["statusLine"] as? [String: Any])?["command"] as? String) == "starship prompt")
    var slOurs: [String: Any] = ["statusLine": ["type": "command", "command": "\"/old\" --statusline"]]
    check("statusline reclaims+refreshes ours", installStatusLineInto(&slOurs, exe: "/new") &&
          (((slOurs["statusLine"] as? [String: Any])?["command"] as? String)?.contains("/new") ?? false))

    print(ok ? "SELFTEST: ALL PASS" : "SELFTEST: FAILURES")
    return ok
}

func renderStack(to path: String) {
    _ = NSApplication.shared
    let sv = StackView(frame: NSRect(x: 0, y: 0, width: 232, height: 200))
    sv.primary.cfg = loadFrames(); sv.primary.sprite = loadActiveSprite()
    sv.primary.caption = "Validate race prediction methodology"
    sv.primary.setState("waiting")
    sv.primary.detail = "permission: run Bash"     // why it needs you (from the Notification hook)
    sv.primary.elapsedText = "2m"                   // time-in-state
    sv.primary.ctxProgress = 0.42                   // context gauge on the pill border
    sv.primary.hovering = true                  // show the pill in the static preview
    sv.selectedID = "sel"
    sv.items = [
        SessionItem(id: "sel", state: "waiting", label: "Validate race prediction", detail: "run Bash"),
        SessionItem(id: "a", state: "running", label: "api-service", detail: "editing app.ts"),
        SessionItem(id: "b", state: "review", label: "Refactor architecture", detail: nil),
        SessionItem(id: "c", state: "failed", label: "data-pipeline", detail: "rate limited"),
        SessionItem(id: "d", state: "idle", label: "docs-site", detail: nil),
    ]
    sv.listExpanded = ProcessInfo.processInfo.environment["CLAUDEPET_EXPAND"] != nil   // QA preview
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
    let env = ProcessInfo.processInfo.environment
    if let t = env["CLAUDEPET_THEME"] { Theme.current = Palette.byID(t) }   // QA preview only
    v.caption = env["CLAUDEPET_CAPTION"]   // QA preview only
    v.detail  = env["CLAUDEPET_DETAIL"]
    v.elapsedText = env["CLAUDEPET_ELAPSED"]
    v.ctxProgress = env["CLAUDEPET_CTXFRAC"].flatMap { Double($0) }
    if env["CLAUDEPET_DETAIL"] != nil || env["CLAUDEPET_REVEAL"] != nil { v.hovering = true }
    v.setState(state)
    let frames = env["CLAUDEPET_ADVANCE"].flatMap { Int($0) } ?? 8   // QA: crank to reach the sleep state
    for _ in 0..<frames { v.advance() }                      // settle into a representative frame
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
