import Foundation

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
