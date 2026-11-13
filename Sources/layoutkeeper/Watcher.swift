import AppKit
import CoreGraphics

/// Long-running daemon: restores layouts when the monitor set changes, autosaves the current
/// layout while it is stable, and places freshly opened apps where they were last seen.
final class Watcher {
    static let shared = Watcher()

    private(set) var config = Store.config()
    private var configModified = Store.configModified()
    /// Pause everything (autosave, restores, placement) from the menu bar.
    var paused = false
    /// Last notable action, shown in the menu.
    struct Event { let title: String; let details: [String]; let at: Date }
    private(set) var lastEvent: Event?
    /// Whether the Accessibility permission has been granted (the menu shows a fix-it item until it is).
    private(set) var trusted = false
    var onChange: (() -> Void)?
    private var menuBar: MenuBar?
    private var currentFP = ""
    private var fpSince = Date.distantPast
    private var suspendUntil = Date.distantPast
    private var lastDigest = ""
    private var pendingDigest = ""
    private var tick = 0
    private var windowCounts: [String: Int] = [:]
    private var settleTimer: Timer?
    private var placementTimers: [String: [Timer]] = [:]
    /// Records still to be placed after a display change (their windows were on another Space at the time).
    private var pending: (layout: Layout, indices: Set<Int>, until: Date)?
    /// Mission Control is being driven to put desktops back; everything else waits.
    private var arrangingDesktops = false
    /// Restore passes are still running; the layout must not be autosaved until they are done.
    private var restoring = false
    private var restoreGen = 0
    /// The displays were off (asleep, lid closed); when they come back windows may have been shuffled.
    private var dark = false
    private var woke = false

