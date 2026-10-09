import Darwin
import Foundation

/// Snapshot of all processes, used to find everything running under a pane's tty.
struct ProcessTree {
    private(set) var children: [pid_t: [pid_t]] = [:]
    private(set) var parent: [pid_t: pid_t] = [:]
    private(set) var byTTY: [dev_t: [pid_t]] = [:]

    init() {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        var procs: [kinfo_proc] = []
        // Processes spawned between the two calls overflow the buffer (ENOMEM); retry with more headroom,
        // because an empty tree would look like every agent quit.
        for headroom in [16, 256, 4096] {
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return }
            procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + headroom)
            size = procs.count * MemoryLayout<kinfo_proc>.stride
            if sysctl(&mib, 4, &procs, &size, nil, 0) == 0 { break }
            guard errno == ENOMEM, headroom != 4096 else { return }
        }
        for p in procs.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            let pid = p.kp_proc.p_pid
            children[p.kp_eproc.e_ppid, default: []].append(pid)
            parent[pid] = p.kp_eproc.e_ppid
            if p.kp_eproc.e_tdev != -1 { byTTY[p.kp_eproc.e_tdev, default: []].append(pid) }
        }
    }

    /// Every process on these ttys plus all their descendants (agents' dev servers often detach from the tty).
    func processes(onTTYs devs: [dev_t]) -> Set<pid_t> {
        var seen = Set<pid_t>()
        var queue = devs.flatMap { byTTY[$0] ?? [] }
        while let pid = queue.popLast() {
            guard pid > 1, seen.insert(pid).inserted else { continue }
            queue += children[pid] ?? []
        }
        return seen
    }
}

enum Metadata {
    struct GitStatus: Equatable { var ahead = 0, behind = 0, dirty = false }

    /// Ahead/behind and dirty state. The one exception to "no subprocesses": the owner asked for it, so it runs
    /// only for the selected tab, off the main thread. Nil when git fails or takes over 2 s.
    static func gitStatus(_ dir: String) -> GitStatus? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // No optional locks: never contend for index.lock with an agent's own git commands.
        p.arguments = ["--no-optional-locks", "-C", dir, "status", "--porcelain=v2", "--branch"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let timer = DispatchWorkItem { p.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        guard p.terminationStatus == 0 else { return nil }
        return parseGitStatus(String(decoding: data, as: UTF8.self))
    }

    /// Parses `git status --porcelain=v2 --branch`: "# branch.ab +A -B", and any non-header line means dirty.
    static func parseGitStatus(_ s: String) -> GitStatus {
        var st = GitStatus()
        for line in s.split(separator: "\n") {
            if line.hasPrefix("# branch.ab ") {
                let parts = line.split(separator: " ")
                if parts.count == 4 {
                    st.ahead = Int(parts[2].dropFirst()) ?? 0
                    st.behind = Int(parts[3].dropFirst()) ?? 0
                }
            } else if !line.hasPrefix("#") {
                st.dirty = true
            }
        }
        return st
    }

    /// The titlebar strip's sections, shown with separators between them:
    /// "⎇ main", "↑2 ahead  ↓1 behind", "● uncommitted changes".
    static func branchParts(_ branch: String, _ st: GitStatus?) -> [String] {
        var parts = ["⎇ " + branch]
        guard let st else { return parts }
        let sync = (st.ahead > 0 ? ["↑\(st.ahead) ahead"] : []) + (st.behind > 0 ? ["↓\(st.behind) behind"] : [])
        if !sync.isEmpty { parts.append(sync.joined(separator: "  ")) }
        if st.dirty { parts.append("● uncommitted changes") }
        return parts
    }
    /// Current branch from .git/HEAD (or the short commit when detached), found by walking up from `dir`.
    static func gitBranch(_ dir: String) -> String? {
        var url = URL(fileURLWithPath: dir)
        while true {
            let dotgit = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotgit.path, isDirectory: &isDir) {
                var gitDir = dotgit
                if !isDir.boolValue {
                    // Worktrees and submodules: ".git" is a file containing "gitdir: <path>".
                    guard let s = try? String(contentsOf: dotgit, encoding: .utf8),
                          let line = s.split(separator: "\n").first, line.hasPrefix("gitdir: ") else { return nil }
                    let p = String(line.dropFirst(8))
                    gitDir = p.hasPrefix("/") ? URL(fileURLWithPath: p) : url.appendingPathComponent(p)
                }
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
                else { return nil }
                let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if h.hasPrefix("ref: refs/heads/") { return String(h.dropFirst(16)) }
                return String(h.prefix(7))
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }

    static func ttyDevice(_ name: String) -> dev_t? {
        var st = stat()
        let path = name.hasPrefix("/dev/") ? name : "/dev/" + name
        return stat(path, &st) == 0 ? st.st_rdev : nil
    }

    /// TCP ports in LISTEN state owned by any process under the given ttys.
    static func listeningPorts(ttys: [String], tree: ProcessTree) -> [Int] {
        let devs = ttys.compactMap(ttyDevice)
        var ports = Set<Int>()
        for pid in tree.processes(onTTYs: devs) {
            ports.formUnion(listeningPorts(pid: pid))
        }
        return ports.sorted()
    }

    static func listeningPorts(pid: pid_t) -> [Int] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)
        guard got > 0 else { return [] }

        var ports: [Int] = []
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            ports.append(Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))))
        }
        return ports
    }

    static func cwd(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { buf in
            String(cString: buf.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }
}
