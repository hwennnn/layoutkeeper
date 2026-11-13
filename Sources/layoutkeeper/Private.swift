import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Private-but-long-stable SkyLight / HIServices entry points (same ones yabai, Hammerspoon and
// Amethyst rely on). Everything here is optional: callers fall back to public APIs when a call fails.

@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSGetActiveSpace") private func CGSGetActiveSpace(_ cid: Int32) -> UInt64
@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ windowIDs: CFArray) -> Unmanaged<CFArray>?
@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>?

enum PrivateAPI {
    /// Accessibility elements for windows that `kAXWindowsAttribute` does not list (they are on another Space).
    /// The remote token addresses an app's AX element by a small integer id, so we scan ids until every
    /// wanted window id is found or the budget runs out (same technique as yabai).
    static func hiddenWindowElements(pid: pid_t, wanted: Set<CGWindowID>, maxIDs: Int = 4000,
                                     budget: TimeInterval = 2.0) -> [CGWindowID: AXUIElement] {
        var found: [CGWindowID: AXUIElement] = [:]
        guard !wanted.isEmpty, let data = CFDataCreateMutable(nil, 0x14) else { return found }
        CFDataIncreaseLength(data, 0x14)
        guard let bytes = CFDataGetMutableBytePtr(data) else { return found }
        let raw = UnsafeMutableRawPointer(bytes)
        raw.storeBytes(of: UInt32(pid), toByteOffset: 0x0, as: UInt32.self)
        raw.storeBytes(of: UInt32(0x636f_636f), toByteOffset: 0x8, as: UInt32.self)
        let deadline = Date().addingTimeInterval(budget)
        var remaining = wanted
        for elementID in 0..<UInt64(maxIDs) {
            if remaining.isEmpty || Date() > deadline { break }
            raw.storeBytes(of: elementID, toByteOffset: 0xc, as: UInt64.self)
            guard let el = _AXUIElementCreateWithRemoteToken(data)?.takeRetainedValue() else { continue }
            guard AX.string(el, kAXRoleAttribute as String) == (kAXWindowRole as String) else { continue }
            let wid = AX.windowID(el)
            if remaining.remove(wid) != nil { found[wid] = el }
        }
        return found
    }

    /// Space id -> (UUID key, display UUID, is a user desktop) for every Space that exists now.
    static func spaceIndex() -> [UInt64: (key: String, display: String, userDesktop: Bool)] {
        var out: [UInt64: (key: String, display: String, userDesktop: Bool)] = [:]
        for (uuid, spaces) in managedSpaces() { for s in spaces { out[s.id] = (s.key, uuid, s.userDesktop) } }
        return out
    }

    private typealias AssignFn = @convention(c) (Int32, pid_t, UInt64) -> Int32
    /// Looked up at run time, so a macOS release without it only loses this feature.
    private static let assign: AssignFn? = {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let sym = dlsym(lib, "SLSProcessAssignToSpace") else { return nil }
        return unsafeBitCast(sym, to: AssignFn.self)
    }()

    /// Move every window of an app to one desktop, without switching the desktop on screen. The assignment
    /// is cleared again right away, so windows the app opens later appear wherever the user is.
    @discardableResult
    static func moveApp(pid: pid_t, toSpace sid: UInt64) -> Bool {
        guard let assign, sid != 0 else { return false }
        let ok = assign(CGSMainConnectionID(), pid, sid) == 0
        usleep(150_000)
        _ = assign(CGSMainConnectionID(), pid, 0)
        return ok
    }

    static var activeSpace: UInt64 { CGSGetActiveSpace(CGSMainConnectionID()) }

    /// The Space each display is showing right now.
    static var visibleSpaces: Set<UInt64> {
        Set(managedSpaces().values.flatMap { $0.filter(\.current).map(\.id) })
    }

