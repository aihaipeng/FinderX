import Foundation
import CryptoKit

enum ConfigurationCodec {
    static func encode(_ configuration: FrameworkConfiguration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(configuration)
    }

    static func snapshot(_ configuration: FrameworkConfiguration) throws -> ConfigurationSnapshot {
        let data = try encode(configuration)
        return ConfigurationSnapshot(configuration: configuration,
            revision: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    static func decode(_ data: Data) throws -> FrameworkConfiguration {
        guard data.count <= 2_097_152 else { throw invalid("$", "配置超过 2 MiB。") }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            try keys(object, ["schemaVersion", "actions", "menu"], "$")
            if let root = object as? [String: Any] {
                for (index, item) in (root["actions"] as? [Any] ?? []).enumerated() {
                    let path = "actions[\(index)]"
                    try keys(item, ["id", "title", "icon", "enabled", "when", "batch", "onError", "execution"], path)
                    if let item = item as? [String: Any] {
                        if let when = item["when"] { try keys(when, ["surfaces", "kinds", "minCount", "maxCount", "extensions"], path + ".when") }
                        if let execution = item["execution"] {
                            let definition = execution as? [String: Any] ?? [:]
                            let allowed: Set<String> = definition["type"] as? String == "builtin"
                                ? ["type", "operation", "parameters"]
                                : ["type", "executable", "arguments", "workingDirectory", "environment", "stdin", "timeoutSeconds", "successExitCodes", "requirements"]
                            try keys(execution, allowed, path + ".execution")
                            if let requirements = definition["requirements"] { try keys(requirements, ["applications", "paths"], path + ".execution.requirements") }
                            if let input = definition["stdin"] {
                                try keys(input, (input as? [String: Any])?["source"] as? String == "paths"
                                    ? ["source", "separator", "trailingSeparator"] : ["source", "value"], path + ".execution.stdin")
                            }
                        }
                    }
                }
                func menu(_ items: [Any], _ path: String, _ depth: Int) throws {
                    guard depth <= 4 else { throw invalid(path, "菜单最多 4 层。") }
                    for (index, item) in items.enumerated() {
                        let field = "\(path)[\(index)]"
                        let dictionary = item as? [String: Any] ?? [:]
                        let kind = dictionary["type"] as? String
                        try keys(item, kind == "group" ? ["type", "id", "title", "icon", "children", "showWhenEmpty"]
                            : kind == "action" ? ["type", "id", "actionID", "title", "icon"] : ["type", "id"], field)
                        if let children = dictionary["children"] as? [Any], !children.isEmpty { try menu(children, field + ".children", depth + 1) }
                    }
                }
                try menu(root["menu"] as? [Any] ?? [], "menu", 1)
            }
            let configuration = try JSONDecoder().decode(FrameworkConfiguration.self, from: data)
            try validate(configuration)
            return configuration
        } catch let error as FrameworkError { throw error }
        catch let DecodingError.keyNotFound(key, context) { throw invalid(location(context.codingPath + [key]), "缺少字段。") }
        catch let DecodingError.typeMismatch(_, context) { throw invalid(location(context.codingPath), "字段类型不正确。") }
        catch let DecodingError.valueNotFound(_, context) { throw invalid(location(context.codingPath), "字段不能为空。") }
        catch let DecodingError.dataCorrupted(context) { throw invalid(location(context.codingPath), "字段值无效：\(context.debugDescription)") }
        catch { throw invalid("$", error.localizedDescription) }
    }

    static func validate(_ configuration: FrameworkConfiguration) throws {
        guard configuration.schemaVersion == 1 else { throw invalid("schemaVersion", "仅支持版本 1，请勿覆盖新版本配置。") }
        guard configuration.actions.count <= 256 else { throw invalid("actions", "最多 256 个动作。") }
        var ids = Set<String>()
        for (index, action) in configuration.actions.enumerated() {
            let path = "actions[\(index)]"
            guard !action.id.isEmpty, action.id.count <= 128, ids.insert(action.id).inserted else { throw invalid(path + ".id", "ID 为空、过长或重复。") }
            guard !action.title.isEmpty else { throw invalid(path + ".title", "名称不能为空。") }
            guard !action.when.surfaces.isEmpty, !action.when.kinds.isEmpty, (action.when.minCount ?? 1) >= 1,
                  (action.when.maxCount ?? Int.max) >= (action.when.minCount ?? 1) else { throw invalid(path + ".when", "适用入口、类型或数量条件无效。") }
            if let extensions = action.when.extensions {
                guard !extensions.isEmpty, action.when.kinds == [.file], extensions.allSatisfy({ !$0.isEmpty && !$0.contains(".") && !$0.contains("/") }) else {
                    throw invalid(path + ".when.extensions", "扩展名不带点，仅适用于文件。")
                }
            }
            if action.errorPolicy == .continue && action.batchMode != .each { throw invalid(path + ".onError", "continue 仅用于 each。") }
            func template(_ text: String, _ field: String, list: Bool = false, stable: Bool = false) throws {
                do {
                    guard !text.utf8.contains(0) else { throw invalid(field, "不能包含 NUL。") }
                    let names = try Template.names(in: text)
                    if names.contains("paths") && (!list || text != "{paths}") { throw invalid(field, "{paths} 必须是完整参数元素。") }
                    if stable && names.contains(where: { $0 != "home" }) { throw invalid(field, "此字段只允许 {home} 变量。") }
                    if action.batchMode == .all && action.when.maxCount != 1 && !Set(names).isDisjoint(with: ["path", "name", "parent"]) {
                        throw invalid(field, "all 多选不能使用单目标变量，请使用 each 或限制 maxCount=1。")
                    }
                } catch let error as FrameworkError {
                    if error.message.hasPrefix(field + ":") { throw error }
                    throw invalid(field, error.message)
                }
            }
            func absolute(_ text: String, _ field: String, stable: Bool = false) throws {
                try template(text, field, stable: stable)
                guard text.hasPrefix("/") || text.hasPrefix("{home}/") || text == "{home}" ||
                    (!stable && ["{path}", "{parent}", "{container}"].contains(where: { text.hasPrefix($0) })) else { throw invalid(field, "需要绝对路径或路径变量。") }
            }
            let ex = action.execution
            let field = path + ".execution"
            if ex.type == .command {
                guard let executable = ex.executable, let arguments = ex.arguments else { throw invalid(field, "缺少 executable 或 arguments。") }
                try absolute(executable, field + ".executable", stable: true)
                for (i, argument) in arguments.enumerated() { try template(argument, field + ".arguments[\(i)]", list: true) }
                if let directory = ex.workingDirectory { try absolute(directory, field + ".workingDirectory") }
                for (key, value) in ex.environment ?? [:] {
                    guard !key.isEmpty, !key.contains("="), !key.utf8.contains(0) else { throw invalid(field + ".environment", "环境变量名无效。") }
                    try template(value, field + ".environment." + key)
                }
                guard (1...600).contains(ex.timeoutSeconds ?? 30) else { throw invalid(field + ".timeoutSeconds", "范围为 1–600。") }
                if let codes = ex.successExitCodes, codes.isEmpty || codes.contains(where: { $0 < 0 || $0 > 255 }) { throw invalid(field + ".successExitCodes", "需要非空的 0–255 退出码数组。") }
                if let input = ex.stdin {
                    if input.source == "text", let value = input.value { try template(value, field + ".stdin.value") }
                    else if input.source == "paths" { guard ["\n", "\0"].contains(input.separator ?? "\n") else { throw invalid(field + ".stdin.separator", "仅支持换行或 NUL。") } }
                    else { throw invalid(field + ".stdin", "需要 text/value 或 paths 来源。") }
                }
                for (i, dependency) in (ex.requirements?.paths ?? []).enumerated() { try absolute(dependency, field + ".requirements.paths[\(i)]", stable: true) }
                for (i, application) in (ex.requirements?.applications ?? []).enumerated() {
                    guard !application.isEmpty else { throw invalid(field + ".requirements.applications[\(i)]", "应用名称不能为空。") }
                    try template(application, field + ".requirements.applications[\(i)]", stable: true)
                }
            } else {
                guard let operation = ex.operation, let parameters = ex.parameters else { throw invalid(field, "缺少 operation 或 parameters。") }
                switch operation {
                case "app.add-destination", "app.settings":
                    guard parameters.isEmpty, action.batchMode == .all else { throw invalid(field, "界面操作需要 all 和空参数。") }
                default: throw invalid(field + ".operation", "未知内置操作：\(operation)")
                }
            }
        }
        var menuIDs = Set<String>()
        func menu(_ nodes: [MenuDefinition], _ depth: Int, _ path: String) throws {
            guard nodes.isEmpty || depth <= 4 else { throw invalid(path, "菜单深度最多为 4。") }
            for (index, node) in nodes.enumerated() {
                let field = "\(path)[\(index)]"
                guard !node.id.isEmpty, menuIDs.insert(node.id).inserted, menuIDs.count <= 512 else { throw invalid(field + ".id", "菜单 ID 为空、重复或节点超过 512。") }
                if node.type != .group && node.showWhenEmpty != nil { throw invalid(field + ".showWhenEmpty", "仅分组支持 showWhenEmpty。") }
                switch node.type {
                case .group:
                    guard let title = node.title, !title.isEmpty, let children = node.children else { throw invalid(field, "分组需要名称和 children。") }
                    try menu(children, depth + 1, field + ".children")
                case .action:
                    guard let id = node.actionID, ids.contains(id) else { throw invalid(field + ".actionID", "引用的动作不存在。") }
                case .separator: break
                }
            }
        }
        try menu(configuration.menu, 1, "menu")
    }

    private static func keys(_ value: Any, _ allowed: Set<String>, _ path: String) throws {
        guard let dictionary = value as? [String: Any] else { throw invalid(path, "需要对象。") }
        if let key = dictionary.keys.sorted().first(where: { !allowed.contains($0) }) { throw invalid(path + "." + key, "未知字段。") }
    }
    private static func location(_ keys: [CodingKey]) -> String {
        keys.reduce("") { result, key in
            result + (key.intValue.map { "[\($0)]" } ?? ((result.isEmpty ? "" : ".") + key.stringValue))
        }
    }
    private static func invalid(_ field: String, _ message: String) -> FrameworkError { FrameworkError(code: "config.invalid", message: "\(field): \(message)") }
}

final class ConfigurationRepository {
    let url: URL
    private let home: String
    private let writable: Bool
    private(set) var snapshot: ConfigurationSnapshot?
    private(set) var lastError: Error?
    var lastGoodURL: URL { url.deletingLastPathComponent().appendingPathComponent("config.last-good.json") }

