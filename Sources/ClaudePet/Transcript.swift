import Foundation
import Darwin

// MARK: - Context window inference + transcript reading

// The context window for a session. Claude Code runs either the standard 200k window
// or the 1M beta, depending on the model/session — and the transcript doesn't state
// which. Infer it: once usage passes 200k it must be a 1M session; otherwise assume
// 200k (the common case). Callers make this sticky per session so it can't flip back.
func contextLimitFor(tokens: Int) -> Int { tokens > 200_000 ? 1_000_000 : 200_000 }

// EXACT context usage, when available. Claude Code only hands the true context-window
// size (200k vs the 1M beta) to its *statusline* command, not to hooks. Some statuslines
// (e.g. GSD's) relay it to a bridge file at $TMPDIR/claude-ctx-<session>.json as
// `used_pct` (= 100 − remaining_percentage, matching CC's own /context). If that file
// exists and is fresh, we use it — automatically correct for 200k or 1M. Otherwise the
// caller falls back to the token-count heuristic.
func bridgeContextUsed(_ session: String) -> Double? {
    guard !session.isEmpty, !session.contains("/"), !session.contains("..") else { return nil }
    var dirs = [NSTemporaryDirectory()]
    var buf = [CChar](repeating: 0, count: 1024)
    if confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count) > 0 { dirs.append(String(cString: buf)) }
    dirs.append("/tmp")
    for dir in dirs {
        let p = (dir as NSString).appendingPathComponent("claude-ctx-\(session).json")
        guard let data = FileManager.default.contents(atPath: p),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        if let ts = o["timestamp"] as? Double, Date().timeIntervalSince1970 - ts > 3600 { continue }  // stale
        let used = (o["used_pct"] as? Double) ?? (o["used_pct"] as? Int).map(Double.init)
        if let u = used { return max(0, min(1, u / 100)) }
    }
    return nil
}

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
    return readTranscriptMeta(path, ignoreCustom: ignoreCustom).title
}

// Everything we surface about a session from its transcript, in ONE tail scan:
// the display title, the latest model, the current context size (tokens), and the
// git branch. All optional — a fresh/empty transcript just yields nils.
struct SessionMeta { var title: String?; var model: String?; var ctxTokens: Int?; var branch: String? }

// Read the session's metadata from the tail of its transcript (JSONL). Titles come
// from "ai-title" (auto) / "custom-title" (manual rename) records — a manual rename
// wins, and for each kind the latest near the end wins (see `ignoreCustom` for the
// /clear behavior). Model + context tokens come from the latest complete "assistant"
// record's `message.model` / `message.usage`; the branch from the latest record that
// carries `gitBranch`. Only the file tail is scanned so this stays cheap on large
// transcripts; a response longer than the window just leaves model/ctx one turn stale.
func readTranscriptMeta(_ path: String, ignoreCustom: Bool = false) -> SessionMeta {
    var meta = SessionMeta()
    guard let fh = FileHandle(forReadingAtPath: path) else { return meta }
    defer { try? fh.close() }
    let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
    let chunk = 131072
    let seeked = size > chunk
    if seeked { try? fh.seek(toOffset: UInt64(size - chunk)) }
    guard let data = try? fh.readToEnd(), let text = String(data: data, encoding: .utf8) else { return meta }
    var aiTitle: String?, customTitle: String?
    var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    if seeked && !lines.isEmpty { lines.removeFirst() }   // drop the partial first line
    for line in lines {
        // Title records are tiny and matched cheaply by substring first.
        if line.contains("\"type\":\"ai-title\"") || line.contains("\"type\":\"custom-title\"") {
            if let d = line.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                if let t = o["customTitle"] as? String, !t.isEmpty { customTitle = t }
                else if let t = o["aiTitle"] as? String, !t.isEmpty { aiTitle = t }
            }
            continue
        }
        // Branch is cheap to pluck from any record that carries it.
        if meta.branch == nil || line.contains("\"gitBranch\"") {
            if let d = line.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let b = o["gitBranch"] as? String, !b.isEmpty { meta.branch = b }
        }
        // Model + context size from the latest parseable assistant record.
        if line.contains("\"type\":\"assistant\"") {
            if let d = line.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let m = o["message"] as? [String: Any] {
                if let model = m["model"] as? String, !model.isEmpty { meta.model = model }
                if let u = m["usage"] as? [String: Any] {
                    let inp = (u["input_tokens"] as? Int) ?? 0
                    let cr  = (u["cache_read_input_tokens"] as? Int) ?? 0
                    let cc  = (u["cache_creation_input_tokens"] as? Int) ?? 0
                    let total = inp + cr + cc
                    if total > 0 { meta.ctxTokens = total }
                }
            }
        }
    }
    meta.title = ignoreCustom ? aiTitle : (customTitle ?? aiTitle)
    return meta
}

// Cumulative session totals from a FULL transcript scan: turns, token sums, an
// estimated cost, and the active span (first→last record timestamp). Heavier than
// the tail scan, so callers cache it by mtime and only read on demand (status / menu).
struct SessionTotals {
    var turns = 0
    var inputTokens = 0, outputTokens = 0, cacheReadTokens = 0, cacheWriteTokens = 0
    var costUSD: Double = 0
    var firstTS: Date?, lastTS: Date?
    var duration: TimeInterval? {
        guard let f = firstTS, let l = lastTS, l >= f else { return nil }
        return l.timeIntervalSince(f)
    }
}

func readTranscriptTotals(_ path: String) -> SessionTotals {
    var t = SessionTotals()
    guard let data = FileManager.default.contents(atPath: path),
          let text = String(data: data, encoding: .utf8) else { return t }
    let isoFrac = ISO8601DateFormatter(); isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let isoPlain = ISO8601DateFormatter(); isoPlain.formatOptions = [.withInternetDateTime]
    func parseTS(_ s: String) -> Date? { isoFrac.date(from: s) ?? isoPlain.date(from: s) }
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let d = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
        if let ts = o["timestamp"] as? String, let date = parseTS(ts) {
            if t.firstTS == nil { t.firstTS = date }
            t.lastTS = date
        }
        guard (o["type"] as? String) == "assistant", let m = o["message"] as? [String: Any],
              let u = m["usage"] as? [String: Any] else { continue }
        let inp = (u["input_tokens"] as? Int) ?? 0, out = (u["output_tokens"] as? Int) ?? 0
        let cr = (u["cache_read_input_tokens"] as? Int) ?? 0, cc = (u["cache_creation_input_tokens"] as? Int) ?? 0
        if inp + out + cr + cc == 0 { continue }
        t.turns += 1
        t.inputTokens += inp; t.outputTokens += out; t.cacheReadTokens += cr; t.cacheWriteTokens += cc
        let p = modelPrices(m["model"] as? String)
        t.costUSD += (Double(inp) * p.inp + Double(out) * p.out + Double(cr) * p.cr + Double(cc) * p.cw) / 1_000_000
    }
    return t
}
