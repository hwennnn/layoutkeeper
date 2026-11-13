import AppKit
import Foundation

let agentLabel = Version.agentLabel
let args = Array(CommandLine.arguments.dropFirst())
func flag(_ n: String) -> Bool { args.contains(n) }
func opt(_ n: String) -> String? {
    guard let i = args.firstIndex(of: n), i + 1 < args.count else { return nil }
    return args[i + 1]
}
Log.verbose = flag("-v") || flag("--verbose")
let config = Store.config()
let usage = """
layoutkeeper — remember and restore window layouts per monitor set

  save                    Pin the current window layout for the current monitor set (onboarding).
  restore [--auto|--pinned] [--launch] [--dry-run]
                          Put windows back the way they were last left (--pinned: the pinned snapshot).
  desktops [--dry-run]    Put desktops (Spaces) back on the monitor they were saved on.
  watch                   Run the daemon (installed as a LaunchAgent by scripts/install.sh).
  open [desktop]          Open the Layouts window (visual map of every saved layout).
  list                    Show known monitor sets and what is saved for them.
  show [--auto|--pinned]  Print the saved layout for the current monitor set.
  capture                 Print the live layout as JSON.
  render [--grid] [--desktop N] [--dark] [--demo] [--out file.png]
                          Draw the saved layout (or a made-up demo one) to a PNG.
  displays                Print connected displays.
  forget [--auto|--pinned|--all]
                          Delete saved layouts for the current monitor set.
  status                  Permission, daemon, and layout status.
  reload                  Ask the running daemon to restore now (same as a monitor change).
  ping                    Check the daemon answers and whether it has Accessibility.
  config [get|set|edit|reset|path]
                          Show or change settings (run `layoutkeeper config` for the key list).
  version
  Options: -v verbose.
"""

/// Commands that touch windows run locally when this process is trusted, otherwise through the daemon.
func runAXCommand(_ name: String, local: () -> Void) {
    if !flag("--via-daemon") && AX.trusted(prompt: flag("--prompt")) { local(); return }
    if let pid = daemonPID(), pid > 0 {
        guard let out = Commands.send(name, Array(args.dropFirst()), to: pid) else {
            Log.error("Daemon (pid \(pid)) did not answer. Check ~/Library/Logs/LayoutKeeper.log — most likely it is waiting for the Accessibility permission.")
            exit(2)
        }
        print(out)
        exit(out.hasPrefix("ERROR") ? 1 : 0)
    }
    Log.error("Accessibility permission missing for this process and the daemon is not running. Run scripts/install.sh, then enable LayoutKeeper in System Settings > Privacy & Security > Accessibility.")
    exit(2)
}

func fmtDate(_ d: Date) -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f.string(from: d)
}

func daemonPID() -> pid_t? {
    // The daemon writes its own pid (it runs as a child of the LayoutKeeper.app launcher).
    if let s = try? String(contentsOf: Store.dir.appendingPathComponent("daemon.pid"), encoding: .utf8),
       let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)), kill(pid, 0) == 0 {
        return pid
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["print", "gui/\(getuid())/\(agentLabel)"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    try? p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0, let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return nil }
    for line in out.split(separator: "\n") where line.contains("pid = ") {
        if let v = line.split(separator: "=").last.flatMap({ pid_t($0.trimmingCharacters(in: .whitespaces)) }) { return v }
    }
    return 0  // loaded but not running
}

func printLayout(_ l: Layout) {
    print("\(l.label) [\(l.fingerprint)] saved \(fmtDate(l.savedAt)) — \(l.windows.count) windows")
    for d in l.displays { print("  display \(d.name)\(d.isMain ? " (main)" : ""): \(d.frame.short)  key=\(d.key)") }
    for w in l.windows {
        let flags = [w.desktop.map { "desktop \($0)" }, w.minimized ? "min" : nil, w.stale == true ? "remembered" : nil].compactMap { $0 }.joined(separator: ", ")
        print("  \(w.appName.padding(toLength: 18, withPad: " ", startingAt: 0)) \(w.abs.short.padding(toLength: 22, withPad: " ", startingAt: 0)) \(w.title.prefix(60))\(flags.isEmpty ? "" : "  [\(flags)]")")
    }
}

