import XCTest
@testable import TestaKit

final class AuditModelTests: XCTestCase {

    // MARK: - Helpers

    func el(_ role: String, label: String? = nil, id: String? = nil, value: String? = nil,
            x: Double = 10, y: Double = 100, w: Double = 100, h: Double = 60) -> [String: Any] {
        var d: [String: Any] = ["role": role, "x": x, "y": y, "w": w, "h": h, "depth": 1]
        if let label = label { d["label"] = label }
        if let id = id { d["id"] = id }
        if let value = value { d["value"] = value }
        return d
    }

    func snap(_ elements: [[String: Any]], w: Double = 400, h: Double = 800) -> Snapshot {
        Snapshot(elements: elements, screenW: w, screenH: h)
    }

    func findings(_ elements: [[String: Any]], rule: String) -> [AuditFinding] {
        AuditModel.audit(snap(elements)).filter { $0.rule == rule }
    }

    // MARK: - missing-label

    func testMissingLabelFlagsUnlabeledInteractable() {
        let f = findings([el("AXButton", x: 10, y: 100)], rule: "missing-label")
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].severity, .error)
        XCTAssertEqual(f[0].ref, "e1")
    }

    func testMissingLabelAcceptsEitherLabelOrIdentifier() {
        XCTAssertTrue(findings([el("AXButton", label: "Sign in")], rule: "missing-label").isEmpty)
        XCTAssertTrue(findings([el("AXButton", id: "signInButton")], rule: "missing-label").isEmpty)
    }

    func testMissingLabelIgnoresNonInteractableElements() {
        // A decorative container with an id but no label is not a11y-broken.
        XCTAssertTrue(findings([el("AXGroup", id: "container")], rule: "missing-label").isEmpty)
    }

    // MARK: - small-target

    func testSmallTargetSeverityThresholds() {
        // 23pt: below the "anyone can hit this" floor -> error.
        let tiny = findings([el("AXButton", label: "x", w: 23, h: 23)], rule: "small-target")
        XCTAssertEqual(tiny.count, 1)
        XCTAssertEqual(tiny[0].severity, .error)

        // 43pt: just under the HIG minimum -> warning.
        let small = findings([el("AXButton", label: "x", w: 43, h: 43)], rule: "small-target")
        XCTAssertEqual(small.count, 1)
        XCTAssertEqual(small[0].severity, .warn)

        // 44pt: exactly the HIG minimum -> nothing.
        XCTAssertTrue(findings([el("AXButton", label: "x", w: 44, h: 44)], rule: "small-target").isEmpty)
    }

    func testSmallTargetUsesTheWorstDimension() {
        // Wide but 20pt tall: the height is what a finger misses -> error.
        let f = findings([el("AXButton", label: "Row", w: 200, h: 20)], rule: "small-target")
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].severity, .error)
        XCTAssertTrue(f[0].message.contains("200×20pt"), f[0].message)
    }

    func testSmallTargetSkipsLayoutSpans() {
        // A full-width row is a layout span, not a hit target, in that dimension.
        XCTAssertTrue(findings([el("AXCell", label: "Row", w: 380, h: 60)], rule: "small-target").isEmpty)
        // …but a 380x10 divider-like cell is still flagged on its height.
        XCTAssertEqual(findings([el("AXCell", label: "Row", w: 380, h: 10)], rule: "small-target").count, 1)
    }

    func testSmallTargetIgnoresNonInteractableElements() {
        XCTAssertTrue(findings([el("AXStaticText", label: "hi", w: 20, h: 12)], rule: "small-target").isEmpty)
    }

    // MARK: - duplicate-label

    func testDuplicateLabelFlagsAmbiguousInteractables() {
        let f = findings([
            el("AXButton", label: "Open", y: 100),
            el("AXButton", label: "Open", y: 200),
            el("AXButton", label: "Close", y: 300),
        ], rule: "duplicate-label")
        XCTAssertEqual(f.count, 2)
        XCTAssertEqual(f.map(\.ref), ["e1", "e2"])
        XCTAssertTrue(f.allSatisfy { $0.severity == .warn })
    }

    func testDuplicateLabelAcceptsDistinctIdentifiers() {
        XCTAssertTrue(findings([
            el("AXButton", label: "Open", id: "open-1", y: 100),
            el("AXButton", label: "Open", id: "open-2", y: 200),
        ], rule: "duplicate-label").isEmpty)
    }

    func testDuplicateLabelStillFlagsRepeatedIdentifiers() {
        // Same label *and* same id: a selector cannot tell them apart either.
        XCTAssertEqual(findings([
            el("AXButton", label: "Open", id: "open", y: 100),
            el("AXButton", label: "Open", id: "open", y: 200),
        ], rule: "duplicate-label").count, 2)
    }

    func testDuplicateLabelIgnoresOffScreenTwins() {
        // Only one is on screen -> no ambiguity for the user in front of it.
        XCTAssertTrue(findings([
            el("AXButton", label: "Open", y: 100),
            el("AXButton", label: "Open", y: 5000),
        ], rule: "duplicate-label").isEmpty)
    }

    func testDuplicateLabelIgnoresStaticText() {
        XCTAssertTrue(findings([
            el("AXStaticText", label: "Total", y: 100),
            el("AXStaticText", label: "Total", y: 200),
        ], rule: "duplicate-label").isEmpty)
    }

    // MARK: - label-in-id-style

    func testIdStyleHeuristicPositives() {
        for s in ["submitBtn2", "user_name_field", "checkoutcontinuebutton", "loginViewTitle",
                  "tab_bar_item", "submit2btn"] {
            XCTAssertTrue(AuditModel.looksLikeIdentifier(s), "\(s) should look like an identifier")
        }
    }

    func testIdStyleHeuristicNegatives() {
        // Long single words are the trap: "Accessibility" is a word, not a symbol.
        for s in ["Sign in", "OK", "Settings", "9:41", "$12.00", "Add to cart",
                  "Done", "example.com", "iPhone", "eBay",
                  "Accessibility", "Notifications", "Einstellungen", "1234567890123"] {
            XCTAssertFalse(AuditModel.looksLikeIdentifier(s), "\(s) should NOT look like an identifier")
        }
    }

    func testLabelInIdStyleFlagsAnyLabeledElement() {
        let f = findings([
            el("AXButton", label: "submitBtn2", y: 100),
            el("AXStaticText", label: "welcome_screen_title", y: 200),
            el("AXButton", label: "Sign in", y: 300),
        ], rule: "label-in-id-style")
        XCTAssertEqual(f.map(\.ref), ["e1", "e2"])
        XCTAssertTrue(f.allSatisfy { $0.severity == .warn })
    }

    // MARK: - offscreen-interactable

    func testOffscreenInteractablesAreInfoOnly() {
        let all = AuditModel.audit(snap([
            el("AXButton", label: "Visible", y: 100),
            el("AXButton", label: "Below the fold", y: 2000),
            el("AXButton", label: "Also below", y: 3000),
        ]))
        let info = all.filter { $0.severity == .info }
        XCTAssertEqual(info.count, 2)
        XCTAssertTrue(info.allSatisfy { $0.rule == "offscreen-interactable" })
        // Off-screen elements are never counted as defects.
        XCTAssertTrue(all.filter { $0.severity != .info }.isEmpty)
    }

    // MARK: - Ordering / report

    func testFindingsAreGroupedBySeverity() {
        let f = AuditModel.audit(snap([
            el("AXButton", label: "submitBtn2", y: 100),   // warn
            el("AXButton", y: 200),                        // error (no label, no id)
            el("AXButton", label: "Way off", y: 4000),     // info
        ]))
        XCTAssertEqual(f.map(\.severity), [.error, .warn, .info])
    }

    func testReportSummaryCountsAndLines() {
        let s = snap([
            el("AXButton", y: 100, w: 20, h: 20),          // missing-label + small-target
            el("AXButton", label: "submitBtn2", y: 200),   // label-in-id-style
            el("AXButton", label: "Off", y: 4000),         // off screen (info)
        ])
        let f = AuditModel.audit(s)
        let text = AuditModel.report(s, findings: f)
        XCTAssertTrue(text.contains("errors (2):"), text)
        XCTAssertTrue(text.contains("warnings (1):"), text)
        XCTAssertTrue(text.contains("[missing-label] e1 Button"), text)
        XCTAssertTrue(text.contains("info: 1 interactable element off screen"), text)
        // Summary first — flows and JUnit quote only the first line of a failure.
        XCTAssertEqual(text.split(separator: "\n").first.map(String.init),
                       "audit: 2 errors, 1 warnings (3 elements scanned)")
    }

    func testCleanScreenReportsNoIssues() {
        let s = snap([
            el("AXButton", label: "Sign in", id: "signIn", y: 100, w: 200, h: 48),
            el("AXStaticText", label: "Welcome back", y: 200, w: 200, h: 20),
        ])
        let text = AuditModel.report(s, findings: AuditModel.audit(s))
        XCTAssertTrue(text.contains("no accessibility issues found"), text)
        XCTAssertTrue(text.hasPrefix("audit: 0 errors, 0 warnings (2 elements scanned)"), text)
    }

    func testTruncatedTreeIsNotedAndNotScanned() {
        let s = snap([
            el("AXButton", label: "Sign in", id: "signIn", y: 100, w: 200, h: 48),
            ["role": Snapshot.truncatedRole],
        ])
        let text = AuditModel.report(s, findings: AuditModel.audit(s))
        XCTAssertTrue(text.contains("truncated"), text)
        XCTAssertTrue(text.hasPrefix("audit: 0 errors, 0 warnings (1 elements scanned)"), text)
    }
}
