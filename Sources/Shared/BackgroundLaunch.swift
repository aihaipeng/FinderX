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
            guard let error else { return }
            NSLog("FinderX background launch: %@", error.localizedDescription)
            let message = "未能启动操作：\(error.localizedDescription)。请打开 FinderX 检查。"
            try? message.write(to: SharedConfig.submissionErrorURLForExtension, atomically: true, encoding: .utf8)
        }
    }
}
