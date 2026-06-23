import Foundation
import Darwin

// MARK: - GUI process lifecycle (singleton lock + auto-launch)

var singletonLockFD: Int32 = -1
func acquireSingletonOrExit() {
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    let lockPath = stateDir.appendingPathComponent("pet.lock").path
    singletonLockFD = open(lockPath, O_CREAT | O_RDWR, 0o644)
    if singletonLockFD >= 0, flock(singletonLockFD, LOCK_EX | LOCK_NB) != 0 { exit(0) }
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
    t.standardInput = FileHandle.nullDevice
    t.standardOutput = FileHandle.nullDevice
    t.standardError = FileHandle.nullDevice
    try? t.run()
}
