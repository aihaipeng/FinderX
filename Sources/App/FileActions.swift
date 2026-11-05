import Cocoa

enum FileActions {
    static func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "FinderX"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    static func registry(addDestination: @escaping () -> Void, settings: @escaping () -> Void) -> BuiltinRegistry {
        let registry = BuiltinRegistry()
        registry.register("app.add-destination") { targets, _ in
            DispatchQueue.main.sync(execute: addDestination)
            return JobResult(targets: targets.map(\.path), status: .succeeded)
        }
        registry.register("app.settings") { targets, _ in
            DispatchQueue.main.sync(execute: settings)
            return JobResult(targets: targets.map(\.path), status: .succeeded)
        }
        return registry
    }
}
