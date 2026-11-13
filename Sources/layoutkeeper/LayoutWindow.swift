import AppKit

/// "Layouts" window: pick a monitor set and desktop, see the saved windows on a map and in a table,
/// and save / restore / forget.
final class LayoutWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private unowned let watcher: Watcher
    private let setPopup = NSPopUpButton()
    private let kind = NSSegmentedControl(labels: ["Pinned", "Remembered"], trackingMode: .selectOne, target: nil, action: nil)
    private let desktops = NSSegmentedControl()
    private let closedToggle = NSButton(checkboxWithTitle: "Show closed apps", target: nil, action: nil)
    private var showClosed: Bool { closedToggle.state == .on }
    private let map = LayoutMapView()
    private let table = NSTableView()
    private let info = NSTextField(labelWithString: "")
    private let restoreButton = NSButton(title: "Restore Now", target: nil, action: nil)
    private let saveButton = NSButton(title: "Pin Current Layout", target: nil, action: nil)
    private let forgetButton = NSButton(title: "Forget…", target: nil, action: nil)

    private var files: [LayoutFile] = []
    private var file: LayoutFile?
    private var filters: [DesktopFilter] = [.all]
    private var rows: [WindowRecord] = []

    init(watcher: Watcher) {
        self.watcher = watcher
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "LayoutKeeper — Layouts"
        w.minSize = NSSize(width: 640, height: 520)
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("LayoutKeeperLayouts")
        super.init(window: w)
        w.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(fingerprint: String? = nil, desktop: DesktopFilter? = nil) {
        reloadFiles(select: fingerprint ?? file?.fingerprint ?? Displays.fingerprint(Displays.current()))
        if let desktop, let i = filters.firstIndex(of: desktop) { desktops.selectedSegment = i; filterChanged() }
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) { reloadFiles(select: file?.fingerprint) }

    // MARK: layout

    private func build() {
        guard let content = window?.contentView else { return }
        setPopup.target = self; setPopup.action = #selector(setChanged)
        kind.target = self; kind.action = #selector(kindChanged)
        desktops.target = self; desktops.action = #selector(filterChanged)
        desktops.segmentStyle = .rounded
        closedToggle.target = self; closedToggle.action = #selector(kindChanged)
        closedToggle.toolTip = "Also show where apps that are not running were last seen (dashed). They are placed there when they open."
        restoreButton.target = self; restoreButton.action = #selector(restore)
        restoreButton.keyEquivalent = "r"; restoreButton.keyEquivalentModifierMask = .command
        saveButton.target = self; saveButton.action = #selector(save)
        saveButton.keyEquivalent = "s"; saveButton.keyEquivalentModifierMask = .command
        forgetButton.target = self; forgetButton.action = #selector(forget)
        info.textColor = .secondaryLabelColor
        info.lineBreakMode = .byTruncatingTail

        let top = NSStackView(views: [label("Monitor set"), setPopup, NSView(), closedToggle, kind])
        top.orientation = .horizontal
        top.spacing = 8
        setPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let mapBox = NSBox()
        mapBox.boxType = .custom
        mapBox.cornerRadius = 8
        mapBox.borderColor = .separatorColor
        mapBox.fillColor = .textBackgroundColor
        mapBox.contentViewMargins = NSSize(width: 10, height: 10)
        mapBox.contentView = map

        for (id, title, width) in [("app", "App", 130.0), ("title", "Window", 210.0), ("display", "Display", 140.0),
                                   ("desktop", "Desktop", 56.0), ("frame", "Position", 130.0), ("state", "State", 110.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.minWidth = 40
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 22
        table.style = .inset
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        let bottom = NSStackView(views: [info, NSView(), forgetButton, saveButton, restoreButton])
        bottom.orientation = .horizontal
        bottom.spacing = 8
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [top, desktops, mapBox, scroll, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            mapBox.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            mapBox.heightAnchor.constraint(equalTo: scroll.heightAnchor, multiplier: 1.6),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.textColor = .secondaryLabelColor
        return l
    }

    // MARK: data

    private func reloadFiles(select fp: String?) {
        let current = Displays.fingerprint(Displays.current())
        files = Store.list().sorted { a, b in
            if (a.fingerprint == current) != (b.fingerprint == current) { return a.fingerprint == current }
            return a.label < b.label
        }
        setPopup.removeAllItems()
        for f in files {
            setPopup.addItem(withTitle: f.label + (f.fingerprint == current ? "  (connected)" : ""))
            setPopup.lastItem?.representedObject = f.fingerprint
        }
        if files.isEmpty { setPopup.addItem(withTitle: "Nothing saved yet") }
        let idx = files.firstIndex { $0.fingerprint == fp } ?? 0
        setPopup.selectItem(at: idx)
        file = files.indices.contains(idx) ? files[idx] : nil
        let prevKind = kind.selectedSegment
        kind.setEnabled(file?.pinned != nil, forSegment: 0)
        kind.setEnabled(file?.auto != nil, forSegment: 1)
        if prevKind < 0 || !kind.isEnabled(forSegment: prevKind) {
            kind.selectedSegment = file?.preferred(pinnedFirst: watcher.config.preferPinned)?.pinned == true ? 0 : 1
        }
        showLayout()
    }

    private var layout: Layout? { kind.selectedSegment == 0 ? file?.pinned : file?.auto }
    private var isCurrent: Bool { file?.fingerprint == Displays.fingerprint(Displays.current()) }

    private func showLayout() {
        let prev = desktops.selectedSegment >= 0 && desktops.selectedSegment < filters.count ? filters[desktops.selectedSegment] : .all
        filters = [.all] + (layout.map { DesktopFilter.present(in: $0, includeRemembered: showClosed) } ?? [])
        desktops.segmentCount = filters.count
        for (i, f) in filters.enumerated() {
            let n = layout?.windows.filter { f.includes($0) && (showClosed || $0.stale != true) }.count ?? 0
            desktops.setLabel(f == .all ? "All · \(n)" : "\(f.title) · \(n)", forSegment: i)
            desktops.setWidth(0, forSegment: i)
        }
        desktops.selectedSegment = filters.firstIndex(of: prev) ?? 0
        map.showRemembered = showClosed
        map.layout = layout
        closedToggle.isEnabled = !(layout?.remembered.isEmpty ?? true)
        filterChanged()

        let used = file?.preferred(pinnedFirst: watcher.config.preferPinned)?.pinned == true ? "pinned" : "remembered"
        if let l = layout {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; f.doesRelativeDateFormatting = true
            let apps = Set(l.remembered.map(\.bundleID)).count
            info.stringValue = "Saved \(f.string(from: l.savedAt)) · \(l.open.count) windows"
                + (apps > 0 ? " · \(apps) closed app\(apps == 1 ? "" : "s") remembered" : "") + " · restores use the \(used) layout"
                + (isCurrent ? "" : " · not connected")
        } else {
            info.stringValue = "Nothing saved for this monitor set yet."
        }
        restoreButton.isEnabled = isCurrent && file != nil
        saveButton.isEnabled = isCurrent || file == nil
        forgetButton.isEnabled = layout != nil
    }

    @objc private func setChanged() {
        reloadFiles(select: setPopup.selectedItem?.representedObject as? String)
    }

    @objc private func kindChanged() { showLayout() }

    @objc private func filterChanged() {
        let f = filters.indices.contains(desktops.selectedSegment) ? filters[desktops.selectedSegment] : .all
        map.filter = f
        rows = (layout?.windows ?? []).filter { f.includes($0) && (showClosed || $0.stale != true) }
            .sorted { ($0.desktop ?? .max, $0.appName, $0.index) < ($1.desktop ?? .max, $1.appName, $1.index) }
        table.reloadData()
    }

    // MARK: actions

    @objc private func restore() {
        watcher.restoreCurrent(reason: "layouts window", pinned: kind.selectedSegment == 0)
        info.stringValue = watcher.lastEvent?.title ?? ""
    }

    @objc private func save() {
        watcher.pinCurrent(reason: "layouts window")
        kind.selectedSegment = 0
        reloadFiles(select: Displays.fingerprint(Displays.current()))
    }

    @objc private func forget() {
        guard var f = file else { return }
        let which = kind.selectedSegment == 0 ? "pinned" : "remembered"
        let alert = NSAlert()
        alert.messageText = "Forget the \(which) layout for \(f.label)?"
        alert.informativeText = kind.selectedSegment == 0
            ? "Restores will fall back to the automatically remembered layout."
            : "LayoutKeeper will start remembering this monitor set from scratch."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if kind.selectedSegment == 0 { f.pinned = nil } else { f.auto = nil }
        if f.pinned == nil && f.auto == nil { Store.delete(f.fingerprint) } else { try? Store.save(f) }
        watcher.note("Forgot \(which) layout for \(f.label)")
        kind.selectedSegment = -1
        reloadFiles(select: f.fingerprint)
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, rows.indices.contains(row) else { return nil }
        let r = rows[row]
        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("cell-\(id)"), owner: self) as? NSTableCellView
            ?? makeCell(id: id)
        let names = Dictionary((layout?.displays ?? []).map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
        switch id {
        case "app": cell.textField?.stringValue = r.appName; cell.imageView?.image = AppLook.icon(r.bundleID)
        case "title": cell.textField?.stringValue = r.title.isEmpty ? "—" : r.title
        case "display": cell.textField?.stringValue = names[r.displayKey] ?? "Disconnected display"
        case "desktop": cell.textField?.stringValue = r.desktop.map(String.init) ?? "—"
        case "frame": cell.textField?.stringValue = "\(Int(r.rel.w))×\(Int(r.rel.h)) @ \(Int(r.rel.x)),\(Int(r.rel.y))"
        default:
            cell.textField?.stringValue = r.stale == true ? "App not running" : (r.minimized ? "Minimized" : "Open")
        }
        cell.toolTip = WindowText.describe(r)
        return cell
    }

    private func makeCell(id: String) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier("cell-\(id)")
        let tf = NSTextField(labelWithString: "")
        tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf
        var lead = cell.leadingAnchor
        if id == "app" {
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(iv)
            cell.imageView = iv
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
            ])
            lead = iv.trailingAnchor
        }
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: lead, constant: 4),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
