import XCTest
@testable import TestaKit

final class FlowModelTests: XCTestCase {

    // MARK: - Tokenizing

    func testTokenizeSplitsOnWhitespaceAndGroupsQuotes() throws {
        let t = try Flow.tokenize(#"tap "Sign in""#)
        XCTAssertEqual(t.tokens, ["tap", "Sign in"])
        XCTAssertEqual(try Flow.tokenize("tap   #id\tvalue").tokens, ["tap", "#id", "value"])
        XCTAssertEqual(try Flow.tokenize("").tokens, [])
        XCTAssertEqual(try Flow.tokenize("   ").tokens, [])
    }

    func testTokenizeKeepsEmptyQuotedArgument() throws {
        XCTAssertEqual(try Flow.tokenize(#"setvalue #email """#).tokens, ["setvalue", "#email", ""])
    }

    func testTokenizeEscapesInsideQuotes() throws {
        XCTAssertEqual(try Flow.tokenize(#"type "say \"hi\"""#).tokens, ["type", #"say "hi""#])
        XCTAssertEqual(try Flow.tokenize(#"type "a\\b""#).tokens, ["type", #"a\b"#])
    }

    func testUnterminatedQuoteThrows() {
        XCTAssertThrowsError(try Flow.tokenize(#"tap "Sign in"#))
    }

    func testHashSelectorsSurviveButCommentsDoNot() throws {
        // A bare #identifier is a selector, not a comment.
        XCTAssertEqual(try Flow.tokenize("assert #welcome exists").tokens, ["assert", "#welcome", "exists"])
        // Trailing comment: "# " (or # at end of line).
        let t = try Flow.tokenize("tap #saveButton   # save the form")
        XCTAssertEqual(t.tokens, ["tap", "#saveButton"])
        XCTAssertEqual(t.code, "tap #saveButton")
        // Full-line comment.
        XCTAssertEqual(try Flow.tokenize("#anything at all").tokens, [])
        XCTAssertEqual(try Flow.tokenize("   # indented").tokens, [])
        // A # inside quotes is literal.
        XCTAssertEqual(try Flow.tokenize(##"tap "#status""##).tokens, ["tap", "#status"])
        XCTAssertEqual(try Flow.tokenize(#"type "a # b""#).tokens, ["type", "a # b"])
    }

    // MARK: - Parsing

    func testParseBuildsStepsWithLineNumbers() throws {
        let text = """
            # a smoke flow
            @name Sign-in smoke

            launch com.example.app
            tap "Sign in"      # by label

            assert #status label=done
            """
        let f = try Flow.parse(text: text, filename: "/tmp/smoke.flow")
        XCTAssertEqual(f.name, "Sign-in smoke")
        XCTAssertEqual(f.steps.count, 3)
        XCTAssertEqual(f.steps[0].line, 4)
        XCTAssertEqual(f.steps[0].argv, ["launch", "com.example.app"])
        XCTAssertEqual(f.steps[1].line, 5)
        XCTAssertEqual(f.steps[1].argv, ["tap", "Sign in"])
        XCTAssertEqual(f.steps[1].raw, #"tap "Sign in""#, "the comment is not part of the raw step")
        XCTAssertEqual(f.steps[2].line, 7)
    }

    func testFlowNameDefaultsToFilenameStem() throws {
        let f = try Flow.parse(text: "tap x", filename: "/a/b/checkout.flow")
        XCTAssertEqual(f.name, "checkout")
    }

    func testIsAssertion() throws {
        let f = try Flow.parse(text: "tap x\nassert #a exists\nwait #b 100\ntype hi", filename: "f.flow")
        XCTAssertEqual(f.steps.map(\.isAssertion), [false, true, true, false])
    }

    func testRequireDirectiveCarriesItsLine() throws {
        let f = try Flow.parse(text: "\n@require com.example.app\ntap x", filename: "f.flow")
        XCTAssertEqual(f.requires, [FlowRequire(line: 2, bundleId: "com.example.app")])
    }

    // MARK: - Timeout injection

    func testTimeoutIsInjectedIntoBareWaitLines() throws {
        let text = """
            @timeout 8000
            wait #welcome
            wait #spinner gone
            wait #slow 20000
            wait #other gone 300
            tap #welcome
            """
        let f = try Flow.parse(text: text, filename: "f.flow")
        XCTAssertEqual(f.timeoutMs, 8000)
        XCTAssertEqual(f.steps[0].argv, ["wait", "#welcome", "8000"])
        XCTAssertEqual(f.steps[0].raw, "wait #welcome 8000", "the injected timeout shows in the reported step")
        XCTAssertEqual(f.steps[1].argv, ["wait", "#spinner", "gone", "8000"])
        XCTAssertEqual(f.steps[2].argv, ["wait", "#slow", "20000"], "an explicit timeout wins")
        XCTAssertEqual(f.steps[3].argv, ["wait", "#other", "gone", "300"])
        XCTAssertEqual(f.steps[4].argv, ["tap", "#welcome"], "only wait lines get a timeout")
    }

    func testTimeoutAppliesToWaitLinesAboveTheDirective() throws {
        let f = try Flow.parse(text: "wait #a\n@timeout 1234", filename: "f.flow")
        XCTAssertEqual(f.steps[0].argv, ["wait", "#a", "1234"])
    }

    func testNoTimeoutDirectiveLeavesWaitAlone() throws {
        let f = try Flow.parse(text: "wait #a", filename: "f.flow")
        XCTAssertEqual(f.steps[0].argv, ["wait", "#a"])
    }

    // MARK: - Parse errors

    func testUnterminatedQuoteReportsItsLine() {
        let text = "tap a\ntap b\ntap \"oops\ntap d"
        XCTAssertThrowsError(try Flow.parse(text: text, filename: "/x/f.flow")) { e in
            let p = e as! FlowParseError
            XCTAssertEqual(p.line, 3)
            XCTAssertEqual(p.file, "/x/f.flow")
            XCTAssertTrue(p.message.contains("unterminated quote"))
            XCTAssertTrue(p.description.hasPrefix("/x/f.flow:3:"))
        }
    }

    func testUnknownDirectiveIsAnError() {
        XCTAssertThrowsError(try Flow.parse(text: "tap a\n@nope 1", filename: "f.flow")) { e in
            let p = e as! FlowParseError
            XCTAssertEqual(p.line, 2)
            XCTAssertTrue(p.message.contains("@nope"))
            XCTAssertTrue(p.message.contains("@timeout"), "the error should list what is allowed")
        }
    }

    func testBadTimeoutAndEmptyDirectivesAreErrors() {
        for (text, line) in [("@timeout soon", 1), ("@timeout 0", 1), ("@timeout 1 2", 1),
                             ("@name", 1), ("tap a\n@require", 2)] {
            XCTAssertThrowsError(try Flow.parse(text: text, filename: "f.flow")) { e in
                XCTAssertEqual((e as! FlowParseError).line, line, text)
            }
        }
    }

    // MARK: - Quoting round-trip

    func testQuoteRoundTrips() throws {
        let cases = [
            ["tap", "Sign in"],
            ["tap", "#status"],
            ["type", #"say "hi""#],
            ["type", #"back\slash"#],
            ["setvalue", "#a", ""],
            ["assert", "#status", "label=tap:1"],
            ["type", "a # b"],
        ]
        for argv in cases {
            let line = Flow.quote(argv: argv)
            XCTAssertEqual(try Flow.tokenize(line).tokens, argv, line)
        }
    }

    // MARK: - Record conversion

    func testRecordDropsPureReadsByDefault() {
        let recorded = [
            ["launch", "com.example.app"],
            ["ui"], ["see"], ["find", "save"], ["screenshot", "/tmp/x.png"],
            ["logs"], ["crashes"], ["apps"], ["pbpaste"],
            ["tap", "Sign in"],
            ["assert", "#status", "label=done"],
        ]
        let text = FlowRecord.flowText(commands: recorded, name: "rec", timestamp: "2026-01-01T00:00:00Z")
        let f = try! Flow.parse(text: text, filename: "rec.flow")
        XCTAssertEqual(f.name, "rec")
        XCTAssertEqual(f.steps.map(\.argv), [
            ["launch", "com.example.app"],
            ["tap", "Sign in"],
            ["assert", "#status", "label=done"],
        ])
        XCTAssertTrue(text.hasPrefix("# recorded by testa flow record — 2026-01-01T00:00:00Z\n"))
    }

    func testRecordAllKeepsEverything() {
        let recorded = [["ui"], ["tap", "Sign in"], ["screenshot", "/tmp/x.png"]]
        let text = FlowRecord.flowText(commands: recorded, name: "rec",
                                       timestamp: "2026-01-01T00:00:00Z", all: true)
        let f = try! Flow.parse(text: text, filename: "rec.flow")
        XCTAssertEqual(f.steps.map(\.argv), recorded)
    }

    func testRecordKeepsEveryMutatingAndEnvironmentCommand() {
        let keep = [
            ["tap", "a"], ["tapocr", "a"], ["typein", "#a", "b"], ["type", "b"],
            ["setvalue", "#a", "b"], ["clear", "#a"], ["key", "40"],
            ["swipe", "1", "2", "3", "4"], ["drag", "#a", "#b"], ["dragdrop", "#a", "#b"],
            ["longpress", "#a"], ["pinch", "#a", "2"], ["rotate", "#a", "1.5"],
            ["scrollto", "#a"], ["button", "home"], ["keycombo", "cmd+a"],
            ["statusbar", "time", "9:41"], ["appearance", "dark"], ["contentsize", "large"],
            ["push", "com.x", "{}"], ["assert", "#a", "exists"], ["wait", "#a", "500"],
            ["launch", "com.x"], ["open", "x://y"], ["permission", "grant", "photos", "com.x"],
            ["location", "1", "2"], ["biometry", "match"],
        ]
        let text = FlowRecord.flowText(commands: keep, name: "rec", timestamp: "t")
        let f = try! Flow.parse(text: text, filename: "rec.flow")
        XCTAssertEqual(f.steps.map(\.argv), keep)
    }

    func testRecordRequotesArgumentsWithWhitespace() {
        let text = FlowRecord.flowText(commands: [["tap", "Sign in"], ["type", #"say "hi""#]],
                                       name: "rec", timestamp: "t")
        XCTAssertTrue(text.contains(#"tap "Sign in""#))
        let f = try! Flow.parse(text: text, filename: "rec.flow")
        XCTAssertEqual(f.steps.map(\.argv), [["tap", "Sign in"], ["type", #"say "hi""#]])
    }

    func testRecordWithNothingProducesAParseableFile() {
        let text = FlowRecord.flowText(commands: [["ui"]], name: "rec", timestamp: "t")
        let f = try! Flow.parse(text: text, filename: "rec.flow")
        XCTAssertTrue(f.steps.isEmpty)
    }

    // MARK: - JUnit XML

    func sampleResult(suite: String = "smoke") -> FlowResult {
        let s1 = FlowStep(line: 4, raw: #"tap "Continue""#, argv: ["tap", "Continue"])
        let s2 = FlowStep(line: 7, raw: "assert #welcome exists", argv: ["assert", "#welcome", "exists"])
        let s3 = FlowStep(line: 8, raw: "tap #next", argv: ["tap", "#next"])
        return FlowResult(
            suite: suite, flowName: "smoke", file: "/tmp/smoke.flow",
            steps: [
                StepResult(step: s1, status: .passed, message: "tapped e5", durationMs: 312),
                StepResult(step: s2, status: .failed, message: "FAIL not found #welcome\ndetail line", durationMs: 120),
                StepResult(step: s3, status: .skipped, message: "skipped after failure at L7", durationMs: 0),
            ],
            durationMs: 4200, startedAt: Date(timeIntervalSince1970: 0))
    }

    func testJUnitStructure() {
        let xml = FlowReport.junitXML(results: [sampleResult()])
        XCTAssertTrue(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"))
        XCTAssertTrue(xml.contains("<testsuites name=\"testa\" tests=\"3\" failures=\"1\" skipped=\"1\" time=\"4.200\">"))
        XCTAssertTrue(xml.contains("<testsuite name=\"smoke\" tests=\"3\" failures=\"1\" skipped=\"1\" time=\"4.200\""))
        XCTAssertTrue(xml.contains("timestamp=\"1970-01-01T00:00:00Z\""))
        XCTAssertTrue(xml.contains("name=\"L4: tap &quot;Continue&quot;\""))
        XCTAssertTrue(xml.contains("time=\"0.312\"/>"), "a passing case is self-closing")
        XCTAssertTrue(xml.contains("<failure message=\"FAIL not found #welcome\">"),
                      "the failure message is the first line of the reply")
        XCTAssertTrue(xml.contains("detail line</failure>"), "the body carries the whole reply")
        XCTAssertTrue(xml.contains("<skipped message=\"skipped after failure at L7\"/>"))
        XCTAssertTrue(xml.hasSuffix("</testsuites>\n"))
        XCTAssertEqual(xml.components(separatedBy: "<testsuite ").count - 1, 1)
    }

    func testJUnitOneSuitePerFlowAndPerDevice() {
        let xml = FlowReport.junitXML(results: [
            sampleResult(suite: "iPhone 14 Pro / smoke"),
            sampleResult(suite: "iPhone 16 Pro / smoke"),
        ])
        XCTAssertTrue(xml.contains("<testsuite name=\"iPhone 14 Pro / smoke\""))
        XCTAssertTrue(xml.contains("<testsuite name=\"iPhone 16 Pro / smoke\""))
        XCTAssertTrue(xml.contains("tests=\"6\" failures=\"2\" skipped=\"2\""))
    }

    func testXMLEscapingOfLabelsFromTheAppUnderTest() {
        let nasty = #"<&">'"#
        let step = FlowStep(line: 1, raw: "assert \(nasty)", argv: ["assert", nasty])
        let r = FlowResult(suite: nasty, flowName: nasty, file: "/tmp/\(nasty).flow",
                           steps: [StepResult(step: step, status: .failed,
                                              message: "FAIL \(nasty)", durationMs: 1)],
                           durationMs: 1, startedAt: Date(timeIntervalSince1970: 0))
        let xml = FlowReport.junitXML(results: [r])
        XCTAssertFalse(xml.contains(nasty), "no raw metacharacter survives")
        XCTAssertTrue(xml.contains("&lt;&amp;&quot;&gt;&apos;"))
        XCTAssertTrue(xml.contains("name=\"L1: assert &lt;&amp;&quot;&gt;&apos;\""))
        XCTAssertTrue(xml.contains("<failure message=\"FAIL &lt;&amp;&quot;&gt;&apos;\">"))
    }

    func testXMLEscapeDropsCharactersXMLCannotCarry() {
        XCTAssertEqual(FlowReport.xmlEscape("a\u{0}b\u{7}c\u{7F}d"), "abcd")
        XCTAssertEqual(FlowReport.xmlEscape("keep\tthese\nplease\r"), "keep\tthese\nplease\r")
        XCTAssertEqual(FlowReport.xmlEscape("héllo 🎉"), "héllo 🎉")
    }

    func testEmptyResultsStillValidXML() {
        let xml = FlowReport.junitXML(results: [])
        XCTAssertTrue(xml.contains("tests=\"0\" failures=\"0\" skipped=\"0\" time=\"0.000\""))
        XCTAssertTrue(xml.hasSuffix("</testsuites>\n"))
    }

    // MARK: - Result summary

    func testSummaryLine() {
        XCTAssertEqual(sampleResult().summaryLine,
                       "flow smoke: 1 passed, 1 failed, 1 skipped — FAILED (4.2s)")
        let ok = FlowResult(suite: "s", flowName: "s", file: "f", steps: [], durationMs: 1000)
        XCTAssertEqual(ok.summaryLine, "flow s: 0 passed, 0 failed, 0 skipped — PASSED (1.0s)")
        XCTAssertTrue(ok.passed)
    }
}
