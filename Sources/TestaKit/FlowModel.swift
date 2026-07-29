import Foundation

// Deterministic test flows — the pure half: parsing a .flow file and turning a
// run into JUnit XML. No Process, no sockets, no simulator: everything here is
// unit-testable. The runner (Sources/testa/Flow.swift) supplies the I/O.
//
// A .flow file is *the CLI, one command per line*. That is the whole format:
// nothing to learn twice, and an agent that just explored a screen already
// knows how to write one.
//
//     # comment
//     @name Sign-in smoke
//     @timeout 8000
//     @require com.example.app
//
//     launch com.example.app
//     wait "#welcome"            # gets the @timeout appended
//     tap "Sign in"
//     assert #status label=done

// MARK: - Errors

public struct FlowParseError: Error, CustomStringConvertible, Sendable {
    public let file: String
    public let line: Int
    public let message: String

    public init(file: String, line: Int, message: String) {
        self.file = file
        self.line = line
        self.message = message
    }

    public var description: String { "\(file):\(line): \(message)" }
}

public enum FlowTokenError: Error, Sendable {
    case unterminatedQuote
}

// MARK: - Model

/// One executable line: the daemon command it becomes, plus where it came from.
public struct FlowStep: Sendable, Equatable {
    public let line: Int
    /// The source line with any trailing comment removed, trimmed. Used verbatim
    /// in progress output and JUnit test-case names.
    public let raw: String
    public let argv: [String]

    public init(line: Int, raw: String, argv: [String]) {
        self.line = line
        self.raw = raw
        self.argv = argv
    }

    /// `assert`/`wait` are the steps that exist to be checked. (Every failing
    /// step fails the flow — this only marks intent, e.g. for reporting.)
    public var isAssertion: Bool {
        let c = argv.first ?? ""
        return c == "assert" || c == "wait"
    }
}

/// An `@require <bundleId>` directive, with the line to blame if it fails.
public struct FlowRequire: Sendable, Equatable {
    public let line: Int
    public let bundleId: String

    public init(line: Int, bundleId: String) {
        self.line = line
        self.bundleId = bundleId
    }
}

public struct Flow: Sendable {
    public let name: String
    public let file: String
    public let steps: [FlowStep]
    public let requires: [FlowRequire]
    /// `@timeout <ms>`, already folded into the `wait` steps that lacked one.
    public let timeoutMs: Int?

    public init(name: String, file: String, steps: [FlowStep],
                requires: [FlowRequire] = [], timeoutMs: Int? = nil) {
        self.name = name
        self.file = file
        self.steps = steps
        self.requires = requires
        self.timeoutMs = timeoutMs
    }
}

// MARK: - Tokenizing

extension Flow {
    /// One tokenized source line: the argv, and the source minus its comment.
    public struct Tokenized: Sendable, Equatable {
        public let tokens: [String]
        public let code: String
    }

