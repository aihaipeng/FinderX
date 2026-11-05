import Foundation

struct DependencyAvailability: Codable {
    let revision: String
    let reasons: [String: String]

    static func read(directory: URL, snapshot: ConfigurationSnapshot) -> [String: String] {
        if let data = try? Data(contentsOf: directory.appendingPathComponent("availability.json")),
           let cache = try? JSONDecoder().decode(Self.self, from: data), cache.revision == snapshot.revision { return cache.reasons }
        return Dictionary(uniqueKeysWithValues: snapshot.configuration.actions.filter { $0.execution.type == .command }.map {
            ($0.id, "请等待主程序检查脚本依赖，稍后重新打开菜单。")
        })
    }
}
