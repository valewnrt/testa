import Foundation
import Darwin
import TestaKit

// Deterministic replay. An agent explores a screen once, saves what it did as a
// .flow file, and CI runs it forever after with zero LLM tokens:
//
//   testa flow run smoke.flow --junit results.xml
//   testa matrix "iPhone 14 Pro,iPhone 16 Pro" -- flow run smoke.flow
//
// Every line of a .flow file is a testa command, so the format needs no docs
// beyond `testa help`. Parsing and reporting live in TestaKit/FlowModel.swift;
// this file is the I/O half — sockets, files, threads.

// stdout from several device threads at once: one whole line at a time.
final class FlowOut: @unchecked Sendable {
    static let shared = FlowOut()
    private let lock = NSLock()

    func line(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        print(s)
        fflush(stdout)
    }

    func errLine(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }
}

struct FlowRunOptions: Sendable {
    var files: [String] = []
    var junit: String? = nil
    var artifacts = "./testa-artifacts"
    var quiet = false
}

// A single device's worth of work. Value type with only Sendable members, so
// `matrix` can hand one to each thread without sharing anything mutable.
struct FlowRunner: Sendable {
    let udid: String
    /// "" for a plain run, "iPhone 14 Pro" under `matrix`.
    let device: String
    let opts: FlowRunOptions

    private var tag: String { device.isEmpty ? "" : "[\(device)] " }
    private func suite(_ flowName: String) -> String {
        device.isEmpty ? flowName : "\(device) / \(flowName)"
    }

    func runAll() -> [FlowResult] {
        opts.files.map(run(file:))
    }

    // MARK: one flow

    private func run(file: String) -> FlowResult {
        let started = Date()
        let path = (file as NSString).standardizingPath
        let name = Flow.stem(of: path)

        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return fail(name: name, file: path, line: 1, raw: file,
                        message: "cannot read flow file: \(path)", started: started)
        }
        let flow: Flow
        do { flow = try Flow.parse(text: text, filename: path) }
        catch let e as FlowParseError {
            return fail(name: name, file: path, line: e.line, raw: "(parse error)",
                        message: e.message, started: started)
        } catch {
            return fail(name: name, file: path, line: 1, raw: "(parse error)",
                        message: error.localizedDescription, started: started)
        }

        // @require: a missing app is a setup mistake, not a test failure — say so
        // before burning a minute of taps against the wrong screen.
        if let bad = missingRequirement(flow) {
            let step = FlowStep(line: bad.line, raw: "@require \(bad.bundleId)", argv: [])
            let msg = "app not installed: \(bad.bundleId) — install it first (testa install <path.app>)"
            if !opts.quiet { FlowOut.shared.line("\(tag)✗ L\(bad.line) @require \(bad.bundleId) — \(msg)") }
            let r = FlowResult(suite: suite(flow.name), flowName: flow.name, file: path,
                               steps: [StepResult(step: step, status: .failed, message: msg, durationMs: 0)],
                               durationMs: ms(since: started), startedAt: started)
            FlowOut.shared.line(tag + r.summaryLine)
            return r
        }

        var results: [StepResult] = []
        var artifactsDir: String? = nil
        var failedAt: Int? = nil

        for step in flow.steps {
            if failedAt != nil {
                results.append(StepResult(step: step, status: .skipped,
                                          message: "skipped after failure at L\(failedAt!)", durationMs: 0))
                continue
            }
            let t0 = Date()
            let (ok, reply) = Client.send(udid, step.argv)
            let took = ms(since: t0)
            if ok {
                results.append(StepResult(step: step, status: .passed, message: reply, durationMs: took))
                if !opts.quiet { FlowOut.shared.line("\(tag)✓ L\(step.line) \(step.raw) (\(took)ms)") }
            } else {
                results.append(StepResult(step: step, status: .failed, message: reply, durationMs: took))
                let first = reply.split(separator: "\n").first.map(String.init) ?? "failed"
                FlowOut.shared.line("\(tag)✗ L\(step.line) \(step.raw) — \(first)")
                failedAt = step.line
                artifactsDir = capture(flow: flow, step: step, reply: reply)
                if let d = artifactsDir { FlowOut.shared.line("\(tag)artifacts → \(d)") }
            }
        }

