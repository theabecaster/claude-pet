import Foundation

// MARK: - Humanizers for the data Claude Code exposes

// Map a tool name (from Pre/PostToolUse hooks) to a short, human verb for the pill.
func toolVerb(_ tool: String) -> String {
    switch tool {
    case "Edit", "MultiEdit", "Write", "NotebookEdit": return "editing"
    case "Read", "NotebookRead":                        return "reading"
    case "Bash", "BashOutput", "KillShell":             return "running"
    case "Grep", "Glob", "LS":                          return "searching"
    case "WebFetch", "WebSearch":                       return "browsing"
    case "Task", "Agent":                               return "delegating"
    case "TodoWrite":                                   return "planning"
    default:
        if tool.hasPrefix("mcp__") { return "calling tool" }
        return tool.isEmpty ? "working" : tool.lowercased()
    }
}

// Map a StopFailure `error_type` to a short, human reason for the pill.
func errorReason(_ type: String) -> String {
    switch type {
    case "rate_limit":            return "rate limited"
    case "overloaded":            return "overloaded"
    case "authentication_failed": return "auth failed"
    case "oauth_org_not_allowed": return "org blocked"
    case "billing_error":         return "billing issue"
    case "invalid_request":       return "bad request"
    case "model_not_found":       return "model missing"
    case "max_output_tokens":     return "output limit"
    case "server_error":          return "server error"
    default:                      return "error"
    }
}

// Short model label from a full model id (claude-opus-4-8 -> "opus 4.8").
func shortModel(_ id: String) -> String {
    let lower = id.lowercased()
    let family = ["opus", "sonnet", "haiku", "fable"].first { lower.contains($0) }
    guard let fam = family else { return id }
    // Pull the version digits that follow the family name, e.g. "...opus-4-8..." -> "4.8".
    if let r = lower.range(of: fam) {
        let tail = lower[r.upperBound...]
        let nums = tail.split(whereSeparator: { !$0.isNumber }).prefix(2).map(String.init)
        if !nums.isEmpty { return fam + " " + nums.joined(separator: ".") }
    }
    return fam
}

// Compact a token count: 1234 -> "1.2k", 45000 -> "45k", 1200000 -> "1.2M".
func compactTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 10_000 { return "\(n / 1000)k" }
    if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1000) }
    return "\(n)"
}

// Compact elapsed duration: "8s", "5m", "2h", "1d".
func compactElapsed(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

// Public Anthropic per-MTok prices by model family (input, output, cache-read,
// cache-write). A rough estimate, clearly labeled as such where shown.
func modelPrices(_ model: String?) -> (inp: Double, out: Double, cr: Double, cw: Double) {
    let m = (model ?? "").lowercased()
    if m.contains("opus")  { return (15, 75, 1.5, 18.75) }
    if m.contains("haiku") { return (0.8, 4, 0.08, 1.0) }
    return (3, 15, 0.30, 3.75)   // sonnet / fable / unknown
}

// Compact a dollar estimate: "<$0.01", "$0.42", "$12".
func compactUSD(_ v: Double) -> String {
    if v < 0.01 { return "<$0.01" }
    if v < 10 { return String(format: "$%.2f", v) }
    return String(format: "$%.0f", v)
}
