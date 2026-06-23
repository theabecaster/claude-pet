import Foundation

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
let prefsURL = stateDir.appendingPathComponent("prefs.json")     // persisted user preferences
func sessionFile(_ id: String) -> URL { sessionsDir.appendingPathComponent(id + ".json") }
let SESSION_STALE_SECONDS: TimeInterval = 12 * 3600
let RENUDGE_SECONDS: TimeInterval = 90    // re-chime interval while a session keeps waiting
// Active sprite sheet — Codex pets ship a WebP, so .webp is preferred.
let activeNames = ["active.webp", "active.png"]
