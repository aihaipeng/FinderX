import Cocoa

enum BackgroundLaunch {
    static func configuration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        return configuration
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url, configuration: configuration()) { _, error in
            if let error { NSLog("FinderX background launch: %@", error.localizedDescription) }
        }
    }
}
