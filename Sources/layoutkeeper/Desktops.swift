import AppKit
import ApplicationServices

/// Desktops (Spaces) per monitor. When a monitor is unplugged macOS moves its desktops onto the remaining
/// display and, when it comes back, gives it one fresh empty desktop instead of returning them. There is no
/// API to move a Space to another display without disabling SIP, so the fix drives Mission Control through
/// Accessibility: drag each desktop back to its monitor, add missing desktops, remove the empty extras.
enum Desktops {
    /// User desktops per display key, in "Desktop N" order. Full-screen spaces are left out.
    static func current(keysByUUID: [String: String]? = nil) -> [String: [String]] {
        let keys = keysByUUID ?? Displays.keysByUUID()
        var out: [String: [String]] = [:]
        for (uuid, spaces) in PrivateAPI.managedSpaces() {
            guard let dk = keys[uuid] else { continue }
            out[dk, default: []] += spaces.filter(\.userDesktop).map(\.key)
        }
        return out
    }

    /// Keys of desktops that hold at least one normal window.
    static func occupied() -> Set<String> {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ids = list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        let spaceOf = PrivateAPI.spaces(for: ids)
        let used = Set(spaceOf.values)
        var out = Set<String>()
        for spaces in PrivateAPI.managedSpaces().values { for s in spaces where used.contains(s.id) { out.insert(s.key) } }
        return out
    }

    enum Step: Equatable, CustomStringConvertible {
        /// `before`: the desktop it should land in front of on the target display (nil = at the end).
        case move(String, from: String, to: String, before: String?)
        case remove(String, on: String)
        case add(on: String)

        var description: String {
            switch self {
            case .move(let k, let from, let to, _): return "move desktop \(k.prefix(8)) from \(from) to \(to)"
            case .remove(let k, let on): return "remove empty desktop \(k.prefix(8)) on \(on)"
            case .add(let on): return "add a desktop on \(on)"
            }
        }
    }

    /// What it takes to turn `current` into `saved`. Desktops go back to the display they were saved on, then
    /// empty desktops macOS invented are removed, then displays still short of desktops get new ones.
    /// A display always keeps at least one desktop, and desktops with windows are never removed.
    static func plan(saved: [String: [String]], current: [String: [String]], occupied: Set<String>) -> [Step] {
        var cur = current
        var steps: [Step] = []
        func location(_ k: String) -> String? { cur.first { $0.value.contains(k) }?.key }

        // Repeat: a desktop held back to keep its display non-empty can go once another one has arrived there.
        var progress = true
        while progress {
            progress = false
            for dk in saved.keys.sorted() where cur[dk] != nil {
                for k in saved[dk]! {
                    guard let from = location(k), from != dk, cur[from]!.count > 1 else { continue }
                    let later = saved[dk]!.drop { $0 != k }.dropFirst()
                    let before = later.first { cur[dk]!.contains($0) }
                    cur[from]!.removeAll { $0 == k }
                    cur[dk]!.insert(k, at: before.flatMap { cur[dk]!.firstIndex(of: $0) } ?? cur[dk]!.count)
                    steps.append(.move(k, from: from, to: dk, before: before))
                    progress = true
                }
            }
        }

        let known = Set(saved.values.joined())
        for dk in cur.keys.sorted() {
            guard let want = saved[dk]?.count else { continue }
            for k in cur[dk]! where cur[dk]!.count > max(want, 1) && !known.contains(k) && !occupied.contains(k) {
                cur[dk]!.removeAll { $0 == k }
                steps.append(.remove(k, on: dk))
            }
        }

        for dk in saved.keys.sorted() where cur[dk] != nil {
            let missing = saved[dk]!.count - cur[dk]!.count
            if missing > 0 { steps += Array(repeating: .add(on: dk), count: missing) }
        }
        return steps
    }

