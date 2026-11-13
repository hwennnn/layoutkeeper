import Foundation

/// Human-readable documentation for every config key; used by `layoutkeeper config` and the README.
enum ConfigDocs {
    struct Entry { let key: String; let type: String; let help: String }
    static let entries: [Entry] = [
        Entry(key: "restoreOnDisplayChange", type: "bool", help: "Restore the layout when the set of connected monitors changes or the Mac wakes up."),
        Entry(key: "restoreDesktops", type: "bool", help: "Put desktops (Spaces) back on the monitor they belong to when monitors change; macOS piles them onto one display."),
        Entry(key: "autosave", type: "bool", help: "Continuously remember the current layout per monitor set (\"how I left it\")."),
        Entry(key: "placeOnLaunch", type: "bool", help: "When an app opens (or shows its first window again), move its windows to where they were."),
        Entry(key: "launchMissingApps", type: "bool", help: "On restore, open apps that are part of the layout but not running."),
        Entry(key: "moveWindowsToDesktops", type: "bool", help: "On restore, send an app's windows back to the desktop (Space) they were saved on."),
        Entry(key: "preferPinned", type: "bool", help: "Restore the pinned layout instead of how the windows were last left."),
        Entry(key: "menuBarIcon", type: "bool", help: "Show the LayoutKeeper menu bar item."),
        Entry(key: "pollSeconds", type: "number", help: "Seconds between checks for new windows / config changes."),
        Entry(key: "autosaveEveryTicks", type: "number", help: "Autosave runs every N polls (default 3 → every 15s) once windows have been still for two polls."),
        Entry(key: "debounceSeconds", type: "number", help: "Wait this long after a display event before restoring, so macOS finishes its own shuffling."),
        Entry(key: "ignoreBundleIDs", type: "list", help: "Bundle ids never captured or moved (comma-separated when set from the CLI)."),
    ]

    static func help() -> String {
        var s = "Config file: \(Store.configURL.path)\n\n"
        for e in entries { s += "  \(e.key.padding(toLength: 24, withPad: " ", startingAt: 0)) \(e.type.padding(toLength: 7, withPad: " ", startingAt: 0)) \(e.help)\n" }
        s += "\nCommands: config | config get <key> | config set <key> <value> | config edit | config reset | config path\n"
        s += "The daemon reloads the file automatically within a few seconds."
        return s
    }
}