    init(url: URL, home: String, writable: Bool) { self.url = url; self.home = home; self.writable = writable }

    @discardableResult func load() throws -> ConfigurationSnapshot {
        do {
            var configuration: FrameworkConfiguration
            if !FileManager.default.fileExists(atPath: url.path) {
                if FileManager.default.fileExists(atPath: lastGoodURL.path) { throw FrameworkError(code: "config.missing", message: "配置文件缺失，已恢复上次有效快照；请恢复或编辑 config.json。") }
                guard writable else { throw FrameworkError(code: "config.missing", message: "请先打开 FinderX 初始化配置。") }
                configuration = DefaultConfiguration.make(home: home)
                try save(configuration)
            } else {
                let data = try Data(contentsOf: url)
                guard data.count <= 2_097_152 else { throw FrameworkError(code: "config.invalid", message: "配置超过 2 MiB。") }
                if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["schemaVersion"] == nil {
                    guard writable, Set(root.keys) == ["destinations"], let items = root["destinations"] as? [[String: String]],
                          items.allSatisfy({ Set($0.keys) == ["name", "path"] && ($0["path"]?.hasPrefix("/") ?? false) }) else {
                        throw FrameworkError(code: "config.invalid", message: "旧配置格式无效，或需要主程序完成迁移。")
                    }
                    configuration = DefaultConfiguration.make(home: home, destinations: items.map { Destination(name: $0["name"]!, path: $0["path"]!) })
                    let backup = url.appendingPathExtension("legacy-backup")
                    if !FileManager.default.fileExists(atPath: backup.path) { try data.write(to: backup, options: .atomic) }
                    try save(configuration)
                } else { configuration = try ConfigurationCodec.decode(data) }
            }
            let migration = url.deletingLastPathComponent().appendingPathComponent("config.copy-to-migrated")
            if writable && !FileManager.default.fileExists(atPath: migration.path) {
                if !configuration.actions.contains(where: { $0.id == DefaultConfiguration.copyToAction.id }) {
                    let upgraded = DefaultConfiguration.addingCopyTo(configuration)
                    try ConfigurationCodec.validate(upgraded)
                    let backup = url.deletingLastPathComponent().appendingPathComponent("config.before-copy-to.json")
                    if !FileManager.default.fileExists(atPath: backup.path) {
                        try Data(contentsOf: url).write(to: backup, options: .withoutOverwriting)
                    }
                    try save(upgraded)
                    configuration = upgraded
                }
                try Data().write(to: migration, options: .atomic)
            }
            let openWithMigration = url.deletingLastPathComponent().appendingPathComponent("config.open-with-migrated")
            if writable && !FileManager.default.fileExists(atPath: openWithMigration.path) {
                if !DefaultConfiguration.hasOpenWith(configuration) {
                    let upgraded = DefaultConfiguration.addingOpenWith(configuration)
                    try ConfigurationCodec.validate(upgraded)
                    try save(upgraded)
                    configuration = upgraded
                }
                try Data().write(to: openWithMigration, options: .atomic)
            }
            let loaded = try ConfigurationCodec.snapshot(configuration)
            let changed = snapshot?.revision != loaded.revision
            snapshot = loaded
            lastError = nil
            if writable && (changed || !FileManager.default.fileExists(atPath: lastGoodURL.path)) {
                do { try ConfigurationCodec.encode(configuration).write(to: lastGoodURL, options: .atomic) }
                catch { lastError = FrameworkError(code: "config.backupFailed", message: "配置已载入，但更新备份失败：\(error.localizedDescription)") }
            }
            return loaded
        } catch {
            lastError = error
            if let snapshot { return snapshot }
            if let data = try? Data(contentsOf: lastGoodURL), let config = try? ConfigurationCodec.decode(data), let recovered = try? ConfigurationCodec.snapshot(config) {
                snapshot = recovered
                return recovered
            }
            throw error
        }
    }

    func save(_ configuration: FrameworkConfiguration) throws {
        guard writable else { throw FrameworkError(code: "config.readOnly", message: "扩展不能修改配置。") }
        let data = try ConfigurationCodec.encode(configuration)
        _ = try ConfigurationCodec.decode(data)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        snapshot = try ConfigurationCodec.snapshot(configuration)
        lastError = nil
        do { try data.write(to: lastGoodURL, options: .atomic) }
        catch { lastError = FrameworkError(code: "config.backupFailed", message: "配置已保存，但更新备份失败：\(error.localizedDescription)") }
    }
}
