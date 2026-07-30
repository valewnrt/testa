import Foundation
import Darwin
import TestaEngine
import TestaKit

// Backstop so a half-written mp4 never survives a daemon exit. Only ever touched
// from the single daemon thread (and from atexit, after it has stopped).
private nonisolated(unsafe) var activeRecorder: Process?

private func finishActiveRecording() {
    guard let p = activeRecorder else { return }
    activeRecorder = nil
    if p.isRunning { p.interrupt(); p.waitUntilExit() }
}

// Where testa is allowed to write. Screen text (OCR, labels) must never be able
// to steer an agent into clobbering a user's file: the extension has to match and
// an existing file has to look like something testa itself produced.
enum OutPath {
    static func png(_ path: String) -> (String?, String) {
        check(path, exts: ["png"], kind: "PNG") { $0.starts(with: [0x89, 0x50, 0x4E, 0x47]) }
    }

    static func video(_ path: String) -> (String?, String) {
        check(path, exts: ["mp4", "mov"], kind: "MP4/MOV") { d in
            d.count >= 8 && Array(d[4..<8]) == Array("ftyp".utf8)
        }
    }

    private static func check(_ path: String, exts: [String], kind: String,
                              magic: (Data) -> Bool) -> (String?, String) {
        let std = (path as NSString).standardizingPath
        let dir = ((std as NSString).deletingLastPathComponent as NSString).resolvingSymlinksInPath
        let name = (std as NSString).lastPathComponent
        let full = (dir.isEmpty ? "." : dir) + "/" + name
        let want = exts.map { "." + $0 }.joined(separator: " or ")
        guard exts.contains((name as NSString).pathExtension.lowercased()) else {
            return (nil, "refusing to write \(full): expected a \(want) file")
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return (nil, "refusing to write \(full): directory does not exist")
        }
        guard fm.fileExists(atPath: full, isDirectory: &isDir) else { return (full, "") }
        guard !isDir.boolValue else { return (nil, "refusing to write \(full): it is a directory") }
        var d = Data()
        if let fh = FileHandle(forReadingAtPath: full) {
            d = ((try? fh.read(upToCount: 16)) ?? nil) ?? Data()
            try? fh.close()
        }
        guard d.isEmpty || magic(d) else {
            return (nil, "refusing to overwrite \(full): existing file is not a \(kind) — pick another path")
        }
        return (full, "")
    }
}

// The warm daemon. Holds a connected TSTSimulator and the last snapshot (for
// ref resolution + diffing). One command per connection; commands are serialized
// against the single simulator, so no locking is needed.
final class Daemon {
    let sim: TSTSimulator
    var last: Snapshot?
    var recorder: Process?
    var recorderPath: String?
    var lastBundle: String?
    private var lockFD: Int32 = -1

    // --- HID actuation health (see `reviveHIDClient` in the engine) ---
    //
    // A tap can report success and still change nothing: either the tap was
    // legitimately inert, or the HID connection died and the message went
    // nowhere. We cannot tell them apart from one action — but a *streak* of
    // no-op gestures is the signature of a deaf client, so after three in a row
    // we revive before the next one. Cheap (a few ms) and self-limiting.
    static let noopStreakLimit = 3
    private var noopStreak = 0
    private var trackNoop = false      // is the running command HID-driven?
    private var pendingNote = ""       // appended to the next mutating reply

    // --- frontmost app tracking (system alert / SpringBoard detection) ---
    private var frontApp: String?      // label of the root AXApplication
    private var lastUserApp: String?   // last frontmost app that wasn't the shell

    // Command history — what `testa flow record` replays. Always on (a ring of
    // the last 500 commands) so recording is a decision you can make *after* an
    // interesting sequence happened, not before.
    private var history: [[String]] = []
    private var historySeq = 0      // total ever appended (survives ring eviction)
    private var historyMark = 0
    static let historyLimit = 500

    // Daemon housekeeping, not app interaction: never recorded, and answerable
    // even when the simulator underneath has gone away.
    static let unrecorded: Set<String> = ["ping", "info", "stop", "histmark", "histget"]

    init(sim: TSTSimulator) { self.sim = sim }

    struct Reply {
        var ok: Bool
        var text: String
        var exitAfter = false
    }

    // Commands that change the screen — their replies carry the settled UI diff.
    static let mutatingCommands: Set<String> = [
        "tap", "tapocr", "typein", "type", "setvalue", "clear", "key", "swipe",
        "drag", "dragdrop", "longpress", "pinch", "rotate", "scrollto", "scrollTo",
        "button", "keycombo", "statusbar", "appearance", "contentsize", "push",
    ]

    // The subset that actuates the simulator over HID. Only these feed the
    // no-op streak: `statusbar`/`appearance`/`push` legitimately change nothing
    // on screen and must not be read as evidence of a dead HID client.
    static let hidCommands: Set<String> = [
        "tap", "tapocr", "typein", "type", "setvalue", "clear", "key", "swipe",
        "drag", "dragdrop", "longpress", "pinch", "rotate", "scrollto", "scrollTo",
        "button", "keycombo",
    ]

