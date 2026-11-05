import Foundation

enum SharedConfig {
    static let extensionBundleID = "com.finderx.app.finder"
    static var legacyDirectoryForHost: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Containers/com.superright.app.finder/Data/Library/Application Support/SuperRight", isDirectory: true)
    }
    static var directoryForExtension: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FinderX", isDirectory: true)
    }
    // A distribution build can replace these URLs with an entitled App Group.
    static var directoryForHost: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Containers/\(extensionBundleID)/Data/Library/Application Support/FinderX", isDirectory: true)
    }
    static var configURLForExtension: URL { directoryForExtension.appendingPathComponent("config.json") }
    static var configURLForHost: URL { directoryForHost.appendingPathComponent("config.json") }
    static func displayName(for url: URL) -> String { FileManager.default.displayName(atPath: url.path) }
}
