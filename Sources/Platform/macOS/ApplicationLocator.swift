import Cocoa

enum ApplicationLocator {
    static func exists(_ identifier: String) -> Bool {
        if identifier.hasPrefix("/") { return Bundle(url: URL(fileURLWithPath: identifier))?.executableURL != nil }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) != nil { return true }
        let name = identifier.hasSuffix(".app") ? identifier : identifier + ".app"
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        return roots.contains { Bundle(url: URL(fileURLWithPath: $0).appendingPathComponent(name))?.executableURL != nil }
    }
}

extension DependencyAvailability {
    static func write(directory: URL, snapshot: ConfigurationSnapshot) throws {
        let builder = PlanBuilder(home: FileManager.default.homeDirectoryForCurrentUser.path, applicationExists: ApplicationLocator.exists)
        var reasons: [String: String] = [:]
        for action in snapshot.configuration.actions where action.execution.type == .command {
            do { try builder.checkDependencies(action.execution) }
            catch { reasons[action.id] = error.localizedDescription }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(Self(revision: snapshot.revision, reasons: reasons))
        let url = directory.appendingPathComponent("availability.json")
        if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
    }
}
