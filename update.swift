import Darwin
import Foundation

private let releaseID = "com.humanleap.spacedock"
private let releaseFeed = URL(string: "https://api.github.com/repos/Humanleap/SpaceDock/releases/latest")!
private let updateLabel = "com.humanleap.spacedock.update"
private let maxDownload = 80 * 1024 * 1024

private final class FeedGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(allowedDownload) == true ? request : nil)
    }
}

private let feedSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    config.waitsForConnectivity = false
    return URLSession(configuration: config, delegate: FeedGuard(), delegateQueue: nil)
}()

private struct GitRelease: Decodable {
    let tag_name: String
    let assets: [GitAsset]
}

private struct GitAsset: Decodable {
    let name: String
    let browser_download_url: String
}

func versionParts(_ raw: String) -> [Int] {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.first == "v" || text.first == "V" { text.removeFirst() }
    return text.split(separator: ".").map { Int($0) ?? 0 }
}

func versionIsNewer(_ remote: String, than local: String) -> Bool {
    let left = versionParts(remote)
    let right = versionParts(local)
    for index in 0..<max(left.count, right.count) {
        let a = index < left.count ? left[index] : 0
        let b = index < right.count ? right[index] : 0
        if a != b { return a > b }
    }
    return false
}

func allowedDownload(_ url: URL) -> Bool {
    guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
    if host == "github.com" || host == "api.github.com" || host == "objects.githubusercontent.com" || host == "release-assets.githubusercontent.com" {
        return true
    }
    return host.hasSuffix(".githubusercontent.com")
}

enum Release {
    static func installFromCommandLine() {
        writeAgent()
        _ = launchctl(["bootout", domainLabel(releaseID)])
        let status = launchctl(["bootstrap", domain(), agentPlist().path])
        if status != 0 { log("Could not start SpaceDock.") }
    }

    /// The running copy is busy on disk, so a login job swaps it after this process exits.
    static func stay() -> Bool {
        let here = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        if here != installedApp().resolvingSymlinksInPath().standardizedFileURL.path {
            let team = FileManager.default.fileExists(atPath: installedApp().path) ? teamID(installedApp()) : nil
            if staged(Bundle.main.bundleURL, team: team) && handOff() { exit(0) }
            log("Could not install SpaceDock.")
            return true
        }
        writeAgent()
        if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == releaseID || agentPID() == getpid() {
            return true
        }
        if agentPID() == nil {
            _ = launchctl(["bootstrap", domain(), agentPlist().path])
        }
        exit(0)
    }

    static func schedule(canUpdate: @escaping () -> Bool) {
        guard !UserDefaults.standard.bool(forKey: "devBuild") else { return }
        let fire = {
            guard canUpdate() else { return }
            check()
        }
        let timer = Timer(timeInterval: 6 * 60 * 60, repeats: true) { _ in fire() }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: fire)
    }

    private static func check() {
        guard checking == false else { return }
        checking = true
        var request = URLRequest(url: releaseFeed)
        request.setValue("SpaceDock", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        feedSession.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data,
                  let release = try? JSONDecoder().decode(GitRelease.self, from: data)
            else {
                DispatchQueue.main.async { checking = false }
                return
            }
            let local = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            guard versionIsNewer(release.tag_name, than: local),
                  let asset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }),
                  let url = URL(string: asset.browser_download_url),
                  allowedDownload(url)
            else {
                DispatchQueue.main.async { checking = false }
                return
            }
            guard let team = teamID(Bundle.main.bundleURL) else {
                log("Update skipped. This copy has no signing team.")
                DispatchQueue.main.async { checking = false }
                return
            }
            feedSession.dataTask(with: url) { body, fileResponse, _ in
                DispatchQueue.main.async {
                    if let file = fileResponse as? HTTPURLResponse, file.statusCode == 200, let body {
                        apply(body, team: team, version: release.tag_name)
                    }
                    checking = false
                }
            }.resume()
        }.resume()
    }

    private static var checking = false

    private static func apply(_ data: Data, team: String, version: String) {
        guard data.count <= maxDownload else {
            log("Update rejected. File is too large.")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spacedock-\(UUID().uuidString)")
        let mount = root.appendingPathComponent("mnt")
        let disk = root.appendingPathComponent("SpaceDock.dmg")
        do {
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            try data.write(to: disk)
            guard launchctlStatus("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, disk.path]) == 0 else {
                log("Update rejected. Disk image did not open.")
                return
            }
            let app = mount.appendingPathComponent("SpaceDock.app")
            let ready = FileManager.default.fileExists(atPath: app.path) && staged(app, team: team)
            let got = bundleVersion(incomingApp())
            _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            // A disk image older than its release tag would download again on every launch.
            guard ready, let got, !versionIsNewer(version, than: got), handOff() else {
                log("Update rejected. Signature does not match this copy.")
                return
            }
            log("Updating to \(version).")
            exit(0)
        } catch {
            log("Update failed.")
        }
    }

    private static func staged(_ app: URL, team: String?) -> Bool {
        guard let incoming = stage(app) else { return false }
        return signatureOK(incoming, team: team)
    }

    private static func handOff() -> Bool {
        writeAgent()
        writeHelper(parent: getpid())
        _ = launchctl(["bootout", domainLabel(updateLabel)])
        return launchctl(["bootstrap", domain(), helperPlist().path]) == 0
    }
}

