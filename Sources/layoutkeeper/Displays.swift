import AppKit
import CoreGraphics
import CryptoKit

enum Displays {
    static func current() -> [DisplayInfo] { withIDs().map(\.1) }

    /// Display keys by the UUID macOS uses for the display in its Spaces configuration.
    static func keysByUUID() -> [String: String] {
        var out: [String: String] = [:]
        for (id, d) in withIDs() {
            guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let s = CFUUIDCreateString(nil, u) as String? else { continue }
            out[s] = d.key
            if d.isMain { out["Main"] = d.key }
        }
        return out
    }

    private static func withIDs() -> [(CGDirectDisplayID, DisplayInfo)] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(max(count, 1)))
        CGGetActiveDisplayList(count, &ids, &count)

        var names: [CGDirectDisplayID: String] = [:]
        for s in NSScreen.screens {
            if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[CGDirectDisplayID(n.uint32Value)] = s.localizedName
            }
        }

        var seen: [String: Int] = [:]
        var out: [(CGDirectDisplayID, DisplayInfo)] = []
        for id in ids.prefix(Int(count)) {
            // Skip displays that merely mirror another one.
            if CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay { continue }
            // Vendor "unkn": the placeholder display macOS reports while the real ones are asleep or switching.
            if CGDisplayVendorNumber(id) == 0x756E_6B6E { continue }
            var key = "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
            if CGDisplayIsBuiltin(id) != 0 { key = "builtin-" + key }
            let n = seen[key, default: 0]
            seen[key] = n + 1
            if n > 0 { key += "#\(n)" }
            out.append((id, DisplayInfo(key: key,
                                        name: names[id] ?? "Display \(id)",
                                        frame: Rect(CGDisplayBounds(id)),
                                        isMain: CGDisplayIsMain(id) != 0)))
        }
        return out.sorted { $0.1.key < $1.1.key }
    }

    static func fingerprint(_ displays: [DisplayInfo]) -> String {
        let joined = displays.map(\.key).sorted().joined(separator: "|")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    static func label(_ displays: [DisplayInfo]) -> String {
        let ordered = displays.sorted { a, b in
            if a.isMain != b.isMain { return a.isMain }
            return a.key < b.key
        }
        return ordered.map(\.name).joined(separator: " + ")
    }

    /// The display a window belongs to: largest intersection, else nearest center.
    static func displayFor(_ frame: CGRect, in displays: [DisplayInfo]) -> DisplayInfo? {
        var best: (DisplayInfo, CGFloat)?
        for d in displays {
            let inter = d.frame.cg.intersection(frame)
            let area = inter.isNull ? 0 : inter.width * inter.height
            if area > 0, area > (best?.1 ?? 0) { best = (d, area) }
        }
        if let b = best { return b.0 }
        let c = CGPoint(x: frame.midX, y: frame.midY)
        return displays.min { a, b in
            hypot(a.frame.cg.midX - c.x, a.frame.cg.midY - c.y) < hypot(b.frame.cg.midX - c.x, b.frame.cg.midY - c.y)
        }
    }
}
