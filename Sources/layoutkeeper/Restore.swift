import AppKit

struct RestoreResult {
    var moved = 0
    var alreadyInPlace = 0
    var failed = 0
    var missingApps: [String] = []
    /// Display names of `missingApps`, for the menu.
    var missingNames: [String] = []
    var launched: [String] = []
    /// Saved windows whose live window exists but cannot be reached yet (another Space, or the app is not
    /// answering). `waitingIdx` are their positions in the layout; they are retried when the Space changes.
    var waiting: [WindowRecord] = []
    var waitingIdx: [Int] = []
    /// Windows on a visible desktop that could not be reached (hidden app, or the app is not answering).
    var unreachable = 0
    /// Apps whose windows were sent back to the desktop they were saved on.
    var respaced: [String] = []
    /// Windows left alone for now because their desktop is still parked on another display.
    var deferred = 0
    /// Apps in the layout that were too busy to answer; their windows still need placing.
    var busy: [String] = []
    /// Nothing could be read at all although windows exist: the screen is locked or apps are still waking.
    var blind: Bool { moved + alreadyInPlace + failed == 0 && (!waiting.isEmpty || unreachable > 0) }
    var summary: String {
        var s = "moved \(moved), in place \(alreadyInPlace), failed \(failed)"
        if !respaced.isEmpty { s += ", sent back to their desktop: \(respaced.joined(separator: ","))" }
        if !waiting.isEmpty { s += ", \(waiting.count) on other Spaces (placed when you switch there)" }
        if !launched.isEmpty { s += ", launched \(launched.joined(separator: ","))" }
        if !missingApps.isEmpty { s += ", not running: \(missingApps.joined(separator: ","))" }
        return s
    }
    /// One-line version for the menu bar.
    var short: String {
        var parts = ["\(moved) moved", "\(alreadyInPlace) in place"]
        if !respaced.isEmpty { parts.append("\(respaced.count) app\(respaced.count == 1 ? "" : "s") sent back to their desktop") }
        if failed > 0 { parts.append("\(failed) failed") }
        if !waiting.isEmpty { parts.append("\(waiting.count) waiting on other desktops") }
        if !busy.isEmpty { parts.append("\(busy.joined(separator: ", ")) busy, will retry") }
        if !missingNames.isEmpty { parts.append("\(missingNames.count) app\(missingNames.count == 1 ? "" : "s") not running") }
        return parts.joined(separator: " · ")
    }
}

enum Restore {
    /// Windows whose app refused the saved size: the size it settled on instead, so the next pass sees them as placed.
    private static var clamped: [CGWindowID: (want: CGSize, got: CGSize)] = [:]
    /// Failures already reported, so a window that cannot be moved is logged once, not on every pass.
    private static var reported = Set<String>()
    private static var busy = false

    /// - onlyIndices: positions in `layout.windows` to act on. Matching still considers every record, so a
    ///   window that already has its place is never handed a leftover record.
    /// - toDesktops: also send apps back to the desktop they were saved on (not for place-on-launch: an app the
    ///   user just opened should stay in front of them).
    static func apply(_ layout: Layout, config: Config, onlyBundle: String? = nil, onlyIndices: Set<Int>? = nil,
                      launchMissing: Bool = false, dryRun: Bool = false, toDesktops: Bool = false) -> RestoreResult {
        var result = RestoreResult()
        let displays = Displays.current()
        // `launchMissing` spins the run loop; a timer firing meanwhile must not start a second restore inside this one.
        guard !displays.isEmpty, !busy else { return result }
        busy = true
        defer { busy = false }
        let byKey = Dictionary(displays.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })

        var saved = Dictionary(grouping: Array(layout.windows.enumerated()), by: \.element.bundleID)
        if let onlyBundle { saved = saved.filter { $0.key == onlyBundle } }
        if let onlyIndices { saved = saved.filter { $0.value.contains { onlyIndices.contains($0.offset) } } }
        guard !saved.isEmpty else { return result }

        // Apps that had windows when the layout was saved; apps only remembered from earlier are not "missing".
        let open = Set(saved.filter { $0.value.contains { $0.element.stale != true } }.keys)
        var apps = AX.apps(ignore: Set(config.ignoreBundleIDs), only: onlyBundle, retryAfter: 2)
        var running = Set(apps.map(\.bundleID))