let cmd = args.first ?? "help"
switch cmd {
case "displays":
    let d = Displays.current()
    print("\(Displays.label(d)) [\(Displays.fingerprint(d))]")
    for x in d { print("  \(x.name)\(x.isMain ? " (main)" : ""): \(x.frame.short)  key=\(x.key)") }

case "capture":
    runAXCommand("capture") { print(Store.encodeJSON(Capture.layout(config: config))) }

case "save":
    runAXCommand("save") {
        let snap = Capture.snapshot(config: config)
        let l = snap.merged
        do {
            try Store.put(l, pinned: true)
            try Store.put(l, pinned: false)
            print("Pinned \(l.windows.count) windows for \(l.label) [\(l.fingerprint)]")
            printLayout(l)
        } catch { Log.error("save failed: \(error)"); exit(1) }
    }

case "restore":
  runAXCommand("restore") {
    let fp = Displays.fingerprint(Displays.current())
    guard let file = Store.load(fp) else { Log.error("No saved layout for this monitor set [\(fp)]. Run `layoutkeeper save` first."); exit(1) }
    let chosen = flag("--auto") ? file.auto.map { ($0, false) } : (flag("--pinned") ? file.pinned.map { ($0, true) } : file.preferred(pinnedFirst: config.preferPinned))
    guard let (layout, isPinned) = chosen else { Log.error("No matching layout saved for [\(fp)]."); exit(1) }
    let r = Restore.apply(layout, config: config, onlyBundle: opt("--app"),
                          launchMissing: flag("--launch") || config.launchMissingApps, dryRun: flag("--dry-run"))
    print("\(flag("--dry-run") ? "Would restore" : "Restored") \(layout.label) (\(isPinned ? "pinned" : "auto"), saved \(fmtDate(layout.savedAt))): \(r.summary)")
    exit(r.failed > 0 ? 3 : 0)
  }

case "list":
    let cur = Displays.fingerprint(Displays.current())
    let files = Store.list()
    if files.isEmpty { print("No layouts saved yet. Run `layoutkeeper save` or start the watcher.") }
    for f in files {
        let mark = f.fingerprint == cur ? "*" : " "
        let p = f.pinned.map { "pinned \($0.windows.count)w @ \(fmtDate($0.savedAt))" } ?? "no pinned"
        let a = f.auto.map { "auto \($0.windows.count)w @ \(fmtDate($0.savedAt))" } ?? "no auto"
        print("\(mark) \(f.label) [\(f.fingerprint)]  \(p); \(a)")
    }
    print("(* = connected now)")

case "show":
    let fp = Displays.fingerprint(Displays.current())
    guard let file = Store.load(fp) else { print("Nothing saved for this monitor set [\(fp)]."); exit(1) }
    let shown = flag("--auto") ? file.auto.map { ($0, false) } : (flag("--pinned") ? file.pinned.map { ($0, true) } : file.preferred(pinnedFirst: config.preferPinned))
    if let (l, isPinned) = shown {
        print(isPinned ? "PINNED layout" : "AUTO layout")
        printLayout(l)
    } else { print("Nothing saved."); exit(1) }

case "forget":
    let fp = Displays.fingerprint(Displays.current())
    guard var file = Store.load(fp) else { print("Nothing saved for [\(fp)]."); exit(0) }
    if flag("--all") || (!flag("--auto") && !flag("--pinned")) { Store.delete(fp); print("Deleted all layouts for \(file.label)."); exit(0) }
    if flag("--auto") { file.auto = nil }
    if flag("--pinned") { file.pinned = nil }
    try? Store.save(file)
    print("Updated \(file.label).")

case "config":
    let sub = args.dropFirst().first ?? "show"
    switch sub {
    case "show":
        let dict = (try? JSONSerialization.jsonObject(with: Data(contentsOf: Store.configURL))) as? [String: Any] ?? [:]
        print("Config file: \(Store.configURL.path)\n")
        func fmt(_ v: Any?) -> String {
            guard let v else { return "(default)" }
            if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            if let a = v as? [Any] { return a.map { "\($0)" }.joined(separator: ",") }
            return "\(v)"
        }
        for e in ConfigDocs.entries {
            let v = fmt(dict[e.key])
            print("  \(e.key.padding(toLength: 24, withPad: " ", startingAt: 0)) = \(v.padding(toLength: 22, withPad: " ", startingAt: 0)) \(e.help)")
        }
        print("\nChange with: layoutkeeper config set <key> <value>   (or: config edit)")
    case "get":
        guard let key = opt("get") else { print("usage: config get <key>"); exit(1) }
        let dict = (try? JSONSerialization.jsonObject(with: Data(contentsOf: Store.configURL))) as? [String: Any] ?? [:]
        if let n = dict[key] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { print(n.boolValue) }
        else if let a = dict[key] as? [Any] { print(a.map { "\($0)" }.joined(separator: ",")) }
        else { print(dict[key].map { "\($0)" } ?? "(default)") }
    case "set":
        guard args.count >= 4 else { print("usage: config set <key> <value>"); exit(1) }
        do { _ = try Store.setConfig(key: args[2], value: args[3]); print("\(args[2]) = \(args[3]) (daemon reloads within \(Int(config.pollSeconds))s)") }
        catch { Log.error(error.localizedDescription); exit(1) }
    case "edit":
        let editor = ProcessInfo.processInfo.environment["VISUAL"] ?? ProcessInfo.processInfo.environment["EDITOR"]
        let p = Process()
        if let editor, isatty(STDIN_FILENO) != 0 {
            p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", "\(editor) \"\(Store.configURL.path)\""]
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = ["-t", Store.configURL.path]
        }
        try? p.run(); p.waitUntilExit()
    case "reset":
        try? Store.writeConfig(Config()); print("Config reset to defaults.")
    case "path":
        print(Store.configURL.path)
    case "help", "--help", "-h":
        print(ConfigDocs.help())
    default:
        print(ConfigDocs.help()); exit(1)
    }

