import Foundation

/// Where the running executable really lives. Through a symlink (Homebrew's /opt/homebrew/bin/helium)
/// Foundation takes the symlink's directory for Bundle.main, so Info.plist and the resource bundle aren't
/// found and the first resource lookup crashes. main.swift uses this to run the real binary instead.
enum Launch {
    /// The .app that holds `executable` once symlinks are resolved, or nil when it isn't inside one.
    static func appBundle(containing executable: URL) -> URL? {
        let app = executable.resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }

    /// True when `executable` is inside an app bundle other than `mainBundle`, the one Foundation chose for
    /// Bundle.main: the process was started through a symlink and must re-run from the real path.
    static func needsRelaunch(executable: URL, mainBundle: URL) -> Bool {
        guard let app = appBundle(containing: executable) else { return false }
        return app.standardizedFileURL.path != mainBundle.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
