import Foundation

/// File-based control channel so the CLI can drive the (accessibility-trusted) daemon from any terminal.
/// CLI drops `<id>.json` into cmd/, signals SIGUSR1, and waits for `<id>.out`.
struct Command: Codable {
    var id: String
    var name: String
    var args: [String]
}

enum Commands {
    static let dir = Store.dir.appendingPathComponent("cmd", isDirectory: true)

    static func send(_ name: String, _ args: [String], to pid: pid_t, timeout: TimeInterval = 45) -> String? {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let cmd = Command(id: id, name: name, args: args)
        let url = dir.appendingPathComponent("\(id).json")
        let out = dir.appendingPathComponent("\(id).out")
        guard let data = try? JSONEncoder().encode(cmd), (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        kill(pid, SIGUSR1)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let s = try? String(contentsOf: out, encoding: .utf8) {
                try? FileManager.default.removeItem(at: out)
                return s
            }
            usleep(100_000)
        }
        try? FileManager.default.removeItem(at: url)
        return nil
    }

    /// Remove requests and replies nobody is waiting for any more (a CLI that gave up, a crash).
    static func sweep() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for u in urls {
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(m) > 120 { try? FileManager.default.removeItem(at: u) }
        }
    }

    static func pending() -> [Command] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                defer { try? FileManager.default.removeItem(at: url) }
                return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Command.self, from: $0) }
            }
    }

    static func reply(_ cmd: Command, _ text: String) {
        try? text.write(to: dir.appendingPathComponent("\(cmd.id).out"), atomically: true, encoding: .utf8)
    }
}
