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
    /// Nothing could be read at all although windows exist: the screen is locked or apps are still waking.
    var blind: Bool { moved + alreadyInPlace + failed == 0 && (!waiting.isEmpty || unreachable > 0) }
    var summary: String {
        var s = "moved \(moved), in place \(alreadyInPlace), failed \(failed)"
        if !waiting.isEmpty { s += ", \(waiting.count) on other Spaces (placed when you switch there)" }
        if !launched.isEmpty { s += ", launched \(launched.joined(separator: ","))" }
        if !missingApps.isEmpty { s += ", not running: \(missingApps.joined(separator: ","))" }
        return s
    }
    /// One-line version for the menu bar.
    var short: String {
        var parts = ["\(moved) moved", "\(alreadyInPlace) in place"]
        if failed > 0 { parts.append("\(failed) failed") }
        if !waiting.isEmpty { parts.append("\(waiting.count) waiting on other desktops") }
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
    static func apply(_ layout: Layout, config: Config, onlyBundle: String? = nil, onlyIndices: Set<Int>? = nil,
                      launchMissing: Bool = false, dryRun: Bool = false) -> RestoreResult {
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
        var apps = AX.apps(ignore: Set(config.ignoreBundleIDs), only: onlyBundle)
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

        let real = Dictionary(grouping: WindowList.real(), by: \.pid)
        let visibleSpaces = PrivateAPI.visibleSpaces
        for app in apps {
            guard let recs = saved[app.bundleID] else { continue }
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