        let r = FlowResult(suite: suite(flow.name), flowName: flow.name, file: path,
                           steps: results, durationMs: ms(since: started),
                           startedAt: started, artifactsDir: artifactsDir)
        FlowOut.shared.line(tag + r.summaryLine)
        return r
    }

    private func fail(name: String, file: String, line: Int, raw: String,
                      message: String, started: Date) -> FlowResult {
        FlowOut.shared.line("\(tag)✗ L\(line) \(raw) — \(message)")
        let step = FlowStep(line: line, raw: raw, argv: [])
        let r = FlowResult(suite: suite(name), flowName: name, file: file,
                           steps: [StepResult(step: step, status: .failed, message: message, durationMs: 0)],
                           durationMs: ms(since: started), startedAt: started)
        FlowOut.shared.line(tag + r.summaryLine)
        return r
    }

    private func ms(since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }

    private func missingRequirement(_ flow: Flow) -> FlowRequire? {
        guard !flow.requires.isEmpty else { return nil }
        let (ok, text) = Client.send(udid, ["apps"])
        guard ok else { return flow.requires.first }
        let installed = Set(text.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        })
        return flow.requires.first { !installed.contains($0.bundleId) }
    }

    // MARK: failure artifacts

    /// Everything a human (or an agent) needs to explain the failure, captured
    /// at the moment it happened. Best-effort per file — a screenshot that fails
    /// is a note in summary.txt, never a second failure.
    private func capture(flow: Flow, step: FlowStep, reply: String) -> String? {
        let base = (opts.artifacts as NSString).standardizingPath
        let dir = base + "/" + slug(flow.name) + "-\(step.line)"
        let fm = FileManager.default
        guard (try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)) != nil else {
            FlowOut.shared.errLine("\(tag)could not create artifacts dir \(dir)")
            return nil
        }

        var notes: [String] = []
        var saved: [String] = []

        // The screenshot is written by the daemon (it owns the simulator).
        let png = dir + "/screenshot.png"
        let (sok, stext) = Client.send(udid, ["screenshot", png])
        if sok, fm.fileExists(atPath: png) { saved.append("screenshot.png") }
        else { notes.append("screenshot.png: \(stext)") }

        for (fileName, argv) in [("ui-full.txt", ["ui", "full"]),
                                 ("see.txt", ["see"]),
                                 ("logs.txt", ["logs"]),
                                 ("crashes.txt", ["crashes"])] {
            let (ok, text) = Client.send(udid, argv)
            guard ok else { notes.append("\(fileName): \(text)"); continue }
            do {
                try text.write(toFile: dir + "/" + fileName, atomically: true, encoding: .utf8)
                saved.append(fileName)
            } catch {
                notes.append("\(fileName): \(error.localizedDescription)")
            }
        }

        var summary = """
            flow:   \(flow.name)
            file:   \(flow.file)
            device: \(device.isEmpty ? udid : "\(device) [\(udid)]")
            when:   \(ISO8601DateFormatter().string(from: Date()))

            failed step:
              L\(step.line)  \(step.raw)

            reply:
            \(reply)

            captured:
            """
        summary += "\n" + saved.map { "  \(dir)/\($0)" }.joined(separator: "\n")
        if !notes.isEmpty {
            summary += "\n\nnot captured:\n" + notes.map { "  \($0)" }.joined(separator: "\n")
        }
        try? (summary + "\n").write(toFile: dir + "/summary.txt", atomically: true, encoding: .utf8)
        return dir
    }

    private func slug(_ s: String) -> String {
        let cleaned = String(s.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
        return cleaned.isEmpty ? "flow" : cleaned
    }
}