        if launchMissing && !dryRun {
            for bid in open.sorted() where !running.contains(bid) {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { continue }
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = false
                NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, err in
                    if let err { Log.warn("launch \(bid): \(err.localizedDescription)") }
                }
                result.launched.append(bid)
            }
            if !result.launched.isEmpty {
                let deadline = Date().addingTimeInterval(20)
                while Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(1))
                    apps = AX.apps(ignore: Set(config.ignoreBundleIDs), only: onlyBundle)
                    let ready = result.launched.allSatisfy { bid in apps.first { $0.bundleID == bid }?.windows.isEmpty == false }
                    if ready { break }
                }
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                apps = AX.apps(ignore: Set(config.ignoreBundleIDs), only: onlyBundle)
                running = Set(apps.map(\.bundleID))
            }
        }

        var real = Dictionary(grouping: WindowList.real(), by: \.pid)
        let visibleSpaces = PrivateAPI.visibleSpaces
        let spaceIndex = PrivateAPI.spaceIndex()
        let displayOfUUID = Displays.keysByUUID()
        for var app in apps {
            guard let recs = saved[app.bundleID] else { continue }
            if !app.answered, recs.contains(where: { $0.element.stale != true }) { result.busy.append(app.name) }
            if toDesktops && config.moveWindowsToDesktops && onlyIndices == nil,
               let target = homeSpace(recs.map(\.element), spaceIndex: spaceIndex) {
                let mine = real[app.app.processIdentifier] ?? []
                // Only when every window sits on an ordinary desktop: full-screen windows own their Space.
                if !mine.isEmpty, mine.allSatisfy({ spaceIndex[$0.space]?.userDesktop == true }), mine.contains(where: { $0.space != target }) {
                    result.respaced.append(app.name)
                    if !dryRun, PrivateAPI.moveApp(pid: app.app.processIdentifier, toSpace: target) {
                        Log.info("\(app.name): moved back to its desktop")
                        usleep(250_000)
                        real = Dictionary(grouping: WindowList.real(), by: \.pid)
                        if let fresh = AX.apps(ignore: [], only: app.bundleID).first(where: { $0.app.processIdentifier == app.app.processIdentifier }) { app = fresh }
                    }
                }
            }
            let current = app.windows.filter { !$0.fullscreen }
            let pairs = matchIndices(saved: recs.map(\.element), current: current)
            // Records left over: as many as the app has windows we could not reach are waiting for their window;
            // any beyond that describe windows that no longer exist.
            let reached = Set(app.windows.map(\.windowID))
            let out = (real[app.app.processIdentifier] ?? []).filter { !reached.contains($0.id) }
            var elsewhere = out.filter { !visibleSpaces.contains($0.space) }.count
            result.unreachable += out.count - elsewhere
            let matched = Set(pairs.map(\.si))
            for (i, r) in recs.enumerated() where !matched.contains(i) && r.element.stale != true && elsewhere > 0 {
                result.waiting.append(r.element); result.waitingIdx.append(r.offset)
                elsewhere -= 1
            }
            for p in pairs {
                let rec = recs[p.si].element, win = current[p.ci]
                if let onlyIndices, !onlyIndices.contains(recs[p.si].offset) { continue }
                let target = onScreen(targetFrame(rec, displays: byKey), displays: displays)
                // A window on a desktop that is not showing and is still parked on another display must wait:
                // moving it across now would pull it out of its desktop onto whatever that display shows.
                let space = win.space != 0 ? win.space : (real[win.pid]?.first { $0.id == win.windowID }?.space ?? 0)
                if let home = spaceIndex[space], !visibleSpaces.contains(space), let dk = displayOfUUID[home.display],
                   byKey[rec.displayKey] != nil, dk != rec.displayKey {
                    result.deferred += 1
                    result.waiting.append(rec); result.waitingIdx.append(recs[p.si].offset)
                    continue
                }
                var inPlace = AX.approx(win.frame, target)
                if !inPlace, let c = clamped[win.windowID], c.want == target.size, AX.approx(CGRect(origin: target.origin, size: c.got), win.frame) {
                    inPlace = true
                }
                if inPlace && win.minimized == rec.minimized { result.alreadyInPlace += 1; continue }
                Log.debug("\(app.name) '\(win.title.prefix(40))' \(Rect(win.frame).short) -> \(Rect(target).short)\(rec.minimized ? " (min)" : "")")
                if dryRun { result.moved += 1; continue }
                if win.minimized && !rec.minimized { AX.setBool(win.element, kAXMinimizedAttribute as String, false); usleep(150_000) }
                let got = inPlace ? win.frame : AX.setFrame(win.element, target)
                if rec.minimized && !win.minimized { AX.setBool(win.element, kAXMinimizedAttribute as String, true) }
                if let got, AX.approx(got, target, tol: 4) || rec.minimized || inPlace {
                    result.moved += 1
                    clamped[win.windowID] = nil
                } else if let got, abs(got.minX - target.minX) <= 4, abs(got.minY - target.minY) <= 4 {
                    // Right place, but the app insists on its own size (fixed-size or min/max-size windows).
                    result.moved += 1
                    if win.windowID != 0 { clamped[win.windowID] = (target.size, got.size) }
                    Log.debug("\(app.name) '\(win.title.prefix(40))' keeps its own size \(Int(got.width))x\(Int(got.height))")
                } else {
                    result.failed += 1
                    let line = "\(app.name) '\(win.title.prefix(40))' wanted \(Rect(target).short), got \(got.map { Rect($0).short } ?? "nil")"
                    if reported.insert("\(win.windowID)|\(line)").inserted { Log.warn(line) }
                    if reported.count > 2000 { reported.removeAll() }
                }
            }
        }
        result.missingApps = open.filter { !running.contains($0) }.sorted()
        result.missingNames = result.missingApps.map { saved[$0]?.first?.element.appName ?? $0 }
        return result
    }

    static func targetFrame(_ rec: WindowRecord, displays: [String: DisplayInfo]) -> CGRect {
        if let d = displays[rec.displayKey] {
            return rec.rel.cg.offsetBy(dx: d.frame.x, dy: d.frame.y)
        }
        return rec.abs.cg
    }

    /// The one desktop all of an app's saved windows were on, if it still exists. Apps spread over several
    /// desktops are left alone: the system call moves all of an app's windows together.
    static func homeSpace(_ recs: [WindowRecord], spaceIndex: [UInt64: (key: String, display: String, userDesktop: Bool)]) -> UInt64? {
        let live = recs.filter { $0.stale != true }
        let use = live.isEmpty ? recs : live
        var ids = Set<UInt64>()
        for r in use {
            if let key = r.spaceKey, let hit = spaceIndex.first(where: { $0.value.key == key }) { ids.insert(hit.key) }
            else if r.spaceKey == nil, r.boot == Boot.id, let s = r.space, spaceIndex[s] != nil { ids.insert(s) }
            else { return nil }   // a window whose desktop is gone or unknown: do not guess
        }
        guard ids.count == 1, let id = ids.first, spaceIndex[id]?.userDesktop == true else { return nil }
        return id
    }

    /// A saved frame can end up outside every display (resolution changed, display swapped for a smaller one).
    /// Keep enough of the title bar on a display to grab the window; frames that are fine come back unchanged.
    static func onScreen(_ f: CGRect, displays: [DisplayInfo]) -> CGRect {
        let grab = CGRect(x: f.minX, y: f.minY, width: f.width, height: min(f.height, 40))
        if displays.contains(where: { d in
            let i = d.frame.cg.intersection(grab)
            return !i.isNull && i.width >= min(120, f.width) && i.height >= min(20, f.height)
        }) { return f }
        guard let d = Displays.displayFor(f, in: displays)?.frame.cg else { return f }
        var r = f
        r.size.width = min(r.width, d.width); r.size.height = min(r.height, d.height)
        r.origin.x = min(max(r.minX, d.minX), d.maxX - r.width)
        r.origin.y = min(max(r.minY, d.minY), d.maxY - r.height)
        return r
    }

    private static func norm(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Greedy best-score assignment of saved records to live windows of one app.
    static func match(saved: [WindowRecord], current: [AXWindow]) -> [(WindowRecord, AXWindow)] {
        matchIndices(saved: saved, current: current).map { (saved[$0.si], current[$0.ci]) }
    }

    static func matchIndices(saved: [WindowRecord], current: [AXWindow]) -> [(si: Int, ci: Int)] {
        if saved.isEmpty || current.isEmpty { return [] }
        if saved.count == 1 && current.count == 1 { return [(0, 0)] }
        var cands: [(score: Int, si: Int, ci: Int)] = []
        for (si, s) in saved.enumerated() {
            for (ci, c) in current.enumerated() {
                var score = 0
                if let id = s.liveID, id == c.windowID { score += 1000 }
                let st = norm(s.title), ct = norm(c.title)
                if !st.isEmpty && st == ct { score += 100 }
                else if !st.isEmpty && !ct.isEmpty && (st.contains(ct) || ct.contains(st)) { score += 50 }
                if abs(s.abs.w - c.frame.width) < 2 && abs(s.abs.h - c.frame.height) < 2 { score += 20 }
                if abs(s.abs.x - c.frame.minX) < 2 && abs(s.abs.y - c.frame.minY) < 2 { score += 15 }
                if s.minimized == c.minimized { score += 5 }
                if s.stale != true { score += 3 }
                if s.index == c.index { score += 10 }
                score -= abs(s.index - c.index)
                cands.append((score, si, ci))
            }
        }
        // Stable order for equal scores, so the same windows get the same records on every pass.
        cands.sort { ($0.score, -$0.si, -$0.ci) > ($1.score, -$1.si, -$1.ci) }
        var usedS = Set<Int>(), usedC = Set<Int>()
        var out: [(si: Int, ci: Int)] = []
        for c in cands where !usedS.contains(c.si) && !usedC.contains(c.ci) {
            usedS.insert(c.si); usedC.insert(c.ci)
            out.append((c.si, c.ci))
        }
        return out
    }
}
