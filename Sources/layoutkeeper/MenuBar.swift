import AppKit

/// Menu bar item for the daemon: a visual preview of the saved layout per desktop, save/restore/pause,
/// settings toggles, and shortcuts to the layouts window, config, layouts folder and log.
final class MenuBar: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu = NSMenu()
    private unowned let watcher: Watcher
    private lazy var layoutsWindow = LayoutWindowController(watcher: watcher)

    /// Boolean settings exposed in the Settings submenu (key, menu title).
    private static let toggles: [(String, String)] = [
        ("restoreOnDisplayChange", "Restore When Monitors Change"),
        ("restoreDesktops", "Move Desktops Back to Their Monitor"),
        ("moveWindowsToDesktops", "Move Windows Back to Their Desktop"),
        ("autosave", "Remember Layout Automatically"),
        ("preferPinned", "Always Restore the Pinned Layout"),
        ("placeOnLaunch", "Place Apps When They Open"),
        ("launchMissingApps", "Open Missing Apps on Restore"),
    ]

    init(watcher: Watcher) {
        self.watcher = watcher
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        watcher.onChange = { [weak self] in self?.refreshIcon() }
        refreshIcon()
    }

    func remove() { NSStatusBar.system.removeStatusItem(item) }

    func refreshIcon() {
        let symbol = !watcher.trusted ? "exclamationmark.triangle" : (watcher.paused ? "pause.rectangle" : "macwindow.on.rectangle")
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "LayoutKeeper") {
            img.isTemplate = true
            item.button?.image = img
        } else {
            item.button?.title = "LK"
        }
        item.button?.appearsDisabled = watcher.paused
        item.button?.toolTip = !watcher.trusted ? "LayoutKeeper needs the Accessibility permission"
            : "LayoutKeeper\(watcher.paused ? " (paused)" : "")"
    }

    func showLayouts(desktop: DesktopFilter? = nil, fingerprint: String? = nil) {
        layoutsWindow.show(fingerprint: fingerprint, desktop: desktop)
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let displays = Displays.current()
        let fp = Displays.fingerprint(displays)
        let file = Store.load(fp)
        let config = watcher.config

        if !watcher.trusted {
            let fix = add("⚠︎ Grant Accessibility Permission…", #selector(openPrivacy))
            fix.toolTip = "Enable LayoutKeeper in System Settings ▸ Privacy & Security ▸ Accessibility. It starts working within 5 seconds."
            menu.addItem(.separator())
        }

        header(Displays.label(displays))
        let chosen = file?.preferred(pinnedFirst: config.preferPinned)
        if let layout = chosen?.layout {
            let open = layout.open.count
            let desks = DesktopFilter.present(in: layout, includeRemembered: false).filter { $0 != .unknown }.count
            if open > 0 {
                let grid = NSMenuItem()
                grid.view = DesktopGridView(layout: layout) { [weak self] f in self?.showLayouts(desktop: f) }
                menu.addItem(grid)
            }
            var line = open == 0 ? "No open windows saved" : "\(open) window\(open == 1 ? "" : "s")\(desks > 1 ? " on \(desks) desktops" : "")"
            line += chosen?.pinned == true ? " · pinned \(Self.when(layout.savedAt))" : " · saved \(Self.when(layout.savedAt))"
            info(line)
        } else {
            info(config.autosave ? "Nothing saved yet. Arrange your windows;\nthey are remembered within a minute."
                                 : "Nothing saved yet. Arrange your windows and pin the layout.")
        }

        if let e = watcher.lastEvent {
            menu.addItem(.separator())
            let last = add("\(e.title) · \(Self.time(e.at))", #selector(noop))
            if #available(macOS 14.4, *), let first = e.details.first { last.subtitle = first }
            if !e.details.isEmpty {
                let sub = NSMenu()
                for d in e.details {
                    let mi = NSMenuItem(title: d, action: nil, keyEquivalent: "")
                    mi.isEnabled = false
                    sub.addItem(mi)
                }
                last.submenu = sub
            }
        }
        menu.addItem(.separator())

        let restoreItem = add("Restore Layout Now", #selector(restore), key: "r", symbol: "arrow.uturn.backward")
        restoreItem.isEnabled = chosen != nil && watcher.trusted && !watcher.paused
        restoreItem.toolTip = "Put every window back where it was last left on \(Displays.label(displays))."
        add("Show Layouts…", #selector(openLayouts), key: "l", symbol: "rectangle.3.group")

        let pin = add("Pinned Layout", nil, symbol: "pin")
        pin.isEnabled = true
        let pinMenu = NSMenu()
        pinMenu.autoenablesItems = false
        func pinItem(_ title: String, _ sel: Selector?, key: String = "", enabled: Bool = true) {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            mi.target = self
            mi.isEnabled = sel != nil && enabled
            pinMenu.addItem(mi)
        }
        if let p = file?.pinned {
            pinItem("\(p.open.count) window\(p.open.count == 1 ? "" : "s") · pinned \(Self.when(p.savedAt))", nil)
            pinMenu.addItem(.separator())
            pinItem("Restore Pinned Layout", #selector(restorePinned), enabled: watcher.trusted)
            pinItem("Replace with Current Layout", #selector(save), key: "s", enabled: watcher.trusted)
            pinItem("Forget Pinned Layout", #selector(forgetPinned))
        } else {
            pinItem("A snapshot of your windows you can go back to", nil)
            pinMenu.addItem(.separator())
            pinItem("Pin Current Layout", #selector(save), key: "s", enabled: watcher.trusted)
        }
        pin.submenu = pinMenu

        let others = Store.list().filter { $0.fingerprint != fp }
        if !others.isEmpty {
            let sets = add("Other Monitor Sets", nil, symbol: "display.2")
            let sub = NSMenu()
            for f in others {
                let n = f.preferred(pinnedFirst: config.preferPinned)?.layout.open.count ?? 0
                let mi = NSMenuItem(title: "\(f.label.isEmpty ? "Unnamed" : f.label) · \(n) window\(n == 1 ? "" : "s")", action: #selector(openSet(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = f.fingerprint
                sub.addItem(mi)
            }
            sets.submenu = sub
            sets.isEnabled = true
        }
        menu.addItem(.separator())

        let pause = add(watcher.paused ? "Resume LayoutKeeper" : "Pause LayoutKeeper", #selector(togglePause), key: "p",
                        symbol: watcher.paused ? "play.circle" : "pause.circle")
        pause.state = watcher.paused ? .on : .off

        let settings = add("Settings", nil, symbol: "gearshape")
        settings.isEnabled = true
        let sub = NSMenu()
        sub.autoenablesItems = false
        let values = Self.boolValues(config)
        for (key, title) in Self.toggles {
            let mi = NSMenuItem(title: title, action: #selector(toggleSetting(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = key
            mi.state = values[key] == true ? .on : .off
            mi.toolTip = ConfigDocs.entries.first { $0.key == key }?.help
            sub.addItem(mi)
        }
        sub.addItem(.separator())
        for (title, sel) in [("Edit Config File…", #selector(openConfig)), ("Open Layouts Folder", #selector(openLayoutsFolder)),
                             ("Open Log", #selector(openLog))] {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self
            sub.addItem(mi)
        }
        settings.submenu = sub
        menu.addItem(.separator())

        add("LayoutKeeper Help", #selector(openRepo), symbol: "questionmark.circle").toolTip = "Version \(Version.string) · opens the project page"
        add("Quit LayoutKeeper", #selector(quit), key: "q", symbol: "power")
    }

    @discardableResult
    private func add(_ title: String, _ sel: Selector?, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        if let symbol { mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        mi.target = self
        mi.isEnabled = sel != nil
        menu.addItem(mi)
        return mi
    }

    private func header(_ title: String) {
        if #available(macOS 14, *) {
            menu.addItem(.sectionHeader(title: title))
        } else {
            let mi = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            mi.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor])
            mi.isEnabled = false
            menu.addItem(mi)
        }
    }

    private func info(_ title: String) {
        let mi = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        mi.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.labelColor])
        mi.isEnabled = false
        menu.addItem(mi)
    }

    private static func boolValues(_ c: Config) -> [String: Bool] {
        ["restoreOnDisplayChange": c.restoreOnDisplayChange, "restoreDesktops": c.restoreDesktops, "autosave": c.autosave,
         "placeOnLaunch": c.placeOnLaunch, "launchMissingApps": c.launchMissingApps, "preferPinned": c.preferPinned,
         "moveWindowsToDesktops": c.moveWindowsToDesktops]
    }

    private static func when(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short; f.timeStyle = .short; f.doesRelativeDateFormatting = true
        return f.string(from: d)
    }

    private static func time(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? DateFormatter.localizedString(from: d, dateStyle: .none, timeStyle: .short) : when(d)
    }

    // MARK: actions

    @objc private func noop() {}
    @objc private func save() { watcher.pinCurrent(reason: "menu") }
    @objc private func restore() { watcher.restoreAll(reason: "menu") }
    @objc private func restorePinned() { watcher.restoreCurrent(reason: "menu", pinned: true) }
    @objc private func openLayouts() { showLayouts() }
    @objc private func openSet(_ sender: NSMenuItem) { showLayouts(fingerprint: sender.representedObject as? String) }
    @objc private func forgetPinned() {
        let fp = Displays.fingerprint(Displays.current())
        guard var f = Store.load(fp) else { return }
        f.pinned = nil
        try? Store.save(f)
        watcher.note("Forgot the pinned layout", details: ["Restores now use the automatically remembered layout"])
    }
    @objc private func togglePause() {
        watcher.paused.toggle()
        watcher.note(watcher.paused ? "Paused" : "Resumed")
    }
    @objc private func toggleSetting(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        watcher.setConfig(key, sender.state == .on ? "false" : "true")
    }
    @objc private func openPrivacy() {
        _ = AX.trusted(prompt: true)
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(u) }
    }
    @objc private func openConfig() { _ = Store.config(); NSWorkspace.shared.open(Store.configURL) }
    @objc private func openLayoutsFolder() { Store.ensureDirs(); NSWorkspace.shared.open(Store.layoutsDir) }
    @objc private func openLog() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LayoutKeeper.log"))
    }
    @objc private func openRepo() { if let u = URL(string: Version.repo) { NSWorkspace.shared.open(u) } }
    @objc private func quit() {
        // Unload the LaunchAgent so launchd does not immediately restart us; `scripts/install.sh` re-enables it.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())/\(Version.agentLabel)"]
        try? p.run()
        exit(0)
    }
}