private func installedApp() -> URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/SpaceDock.app")
}

private func incomingApp() -> URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/SpaceDock.app.incoming")
}

private func bundleVersion(_ app: URL) -> String? {
    let url = app.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: url),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return nil }
    return plist["CFBundleShortVersionString"] as? String
}

private func agentPlist() -> URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents/\(releaseID).plist")
}

private func helperPlist() -> URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents/\(updateLabel).plist")
}

private func domain() -> String { "gui/\(getuid())" }
private func domainLabel(_ label: String) -> String { "\(domain())/\(label)" }

private func writeAgent() {
    let home = NSHomeDirectory()
    let plist: [String: Any] = [
        "Label": releaseID,
        "ProgramArguments": ["\(home)/Applications/SpaceDock.app/Contents/MacOS/SpaceDock"],
        "RunAtLoad": true,
        "ProcessType": "Interactive",
        "LimitLoadToSessionType": "Aqua",
        "StandardOutPath": "\(home)/Library/Logs/SpaceDock.log",
        "StandardErrorPath": "\(home)/Library/Logs/SpaceDock.log",
    ]
    writePlist(plist, to: agentPlist())
    try? FileManager.default.createDirectory(
        at: URL(fileURLWithPath: home).appendingPathComponent("Library/Logs"),
        withIntermediateDirectories: true
    )
}

private func writeHelper(parent: pid_t) {
    let home = NSHomeDirectory()
    let support = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/SpaceDock")
    try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let script = support.appendingPathComponent("update.sh")
    let text = """
    #!/bin/sh
    parent="$1"
    uid=$(id -u)
    home="$HOME"
    dest="$home/Applications/SpaceDock.app"
    incoming="$home/Applications/SpaceDock.app.incoming"
    log="$home/Library/Logs/SpaceDock.log"
    launchctl bootout "gui/$uid/\(releaseID)" || true
    n=0
    while kill -0 "$parent" 2>/dev/null && [ "$n" -lt 50 ]; do
      n=$((n + 1))
      sleep 0.2
    done
    if [ -d "$incoming" ]; then
      n=0
      while [ -e "$dest" ] && [ "$n" -lt 50 ]; do
        rm -rf "$dest" && break
        n=$((n + 1))
        sleep 0.2
      done
      if [ -e "$dest" ]; then
        echo "SpaceDock swap failed" >> "$log"
        rm -rf "$incoming"
      else
        mv "$incoming" "$dest" || echo "SpaceDock swap failed" >> "$log"
      fi
    fi
    xattr -dr com.apple.quarantine "$dest" || true
    launchctl bootstrap "gui/$uid" "$home/Library/LaunchAgents/\(releaseID).plist" \
      || { sleep 0.5; launchctl bootstrap "gui/$uid" "$home/Library/LaunchAgents/\(releaseID).plist"; } \
      || echo "SpaceDock did not start" >> "$log"
    rm -f "$home/Library/LaunchAgents/\(updateLabel).plist"
    rm -f "$0"
    launchctl bootout "gui/$uid/\(updateLabel)" || true
    """
    try? text.write(to: script, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    writePlist([
        "Label": updateLabel,
        "ProgramArguments": ["/bin/sh", script.path, String(parent)],
        "RunAtLoad": true,
    ], to: helperPlist())
}

private func writePlist(_ plist: [String: Any], to url: URL) {
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)
    } catch {
        log("Could not write \(url.lastPathComponent).")
    }
}

private func stage(_ app: URL) -> URL? {
    let incoming = installedApp().deletingLastPathComponent().appendingPathComponent("SpaceDock.app.incoming")
    do {
        try FileManager.default.createDirectory(at: incoming.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: incoming.path) {
            try FileManager.default.removeItem(at: incoming)
        }
        try FileManager.default.copyItem(at: app, to: incoming)
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", incoming.path])
        return incoming
    } catch {
        return nil
    }
}

private func signatureOK(_ app: URL, team: String?) -> Bool {
    guard run("/usr/bin/codesign", ["--verify", "--strict", app.path]).status == 0 else { return false }
    guard let team else { return true }
    return teamID(app) == team
}

private func teamID(_ app: URL) -> String? {
    let text = run("/usr/bin/codesign", ["-dv", "--verbose=4", app.path]).text
    for line in text.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
        let value = line.dropFirst("TeamIdentifier=".count)
        if value.isEmpty || value == "not set" { return nil }
        return String(value)
    }
    return nil
}

private func agentPID() -> Int32? {
    let text = run("/bin/launchctl", ["print", domainLabel(releaseID)]).text
    for line in text.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("pid = ") { return Int32(trimmed.dropFirst("pid = ".count)) }
    }
    return nil
}

@discardableResult
private func launchctl(_ args: [String]) -> Int32 {
    launchctlStatus("/bin/launchctl", args)
}

private func launchctlStatus(_ path: String, _ args: [String]) -> Int32 {
    run(path, args).status
}

private func run(_ path: String, _ args: [String]) -> (status: Int32, text: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    task.arguments = ["-i", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=\(NSHomeDirectory())", path] + args
    let out = Pipe()
    let err = Pipe()
    task.standardOutput = out
    task.standardError = err
    do { try task.run() } catch { return (1, "") }
    task.waitUntilExit()
    let data = out.fileHandleForReading.readDataToEndOfFile() + err.fileHandleForReading.readDataToEndOfFile()
    return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}
