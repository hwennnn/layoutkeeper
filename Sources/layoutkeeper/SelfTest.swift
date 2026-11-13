import Foundation
import ApplicationServices

/// Pure-logic checks that do not need Accessibility: matching, display mapping, stale merge, fingerprints.
enum SelfTest {
    /// A made-up layout with stock apps, for screenshots (`render --demo`).
    static func demoLayout() -> Layout {
        let laptop = DisplayInfo(key: "demo-laptop", name: "Built-in Display", frame: Rect(x: 0, y: 0, w: 1728, h: 1117), isMain: true)
        let big = DisplayInfo(key: "demo-external", name: "Studio Display", frame: Rect(x: 1728, y: -323, w: 2560, h: 1440), isMain: false)
        func w(_ bid: String, _ name: String, _ d: DisplayInfo, _ desktop: Int, _ r: Rect) -> WindowRecord {
            WindowRecord(bundleID: bid, appName: name, title: name, displayKey: d.key, rel: r,
                         abs: Rect(x: r.x + d.frame.x, y: r.y + d.frame.y, w: r.w, h: r.h), minimized: false, index: 0,
                         windowID: nil, space: nil, desktop: desktop, lastSeen: Date(), stale: nil)
        }
        return Layout(fingerprint: "demo", label: "Built-in Display + Studio Display", displays: [laptop, big], savedAt: Date(), windows: [
            w("com.apple.Safari", "Safari", big, 1, Rect(x: 0, y: 30, w: 1500, h: 1410)),
            w("com.apple.Notes", "Notes", big, 1, Rect(x: 1500, y: 30, w: 1060, h: 700)),
            w("com.apple.iCal", "Calendar", big, 1, Rect(x: 1500, y: 730, w: 1060, h: 710)),
            w("com.apple.mail", "Mail", laptop, 2, Rect(x: 0, y: 33, w: 1728, h: 1084)),
            w("com.apple.Terminal", "Terminal", big, 3, Rect(x: 0, y: 30, w: 1280, h: 1410)),
            w("com.apple.dt.Xcode", "Xcode", big, 3, Rect(x: 1280, y: 30, w: 1280, h: 1410)),
            w("com.apple.Music", "Music", laptop, 4, Rect(x: 264, y: 120, w: 1200, h: 840)),
            w("com.apple.MobileSMS", "Messages", laptop, 4, Rect(x: 900, y: 300, w: 760, h: 700)),
        ])
    }

