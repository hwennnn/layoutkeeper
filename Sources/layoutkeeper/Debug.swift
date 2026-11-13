import AppKit
import ApplicationServices

/// Diagnostics used by `layoutkeeper probe` / `inventory`. Runs inside whichever process is trusted.
enum Debug {
    static func probe(only: String?) -> String {

        // Debug: can we reach windows on other Spaces through remote tokens?
        var lines: [String] = ["active space \(PrivateAPI.activeSpace)"]
        let t0 = Date()
        for ra in NSWorkspace.shared.runningApplications where ra.activationPolicy == .regular {
            if let only = only, ra.bundleIdentifier != only { continue }
            let pid = ra.processIdentifier
            if only != nil {
                let appEl = AXUIElementCreateApplication(pid)
                var v: CFTypeRef?
                let roleErr = AXUIElementCopyAttributeValue(appEl, kAXRoleAttribute as CFString, &v)
                let setErr = AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                let setErr2 = AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                var names: CFArray?
                let namesErr = AXUIElementCopyAttributeNames(appEl, &names)
                lines.append("  app element: role err=\(roleErr.rawValue) value=\(v.map { "\($0)" } ?? "nil"); set manual=\(setErr.rawValue) enhanced=\(setErr2.rawValue); names err=\(namesErr.rawValue) \((names as? [String] ?? []).prefix(12))")
                lines.append("  pid=\(pid) exe=\(ra.executableURL?.path ?? "?") hidden=\(ra.isHidden) policy=\(ra.activationPolicy.rawValue)")
            }
            let listed = Set(AX.windows(of: AXUIElementCreateApplication(pid), pid: pid).map(\.windowID))
            let all = Set(WindowList.real().filter { $0.pid == pid }.map(\.id))
            let hidden = all.subtracting(listed)
            let ta = Date()
            let els = PrivateAPI.hiddenWindowElements(pid: pid, wanted: hidden)
            lines.append("\(ra.localizedName ?? "?"): listed \(listed.count), hidden \(hidden.count), reached \(els.count) in \(Int(Date().timeIntervalSince(ta) * 1000))ms")
            for (wid, el) in els {
                let space = PrivateAPI.spaces(for: [wid])[wid] ?? 0
                lines.append("    wid=\(wid) desktop=\(PrivateAPI.desktopNumber(of: space).map(String.init) ?? "-") frame=\(AX.frame(el).map { Rect($0).short } ?? "nil") sub=\(AX.string(el, kAXSubroleAttribute as String) ?? "") '\((AX.string(el, kAXTitleAttribute as String) ?? "").prefix(30))'")
            }
        }
        lines.append("total \(Int(Date().timeIntervalSince(t0) * 1000))ms")
        return lines.joined(separator: "\n")
    }

    static func inventory() -> String {

        var lines: [String] = []
        for ra in NSWorkspace.shared.runningApplications where ra.activationPolicy == .regular {
            let el = AXUIElementCreateApplication(ra.processIdentifier)
            AXUIElementSetMessagingTimeout(el, 1.5)
            var raw: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &raw)
            let n = (raw as? [AnyObject])?.count ?? -1
            let cg = WindowList.counts()[ra.bundleIdentifier ?? ""] ?? 0
            var detail: [String] = []
            for w in AX.windows(of: el, pid: ra.processIdentifier) {
                detail.append("    \(Rect(w.frame).short) min=\(w.minimized) fs=\(w.fullscreen) '\(w.title.prefix(40))'")
            }
            lines.append("\(ra.localizedName ?? "?") [\(ra.bundleIdentifier ?? "?")] ax=\(err.rawValue == 0 ? "\(n)" : "err\(err.rawValue)") cg=\(cg) usable=\(detail.count)")
            lines += detail
        }
        return lines.joined(separator: "\n")
    }
}
