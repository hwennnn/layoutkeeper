import AppKit

/// Which windows of a layout to show: everything, one desktop, or windows whose desktop is unknown.
enum DesktopFilter: Hashable {
    case all, desktop(Int), unknown

    func includes(_ r: WindowRecord) -> Bool {
        switch self {
        case .all: return true
        case .desktop(let n): return r.desktop == n
        case .unknown: return r.desktop == nil
        }
    }

    var title: String {
        switch self {
        case .all: return "All Desktops"
        case .desktop(let n): return "Desktop \(n)"
        case .unknown: return "Unknown Desktop"
        }
    }

    /// Filters that have at least one window, in desktop order.
    static func present(in layout: Layout, includeRemembered: Bool = true) -> [DesktopFilter] {
        let windows = includeRemembered ? layout.windows : layout.open
        var out = Set(windows.compactMap(\.desktop)).sorted().map { DesktopFilter.desktop($0) }
        if windows.contains(where: { $0.desktop == nil }) { out.append(.unknown) }
        return out
    }
}

/// Pure geometry for drawing a saved layout: display and window rects scaled into a (flipped) view.
struct LayoutGeometry {
    struct Item { let rec: WindowRecord; let rect: CGRect }
    let displays: [(info: DisplayInfo, rect: CGRect)]
    /// Back-to-front: larger windows first so small ones stay visible on top.
    let items: [Item]

    init(layout: Layout, filter: DesktopFilter, in bounds: CGRect, inset: CGFloat = 4, includeRemembered: Bool = true) {
        let union = layout.displays.reduce(CGRect.null) { $0.union($1.frame.cg) }
        guard !union.isNull, union.width > 0, union.height > 0 else { displays = []; items = []; return }
        let s = min((bounds.width - 2 * inset) / union.width, (bounds.height - 2 * inset) / union.height)
        let ox = bounds.minX + (bounds.width - union.width * s) / 2
        let oy = bounds.minY + (bounds.height - union.height * s) / 2
        func map(_ r: CGRect) -> CGRect {
            CGRect(x: ox + (r.minX - union.minX) * s, y: oy + (r.minY - union.minY) * s, width: r.width * s, height: r.height * s)
        }
        let byKey = Dictionary(layout.displays.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        displays = layout.displays.map { ($0, map($0.frame.cg).integral) }
        items = layout.windows.filter { filter.includes($0) && !$0.minimized && (includeRemembered || $0.stale != true) }.compactMap { rec in
            let d = byKey[rec.displayKey]
            let frame = d.map { rec.rel.cg.offsetBy(dx: $0.frame.x, dy: $0.frame.y) } ?? rec.abs.cg
            var r = map(frame)
            if let d { r = r.intersection(map(d.frame.cg)) }
            return r.isNull || r.width < 1 || r.height < 1 ? nil : Item(rec: rec, rect: r)
        }.sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
    }

    /// Topmost window under a point.
    func item(at p: CGPoint) -> Item? { items.last { $0.rect.contains(p) } }
}

enum AppLook {
    private static var icons: [String: NSImage] = [:]

    static func icon(_ bundleID: String) -> NSImage {
        if let i = icons[bundleID] { return i }
        let img: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            img = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            img = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        icons[bundleID] = img
        return img
    }

    /// Stable per-app tint.
    static func color(_ bundleID: String) -> NSColor {
        var h: UInt32 = 5381
        for b in bundleID.utf8 { h = (h &* 33) &+ UInt32(b) }
        return NSColor(calibratedHue: CGFloat(h % 360) / 360, saturation: 0.42, brightness: 0.92, alpha: 1)
    }
}

/// Draws one desktop of a layout: monitors as rounded panels, windows as tinted rectangles with app icons.
final class LayoutMapView: NSView, NSViewToolTipOwner {
    var layout: Layout? { didSet { needsDisplay = true; rebuildToolTips() } }
    var filter: DesktopFilter = .all { didSet { needsDisplay = true; rebuildToolTips() } }
    /// Draw display names and app names (off for small thumbnails).
    var showLabels = true
    /// Also draw (dashed) where closed apps were last seen.
    /// Stronger outline, for the desktop on screen right now.
    var highlighted = false
    var showRemembered = true { didSet { needsDisplay = true; rebuildToolTips() } }
    var onClick: (() -> Void)?
    private var geometry: LayoutGeometry?

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rebuildToolTips()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout else { return }
        let g = LayoutGeometry(layout: layout, filter: filter, in: bounds, includeRemembered: showRemembered)
        geometry = g
        let small = bounds.width < 260