// Collects per-device results from parallel threads.
final class FlowCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Int, [FlowResult])] = []

    func add(_ index: Int, _ results: [FlowResult]) {
        lock.lock(); items.append((index, results)); lock.unlock()
    }

    var ordered: [FlowResult] {
        lock.lock(); defer { lock.unlock() }
        return items.sorted { $0.0 < $1.0 }.flatMap { $0.1 }
    }
}

enum FlowCLI {
    static let runUsage = """
        usage:
          testa flow run <file.flow ...> [--junit <out.xml>] [--artifacts <dir>] [--quiet]
          testa flow record start
          testa flow record save <file.flow> [--all]
          testa matrix "<device1,device2,…>" -- flow run <file.flow ...> [options]
        """

    // MARK: testa flow …

    static func flow(_ argv: [String], explicitUDID: String?) -> Never {
        guard let sub = argv.first else { out(runUsage); exit(0) }
        switch sub {
        case "run":
            let opts = parseRunOptions(Array(argv.dropFirst()))
            guard !opts.files.isEmpty else { err("flow run needs at least one .flow file\n" + runUsage); exit(2) }
            let udid = requireUDID(explicitUDID)
            let results = FlowRunner(udid: udid, device: "", opts: opts).runAll()
            writeJUnit(results, to: opts.junit)
            exit(results.allSatisfy { $0.passed } ? 0 : 1)

        case "record":
            recordCommand(Array(argv.dropFirst()), explicitUDID: explicitUDID)

        case "help", "-h", "--help":
            out(runUsage); exit(0)

        default:
            err("unknown flow subcommand \"\(sub)\"\n" + runUsage); exit(2)
        }
    }

    static func parseRunOptions(_ argv: [String]) -> FlowRunOptions {
        var o = FlowRunOptions()
        var i = 0
        while i < argv.count {
            switch argv[i] {
            case "--junit" where i + 1 < argv.count:
                o.junit = argv[i + 1]; i += 2
            case "--artifacts" where i + 1 < argv.count:
                o.artifacts = argv[i + 1]; i += 2
            case "--quiet", "-q":
                o.quiet = true; i += 1
            default:
                o.files.append(argv[i]); i += 1
            }
        }
        return o
    }

    static func writeJUnit(_ results: [FlowResult], to path: String?) {
        guard let path = path else { return }
        let full = (path as NSString).standardizingPath
        let dir = (full as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let xml = FlowReport.junitXML(results: results)
        do {
            try xml.write(toFile: full, atomically: true, encoding: .utf8)
            FlowOut.shared.line("junit → \(full)")
        } catch {
            FlowOut.shared.errLine("could not write \(full): \(error.localizedDescription)")
        }
    }

    // MARK: testa flow record …

    static func recordCommand(_ argv: [String], explicitUDID: String?) -> Never {
        let udid = requireUDID(explicitUDID)
        switch argv.first {
        case "start":
            let (ok, text) = Client.send(udid, ["histmark"])
            if !ok { err(text); exit(1) }
            out("recording — drive the app, then: testa flow record save <file.flow>")
            exit(0)

        case "save":
            var rest = Array(argv.dropFirst())
            let all = rest.contains("--all")
            rest.removeAll { $0 == "--all" }
            guard let target = rest.first else {
                err("flow record save needs an output path\n" + runUsage); exit(2)
            }
            let (ok, text) = Client.send(udid, ["histget"])
            if !ok { err(text); exit(1) }
            let commands: [[String]] = text.split(separator: "\n").compactMap {
                guard let d = $0.data(using: .utf8) else { return nil }
                return (try? JSONSerialization.jsonObject(with: d)) as? [String]
            }
            let path = (target as NSString).standardizingPath
            let stamp = ISO8601DateFormatter().string(from: Date())
            let body = FlowRecord.flowText(commands: commands, name: Flow.stem(of: path),
                                           timestamp: stamp, all: all)
            do { try body.write(toFile: path, atomically: true, encoding: .utf8) }
            catch { err("could not write \(path): \(error.localizedDescription)"); exit(1) }
            let kept = body.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.hasPrefix("@") && !$0.isEmpty }.count
            out("saved \(kept) step\(kept == 1 ? "" : "s") → \(path)")
            exit(0)

        default:
            err("flow record wants `start` or `save <file.flow>`\n" + runUsage); exit(2)
        }
    }

