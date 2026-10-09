import Darwin
import Foundation

/// Snapshot of all processes, used to find everything running under a pane's tty.
struct ProcessTree {
    private(set) var children: [pid_t: [pid_t]] = [:]
    private(set) var byTTY: [dev_t: [pid_t]] = [:]

    init() {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return }
        // Headroom for processes spawned between the two calls.
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return }
        for p in procs.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            let pid = p.kp_proc.p_pid
            children[p.kp_eproc.e_ppid, default: []].append(pid)
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

    /// TCP ports in LISTEN state owned by any process under the given ttys.
    static func listeningPorts(ttys: [String], tree: ProcessTree) -> [Int] {
        let devs: [dev_t] = ttys.compactMap { name in
            var st = stat()
            let path = name.hasPrefix("/dev/") ? name : "/dev/" + name
            return stat(path, &st) == 0 ? st.st_rdev : nil
        }
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