    struct Result {
        var done: [Step] = []
        var failed: [String] = []
        var summary: String {
            var parts: [String] = []
            let moved = done.filter { if case .move = $0 { return true }; return false }.count
            let added = done.filter { if case .add = $0 { return true }; return false }.count
            let removed = done.filter { if case .remove = $0 { return true }; return false }.count
            if moved > 0 { parts.append("\(moved) moved back") }
            if added > 0 { parts.append("\(added) added") }
            if removed > 0 { parts.append("\(removed) empty removed") }
            if !failed.isEmpty { parts.append("\(failed.count) failed") }
            return parts.isEmpty ? "nothing to do" : parts.joined(separator: " · ")
        }
    }

    /// Carry out `steps` in Mission Control. Blocks for a few seconds; safe to call off the main thread as long
    /// as `displays` and `keysByUUID` were read on the main thread.
    static func apply(_ steps: [Step], displays: [DisplayInfo], keysByUUID: [String: String]) -> Result {
        var r = Result()
        guard !steps.isEmpty else { return r }
        let mc = MissionControl(displays: displays, keysByUUID: keysByUUID)
        guard mc.open() else {
            r.failed.append("Mission Control did not open")
            usleep(800_000)
            if !mc.bars().isEmpty { mc.close() }   // it opened late: do not leave it in the user's face
            return r
        }
        defer { mc.close() }
        for step in steps {
            if let why = mc.perform(step) { r.failed.append("\(step): \(why)") } else { r.done.append(step) }
        }
        return r
    }
}

/// Drives the Mission Control UI that the Dock exposes to Accessibility: one "Spaces Bar" per display with a
/// button per desktop (in "Desktop N" order, supporting AXRemoveDesktop) and an "add desktop" button.
private struct MissionControl {
    let displays: [DisplayInfo]
    let keysByUUID: [String: String]

    struct Bar { let desktops: [AXUIElement]; let add: AXUIElement }

