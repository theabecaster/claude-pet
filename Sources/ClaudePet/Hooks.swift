import Foundation
import Darwin

// MARK: - Hook wiring (Claude Code session state -> animation)

let HOOK_WIRING: [(event: String, state: String, matcher: Bool)] = [
    ("SessionStart",     "waving",        false),
    ("UserPromptSubmit", "running-right", false),
    ("PreToolUse",       "running",       true),
    ("PostToolUse",      "running-left",  true),
    ("Notification",     "waiting",       false),
    ("PermissionRequest","waiting",       false),
    ("PreCompact",       "running",       false),
    ("Stop",             "jumping",       false),
    ("StopFailure",      "failed",        false),
    ("SessionEnd",       "off",           false),
]

// MARK: - CLI helpers (no GUI)

func selfExecPath() -> String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

// Claude Code delivers event JSON on stdin; readHookInput() folds it into this.
// (The non-blocking read itself lives in readStdinData(), below.)
struct HookInput {
    var session = "default"
    var cwd: String?
    var transcript: String?
    var source: String?           // SessionStart: "startup"|"resume"|"clear"|"compact"
    var event: String?            // hook_event_name
    var toolName: String?         // Pre/PostToolUse
    var toolInput: [String: Any]? // Pre/PostToolUse (tool args: file_path, command, …)
    var message: String?          // Notification
    var errorType: String?        // StopFailure
    var permissionMode: String?   // "default"|"plan"|"acceptEdits"|"bypassPermissions"
    var trigger: String?          // PreCompact: "manual"|"auto"
}
// Drain stdin without ever blocking the session: every read is gated by poll with a
// hard time cap, so a hook OR statusline can never hang (e.g. if the writer keeps the
// pipe open). Shared by readHookInput() and statusLine() — keep the guard in one place.
func readStdinData(maxBytes: Int = 1 << 20) -> Data {
    let fd: Int32 = 0
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while data.count < maxBytes {
        var fds = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let r = poll(&fds, 1, data.isEmpty ? 50 : 0)
        if r <= 0 { break }
        if (fds.revents & Int16(POLLIN)) == 0 { break }
        let n = read(fd, &buf, buf.count)
        if n > 0 { data.append(buf, count: n) } else { break }
    }
    return data
}
func readHookInput() -> HookInput {
    var info = HookInput()
    let data = readStdinData()
    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let s = obj["session_id"] as? String, !s.isEmpty { info.session = s }
        info.cwd = obj["cwd"] as? String
        info.transcript = obj["transcript_path"] as? String
        info.source = obj["source"] as? String
        info.event = obj["hook_event_name"] as? String
        info.toolName = obj["tool_name"] as? String
        info.toolInput = obj["tool_input"] as? [String: Any]
        info.message = obj["message"] as? String
        info.errorType = obj["error_type"] as? String
        info.permissionMode = obj["permission_mode"] as? String
        info.trigger = obj["trigger"] as? String
    }
    return info
}

