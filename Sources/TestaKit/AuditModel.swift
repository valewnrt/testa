import Foundation

// Accessibility audit — the pure half. Everything here is a function of the
// screen model (`Snapshot`), so the rules are unit-testable without a simulator.
//
// The audit is a free byproduct of the tree testa already reads for every
// command: the same data that lets an agent tap "Sign in" also says whether a
// VoiceOver user (or a selector) could ever find that button.
//
// Deliberately NOT rules here:
//   * contrast   — needs pixel sampling, not the tree (see `vdiff` for pixels)
//   * font size  — not exposed by the accessibility tree at all
// Guessing at either from the tree would produce confident nonsense.

/// One accessibility problem, tied to the element that has it.
public struct AuditFinding: Equatable, Sendable {
    public enum Severity: String, Sendable, CaseIterable {
        case error, warn, info
    }

    /// Stable rule id, e.g. "missing-label" — greppable in CI output.
    public let rule: String
    public let severity: Severity
    /// The element's snapshot ref ("e12"), resolved to a compact line at print time.
    public let ref: String
    public let message: String

    public init(rule: String, severity: Severity, ref: String, message: String) {
        self.rule = rule
        self.severity = severity
        self.ref = ref
        self.message = message
    }
}

public enum AuditModel {

    // MARK: - Thresholds

    /// Apple HIG minimum hit target (points). Below this is a warning …
    public static let minTargetPt = 44.0
    /// … below this it is an error: unusable for anyone with imprecise touch.
    public static let tinyTargetPt = 24.0
    /// A dimension this large is a layout span, not a hit target — never flagged.
    public static let wideDimensionPt = 250.0
    /// Shortest label that can still look like a variable name ("submitBtn2").
    public static let idStyleMinLength = 8
    /// A spaceless, identifier-charset label this long is suspicious on its own.
    public static let idStyleLongLength = 12

    // MARK: - Entry points

    public static func audit(_ snap: Snapshot) -> [AuditFinding] {
        audit(snap.all, screenW: snap.screenW, screenH: snap.screenH)
    }

    /// Run every rule. Findings come back grouped by severity (errors, warnings,
    /// then the informational off-screen entries), each group in screen order.
    public static func audit(_ elements: [UIElement],
                             screenW: Double = 0, screenH: Double = 0) -> [AuditFinding] {
        let real = elements.filter { $0.role != Snapshot.truncatedRole }
        let onScreen = real.filter { visible($0, screenW: screenW, screenH: screenH) }
        let targets = onScreen.filter { interactable($0) }

        var found: [AuditFinding] = []
        found += missingLabel(targets)
        found += smallTarget(targets)
        found += duplicateLabel(targets)
        found += labelInIdStyle(onScreen)
        found += offscreenInteractable(real, screenW: screenW, screenH: screenH)

        // Group by severity; inside a group keep the screen order refs give us.
        let order: [AuditFinding.Severity: Int] = [.error: 0, .warn: 1, .info: 2]
        return found.enumerated().sorted { a, b in
            let sa = order[a.element.severity] ?? 9, sb = order[b.element.severity] ?? 9
            if sa != sb { return sa < sb }
            let ra = refIndex(a.element.ref), rb = refIndex(b.element.ref)
            if ra != rb { return ra < rb }
            return a.offset < b.offset
        }.map(\.element)
    }

    // MARK: - Rules

    /// error — an interactable with neither label nor identifier. A screen-reader
    /// user gets "button" and nothing else; an E2E selector has nothing to match.
    static func missingLabel(_ targets: [UIElement]) -> [AuditFinding] {
        targets.filter { ($0.label ?? "").isEmpty && ($0.id ?? "").isEmpty }
            .map {
                AuditFinding(rule: "missing-label", severity: .error, ref: $0.ref,
                             message: "\($0.shortRole) has no label and no identifier — "
                                    + "VoiceOver announces nothing and no selector can target it")
            }
    }

    /// error/warn — hit target below Apple's 44×44pt HIG minimum. A dimension over
    /// `wideDimensionPt` is a layout span (full-width row), not a target: skipped.
    static func smallTarget(_ targets: [UIElement]) -> [AuditFinding] {
        targets.compactMap { e in
            guard e.w > 0, e.h > 0 else { return nil }
            var small: [Double] = []
            if e.w <= wideDimensionPt, e.w < minTargetPt { small.append(e.w) }
            if e.h <= wideDimensionPt, e.h < minTargetPt { small.append(e.h) }
            guard let worst = small.min() else { return nil }
            return AuditFinding(
                rule: "small-target",
                severity: worst < tinyTargetPt ? .error : .warn,
                ref: e.ref,
                message: "\(pt(e.w))×\(pt(e.h))pt hit target — below the \(pt(minTargetPt))×\(pt(minTargetPt))pt HIG minimum")
        }
    }

    /// warn — several on-screen interactables share one label and have no
    /// identifier to tell them apart: ambiguous for VoiceOver *and* for selectors
    /// (testa's own `tap "Open"` would pick whichever sits highest).
    static func duplicateLabel(_ targets: [UIElement]) -> [AuditFinding] {
        var groups: [String: [UIElement]] = [:]
        for e in targets {
            guard let l = e.label, !l.isEmpty else { continue }
            groups[l, default: []].append(e)
        }
        var out: [AuditFinding] = []
        for (label, group) in groups where group.count >= 2 {
            // An element is distinguishable if it carries an id no sibling shares.
            var idCount: [String: Int] = [:]
            for e in group { if let i = e.id, !i.isEmpty { idCount[i, default: 0] += 1 } }
            let ambiguous = group.filter { e in
                guard let i = e.id, !i.isEmpty else { return true }
                return (idCount[i] ?? 0) > 1
            }
            guard ambiguous.count >= 2 else { continue }
            for e in ambiguous {
                out.append(AuditFinding(
                    rule: "duplicate-label", severity: .warn, ref: e.ref,
                    message: "\(ambiguous.count) on-screen elements share the label "
                           + "\"\(Snapshot.escaped(label, limit: 60))\" with no distinguishing identifier"))
            }
        }
        return out
    }

