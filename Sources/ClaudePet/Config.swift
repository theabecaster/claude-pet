import Foundation

// MARK: - Config

struct Frames: Codable {
    var frameWidth = 192
    var frameHeight = 208
    var scale: Double = 0.42
    var fps: Double = 8
    var animations: [String: [Int]]? = nil
}
func loadFrames() -> Frames {
    if let data = try? Data(contentsOf: framesURL),
       let f = try? JSONDecoder().decode(Frames.self, from: data) { return f }
    return Frames()
}

struct PetState: Codable { var state = "idle"; var cwd: String?; var transcript: String?; var detail: String?; var mode: String?; var cleared: Bool? }

// MARK: - Preferences (persisted to ~/.claude-pet/prefs.json)
//
// Small, additive, and forward-compatible (all optional with defaults), so older
// files keep decoding as new keys are added. Loaded once at launch and after every
// menu toggle; `applyToGlobals()` pushes the theme into `Theme.current`.

struct Prefs: Codable {
    var theme: String = "claude"        // Palette id
    var soundOnAttention: Bool = true   // chime when a session needs you / fails
    var bounceOnAttention: Bool = true  // requestUserAttention (bounce) on the same
    var pinDetails: Bool = false        // keep the status pill open instead of reveal-on-hover
    var muted: Bool = false             // master mute for all attention alerts
    var renudge: Bool = true            // re-chime while a session keeps waiting on you
    var autoCheckUpdates: Bool = true   // silently check GitHub for a newer release on launch

    static func load() -> Prefs {
        if let d = try? Data(contentsOf: prefsURL),
           let p = try? JSONDecoder().decode(Prefs.self, from: d) { return p }
        return Prefs()
    }
    func save() {
        if let d = try? JSONEncoder().encode(self) { try? d.write(to: prefsURL) }
    }
    func applyToGlobals() { Theme.current = Palette.byID(theme) }
}
