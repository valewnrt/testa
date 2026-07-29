import Foundation
import Darwin
import TestaEngine

func out(_ s: String) { print(s) }
func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// A client (or daemon) writing to a closed socket must see EPIPE, not die.
_ = signal(SIGPIPE, SIG_IGN)

let usage = """
testa — autonomous iOS Simulator E2E driver for AI agents

  Observe:
    testa ui [diff|full]            on-screen snapshot (diff=changes, full=incl. off-screen)
    testa see                       OCR every visible text + tap coords (any app)
    testa find <query>              elements matching label/id/value/role
    testa scrollto <sel>            scroll until an element is visible
    testa assert <sel> [exists|gone|value=..|label=..]
    testa wait <sel> [gone] [timeoutMs]   wait until it appears (or disappears)
    testa audit                     accessibility audit (labels, 44pt targets, dupes)
    testa vdiff <baseline.png> [tolerancePct]   visual regression (writes the
                                    baseline on first run; OCR-aware diff after)
    testa screenshot [path.png]

  Act (sel = eN | #id | "label"; tap falls back to OCR text):
    testa tap <sel> | testa tap <x> <y> | testa tapocr <text>
    testa typein <sel> <text> | testa type <text> | testa setvalue <sel> <text>
    testa clear <sel> | testa key <hidUsage>
    testa swipe|drag|dragdrop <x1> <y1> <x2> <y2> [secs]  (also <fromSel> <toSel>)
    testa longpress <sel|x y> [secs] | pinch <sel|x y> <scale> [secs]
    testa rotate <sel|x y> <radians> [secs]

  App / device:
    testa devices                   booted simulators
    testa boot <udid|name> | shutdown <udid|all>
    testa install <app> | terminate <bundle> | apps
    testa launch <bundle> [--env K=V ...] [--args <a> ...]
    testa logs [bundle] [seconds]   recent app console logs
    testa crashes [bundle]          newest crash report, if any
    testa open <url>                open a deep link / universal link
    testa permission <grant|revoke|reset> <service> <bundle>
    testa record <start [path.mp4]|stop>

  Environment:
    testa push <bundle> <file.json | '{"aps":{"alert":"hi"}}'>
    testa location <lat> <lon> | testa location clear
    testa statusbar time 9:41 [battery 100 charged] [wifi 3] [cell 4] | statusbar clear
    testa appearance <dark|light> | testa contentsize <size|increment|decrement>
    testa locale <en_US> [lang]     (apps need a relaunch to pick it up)
    testa addmedia <file...>        add photos/videos to the library
    testa pbcopy <text> | testa pbpaste     simulator pasteboard
    testa biometry <enroll|unenroll|match|nomatch>
    testa button <home|lock|siri|apple-pay> | testa keycombo <cmd+shift+a>

  Flows / CI (deterministic replay — no agent, no tokens):
    testa flow run <file.flow ...> [--junit <out.xml>] [--artifacts <dir>] [--quiet]
    testa flow record start         mark "record from here"
    testa flow record save <file.flow> [--all]   write what you just did as a flow
    testa matrix "<dev1,dev2,…>" -- flow run <file.flow ...>   same flow, every device

  A .flow file is one testa command per line (`#` comments, `@name`, `@timeout`,
  `@require <bundle>`). Exit 0 iff every step passed; failures dump a screenshot,
  the full tree, OCR, logs and crashes into the artifacts dir.

  Target a specific sim with --udid <udid> (default: the booted one).
  Setup / daemon: testa setup | start | stop | status | info | mcp | version

  Acting commands answer with the settled UI diff, so a follow-up `ui` is
  usually unnecessary.
"""

// --- parse a global --udid flag ---
var explicitUDID: String? = nil
var rawArgs = Array(CommandLine.arguments.dropFirst())
if let i = rawArgs.firstIndex(of: "--udid"), i + 1 < rawArgs.count {
    explicitUDID = rawArgs[i + 1]
    rawArgs.removeSubrange(i...(i + 1))
}
let argv = rawArgs
let cmd = argv.first ?? "help"

