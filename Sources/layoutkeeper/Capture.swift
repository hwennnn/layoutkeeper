import AppKit
import CryptoKit
import Foundation

enum Capture {
    static func layout(config: Config, displays: [DisplayInfo]? = nil) -> Layout {
        let displays = displays ?? Displays.current()
        var recs: [WindowRecord] = []
        let spaceIndex = PrivateAPI.spaceIndex()
        for app in AX.apps(ignore: Set(config.ignoreBundleIDs)) {
            for w in app.windows where !w.fullscreen && w.frame.width >= 40 && w.frame.height >= 40 {
                guard let d = Displays.displayFor(w.frame, in: displays) else { continue }
                let rel = w.frame.offsetBy(dx: -d.frame.x, dy: -d.frame.y)
                recs.append(WindowRecord(bundleID: app.bundleID, appName: app.name, title: w.title,
                                         displayKey: d.key, rel: Rect(rel), abs: Rect(w.frame),
                                         minimized: w.minimized, index: w.index,
                                         windowID: w.windowID == 0 ? nil : w.windowID,
                                         space: w.space == 0 ? nil : w.space,
                                         desktop: w.space == 0 ? nil : PrivateAPI.desktopNumber(of: w.space),
                                         lastSeen: Date(), stale: nil, boot: Boot.id,
                                         spaceKey: spaceIndex[w.space]?.key))
            }
        }
        return Layout(fingerprint: Displays.fingerprint(displays), label: Displays.label(displays),
                      displays: displays, savedAt: Date(), windows: recs, desktops: Desktops.current())
    }

    /// Cheap change detector over the windows visible right now: ignores titles (browser tabs flip constantly)
    /// but tracks frames + minimized state. Records carried over from other Spaces or closed apps are excluded.
    static func digest(_ layout: Layout, visibleIDs: Set<UInt32>? = nil) -> String {
        let parts = layout.windows.filter { $0.stale != true && (visibleIDs == nil || $0.windowID.map { visibleIDs!.contains($0) } ?? true) }
            .map { "\($0.bundleID)|\($0.abs.short)|\($0.minimized)" }.sorted()
            + (layout.desktops ?? [:]).sorted { $0.key < $1.key }.map { "desktops \($0.key): \($0.value.joined(separator: ","))" }
        let d = SHA256.hash(data: Data(parts.joined(separator: "\n").utf8))
        return d.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// A fresh capture, plus the same capture merged with what is already known about windows that cannot
    /// be seen right now (other Spaces) and about apps that are closed.
    static func snapshot(config: Config) -> (fresh: Layout, merged: Layout) {
        let fresh = layout(config: config)
        let real = WindowList.real()
        let running = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier))
        let merged = merge(new: fresh, old: Store.load(fresh.fingerprint)?.auto, windowCounts: WindowList.counts(real),
                           existingIDs: Set(real.map(\.id)), running: running)
        return (fresh, merged)
    }

    /// Some windows cannot be read while they are on another Space, so a fresh capture can be partial. Merge it
    /// with the previous layout: keep records for windows that still exist but were not captured (matched by
    /// window id, or by count when the id is from an earlier boot), and keep the latest records of apps that
    /// are closed as "remembered" (stale) so place-on-launch knows where they belong.
    /// - windowCounts: number of real windows per bundle id across all Spaces.
    /// - existingIDs: ids of real windows that exist right now.
    /// - running: bundle ids of running regular apps.
    static func merge(new: Layout, old: Layout?, windowCounts: [String: Int], existingIDs: Set<UInt32>, running: Set<String>,
                      now: Date = Date()) -> Layout {
        guard let old else { return new }
        var merged = new
        let newIDs = Set(new.windows.compactMap(\.liveID))
        let newByBundle = Dictionary(grouping: new.windows, by: \.bundleID)
        for (bid, recs) in Dictionary(grouping: old.windows, by: \.bundleID).sorted(by: { $0.key < $1.key }) {
            let unmatched = recs.filter { r in r.liveID.map { !newIDs.contains($0) } ?? true }
            if unmatched.isEmpty { continue }
            let fresh = newByBundle[bid] ?? []
            let total = windowCounts[bid] ?? 0
            if !running.contains(bid) || total == 0 {
                if !fresh.isEmpty { continue }
                merged.windows += latest(unmatched).map { var r = $0; r.stale = true; return r }
                continue
            }
            // App is running: how many of its windows did the capture miss?
            let hidden = max(total - fresh.count, 0)
            if hidden == 0 { continue }
            var keep = unmatched.filter { $0.liveID.map(existingIDs.contains) ?? false }.map { r -> WindowRecord in
                var r = r; r.lastSeen = now; return r   // the window is still there, just out of reach
            }
            if keep.count < hidden {
                // Not identifiable by id. Drop the records that look like a window captured just now, then take
                // the most recently seen of the rest.
                var pool = unmatched.filter { r in !(r.liveID.map(existingIDs.contains) ?? false) }
                let oldIDs = Set(recs.compactMap(\.liveID))
                for f in fresh where !(f.liveID.map(oldIDs.contains) ?? false) {
                    let i = pool.firstIndex { $0.title == f.title && $0.abs == f.abs }
                        ?? pool.firstIndex { !f.title.isEmpty && $0.title == f.title }
                        ?? pool.firstIndex { $0.abs == f.abs }
                    if let i { pool.remove(at: i) }
                }
                pool.sort { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
                keep += pool.prefix(hidden - keep.count)
            }
            merged.windows += keep.prefix(hidden).map { var r = $0; r.stale = nil; return r }
        }
        return merged.tidied(now: now)
    }

    /// The records from an app's most recent sighting; older ones describe windows it no longer had.
    private static func latest(_ recs: [WindowRecord]) -> [WindowRecord] {
        guard let newest = recs.compactMap(\.lastSeen).max() else { return recs }
        return recs.filter { $0.lastSeen.map { newest.timeIntervalSince($0) < 60 } ?? false }
    }

    /// Ids of every window that exists on any Space.
    static func existingWindowIDs() -> Set<UInt32> {
        Set(WindowList.real().map(\.id))
    }
}