case "version":
    print("layoutkeeper \(Version.string)")

case "watch":
    Watcher.shared.run()

case "reload":
    if let pid = daemonPID(), pid > 0, let out = Commands.send("reload", [], to: pid, timeout: 10) { print(out) }
    else { print("Daemon not running or not answering."); exit(1) }

case "simulate":
    if let pid = daemonPID(), pid > 0, let out = Commands.send("simulate", Array(args.dropFirst()), to: pid, timeout: 10) {
        print(out); exit(out.hasPrefix("ERROR") ? 1 : 0)
    } else { print("Daemon not running or not answering."); exit(1) }

case "status":
    let d = Displays.current(); let fp = Displays.fingerprint(d)
    switch daemonPID() {
    case .some(let pid) where pid > 0:
        let pong = Commands.send("ping", [], to: pid, timeout: 5) ?? ""
        let trusted = pong.contains("trusted=true")
        print("Daemon: running (pid \(pid)), Accessibility \(trusted ? "granted" : "NOT granted — enable LayoutKeeper in System Settings > Privacy & Security > Accessibility")")
    case .some: print("Daemon: loaded but not running")
    case .none: print("Daemon: not installed (run scripts/install.sh)")
    }
    print("Monitor set: \(Displays.label(d)) [\(fp)]")
    if let f = Store.load(fp) {
        print("  pinned: \(f.pinned.map { "\($0.windows.count) windows @ \(fmtDate($0.savedAt))" } ?? "none")")
        print("  auto:   \(f.auto.map { "\($0.windows.count) windows @ \(fmtDate($0.savedAt))" } ?? "none")")
    } else { print("  no layout saved yet") }
    print("Log: ~/Library/Logs/LayoutKeeper.log")