        for (_, r) in g.displays {
            let panel = NSBezierPath(roundedRect: r, xRadius: small ? 3 : 6, yRadius: small ? 3 : 6)
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            panel.fill()
            NSColor.labelColor.withAlphaComponent(highlighted ? 0.45 : 0.18).setStroke()
            panel.lineWidth = 1
            panel.stroke()
        }

        for it in g.items {
            let stale = it.rec.stale == true
            let r = it.rect.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: r, xRadius: small ? 2 : 4, yRadius: small ? 2 : 4)
            let tint = AppLook.color(it.rec.bundleID)
            tint.withAlphaComponent(stale ? 0.08 : 0.22).setFill()
            path.fill()
            tint.withAlphaComponent(stale ? 0.5 : 0.8).setStroke()
            path.lineWidth = 1
            if stale { path.setLineDash([4, 3], count: 2, phase: 0) }
            path.stroke()

        }

        // Display names last, on a pill, so windows never cover them.
        if showLabels && !small {
            for (info, r) in g.displays {
                let text = info.name + (info.isMain ? " (main)" : "")
                let w = min((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width + 14, r.width - 12)
                let pill = CGRect(x: r.minX + 6, y: r.maxY - 24, width: w, height: 18)
                NSColor.windowBackgroundColor.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 9, yRadius: 9).fill()
                label(text, in: pill.insetBy(dx: 7, dy: 1), size: 11, color: .secondaryLabelColor, align: .bottomLeft)
            }
        }

        // Icons + names: windows sharing a center (maximized apps, stacked dialogs) are drawn as one row of icons
        // with a combined label, so nothing overprints.
        var clusters: [[LayoutGeometry.Item]] = []
        for it in g.items {
            let c = CGPoint(x: it.rect.midX, y: it.rect.midY)
            if let i = clusters.firstIndex(where: { hypot($0[0].rect.midX - c.x, $0[0].rect.midY - c.y) < (small ? 8 : 30) }) {
                clusters[i].append(it)
            } else { clusters.append([it]) }
        }
        var placed: [CGRect] = []
        for cl in clusters {
            let r = cl.map(\.rect).min { $0.width * $0.height < $1.width * $1.height }!
            var seen = Set<String>()
            let all = cl.reversed().filter { seen.insert($0.rec.bundleID).inserted }
            let side = min(small ? 20 : 36, r.height * 0.55, max((r.width - 8) / CGFloat(all.count) - 3, small ? 10 : 20))
            guard side >= 7 else { continue }
            let apps = Array(all.prefix(max(Int((r.width - 4) / (side + 3)), 1)))
            let nameH: CGFloat = showLabels && !small && r.height > side + 26 ? 16 : 0
            let rowW = CGFloat(apps.count) * side + CGFloat(apps.count - 1) * 3
            var x = r.midX - rowW / 2
            var y = r.midY - (side + nameH) / 2
            // Nudge down (then up) past labels already drawn, staying inside the window where possible.
            let labelW = nameH > 0 ? min(r.width - 8, 220) : rowW
            func block(_ y: CGFloat) -> CGRect { CGRect(x: r.midX - max(rowW, labelW) / 2, y: y, width: max(rowW, labelW), height: side + nameH + 2) }
            for step in [0, 1, -1, 2, -2] as [CGFloat] {
                let cand = r.midY - (side + nameH) / 2 + step * (side + nameH + 6)
                // Icons never leave their window (in a thumbnail they would land on the caption).
                if cand < r.minY || cand + side + nameH > r.maxY { continue }
                if !placed.contains(where: { $0.intersects(block(cand)) }) { y = cand; break }
            }
            placed.append(block(y))
            for it in apps {
                AppLook.icon(it.rec.bundleID).draw(in: CGRect(x: x, y: y, width: side, height: side), from: .zero, operation: .sourceOver,
                                                   fraction: it.rec.stale == true ? 0.45 : 1, respectFlipped: true, hints: nil)
                x += side + 3
            }
            if nameH > 0 {
                label(apps.map(\.rec.appName).joined(separator: ", "), in: CGRect(x: r.minX + 4, y: y + side + 2, width: r.width - 8, height: nameH),
                      size: 11, color: .labelColor, align: .center)
            }
        }
    }

    private enum Align { case center, bottomLeft }

    private func label(_ s: String, in r: CGRect, size: CGFloat, color: NSColor, align: Align) {
        let para = NSMutableParagraphStyle()
        para.alignment = align == .center ? .center : .left
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .medium),
                                                    .foregroundColor: color, .paragraphStyle: para]
        let h = ceil(NSFont.systemFont(ofSize: size).boundingRectForFont.height)
        let rect = align == .center ? CGRect(x: r.minX, y: r.minY, width: r.width, height: h)
                                    : CGRect(x: r.minX, y: r.maxY - h, width: r.width, height: h)
        (s as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }

    // MARK: tooltips and clicks

    private func rebuildToolTips() {
        removeAllToolTips()
        guard let layout, showLabels else { return }
        for it in LayoutGeometry(layout: layout, filter: filter, in: bounds, includeRemembered: showRemembered).items {
            addToolTip(it.rect, owner: self, userData: nil)
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
                       userData data: UnsafeMutableRawPointer?) -> String {
        guard let it = geometry?.item(at: point) else { return "" }
        return WindowText.describe(it.rec)
    }

    override func mouseUp(with event: NSEvent) {
        guard let onClick else { return super.mouseUp(with: event) }
        enclosingMenuItem?.menu?.cancelTracking()
        onClick()
    }
}

