import Foundation

enum Log {
    static var verbose = false
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func info(_ s: String) { write("INFO ", s) }
    static func warn(_ s: String) { write("WARN ", s) }
    static func error(_ s: String) { write("ERROR", s) }
    static func debug(_ s: String) { if verbose { write("DEBUG", s) } }

    /// launchd appends our stderr to the log file forever; keep the last part when it gets large.
    static func trim(_ url: URL, over limit: Int = 4_000_000, keep: Int = 1_000_000) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > limit,
              let h = try? FileHandle(forUpdating: url) else { return }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: UInt64(size - keep))) != nil, var tail = try? h.readToEnd() else { return }
        if let nl = tail.firstIndex(of: 0x0A) { tail = tail.suffix(from: tail.index(after: nl)) }
        try? h.truncate(atOffset: 0)   // same inode, so the daemon's append-mode stderr keeps working
        try? h.seek(toOffset: 0)
        try? h.write(contentsOf: tail)
    }

    private static func write(_ level: String, _ s: String) {
        let line = "\(fmt.string(from: Date())) [\(level)] \(s)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }
}
