import Foundation

enum Store {
    static let dir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LayoutKeeper", isDirectory: true)
    static let layoutsDir = dir.appendingPathComponent("layouts", isDirectory: true)
    static let configURL = dir.appendingPathComponent("config.json")

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func ensureDirs() {
        try? FileManager.default.createDirectory(at: layoutsDir, withIntermediateDirectories: true)
    }

    static func config() -> Config {
        ensureDirs()
        guard let data = try? Data(contentsOf: configURL) else {
            let c = Config()
            if let data = try? encoder.encode(c) { try? data.write(to: configURL, options: .atomic) }
            return c
        }
        do { return try decoder.decode(Config.self, from: data) } catch {
            // A typo in a hand-edited file must not wipe the user's settings: use defaults, leave the file alone.
            if badConfigLogged != data { badConfigLogged = data; Log.error("config.json is not valid (\(error.localizedDescription)); using defaults until it is fixed") }
            return Config()
        }
    }

    private static var badConfigLogged: Data?

    static func writeConfig(_ c: Config) throws {
        ensureDirs()
        try encoder.encode(c).write(to: configURL, options: .atomic)
    }

    static func configModified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: configURL.path))?[.modificationDate] as? Date
    }

    /// Set one key from a CLI string, validating the type by round-tripping through `Config`.
    static func setConfig(key: String, value: String) throws -> Config {
        var dict = (try? JSONSerialization.jsonObject(with: Data(contentsOf: configURL))) as? [String: Any] ?? [:]
        guard let doc = ConfigDocs.entries.first(where: { $0.key == key }) else {
            throw NSError(domain: "layoutkeeper", code: 1, userInfo: [NSLocalizedDescriptionKey: "unknown key '\(key)'. Run `layoutkeeper config` to list keys."])
        }
        switch doc.type {
        case "bool":
            guard let b = ["true": true, "yes": true, "on": true, "1": true, "false": false, "no": false, "off": false, "0": false][value.lowercased()] else {
                throw NSError(domain: "layoutkeeper", code: 1, userInfo: [NSLocalizedDescriptionKey: "'\(key)' expects true/false"])
            }
            dict[key] = b
        case "number":
            guard let n = Double(value), n > 0 else { throw NSError(domain: "layoutkeeper", code: 1, userInfo: [NSLocalizedDescriptionKey: "'\(key)' expects a positive number"]) }
            dict[key] = key == "autosaveEveryTicks" ? Int(n) as Any : n
        default:
            dict[key] = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        let parsed = try decoder.decode(Config.self, from: data)
        try writeConfig(parsed)
        return parsed
    }

    static func url(for fingerprint: String) -> URL { layoutsDir.appendingPathComponent("\(fingerprint).json") }

    static func load(_ fingerprint: String) -> LayoutFile? {
        let u = url(for: fingerprint)
        guard let data = try? Data(contentsOf: u) else { return nil }
        do { return try decoder.decode(LayoutFile.self, from: data) } catch {
            // Keep the unreadable file for inspection instead of silently overwriting it on the next save.
            let aside = layoutsDir.appendingPathComponent("\(fingerprint).unreadable-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: u, to: aside)
            Log.error("layout file \(fingerprint).json could not be read (\(error.localizedDescription)); moved to \(aside.lastPathComponent)")
            return nil
        }
    }

    static func save(_ file: LayoutFile) throws {
        ensureDirs()
        let data = try encoder.encode(file)
        try data.write(to: url(for: file.fingerprint), options: .atomic)
    }

    static func delete(_ fingerprint: String) { try? FileManager.default.removeItem(at: url(for: fingerprint)) }

    static func list() -> [LayoutFile] {
        ensureDirs()
        let urls = (try? FileManager.default.contentsOfDirectory(at: layoutsDir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { load($0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.label < $1.label }
    }

    /// Store `layout` into the pinned or auto slot of its fingerprint's file.
    static func put(_ layout: Layout, pinned: Bool) throws {
        var file = load(layout.fingerprint) ?? LayoutFile(fingerprint: layout.fingerprint, label: layout.label, displays: layout.displays)
        file.label = layout.label
        file.displays = layout.displays
        file.schema = LayoutFile.currentSchema
        if pinned { file.pinned = layout } else { file.auto = layout }
        try save(file)
    }

    /// For a monitor set with nothing saved yet: the saved layout that shares the most displays with it, cut down
    /// to the windows on those displays. Better than leaving windows wherever macOS dropped them.
    static func borrowed(for displays: [DisplayInfo], pinnedFirst: Bool) -> (layout: Layout, from: String)? {
        let keys = Set(displays.map(\.key))
        let fp = Displays.fingerprint(displays)
        var best: (layout: Layout, from: String, shared: Int)?
        for f in list() where f.fingerprint != fp {
            guard let l = f.preferred(pinnedFirst: pinnedFirst)?.layout else { continue }
            let shared = Set(l.displays.map(\.key)).intersection(keys).count
            guard shared > 0 else { continue }
            if best == nil || shared > best!.shared || (shared == best!.shared && l.savedAt > best!.layout.savedAt) { best = (l, f.label, shared) }
        }
        guard var l = best?.layout, let from = best?.from else { return nil }
        l.windows = l.windows.filter { keys.contains($0.displayKey) }
        l.fingerprint = fp
        l.label = Displays.label(displays)
        l.displays = displays
        l.desktops = nil
        return l.open.isEmpty ? nil : (l, from)
    }

    /// One-time clean-up of files written by older versions (see `Layout.tidied`).
    static func tidyAll() {
        for var f in list() where (f.schema ?? 1) < LayoutFile.currentSchema {
            let before = (f.pinned?.windows.count ?? 0) + (f.auto?.windows.count ?? 0)
            f.pinned = f.pinned?.tidied(deep: true)
            f.auto = f.auto?.tidied(deep: true)
            f.schema = LayoutFile.currentSchema
            let after = (f.pinned?.windows.count ?? 0) + (f.auto?.windows.count ?? 0)
            do { try save(f); Log.info("cleaned up \(f.label) [\(f.fingerprint)]: \(before) -> \(after) saved windows") }
            catch { Log.error("clean-up of \(f.fingerprint) failed: \(error.localizedDescription)") }
        }
    }

    /// Delete sets saved while no real display was on (older versions recorded sleep as a monitor set).
    static func removeEmptySets() {
        for f in list() where (f.pinned?.windows.isEmpty ?? true) && (f.auto?.windows.isEmpty ?? true) {
            Log.info("removing empty layout file \(f.fingerprint)")
            delete(f.fingerprint)
        }
    }

    static func encodeJSON<T: Encodable>(_ v: T) -> String {
        (try? encoder.encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
