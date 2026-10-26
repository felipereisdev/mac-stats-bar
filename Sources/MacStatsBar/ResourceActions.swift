import AppKit
import MacStatsBarCore

@MainActor
enum ResourceActions {
    static func confirm(title: String, message: String, action: String, destructive: Bool = true) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action).hasDestructiveAction = destructive
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func quit(_ application: ObservedApplication) async throws -> Bool {
        let identity = application.descriptor.mainProcess
        guard identity.ownerUID == getuid(), identity.pid != getpid(), identity.isCurrent,
              let app = NSRunningApplication(processIdentifier: identity.pid),
              app.activationPolicy == .regular, app.bundleURL?.path == application.descriptor.bundlePath,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != identity.pid,
              !application.descriptor.bundlePath.hasPrefix("/System/") else { throw DockerError.resourceChanged }
        // Request normal application termination; never signal a generic executable group.
        guard app.terminate() else { return false }
        for _ in 0..<30 {
            if app.isTerminated || !identity.isCurrent { return true }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }
}
