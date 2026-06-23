import AppKit
import Foundation

// MARK: - Entry point
//
// Dual-mode, dispatched by argv[1]:
// - CLI mode (--state, --install-hooks, --statusline, --render*, --selftest, --status, …):
//   does its work and exit(0).
// - GUI mode (no args): singleton flock, runs the NSApplication overlay.
// Everything else lives in the sibling files of this SwiftPM target (one module).

let args = CommandLine.arguments
if args.count >= 2 {
    switch args[1] {
    case "--state":
        writeState(args.count >= 3 ? args[2] : "idle"); ensureRunning(); exit(0)
    case "--install-hooks":   installHooks(); exit(0)
    case "--uninstall-hooks": uninstallHooks(); exit(0)
    case "--statusline":      statusLine(); exit(0)
    case "--render":
        renderState(args.count >= 3 ? args[2] : "running", to: args.count >= 4 ? args[3] : "/tmp/pet.png"); exit(0)
    case "--make-icon":
        renderIcon(to: args.count >= 3 ? args[2] : "/tmp/AppIcon.png"); exit(0)
    case "--render-stack":
        renderStack(to: args.count >= 3 ? args[2] : "/tmp/stack.png"); exit(0)
    case "--render-menubar":
        renderMenuBar(to: args.count >= 3 ? args[2] : "/tmp/menubar.png"); exit(0)
    case "--selftest":
        exit(selfTest() ? 0 : 1)
    case "--status":
        statusReport(); exit(0)
    case "--aititle":
        print(readAITitle(args.count >= 3 ? args[2] : "") ?? "(no title)"); exit(0)
    case "--meta":
        let m = readTranscriptMeta(args.count >= 3 ? args[2] : "")
        print("title:  \(m.title ?? "-")")
        print("model:  \(m.model.map(shortModel) ?? "-")  (\(m.model ?? "-"))")
        print("ctx:    \(m.ctxTokens.map(compactTokens) ?? "-")  (\(m.ctxTokens.map(String.init) ?? "-") tokens)")
        print("branch: \(m.branch ?? "-")")
        exit(0)
    default: break
    }
}

acquireSingletonOrExit()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