    static func run() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ name: String) { print("\(cond ? "PASS" : "FAIL") \(name)"); if !cond { ok = false } }

        let laptop = DisplayInfo(key: "builtin-1", name: "Built-in", frame: Rect(x: 0, y: 0, w: 1728, h: 1117), isMain: true)
        let lg = DisplayInfo(key: "lg-1", name: "LG", frame: Rect(x: 1728, y: -499, w: 2560, h: 1440), isMain: false)
        let displays = [laptop, lg]

        // fingerprint independent of order, dependent on set
        check(Displays.fingerprint([laptop, lg]) == Displays.fingerprint([lg, laptop]), "fingerprint is order-independent")
        check(Displays.fingerprint([laptop]) != Displays.fingerprint([laptop, lg]), "fingerprint changes with monitor set")
        check(Displays.label(displays) == "Built-in + LG", "label puts main display first")

        // display assignment
        check(Displays.displayFor(CGRect(x: 2000, y: 0, width: 800, height: 600), in: displays)?.key == "lg-1", "window on LG maps to LG")
        check(Displays.displayFor(CGRect(x: 100, y: 100, width: 800, height: 600), in: displays)?.key == "builtin-1", "window on laptop maps to laptop")
        check(Displays.displayFor(CGRect(x: 1600, y: 100, width: 800, height: 600), in: displays)?.key == "lg-1", "straddling window maps to larger overlap")
        check(Displays.displayFor(CGRect(x: 9000, y: 9000, width: 10, height: 10), in: displays) != nil, "offscreen window still maps to nearest")

        // relative -> absolute when the arrangement shifts
        let rec = WindowRecord(bundleID: "a", appName: "A", title: "t", displayKey: "lg-1",
                               rel: Rect(x: 10, y: 20, w: 300, h: 200), abs: Rect(x: 1738, y: -479, w: 300, h: 200), minimized: false, index: 0, windowID: nil, space: nil, desktop: nil, lastSeen: nil, stale: nil)
        let movedLG = DisplayInfo(key: "lg-1", name: "LG", frame: Rect(x: -2560, y: 0, w: 2560, h: 1440), isMain: false)
        let t = Restore.targetFrame(rec, displays: ["lg-1": movedLG])
        check(t.origin.x == -2550 && t.origin.y == 20, "target follows display when arrangement changes")
        check(Restore.targetFrame(rec, displays: [:]).origin.x == 1738, "falls back to absolute frame when display key missing")

        // matching
        func win(_ i: Int, _ title: String, _ f: CGRect, id: UInt32 = 0) -> AXWindow {
            AXWindow(element: AXUIElementCreateSystemWide(), pid: 1, windowID: id, title: title, frame: f, minimized: false, fullscreen: false, index: i)
        }
        func saved(_ i: Int, _ title: String, _ f: CGRect) -> WindowRecord {
            WindowRecord(bundleID: "b", appName: "B", title: title, displayKey: "lg-1", rel: Rect(f), abs: Rect(f), minimized: false, index: i, windowID: nil, space: nil, desktop: nil, lastSeen: nil, stale: nil)
        }
        let s = [saved(0, "Inbox - Gmail", CGRect(x: 0, y: 0, width: 1200, height: 800)),
                 saved(1, "Research Launch Plan", CGRect(x: 100, y: 100, width: 900, height: 700))]
        let c = [win(0, "Research Launch Plan", CGRect(x: 500, y: 500, width: 900, height: 700)),
                 win(1, "Inbox (3) - Gmail", CGRect(x: 0, y: 0, width: 1200, height: 800))]
        let m = Restore.match(saved: s, current: c)
        check(m.count == 2, "matches all windows")
        check(m.first { $0.0.title == "Research Launch Plan" }?.1.index == 0, "exact title wins over index")
        check(m.first { $0.0.title == "Inbox - Gmail" }?.1.index == 1, "size match beats index when titles drift")
        check(Restore.match(saved: [s[0]], current: [c[0]]).count == 1, "single/single always matches")
        check(Restore.match(saved: s, current: [c[0]]).count == 1, "extra saved records are ignored")

        // merge across Spaces / closed apps
        func mk(_ bid: String, _ title: String, id: UInt32?, x: Double = 0) -> WindowRecord {
            WindowRecord(bundleID: bid, appName: bid, title: title, displayKey: "lg-1", rel: Rect(x: x, y: 0, w: 100, h: 100), abs: Rect(x: x, y: 0, w: 100, h: 100), minimized: false, index: 0, windowID: id, space: nil, desktop: nil, lastSeen: Date(), stale: nil, boot: Boot.id)
        }
        let old = Layout(fingerprint: "f", label: "l", displays: displays, savedAt: Date(),
                         windows: [mk("b", "visible", id: 1), mk("b", "other space", id: 2, x: 500), mk("gone", "x", id: 3), mk("c", "closed window", id: 4)])
        let new = Layout(fingerprint: "f", label: "l", displays: displays, savedAt: Date(), windows: [mk("b", "visible renamed", id: 1)])
        let merged = Capture.merge(new: new, old: old, windowCounts: ["b": 2, "c": 1], existingIDs: [1, 2, 9], running: ["b", "c"])
        check(merged.windows.filter { $0.bundleID == "b" }.count == 2, "window on another Space is kept")
        let bRecs = merged.windows.filter { $0.bundleID == "b" }
        let otherSpace = bRecs.first { $0.windowID == 2 }
        let visible = bRecs.first { $0.windowID == 1 }
        check(otherSpace != nil && otherSpace?.stale == nil, "other-Space window is kept and not stale")
        check(visible?.title == "visible renamed", "visible window uses fresh record")
        check(merged.windows.first { $0.bundleID == "gone" }?.stale == true, "quit app's windows are remembered as stale")
        let cRecs = merged.windows.filter { $0.bundleID == "c" }
        check(cRecs.count == 1 && cRecs[0].stale == nil, "running app with a hidden window keeps its record")
        let merged2 = Capture.merge(new: new, old: old, windowCounts: ["b": 1, "c": 0], existingIDs: [1], running: ["b", "c"])
        check(merged2.windows.filter { $0.bundleID == "b" }.count == 1, "closed window of a running app is dropped")
        check(merged2.windows.first { $0.bundleID == "c" }?.stale == true, "running app with no windows keeps a remembered record")
        check(Capture.digest(merged, visibleIDs: [1]) == Capture.digest(new), "digest ignores records from other Spaces and stale records")
        let idMatch = Restore.match(saved: [mk("b", "a", id: 7), mk("b", "b", id: 8)],
                                    current: [win(0, "zzz", CGRect(x: 0, y: 0, width: 100, height: 100), id: 8)])
        check(idMatch.count == 1 && idMatch[0].0.windowID == 8, "window id match beats everything")

        // window ids from an earlier boot mean nothing
        var oldBoot = mk("b", "a", id: 8); oldBoot.boot = 1
        let titled = Restore.match(saved: [oldBoot, mk("b", "zzz", id: 7)],
                                   current: [win(0, "zzz", CGRect(x: 0, y: 0, width: 100, height: 100), id: 8),
                                             win(1, "a", CGRect(x: 0, y: 0, width: 100, height: 100), id: 9)])
        check(titled.first { $0.0.title == "a" }?.1.windowID == 9, "a window id from an earlier boot is ignored")
        var beforeRestart = mk("b", "doc", id: 5); beforeRestart.boot = 1
        let afterRestart = Capture.merge(new: Layout(fingerprint: "f", label: "l", displays: displays, savedAt: Date(), windows: [mk("b", "doc", id: 50)]),
                                         old: Layout(fingerprint: "f", label: "l", displays: displays, savedAt: Date(), windows: [beforeRestart]),
                                         windowCounts: ["b": 1], existingIDs: [50, 5], running: ["b"])
        check(afterRestart.windows.count == 1, "a record from before a restart is not kept next to the same window")

        // closed apps: only the latest sighting is remembered
        var ancient = mk("gone", "older", id: 30); ancient.lastSeen = Date(timeIntervalSinceNow: -86_400); ancient.stale = true
        let remembered = Capture.merge(new: new, old: Layout(fingerprint: "f", label: "l", displays: displays, savedAt: Date(),
                                                              windows: [mk("gone", "x", id: 3), ancient]),
                                       windowCounts: ["b": 1], existingIDs: [1], running: ["b"])
        check(remembered.windows.filter { $0.bundleID == "gone" }.map(\.title) == ["x"], "only a closed app's latest windows are remembered")

        // leftover records never steal a window that already has its place
        let three = [mk("b", "one", id: 1), mk("b", "two", id: 2, x: 500), mk("b", "closed long ago", id: 99, x: 900)]
        let live = [win(0, "one", CGRect(x: 0, y: 0, width: 100, height: 100), id: 1), win(1, "two", CGRect(x: 500, y: 0, width: 100, height: 100), id: 2)]
        let again = Restore.matchIndices(saved: three, current: live)
        check(again.count == 2 && !again.contains { $0.si == 2 }, "a record without a window stays unmatched")
        check((0..<5).allSatisfy { _ in Restore.matchIndices(saved: three, current: live).map(\.si) == again.map(\.si) }, "matching is the same on every pass")

        // which layout restores use
        var file = LayoutFile(fingerprint: "f", label: "l", displays: displays)
        file.pinned = old; file.auto = new
        check(file.preferred(pinnedFirst: false)?.pinned == false, "restores use how the windows were last left")
        check(file.preferred(pinnedFirst: true)?.pinned == true, "preferPinned restores the pinned layout")
        file.auto = nil
        check(file.preferred(pinnedFirst: false)?.pinned == true, "pinned is used when nothing was remembered")

        // clean-up of saved layouts
        var month = mk("old", "x", id: 40); month.stale = true; month.lastSeen = Date(timeIntervalSinceNow: -40 * 86_400)
        var week = mk("recent", "x", id: 41); week.stale = true; week.lastSeen = Date(timeIntervalSinceNow: -7 * 86_400)
        var openOld = mk("b", "left open", id: 42); openOld.lastSeen = Date(timeIntervalSinceNow: -40 * 86_400)
        let messy = Layout(fingerprint: "f", label: "l", displays: displays, savedAt: Date(),
                           windows: [month, week, week, openOld, mk("b", "now", id: 43, x: 300)])
        let tidy = messy.tidied()
        check(!tidy.windows.contains { $0.bundleID == "old" }, "positions of apps closed for over a month are dropped")
        check(tidy.windows.filter { $0.bundleID == "recent" }.count == 1, "duplicate records are dropped")
        check(tidy.windows.filter { $0.bundleID == "b" }.count == 2, "windows of open apps are never dropped by age")
        check(messy.tidied(deep: true).windows.filter { $0.bundleID == "b" }.map(\.title) == ["now"], "deep clean drops records long superseded for the same app")
        check(tidy.open.count == 2 && tidy.remembered.count == 1, "open and remembered windows are told apart")

        // saved frames that ended up off every display are pulled back on
        let fine = CGRect(x: 100, y: 100, width: 800, height: 600)
        check(Restore.onScreen(fine, displays: displays) == fine, "a frame on a display is left alone")
        let lost = Restore.onScreen(CGRect(x: 9000, y: 5000, width: 800, height: 600), displays: displays)
        check(displays.contains { $0.frame.cg.contains(lost) }, "a frame off every display is moved onto the nearest one")
        let huge = Restore.onScreen(CGRect(x: -9000, y: 0, width: 5000, height: 3000), displays: [laptop])
        check(laptop.frame.cg.contains(huge), "an oversized off-screen frame is shrunk to fit")
        let peek = CGRect(x: 1728 + 2560 - 200, y: 0, width: 800, height: 600)
        check(Restore.onScreen(peek, displays: displays) == peek, "a window hanging off the edge with its title bar reachable is left alone")

        // store round trip
        let fp = "selftest-\(UUID().uuidString.prefix(6))"
        var l = new; l.fingerprint = fp
        do {
            try Store.put(l, pinned: true)
            try Store.put(l, pinned: false)
            let f = Store.load(fp)
            check(f?.pinned?.windows.count == 1 && f?.auto?.windows.count == 1, "store round-trips pinned and auto")
        } catch { check(false, "store write: \(error)") }
        Store.delete(fp)
        check(Store.load(fp) == nil, "store delete")

        // layout map geometry: scaled into the view, clipped to its display, filtered by desktop
        var onD1 = rec; onD1.desktop = 1
        var onD2 = rec; onD2.desktop = 2; onD2.rel = Rect(x: 0, y: 0, w: 2560, h: 1440)
        let mapLayout = Layout(fingerprint: "x", label: "L", displays: displays, savedAt: Date(), windows: [onD1, onD2])
        let g = LayoutGeometry(layout: mapLayout, filter: .all, in: CGRect(x: 0, y: 0, width: 430, height: 200), inset: 0)
        let lgRect = g.displays.first { $0.info.key == "lg-1" }!.rect
        check(g.displays.allSatisfy { CGRect(x: 0, y: 0, width: 430, height: 200).insetBy(dx: -1, dy: -1).contains($0.rect) }, "map fits displays into the view")
        check(g.items.count == 2 && g.items.allSatisfy { lgRect.insetBy(dx: -1, dy: -1).contains($0.rect) }, "map places windows on their display")
        check(g.items.first?.rec.desktop == 2, "map draws larger windows first")
        check(LayoutGeometry(layout: mapLayout, filter: .desktop(1), in: CGRect(x: 0, y: 0, width: 430, height: 200)).items.count == 1, "map filters by desktop")
        check(DesktopFilter.present(in: mapLayout) == [.desktop(1), .desktop(2)], "desktops present are listed in order")

        // desktops: after a reconnect macOS has piled the LG's desktops onto the laptop and made one fresh one
        let savedDesks = ["builtin-1": ["a", "b"], "lg-1": ["c", "d"]]
        let piled = ["builtin-1": ["a", "b", "c", "d"], "lg-1": ["fresh"]]
        check(Desktops.plan(saved: savedDesks, current: piled, occupied: []) == [
            .move("c", from: "builtin-1", to: "lg-1", before: nil), .move("d", from: "builtin-1", to: "lg-1", before: nil), .remove("fresh", on: "lg-1")],
              "desktops move back and the empty fresh one goes")
        check(!Desktops.plan(saved: savedDesks, current: piled, occupied: ["fresh"]).contains(.remove("fresh", on: "lg-1")),
              "a desktop with windows is never removed")
        check(Desktops.plan(saved: savedDesks, current: savedDesks, occupied: []).isEmpty, "nothing to do when desktops are in place")
        check(Desktops.plan(saved: ["builtin-1": ["a"], "lg-1": ["x", "y", "z"]], current: ["builtin-1": ["a"], "lg-1": ["new"]], occupied: [])
              == [.add(on: "lg-1"), .add(on: "lg-1")], "missing desktops (e.g. after a restart) are added")
        var swapped = ["builtin-1": ["c"], "lg-1": ["a", "b"]]
        var neverEmpty = true
        for step in Desktops.plan(saved: ["builtin-1": ["a", "b"], "lg-1": ["c"]], current: swapped, occupied: []) {
            guard case .move(let k, let from, let to, let before) = step else { continue }
            swapped[from]!.removeAll { $0 == k }
            swapped[to]!.insert(k, at: before.flatMap { swapped[to]!.firstIndex(of: $0) } ?? swapped[to]!.count)
            if swapped[from]!.isEmpty { neverEmpty = false }
        }
        check(neverEmpty && swapped["builtin-1"] == ["a", "b"] && swapped["lg-1"] == ["c"],
              "swapped desktops all go home, in order, without leaving a display empty")
        check(Desktops.plan(saved: ["builtin-1": ["a"], "lg-1": ["c", "d"]], current: ["builtin-1": ["a", "c"], "lg-1": ["d"]], occupied: [])
              == [.move("c", from: "builtin-1", to: "lg-1", before: "d")], "a desktop goes back into its old slot")

        print(ok ? "selftest OK" : "selftest FAILED")
        return ok
    }
}
