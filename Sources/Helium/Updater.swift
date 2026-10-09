import AppKit
import Security

extension Notification.Name {
    static let heliumUpdaterChanged = Notification.Name("HeliumUpdaterChanged")
}

/// Updates from GitHub releases. A new version is downloaded, checked to be signed by
/// the same Apple team as this app and notarized, then swapped in on disk. The running
/// app keeps going, so open shells survive; the new version starts on the next launch.
final class Updater {
    static let shared = Updater()
    private static let repo = "yowmamasita/helium-terminal"

    enum State: Equatable {
        case idle, checking, upToDate
        case downloading(String)
        case ready(String)
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet { NotificationCenter.default.post(name: .heliumUpdaterChanged, object: nil) }
    }

    var automatic: Bool {
        get { UserDefaults.standard.object(forKey: "AutoUpdate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "AutoUpdate") }
    }

    private let appURL = Bundle.main.bundleURL
    private var timer: Timer?
    /// The version on disk, which moves ahead of the running one after an install.
    private lazy var installedVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    /// Why this copy can't update itself, or nil when it can.
    lazy var unavailableReason: String? = {
        let path = appURL.path
        if path.contains("/AppTranslocation/") { return "Move Helium to the Applications folder to get updates." }
        if path.contains("/Cellar/") || path.contains("zerobrew") {
            return "Installed as a formula; update with `zb upgrade` or `brew upgrade`."
        }
        guard Self.teamID(of: appURL) != nil else { return "This is a development build, which doesn't update itself." }
        guard FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path) else {
            return "Helium can't replace itself in \(appURL.deletingLastPathComponent().path)."
        }
        return nil
    }()

    func start() {
        guard unavailableReason == nil else { return }
        // First check shortly after launch, then daily.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            if self?.automatic == true { self?.check() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            if self?.automatic == true { self?.check() }
        }
        timer?.tolerance = 3600
    }

    func check() {
        guard unavailableReason == nil else { return }
        switch state {
        case .checking, .downloading, .ready: return // .ready: keep "Relaunch to update" until the user does
        default: break
        }
        state = .checking
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("helium-terminal/\(installedVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, error in
            let result = Self.parseRelease(data)
            DispatchQueue.main.async { self.handle(result, error: error) }
        }.resume()
    }

    private func handle(_ release: (version: String, zip: URL)?, error: Error?) {
        guard let release else {
            state = .failed(error?.localizedDescription ?? "Couldn't read the latest release.")
            return
        }
        guard Self.isNewer(release.version, than: installedVersion) else {
            if case .ready = state { return } // already installed, waiting for a relaunch
            state = .upToDate
            return
        }
        state = .downloading(release.version)
        URLSession.shared.downloadTask(with: release.zip) { file, _, error in
            // The downloaded file is deleted when this handler returns, so install here (off the main thread).
            let outcome: Result<Void, Error> = file.map { f in Result { try self.install(zip: f, version: release.version) } }
                ?? .failure(error ?? URLError(.unknown))
            DispatchQueue.main.async {
                switch outcome {
                case .success:
                    self.installedVersion = release.version
                    self.state = .ready(release.version)
                case .failure(let e):
                    self.state = .failed(e.localizedDescription)
                }
            }
        }.resume()
    }

    private struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    private func install(zip: URL, version: String) throws {
        // Unpack next to the app so the final swap is a rename on the same volume.
        let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                appropriateFor: appURL, create: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, work.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0,
              let newApp = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else { throw UpdateError("The download didn't contain the app.") }

        // The real safeguard: only an app signed by our own Apple team, and notarized, replaces this one.
        guard let team = Self.teamID(of: appURL), Self.verify(newApp, team: team) else {
            throw UpdateError("The download isn't signed by the Helium developer; not installing it.")
        }
        let newVersion = Bundle(url: newApp)?.infoDictionary?["CFBundleShortVersionString"] as? String
        guard newVersion == version else { throw UpdateError("The download is version \(newVersion ?? "?"), expected \(version).") }

        _ = try FileManager.default.replaceItemAt(appURL, withItemAt: newApp)
    }

    /// Quits and starts the installed version once this process has exited.
    func relaunch() {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", appURL.path]
        try? waiter.run()
        NSApp.terminate(nil)
        // Only reached when quitting was cancelled; don't reopen later by surprise.
        waiter.terminate()
    }

    // MARK: Helpers

    static func parseRelease(_ data: Data?) -> (version: String, zip: URL)? {
        guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String, let assets = obj["assets"] as? [[String: Any]] else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let name = "helium-terminal-\(version)-macos-arm64.zip"
        guard let asset = assets.first(where: { $0["name"] as? String == name }),
              let s = asset["browser_download_url"] as? String, let url = URL(string: s) else { return nil }
        return (version, url)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// The Apple team that signed the app at `url`, or nil if it isn't Developer ID signed.
    static func teamID(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func verify(_ app: URL, team: String,
                       identifier id: String = Bundle.main.bundleIdentifier ?? "io.github.yowmamasita.helium-terminal") -> Bool {
        var code: SecStaticCode?
        var req: SecRequirement?
        // Pin the bundle ID too, so another notarized app from the same team can't be swapped in.
        let text = "anchor apple generic and identifier \"\(id)\" and certificate leaf[subject.OU] = \"\(team)\" and notarized"
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess, let req else { return false }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess
    }
}
