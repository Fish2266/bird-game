import AppKit
import CryptoKit

/// Keeps Bird Game up to date from its GitHub releases: checks for a newer version (at launch and every few hours),
/// and installs it on request. Installing downloads the release's DMG, checks it against the SHA-256 GitHub publishes,
/// copies the new app out of it, then quits; a tiny helper swaps the new app in and opens it. Coins and birds live
/// in the user's preferences, so they carry over.
final class Updater {
    struct Release: Equatable {
        var version: String
        var tag: String
        var notes: [String]
        var dmg: URL
        var size: Int
        var sha256: String?
        var page: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release, Double)
        case installing(Release)
        case failed(String)
        /// A check the player asked for didn't get through.
        case offline(String)
        /// A newer version exists but can't be installed in place (show the download page instead).
        case manual(Release, String)
    }

    static let repo = "Fish2266/bird-game"
    private(set) var state = State.idle { didSet { if state != oldValue { onChange?(state) } } }
    /// Main queue.
    var onChange: ((State) -> Void)?
    /// Quits the app once the helper is waiting (the app passes NSApp.terminate; tests exit).
    var quit: () -> Void = { NSApp.terminate(nil) }
    private var lastCheck = Date.distantPast
    private var download: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?
    private var cancelled = false
    /// The newest release seen by the last successful check.
    private(set) var latest: Release?

    var current: String { AppVersion.short }
    /// Checking on its own can be turned off in the menu.
    var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: "updates.auto") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "updates.auto") }
    }

    private var feed: URL {
        if let s = ProcessInfo.processInfo.environment["BIRD_UPDATE_FEED"], let u = URL(string: s) { return u }
        return URL(string: "https://api.github.com/repos/\(Updater.repo)/releases/latest")!
    }

    /// Newer than ours? ("0.3" > "0.2.1", "0.10" > "0.9")
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// At launch and then every 6 hours (when automatic checks are on).
    func checkIfDue() {
        guard autoCheck, Date().timeIntervalSince(lastCheck) > 6 * 3600 else { return }
        check(quietly: true)
    }

    /// `quietly`: an automatic check; if it can't get through it says nothing.
    func check(quietly: Bool = false) {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        lastCheck = Date()
        // Automatic checks don't flicker the menu row.
        if !quietly { state = .checking }
        var req = URLRequest(url: feed, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("BirdGame/\(current)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let data, code == 200, let r = Updater.parse(data) {
                DispatchQueue.main.async { self.found(r) }
            } else if self.feed.host == "api.github.com" {
                // Rate-limited or the API is down: the releases page redirect still names the latest tag.
                self.checkViaRedirect(apiError: error?.localizedDescription ?? "HTTP \(code)", quietly: quietly)
            } else {
                let why = "Couldn't reach the update server (\(error?.localizedDescription ?? "HTTP \(code)"))."
                DispatchQueue.main.async { self.checkFailed(why, quietly: quietly) }
            }
        }.resume()
    }

    private func checkFailed(_ why: String, quietly: Bool) {
        Log.write("update check failed: \(why)")
        switch state {
        case .downloading, .installing: return
        default: break
        }
        // An automatic check that can't get through keeps whatever the menu showed.
        if !quietly { state = .offline(why) }
    }

    private func found(_ r: Release) {
        Log.write("update check: latest \(r.version), have \(current)")
        latest = r
        // A background check finishing mid-install mustn't offer the update again.
        switch state {
        case .downloading, .installing: return
        default: break
        }
        guard Updater.isNewer(r.version, than: current) else { state = .upToDate; return }
        offer(r)
    }

    private func offer(_ r: Release) {
        if let why = installBlocker() { state = .manual(r, why) }
        else if installFailedBefore == r.version {
            state = .manual(r, "Bird Game couldn't replace itself last time (macOS may have stopped it). Download the new version and drag it into Applications.")
        } else { state = .available(r) }
    }

    /// The version a previous install tried to put in place, if we're still not running it (the swap failed).
    private(set) var installFailedBefore: String?
    private static let pendingKey = "update.pending"

    /// At launch: did the last install work? Returns the version that failed to go in, if any.
    @discardableResult
    func checkLastInstall() -> String? {
        let d = UserDefaults.standard
        guard let pending = d.string(forKey: Updater.pendingKey) else { return nil }
        d.removeObject(forKey: Updater.pendingKey)
        guard Updater.isNewer(pending, than: current) else { return nil }
        Log.write("update: \(pending) was installed but we're still \(current) - the swap failed")
        installFailedBefore = pending
        return pending
    }

    /// After a failure: offer the release again if there is one, otherwise check again.
    func retry() {
        if let r = latest, Updater.isNewer(r.version, than: current) { offer(r) } else { check() }
    }

    /// Put a failure message away (back to offering the update, if there is one).
    func dismissFailure() {
        guard case .failed = state else { return }
        if let r = latest, Updater.isNewer(r.version, than: current) { offer(r) } else { state = .idle }
    }

    /// Stop a download that's under way.
    func cancel() {
        guard case .downloading(let r, _) = state else { return }
        cancelled = true
        download?.cancel()
        download = nil
        progressObservation = nil
        state = .available(r)
        Log.write("update: download cancelled")
    }

    /// Parses GitHub's "latest release" JSON.
    static func parse(_ data: Data) -> Release? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String,
              let assets = j["assets"] as? [[String: Any]],
              let dmg = assets.first(where: { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }),
              let urlString = dmg["browser_download_url"] as? String, let url = URL(string: urlString) else { return nil }
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        var sha: String?
        if let d = dmg["digest"] as? String, d.hasPrefix("sha256:") { sha = String(d.dropFirst(7)).lowercased() }
        let page = (j["html_url"] as? String).flatMap(URL.init(string:)) ?? URL(string: "https://github.com/\(repo)/releases/latest")!
        return Release(version: version, tag: tag, notes: notes(j["body"] as? String ?? ""), dmg: url, size: dmg["size"] as? Int ?? 0,
                       sha256: sha, page: page)
    }

    /// The first few bullet points of the release notes, without Markdown.
    static func notes(_ body: String) -> [String] {
        var out: [String] = []
        for line in body.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- ") || t.hasPrefix("* ") else { continue }
            var s = String(t.dropFirst(2))
            for m in ["**", "__", "`"] { s = s.replacingOccurrences(of: m, with: "") }
            out.append(s)
            if out.count == 6 { break }
        }
        return out
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    private func checkViaRedirect(apiError: String, quietly: Bool) {
        let url = URL(string: "https://github.com/\(Updater.repo)/releases/latest")!
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        session.dataTask(with: url) { [weak self] _, response, error in
            guard let self else { return }
            let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location") ?? ""
            guard let range = location.range(of: "/releases/tag/") else {
                let why = "Couldn't check for updates (\(error?.localizedDescription ?? apiError))."
                DispatchQueue.main.async { self.checkFailed(why, quietly: quietly) }
                session.finishTasksAndInvalidate()
                return
            }
            let tag = String(location[range.upperBound...])
            let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let dmg = URL(string: "https://github.com/\(Updater.repo)/releases/download/\(tag)/BirdGame-\(version).dmg")!
            let r = Release(version: version, tag: tag, notes: [], dmg: dmg, size: 0, sha256: nil,
                            page: URL(string: "https://github.com/\(Updater.repo)/releases/tag/\(tag)")!)
            DispatchQueue.main.async { self.found(r) }
            session.finishTasksAndInvalidate()
        }.resume()
    }

    // MARK: Installing

    private var appURL: URL { Bundle.main.bundleURL }

    /// Why this copy can't replace itself (nil = it can).
    func installBlocker() -> String? {
        let path = appURL.path
        if path.contains("/AppTranslocation/") {
            return "Bird Game is running from a temporary place macOS made for it. Move it into Applications first, then open it from there."
        }
        if path.hasPrefix("/Volumes/") {
            return "Bird Game is running straight from the installer. Drag it into Applications first."
        }
        let parent = appURL.deletingLastPathComponent().path
        if !FileManager.default.isWritableFile(atPath: parent) || !FileManager.default.isWritableFile(atPath: path) {
            return "This Mac doesn't let Bird Game replace itself (it needs an administrator). Download the new version instead."
        }
        return nil
    }

    func install() {
        guard case .available(let r) = state else { return }
        if let why = installBlocker() { state = .manual(r, why); return }
        state = .downloading(r, 0)
        cancelled = false
        Log.write("update: downloading \(r.dmg.absoluteString)")
        let task = URLSession.shared.downloadTask(with: r.dmg) { [weak self] tmp, response, error in
            guard let self else { return }
            if (error as? URLError)?.code == .cancelled { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let tmp, error == nil, code == 200 || code == 0 else {
                DispatchQueue.main.async { self.state = .failed("The download failed (\(error?.localizedDescription ?? "HTTP \(code)")). Try again in a moment.") }
                return
            }
            // Move it somewhere that survives this callback, then do the slow work off the main thread.
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("BirdGameUpdate-\(UUID().uuidString.prefix(8))", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let dmg = work.appendingPathComponent("BirdGame.dmg")
                try FileManager.default.moveItem(at: tmp, to: dmg)
                DispatchQueue.main.async { self.state = .installing(r) }
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = self.prepare(r, dmg: dmg, work: work)
                    DispatchQueue.main.async {
                        switch result {
                        case .success(let staged): self.handOver(r, staged: staged, work: work)
                        case .failure(let e):
                            try? FileManager.default.removeItem(at: work)
                            self.state = .failed(e.message)
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { self.state = .failed("Couldn't save the download: \(error.localizedDescription)") }
            }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            // Whole percents only: the observer fires for every packet.
            let f = (p.fractionCompleted * 100).rounded(.down) / 100
            DispatchQueue.main.async {
                guard let self, !self.cancelled, case .downloading(let r, let old) = self.state, f > old else { return }
                self.state = .downloading(r, f)
            }
        }
        download = task
        task.resume()
    }

    struct UpdateError: Error { let message: String }

    /// Verify, mount, copy the app out, unmount. Returns the new app, ready to swap in.
    private func prepare(_ r: Release, dmg: URL, work: URL) -> Result<URL, UpdateError> {
        if let want = r.sha256 {
            guard let data = try? Data(contentsOf: dmg, options: .mappedIfSafe) else { return .failure(UpdateError(message: "Couldn't read the download.")) }
            let got = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard got == want else {
                Log.write("update: checksum mismatch \(got) != \(want)")
                return .failure(UpdateError(message: "The download didn't match what GitHub says it should be, so it wasn't installed. Try again."))
            }
        }
        let mount = work.appendingPathComponent("mnt", isDirectory: true)
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard Updater.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path]) == 0 else {
            return .failure(UpdateError(message: "Couldn't open the downloaded installer."))
        }
        defer { _ = Updater.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        guard let found = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "app" }),
              let info = NSDictionary(contentsOf: found.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let newVersion = info["CFBundleShortVersionString"] as? String,
              Updater.isNewer(newVersion, than: current) else {
            return .failure(UpdateError(message: "The downloaded installer doesn't contain a newer Bird Game."))
        }
        let staged = work.appendingPathComponent(found.lastPathComponent)
        guard Updater.run("/usr/bin/ditto", [found.path, staged.path]) == 0 else {
            return .failure(UpdateError(message: "Couldn't copy the new version out of the installer."))
        }
        _ = Updater.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        Log.write("update: staged \(newVersion) at \(staged.path)")
        return .success(staged)
    }

    /// The notes of the version that was just installed, for the new version's "what's new" card.
    static let installedNotesKey = "update.installedNotes"

    /// Start the helper that swaps the apps once we've quit, then quit.
    private func handOver(_ r: Release, staged: URL, work: URL) {
        let script = work.appendingPathComponent("swap.sh")
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/BirdGame-update.log").path
        let relaunch = ProcessInfo.processInfo.environment["BIRD_UPDATE_NO_RELAUNCH"] == nil
        let text = """
        #!/bin/sh
        # Waits for Bird Game to quit, puts the new version in its place and opens it.
        PID="$1"; APP="$2"; NEW="$3"; WORK="$4"
        exec >>"\(log)" 2>&1
        echo "$(date): updating $APP"
        i=0
        while kill -0 "$PID" 2>/dev/null && [ $i -lt 600 ]; do sleep 0.1; i=$((i+1)); done
        OLD="$APP.previous"
        rm -rf "$OLD"
        if mv "$APP" "$OLD"; then
          if mv "$NEW" "$APP"; then
            rm -rf "$OLD"
            echo "installed"
          else
            mv "$OLD" "$APP"
            echo "couldn't move the new version in; kept the old one"
          fi
        else
          echo "couldn't move the old version aside"
        fi
        xattr -dr com.apple.quarantine "$APP" 2>/dev/null
        \(relaunch ? "open \"$APP\"" : "echo \"not relaunching (test)\"")
        rm -rf "$WORK"
        """
        do {
            try text.write(to: script, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), appURL.path, staged.path, work.path]
            try p.run()
            UserDefaults.standard.set(["version": r.version, "notes": r.notes] as [String: Any], forKey: Updater.installedNotesKey)
            UserDefaults.standard.set(r.version, forKey: Updater.pendingKey)
            Log.write("update: helper started, quitting")
            quit()
        } catch {
            state = .failed("Couldn't start the installer: \(error.localizedDescription)")
        }
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

// MARK: - UI

/// The update line at the bottom of the menu's left column: status and one button.
final class UpdateRowView: FlippedView {
    var onAction: (() -> Void)?
    private let label = WiiLabel(12, color: Wii.textSoft)
    private let button = WiiButton("", textSize: 13)
    private let bar = ThinBar()

    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [label, button, bar] as [NSView] { addSubview(v) }
        button.onClick = { [weak self] in self?.onAction?() }
        bar.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ state: Updater.State, current: String) {
        toolTip = nil
        label.bold = false
        bar.isHidden = true
        button.isHidden = false
        button.isEnabled = true
        label.color = Wii.textSoft
        switch state {
        case .idle:
            label.text = "Bird Game \(current)"
            button.title = "Check for updates"
        case .checking:
            label.text = "Checking for updates\u{2026}"
            button.isHidden = true
        case .upToDate:
            label.text = "Bird Game \(current) is up to date \u{2713}"
            button.title = "Check again"
        case .available(let r):
            label.text = "Bird Game \(r.version) is here!"
            label.color = Wii.blue
            label.bold = true
            button.title = "Update now"
        case .downloading(_, let p):
            label.text = "Downloading the update\u{2026} \(Int(p * 100))%"
            bar.isHidden = false
            bar.fraction = p
            button.isHidden = true
        case .installing:
            label.text = "Installing\u{2026} Bird Game will restart"
            button.isHidden = true
        case .failed(let why):
            label.text = "The update didn't work"
            label.color = NSColor(srgbRed: 0.78, green: 0.3, blue: 0.25, alpha: 1)
            button.title = "Try again"
            toolTip = why
        case .offline(let why):
            label.text = "Couldn't check for updates"
            button.title = "Try again"
            toolTip = why
        case .manual(let r, _):
            label.text = "Bird Game \(r.version) is out"
            label.color = Wii.blue
            label.bold = true
            button.title = "Get it"
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let W = bounds.width
        label.frame = NSRect(x: 0, y: 0, width: W, height: label.fittingHeight(width: W))
        bar.frame = NSRect(x: 0, y: label.frame.maxY + 6, width: W, height: 6)
        button.frame = NSRect(x: -5, y: max(label.frame.maxY + 2, bounds.height - 40), width: W + 10, height: 40)
    }
}

/// "Update to Bird Game x?" with the release notes; stays up with a progress bar while it downloads.
final class UpdateCard: NSView {
    var onInstall: (() -> Void)?
    var onCancel: (() -> Void)?
    var onOpenPage: (() -> Void)?
    private let card = WiiPanel()
    private let title = WiiLabel(26, bold: true)
    private let notes = WiiLabel(14)
    private let info = WiiLabel(13, color: Wii.textSoft)
    private let status = WiiLabel(14, bold: true, color: Wii.blue)
    private let bar = ThinBar()
    private let primary = WiiButton("", textSize: 17)
    private let secondary = WiiButton("Not now", textSize: 14)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.3).cgColor
        layer?.zPosition = 200
        addSubview(card)
        card.borderColor = Wii.blue
        card.glass = 62
        for v in [title, notes, info, status, bar, primary, secondary] as [NSView] { card.addSubview(v) }
        title.align = .center
        title.centerV = true
        info.align = .center
        status.align = .center
        primary.onClick = { [weak self] in self?.primaryClicked() }
        secondary.onClick = { [weak self] in self?.onCancel?() }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) {}
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 53: if !secondary.isHidden { onCancel?() }
        case 36, 76: if !primary.isHidden { primaryClicked() }
        default: break
        }
    }

    private var state = Updater.State.idle
    private func primaryClicked() {
        if case .manual = state { onOpenPage?() } else { onInstall?() }
    }

    /// `lanNote`: what updating does to the LAN game you're in (nil = not in one).
    func show(_ s: Updater.State, lanNote: String?) {
        state = s
        bar.isHidden = true
        status.text = ""
        primary.isHidden = false
        primary.isEnabled = true
        secondary.title = "Not now"
        switch s {
        case .available(let r), .manual(let r, _):
            title.text = "Bird Game \(r.version) is here!"
            notes.text = r.notes.isEmpty ? "New features and fixes." : r.notes.map { "\u{2022} " + $0 }.joined(separator: "\n")
            if case .manual(_, let why) = s {
                info.text = why
                primary.title = "Open the download page"
            } else {
                let size = r.size > 0 ? String(format: " (%.1f MB)", Double(r.size) / 1_000_000) : ""
                info.text = "It downloads\(size), then Bird Game restarts on the new version. Your coins, birds and outfits are kept."
                    + (lanNote.map { " " + $0 } ?? "") + " macOS may ask for camera access again."
                primary.title = "Update and restart"
            }
        case .downloading(let r, let p):
            title.text = "Updating to Bird Game \(r.version)"
            status.text = "Downloading\u{2026} \(Int(p * 100))%"
            bar.isHidden = false
            bar.fraction = p
            primary.isHidden = true
            secondary.title = "Cancel"
        case .installing(let r):
            title.text = "Updating to Bird Game \(r.version)"
            status.text = "Installing\u{2026} Bird Game will restart in a moment"
            bar.isHidden = false
            bar.fraction = 1
            primary.isHidden = true
            secondary.isHidden = true
        case .failed(let why):
            title.text = "The update didn't work"
            status.text = ""
            info.text = why
            primary.title = "Try again"
            secondary.title = "Close"
        default:
            break
        }
        secondary.isHidden = { if case .installing = s { return true }; return false }()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w: CGFloat = 560
        let W = w - 80
        let notesH = notes.fittingHeight(width: W), infoH = info.fittingHeight(width: W)
        // The progress line only takes room while there's progress to show.
        let progressH: CGFloat = bar.isHidden && status.text.isEmpty ? 0 : 48
        let h = 4 + card.glass + 3 + 20 + notesH + 16 + infoH + 22 + progressH + 128
        card.frame = NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
        let c = card.contentRect
        let x = c.minX + 36
        let header = card.headerRect
        title.frame = header
        var y = header.maxY + 20
        notes.frame = NSRect(x: x, y: y, width: W, height: notesH); y += notesH + 16
        info.frame = NSRect(x: x, y: y, width: W, height: infoH); y += infoH + 14
        status.frame = NSRect(x: x, y: y, width: W, height: 20)
        bar.frame = NSRect(x: x + 40, y: y + 26, width: W - 80, height: 8)
        primary.frame = NSRect(x: c.midX - 170, y: c.maxY - 124, width: 340, height: 58)
        secondary.frame = NSRect(x: c.midX - 110, y: c.maxY - 64, width: 220, height: 46)
    }
}