    /// Split a line into argv exactly the way a shell-free CLI would: whitespace
    /// separates, double quotes group (`tap "Sign in"` -> ["tap", "Sign in"]),
    /// `\"` and `\\` escape inside quotes.
    ///
    /// `#` starts a comment when it opens a token *and* is either the first thing
    /// on the line or followed by whitespace/end-of-line. That keeps `#identifier`
    /// selectors — which every testa command uses — working unquoted.
    public static func tokenize(_ line: String) throws -> Tokenized {
        let chars = Array(line)
        var tokens: [String] = []
        var cur = ""
        var hasCur = false
        var inQuote = false
        var commentAt: Int? = nil
        var i = 0

        func isSpace(_ c: Character) -> Bool { c == " " || c == "\t" || c == "\r" }

        while i < chars.count {
            let c = chars[i]
            if inQuote {
                if c == "\\", i + 1 < chars.count, chars[i + 1] == "\"" || chars[i + 1] == "\\" {
                    cur.append(chars[i + 1]); i += 2; continue
                }
                if c == "\"" { inQuote = false; i += 1; continue }
                cur.append(c); i += 1; continue
            }
            if c == "\"" { inQuote = true; hasCur = true; i += 1; continue }
            if isSpace(c) {
                if hasCur { tokens.append(cur); cur = ""; hasCur = false }
                i += 1; continue
            }
            if c == "#", !hasCur {
                let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                if tokens.isEmpty || next == nil || isSpace(next!) {
                    commentAt = i
                    break
                }
            }
            cur.append(c); hasCur = true; i += 1
        }
        guard !inQuote else { throw FlowTokenError.unterminatedQuote }
        if hasCur { tokens.append(cur) }
        let code = String(chars[0..<(commentAt ?? chars.count)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Tokenized(tokens: tokens, code: code)
    }

    /// Render one argument back into flow syntax (used by `flow record save`).
    public static func quote(_ arg: String) -> String {
        let needs = arg.isEmpty
            || arg.contains(where: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            || arg.contains("\"") || arg.contains("\\")
            || arg == "#" || arg.hasPrefix("@")
        guard needs else { return arg }
        let escaped = arg
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    public static func quote(argv: [String]) -> String {
        argv.map(quote).joined(separator: " ")
    }
}

// MARK: - Parsing

extension Flow {
    /// The file's basename without extension — the default flow name.
    public static func stem(of path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    public static func parse(text: String, filename: String) throws -> Flow {
        // Pass 1: tokenize + collect directives (a directive applies to the whole
        // file, wherever it sits).
        var lines: [(n: Int, t: Tokenized)] = []
        var name: String? = nil
        var timeoutMs: Int? = nil
        var requires: [FlowRequire] = []

        for (idx, source) in text.components(separatedBy: "\n").enumerated() {
            let n = idx + 1
            let tok: Tokenized
            do { tok = try tokenize(source) }
            catch {
                throw FlowParseError(file: filename, line: n,
                                     message: "unterminated quote — every \" needs a closing \"")
            }
            guard let head = tok.tokens.first else { continue }
            guard head.hasPrefix("@") else { lines.append((n, tok)); continue }

            let rest = Array(tok.tokens.dropFirst())
            switch head {
            case "@name":
                guard !rest.isEmpty else {
                    throw FlowParseError(file: filename, line: n, message: "@name needs a title")
                }
                name = rest.joined(separator: " ")
            case "@timeout":
                guard rest.count == 1, let ms = Int(rest[0]), ms > 0 else {
                    throw FlowParseError(file: filename, line: n,
                                         message: "@timeout wants a positive number of milliseconds (e.g. @timeout 8000)")
                }
                timeoutMs = ms
            case "@require":
                guard rest.count == 1, !rest[0].isEmpty else {
                    throw FlowParseError(file: filename, line: n,
                                         message: "@require wants one bundle id (e.g. @require com.example.app)")
                }
                requires.append(FlowRequire(line: n, bundleId: rest[0]))
            default:
                throw FlowParseError(file: filename, line: n,
                                     message: "unknown directive \"\(head)\" — want @name, @timeout or @require")
            }
        }

        // Pass 2: build steps, folding @timeout into bare `wait` lines.
        var steps: [FlowStep] = []
        for (n, tok) in lines {
            var argv = tok.tokens
            var raw = tok.code
            if let ms = timeoutMs, needsTimeout(argv) {
                argv.append("\(ms)")
                raw = raw + " \(ms)"
            }
            steps.append(FlowStep(line: n, raw: raw, argv: argv))
        }
        return Flow(name: name ?? stem(of: filename), file: filename,
                    steps: steps, requires: requires, timeoutMs: timeoutMs)
    }

    /// `wait <sel> [gone] [timeoutMs]` — true when the trailing timeout is absent.
    static func needsTimeout(_ argv: [String]) -> Bool {
        guard argv.first == "wait" else { return false }
        switch argv.count {
        case 2: return true                                   // wait <sel>
        case 3: return argv[2].lowercased() == "gone"          // wait <sel> gone
        default: return false
        }
    }
}

// MARK: - Results

public struct StepResult: Sendable {
    public enum Status: String, Sendable { case passed, failed, skipped }

    public let step: FlowStep
    public let status: Status
    /// The daemon's reply text (or the local reason a step never ran).
    public let message: String
    public let durationMs: Int

    public init(step: FlowStep, status: Status, message: String, durationMs: Int) {
        self.step = step
        self.status = status
        self.message = message
        self.durationMs = durationMs
    }
}

public struct FlowResult: Sendable {
    /// JUnit suite name: the flow name, or "<device> / <flow>" under `matrix`.
    public let suite: String
    public let flowName: String
    public let file: String
    public let steps: [StepResult]
    public let durationMs: Int
    public let startedAt: Date
    /// Set when the flow could not even start (parse error, missing app).
    public let artifactsDir: String?

    public init(suite: String, flowName: String, file: String, steps: [StepResult],
                durationMs: Int, startedAt: Date = Date(), artifactsDir: String? = nil) {
        self.suite = suite
        self.flowName = flowName
        self.file = file
        self.steps = steps
        self.durationMs = durationMs
        self.startedAt = startedAt
        self.artifactsDir = artifactsDir
    }

    public var passedCount: Int { steps.filter { $0.status == .passed }.count }
    public var failedCount: Int { steps.filter { $0.status == .failed }.count }
    public var skippedCount: Int { steps.filter { $0.status == .skipped }.count }
    public var passed: Bool { failedCount == 0 }

    public var summaryLine: String {
        let secs = String(format: "%.1f", Double(durationMs) / 1000)
        return "flow \(flowName): \(passedCount) passed, \(failedCount) failed, "
            + "\(skippedCount) skipped — \(passed ? "PASSED" : "FAILED") (\(secs)s)"
    }
}

// MARK: - JUnit

public enum FlowReport {
    /// XML 1.0 text: escape the five entities and drop characters XML cannot
    /// carry at all. Reply text comes from the app under test — untrusted.
    public static func xmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.unicodeScalars.count + 8)
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default:
                let v = u.value
                if v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D { continue }
                if v == 0x7F { continue }
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    static func seconds(_ ms: Int) -> String { String(format: "%.3f", Double(ms) / 1000) }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    /// One `<testsuite>` per flow, one `<testcase>` per step.
    public static func junitXML(results: [FlowResult]) -> String {
        let tests = results.reduce(0) { $0 + $1.steps.count }
        let failures = results.reduce(0) { $0 + $1.failedCount }
        let skipped = results.reduce(0) { $0 + $1.skippedCount }
        let total = results.reduce(0) { $0 + $1.durationMs }

        var x = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        x += "<testsuites name=\"testa\" tests=\"\(tests)\" failures=\"\(failures)\" "
        x += "skipped=\"\(skipped)\" time=\"\(seconds(total))\">\n"
        for r in results {
            x += "  <testsuite name=\"\(xmlEscape(r.suite))\" tests=\"\(r.steps.count)\" "
            x += "failures=\"\(r.failedCount)\" skipped=\"\(r.skippedCount)\" "
            x += "time=\"\(seconds(r.durationMs))\" timestamp=\"\(iso(r.startedAt))\" "
            x += "file=\"\(xmlEscape(r.file))\">\n"
            for s in r.steps {
                let name = "L\(s.step.line): \(s.step.raw)"
                let head = "    <testcase name=\"\(xmlEscape(name))\" "
                    + "classname=\"\(xmlEscape(r.suite))\" time=\"\(seconds(s.durationMs))\""
                switch s.status {
                case .passed:
                    x += head + "/>\n"
                case .failed:
                    let first = s.message.split(separator: "\n").first.map(String.init) ?? "failed"
                    x += head + ">\n"
                    x += "      <failure message=\"\(xmlEscape(first))\">\(xmlEscape(s.message))</failure>\n"
                    x += "    </testcase>\n"
                case .skipped:
                    x += head + ">\n"
                    x += "      <skipped message=\"\(xmlEscape(s.message))\"/>\n"
                    x += "    </testcase>\n"
                }
            }
            x += "  </testsuite>\n"
        }
        x += "</testsuites>\n"
        return x
    }
}

// MARK: - Recording

public enum FlowRecord {
    /// Pure reads: they observe, they never change the app, and replaying them
    /// only slows a flow down. Dropped unless `--all`.
    public static let readOnly: Set<String> = [
        "ui", "see", "find", "screenshot", "logs", "crashes", "apps", "pbpaste",
        "devices", "info", "status", "layout",
    ]

    /// Turn recorded argv into flow text.
    public static func flowText(commands: [[String]], name: String,
                                timestamp: String, all: Bool = false) -> String {
        let kept = commands.filter { argv in
            guard let c = argv.first, !c.isEmpty else { return false }
            return all || !readOnly.contains(c)
        }
        var out = "# recorded by testa flow record — \(timestamp)\n"
        out += "@name \(name)\n\n"
        if kept.isEmpty {
            out += "# (nothing recorded — drive the app between `flow record start` and `save`)\n"
            return out
        }
        out += kept.map { Flow.quote(argv: $0) }.joined(separator: "\n")
        return out + "\n"
    }
}
