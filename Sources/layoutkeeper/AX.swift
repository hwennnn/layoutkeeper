import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ out: UnsafeMutablePointer<CGWindowID>) -> AXError

struct AXWindow {
    let element: AXUIElement
    let pid: pid_t
    let windowID: CGWindowID
    let title: String
    let frame: CGRect
    let minimized: Bool
    let fullscreen: Bool
    let index: Int
    /// Space (desktop) id the window lives on, 0 if unknown.
    var space: UInt64 = 0
    /// True when the window was reached through a remote token because it is on another Space.
    var onOtherSpace = false
}

struct AXApp {
    let app: NSRunningApplication
    let element: AXUIElement
    var windows: [AXWindow]
    /// False when the app did not answer in time (busy or hung); its windows are unknown, not absent.
    var answered = true
    var bundleID: String { app.bundleIdentifier ?? "pid.\(app.processIdentifier)" }
    var name: String { app.localizedName ?? bundleID }
}

enum AX {
    static func trusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func value(_ el: AXUIElement, _ attr: String) -> AnyObject? {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, attr as CFString, &v)
        return err == .success ? v : nil
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? { value(el, attr) as? String }
    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? { value(el, attr) as? Bool }

    private static func axValue(_ el: AXUIElement, _ attr: String) -> AXValue? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(v, to: AXValue.self)
    }

    static func point(_ el: AXUIElement, _ attr: String) -> CGPoint? {
        guard let v = axValue(el, attr) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v, .cgPoint, &p) ? p : nil
    }

    static func size(_ el: AXUIElement, _ attr: String) -> CGSize? {
        guard let v = axValue(el, attr) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v, .cgSize, &s) ? s : nil
    }

    @discardableResult
    static func setPoint(_ el: AXUIElement, _ attr: String, _ p: CGPoint) -> Bool {
        var p = p
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(el, attr as CFString, v) == .success
    }

    @discardableResult
    static func setSize(_ el: AXUIElement, _ attr: String, _ s: CGSize) -> Bool {
        var s = s
        guard let v = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(el, attr as CFString, v) == .success
    }

    @discardableResult
    static func setBool(_ el: AXUIElement, _ attr: String, _ b: Bool) -> Bool {
        AXUIElementSetAttributeValue(el, attr as CFString, (b ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef) == .success
    }

    static func windowID(_ el: AXUIElement) -> CGWindowID {
        var id: CGWindowID = 0
        _ = _AXUIElementGetWindow(el, &id)
        return id
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = point(el, kAXPositionAttribute as String), let s = size(el, kAXSizeAttribute as String) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// Apps that did not answer, and when. They are left alone for a while so one hung app cannot stall every pass.
    private static var unresponsive: [pid_t: Date] = [:]
    private static var unresponsiveLogged: [pid_t: Date] = [:]
    private static var timeoutSet = false

    /// Regular (dock-visible) apps and their standard windows.
    /// - retryAfter: how long an app that did not answer is left alone (shorter during a restore).
    static func apps(ignore: Set<String>, only: String? = nil, retryAfter: TimeInterval = 20) -> [AXApp] {
        if !timeoutSet {
            // Applies to every element, including the ones made from remote tokens (default is 6 seconds per call).
            AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.5)
            timeoutSet = true
        }
        var out: [AXApp] = []
        for ra in NSWorkspace.shared.runningApplications {
            guard ra.activationPolicy == .regular, !ra.isTerminated else { continue }
            let bid = ra.bundleIdentifier ?? "pid.\(ra.processIdentifier)"
            if ignore.contains(bid) { continue }
            if let only, only != bid { continue }
            let el = AXUIElementCreateApplication(ra.processIdentifier)
            AXUIElementSetMessagingTimeout(el, 1.5)
            if let t = unresponsive[ra.processIdentifier], Date().timeIntervalSince(t) < retryAfter {
                out.append(AXApp(app: ra, element: el, windows: [], answered: false))
                continue
            }
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role) == .cannotComplete {
                // Busy apps do this all day; one line an hour per app is enough.
                if Date().timeIntervalSince(unresponsiveLogged[ra.processIdentifier] ?? .distantPast) > 3600 {
                    unresponsiveLogged[ra.processIdentifier] = Date()
                    Log.info("\(ra.localizedName ?? bid) is busy and not answering; its windows are skipped until it does")
                }
                unresponsive[ra.processIdentifier] = Date()
                out.append(AXApp(app: ra, element: el, windows: [], answered: false))
                continue
            }
            unresponsive[ra.processIdentifier] = nil
            var wins = windows(of: el, pid: ra.processIdentifier)
            wins += hiddenWindows(pid: ra.processIdentifier, excluding: Set(wins.map(\.windowID)), startIndex: wins.count)
            let spaces = PrivateAPI.spaces(for: wins.map(\.windowID))
            for i in wins.indices { wins[i].space = spaces[wins[i].windowID] ?? 0 }
            out.append(AXApp(app: ra, element: el, windows: wins))
        }
        return out
    }

    private static var electronEnabled = Set<pid_t>()
    private static var refusedLogged = Set<pid_t>()
    /// Ask an Electron/Chromium app to build its accessibility tree. Both attributes are honoured by
    /// different Electron versions; the tree appears asynchronously so we wait briefly the first time.
    static func enableElectronAccessibility(_ appEl: AXUIElement, pid: pid_t) {
        let first = !electronEnabled.contains(pid)
        setBool(appEl, "AXManualAccessibility", true)
        setBool(appEl, "AXEnhancedUserInterface", true)
        if first { electronEnabled.insert(pid); usleep(600_000) }
    }

    /// Cache of remote-token elements per window id; they stay valid for the window's lifetime.
    private static var hiddenCache: [CGWindowID: (pid: pid_t, element: AXUIElement)] = [:]
    /// Windows the scan could not reach, and when; they are retried after a minute instead of on every poll.
    private static var unreachable: [CGWindowID: Date] = [:]

    /// Windows of `pid` that exist on other Spaces and are therefore missing from `kAXWindowsAttribute`.
    static func hiddenWindows(pid: pid_t, excluding listed: Set<CGWindowID>, startIndex: Int) -> [AXWindow] {
        // Only windows that live on a real desktop; utility overlays report no Space.
        let entries = WindowList.real().filter { $0.pid == pid && !listed.contains($0.id) }
        guard !entries.isEmpty else { return [] }
        let spaces = Dictionary(entries.map { ($0.id, $0.space) }, uniquingKeysWith: { a, _ in a })
        let wanted = Set(entries.map(\.id))

        var elements: [CGWindowID: AXUIElement] = [:]
        var missing = Set<CGWindowID>()
        for wid in wanted {
            if let c = hiddenCache[wid], c.pid == pid, string(c.element, kAXRoleAttribute as String) == (kAXWindowRole as String) {
                elements[wid] = c.element
            } else if unreachable[wid].map({ Date().timeIntervalSince($0) > 60 }) ?? true { missing.insert(wid) }
        }
        if !missing.isEmpty {
            let found = PrivateAPI.hiddenWindowElements(pid: pid, wanted: missing)
            for (wid, el) in found {
                elements[wid] = el
                hiddenCache[wid] = (pid, el)
                unreachable[wid] = nil
            }
            for wid in missing where found[wid] == nil { unreachable[wid] = Date() }
            if unreachable.count > 500 { unreachable = unreachable.filter { Date().timeIntervalSince($0.value) < 60 } }
        }
        var out: [AXWindow] = []
        for (wid, w) in elements.sorted(by: { $0.key < $1.key }) {
            let subrole = string(w, kAXSubroleAttribute as String) ?? ""
            if !subrole.isEmpty && subrole != (kAXStandardWindowSubrole as String) { continue }
            guard let f = frame(w) else { continue }
            out.append(AXWindow(element: w, pid: pid, windowID: wid,
                                title: string(w, kAXTitleAttribute as String) ?? "",
                                frame: f,
                                minimized: bool(w, kAXMinimizedAttribute as String) ?? false,
                                fullscreen: bool(w, "AXFullScreen") ?? false,
                                index: startIndex + out.count, space: spaces[wid] ?? 0, onOtherSpace: true))
        }
        return out
    }

    static func windows(of appEl: AXUIElement, pid: pid_t) -> [AXWindow] {
        var rawRef: CFTypeRef?
        var err = AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &rawRef)
        if err == .apiDisabled {
            // Electron/Chromium apps keep their accessibility tree off until a client asks for it.
            enableElectronAccessibility(appEl, pid: pid)
            err = AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &rawRef)
        }
        if err == .apiDisabled && !refusedLogged.contains(pid) {
            refusedLogged.insert(pid)
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
            Log.warn("\(name) refuses Accessibility clients (error -25211); its windows are skipped. Relaunching the app usually fixes this.")
        }
        guard err == .success, let raw = rawRef, CFGetTypeID(raw) == CFArrayGetTypeID() else { return [] }
        let cfArr = unsafeBitCast(raw, to: CFArray.self)
        var arr: [AXUIElement] = []
        for i in 0..<CFArrayGetCount(cfArr) {
            guard let ptr = CFArrayGetValueAtIndex(cfArr, i) else { continue }
            let obj = Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue()
            if CFGetTypeID(obj) == AXUIElementGetTypeID() { arr.append(unsafeBitCast(obj, to: AXUIElement.self)) }
        }
        var out: [AXWindow] = []
        for w in arr {
            guard string(w, kAXRoleAttribute as String) == (kAXWindowRole as String) else { continue }
            let subrole = string(w, kAXSubroleAttribute as String) ?? ""
            if !subrole.isEmpty && subrole != (kAXStandardWindowSubrole as String) { continue }
            guard let f = frame(w) else { continue }
            out.append(AXWindow(element: w,
                                pid: pid,
                                windowID: windowID(w),
                                title: string(w, kAXTitleAttribute as String) ?? "",
                                frame: f,
                                minimized: bool(w, kAXMinimizedAttribute as String) ?? false,
                                fullscreen: bool(w, "AXFullScreen") ?? false,
                                index: out.count))
        }
        return out
    }

    /// Move+resize with the position/size/position dance most apps need. Returns the frame actually achieved.
    @discardableResult
    static func setFrame(_ el: AXUIElement, _ f: CGRect) -> CGRect? {
        setPoint(el, kAXPositionAttribute as String, f.origin)
        setSize(el, kAXSizeAttribute as String, f.size)
        setPoint(el, kAXPositionAttribute as String, f.origin)
        var got = frame(el)
        if let g = got, !approx(g, f) {
            // Second attempt: size first, then position (helps apps that clamp to the current display).
            setSize(el, kAXSizeAttribute as String, f.size)
            setPoint(el, kAXPositionAttribute as String, f.origin)
            setSize(el, kAXSizeAttribute as String, f.size)
            got = frame(el)
        }
        return got
    }

    static func approx(_ a: CGRect, _ b: CGRect, tol: CGFloat = 2) -> Bool {
        abs(a.origin.x - b.origin.x) <= tol && abs(a.origin.y - b.origin.y) <= tol &&
        abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }
}
