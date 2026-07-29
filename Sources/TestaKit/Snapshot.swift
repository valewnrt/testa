import Foundation

// Pure, dependency-free screen model — lives in its own library target so it can
// be unit-tested without a simulator.

/// A single accessibility element, normalized from the engine's dictionary.
public struct UIElement {
    public let ref: String
    public let role: String
    public let label: String?
    public let id: String?
    public let value: String?
    public let x: Double, y: Double, w: Double, h: Double
    public let enabled: Bool
    public let depth: Int
    public var onScreen: Bool = true

    public var cx: Int { Int((x + w / 2).rounded()) }
    public var cy: Int { Int((y + h / 2).rounded()) }

    /// Short role without the "AX" prefix.
    public var shortRole: String { role.hasPrefix("AX") ? String(role.dropFirst(2)) : role }

    /// Stable identity for diffing across snapshots. Deliberately built from the
    /// RAW label/id — escaping is a rendering concern and must not change identity.
    public var key: String { (id.map { "#\($0)" }) ?? "\(role)|\(label ?? "")" }
}

/// A token-efficient view of the screen: only meaningful/interactable elements,
/// each on one compact line with a stable ref and tap-ready center coordinates.
public struct Snapshot {
    public let all: [UIElement]
    public let byRef: [String: UIElement]
    public let screenW: Double
    public let screenH: Double

