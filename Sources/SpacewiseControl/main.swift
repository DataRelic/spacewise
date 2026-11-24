import AppKit
import Foundation

// Development helper for scripts/tool.py. `status` prints the running Spacewise processes as JSON; `quit` asks each
// copy running from the canonical ~/Applications path to terminate (normal termination only, never forced).

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data(("SpacewiseControl: " + message + "\n").utf8))
    exit(code)
}

let usage = "usage: SpacewiseControl status | quit"
let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 1, let command = arguments.first else { fail(usage, code: 64) }

let target = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Spacewise.app")
    .standardizedFileURL
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "local.spacewise.app")
func isCanonical(_ app: NSRunningApplication) -> Bool { app.bundleURL?.standardizedFileURL == target }

switch command {
case "quit":
    for app in apps where isCanonical(app) && !app.terminate() {
        fail("terminate request refused or not delivered for pid \(app.processIdentifier)", code: 2)
    }
case "status":
    let records = apps.map { app in
        [
            "pid": String(app.processIdentifier), "exact": isCanonical(app) ? "true" : "false",
            "terminated": app.isTerminated ? "true" : "false",
        ]
    }
    do {
        let data = try JSONSerialization.data(withJSONObject: records)
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    } catch {
        fail("could not encode \(records.count) process records as JSON: \(error)", code: 1)
    }
default:
    fail("unknown command '\(command)'; \(usage)", code: 64)
}
