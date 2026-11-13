// Tiny launcher that never changes, so the macOS Accessibility grant (tied to this binary's
// signature) survives rebuilds of the real `layoutkeeper` binary. Children inherit the grant.
import Foundation

let real = ProcessInfo.processInfo.environment["LAYOUTKEEPER_BIN"]
    ?? NSHomeDirectory() + "/.local/libexec/layoutkeeper/layoutkeeper"
var child: Process?

signal(SIGTERM) { _ in child?.terminate(); exit(0) }
signal(SIGINT) { _ in child?.terminate(); exit(0) }
signal(SIGUSR1, SIG_IGN)
signal(SIGUSR2, SIG_IGN)

while true {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: real)
    p.arguments = ["watch"]
    p.standardOutput = FileHandle.standardOutput
    p.standardError = FileHandle.standardError
    do {
        try p.run()
        child = p
        p.waitUntilExit()
        FileHandle.standardError.write("LayoutKeeperAgent: layoutkeeper exited (\(p.terminationStatus)); restarting in 5s\n".data(using: .utf8)!)
    } catch {
        FileHandle.standardError.write("LayoutKeeperAgent: cannot start \(real): \(error)\n".data(using: .utf8)!)
    }
    sleep(5)
}