    func run() {
        signal(SIGUSR1, SIG_IGN); signal(SIGUSR2, SIG_IGN)   // CLI may signal us before we are ready
        Store.ensureDirs()
        // Two daemons would fight over every window. Wait quietly until the other one is gone.
        let lock = open(Store.dir.appendingPathComponent("daemon.lock").path, O_CREAT | O_RDWR, 0o644)
        if lock >= 0, flock(lock, LOCK_EX | LOCK_NB) != 0 {
            Log.warn("another LayoutKeeper daemon is running; waiting for it to exit (pid \(getpid()))")
            flock(lock, LOCK_EX)
        }
        Log.trim(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LayoutKeeper.log"))
        Log.info("layoutkeeper watch starting (pid \(getpid()), v\(Version.string))")
        Commands.sweep()
        try? "\(getpid())".write(to: Store.dir.appendingPathComponent("daemon.pid"), atomically: true, encoding: .utf8)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if config.menuBarIcon { menuBar = MenuBar(watcher: self) }
        trusted = AX.trusted(prompt: true)   // prompt once so LayoutKeeper appears in the list, then poll silently
        onChange?()
        if trusted { start() } else {
            Log.warn("Accessibility permission not granted. Enable LayoutKeeper in System Settings > Privacy & Security > Accessibility (toggle it off and on if it already shows enabled). Waiting…")
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] t in
                guard let self, AX.trusted(prompt: false) else { return }
                t.invalidate()
                self.trusted = true
                Log.info("Accessibility permission granted")
                self.start()
                self.onChange?()
            }
        }
        app.run()
    }

    private func start() {
        let displays = Displays.current()
        currentFP = Displays.fingerprint(displays)
        Log.info("monitor set: \(Displays.label(displays)) [\(currentFP)]")
        windowCounts = WindowList.counts()
        Store.removeEmptySets()
        Store.tidyAll()

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.displayChanged(reason: "woke from sleep")
        }

        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            if flags.contains(.beginConfigurationFlag) { return }
            Watcher.shared.displayChanged(reason: "reconfiguration flags=\(flags.rawValue)")
        }, nil)

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular, let bid = app.bundleIdentifier else { return }
            self?.schedulePlacement(bid, reason: "launched")
        }

        // SIGUSR1: process CLI commands from the cmd/ directory (or restore if none). SIGUSR2: force an autosave.
        let s1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        s1.setEventHandler { Watcher.shared.handleCommands() }
        s1.resume()
        let s2 = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        s2.setEventHandler { Watcher.shared.autosave(force: true) }
        s2.resume()
        Self.signalSources = [s1, s2]

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.spaceChanged()
        }

        Timer.scheduledTimer(withTimeInterval: config.pollSeconds, repeats: true) { [weak self] _ in self?.poll() }
    }

    func note(_ s: String, details: [String] = []) {
        lastEvent = Event(title: s, details: details, at: Date())
        Log.info(details.isEmpty ? s : "\(s): \(details.joined(separator: "; "))")
        onChange?()
    }

    /// Change one config key (from the menu) and apply it immediately.
    func setConfig(_ key: String, _ value: String) {
        do { _ = try Store.setConfig(key: key, value: value) } catch { Log.error("config set \(key): \(error.localizedDescription)") }
        reloadConfigIfChanged()
    }

    /// Pin what is on screen now. It also becomes the remembered layout, so the next restore uses it either way.
    @discardableResult
    func pin() throws -> (fresh: Layout, merged: Layout) {
        let snap = Capture.snapshot(config: config)
        guard !snap.fresh.displays.isEmpty else { throw NSError(domain: "layoutkeeper", code: 2, userInfo: [NSLocalizedDescriptionKey: "no display is on"]) }
        try Store.put(snap.merged, pinned: true)
        try Store.put(snap.merged, pinned: false)
        lastDigest = ""
        return snap
    }

    func pinCurrent(reason: String) {
        do {
            let snap = try pin()
            note("Saved \(snap.merged.windows.count) windows as the pinned layout", details: ["Monitor set: \(snap.fresh.label)", "From: \(reason)"])
        } catch { Log.error("pin failed: \(error.localizedDescription)") }
    }

    func reloadConfigIfChanged() {
        let m = Store.configModified()
        guard m != configModified else { return }
        configModified = m
        config = Store.config()
        if config.menuBarIcon && menuBar == nil { menuBar = MenuBar(watcher: self) }
        if !config.menuBarIcon, let mb = menuBar { mb.remove(); menuBar = nil }
        Log.info("config reloaded")
        onChange?()
    }
    private static var signalSources: [DispatchSourceSignal] = []

    // MARK: display changes

    func displayChanged(reason: String) {
        Log.debug("display event: \(reason)")
        if reason.hasPrefix("woke") { woke = true }
        suspendUntil = Date().addingTimeInterval(90)
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: config.debounceSeconds, repeats: false) { [weak self] _ in self?.settle() }
    }

    private func settle() {
        if paused { return }
        let displays = Displays.current()
        if displays.isEmpty { goDark(); return }
        let fp = Displays.fingerprint(displays)
        if fp != currentFP {
            Log.info("monitor set changed: [\(currentFP)] -> \(Displays.label(displays)) [\(fp)]")
            currentFP = fp
        } else {
            Log.info("\(woke ? "woke up" : dark ? "displays back on" : "displays reconfigured"), monitor set unchanged (\(Displays.label(displays)))")
        }
        dark = false
        fpSince = Date()
        lastDigest = ""; pendingDigest = ""
        pending = nil   // it described the previous arrangement
        guard config.restoreOnDisplayChange else {
            suspendUntil = Date().addingTimeInterval(10)
            restoreDesktops(reason: "display change") {}
            return
        }
        restoreAll(reason: woke ? "wake from sleep" : "display change")
        woke = false
    }

    private func goDark() {
        if !dark { Log.info("displays are off; waiting for them to come back") }
        dark = true
        restoreGen += 1; restoring = false   // nothing to restore onto
    }

    /// Desktops first (windows travel with their desktop), then window frames, checked again until they stay put:
    /// macOS and some apps keep shuffling windows for a while after a hotplug or wake, and nothing can be read
    /// while the screen is locked.
    func restoreAll(reason: String) {
        restoreGen += 1
        restoring = true
        restoreStep(RestoreRun(gen: restoreGen, reason: reason))
    }

    private final class RestoreRun {
        let gen: Int, reason: String
        var pass = 0, calm = 0, waits = 0
        init(gen: Int, reason: String) { self.gen = gen; self.reason = reason }
    }
    private static let restoreGaps: [TimeInterval] = [3, 5, 8, 12, 15]

    private func restoreStep(_ run: RestoreRun) {
        guard run.gen == restoreGen else { return }
        func finish() {
            restoring = false
            suspendUntil = Date().addingTimeInterval(5)
            lastDigest = ""; pendingDigest = ""
        }
        func again(in delay: TimeInterval) {
            suspendUntil = max(suspendUntil, Date().addingTimeInterval(delay + 5))
            Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.restoreStep(run) }
        }
        if paused || Displays.current().isEmpty { finish(); return }
        if Session.locked {
            run.waits += 1
            if run.waits == 1 { Log.info("screen is locked; restoring once it is unlocked") }
            if run.waits > 720 { finish() } else { again(in: 5) }
            return
        }
        let windows = { [self] in
            guard run.gen == restoreGen else { return }
            let reason = run.pass == 0 ? run.reason : "\(run.reason), check \(run.pass + 1)"
            guard let r = restoreCurrent(reason: reason, quiet: run.pass > 0) else { finish(); return }
            if r.blind {
                // Apps are not answering yet (just woke up). Does not count as a pass.
                run.waits += 1
                if run.waits > 60 { finish() } else { again(in: 5) }
                return
            }
            run.calm = r.moved == 0 && r.failed == 0 && r.respaced.isEmpty && r.deferred == 0 ? run.calm + 1 : 0
            run.pass += 1
            if run.calm >= 2 || run.pass > Self.restoreGaps.count { finish() } else { again(in: Self.restoreGaps[run.pass - 1]) }
        }
        // Mission Control gets two chances; it sometimes is not ready right after a hotplug.
        if run.pass < 2 { restoreDesktops(reason: run.reason, then: windows) } else { windows() }
    }

    /// Put desktops back on the monitor they were saved on, then call `then` (always, on the main thread).
    func restoreDesktops(reason: String, then: @escaping () -> Void) {
        let displays = Displays.current()
        let fp = Displays.fingerprint(displays)
        guard config.restoreDesktops, !arrangingDesktops, !Session.locked, displays.count > 1, let file = Store.load(fp),
              let saved = file.preferred(pinnedFirst: config.preferPinned)?.layout.desktops ?? file.auto?.desktops ?? file.pinned?.desktops
        else { then(); return }
        let keys = Displays.keysByUUID()
        let steps = Desktops.plan(saved: saved, current: Desktops.current(keysByUUID: keys), occupied: Desktops.occupied())
        guard !steps.isEmpty else { then(); return }
        arrangingDesktops = true
        suspendUntil = .distantFuture
        Log.info("arranging desktops (\(reason)): \(steps.map(\.description).joined(separator: "; "))")
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Desktops.apply(steps, displays: displays, keysByUUID: keys)
            DispatchQueue.main.async {
                self.arrangingDesktops = false
                self.suspendUntil = Date().addingTimeInterval(3)
                self.note("Put desktops back on their monitors", details: [r.summary, "Trigger: \(reason)"] + r.failed.map { "Failed: \($0)" })
                then()
            }
        }
    }

    /// One restore pass. `pinned`: true forces the pinned layout, false the remembered one, nil the one the
    /// settings prefer. Returns nil when there is nothing saved.
    /// `quiet` passes only report when they had to move something.
    @discardableResult
    func restoreCurrent(reason: String, pinned: Bool? = nil, quiet: Bool = false) -> RestoreResult? {
        let fp = Displays.fingerprint(Displays.current())
        let file = Store.load(fp)
        let pick: (Layout, Bool)? = pinned == true ? file?.pinned.map { ($0, true) }
            : pinned == false ? file?.auto.map { ($0, false) }
            : file?.preferred(pinnedFirst: config.preferPinned).map { ($0.layout, $0.pinned) }
        guard let chosen = pick else {
            if !quiet { note("Nothing saved for this monitor set yet", details: ["Trigger: \(reason)"]) }
            return nil
        }
        let (layout, isPinned) = chosen
        suspendUntil = max(suspendUntil, Date().addingTimeInterval(3))
        let r = Restore.apply(layout, config: config, launchMissing: config.launchMissingApps && !quiet, toDesktops: true)
        if !quiet || r.moved > 0 || r.failed > 0 || !r.respaced.isEmpty {
            var details = ["After: \(reason)", r.short]
            if !r.waiting.isEmpty { details.append("Waiting for you to visit their desktop: " + Self.names(r.waiting)) }
            if !r.missingNames.isEmpty { details.append("Not running: " + r.missingNames.joined(separator: ", ")) }
            if !r.launched.isEmpty { details.append("Opened: " + r.launched.joined(separator: ", ")) }
            let suffix = isPinned ? " (pinned layout)" : ""
            let title = r.failed > 0 ? "\(r.failed) window\(r.failed == 1 ? "" : "s") would not move"
                : r.moved == 0 && !r.respaced.isEmpty ? "Sent \(r.respaced.count) app\(r.respaced.count == 1 ? "" : "s") back to \(r.respaced.count == 1 ? "its" : "their") desktop"
                : r.moved > 0 ? "Moved \(r.moved) window\(r.moved == 1 ? "" : "s") back"
                : "Everything is in place"
            note(title + suffix, details: details)
        }
        rememberPending(layout, r)
        windowCounts = WindowList.counts()
        lastDigest = ""
        return r
    }

    /// Keep the records we could not place (windows out of reach on other Spaces) and retry when the user switches Space.
    private func rememberPending(_ layout: Layout, _ r: RestoreResult) {
        pending = r.waitingIdx.isEmpty ? nil : (layout, Set(r.waitingIdx), Date().addingTimeInterval(30 * 60))
    }

    private func spaceChanged() {
        guard let p = pending, Date() < p.until, !paused, p.layout.fingerprint == currentFP else { pending = nil; return }
        suspendUntil = max(suspendUntil, Date().addingTimeInterval(8))
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            guard let self, let p = self.pending, !self.restoring else { return }
            let r = Restore.apply(p.layout, config: self.config, onlyIndices: p.indices)
            if r.moved > 0 {
                self.note("Placed \(r.moved) window\(r.moved == 1 ? "" : "s") on this desktop", details: [r.short])
            }
            // Only what was waiting before can still be waiting; never widen the set.
            let left = p.indices.intersection(r.waitingIdx)
            self.pending = left.isEmpty ? nil : (p.layout, left, p.until)
            self.windowCounts = WindowList.counts()
            self.lastDigest = ""
        }
    }

    // MARK: polling

    private func poll() {
        tick += 1
        reloadConfigIfChanged()
        if tick % 6 == 0 {
            let now = AX.trusted(prompt: false)
            if now != trusted {
                trusted = now
                if now { Log.info("Accessibility permission is back") }
                else { Log.warn("Accessibility permission was removed. Enable LayoutKeeper in System Settings > Privacy & Security > Accessibility.") }
                onChange?()
            }
        }
        if paused || !trusted { return }
        let displays = Displays.current()
        if displays.isEmpty { goDark(); return }
        if (dark || Displays.fingerprint(displays) != currentFP) && settleTimer?.isValid != true {
            displayChanged(reason: dark ? "displays back on" : "fingerprint drift detected by poll")
            return
        }
        if Date() < suspendUntil || restoring || Session.locked { return }

        if config.placeOnLaunch {
            let counts = WindowList.counts()
            for (bid, n) in counts where n > 0 && (windowCounts[bid] ?? 0) == 0 {
                schedulePlacement(bid, reason: "first window appeared")
            }
            windowCounts = counts
        }

        if config.autosave && tick % max(config.autosaveEveryTicks, 1) == 0 {
            autosave(force: false)
        }
    }

    func autosave(force: Bool) {
        let fpBefore = Displays.fingerprint(Displays.current())
        guard force || (!restoring && Date().timeIntervalSince(fpSince) > 45) else { return }
        let snap = Capture.snapshot(config: config)
        let layout = snap.fresh
        guard !layout.displays.isEmpty, layout.fingerprint == fpBefore, layout.fingerprint == currentFP || force else { return }
        // Windows exist but none could be read (permission hiccup, apps frozen): not a layout worth remembering.
        if layout.windows.isEmpty && WindowList.counts().contains(where: { $0.value > 0 && !config.ignoreBundleIDs.contains($0.key) }) {
            Log.debug("autosave skipped: no window could be read")
            return
        }
        let digest = Capture.digest(layout)
        if !force {
            if digest == lastDigest { return }
            if digest != pendingDigest { pendingDigest = digest; return }  // wait until stable across two polls
        }
        let merged = snap.merged
        do {
            try Store.put(merged, pinned: false)
            lastDigest = digest
            let stale = merged.windows.filter { $0.stale == true }.count
            let elsewhere = merged.windows.count - layout.windows.count - stale
            var note = ""
            if elsewhere > 0 { note += " +\(elsewhere) on other Spaces" }
            if stale > 0 { note += " +\(stale) remembered for closed apps" }
            Log.info("autosaved \(layout.windows.count) windows for \(layout.label) [\(layout.fingerprint)]\(note)")
        } catch {
            Log.error("autosave failed: \(error)")
        }
    }

    // MARK: place-on-launch

    private func layoutForPlacement(_ bid: String) -> Layout? {
        guard let layout = Store.load(currentFP)?.preferred(pinnedFirst: config.preferPinned)?.layout,
              layout.windows.contains(where: { $0.bundleID == bid }) else { return nil }
        return layout
    }

    private func schedulePlacement(_ bid: String, reason: String) {
        guard config.placeOnLaunch, !paused, !config.ignoreBundleIDs.contains(bid), layoutForPlacement(bid) != nil else { return }
        placementTimers[bid]?.forEach { $0.invalidate() }
        Log.info("\(bid) \(reason); will place its windows")
        var done = false
        let delays: [TimeInterval] = [1.5, 4, 8, 15]
        placementTimers[bid] = delays.map { delay in
            Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                guard let self, !done, !self.paused, !self.restoring, !Session.locked else { return }
                // Read the layout now, not when the app launched: it may have been saved again since.
                guard let layout = self.layoutForPlacement(bid) else { return }
                let r = Restore.apply(layout, config: self.config, onlyBundle: bid)
                if r.moved > 0 || r.alreadyInPlace > 0 {
                    done = true
                    Log.info("placed \(bid): \(r.summary)")
                    self.windowCounts = WindowList.counts()
                    self.lastDigest = ""
                } else if delay == delays.last {
                    Log.info("\(bid): no window to place (\(r.failed > 0 ? "it would not move" : "none reachable"))")
                }
            }
        }
    }

    // MARK: CLI command channel

    func handleCommands() {
        // A bare signal does nothing: a CLI that timed out leaves one behind, and that must not move windows.
        let cmds = Commands.pending()
        for c in cmds {
            Log.info("command from CLI: \(c.name) \(c.args.joined(separator: " "))")
            Commands.reply(c, execute(c))
        }
    }

    private func execute(_ c: Command) -> String {
        func has(_ f: String) -> Bool { c.args.contains(f) }
        func opt(_ f: String) -> String? { c.args.firstIndex(of: f).flatMap { $0 + 1 < c.args.count ? c.args[$0 + 1] : nil } }
        switch c.name {
        case "capture":
            return Store.encodeJSON(Capture.layout(config: config))
        case "save":
            do {
                let snap = try pin()
                let extra = snap.merged.windows.count - snap.fresh.windows.count
                return "Pinned \(snap.fresh.windows.count) visible windows\(extra > 0 ? " (+\(extra) known from other Spaces / closed apps)" : "") for \(snap.fresh.label) [\(snap.fresh.fingerprint)]"
            } catch { return "ERROR save failed: \(error.localizedDescription)" }
        case "restore":
            let fp = Displays.fingerprint(Displays.current())
            guard let file = Store.load(fp) else { return "ERROR No saved layout for this monitor set [\(fp)]." }
            let chosen = has("--auto") ? file.auto.map { ($0, false) } : (has("--pinned") ? file.pinned.map { ($0, true) } : file.preferred(pinnedFirst: config.preferPinned))
            guard let (layout, isPinned) = chosen else { return "ERROR No matching layout saved for [\(fp)]." }
            suspendUntil = Date().addingTimeInterval(3)
            let r = Restore.apply(layout, config: config, onlyBundle: opt("--app"),
                                  launchMissing: has("--launch") || config.launchMissingApps, dryRun: has("--dry-run"), toDesktops: true)
            if !has("--dry-run") && opt("--app") == nil { rememberPending(layout, r); lastDigest = "" }
            windowCounts = WindowList.counts()
            return "\(has("--dry-run") ? "Would restore" : "Restored") \(layout.label) (\(isPinned ? "pinned" : "auto")): \(r.summary)"
        case "nudge":
            guard c.args.count >= 3, let dx = Double(c.args[1]), let dy = Double(c.args[2]) else { return "ERROR usage: nudge <bundleID> <dx> <dy>" }
            var lines: [String] = []
            for app in AX.apps(ignore: [], only: c.args[0]) {
                for w in app.windows where !w.fullscreen && !w.minimized {
                    let got = AX.setFrame(w.element, w.frame.offsetBy(dx: dx, dy: dy))
                    lines.append("\(app.name) '\(w.title.prefix(40))' \(Rect(w.frame).short) -> \(got.map { Rect($0).short } ?? "?")")
                }
            }
            return lines.isEmpty ? "no windows for \(c.args[0])" : lines.joined(separator: "\n")
        case "desktops":
            let displays = Displays.current()
            let keys = Displays.keysByUUID()
            let names = Dictionary(displays.map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
            let cur = Desktops.current(keysByUUID: keys)
            let file = Store.load(Displays.fingerprint(displays))
            let saved = file?.preferred(pinnedFirst: config.preferPinned)?.layout.desktops ?? file?.auto?.desktops ?? file?.pinned?.desktops
            var lines = ["Now:"] + cur.sorted { $0.key < $1.key }.map { "  \(names[$0.key] ?? $0.key): \($0.value.count) desktops \($0.value.map { String($0.prefix(8)) })" }
            guard let saved else { return (lines + ["Nothing saved for this monitor set yet."]).joined(separator: "\n") }
            lines += ["Saved:"] + saved.sorted { $0.key < $1.key }.map { "  \(names[$0.key] ?? $0.key): \($0.value.count) desktops \($0.value.map { String($0.prefix(8)) })" }
            let steps = Desktops.plan(saved: saved, current: cur, occupied: Desktops.occupied())
            if steps.isEmpty { return (lines + ["Desktops are where they belong."]).joined(separator: "\n") }
            lines += ["Plan:"] + steps.map { "  \($0)" }
            if has("--dry-run") { return lines.joined(separator: "\n") }
            suspendUntil = Date().addingTimeInterval(30)
            let r = Desktops.apply(steps, displays: displays, keysByUUID: keys)
            suspendUntil = Date().addingTimeInterval(3)
            note("Put desktops back on their monitors", details: [r.summary, "Trigger: CLI"] + r.failed.map { "Failed: \($0)" })
            return (lines + ["Result: \(r.summary)"] + r.failed.map { "  failed: \($0)" }).joined(separator: "\n")
        case "reload":
            restoreAll(reason: "CLI")
            return "Restoring the layout for the current monitor set."
        case "simulate":
            // Test hooks (tests/e2e.sh): the paths that otherwise need a real unplug, sleep or lock screen.
            switch c.args.first ?? "" {
            case "wake": displayChanged(reason: "woke from sleep (simulated)"); return "simulated wake"
            case "display": displayChanged(reason: "reconfiguration (simulated)"); return "simulated display change"
            case "lock": Session.pretendLocked = true; return "pretending the screen is locked"
            case "unlock": Session.pretendLocked = false; return "screen no longer pretend-locked"
            case "respace":
                // Send an app to some other desktop, as macOS does when a monitor goes away.
                guard c.args.count >= 2, let ra = NSRunningApplication.runningApplications(withBundleIdentifier: c.args[1]).first else { return "ERROR usage: simulate respace <bundleID>" }
                let index = PrivateAPI.spaceIndex()
                let here = Set(WindowList.real().filter { $0.pid == ra.processIdentifier }.map(\.space))
                guard let other = index.filter({ $0.value.userDesktop && !here.contains($0.key) }).keys.sorted().first else { return "ERROR no other desktop" }
                return PrivateAPI.moveApp(pid: ra.processIdentifier, toSpace: other) ? "moved to space \(other)" : "ERROR could not move"
            default: return "ERROR usage: simulate wake|display|lock|unlock"
            }
        case "autosave":
            autosave(force: true)
            return "autosaved"
        case "probe":
            return Debug.probe(only: c.args.first)
        case "inventory":
            return Debug.inventory()
        case "open":
            let d = c.args.first.flatMap(Int.init).map { DesktopFilter.desktop($0) }
            if menuBar == nil { menuBar = MenuBar(watcher: self) }
            menuBar?.showLayouts(desktop: d)
            return "Opened the Layouts window"
        case "ping":
            return "pong pid \(getpid()) v\(Version.string) trusted=\(AX.trusted(prompt: false)) set=\(currentFP) menubar=\(menuBar != nil ? "on" : "off")\(paused ? " paused" : "")\(restoring ? " restoring" : "")"
        default:
            return "ERROR unknown command \(c.name)"
        }
    }

    // MARK: helpers

    private static func names(_ recs: [WindowRecord]) -> String {
        var seen = Set<String>()
        return recs.map(\.appName).filter { seen.insert($0).inserted }.joined(separator: ", ")
    }

    private static func short(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f.string(from: d)
    }
}