case "nudge":
    // Test helper: shift every window of an app by dx,dy. `layoutkeeper nudge com.tinyspeck.slackmacgap 120 80`
    runAXCommand("nudge") {
        guard args.count >= 4, let dx = Double(args[2]), let dy = Double(args[3]) else { print("usage: nudge <bundleID> <dx> <dy>"); exit(1) }
        for app in AX.apps(ignore: [], only: args[1]) {
            for w in app.windows where !w.fullscreen && !w.minimized {
                let got = AX.setFrame(w.element, w.frame.offsetBy(dx: dx, dy: dy))
                print("\(app.name) '\(w.title.prefix(40))' \(Rect(w.frame).short) -> \(got.map { Rect($0).short } ?? "?")")
            }
        }
    }

case "probe":
    // Debug: per-app window reachability, including windows on other Spaces.
    runAXCommand("probe") { print(Debug.probe(only: args.dropFirst().first { !$0.hasPrefix("-") })) }

case "inventory":
    // Debug: raw Accessibility view of every app.
    runAXCommand("inventory") { print(Debug.inventory()) }

case "open":
    if let pid = daemonPID(), pid > 0, let out = Commands.send("open", Array(args.dropFirst()), to: pid, timeout: 10) { print(out) }
    else { print("Daemon not running or not answering."); exit(1) }

case "desktops":
    if let pid = daemonPID(), pid > 0, let out = Commands.send("desktops", Array(args.dropFirst()), to: pid, timeout: 60) {
        print(out); exit(out.hasPrefix("ERROR") ? 1 : 0)
    } else { print("Daemon not running or not answering."); exit(1) }

case "ping":
    if let pid = daemonPID(), pid > 0, let out = Commands.send("ping", [], to: pid, timeout: 10) { print(out) }
    else { print("Daemon not running or not answering."); exit(1) }

case "render":
    // Render the saved layout of the current monitor set to a PNG (the same drawing the menu and Layouts window use).
    let fp = Displays.fingerprint(Displays.current())
    let l: Layout
    if flag("--demo") { l = SelfTest.demoLayout() }
    else if let saved = Store.load(fp)?.preferred(pinnedFirst: config.preferPinned)?.layout { l = saved }
    else { print("Nothing saved for [\(fp)]."); exit(1) }
    let out = opt("--out") ?? "layoutkeeper-preview.png"
    let size = NSSize(width: Double(opt("--width") ?? "") ?? 1200, height: Double(opt("--height") ?? "") ?? 560)
    NSApplication.shared.appearance = NSAppearance(named: flag("--dark") ? .darkAqua : .aqua)
    let view: NSView
    if flag("--grid") {
        view = DesktopGridView(layout: l) { _ in }
    } else {
        let m = LayoutMapView(frame: NSRect(origin: .zero, size: size))
        m.layout = l
        if let d = opt("--desktop") { m.filter = d == "none" ? .unknown : (Int(d).map { .desktop($0) } ?? .all) }
        view = m
    }
    let bg = NSView(frame: view.bounds)
    bg.wantsLayer = true
    bg.layer?.backgroundColor = (flag("--dark") ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.97, alpha: 1)).cgColor
    bg.addSubview(view)
    bg.appearance = NSApplication.shared.appearance
    guard let rep = bg.bitmapImageRepForCachingDisplay(in: bg.bounds) else { exit(1) }
    bg.cacheDisplay(in: bg.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
    print("wrote \(out)")

case "selftest":
    exit(SelfTest.run() ? 0 : 1)

default:
    print(usage)
    exit(cmd == "help" || cmd == "--help" ? 0 : 1)
}
