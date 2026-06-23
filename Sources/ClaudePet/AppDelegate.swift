import AppKit
import Foundation
import Carbon.HIToolbox
import UniformTypeIdentifiers

// MARK: - App (single stacked overlay)

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var window: NSWindow!
    var stack: StackView!
    var statusItem: NSStatusItem!
    var hidden = false
    var order: [String] = []               // stable display order of session ids
    var selectedID: String?
    var appliedKey = ""
    var menuIconKey = ""
    var metaCache: [String: (mtime: Date?, meta: SessionMeta)] = [:]
    var prefs = Prefs()
    var prevStates: [String: String] = [:]   // last-seen state per session (for transition alerts)
    var lastNudge: [String: Date] = [:]       // last re-nudge time per session
    var ctxLimit: [String: Int] = [:]         // inferred context window per session (sticky)
    var stateSince: [String: Date] = [:]      // when each session entered its current state
    var didInitialSync = false                // suppress alerts for sessions present at launch

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarIcon("idle")
        let menu = NSMenu()
        menu.delegate = self            // repopulated on open so the session list is always live
        statusItem.menu = menu
        populate(menu)
    }

    // NSMenuDelegate: refresh the (live) session list + checkmarks right before the
    // menu opens, so the dropdown is a usable status panel even with the overlay hidden.
    func menuNeedsUpdate(_ menu: NSMenu) { populate(menu) }

    // Kept for the toggle paths; repopulating the existing menu object in place keeps
    // checkmarks/theme dots in sync with `prefs` without juggling item references.
    func rebuildMenu() { if let m = statusItem?.menu { populate(m) } }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Live sessions: pick any to make it the big pet; shows state + what it's doing.
        if let items = stack?.items, !items.isEmpty {
            let header = NSMenuItem(title: items.count == 1 ? "Session" : "Sessions (\(items.count))", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for it in items {
                var title = it.label
                if let d = it.detail, !d.isEmpty { title += " — " + d } else { title += " — " + shortStatus(it.state) }
                if let age = sessionAge(it.id) { title += "  ·  up " + age }
                let mi = NSMenuItem(title: title, action: #selector(selectSession(_:)), keyEquivalent: "")
                mi.representedObject = it.id
                mi.state = (it.id == selectedID) ? .on : .off
                mi.image = menuBarImage(state: it.state, sprite: nil, cfg: Frames())   // tiny state-colored dot-pet
                menu.addItem(mi)
            }
            menu.addItem(.separator())
        }

        menu.addItem(NSMenuItem(title: "Show / Hide  (⌃⌥⌘P)", action: #selector(toggleVisibility), keyEquivalent: "p"))
        menu.addItem(.separator())

        // Theme submenu
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        for p in Palette.all {
            let it = NSMenuItem(title: p.name, action: #selector(pickTheme(_:)), keyEquivalent: "")
            it.representedObject = p.id
            it.state = (prefs.theme == p.id) ? .on : .off
            themeMenu.addItem(it)
        }
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

        // Preference toggles
        func toggle(_ title: String, _ on: Bool, _ sel: Selector) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.state = on ? .on : .off
            return it
        }
        menu.addItem(toggle("Keep Details Open", prefs.pinDetails, #selector(togglePin)))
        menu.addItem(.separator())
        menu.addItem(toggle("Sound on Attention", prefs.soundOnAttention && !prefs.muted, #selector(toggleSound)))
        menu.addItem(toggle("Bounce on Attention", prefs.bounceOnAttention && !prefs.muted, #selector(toggleBounce)))
        menu.addItem(toggle("Re-nudge While Waiting", prefs.renudge, #selector(toggleRenudge)))
        menu.addItem(toggle("Mute All Alerts", prefs.muted, #selector(toggleMuted)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Get Custom Pets (codex-pets.net)…", action: #selector(browseCustomPets), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Load Pet… (Codex .webp or folder)", action: #selector(loadSprite), keyEquivalent: "l"))
        menu.addItem(NSMenuItem(title: "Reset to Default Pet", action: #selector(resetSprite), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Reinstall Claude Code Hooks", action: #selector(reinstallHooks), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Uninstall Claude Pet…", action: #selector(uninstallSelf), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit Claude Pet", action: #selector(quit), keyEquivalent: "q"))
    }

    @objc func selectSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        selectedID = id
        if hidden { hidden = false; window.orderFrontRegardless() }   // bring it back if hidden
        sync()
    }

    private func commitPrefs() { prefs.save(); rebuildMenu() }

    @objc func pickTheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        prefs.theme = id; prefs.applyToGlobals()
        menuIconKey = ""; updateMenuBarIcon(stack?.primary.anim ?? "idle")
        stack?.needsDisplay = true; stack?.primary.needsDisplay = true
        commitPrefs()
    }
    @objc func toggleSound()   { prefs.soundOnAttention.toggle(); commitPrefs() }
    @objc func toggleBounce()  { prefs.bounceOnAttention.toggle(); commitPrefs() }
    @objc func toggleMuted()   { prefs.muted.toggle(); commitPrefs() }
    @objc func toggleRenudge() { prefs.renudge.toggle(); commitPrefs() }
    @objc func togglePin()     { prefs.pinDetails.toggle(); commitPrefs(); sync() }

    // Wall-clock age of a session, from when its state file was first written.
    private func sessionAge(_ id: String) -> String? {
        guard let created = (try? FileManager.default.attributesOfItem(atPath: sessionFile(id).path))?[.creationDate] as? Date
        else { return nil }
        return compactElapsed(Date().timeIntervalSince(created))
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

    // A system-wide hotkey (⌃⌥⌘P) to show/hide the overlay without opening the menu.
    // Carbon's RegisterEventHotKey works for an accessory app and needs no extra
    // entitlements or accessibility permission (unlike a global NSEvent monitor).
    private var hotKeyRef: EventHotKeyRef?
    private func registerHotKey() {
        let mods = UInt32(controlKey | optionKey | cmdKey)
        let keyP = UInt32(kVK_ANSI_P)
        let id = EventHotKeyID(signature: OSType(0x43505054), id: 1)   // 'CPPT'
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.toggleVisibility() }
            return noErr
        }, 1, &spec, nil, nil)
        RegisterEventHotKey(keyP, mods, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
    // Facilitate getting a custom pet: open the gallery, then spell out the two-step
    // flow (download a sheet → Load Pet…) so it's obvious how to apply what you find.
    @objc func browseCustomPets() {
        if let url = URL(string: "https://codex-pets.net") { NSWorkspace.shared.open(url) }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Find a custom pet at codex-pets.net"
        a.informativeText = "Opened the pet gallery in your browser.\n\n1. Download a pet's spritesheet (.webp).\n2. Come back here and choose “Load Pet…” to apply it.\n\nClaude Pet is compatible with any Codex pet sprite."
        a.addButton(withTitle: "Load Pet…")
        a.addButton(withTitle: "Done")
        if a.runModal() == .alertFirstButtonReturn { loadSprite() }
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
    @objc func reinstallHooks() {
        installHooks()
        let a = NSAlert()
        a.messageText = "Claude Code hooks installed"
        a.informativeText = "Wired \(HOOK_WIRING.count) events into ~/.claude/settings.json.\nRestart Claude Code for the pet to react."
        a.addButton(withTitle: "OK")
        a.runModal()
    }
    // Self-uninstall so removal never depends on a quarantine-gated script either:
    // unwire the hooks, delete the app's state, then remove the app bundle and quit.
    @objc func uninstallSelf() {
        let a = NSAlert()
        a.messageText = "Uninstall Claude Pet?"
        a.informativeText = "This removes the Claude Code hooks, this app, and ~/.claude-pet (your saved layout and sprites). Your other Claude Code settings are left untouched."
        a.addButton(withTitle: "Uninstall")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        uninstallHooks()
        try? FileManager.default.removeItem(at: stateDir)
        try? FileManager.default.removeItem(at: Bundle.main.bundleURL)   // best-effort (no-op if translocated)
        NSApp.terminate(nil)
    }
    @objc func quit() { NSApp.terminate(nil) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: petsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try? "\(getpid())".write(to: pidURL, atomically: true, encoding: .utf8)
        // The app is its own installer: wire the Claude Code hooks on first launch
        // (and re-wire if the app was moved, since the hook stores an absolute path).
        // Lets users just open the notarized .app — no quarantine-gated installer script.
        if !hooksPointToSelf() { installHooks() }
        // Claim the statusLine for the exact context gauge — only if free or already
        // ours (installHooks() already tried; this also self-heals a moved app path).
        installStatusLine()
        prefs = Prefs.load(); prefs.applyToGlobals()
        setupMenu()
        registerHotKey()

        stack = StackView(frame: NSRect(x: 0, y: 0, width: 232, height: 200))
        stack.primary.cfg = loadFrames(); stack.primary.sprite = loadActiveSprite()
        stack.onSelect = { [weak self] id in self?.selectedID = id; self?.sync() }
        stack.onReorder = { [weak self] ids in self?.order = ids; self?.sync() }
        stack.onCycle = { [weak self] d in self?.cycleSelection(d) }
        stack.onPetTapped = { [weak self] in self?.stack.primary.poke() }
        stack.onWindowMoved = { [weak self] in
            guard let self = self, self.window != nil else { return }
            self.petAnchorY = self.window.frame.minY + self.stack.margin + self.stack.listOffset()
        }

        window = NSWindow(contentRect: stack.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.contentView = stack
        if let vf = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: vf.maxX - stack.W - 16, y: vf.minY + 28))
        }
        petAnchorY = window.frame.minY + stack.margin       // pin the pet here
        stack.layoutContents()
        loadLayout()
        sync()

        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.stack.primary.advance()
            self.stack.advanceExpand()     // ease the picker's grow/shrink; persists across hide
            self.resizeIfNeeded()          // grow/shrink the panel as details reveal/collapse
        }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.sync() }
    }

    // Keep the window matched to the stack's desired height as the bubble (above) and
    // picker (below) reveal. The pet stays visually put: the bubble grows upward from the
    // current top, while the picker grows downward — we shift the window's bottom by the
    // change in the picker's height so the pet doesn't move.
    // Absolute pet anchor (screen Y of the pet panel's bottom). Keeping it fixed and
    // deriving the window origin from it makes applyWindowFrame() idempotent — the bubble
    // grows up and the picker grows down, but the PET never moves (no drift on repeated
    // calls, unlike an incremental delta). Updated only when the user drags the widget.
    var petAnchorY: CGFloat? = nil
    private func applyWindowFrame() {
        guard window != nil else { return }
        let listOffset = stack.listOffset()
        let h = stack.desiredHeight()
        let anchor = petAnchorY ?? (window.frame.minY + stack.margin)
        petAnchorY = anchor
        var f = window.frame
        f.origin.y = anchor - stack.margin - listOffset      // pet pinned; picker extends downward
        f.size = NSSize(width: stack.W, height: h)
        window.setFrame(f, display: true)
        stack.frame = NSRect(origin: .zero, size: f.size)
        stack.layoutContents()
    }
    private func resizeIfNeeded() {
        guard window != nil, !order.isEmpty, !hidden else { return }
        let desiredY = (petAnchorY ?? (window.frame.minY + stack.margin)) - stack.margin - stack.listOffset()
        if abs(window.frame.height - stack.desiredHeight()) > 0.5 || abs(window.frame.minY - desiredY) > 0.5 {
            applyWindowFrame()
        }
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

    private func sessionMeta(_ id: String, _ st: PetState) -> SessionMeta {
        guard let tp = st.transcript else { return SessionMeta() }
        let m = (try? FileManager.default.attributesOfItem(atPath: tp))?[.modificationDate] as? Date
        if metaCache[id]?.mtime != m { metaCache[id] = (m, readTranscriptMeta(tp, ignoreCustom: st.cleared == true)) }
        return metaCache[id]?.meta ?? SessionMeta()
    }
    private func folderName(_ st: PetState) -> String? { st.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } }
    private func label(_ id: String, _ st: PetState) -> String? { sessionMeta(id, st).title ?? folderName(st) }

    private func isAttentionState(_ s: String) -> Bool { s == "waiting" || s == "failed" || s == "error" }

    // A single session crossing into "needs you" / "failed": optionally chime and
    // bounce the app so you notice even when the overlay is behind other windows.
    // Both are independently toggleable and globally mutable from the menu.
    private var lastAlert = Date(timeIntervalSince1970: 0)
    private func fireAttentionAlert() {
        guard !prefs.muted else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAlert) > 1.0 else { return }   // debounce bursts
        lastAlert = now
        if prefs.soundOnAttention { NSSound(named: "Submarine")?.play() }
        if prefs.bounceOnAttention { NSApp.requestUserAttention(.informationalRequest) }
    }

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
        for id in metaCache.keys where live[id] == nil { metaCache[id] = nil }
        for id in stateSince.keys where live[id] == nil { stateSince[id] = nil }
        for id in prevStates.keys where live[id] == nil { prevStates[id] = nil }
        for id in lastNudge.keys where live[id] == nil { lastNudge[id] = nil }
        for id in ctxLimit.keys where live[id] == nil { ctxLimit[id] = nil }

        // Track time-in-state and fire attention alerts on transitions INTO an
        // attention state (needs you / failed), for any session — not just the
        // selected one. The first sync after launch only records baselines so we
        // don't alert for sessions that were already waiting when the app started.
        // While a session keeps waiting on you, optionally re-nudge on an interval.
        let now = Date()
        for (id, v) in live {
            let s = v.st.state
            if prevStates[id] != s {
                stateSince[id] = now
                lastNudge[id] = nil
                if didInitialSync, isAttentionState(s), !isAttentionState(prevStates[id] ?? "") {
                    fireAttentionAlert(); lastNudge[id] = now
                }
                prevStates[id] = s
            } else if didInitialSync, prefs.renudge, isAttentionState(s) {
                let since = stateSince[id] ?? now
                if now.timeIntervalSince(since) > RENUDGE_SECONDS,
                   now.timeIntervalSince(lastNudge[id] ?? .distantPast) > RENUDGE_SECONDS {
                    lastNudge[id] = now; fireAttentionAlert()
                }
            }
        }
        didInitialSync = true

        // Maintain a STABLE order: keep existing positions, append new sessions
        // (oldest-first), drop ended ones. Never reorder on state change.
        order.removeAll { live[$0] == nil }
        let newIDs = live.keys.filter { !order.contains($0) }.sorted { live[$0]!.mtime < live[$1]!.mtime }
        order.append(contentsOf: newIDs)

        if order.isEmpty { window.orderOut(nil); appliedKey = ""; selectedID = nil; updateMenuBarIcon("idle"); return }
        if selectedID == nil || live[selectedID!] == nil { selectedID = order.first }

        let sel = live[selectedID!]!
        // Don't clobber a live reorder: while a row is being dragged, `items` holds the
        // in-progress order but `order` isn't committed until mouseUp. Rebuilding from
        // `order` here would snap the grabbed row back and leave dragIndex pointing at
        // the wrong item. Resume rebuilding once the drag commits.
        if !stack.isReordering {
            stack.items = order.compactMap { id in live[id].map { SessionItem(id: id, state: $0.st.state, label: label(id, $0.st) ?? String(id.prefix(6)), detail: $0.st.detail) } }
        }
        stack.selectedID = selectedID
        stack.primary.baseState = sel.st.state                 // so a pet-tap reaction settles back here
        stack.primary.detail = sel.st.detail                   // what it's doing / why it needs you
        stack.primary.elapsedText = stateSince[selectedID!].map { compactElapsed(now.timeIntervalSince($0)) }
        // Context gauge on the pill border. Prefer the EXACT usage from the statusline
        // bridge file (correct for 200k or 1M); otherwise infer the window from usage
        // (sticky once it passes 200k → 1M).
        if let exact = bridgeContextUsed(selectedID!) {
            stack.primary.ctxProgress = exact
        } else if let tok = sessionMeta(selectedID!, sel.st).ctxTokens {
            let limit = max(ctxLimit[selectedID!] ?? 0, contextLimitFor(tokens: tok))
            ctxLimit[selectedID!] = limit
            stack.primary.ctxProgress = Double(tok) / Double(limit)
        } else { stack.primary.ctxProgress = nil }
        stack.pinDetails = prefs.pinDetails
        stack.primary.hovering = prefs.pinDetails || stack.petHovered
        let key = selectedID! + "|" + sel.st.state
        if appliedKey != key { appliedKey = key; stack.primary.setState(sel.st.state) }
        updateMenuBarIcon(sel.st.state)

        applyWindowFrame()                     // bubble grows up, picker grows down, pet stays put
        stack.needsDisplay = true
        if !hidden { window.orderFrontRegardless() }
        saveLayoutIfChanged()
    }
}