enum WindowText {
    static func describe(_ r: WindowRecord) -> String {
        var s = r.appName
        if !r.title.isEmpty && r.title != r.appName { s += " — \(r.title)" }
        s += "\n\(Int(r.rel.w))×\(Int(r.rel.h)) at \(Int(r.rel.x)),\(Int(r.rel.y))"
        if let d = r.desktop { s += " · Desktop \(d)" }
        if r.minimized { s += " · minimized" }
        if r.stale == true { s += " · app not running (remembered)" }
        return s
    }
}

/// A grid of per-desktop thumbnails with captions; used in the menu.
final class DesktopGridView: NSView {
    /// Width of the thumbnail area; the columns share it, so the menu is the same width for any number of desktops.
    static let contentWidth: CGFloat = 416
    static let gap: CGFloat = 10
    static let caption: CGFloat = 16
    static let margin: CGFloat = 14

    init(layout: Layout, onSelect: @escaping (DesktopFilter) -> Void) {
        let filters = DesktopFilter.present(in: layout, includeRemembered: false)
        let union = layout.displays.reduce(CGRect.null) { $0.union($1.frame.cg) }
        let aspect = union.isNull || union.width == 0 ? 0.5 : min(max(union.height / union.width, 0.3), 0.8)
        // 1-3 desktops in one row, 4 as 2x2, more in rows of three: no orphan thumbnail on its own row.
        let cols = filters.count <= 3 ? max(filters.count, 2) : (filters.count == 4 ? 2 : 3)
        let thumbW = ((Self.contentWidth - CGFloat(cols - 1) * Self.gap) / CGFloat(cols)).rounded(.down)
        let thumbH = (thumbW * aspect).rounded()
        let rows = (filters.count + cols - 1) / cols
        let height = CGFloat(rows) * (thumbH + Self.caption + Self.gap) + 4
        super.init(frame: NSRect(x: 0, y: 0, width: Self.margin * 2 + Self.contentWidth, height: height))
        let onScreen = Set(PrivateAPI.visibleSpaces.compactMap(PrivateAPI.desktopNumber(of:)))

        for (i, f) in filters.enumerated() {
            let col = i % cols, row = i / cols
            let x = Self.margin + CGFloat(col) * (thumbW + Self.gap)
            var current = false
            if case .desktop(let n) = f { current = onScreen.contains(n) }
            let yTop = CGFloat(row) * (thumbH + Self.caption + Self.gap) + 4
            let map = LayoutMapView(frame: NSRect(x: x, y: height - yTop - thumbH, width: thumbW, height: thumbH))
            map.showLabels = false
            map.highlighted = current
            map.showRemembered = false
            map.layout = layout
            map.filter = f
            map.onClick = { onSelect(f) }
            map.toolTip = Self.tooltip(layout, f)
            addSubview(map)

            let n = layout.open.filter { f.includes($0) }.count
            let cap = NSTextField(labelWithString: "\(f.title) · \(n) window\(n == 1 ? "" : "s")")
            cap.font = .systemFont(ofSize: 11, weight: current ? .semibold : .regular)
            cap.textColor = current ? .labelColor : .secondaryLabelColor
            cap.alignment = .center
            cap.frame = NSRect(x: x, y: height - yTop - thumbH - Self.caption, width: thumbW, height: Self.caption - 2)
            addSubview(cap)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func tooltip(_ layout: Layout, _ f: DesktopFilter) -> String {
        let names = layout.open.filter { f.includes($0) }.map(\.appName)
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }.joined(separator: ", ") + "\nClick to see this desktop in the Layouts window"
    }
}
