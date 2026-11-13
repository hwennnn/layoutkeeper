import Foundation
import CoreGraphics

struct Rect: Codable, Equatable {
    var x: Double, y: Double, w: Double, h: Double
    init(_ r: CGRect) { x = r.origin.x; y = r.origin.y; w = r.size.width; h = r.size.height }
    init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
    var cg: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    var short: String { "\(Int(x)),\(Int(y)) \(Int(w))x\(Int(h))" }
}

struct DisplayInfo: Codable {
    var key: String
    var name: String
    var frame: Rect
    var isMain: Bool
}

struct WindowRecord: Codable {
    var bundleID: String
    var appName: String
    var title: String
    var displayKey: String
    /// Frame relative to the top-left of its display (AX / CG coordinates, y down).
    var rel: Rect
    /// Absolute frame in global AX coordinates.
    var abs: Rect
    var minimized: Bool
    var index: Int
    /// CoreGraphics window id; valid until the app quits or the Mac restarts. Used to track windows across Spaces.
    var windowID: UInt32?
    /// Space id and user-facing desktop number the window was on when captured (informational).
    var space: UInt64?
    var desktop: Int?
    var lastSeen: Date?
    /// True when carried over from an earlier snapshot because the app was not running (or had no windows).
    var stale: Bool?
    /// Boot session `windowID` belongs to. Window ids are reused after a restart, so an id from another boot means nothing.
    var boot: Int? = nil

    /// The window id, if it can still refer to a live window.
    var liveID: UInt32? { boot == Boot.id ? windowID : nil }
}

enum Boot {
    /// Seconds since 1970 at which this Mac started; identifies the boot session.
    static let id: Int = {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        return sysctl(&mib, 2, &tv, &size, nil, 0) == 0 ? Int(tv.tv_sec) : 0
    }()
}

struct Layout: Codable {
    var fingerprint: String
    var label: String
    var displays: [DisplayInfo]
    var savedAt: Date
    var windows: [WindowRecord]
    /// Desktops (Spaces) per display key, in "Desktop N" order, as `Desktops.current()` reports them.
    var desktops: [String: [String]]? = nil

    /// Windows of apps that were open when this was saved (not just remembered from an earlier time).
    var open: [WindowRecord] { windows.filter { $0.stale != true } }
    var remembered: [WindowRecord] { windows.filter { $0.stale == true } }

    /// Drop what no longer helps: exact duplicates, and positions remembered for apps not seen for `maxAge`.
    /// `deep` (one-time clean-up of files written by older versions) also drops, per app, every record older
    /// than a day before that app's latest sighting: those were kept by mistake for windows long gone.
    func tidied(now: Date = Date(), maxAge: TimeInterval = 30 * 86_400, deep: Bool = false) -> Layout {
        var out = self
        var newest: [String: Date] = [:]
        for w in windows { if let d = w.lastSeen, d > (newest[w.bundleID] ?? .distantPast) { newest[w.bundleID] = d } }
        var seen = Set<String>()
        out.windows = windows.filter { w in
            if w.stale == true, let d = w.lastSeen, now.timeIntervalSince(d) > maxAge { return false }
            if deep, let n = newest[w.bundleID] {
                guard let d = w.lastSeen, n.timeIntervalSince(d) < 86_400 else { return false }
            }
            return seen.insert("\(w.bundleID)|\(w.title)|\(w.displayKey)|\(w.rel.short)|\(w.minimized)|\(w.desktop ?? -1)").inserted
        }
        return out
    }
}

struct LayoutFile: Codable {
    /// 2: cleaned of the phantom records older versions kept.
    var schema: Int? = nil
    static let currentSchema = 2
    var fingerprint: String
    var label: String
    var displays: [DisplayInfo]
    /// Explicitly saved by the user with `layoutkeeper save`. Wins over `auto`.
    var pinned: Layout?
    /// Continuously updated by the watcher: "how I left it last time".
    var auto: Layout?

    /// The layout restores use: how the windows were last left, unless the user asked for the pinned one.
    func preferred(pinnedFirst: Bool) -> (layout: Layout, pinned: Bool)? {
        if pinnedFirst, let p = pinned { return (p, true) }
        if let a = auto { return (a, false) }
        return pinned.map { ($0, true) }
    }
}

struct Config: Codable {
    var restoreOnDisplayChange = true
    var restoreDesktops = true
    var autosave = true
    var placeOnLaunch = true
    var launchMissingApps = false
    /// Restore the pinned layout instead of the automatically remembered one.
    var preferPinned = false
    var menuBarIcon = true
    var pollSeconds = 5.0
    var autosaveEveryTicks = 3
    var debounceSeconds = 4.0
    var ignoreBundleIDs: [String] = ["com.apple.finder"]

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        restoreOnDisplayChange = try c.decodeIfPresent(Bool.self, forKey: .restoreOnDisplayChange) ?? true
        restoreDesktops = try c.decodeIfPresent(Bool.self, forKey: .restoreDesktops) ?? true
        autosave = try c.decodeIfPresent(Bool.self, forKey: .autosave) ?? true
        placeOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .placeOnLaunch) ?? true
        launchMissingApps = try c.decodeIfPresent(Bool.self, forKey: .launchMissingApps) ?? false
        preferPinned = try c.decodeIfPresent(Bool.self, forKey: .preferPinned) ?? false
        menuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .menuBarIcon) ?? true
        pollSeconds = try c.decodeIfPresent(Double.self, forKey: .pollSeconds) ?? 5.0
        autosaveEveryTicks = try c.decodeIfPresent(Int.self, forKey: .autosaveEveryTicks) ?? 3
        debounceSeconds = try c.decodeIfPresent(Double.self, forKey: .debounceSeconds) ?? 4.0
        ignoreBundleIDs = try c.decodeIfPresent([String].self, forKey: .ignoreBundleIDs) ?? ["com.apple.finder"]
    }
}
