import AppKit
import Foundation

// MARK: - In-app updater
//
// Each GitHub Release ships the notarized app inside `ClaudePet-macos.zip`. This
// reads that release feed, compares the tag to our bundle version, and — when a
// newer one exists — downloads it, verifies the code signature, and swaps the
// running bundle in place via a small detached helper that waits for us to exit.
//
// Pure Foundation: no Sparkle, no runtime deps, in keeping with the single-binary
// design. When an in-place swap can't be trusted (a translocated/quarantined run,
// an unwritable location, or a signature that won't verify) it falls back to just
// opening the Releases page so the user can drag the new app in by hand.

let GITHUB_REPO = "theabecaster/claude-pet"
let UPDATE_ASSET = "ClaudePet-macos.zip"
let releasesPageURL = URL(string: "https://github.com/\(GITHUB_REPO)/releases/latest")!
private let lastUpdateCheckURL = stateDir.appendingPathComponent("last-update-check")
private let autoCheckInterval: TimeInterval = 24 * 3600   // throttle the silent launch check

// MARK: Version comparison

// Parse "v1.2.3" / "1.2.3" / "1.2.3-beta" -> [1, 2, 3]; missing parts read as 0.
func semverParts(_ s: String) -> [Int] {
    let core = s.trimmingCharacters(in: CharacterSet(charactersIn: "v "))
        .split(separator: "-").first.map(String.init) ?? ""
    return core.split(separator: ".").map { Int($0) ?? 0 }
}
// True when `a` is strictly older than `b` (component-wise).
func semverLess(_ a: String, _ b: String) -> Bool {
    let pa = semverParts(a), pb = semverParts(b)
    for i in 0..<max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0
        let y = i < pb.count ? pb[i] : 0
        if x != y { return x < y }
    }
    return false
}

func currentVersion() -> String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
}

// MARK: Release feed

struct LatestRelease { let tag: String; let notes: String; let zipURL: URL }

// Synchronous GET with a hard timeout. Always call off the main thread.
private func httpGet(_ url: URL, timeout: TimeInterval) -> Data? {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = timeout
    cfg.timeoutIntervalForResource = timeout
    let session = URLSession(configuration: cfg)
    defer { session.invalidateAndCancel() }
    var req = URLRequest(url: url)
    req.setValue("ClaudePet", forHTTPHeaderField: "User-Agent")
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    var out: Data?
    let sem = DispatchSemaphore(value: 0)
    session.dataTask(with: req) { data, resp, _ in
        if let http = resp as? HTTPURLResponse, http.statusCode == 200 { out = data }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 2)
    return out
}

func fetchLatestRelease() -> LatestRelease? {
    let api = URL(string: "https://api.github.com/repos/\(GITHUB_REPO)/releases/latest")!
    guard let data = httpGet(api, timeout: 15),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tag = obj["tag_name"] as? String,
          let assets = obj["assets"] as? [[String: Any]],
          let asset = assets.first(where: { ($0["name"] as? String) == UPDATE_ASSET }),
          let urlStr = asset["browser_download_url"] as? String,
          let url = URL(string: urlStr) else { return nil }
    return LatestRelease(tag: tag, notes: (obj["body"] as? String) ?? "", zipURL: url)
}

// MARK: Apply

// The writable, non-translocated `.app` we can replace in place, or nil when an
// in-place swap can't be trusted (dev binary, read-only translocation mount, or a
// parent directory we can't write to).
func updatableBundlePath() -> String? {
    let bundle = Bundle.main.bundleURL
    let path = bundle.path
    guard path.hasSuffix(".app") else { return nil }              // running the bare CLI binary
    if path.contains("/AppTranslocation/") { return nil }         // randomized read-only mount
    let parent = bundle.deletingLastPathComponent().path
    guard FileManager.default.isWritableFile(atPath: parent) else { return nil }
    return path
}

enum UpdateApplyResult { case relaunching; case failed(String) }

// Run a tool to completion, returning its exit status (-1 if it couldn't launch).
@discardableResult
private func runTool(_ launchPath: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

// Download the release zip, verify it, and stage a detached helper that swaps the
// bundle once we exit. On `.relaunching` the caller should terminate the app; the
// helper waits for the PID to drop, replaces `dest`, strips quarantine, relaunches.
func downloadAndStage(_ release: LatestRelease, into dest: String) -> UpdateApplyResult {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("claudepet-update-\(getpid())")
    try? fm.removeItem(at: tmp)
    do { try fm.createDirectory(at: tmp, withIntermediateDirectories: true) }
    catch { return .failed("couldn’t create a temporary folder") }

    let zipPath = tmp.appendingPathComponent(UPDATE_ASSET)
    guard let zipData = httpGet(release.zipURL, timeout: 120) else { return .failed("download failed") }
    do { try zipData.write(to: zipPath) } catch { return .failed("couldn’t save the download") }

    // Extract with ditto (preserves the notarized bundle layout the zip carries).
    if runTool("/usr/bin/ditto", ["-x", "-k", zipPath.path, tmp.path]) != 0 {
        return .failed("couldn’t unpack the download")
    }
    let newApp = tmp.appendingPathComponent("ClaudePet.app")
    guard fm.fileExists(atPath: newApp.path) else { return .failed("the download was incomplete") }

    // Integrity gate: refuse anything whose signature seal won't verify.
    if runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]) != 0 {
        return .failed("the download failed signature verification")
    }

    // The helper outlives us: it waits for our PID to exit before touching the live
    // bundle, so the swap happens when nothing holds the old app open. The swap is
    // staged + atomic with rollback — a failed copy or move never leaves the user
    // without a working app, which they'd have no easy way to recover from.
    let script = """
    #!/bin/sh
    while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
    DEST="\(dest)"
    STAGED="$DEST.new-$$"
    BACKUP="$DEST.old-$$"
    /usr/bin/ditto "\(newApp.path)" "$STAGED" || { /bin/rm -rf "$STAGED"; /usr/bin/open "$DEST"; exit 1; }
    /bin/mv "$DEST" "$BACKUP" || { /bin/rm -rf "$STAGED"; /usr/bin/open "$DEST"; exit 1; }
    /bin/mv "$STAGED" "$DEST" || { /bin/mv "$BACKUP" "$DEST"; /usr/bin/open "$DEST"; exit 1; }
    /bin/rm -rf "$BACKUP"
    /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
    /bin/rm -rf "\(tmp.path)"
    /usr/bin/open "$DEST"
    """
    let scriptURL = tmp.appendingPathComponent("apply.sh")
    do { try script.write(to: scriptURL, atomically: true, encoding: .utf8) }
    catch { return .failed("couldn’t stage the installer") }

    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: "/bin/sh")
    helper.arguments = [scriptURL.path]
    helper.standardInput = FileHandle.nullDevice
    helper.standardOutput = FileHandle.nullDevice
    helper.standardError = FileHandle.nullDevice
    do { try helper.run() } catch { return .failed("couldn’t launch the installer") }
    return .relaunching
}

// MARK: Launch-check throttle

// True at most once per `autoCheckInterval`; records the attempt so the silent
// launch check doesn't hit the network on every restart.
func shouldAutoCheckNow() -> Bool {
    let fm = FileManager.default
    if let attrs = try? fm.attributesOfItem(atPath: lastUpdateCheckURL.path),
       let mtime = attrs[.modificationDate] as? Date,
       Date().timeIntervalSince(mtime) < autoCheckInterval { return false }
    try? Data().write(to: lastUpdateCheckURL)
    return true
}