// The specific target of a tool call, from `tool_input`, so the pill can say
// "editing main.swift" / "running npm test" / "searching \"TODO\"" — not just the
// verb. Kept short; the pill truncates anything long.
func toolTarget(_ tool: String, _ input: [String: Any]?) -> String? {
    guard let input = input else { return nil }
    func str(_ k: String) -> String? { (input[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    switch tool {
    case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit", "NotebookRead":
        return str("file_path").map { URL(fileURLWithPath: $0).lastPathComponent }
    case "Bash", "BashOutput":
        // First "word" of the command (the program being run) is the useful glance.
        return str("command").map { String($0.split(whereSeparator: { $0 == " " || $0 == "\n" }).first ?? "") }
    case "Grep", "Glob":
        return str("pattern").map { "\"\($0)\"" }
    case "WebFetch":
        return str("url").flatMap { URL(string: $0)?.host }
    case "WebSearch":
        return str("query").map { "\"\($0)\"" }
    case "Task", "Agent":
        return str("subagent_type") ?? str("description")
    default:
        return nil
    }
}

// Humanize a permission mode into a short badge (nil for the normal "default" mode).
func modeBadge(_ mode: String?) -> String? {
    switch mode {
    case "plan":              return "plan"
    case "acceptEdits":       return "auto-edits"
    case "bypassPermissions": return "bypass"
    default:                  return nil
    }
}

// Pick a short, human "detail" string for a state from the hook payload, so the pet's
// pill can say *what* it's doing / *why* it needs you — not just the bare state.
func detailFor(state: String, _ info: HookInput) -> String? {
    if info.event == "PreCompact" {                 // context being summarized to free room
        return info.trigger == "manual" ? "compacting context" : "auto-compacting"
    }
    switch state {
    case "running", "running-left", "running-right":
        guard let t = info.toolName, !t.isEmpty else { return nil }   // e.g. UserPromptSubmit has none
        let verb = toolVerb(t)
        if let target = toolTarget(t, info.toolInput) { return verb + " " + target }
        return verb
    case "waiting":
        if let m = info.message, !m.isEmpty { return m }
        return nil
    case "failed":
        if let e = info.errorType, !e.isEmpty { return errorReason(e) }
        return nil
    default:
        return nil
    }
}

func writeState(_ state: String) {
    try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    let info = readHookInput()
    let file = sessionFile(info.session)
    if state == "off" { try? FileManager.default.removeItem(at: file); return }
    var obj: [String: Any] = ["state": state]
    if let c = info.cwd { obj["cwd"] = c }
    if let t = info.transcript { obj["transcript"] = t }
    if let d = detailFor(state: state, info) { obj["detail"] = d }   // what it's doing / why it needs you
    if let m = info.permissionMode, m != "default", !m.isEmpty { obj["mode"] = m }   // plan / auto-edits / bypass
    // A `/clear` reuses the session_id but starts a fresh conversation; sticky
    // once set so later state writes (running, waiting…) don't drop it. The flag
    // dies with the session file on SessionEnd ("off").
    let wasCleared = (try? Data(contentsOf: file))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["cleared"] as? Bool ?? false
    if info.source == "clear" || wasCleared { obj["cleared"] = true }
    if let data = try? JSONSerialization.data(withJSONObject: obj) { try? data.write(to: file) }
}

// Claude Code hands the TRUE context-window usage (the right 200k-vs-1M denominator,
// already reduced to a percentage) only to the statusLine command — never to hooks.
// So we register a tiny statusLine that relays that percentage to the bridge file
// bridgeContextUsed() reads, giving the pet's gauge an EXACT fill instead of the
// token-count estimate. Registering it also makes this our user's statusline, so we
// print a short, useful line too. Runs synchronously inside Claude Code like a hook,
// so it uses the same non-blocking stdin read and never touches the network.
func statusLine() {
    let data = readStdinData()
    guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    let session = (o["session_id"] as? String) ?? ""
    let ctx = o["context_window"] as? [String: Any]

    // Prefer CC's pre-computed percentage; fall back to computing it from the
    // per-component usage + window size when it isn't populated yet (early/after
    // /compact). Input-only, matching how CC's own /context measures the window.
    var usedPct = (ctx?["used_percentage"] as? Double) ?? (ctx?["used_percentage"] as? Int).map(Double.init)
    if usedPct == nil, let ctx = ctx,
       let size = ctx["context_window_size"] as? Int, size > 0,
       let cur = ctx["current_usage"] as? [String: Any] {
        let inp = (cur["input_tokens"] as? Int) ?? 0
        let cc  = (cur["cache_creation_input_tokens"] as? Int) ?? 0
        let cr  = (cur["cache_read_input_tokens"] as? Int) ?? 0
        usedPct = Double(inp + cc + cr) / Double(size) * 100
    }

    // Relay to the bridge file the gauge reads (same path/shape as bridgeContextUsed()).
    if let pct = usedPct, !session.isEmpty, !session.contains("/"), !session.contains("..") {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("claude-ctx-\(session).json")
        let payload: [String: Any] = ["used_pct": pct, "timestamp": Date().timeIntervalSince1970]
        if let d = try? JSONSerialization.data(withJSONObject: payload) { try? d.write(to: URL(fileURLWithPath: path)) }
    }

    // Print a compact line — this IS the user's statusline now, so make it worth showing.
    var bits: [String] = []
    if let dir = (o["workspace"] as? [String: Any])?["current_dir"] as? String ?? o["cwd"] as? String {
        bits.append(URL(fileURLWithPath: dir).lastPathComponent)
    }
    if let m = (o["model"] as? [String: Any])?["display_name"] as? String, !m.isEmpty { bits.append(m) }
    if let pct = usedPct { bits.append("\(Int(pct.rounded()))% ctx") }
    print("🐾 " + bits.joined(separator: "  ·  "))
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
    // statusLine is a SINGLE slot (unlike the hooks list), so only claim it when the
    // user has none — never clobber their own. This wins the EXACT context gauge out of
    // the box; users with their own statusline keep it and fall back to the estimate.
    installStatusLineInto(&root, exe: exe)
    if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
        try? out.write(to: settingsURL)
        print("🐾 Claude Pet hooks installed (\(HOOK_WIRING.count) events) → \(settingsURL.path)")
    }
}

// Add/refresh our statusLine in an already-loaded settings dict, but only if the slot
// is empty or already ours. Returns true if we (re)claimed it. Mutating-in-place lets
// installHooks() write once; the GUI self-heal path uses installStatusLine() below.
@discardableResult
func installStatusLineInto(_ root: inout [String: Any], exe: String) -> Bool {
    if let existing = root["statusLine"] as? [String: Any],
       (existing["command"] as? String)?.contains("--statusline") != true {
        return false   // user has their own statusline — leave it untouched
    }
    root["statusLine"] = ["type": "command", "command": "\"\(exe)\" --statusline", "padding": 0]
    return true
}

// Standalone (re)install — reads settings, claims the statusLine if free/ours, writes back.
func installStatusLine() {
    let exe = selfExecPath()
    try? FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var root: [String: Any] = [:]
    if let d = try? Data(contentsOf: settingsURL),
       let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { root = o }
    guard installStatusLineInto(&root, exe: exe) else { return }
    if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
        try? out.write(to: settingsURL)
    }
}

// True only when settings.json's statusLine is OUR command pointing at this binary.
func statusLinePointsToSelf() -> Bool {
    guard let d = try? Data(contentsOf: settingsURL),
          let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let sl = root["statusLine"] as? [String: Any],
          let cmd = sl["command"] as? String else { return false }
    return cmd.contains("--statusline") && cmd.contains(selfExecPath())
}

// Human-readable statusLine state for --status: ours → exact gauge; user's own or
// none → the token-count estimate.
func statusLineState() -> String {
    if statusLinePointsToSelf() { return "ours (exact context gauge)" }
    if let d = try? Data(contentsOf: settingsURL),
       let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
       root["statusLine"] != nil { return "user's own — gauge uses estimate" }
    return "none — gauge uses estimate"
}

// Remove the statusLine only if it's ours (never touch a user's own statusline).
func uninstallStatusLine() {
    guard let d = try? Data(contentsOf: settingsURL),
          var root = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
    guard let sl = root["statusLine"] as? [String: Any],
          (sl["command"] as? String)?.contains("--statusline") == true else { return }
    root.removeValue(forKey: "statusLine")
    if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
        try? out.write(to: settingsURL)
    }
}

// True only when settings.json already has a Claude Pet --state hook whose command
// points at THIS running binary. Used by the GUI to self-wire on first launch and
// self-heal if the app was moved (the hook stores an absolute exe path). This makes
// the notarized .app a complete installer, so the download flow never depends on a
// quarantine-gated .command script.
func hooksPointToSelf() -> Bool {
    guard let d = try? Data(contentsOf: settingsURL),
          let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let hooks = root["hooks"] as? [String: Any] else { return false }
    let exe = selfExecPath()
    for (_, v) in hooks {
        for g in (v as? [[String: Any]]) ?? [] {
            for c in (g["hooks"] as? [[String: Any]]) ?? [] {
                if let cmd = c["command"] as? String, cmd.contains("--state"), cmd.contains(exe) { return true }
            }
        }
    }
    return false
}

func uninstallHooks() {
    uninstallStatusLine()   // drop our statusLine too (no-op if it's the user's own)
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