    // MARK: testa matrix …

    static func matrix(_ argv: [String], explicitUDID: String?) -> Never {
        guard let spec = argv.first, !spec.isEmpty, spec != "--" else {
            err("usage: testa matrix \"<device1,device2,…>\" -- flow run <file.flow ...>"); exit(2)
        }
        var tail = Array(argv.dropFirst())
        if tail.first == "--" { tail.removeFirst() }
        // The tail is "anything flow run accepts" — with or without the words.
        if tail.first == "flow" { tail.removeFirst() }
        if tail.first == "run" { tail.removeFirst() }
        let opts = parseRunOptions(tail)
        guard !opts.files.isEmpty else {
            err("matrix needs a flow to run: testa matrix \"iPhone 14 Pro\" -- flow run smoke.flow"); exit(2)
        }

        // Resolve targets (device name or udid), de-duplicated, order preserved.
        let devices = Simctl.allDevices()
        var targets: [Simctl.Device] = []
        for raw in spec.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !raw.isEmpty {
            guard let d = devices.first(where: { $0.udid == raw || $0.name == raw }) else {
                err("unknown device \"\(raw)\". Available:\n"
                    + devices.map { "  \($0.name)  (\($0.state))" }.joined(separator: "\n"))
                exit(2)
            }
            if !targets.contains(where: { $0.udid == d.udid }) { targets.append(d) }
        }

        // Boot whatever is not up yet — a matrix that silently skips a device is
        // worse than one that takes 30 seconds longer.
        for d in targets where d.state != "Booted" {
            out("booting \(d.name) …")
            Simctl.run(["boot", d.udid])
            Simctl.run(["bootstatus", d.udid, "-b"])
        }

        let collector = FlowCollector()
        let group = DispatchGroup()
        for (i, d) in targets.enumerated() {
            var perDevice = opts
            perDevice.junit = nil  // one combined report, written below
            perDevice.artifacts = opts.artifacts + "/" + d.name.replacingOccurrences(of: " ", with: "-")
            let runner = FlowRunner(udid: d.udid, device: d.name, opts: perDevice)
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                collector.add(i, runner.runAll())
            }
        }
        group.wait()

        let results = collector.ordered
        writeJUnit(results, to: opts.junit)
        printMatrixTable(results)
        exit(results.allSatisfy { $0.passed } ? 0 : 1)
    }

    static func printMatrixTable(_ results: [FlowResult]) {
        let rows = results.map { r -> [String] in
            [r.suite, "\(r.passedCount)", "\(r.failedCount)", "\(r.skippedCount)",
             r.passed ? "PASSED" : "FAILED", String(format: "%.1fs", Double(r.durationMs) / 1000)]
        }
        let header = ["device / flow", "pass", "fail", "skip", "result", "time"]
        var widths = header.map { $0.count }
        for row in rows { for (i, cell) in row.enumerated() { widths[i] = max(widths[i], cell.count) } }
        func render(_ cells: [String]) -> String {
            cells.enumerated().map { i, c in
                i == cells.count - 1 ? c : c.padding(toLength: widths[i], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
        out("")
        out(render(header))
        out(widths.map { String(repeating: "─", count: $0) }.joined(separator: "  "))
        for row in rows { out(render(row)) }
        let failed = results.filter { !$0.passed }.count
        out("")
        out(failed == 0 ? "all \(results.count) run\(results.count == 1 ? "" : "s") passed"
                        : "\(failed) of \(results.count) runs FAILED")
    }
}