    /// warn — the label reads like a variable name, so it was probably never
    /// written for a human: VoiceOver will spell out "submitBtn2".
    static func labelInIdStyle(_ elements: [UIElement]) -> [AuditFinding] {
        elements.compactMap { e in
            guard let l = e.label, looksLikeIdentifier(l) else { return nil }
            return AuditFinding(
                rule: "label-in-id-style", severity: .warn, ref: e.ref,
                message: "label \"\(Snapshot.escaped(l, limit: 60))\" looks like an identifier, "
                       + "not human speech — VoiceOver reads it verbatim")
        }
    }

    /// info — interactables outside the viewport. Context (they may simply be
    /// below the fold), never a defect, so they are only ever counted.
    static func offscreenInteractable(_ elements: [UIElement],
                                      screenW: Double, screenH: Double) -> [AuditFinding] {
        elements.filter { interactable($0) && !visible($0, screenW: screenW, screenH: screenH) }
            .map {
                AuditFinding(rule: "offscreen-interactable", severity: .info, ref: $0.ref,
                             message: "interactable outside the viewport")
            }
    }

    // MARK: - Heuristics

    public static func interactable(_ e: UIElement) -> Bool {
        Snapshot.interactableRoles.contains(e.role)
    }

    /// Viewport test. `UIElement.onScreen` already knows this; recompute when a
    /// screen size is supplied so the rules stay a pure function of their inputs.
    public static func visible(_ e: UIElement, screenW: Double, screenH: Double) -> Bool {
        guard screenW > 0, screenH > 0 else { return e.onScreen }
        return e.x + e.w > -1 && e.x < screenW + 1 && e.y + e.h > -1 && e.y < screenH + 1
    }

    /// "submitBtn2" / "user_name_field" / "checkoutcontinuebutton" -> true.
    /// "Sign in" / "OK" / "9:41" / "$12.00" -> false.
    ///
    /// Two ways in: a camelCase hump or a snake_case underscore (strong signals,
    /// so 8 characters is enough), or a long spaceless run of identifier
    /// characters (weak signal, needs `idStyleLongLength`).
    public static func looksLikeIdentifier(_ label: String) -> Bool {
        let s = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= idStyleMinLength else { return false }
        let chars = Array(s)
        // Any whitespace at all means somebody wrote it as text.
        guard !chars.contains(where: { $0.isWhitespace }) else { return false }
        // Identifier charset only: letters, digits, underscore. Prices, times,
        // URLs and sentences with punctuation drop out here.
        guard chars.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
        guard chars.contains(where: { $0.isLetter }) else { return false }   // not a bare number

        let snake = chars.contains("_")
        var camel = false
        for i in 1..<chars.count where chars[i].isUppercase && (chars[i - 1].isLowercase || chars[i - 1].isNumber) {
            camel = true
            break
        }
        if snake || camel { return true }
        // No hump and no underscore. A capital anywhere means somebody cased it
        // for reading ("Accessibility", "Notifications") — those are words, not
        // identifiers, and flagging them was the rule's worst false positive.
        guard !chars.contains(where: { $0.isUppercase }) else { return false }
        // Digits welded into lowercase letters ("submit2btn") read as generated.
        if chars.contains(where: { $0.isNumber }) { return true }
        // Otherwise only a long single lowercase run ("checkoutcontinuebutton").
        return chars.count > idStyleLongLength
    }

    // MARK: - Report

    /// Human/agent-readable report: findings grouped by severity, one compact
    /// element line each, then a machine-greppable summary line.
    public static func report(_ snap: Snapshot, findings: [AuditFinding]) -> String {
        let scanned = snap.all.filter { $0.role != Snapshot.truncatedRole }.count
        let truncated = snap.all.contains { $0.role == Snapshot.truncatedRole }
        return report(findings, scanned: scanned, truncated: truncated) { ref in
            snap.byRef[ref].map(snap.line)
        }
    }

    public static func report(_ findings: [AuditFinding], scanned: Int, truncated: Bool = false,
                              line: (String) -> String?) -> String {
        let errors = findings.filter { $0.severity == .error }
        let warnings = findings.filter { $0.severity == .warn }
        let offscreen = findings.filter { $0.severity == .info }

        func block(_ title: String, _ group: [AuditFinding]) -> [String] {
            guard !group.isEmpty else { return [] }
            return ["\(title) (\(group.count)):"] + group.map {
                "  [\($0.rule)] \(line($0.ref) ?? $0.ref) — \($0.message)"
            }
        }

        // Summary first: a flow/JUnit failure quotes only the first line, and
        // "audit: 3 errors, 1 warnings" is the line worth quoting.
        var out = ["audit: \(errors.count) errors, \(warnings.count) warnings (\(scanned) elements scanned)"]
        if errors.isEmpty && warnings.isEmpty {
            out.append("no accessibility issues found")
        }
        out += block("errors", errors)
        out += block("warnings", warnings)
        if !offscreen.isEmpty {
            out.append("info: \(offscreen.count) interactable element\(offscreen.count == 1 ? "" : "s") "
                     + "off screen (context, not a defect)")
        }
        if truncated {
            out.append("note: the accessibility tree was truncated — this audit is partial")
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Formatting

    static func pt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    static func refIndex(_ ref: String) -> Int {
        Int(ref.dropFirst()) ?? Int.max
    }
}