// One-shot post-install: install the Claude Code skill + register the MCP server.
// Works for both Homebrew (skill under <prefix>/share) and source installs.
func runSetup() {
    let home = NSHomeDirectory()
    let skillDir = home + "/.claude/skills/testa"
    let exe = Client.executablePath()
    let exeDir = (exe as NSString).deletingLastPathComponent
    let candidates = [
        exeDir + "/../share/testa/skills/testa/SKILL.md",
        exeDir + "/../share/testa/SKILL.md",
        exeDir + "/../skills/testa/SKILL.md",
        FileManager.default.currentDirectoryPath + "/skills/testa/SKILL.md",
    ].map { ($0 as NSString).standardizingPath }

    if let src = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
        try? FileManager.default.createDirectory(atPath: skillDir, withIntermediateDirectories: true)
        let dst = skillDir + "/SKILL.md"
        try? FileManager.default.removeItem(atPath: dst)
        do { try FileManager.default.copyItem(atPath: src, toPath: dst); out("✓ skill installed → \(dst)") }
        catch { err("• could not copy skill: \(error.localizedDescription)") }
    } else {
        out("• skill file not found near binary (MCP still works)")
    }

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["claude", "mcp", "add", "testa", "--", exe, "mcp"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    if (try? p.run()) != nil {
        p.waitUntilExit()
        if p.terminationStatus == 0 { out("✓ MCP server registered with Claude Code") }
        else { out("• register MCP manually:  claude mcp add testa -- \(exe) mcp") }
    } else {
        out("• Claude Code CLI not found. Register MCP with:\n    claude mcp add testa -- \(exe) mcp")
    }
    out("\nDone. Boot a simulator, then:  testa info && testa ui")
}

func requireUDID(_ explicit: String?) -> String {
    guard let u = Simctl.resolveUDID(explicit) else {
        err("no booted simulator. Boot one (testa boot <name>) or pass --udid.")
        exit(1)
    }
    // Picking one of several booted sims silently is how a test ends up driving
    // the wrong device — say which one we chose.
    if explicit == nil, ProcessInfo.processInfo.environment["TESTA_UDID"]?.isEmpty != false {
        let booted = Simctl.bootedDevices()
        if booted.count > 1, let d = booted.first(where: { $0.udid == u }) {
            err("multiple booted simulators — using \(d.name) (\(d.udid)); pass --udid to choose")
        }
    }
    return u
}

func route(_ udid: String, _ argv: [String]) -> Never {
    let (ok, text) = Client.send(udid, argv)
    if ok { out(text) } else { err(text); exit(1) }
    exit(0)
}

switch cmd {
case "__daemon":
    _ = setsid()
    do {
        let udid = Simctl.resolveUDID(nil)
        let sim = try (udid.map { try TSTSimulator.withUDID($0) } ?? TSTSimulator.bootedSimulator())
        Daemon(sim: sim).serve()
    } catch {
        err("testad: \(error.localizedDescription)")
        exit(1)
    }

case "mcp":
    MCP.run()

case "setup":
    runSetup()

case "help", "-h", "--help":
    out(usage)

case "version", "--version", "-v":
    out("testa \(testaVersion)")

case "layout":
    out(TSTSimulator.layoutDescription())

case "devices":
    let booted = Simctl.bootedDevices()
    if booted.isEmpty { out("no booted simulators") }
    else { out(booted.map { "\($0.udid)  \($0.name)  (\($0.state))" }.joined(separator: "\n")) }

case "boot" where argv.count >= 2:
    let arg = argv[1]
    let dev = Simctl.allDevices().first { $0.udid == arg || $0.name == arg }
    let udid = dev?.udid ?? arg
    let (code, o) = Simctl.run(["boot", udid])
    Simctl.run(["bootstatus", udid, "-b"])
    _ = Simctl.run(["io", udid, "screenshot", "/dev/null"]) // nudge
    Process.launchedProcess(launchPath: "/usr/bin/open", arguments: ["-a", "Simulator"])
    out(code == 0 || o.contains("current state: Booted") ? "booted \(udid)" : o)

case "shutdown" where argv.count >= 2:
    let (code, o) = Simctl.run(["shutdown", argv[1]])
    out(code == 0 ? "shutdown \(argv[1])" : o)

case "start":
    let udid = requireUDID(explicitUDID)
    if Client.daemonRunning(udid) { out("already running for \(udid)"); break }
    Client.spawnDaemon(udid)
    var ready = false
    for _ in 0..<200 { usleep(100 * 1000); if Client.daemonRunning(udid) { ready = true; break } }
    let (ok, text) = ready ? Client.send(udid, ["info"]) : (false, "failed to start")
    out(ok ? "started: \(text)" : text)

case "stop":
    let udid = requireUDID(explicitUDID)
    if Client.daemonRunning(udid) { _ = Client.sendOnce(udid, ["stop"]); out("stopped \(udid)") }
    else { out("not running") }

case "flow":
    FlowCLI.flow(Array(argv.dropFirst()), explicitUDID: explicitUDID)

case "matrix":
    FlowCLI.matrix(Array(argv.dropFirst()), explicitUDID: explicitUDID)

case "status":
    let udid = requireUDID(explicitUDID)
    let (ok, text) = Client.daemonRunning(udid) ? Client.send(udid, ["ping"]) : (false, "not running")
    out(ok ? "running: \(text)" : text); exit(ok ? 0 : 1)

default:
    route(requireUDID(explicitUDID), argv)
}