    public static let interactableRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXSecureTextField", "AXSwitch",
        "AXSlider", "AXLink", "AXCheckBox", "AXMenuItem", "AXTabButton",
        "AXSearchField", "AXCell", "AXImage", "AXPopUpButton", "AXSegmentedControl",
        "AXToggle", "AXStepper", "AXTab",
    ]

    /// Marker role the engine appends when a tree walk was cut short by its deadline.
    public static let truncatedRole = "AXTruncated"

    /// Decide if an element carries information worth showing an agent.
    public static func interesting(role: String, label: String?, id: String?, value: String?, w: Double, h: Double) -> Bool {
        // The engine's truncation marker has no geometry but must always surface.
        if role == truncatedRole { return true }
        if w <= 0 || h <= 0 { return false }
        if let id = id, !id.isEmpty { return true }
        if interactableRoles.contains(role) { return true }
        if let l = label, !l.isEmpty { return true }
        if let v = value, !v.isEmpty { return true }
        return false
    }

    public init(elements: [[String: Any]], screenW: Double = 0, screenH: Double = 0) {
        self.screenW = screenW
        self.screenH = screenH
        var kept: [UIElement] = []
        var map: [String: UIElement] = [:]
        var n = 0
        for e in elements {
            let role = (e["role"] as? String) ?? ""
            let label = (e["label"] as? String)?.nilIfEmpty
            let id = (e["id"] as? String)?.nilIfEmpty
            let value = (e["value"] as? String)?.nilIfEmpty
            let w = (e["w"] as? Double) ?? 0
            let h = (e["h"] as? Double) ?? 0
            guard Snapshot.interesting(role: role, label: label, id: id, value: value, w: w, h: h) else { continue }
            n += 1
            let x = (e["x"] as? Double) ?? 0
            let y = (e["y"] as? Double) ?? 0
            // On-screen if the rect intersects the viewport (with a small margin).
            let onScreen = screenW <= 0 || screenH <= 0
                || (x + w > -1 && x < screenW + 1 && y + h > -1 && y < screenH + 1)
            let el = UIElement(
                ref: "e\(n)", role: role, label: label, id: id, value: value,
                x: x, y: y, w: w, h: h,
                enabled: (e["enabled"] as? Bool) ?? true,
                depth: (e["depth"] as? Int) ?? 0,
                onScreen: onScreen
            )
            kept.append(el)
            map[el.ref] = el
        }
        self.all = kept
        self.byRef = map
    }

    /// Labels, ids and values come from the app under test — they are untrusted
    /// input, not markup. Escape them so a crafted label can never break out of
    /// its line and forge extra elements (or instructions) in an agent's view:
    /// backslash/quote/newline/tab become visible escapes, other control
    /// characters are dropped, and the result is capped at `limit` characters.
    public static func escaped(_ s: String, limit: Int = 120) -> String {
        var out = ""
        out.reserveCapacity(s.unicodeScalars.count + 8)
        for u in s.unicodeScalars {
            switch u {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                // C0/C1 controls, DEL and the Unicode line/paragraph separators
                // all render as breaks somewhere — none may pass through.
                let v = u.value
                if v < 0x20 || v == 0x7F || (v >= 0x80 && v <= 0x9F) || v == 0x2028 || v == 0x2029 { continue }
                out.unicodeScalars.append(u)
            }
        }
        guard out.count > limit else { return out }
        var cut = String(out.prefix(limit))
        // Never leave half an escape sequence at the cut point.
        var trailing = 0
        for ch in cut.reversed() { if ch == "\\" { trailing += 1 } else { break } }
        if trailing % 2 == 1 { cut.removeLast() }
        return cut + "…"
    }

    public func line(_ e: UIElement) -> String {
        var s = "\(e.ref) \(e.shortRole)"
        if let l = e.label { s += " \"\(Snapshot.escaped(l))\"" }
        if let i = e.id { s += " #\(Snapshot.escaped(i, limit: 80))" }
        if let v = e.value { s += " =\(Snapshot.escaped(v))" }
        s += " @\(e.cx),\(e.cy)"
        if !e.enabled { s += " (disabled)" }
        return s
    }

    public var compact: String { all.map(line).joined(separator: "\n") }
    public var visible: [UIElement] { all.filter { $0.onScreen } }
    public var compactVisible: String { visible.map(line).joined(separator: "\n") }

    /// Resolve a selector to an element:
    ///   eN          -> by ref
    ///   #identifier -> by accessibility id (exact, then contains)
    ///   text        -> by label/value (exact, then contains), case-insensitive
    /// Prefers on-screen, top-most matches.
    public func resolve(_ selector: String) -> UIElement? {
        let sel = selector.trimmingCharacters(in: .whitespaces)
        if sel.hasPrefix("e"), byRef[sel] != nil { return byRef[sel] }
        func pick(_ pred: (UIElement) -> Bool) -> UIElement? {
            all.filter { pred($0) && $0.onScreen }.min(by: { $0.y < $1.y })
                ?? all.first(where: pred)
        }
        if sel.hasPrefix("#") {
            let want = String(sel.dropFirst())
            return pick { $0.id == want } ?? pick { ($0.id ?? "").localizedCaseInsensitiveContains(want) }
        }
        let lower = sel.lowercased()
        return pick { ($0.label?.lowercased() == lower) || ($0.value?.lowercased() == lower) }
            ?? pick { ($0.label?.lowercased().contains(lower) ?? false) || ($0.value?.lowercased().contains(lower) ?? false) }
    }

    public func find(_ query: String) -> [UIElement] {
        let q = query.lowercased()
        return all.filter {
            ($0.label?.lowercased().contains(q) ?? false)
            || ($0.id?.lowercased().contains(q) ?? false)
            || ($0.value?.lowercased().contains(q) ?? false)
            || $0.shortRole.lowercased().contains(q)
        }
    }

    /// Token-saving diff: what changed vs a previous snapshot, keyed by identity.
    public func diff(from prev: Snapshot) -> String {
        let prevByKey = Dictionary(prev.all.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let curByKey = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var lines: [String] = []
        for e in all where prevByKey[e.key] == nil { lines.append("+ \(line(e))") }
        for e in prev.all where curByKey[e.key] == nil { lines.append("- \(prev.line(e))") }
        for e in all {
            if let p = prevByKey[e.key], p.value != e.value || p.label != e.label {
                lines.append("~ \(line(e))")
            }
        }
        return lines.isEmpty ? "(no change)" : lines.joined(separator: "\n")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
