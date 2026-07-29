import Foundation
import CoreGraphics
import ImageIO
import Vision
import TestaKit

// Visual regression — pixels, with an OCR layer on top.
//
// A bare "3.1% of pixels differ" is not actionable: it could be a broken layout
// or it could be the clock ticking. So after the pixel pass we run Vision over
// *both* images and report which text disappeared and which appeared. That
// usually turns the percentage into a sentence a human can act on.
//
// Everything here is Apple-only: CoreGraphics/ImageIO for the pixels, Vision for
// the text. No third-party image library.
enum VDiff {

    /// Pixels are compared on a small grid (this wide, aspect preserved). Scaling
    /// both images through the same filter is what makes the comparison immune to
    /// antialiasing noise — and it keeps a full-resolution retina diff fast.
    static let gridWidth = 400
    /// Per-channel delta that counts as "different" (0-255).
    static let channelThreshold = 24
    /// Cap on the OCR lines reported in each direction.
    static let maxTextLines = 10

    struct Outcome {
        var ok: Bool
        var text: String
    }

    // MARK: - Entry point

    /// Compare `current` against `baseline`, writing a heatmap to `diffPath`.
    static func compare(baseline: String, current: String, diffPath: String,
                        tolerancePct: Double) -> Outcome {
        guard let base = load(baseline) else {
            return Outcome(ok: false, text: "cannot read baseline image: \(baseline)")
        }
        guard let cur = load(current) else {
            return Outcome(ok: false, text: "cannot read screenshot: \(current)")
        }
        guard base.width == cur.width, base.height == cur.height else {
            return Outcome(ok: false, text: """
                vdiff FAIL size changed — baseline \(base.width)x\(base.height)px, \
                current \(cur.width)x\(cur.height)px (different device, orientation or scale)
                """)
        }

        let w = Swift.max(1, Swift.min(gridWidth, base.width))
        let h = Swift.max(1, Int((Double(base.height) * Double(w) / Double(base.width)).rounded()))
        guard let a = render(base, w: w, h: h), let b = render(cur, w: w, h: h) else {
            return Outcome(ok: false, text: "cannot rasterize images for comparison")
        }

        var mismatch = [Bool](repeating: false, count: w * h)
        var differing = 0
        for i in 0..<(w * h) {
            let p = i * 4
            let d = Swift.max(Swift.max(delta(a[p], b[p]), delta(a[p + 1], b[p + 1])), delta(a[p + 2], b[p + 2]))
            if d > channelThreshold { mismatch[i] = true; differing += 1 }
        }
        let pct = Double(differing) * 100.0 / Double(w * h)

        var lines: [String] = []
        let wrote = writeHeatmap(current: b, mismatch: mismatch, w: w, h: h, to: diffPath)
        let pass = pct <= tolerancePct
        let cmp = pass ? "≤" : ">"
        var verdict = "vdiff \(pass ? "PASS" : "FAIL") \(fmt(pct))% \(cmp) \(fmt(tolerancePct))%"
        if !pass { verdict += wrote ? " — diff: \(diffPath)" : " — (could not write diff heatmap)" }
        lines.append(verdict)

        // Identical pixels can't hide a text change, so skip the OCR round-trip.
        if differing > 0 {
            let (lost, added) = textDiff(baseline: recognize(base), current: recognize(cur))
            if !lost.isEmpty { lines.append("- lost: " + quoteList(lost)) }
            if !added.isEmpty { lines.append("+ new: " + quoteList(added)) }
            if lost.isEmpty && added.isEmpty {
                lines.append("(no text changed — the difference is purely visual)")
            }
        }
        return Outcome(ok: pass, text: lines.joined(separator: "\n"))
    }

    // MARK: - Pixels

    static func load(_ path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil),
              CGImageSourceGetCount(src) > 0 else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Draw an image into a w×h RGBA8 buffer (both sides go through this, so the
    /// same resampling is applied to both).
    static func render(_ img: CGImage, w: Int, h: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }

    static func delta(_ x: UInt8, _ y: UInt8) -> Int { abs(Int(x) - Int(y)) }

    /// Washed-out grayscale of the current screen with every mismatching pixel in
    /// red — so "where did it change" is one glance, not a hunt.
    @discardableResult
    static func writeHeatmap(current: [UInt8], mismatch: [Bool], w: Int, h: Int, to path: String) -> Bool {
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            let p = i * 4
            if mismatch[i] {
                out[p] = 235; out[p + 1] = 32; out[p + 2] = 42
            } else {
                let lum = 0.299 * Double(current[p]) + 0.587 * Double(current[p + 1])
                        + 0.114 * Double(current[p + 2])
                let faded = UInt8(Swift.min(255, Swift.max(0, lum * 0.55 + 96)))
                out[p] = faded; out[p + 1] = faded; out[p + 2] = faded
            }
            out[p + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false,
                                intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                         "public.png" as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
    }

    // MARK: - Text (Vision)

    /// Every recognized string, top of the screen first.
    static func recognize(_ img: CGImage) -> [String] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: img, options: [:])
        guard (try? handler.perform([req])) != nil,
              let obs = req.results else { return [] }
        // Vision's origin is bottom-left: larger y is higher on screen.
        return obs.sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
            .compactMap { $0.topCandidates(1).first?.string }
    }

    /// Text present in exactly one of the two screens, in reading order.
    static func textDiff(baseline: [String], current: [String],
                         limit: Int = maxTextLines) -> (lost: [String], new: [String]) {
        func norm(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let baseKeys = Set(baseline.map(norm).filter { !$0.isEmpty })
        let curKeys = Set(current.map(norm).filter { !$0.isEmpty })
        func only(_ list: [String], missingFrom other: Set<String>) -> [String] {
            var seen = Set<String>()
            var out: [String] = []
            for s in list {
                let k = norm(s)
                guard !k.isEmpty, !other.contains(k), seen.insert(k).inserted else { continue }
                out.append(s)
                if out.count == limit { break }
            }
            return out
        }
        return (only(baseline, missingFrom: curKeys), only(current, missingFrom: baseKeys))
    }

    // MARK: - Formatting

    /// Screen text is untrusted input — escape it exactly like the tree lines do.
    static func quoteList(_ items: [String]) -> String {
        items.map { "\"\(Snapshot.escaped($0, limit: 60))\"" }.joined(separator: ", ")
    }

    static func fmt(_ pct: Double) -> String {
        String(format: pct > 0 && pct < 0.1 ? "%.2f" : "%.1f", pct)
    }
}