    // One daemon per simulator. Whoever takes the lock binds; a racing spawn exits
    // quietly and its client reaches the winner on the next retry. The fd stays
    // open (and the lock held) for the daemon's lifetime.
    private func acquireSpawnLock() -> Bool {
        let path = "\(Net.socketDir())/daemon-\(sim.udid).lock"
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }  // can't lock: better to serve than to wedge
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
        lockFD = fd
        return true
    }

    func serve() {
        guard acquireSpawnLock() else { return }
        atexit { finishActiveRecording() }
        let path = Net.socketPath(sim.udid)
        let fd = Net.listen(path)
        guard fd >= 0 else {
            FileHandle.standardError.write("testad: cannot bind \(path)\n".data(using: .utf8)!)
            exit(1)
        }
        // Warm the AXPTranslator so the first client call is fast (~66ms not ~3.5s).
        last = try? snapshot()
        FileHandle.standardError.write("testad: ready on \(path) [\(sim.name)]\n".data(using: .utf8)!)

        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { continue }
            // A stalled client can never wedge the accept loop.
            Net.setTimeouts(c, recv: 10, send: 10)
            var quit = false
            if let line = Net.readLine(c) {
                let reply = handle(line)
                quit = reply.exitAfter
                let obj: [String: Any] = ["ok": reply.ok, "text": reply.text]
                if let data = try? JSONSerialization.data(withJSONObject: obj),
                   let s = String(data: data, encoding: .utf8) {
                    Net.writeLine(c, s)
                }
            }
            close(c)  // reply is out and flushed before we go away
            if quit {
                stopRecording()  // finalize the mp4 before we go
                exit(0)
            }
        }
    }

    // --- snapshot helpers ---

    func snapshot() throws -> Snapshot {
        let tree = try sim.accessibilityTree()
        let snap = Snapshot(elements: tree,
                            screenW: Double(sim.screenPointSize.width),
                            screenH: Double(sim.screenPointSize.height))
        // The root AXApplication names whoever owns the screen right now. Track
        // it so `ui` can say when a system alert has taken the app's place.
        if let root = tree.first(where: { ($0["role"] as? String) == "AXApplication" }) {
            let label = ((root["label"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            frontApp = label
            if !Daemon.isSystemShell(label) { lastUserApp = label }
        }
        last = snap
        return snap
    }

    /// SpringBoard (or an unnamed root) owns the screen — i.e. not the app under
    /// test. System alerts (permissions, Face ID, "…would like to…") are hosted
    /// there, and so is the home screen.
    static func isSystemShell(_ appLabel: String) -> Bool {
        appLabel.isEmpty || appLabel.caseInsensitiveCompare("SpringBoard") == .orderedSame
    }

    /// One extra line for the `ui` header when the app under test lost the front.
    func frontmostWarning() -> String? {
        guard let front = frontApp, Daemon.isSystemShell(front),
              let app = lastUserApp, !Daemon.isSystemShell(app) else { return nil }
        return "⚠️ system alert / SpringBoard in front — your app is not frontmost (was \"\(Snapshot.escaped(app, limit: 60))\")"
    }

    /// Taps in the bottom strip race the home-indicator swipe recognizer. We do
    /// not refuse them — plenty of apps put real controls there — but the agent
    /// deserves to know why nothing happened.
    /// 50pt, not the 34pt indicator height: a tap at y=828 on an 874pt screen
    /// (46pt up) was observed backgrounding the app during dogfooding.
    static let homeIndicatorStrip: Double = 50

    static func homeIndicatorWarning(y: Double, screenH h: Double) -> String {
        guard h > 0, y.isFinite, y >= h - homeIndicatorStrip else { return "" }
        return "\n-- warning: tap at y=\(Int(y)) is inside the home-indicator strip "
            + "(screen \(Int(h))pt); it may trigger the home gesture --"
    }

    func homeIndicatorWarning(_ y: Double) -> String {
        Daemon.homeIndicatorWarning(y: y, screenH: Double(sim.screenPointSize.height))
    }

    func currentForResolve() -> Snapshot {
        if let l = last { return l }
        return (try? snapshot()) ?? Snapshot(elements: [])
    }

    // Every mutating reply carries the settled delta, so the agent almost never
    // needs a follow-up `ui` round-trip.
    func withDiff(_ text: String, from prev: Snapshot?, after post: Snapshot? = nil) -> Reply {
        let note = pendingNote
        pendingNote = ""
        guard let prev = prev, let now = post ?? (try? snapshot()) else {
            return Reply(ok: true, text: text + note)
        }
        let d = now.diff(from: prev)
        if d == "(no change)" {
            if trackNoop { noopStreak += 1 }
            return Reply(ok: true, text: text + note + "\n-- no ui change --")
        }
        noopStreak = 0
        let lines = d.split(separator: "\n").map(String.init)
        let shown = lines.count > 30
            ? Array(lines.prefix(30)) + ["(+\(lines.count - 30) more — run `ui` for full state)"]
            : lines
        return Reply(ok: true, text: text + note + "\n-- ui changes --\n" + shown.joined(separator: "\n"))
    }

    // Poll the tree until two consecutive reads are identical (UI quiescent) or
    // the timeout elapses — waits out animations/navigation without guessing.
    func settle(maxMs: Int = 1500) {
        var prev = ""
        let start = Date()
        while Date().timeIntervalSince(start) * 1000 < Double(maxMs) {
            guard let tree = try? sim.accessibilityTree() else { break }
            let sig = "\(tree.count)|" + tree.prefix(80).compactMap {
                ($0["label"] as? String) ?? ($0["value"] as? String) ?? ($0["role"] as? String)
            }.joined(separator: "·")
            if sig == prev && !sig.isEmpty { return }
            prev = sig
            usleep(90 * 1000)
        }
    }

    // Wait (bounded) until the tree actually differs from `prev`. Used where the
    // screen changes owner rather than animating in place (hardware buttons).
    func awaitChange(from prev: Snapshot?, maxMs: Int = 1400) {
        guard let prev = prev else { return }
        let start = Date()
        while Date().timeIntervalSince(start) * 1000 < Double(maxMs) {
            usleep(150 * 1000)
            if let now = try? snapshot(), now.diff(from: prev) != "(no change)" { return }
        }
    }

    // Clamp a user-supplied duration; non-finite / non-positive falls back to `def`.
    static func dur(_ v: Double?, _ def: Double, lo: Double = 0.05, hi: Double = 30) -> Double {
        guard let v = v, v.isFinite, v > 0 else { return def }
        return Swift.min(Swift.max(v, lo), hi)
    }

    // The app's executable (process) name, from its installed Info.plist.
    func appExecutable(_ bundle: String) -> String? {
        let (c, path) = Simctl.run(["get_app_container", sim.udid, bundle, "app"])
        guard c == 0 else { return nil }
        let plist = path.trimmingCharacters(in: .whitespacesAndNewlines) + "/Info.plist"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/libexec/PlistBuddy")
        p.arguments = ["-c", "Print CFBundleExecutable", plist]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let exe = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (exe?.isEmpty == false) ? exe : nil
    }

    // Newest crash report (.ips) for the sim, optionally filtered by process name.
    // The host's DiagnosticReports holds *macOS* crashes (other people's apps), so
    // it is only consulted when we have an executable name to filter by.
    func latestCrash(matching exe: String?) -> (String?, String) {
        let home = NSHomeDirectory()
        var dirs = ["\(home)/Library/Developer/CoreSimulator/Devices/\(sim.udid)/data/Library/Logs/DiagnosticReports"]
        if exe != nil { dirs.append("\(home)/Library/Logs/DiagnosticReports") }
        let fm = FileManager.default
        var candidates: [(String, Date)] = []
        for dir in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where n.hasSuffix(".ips") || n.hasSuffix(".crash") {
                // Reports are named "<exe>-<date>.ips" / "<exe>.<something>" — a bare
                // prefix match would also catch "MyAppHelper".
                if let exe = exe, !(n.hasPrefix(exe + "-") || n.hasPrefix(exe + ".")) { continue }
                let full = dir + "/" + n
                let m = (try? fm.attributesOfItem(atPath: full)[.modificationDate] as? Date) ?? nil
                candidates.append((full, m ?? .distantPast))
            }
        }
        guard let newest = candidates.max(by: { $0.1 < $1.1 })?.0 else { return (nil, "") }
        let content = (try? String(contentsOfFile: newest, encoding: .utf8)) ?? ""
        let head = content.split(separator: "\n").prefix(60).joined(separator: "\n")
        return (newest, head)
    }

    // Installed user apps via `simctl listapps` (old-style plist) -> plutil JSON.
    func userApps() -> [String] {
        let (_, o) = Simctl.run(["listapps", sim.udid])
        let tmp = "\(Net.socketDir())/apps.plist"
        try? o.write(toFile: tmp, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        p.arguments = ["-convert", "json", "-o", "-", "--", tmp]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [] }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [] }
        return obj.compactMap { (bid, v) -> String? in
            guard let dict = v as? [String: Any], (dict["ApplicationType"] as? String) == "User" else { return nil }
            return bid
        }.sorted()
    }

    // Resolve a selector to its element center (for gesture targeting by id/label).
    func center(_ sel: String) -> (Double, Double)? {
        guard let el = currentForResolve().resolve(sel) else { return nil }
        return (Double(el.cx), Double(el.cy))
    }

    /// One matched OCR text region, already reduced to a tap-ready center.
    struct OCRHit {
        let text: String
        let x: Double, y: Double
        var at: String { "@\(Int(x)),\(Int(y))" }
        /// Screen text is untrusted input — render it the same way tree labels are.
        var rendered: String { "\"\(Snapshot.escaped(text))\" \(at)" }
    }

    // OCR fallback matching (works with no app accessibility). Vision misreads a
    // character now and then, so matching degrades gracefully, best tier first:
    // exact -> substring -> punctuation-insensitive -> small edit distance.
    // Pure over the engine's observation dicts, so it is unit-testable.
    static func ocrMatches(_ obs: [[String: Any]], query: String) -> [OCRHit] {
        let q = query.lowercased()
        let qn = normalize(query)
        func text(_ o: [String: Any]) -> String { (o["text"] as? String) ?? "" }

        var order: [Int] = []
        var seen = Set<Int>()
        func tier(_ pred: (String) -> Bool) {
            for (i, o) in obs.enumerated() where !seen.contains(i) && pred(text(o)) {
                seen.insert(i); order.append(i)
            }
        }
        if !q.isEmpty {
            tier { $0.lowercased() == q }
            tier { $0.lowercased().contains(q) }
        }
        if !qn.isEmpty { tier { normalize($0) == qn } }
        if order.isEmpty, query.count >= 5 {
            let budget = Swift.max(1, query.count / 8)
            let qc = Array(q)
            for (i, _) in obs.enumerated()
                .map({ ($0.offset, editDistance(qc, Array(text($0.element).lowercased()))) })
                .filter({ $0.1 <= budget })
                .sorted(by: { $0.1 < $1.1 }) {
                order.append(i)
            }
        }
        return order.compactMap { i -> OCRHit? in
            let o = obs[i]
            guard let t = o["text"] as? String,
                  let x = o["x"] as? Double, let y = o["y"] as? Double,
                  let w = o["w"] as? Double, let h = o["h"] as? Double else { return nil }
            return OCRHit(text: t, x: x + w / 2, y: y + h / 2)
        }
    }

    /// Live OCR of the screen, filtered to `query`. Costs ~300 ms — only call it
    /// when the accessibility tree has already missed.
    func ocrHits(matching query: String) -> [OCRHit] {
        guard let obs = try? sim.recognizeText() else { return [] }
        return Daemon.ocrMatches(obs, query: query)
    }

    func ocrCenter(matching query: String) -> (Double, Double, String)? {
        guard let h = ocrHits(matching: query).first else { return nil }
        return (h.x, h.y, h.text)
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = prev
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = Swift.min(prev[j] + 1, cur[j - 1] + 1,
                                   prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    // Stop the recorder (if any) so the mp4 is finalized; returns its path.
    @discardableResult
    func stopRecording() -> String? {
        guard let p = recorder else { return nil }
        if p.isRunning { p.interrupt(); p.waitUntilExit() }
        let path = recorderPath ?? ""
        recorder = nil; recorderPath = nil; activeRecorder = nil
        return path
    }

    // --- environment helpers ---

    static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // simctl's own content_size vocabulary (plus the two relative moves).
    static let contentSizes = [
        "extra-small", "small", "medium", "large", "extra-large", "extra-extra-large",
        "extra-extra-extra-large", "accessibility-medium", "accessibility-large",
        "accessibility-extra-large", "accessibility-extra-extra-large",
        "accessibility-extra-extra-extra-large", "increment", "decrement",
    ]

    // "9:41" / "21:05" — or an ISO-ish date string, which simctl also accepts.
    static func validClock(_ s: String) -> Bool {
        if s.contains("-") { return s.count >= 8 }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              parts[0].count <= 2, parts[1].count == 2 else { return false }
        return (0...23).contains(h) && (0...59).contains(m)
    }

    // en_US / de-DE / zh_Hans_CN …
    static func validLocale(_ s: String) -> Bool {
        let parts = s.split(whereSeparator: { $0 == "_" || $0 == "-" })
        guard parts.count >= 2, parts.count <= 3 else { return false }
        guard (2...3).contains(parts[0].count), parts[0].allSatisfy({ $0.isLowercase && $0.isLetter })
        else { return false }
        return parts.dropFirst().allSatisfy { p in
            (2...4).contains(p.count) && p.allSatisfy { $0.isLetter || $0.isNumber }
        }
    }

    // Characters the simulator's HID keyboard cannot produce (anything outside
    // printable US-ASCII + tab/newline), de-duplicated, in first-seen order.
    // Mirrors TSTUsageForChar so we can decide *before* typing whether the
    // pasteboard route is needed — half a word then a paste would duplicate text.
    static func untypeable(_ text: String) -> String {
        var seen = Set<Character>()
        var out = ""
        for ch in text {
            var ok = false
            if ch.unicodeScalars.count == 1 {
                let v = ch.unicodeScalars.first!.value
                ok = (v >= 0x20 && v <= 0x7E) || v == 0x09 || v == 0x0A || v == 0x0D
            }
            if !ok, seen.insert(ch).inserted { out.append(ch) }
        }
        return out
    }

    // HID usage + needs-shift for one ASCII character (same table as the engine).
    static func usage(for c: Character) -> (usage: Int32, shift: Bool)? {
        guard let ascii = c.asciiValue else { return nil }
        switch ascii {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return (Int32(0x04 + ascii - UInt8(ascii: "a")), false)
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return (Int32(0x04 + ascii - UInt8(ascii: "A")), true)
        case UInt8(ascii: "1")...UInt8(ascii: "9"): return (Int32(0x1E + ascii - UInt8(ascii: "1")), false)
        default: break
        }
        let plain: [Character: Int32] = [
            "0": 0x27, " ": 0x2C, "\n": 0x28, "\r": 0x28, "\t": 0x2B, "-": 0x2D, "=": 0x2E,
            ".": 0x37, ",": 0x36, "/": 0x38, ";": 0x33, "'": 0x34, "[": 0x2F, "]": 0x30,
            "\\": 0x31, "`": 0x35,
        ]
        if let u = plain[c] { return (u, false) }
        let shifted: [Character: Int32] = [
            "!": 0x1E, "@": 0x1F, "#": 0x20, "$": 0x21, "%": 0x22, "^": 0x23, "&": 0x24,
            "*": 0x25, "(": 0x26, ")": 0x27, "_": 0x2D, "+": 0x2E, "?": 0x38, ":": 0x33,
            "\"": 0x34, "{": 0x2F, "}": 0x30, "|": 0x31, "~": 0x35, "<": 0x36, ">": 0x37,
        ]
        if let u = shifted[c] { return (u, true) }
        return nil
    }

    // "cmd+shift+h" / "ctrl+alt+0x2A" -> (usage, modifier mask).
    // Mask bits: 0 ctrl, 1 shift, 2 alt, 3 cmd (as the engine documents).
    static func parseKeyCombo(_ s: String) -> (usage: Int32, mods: Int32)? {
        let parts = s.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }
        let mods: [String: Int32] = [
            "ctrl": 1 << 0, "control": 1 << 0,
            "shift": 1 << 1,
            "alt": 1 << 2, "opt": 1 << 2, "option": 1 << 2,
            "cmd": 1 << 3, "command": 1 << 3, "meta": 1 << 3, "super": 1 << 3,
        ]
        let named: [String: Int32] = [
            "return": 0x28, "enter": 0x28, "esc": 0x29, "escape": 0x29, "tab": 0x2B,
            "space": 0x2C, "delete": 0x2A, "backspace": 0x2A, "up": 0x52, "down": 0x51,
            "left": 0x50, "right": 0x4F, "home": 0x4A, "end": 0x4D,
        ]
        var mask: Int32 = 0
        for (i, raw) in parts.enumerated() {
            let p = raw.lowercased()
            if i < parts.count - 1 {
                guard let m = mods[p] else { return nil }
                mask |= m
                continue
            }
            // Last token is the key itself: name, single char, or raw usage code.
            if let u = named[p] { return (u, mask) }
            if p.hasPrefix("0x"), let u = Int32(p.dropFirst(2), radix: 16), u > 0, u < 0xFFFF {
                return (u, mask)
            }
            if p.count > 1, let u = Int32(p), u > 0, u < 0xFFFF { return (u, mask) }
            guard raw.count == 1, let k = usage(for: raw.first!) else { return nil }
            return (k.usage, mask | (k.shift ? 1 << 1 : 0))
        }
        return nil  // modifiers only, no key
    }

    // Type `text`, automatically routing through the simulator pasteboard when the
    // HID keyboard cannot represent every character (emoji, accents, CJK …).
    // Returns a note to append to the reply ("" when plain HID typing sufficed).
    func typeSmart(_ text: String) throws -> String {
        let bad = Daemon.untypeable(text)
        if bad.isEmpty {
            var skipped: NSString?
            _ = try sim.type(text, skipped: &skipped)
            let s = (skipped as String?) ?? ""
            if s.isEmpty { return "" }
            // Table drift (should not happen): part of the text is already in the
            // field, so select-all before pasting instead of appending a duplicate.
            return pasteFallback(text, skipped: s, replaceSelection: true)
        }
        return pasteFallback(text, skipped: bad, replaceSelection: false)
    }

    private func pasteFallback(_ text: String, skipped: String, replaceSelection: Bool) -> String {
        let list = skipped.map(String.init).joined(separator: " ")
        let (c, _) = Simctl.run(["pbcopy", sim.udid], stdin: text)
        guard c == 0 else { return " (skipped: \(list))" }
        if replaceSelection { try? sim.pressKey(usage: 0x04, modifiers: 1 << 3) }  // cmd+a
        usleep(80 * 1000)
        guard (try? sim.pressKey(usage: 0x19, modifiers: 1 << 3)) != nil else {    // cmd+v
            return " (skipped: \(list))"
        }
        return " (via paste — contains characters HID can't type: \(list))"
    }

    static func clean(_ sel: String) -> String {
        var s = sel
        if s.hasPrefix("#") { s.removeFirst() }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    // --- command history ---

    private func record(_ argv: [String], ok: Bool) {
        guard let cmd = argv.first, !Daemon.unrecorded.contains(cmd) else { return }
        // A command that failed is not something you want replayed in CI.
        guard ok else { return }
        historySeq += 1
        history.append(argv)
        if history.count > Daemon.historyLimit { history.removeFirst(history.count - Daemon.historyLimit) }
    }

    /// The commands recorded since the last `histmark`, one JSON array per line.
    private func historySinceMark() -> String {
        let evicted = historySeq - history.count
        let start = Swift.max(0, Swift.min(history.count, historyMark - evicted))
        return history[start...].compactMap { argv -> String? in
            guard let d = try? JSONSerialization.data(withJSONObject: argv) else { return nil }
            return String(data: d, encoding: .utf8)
        }.joined(separator: "\n")
    }

    // --- command dispatch ---

    // Every handled command lands in the ring buffer; `dispatch` does the work.
    func handle(_ line: String) -> Reply {
        let reply = dispatch(line)
        if let data = line.data(using: .utf8),
           let argv = (try? JSONSerialization.jsonObject(with: data)) as? [String] {
            record(argv, ok: reply.ok)
        }
        return reply
    }

    func dispatch(_ line: String) -> Reply {
        guard let data = line.data(using: .utf8),
              let argv = (try? JSONSerialization.jsonObject(with: data)) as? [String],
              let cmd = argv.first else {
            return Reply(ok: false, text: "bad request")
        }
        var a = Array(argv.dropFirst())
        // `--ocr` (leading or trailing) forces the OCR path for the three read
        // commands that also have one. Only stripped for those, so `type --ocr`
        // still types the literal text.
        var forceOCR = false
        if ["assert", "wait", "find"].contains(cmd), let i = a.firstIndex(of: "--ocr") {
            forceOCR = true
            a.remove(at: i)
        }
        // Reject NaN/inf outright: "tap nan nan" must not reach the touch pipeline.
        func fin(_ s: String?, _ def: Double) -> Double {
            guard let s = s, let v = Double(s), v.isFinite else { return def }
            return v
        }
        func num(_ i: Int) -> Double { fin(i < a.count ? a[i] : nil, 0) }
        func arg(_ i: Int) -> String? { i < a.count ? a[i] : nil }
        // Optional trailing duration argument, clamped to a sane range.
        func secs(_ i: Int, _ def: Double) -> Double {
            Daemon.dur(arg(i).flatMap { Double($0) }, def)
        }

        do {
            // Resilience: if the bound simulator is gone, exit cleanly so the next
            // CLI/MCP call respawns a fresh daemon (or surfaces a clear error).
            if !Daemon.unrecorded.contains(cmd), !sim.isBooted() {
                return Reply(ok: false,
                             text: "simulator not booted — daemon exiting; reconnect on next call",
                             exitAfter: true)
            }
            // Pre-action state for the reply diff (cheap: usually the cached tree).
            let pre: Snapshot? = Daemon.mutatingCommands.contains(cmd) ? currentForResolve() : nil

            // Actuation self-healing: a run of gestures that all changed nothing
            // is what a dead HID client looks like from the outside. Re-create it
            // before the next one and say so in the reply.
            trackNoop = Daemon.hidCommands.contains(cmd)
            pendingNote = ""
            if trackNoop, noopStreak >= Daemon.noopStreakLimit {
                let n = noopStreak
                noopStreak = 0
                do {
                    try sim.reviveHIDClient()
                    pendingNote = "\n-- note: HID client revived after \(n) no-op actions --"
                } catch {
                    pendingNote = "\n-- note: HID client revive failed: \(error.localizedDescription) --"
                }
            }

            switch cmd {
            case "ping":
                // Liveness alone is a lie when the HID connection has died under
                // us: reads keep answering while gestures go nowhere. Say both.
                return Reply(ok: true, text: "pong \(sim.name) hid=\(sim.isHIDClientHealthy ? "ok" : "stale")")

            case "info":
                return Reply(ok: true, text: "\(sim.name) [\(sim.udid)] \(Int(sim.screenPointSize.width))x\(Int(sim.screenPointSize.height))pt @\(sim.screenScale)x")

            case "ui":
                let prev = last
                let snap = try snapshot()
                if a.contains("diff"), let prev = prev {
                    return Reply(ok: true, text: snap.diff(from: prev))
                }
                let full = a.contains("full")
                let els = full ? snap.all : snap.visible
                var header = "\(els.count) elements" + (full ? " (full tree)" : " (on screen)")
                if let warn = frontmostWarning() { header += " " + warn }
                let body = els.map(snap.line).joined(separator: "\n")
                return Reply(ok: true, text: header + "\n" + body)

            case "scrollto", "scrollTo":
                guard !a.isEmpty else { return Reply(ok: false, text: "scrollTo needs a selector") }
                let sel = a.joined(separator: " ")
                let w = Double(sim.screenPointSize.width)
                let h = Double(sim.screenPointSize.height)
                for _ in 0..<14 {
                    let snap = try snapshot()
                    let el = snap.resolve(sel)
                    if let e = el, e.onScreen {
                        return withDiff("visible \(snap.line(e))", from: pre, after: snap)
                    }
                    // Horizontal carousels/pagers: swipe sideways toward the element.
                    if let e = el, e.x >= w || e.x + e.w <= 0 {
                        let toRight = e.x >= w
                        try sim.swipe(x1: w * (toRight ? 0.8 : 0.2), y1: h / 2,
                                      x2: w * (toRight ? 0.2 : 0.8), y2: h / 2, duration: 0.25)
                    } else {
                        // Decide direction: known-above -> scroll up, else scroll down.
                        let above = el.map { $0.y < 0 } ?? false
                        if above {
                            try sim.swipe(x1: w / 2, y1: h * 0.28, x2: w / 2, y2: h * 0.72, duration: 0.25)
                        } else {
                            try sim.swipe(x1: w / 2, y1: h * 0.72, x2: w / 2, y2: h * 0.28, duration: 0.25)
                        }
                    }
                    usleep(280 * 1000)
                }
                let snap = try snapshot()
                if let el = snap.resolve(sel), el.onScreen {
                    return withDiff("visible \(snap.line(el))", from: pre, after: snap)
                }
                return Reply(ok: false, text: "could not scroll to \(sel)")

            case "clear" where !a.isEmpty:
                let sel = a[0]
                let el = currentForResolve().resolve(sel)
                let ident = el?.id ?? (sel.hasPrefix("#") ? String(sel.dropFirst()) : nil)
                let label = el?.label ?? (!sel.hasPrefix("#") && !sel.hasPrefix("e") ? sel : nil)
                if el != nil { try sim.tap(x: Double(el!.cx), y: Double(el!.cy)); usleep(150 * 1000) }
                try sim.setValue("", identifier: ident, label: label)
                settle()
                return withDiff("cleared \(sel)", from: pre)

            case "find" where !a.isEmpty:
                let query = a.joined(separator: " ")
                let snap = try snapshot()
                let hits = forceOCR ? [] : snap.find(query)
                if !hits.isEmpty { return Reply(ok: true, text: hits.map(snap.line).joined(separator: "\n")) }
                // Tree miss: fall back to on-screen text. Marked `(ocr)` so the
                // agent knows these have no ref, id or role — only coordinates.
                let seen = ocrHits(matching: Daemon.clean(query))
                if !seen.isEmpty {
                    return Reply(ok: true, text: seen.map { "(ocr) \($0.rendered)" }.joined(separator: "\n"))
                }
                return Reply(ok: false, text: "no match")

            case "tap":
                if a.count >= 2, Double(a[0]) != nil, Double(a[1]) != nil {
                    try sim.tap(x: num(0), y: num(1)); settle()
                    return withDiff("tapped @\(Int(num(0))),\(Int(num(1)))" + homeIndicatorWarning(num(1)),
                                    from: pre)
                }
                let sel = a.joined(separator: " ")
                if let el = currentForResolve().resolve(sel) {
                    try sim.tap(x: Double(el.cx), y: Double(el.cy)); settle()
                    return withDiff("tapped \(el.ref) \(el.shortRole) \(el.label ?? el.id ?? "")"
                                    + homeIndicatorWarning(Double(el.cy)), from: pre)
                }
                // Fallback: tap visible text via OCR (no accessibility needed).
                if let h = ocrHits(matching: Daemon.clean(sel)).first {
                    try sim.tap(x: h.x, y: h.y); settle()
                    return withDiff("tapped (ocr) \(h.rendered)" + homeIndicatorWarning(h.y), from: pre)
                }
                return Reply(ok: false, text: "not found: \(sel)")

            case "tapocr" where !a.isEmpty:
                let q = Daemon.clean(a.joined(separator: " "))
                guard let h = ocrHits(matching: q).first else {
                    return Reply(ok: false, text: "no visible text matching: \(q)")
                }
                try sim.tap(x: h.x, y: h.y); settle()
                return withDiff("tapped (ocr) \(h.rendered)" + homeIndicatorWarning(h.y), from: pre)

            case "type" where !a.isEmpty:
                let note = try typeSmart(a.joined(separator: " ")); settle()
                return withDiff("typed" + note, from: pre)

            case "typein" where a.count >= 2:
                guard let el = currentForResolve().resolve(a[0]) else {
                    return Reply(ok: false, text: "not found: \(a[0])")
                }
                try sim.tap(x: Double(el.cx), y: Double(el.cy)); usleep(200 * 1000)
                let note = try typeSmart(a[1...].joined(separator: " ")); settle()
                return withDiff("typed into \(el.ref)" + note, from: pre)

            case "key" where !a.isEmpty:
                try sim.pressKey(usage: Int32(Swift.max(0, Swift.min(num(0), 65535)))); settle()
                return withDiff("key \(a[0])", from: pre)

            case "swipe" where a.count >= 4:
                try sim.swipe(x1: num(0), y1: num(1), x2: num(2), y2: num(3), duration: secs(4, 0.3)); settle()
                return withDiff("swiped", from: pre)

            case "drag", "dragdrop":
                let hold = (cmd == "dragdrop") ? 0.7 : 0.0
                if a.count >= 4, Double(a[0]) != nil {
                    try sim.drag(x1: num(0), y1: num(1), x2: num(2), y2: num(3), hold: hold, move: secs(4, 0.5))
                } else if a.count >= 2, let from = center(a[0]), let to = center(a[1]) {
                    try sim.drag(x1: from.0, y1: from.1, x2: to.0, y2: to.1, hold: hold, move: secs(2, 0.5))
                } else {
                    return Reply(ok: false, text: "drag needs <x1 y1 x2 y2> or <fromSel toSel>")
                }
                settle()
                return withDiff(cmd == "dragdrop" ? "drag-and-dropped" : "dragged", from: pre)

            case "longpress" where !a.isEmpty:
                if a.count >= 2, Double(a[0]) != nil {
                    try sim.longPress(x: num(0), y: num(1),
                                      duration: secs(2, 1.0))
                } else if let p = center(a[0]) {
                    try sim.longPress(x: p.0, y: p.1,
                                      duration: secs(1, 1.0))
                } else { return Reply(ok: false, text: "not found: \(a[0])") }
                settle()
                return withDiff("long-pressed", from: pre)

            case "pinch" where a.count >= 2:
                if a.count >= 3, Double(a[0]) != nil {
                    try sim.pinch(x: num(0), y: num(1), scale: fin(arg(2), 2.0),
                                  duration: secs(3, 0.5))
                } else if let p = center(a[0]) {
                    try sim.pinch(x: p.0, y: p.1, scale: fin(arg(1), 2.0),
                                  duration: secs(2, 0.5))
                } else { return Reply(ok: false, text: "not found: \(a[0])") }
                settle()
                return withDiff("pinched", from: pre)

            case "rotate" where a.count >= 2:
                if a.count >= 3, Double(a[0]) != nil {
                    try sim.rotate(x: num(0), y: num(1), radians: fin(arg(2), 0),
                                   duration: secs(3, 0.5))
                } else if let p = center(a[0]) {
                    try sim.rotate(x: p.0, y: p.1, radians: fin(arg(1), 0),
                                   duration: secs(2, 0.5))
                } else { return Reply(ok: false, text: "not found: \(a[0])") }
                settle()
                return withDiff("rotated", from: pre)

            case "screenshot":
                let (path, why) = OutPath.png(a.first ?? "\(Net.socketDir())/last.png")
                guard let path = path else { return Reply(ok: false, text: why) }
                try sim.screenshot(toPath: path)
                return Reply(ok: true, text: path)

            case "see":
                let obs = try sim.recognizeText()
                if obs.isEmpty { return Reply(ok: true, text: "(no text recognized)") }
                let lines = obs.compactMap { o -> String? in
                    guard let t = o["text"] as? String,
                          let x = o["x"] as? Double, let y = o["y"] as? Double,
                          let w = o["w"] as? Double, let h = o["h"] as? Double else { return nil }
                    return "\"\(t)\" @\(Int(x + w / 2)),\(Int(y + h / 2))"
                }
                return Reply(ok: true, text: "\(lines.count) text regions (OCR)\n" + lines.joined(separator: "\n"))

            case "setvalue" where a.count >= 2:
                let sel = a[0]
                let text = a[1...].joined(separator: " ")
                let el = currentForResolve().resolve(sel)
                let ident = el?.id ?? (sel.hasPrefix("#") ? String(sel.dropFirst()) : nil)
                let label = el?.label ?? (!sel.hasPrefix("#") && !sel.hasPrefix("e") ? sel : nil)
                if el != nil { try sim.tap(x: Double(el!.cx), y: Double(el!.cy)); usleep(150 * 1000) }
                try sim.setValue(text, identifier: ident, label: label)
                settle()
                return withDiff("set value of \(sel)", from: pre)

            // The accessibility tree is the fast, precise source; on-screen text
            // is the fallback that keeps OCR-only apps verifiable and not just
            // drivable. Every reply names the source it used — (tree) or (ocr).
            case "assert" where !a.isEmpty:
                let snap = try snapshot()
                let sel = a[0]
                let cond = a.count >= 2 ? a[1...].joined(separator: " ") : "exists"
                let el = forceOCR ? nil : snap.resolve(sel)
                if cond == "gone" {
                    if let el = el { return Reply(ok: false, text: "FAIL still present (tree) \(snap.line(el))") }
                    // "gone" has to clear both sources, or an OCR-only element
                    // would silently count as absent.
                    if let h = ocrHits(matching: Daemon.clean(sel)).first {
                        return Reply(ok: false, text: "FAIL still present (ocr) \(h.rendered)")
                    }
                    return Reply(ok: true, text: "PASS gone \(sel)")
                }
                // value=/label= are properties of a tree node; OCR has neither.
                if cond.hasPrefix("value=") {
                    let want = String(cond.dropFirst(6))
                    let got = el?.value ?? ""
                    return got == want ? Reply(ok: true, text: "PASS value \(want)") : Reply(ok: false, text: "FAIL value got \"\(got)\" want \"\(want)\"")
                }
                if cond.hasPrefix("label=") {
                    let want = String(cond.dropFirst(6))
                    let got = el?.label ?? ""
                    return got == want ? Reply(ok: true, text: "PASS label \(want)") : Reply(ok: false, text: "FAIL label got \"\(got)\" want \"\(want)\"")
                }
                if let el = el { return Reply(ok: true, text: "PASS exists (tree) \(snap.line(el))") }
                if let h = ocrHits(matching: Daemon.clean(sel)).first {
                    return Reply(ok: true, text: "PASS exists (ocr) \(h.rendered)")
                }
                return Reply(ok: false, text: "FAIL not found \(sel)")

            case "wait" where !a.isEmpty:
                let sel = a[0]
                var rest = Array(a.dropFirst())
                let gone = rest.first?.lowercased() == "gone"
                if gone { rest.removeFirst() }
                let timeout = Swift.min(Swift.max(fin(rest.first, 5000), 0), 60_000)
                let start = Date()
                // Tree polls are ~60 ms, an OCR pass ~300 ms — so poll the tree
                // hot and only reach for OCR when the tree keeps missing.
                var nextOCR = Date.distantPast
                repeat {
                    let snap = try snapshot()
                    let el = forceOCR ? nil : snap.resolve(sel)
                    if !gone, let el = el { return Reply(ok: true, text: "appeared (tree) \(snap.line(el))") }
                    var ocrChecked = false
                    var ocrHit: OCRHit? = nil
                    if el == nil, Date() >= nextOCR {
                        ocrChecked = true
                        nextOCR = Date().addingTimeInterval(0.5)
                        ocrHit = ocrHits(matching: Daemon.clean(sel)).first
                    }
                    if !gone, let h = ocrHit { return Reply(ok: true, text: "appeared (ocr) \(h.rendered)") }
                    if gone, el == nil, ocrChecked, ocrHit == nil {
                        return Reply(ok: true, text: "gone \(sel)")
                    }
                    usleep(120 * 1000)
                } while Date().timeIntervalSince(start) * 1000 < timeout
                return Reply(ok: false, text: "timeout waiting for \(sel)\(gone ? " to disappear" : "")")

            // Accessibility audit over the full tree — a free byproduct of the
            // data every other command already reads. Not in `mutatingCommands`
            // (it changes nothing, so no "-- ui changes --" tail) and not in
            // `unrecorded`: a recorded flow should keep the gate.
            case "audit":
                let snap = try snapshot()
                let findings = AuditModel.audit(snap)
                let errors = findings.filter { $0.severity == .error }.count
                // ok:false on any error, so `audit` gates a flow / CI run exactly
                // the way `assert` does.
                return Reply(ok: errors == 0, text: AuditModel.report(snap, findings: findings))

            // Visual regression against a stored baseline. First run bootstraps
            // the baseline; later runs compare and write a heatmap next to it.
            case "vdiff" where !a.isEmpty:
                let (checked, why) = OutPath.png(a[0])
                guard let basePath = checked else { return Reply(ok: false, text: why) }
                let tol = Swift.min(Swift.max(fin(arg(1), 1.0), 0), 100)
                guard FileManager.default.fileExists(atPath: basePath) else {
                    try sim.screenshot(toPath: basePath)
                    return Reply(ok: true, text: "baseline saved → \(basePath)")
                }
                let (curChecked, curWhy) = OutPath.png("\(Net.socketDir())/vdiff-current.png")
                guard let curPath = curChecked else { return Reply(ok: false, text: curWhy) }
                let (diffChecked, diffWhy) = OutPath.png((basePath as NSString).deletingPathExtension + ".diff.png")
                guard let diffPath = diffChecked else { return Reply(ok: false, text: diffWhy) }
                try sim.screenshot(toPath: curPath)
                let vd = VDiff.compare(baseline: basePath, current: curPath,
                                       diffPath: diffPath, tolerancePct: tol)
                return Reply(ok: vd.ok, text: vd.text)

            case "install" where !a.isEmpty:
                let (c, o) = Simctl.run(["install", sim.udid, a[0]])
                return Reply(ok: c == 0, text: c == 0 ? "installed \(a[0])" : o)

            case "launch" where !a.isEmpty:
                // launch <bundle> [--env K=V ...] [--args ...]; anything else is
                // forwarded to simctl untouched (so plain `launch <bundle>` is
                // byte-for-byte the old behaviour).
                var passthrough: [String] = []
                var launchArgs: [String] = []
                var childEnv: [String: String] = [:]
                var i = 0
                while i < a.count {
                    if a[i] == "--env" {
                        guard i + 1 < a.count else { return Reply(ok: false, text: "--env needs K=V") }
                        let kv = a[i + 1]
                        guard let eq = kv.firstIndex(of: "="), eq != kv.startIndex else {
                            return Reply(ok: false, text: "--env expects K=V (got \"\(kv)\")")
                        }
                        // simctl passes SIMCTL_CHILD_<K> through to the app as <K>.
                        childEnv["SIMCTL_CHILD_" + String(kv[..<eq])] = String(kv[kv.index(after: eq)...])
                        i += 2
                    } else if a[i] == "--args" {
                        launchArgs = Array(a[(i + 1)...])
                        break
                    } else {
                        passthrough.append(a[i]); i += 1
                    }
                }
                guard let bundle = passthrough.first(where: { !$0.hasPrefix("-") }) else {
                    return Reply(ok: false, text: "launch needs a bundle id")
                }
                let (c, o) = Simctl.run(["launch", sim.udid] + passthrough + launchArgs,
                                        env: childEnv.isEmpty ? nil : childEnv)
                if c == 0 { lastBundle = bundle }
                var text = Daemon.trim(o)
                if c == 0, !childEnv.isEmpty || !launchArgs.isEmpty {
                    let bits = childEnv.keys.sorted().map { String($0.dropFirst("SIMCTL_CHILD_".count)) }
                    if !bits.isEmpty { text += "\nenv: \(bits.joined(separator: ", "))" }
                    if !launchArgs.isEmpty { text += "\nargs: \(launchArgs.joined(separator: " "))" }
                }
                return Reply(ok: c == 0, text: text)

            case "push" where a.count >= 2:
                let bundle = a[0]
                let payload = a[1...].joined(separator: " ")
                var file: String
                if Daemon.trim(payload).hasPrefix("{") {
                    file = "\(Net.socketDir())/push.json"
                    do { try payload.write(toFile: file, atomically: true, encoding: .utf8) }
                    catch { return Reply(ok: false, text: "could not write \(file): \(error.localizedDescription)") }
                } else {
                    file = (payload as NSString).standardizingPath
                    guard FileManager.default.fileExists(atPath: file) else {
                        return Reply(ok: false, text: "no such payload: \(file) — pass a .json/.apns path or inline JSON starting with {")
                    }
                }
                guard let pd = FileManager.default.contents(atPath: file),
                      let obj = (try? JSONSerialization.jsonObject(with: pd)) as? [String: Any] else {
                    return Reply(ok: false, text: "push payload is not a JSON object: \(file)")
                }
                guard obj["aps"] != nil else {
                    return Reply(ok: false, text: "push payload has no \"aps\" key — e.g. {\"aps\":{\"alert\":{\"title\":\"Hi\",\"body\":\"There\"}}}")
                }
                let (pc, po) = Simctl.run(["push", sim.udid, bundle, file])
                guard pc == 0 else { return Reply(ok: false, text: Daemon.trim(po)) }
                settle()
                return withDiff("pushed to \(bundle)", from: pre)

            case "location" where !a.isEmpty:
                if a[0].lowercased() == "clear" {
                    let (c, o) = Simctl.run(["location", sim.udid, "clear"])
                    return Reply(ok: c == 0, text: c == 0 ? "location cleared" : Daemon.trim(o))
                }
                guard a.count >= 2, let lat = Double(a[0]), let lon = Double(a[1]),
                      lat.isFinite, lon.isFinite else {
                    return Reply(ok: false, text: "location needs <lat> <lon> (or `location clear`)")
                }
                guard (-90...90).contains(lat) else {
                    return Reply(ok: false, text: "latitude out of range: \(lat) (want -90..90)")
                }
                guard (-180...180).contains(lon) else {
                    return Reply(ok: false, text: "longitude out of range: \(lon) (want -180..180)")
                }
                let (c, o) = Simctl.run(["location", sim.udid, "set", "\(lat),\(lon)"])
                return Reply(ok: c == 0, text: c == 0 ? "location set to \(lat),\(lon)" : Daemon.trim(o))

            case "statusbar" where !a.isEmpty:
                if a[0].lowercased() == "clear" {
                    let (c, o) = Simctl.run(["status_bar", sim.udid, "clear"])
                    guard c == 0 else { return Reply(ok: false, text: Daemon.trim(o)) }
                    return withDiff("status bar overrides cleared", from: pre)
                }
                var flags: [String] = []
                var shown: [String] = []
                var j = 0
                while j < a.count {
                    let k = a[j].lowercased()
                    guard j + 1 < a.count else {
                        return Reply(ok: false, text: "statusbar \(k) needs a value")
                    }
                    let v = a[j + 1]
                    j += 2
                    switch k {
                    case "time":
                        guard Daemon.validClock(v) else {
                            return Reply(ok: false, text: "statusbar time wants HH:MM (e.g. 9:41) or an ISO date")
                        }
                        flags += ["--time", v]; shown.append("time \(v)")
                    case "battery":
                        guard let n = Int(v), (0...100).contains(n) else {
                            return Reply(ok: false, text: "statusbar battery wants 0-100 (got \"\(v)\")")
                        }
                        flags += ["--batteryLevel", "\(n)"]; shown.append("battery \(n)%")
                        if j < a.count,
                           ["charging", "discharging", "charged"].contains(a[j].lowercased()) {
                            flags += ["--batteryState", a[j].lowercased()]
                            shown.append(a[j].lowercased()); j += 1
                        }
                    case "wifi":
                        guard let n = Int(v), (0...3).contains(n) else {
                            return Reply(ok: false, text: "statusbar wifi wants 0-3 bars (got \"\(v)\")")
                        }
                        flags += ["--wifiBars", "\(n)"]; shown.append("wifi \(n)")
                    case "cell", "cellular":
                        guard let n = Int(v), (0...4).contains(n) else {
                            return Reply(ok: false, text: "statusbar cell wants 0-4 bars (got \"\(v)\")")
                        }
                        flags += ["--cellularBars", "\(n)"]; shown.append("cell \(n)")
                    default:
                        return Reply(ok: false, text: "statusbar: unknown key \"\(k)\" — want time|battery|wifi|cell|clear")
                    }
                }
                let (sc, so) = Simctl.run(["status_bar", sim.udid, "override"] + flags)
                guard sc == 0 else { return Reply(ok: false, text: Daemon.trim(so)) }
                return withDiff("status bar: " + shown.joined(separator: ", "), from: pre)

            case "appearance" where !a.isEmpty:
                let want = a[0].lowercased()
                guard want == "dark" || want == "light" else {
                    return Reply(ok: false, text: "appearance wants dark or light (got \"\(a[0])\")")
                }
                let (c, o) = Simctl.run(["ui", sim.udid, "appearance", want])
                guard c == 0 else { return Reply(ok: false, text: Daemon.trim(o)) }
                settle()
                return withDiff("appearance \(want)", from: pre)

            case "contentsize" where !a.isEmpty:
                let want = a[0].lowercased()
                guard Daemon.contentSizes.contains(want) else {
                    return Reply(ok: false, text: "unknown content size \"\(a[0])\" — want one of:\n  "
                                 + Daemon.contentSizes.joined(separator: ", "))
                }
                let (c, o) = Simctl.run(["ui", sim.udid, "content_size", want])
                guard c == 0 else { return Reply(ok: false, text: Daemon.trim(o)) }
                settle()
                return withDiff("content size \(want)", from: pre)

            case "locale" where !a.isEmpty:
                let id = a[0]
                guard Daemon.validLocale(id) else {
                    return Reply(ok: false, text: "locale id should look like en_US or de-DE (got \"\(id)\")")
                }
                let lang = a.count >= 2 ? a[1]
                    : String(id.prefix { $0 != "_" && $0 != "-" })
                let (c1, o1) = Simctl.run(["spawn", sim.udid, "defaults", "write",
                                           "Apple Global Domain", "AppleLocale", "-string", id])
                guard c1 == 0 else { return Reply(ok: false, text: Daemon.trim(o1)) }
                let (c2, o2) = Simctl.run(["spawn", sim.udid, "defaults", "write",
                                           "Apple Global Domain", "AppleLanguages", "-array", lang])
                guard c2 == 0 else { return Reply(ok: false, text: Daemon.trim(o2)) }
                return Reply(ok: true, text: """
                    locale \(id), language \(lang)
                    note: already-running apps must be relaunched (testa terminate <bundle> && \
                    testa launch <bundle>) to pick this up; some SpringBoard UI only changes \
                    after a simulator reboot.
                    """)

            case "addmedia" where !a.isEmpty:
                var paths: [String] = []
                for p in a {
                    let full = (p as NSString).standardizingPath
                    guard FileManager.default.fileExists(atPath: full) else {
                        return Reply(ok: false, text: "no such file: \(full)")
                    }
                    paths.append(full)
                }
                let (c, o) = Simctl.run(["addmedia", sim.udid] + paths)
                return Reply(ok: c == 0,
                             text: c == 0 ? "added \(paths.count) file\(paths.count == 1 ? "" : "s") to Photos"
                                          : Daemon.trim(o))

            case "pbcopy" where !a.isEmpty:
                let text = a.joined(separator: " ")
                let (c, o) = Simctl.run(["pbcopy", sim.udid], stdin: text)
                return Reply(ok: c == 0,
                             text: c == 0 ? "copied \(text.count) chars to the simulator pasteboard"
                                          : Daemon.trim(o))

            case "pbpaste":
                let (c, o) = Simctl.run(["pbpaste", sim.udid])
                guard c == 0 else { return Reply(ok: false, text: Daemon.trim(o)) }
                return Reply(ok: true, text: o.isEmpty ? "(pasteboard empty)" : o)

            case "biometry" where !a.isEmpty:
                let enrollKey = "com.apple.BiometricKit.enrollmentChanged"
                var args: [String]
                var note: String
                switch a[0].lowercased() {
                case "enroll":
                    args = ["-s", enrollKey, "1", "-p", enrollKey]
                    note = "biometry enrolled — an app only sees this when it re-queries (relaunch or re-enter the flow if it cached the state)"
                case "unenroll":
                    args = ["-s", enrollKey, "0", "-p", enrollKey]
                    note = "biometry unenrolled — an app only sees this when it re-queries (relaunch or re-enter the flow if it cached the state)"
                case "match":
                    args = ["-p", "com.apple.BiometricKit_Sim.fingerTouch.match"]
                    note = "sent matching biometry — only has an effect while a Face ID / Touch ID prompt is on screen"
                case "nomatch":
                    args = ["-p", "com.apple.BiometricKit_Sim.fingerTouch.nomatch"]
                    note = "sent non-matching biometry — only has an effect while a Face ID / Touch ID prompt is on screen"
                default:
                    return Reply(ok: false, text: "biometry wants enroll, unenroll, match or nomatch")
                }
                let (c, o) = Simctl.run(["spawn", sim.udid, "notifyutil"] + args)
                return Reply(ok: c == 0, text: c == 0 ? note : Daemon.trim(o))

            case "button" where !a.isEmpty:
                let name = a[0].lowercased()
                guard ["home", "lock", "power", "side", "siri", "apple-pay", "applepay"].contains(name) else {
                    return Reply(ok: false, text: "button wants home, lock, siri or apple-pay (got \"\(a[0])\")")
                }
                try sim.pressButton(name)
                // Home/lock hand off to SpringBoard: for a while the tree is still
                // the outgoing app and perfectly quiescent, so settle() alone would
                // snapshot the old screen. Wait (bounded) for the switch to land.
                awaitChange(from: pre)
                settle()
                return withDiff("pressed \(name) button", from: pre)

            case "keycombo" where !a.isEmpty:
                let combo = a.joined(separator: "").lowercased()
                guard let k = Daemon.parseKeyCombo(combo) else {
                    return Reply(ok: false, text: "cannot parse key combo \"\(combo)\" — want e.g. cmd+a, cmd+shift+h, ctrl+alt+delete, cmd+0x2A")
                }
                try sim.pressKey(usage: k.usage, modifiers: k.mods); settle()
                return withDiff("pressed \(combo)", from: pre)

            case "logs":
                var seconds = 20
                var bundle = lastBundle
                for x in a { if let n = Int(x) { seconds = n } else { bundle = x } }
                guard let b = bundle else { return Reply(ok: false, text: "no app launched yet — pass a bundle id: testa logs <bundle> [seconds]") }
                guard let exe = appExecutable(b) else { return Reply(ok: false, text: "app not installed: \(b)") }
                // The predicate is a quoted string: an exe name with " or \ must not break out.
                let esc = exe.replacingOccurrences(of: "\\", with: "\\\\")
                             .replacingOccurrences(of: "\"", with: "\\\"")
                let (_, o) = Simctl.run(["spawn", sim.udid, "log", "show", "--style", "compact",
                                         "--last", "\(seconds)s", "--predicate", "process == \"\(esc)\""])
                let lines = o.split(separator: "\n", omittingEmptySubsequences: true)
                    .filter { !$0.contains("getpwuid_r did not find") }
                    .suffix(120).map { String($0.prefix(300)) }
                return Reply(ok: true, text: lines.isEmpty ? "(no logs for \(exe) in last \(seconds)s)" : lines.joined(separator: "\n"))

            case "crashes":
                let bundle = a.first ?? lastBundle
                let exe = bundle.flatMap { appExecutable($0) }
                let (path, body) = latestCrash(matching: exe)
                if path == nil { return Reply(ok: true, text: "(no crash reports\(exe.map { " for \($0)" } ?? ""))") }
                return Reply(ok: true, text: "\(path!)\n\n\(body)")

            case "terminate" where !a.isEmpty:
                let (c, o) = Simctl.run(["terminate", sim.udid, a[0]])
                return Reply(ok: c == 0, text: c == 0 ? "terminated \(a[0])" : o)

            case "apps":
                let ids = userApps()
                return Reply(ok: true, text: ids.isEmpty ? "(no user apps)" : ids.joined(separator: "\n"))

            case "open" where !a.isEmpty:
                let (c, o) = Simctl.run(["openurl", sim.udid, a[0]])
                return Reply(ok: c == 0, text: c == 0 ? "opened \(a[0])" : o)

            case "permission" where a.count >= 3:
                let (c, o) = Simctl.run(["privacy", sim.udid, a[0], a[1], a[2]])
                return Reply(ok: c == 0, text: c == 0 ? "\(a[0]) \(a[1]) for \(a[2])" : o)

            case "record" where !a.isEmpty:
                if a[0] == "start" {
                    if recorder != nil { return Reply(ok: false, text: "already recording") }
                    let (checked, why) = OutPath.video(a.count >= 2 ? a[1] : "\(Net.socketDir())/recording.mp4")
                    guard let path = checked else { return Reply(ok: false, text: why) }
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                    p.arguments = ["simctl", "io", sim.udid, "recordVideo", "--codec=h264", "--force", path]
                    p.standardInput = FileHandle.nullDevice
                    p.standardOutput = FileHandle.nullDevice
                    p.standardError = FileHandle.nullDevice
                    try p.run()
                    recorder = p; recorderPath = path; activeRecorder = p
                    return Reply(ok: true, text: "recording -> \(path)")
                } else {
                    guard let path = stopRecording() else { return Reply(ok: false, text: "not recording") }
                    return Reply(ok: true, text: "saved \(path)")
                }

            case "histmark":
                historyMark = historySeq
                return Reply(ok: true, text: "recording from here")

            case "histget":
                let text = historySinceMark()
                return Reply(ok: true, text: text)

            case "stop":
                return Reply(ok: true, text: "stopping", exitAfter: true)

            // Reached only when the guarded cases above rejected the arg count —
            // one line of usage beats a generic "unknown command".
            case "push", "location", "statusbar", "appearance", "contentsize",
                 "locale", "addmedia", "pbcopy", "biometry", "button", "keycombo", "vdiff":
                let hint = [
                    "vdiff": "vdiff <baseline.png> [tolerancePct]  (first run saves the baseline)",
                    "push": "push <bundle> <payload.json | inline JSON with an \"aps\" key>",
                    "location": "location <lat> <lon>  |  location clear",
                    "statusbar": "statusbar time <HH:MM> | battery <0-100> [charging|discharging|charged] | wifi <0-3> | cell <0-4> | clear",
                    "appearance": "appearance <dark|light>",
                    "contentsize": "contentsize <size|increment|decrement>",
                    "locale": "locale <en_US> [lang]",
                    "addmedia": "addmedia <file.png|jpg|mp4 ...>",
                    "pbcopy": "pbcopy <text>",
                    "biometry": "biometry <enroll|unenroll|match|nomatch>",
                    "button": "button <home|lock|siri|apple-pay>",
                    "keycombo": "keycombo <cmd+a | cmd+shift+h | ctrl+alt+delete>",
                ][cmd] ?? cmd
                return Reply(ok: false, text: "usage: testa \(hint)")

            default:
                return Reply(ok: false, text: "unknown command: \(cmd)")
            }
        } catch {
            return Reply(ok: false, text: "error: \(error.localizedDescription)")
        }
    }
}
