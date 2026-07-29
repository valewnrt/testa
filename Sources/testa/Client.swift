import Foundation
import Darwin

enum Client {
    static func executablePath() -> String {
        // The real running binary — reliable however we were invoked (bare PATH
        // name, relative, or absolute). argv[0] is not trustworthy here.
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buf, &size) == 0 {
            let p = buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            return (p as NSString).resolvingSymlinksInPath
        }
        let arg0 = CommandLine.arguments[0]
        let abs = (arg0 as NSString).isAbsolutePath
            ? arg0 : FileManager.default.currentDirectoryPath + "/" + arg0
        return (abs as NSString).resolvingSymlinksInPath
    }

    static func sendOnce(_ udid: String, _ argv: [String]) -> (Bool, String)? {
        let fd = Net.connect(Net.socketPath(udid))
        if fd < 0 { return nil }
        defer { close(fd) }
        // Generous read budget — scrollto/wait legitimately take tens of seconds —
        // but never unbounded.
        Net.setTimeouts(fd, recv: 120, send: 10)
        guard let data = try? JSONSerialization.data(withJSONObject: argv),
              let s = String(data: data, encoding: .utf8) else { return nil }
        Net.writeLine(fd, s)
        guard let resp = Net.readLine(fd),
              let rd = resp.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: rd)) as? [String: Any]
        else { return nil }
        return ((obj["ok"] as? Bool) ?? false, (obj["text"] as? String) ?? "")
    }

    static func spawnDaemon(_ udid: String) {
        let log = "\(Net.socketDir())/daemon-\(udid).log"
        FileManager.default.createFile(atPath: log, contents: nil)
        let out = FileHandle(forWritingAtPath: log)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executablePath())
        p.arguments = ["__daemon"]
        var env = ProcessInfo.processInfo.environment
        env["TESTA_UDID"] = udid
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out ?? FileHandle.nullDevice
        p.standardError = out ?? FileHandle.nullDevice
        try? p.run()
    }

    static func send(_ udid: String, _ argv: [String]) -> (Bool, String) {
        if let r = sendOnce(udid, argv) { return r }
        spawnDaemon(udid)
        for _ in 0..<200 {  // up to ~20s for cold framework warmup
            usleep(100 * 1000)
            if let r = sendOnce(udid, argv) { return r }
        }
        return (false, "daemon did not start (see ~/.testa/daemon-\(udid).log)")
    }

    static func daemonRunning(_ udid: String) -> Bool {
        let fd = Net.connect(Net.socketPath(udid))
        if fd < 0 { return false }
        close(fd)
        return true
    }
}