    private var dock: AXUIElement? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
            .map { AXUIElementCreateApplication($0.processIdentifier) }
    }

    func open() -> Bool {
        if !bars().isEmpty { return true }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            usleep(100_000)
            if !bars().isEmpty { usleep(700_000); return true }   // let the zoom animation finish
        }
        return false
    }

    func close() {
        let saved = CGEvent(source: nil)?.location
        for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap) }
        usleep(500_000)
        if let saved { CGWarpMouseCursorPosition(saved) }
    }

    /// Spaces bars keyed by the display they are drawn on.
    func bars() -> [String: Bar] {
        guard let dock else { return [:] }
        var out: [String: Bar] = [:]
        func children(_ el: AXUIElement) -> [AXUIElement] { AX.value(el, kAXChildrenAttribute as String) as? [AXUIElement] ?? [] }
        func role(_ el: AXUIElement) -> String { AX.string(el, kAXRoleAttribute as String) ?? "" }
        func visit(_ el: AXUIElement, depth: Int) {
            let kids = children(el)
            if role(el) == kAXGroupRole as String,
               let list = kids.first(where: { role($0) == kAXListRole as String }),
               let add = kids.first(where: { role($0) == kAXButtonRole as String }) {
                let buttons = children(list).filter { role($0) == kAXButtonRole as String }
                if let f = buttons.first.flatMap(AX.frame), let d = Displays.displayFor(f, in: displays) {
                    out[d.key] = Bar(desktops: buttons, add: add)
                }
                return
            }
            if depth < 6 { kids.forEach { visit($0, depth: depth + 1) } }
        }
        visit(dock, depth: 0)
        return out
    }

    /// Where a desktop is right now: display key and its index in that display's bar (full-screen spaces included,
    /// as the bar shows them too).
    func locate(_ key: String) -> (display: String, index: Int, active: Bool, others: [Int])? {
        for (uuid, spaces) in PrivateAPI.managedSpaces() {
            if let i = spaces.firstIndex(where: { $0.key == key }), let dk = keysByUUID[uuid] {
                return (dk, i, spaces[i].current, spaces.indices.filter { $0 != i && spaces[$0].userDesktop })
            }
        }
        return nil
    }

    /// Mission Control will not drag or remove the desktop a display is showing, so show another one first.
    /// Clicking a desktop leaves Mission Control; it is reopened afterwards.
    private func leave(_ key: String) -> Bool {
        guard let at = locate(key), at.active else { return true }
        guard let other = at.others.first, let button = bars()[at.display]?.desktops[safe: other] else { return false }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
        _ = waitUntil { locate(key)?.active == false }
        let gone = Date().addingTimeInterval(3)
        while Date() < gone, !bars().isEmpty { usleep(100_000) }
        usleep(300_000)
        return open()
    }

    /// nil when done, else why not.
    func perform(_ step: Desktops.Step) -> String? {
        switch step {
        case .add(let on):
            guard let bar = bars()[on] else { return "no desktop bar for that display (found \(bars().keys.sorted()))" }
            let before = Desktops.current(keysByUUID: keysByUUID)[on]?.count ?? 0
            AXUIElementPerformAction(bar.add, kAXPressAction as CFString)
            return waitUntil { (Desktops.current(keysByUUID: keysByUUID)[on]?.count ?? 0) > before } ? nil : "no new desktop appeared"
        case .remove(let key, _):
            guard leave(key) else { return "could not switch away from it" }
            guard let at = locate(key), let bar = bars()[at.display], at.index < bar.desktops.count else { return "desktop not found in Mission Control" }
            AXUIElementPerformAction(bar.desktops[at.index], "AXRemoveDesktop" as CFString)
            return waitUntil { locate(key) == nil } ? nil : "desktop is still there"
        case .move(let key, _, let to, let before):
            guard let at = locate(key) else { return "desktop no longer exists" }
            if at.display == to { return nil }
            guard leave(key) else { return "could not switch away from it (it is the only desktop there)" }
            // The bars only show desktop thumbnails (and accept drags) while the pointer is at the top of a display.
            expand(at.display)
            guard let src = bars()[at.display]?.desktops[safe: at.index].flatMap(AX.frame),
                  let dstFrame = dropFrame(on: to, before: before) else { return "desktop not found in Mission Control (bars \(bars().keys.sorted()), index \(at.index))" }
            let start = center(src)
            mouse(.mouseMoved, start); usleep(100_000)
            mouse(.leftMouseDown, start); usleep(250_000)
            var target = dropPoint(dstFrame, before: before != nil)
            drag(from: start, to: target)
            usleep(450_000)
            if let expanded = dropFrame(on: to, before: before) {
                let refined = dropPoint(expanded, before: before != nil)
                drag(from: target, to: refined, steps: 8)
                target = refined
            }
            usleep(300_000)
            mouse(.leftMouseUp, target)
            return waitUntil { locate(key)?.display == to } ? nil : "drag from \(Int(start.x)),\(Int(start.y)) to \(Int(target.x)),\(Int(target.y)) did not move it"
        }
    }

    /// Point at the top edge of a display so Mission Control expands its Spaces bars, and wait until it has.
    private func expand(_ displayKey: String) {
        guard let d = displays.first(where: { $0.key == displayKey }) else { return }
        let p = CGPoint(x: d.frame.x + d.frame.w / 2, y: d.frame.y + 1)
        mouse(.mouseMoved, p); usleep(150_000)
        mouse(.mouseMoved, CGPoint(x: p.x + 2, y: p.y))
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            usleep(100_000)
            if let f = bars()[displayKey]?.desktops.first.flatMap(AX.frame), f.height > 40 { usleep(350_000); return }
        }
    }

    /// Frame of the desktop to drop next to: `before`, else the last one on the display.
    private func dropFrame(on display: String, before: String?) -> CGRect? {
        guard let bar = bars()[display] else { return nil }
        if let before, let at = locate(before), at.display == display, let f = bar.desktops[safe: at.index].flatMap(AX.frame) { return f }
        return bar.desktops.last.flatMap(AX.frame)
    }

    /// Left part of the thumbnail inserts in front of it; past its right edge appends.
    private func dropPoint(_ f: CGRect, before: Bool) -> CGPoint {
        CGPoint(x: before ? f.minX + f.width * 0.2 : f.maxX + f.width * 0.6, y: f.midY)
    }

    private func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

    private func mouse(_ type: CGEventType, _ p: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func drag(from a: CGPoint, to b: CGPoint, steps: Int = 30) {
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            usleep(15_000)
        }
    }

    private func waitUntil(_ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline { if cond() { usleep(250_000); return true }; usleep(100_000) }
        return false
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
