import Foundation
import Darwin

// Minimal newline-delimited JSON-over-AF_UNIX transport. Local only: no TCP, no
// network exposure. Socket directory is 0700 and the socket file is 0600.
enum Net {
    // A single request/reply never legitimately exceeds this; anything longer is
    // a runaway peer and the connection is dropped.
    static let maxLine = 1 << 20

    static func socketDir() -> String {
        let home = NSHomeDirectory()
        let dir = "\(home)/.testa"
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) {
            try? FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        chmod(dir, 0o700)  // also tighten a pre-existing, looser directory
        return dir
    }

    // Per-UDID socket so multiple simulators can each have a warm daemon.
    static func socketPath(_ udid: String) -> String { "\(socketDir())/daemon-\(udid).sock" }

    // Bound the time any read/write can block, so neither side can wedge forever.
    static func setTimeouts(_ fd: Int32, recv: Double, send: Double) {
        func tv(_ s: Double) -> timeval {
            timeval(tv_sec: Int(s), tv_usec: Int32((s - s.rounded(.down)) * 1_000_000))
        }
        var r = tv(recv)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &r, socklen_t(MemoryLayout<timeval>.size))
        var w = tv(send)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &w, socklen_t(MemoryLayout<timeval>.size))
    }

    private static let sunPathCap = 104  // sockaddr_un.sun_path size on Darwin

    private static func makeAddr(_ path: String) -> (sockaddr_un, socklen_t)? {
        let bytes = Array(path.utf8)
        guard bytes.count < sunPathCap else {
            fputs("testa: socket path too long (\(bytes.count) > \(sunPathCap - 1)): \(path)\n", stderr)
            return nil
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: sunPathCap) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        return (addr, socklen_t(MemoryLayout<sockaddr_un>.size))
    }

    // --- Server ---

    static func listen(_ path: String) -> Int32 {
        guard let a = makeAddr(path) else { return -1 }
        var addr = a.0
        let len = a.1
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        // umask around bind(): the socket is never world-connectable, not even in
        // the window between bind() and chmod().
        let saved = umask(0o177)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        umask(saved)
        guard rc == 0 else { close(fd); return -1 }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else { close(fd); return -1 }
        return fd
    }

    // --- Client ---

    static func connect(_ path: String) -> Int32 {
        guard let a = makeAddr(path) else { return -1 }
        var addr = a.0
        let len = a.1
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        if rc != 0 { close(fd); return -1 }
        return fd
    }

    // Read one '\n'-terminated line (without the newline). nil on EOF, error,
    // timeout or overlong input. Reads in chunks: each connection carries exactly
    // one request/reply, so over-reading past the newline is harmless.
    static func readLine(_ fd: Int32) -> String? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { return nil }
            if let nl = buf[0..<n].firstIndex(of: 0x0A) {
                data.append(contentsOf: buf[0..<nl])
                return String(data: data, encoding: .utf8)
            }
            data.append(contentsOf: buf[0..<n])
            if data.count > maxLine { return nil }
        }
    }

    static func writeLine(_ fd: Int32, _ s: String) {
        var data = Data(s.utf8)
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            var p = raw.baseAddress!
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, p, remaining)
                if n <= 0 { break }
                p = p.advanced(by: n)
                remaining -= n
            }
        }
    }
}