    /// Space ids for the given windows (first space per window; 0 if unknown).
    static func spaces(for windowIDs: [CGWindowID]) -> [CGWindowID: UInt64] {
        guard !windowIDs.isEmpty else { return [:] }
        var out: [CGWindowID: UInt64] = [:]
        for wid in windowIDs {
            let arr = [NSNumber(value: wid)] as CFArray
            if let spaces = CGSCopySpacesForWindows(CGSMainConnectionID(), 0x7, arr)?.takeRetainedValue() as? [NSNumber],
               let first = spaces.first {
                out[wid] = first.uint64Value
            }
        }
        return out
    }

    /// Desktop ordering per display: [display uuid: [space id...]] (user-visible "Desktop N" order).
    static func spaceOrder() -> [String: [UInt64]] {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?.takeRetainedValue() as? [[String: Any]] else { return [:] }
        var out: [String: [UInt64]] = [:]
        for d in displays {
            let uuid = d["Display Identifier"] as? String ?? "?"
            let spaces = (d["Spaces"] as? [[String: Any]] ?? []).compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
            out[uuid] = spaces
        }
        return out
    }

    struct Space { let id: UInt64; let key: String; let userDesktop: Bool; var current = false }

    /// Spaces per display UUID in "Desktop N" order. `key` is the Space's UUID, which survives restarts
    /// (the very first desktop sometimes has none, then its id is used).
    static func managedSpaces() -> [String: [Space]] {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?.takeRetainedValue() as? [[String: Any]] else { return [:] }
        var out: [String: [Space]] = [:]
        for d in displays {
            let uuid = d["Display Identifier"] as? String ?? "?"
            let active = ((d["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value
            out[uuid] = (d["Spaces"] as? [[String: Any]] ?? []).compactMap { s in
                guard let id = (s["id64"] as? NSNumber)?.uint64Value else { return nil }
                let u = s["uuid"] as? String ?? ""
                return Space(id: id, key: u.isEmpty ? "id:\(id)" : u, userDesktop: (s["type"] as? NSNumber)?.intValue == 0, current: id == active)
            }
        }
        return out
    }

    /// Human label like "Desktop 3" for a space id, if it is a user desktop.
    static func desktopNumber(of space: UInt64) -> Int? {
        var n = 0
        for (_, spaces) in spaceOrder().sorted(by: { $0.key < $1.key }) {
            for s in spaces { n += 1; if s == space { return n } }
        }
        return nil
    }
}

/// Windows that really sit on a desktop. Every app also owns invisible helper windows (no Space, often
/// 500x500 or 64x64 at the screen edge) and hidden-on-close windows; counting those makes each app look
/// like it has a window on another Space.
enum WindowList {
    struct Entry { let id: CGWindowID; let pid: pid_t; let space: UInt64 }

    static func real() -> [Entry] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var cands: [(CGWindowID, pid_t)] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let wid = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat], (b["Height"] ?? 0) > 40 else { continue }
            cands.append((wid, pid))
        }
        let spaces = PrivateAPI.spaces(for: cands.map(\.0))
        return cands.compactMap { c in spaces[c.0].flatMap { $0 == 0 ? nil : Entry(id: c.0, pid: c.1, space: $0) } }
    }

    /// Number of real windows per bundle id of regular apps, across all Spaces.
    static func counts(_ entries: [Entry]? = nil) -> [String: Int] {
        var byPid: [pid_t: Int] = [:]
        for e in entries ?? real() { byPid[e.pid, default: 0] += 1 }
        var out: [String: Int] = [:]
        for ra in NSWorkspace.shared.runningApplications where ra.activationPolicy == .regular {
            if let bid = ra.bundleIdentifier { out[bid, default: 0] += byPid[ra.processIdentifier] ?? 0 }
        }
        return out
    }
}

enum Session {
    /// True while the screen is locked or another user has the console: windows cannot be read or moved then.
    /// Set by the `simulate lock` test command.
    static var pretendLocked = false

    static var locked: Bool {
        if pretendLocked { return true }
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if (d["CGSSessionScreenIsLocked"] as? Bool) == true { return true }
        return (d["kCGSSessionOnConsoleKey"] as? Bool) == false
    }
}
