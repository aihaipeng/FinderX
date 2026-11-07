import Cocoa

struct ScriptLibrary {
    static func shellLiteral(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let directory: URL
    var scripts: URL { directory.appendingPathComponent("Scripts", isDirectory: true) }

    func migrateLegacy(from legacy: URL) throws {
        let manager = FileManager.default
        let config = directory.appendingPathComponent("config.json")
        let source = legacy.appendingPathComponent("config.json")
        guard !manager.fileExists(atPath: config.path), manager.fileExists(atPath: source.path) else { return }
        let original = try Data(contentsOf: source)
        let oldTemplate = "{home}/Library/Containers/com.superright.app.finder/Data/Library/Application Support/SuperRight"
        let newTemplate = "{home}/Library/Containers/com.finderx.app.finder/Data/Library/Application Support/FinderX"
        func rewrite(_ object: Any) -> Any {
            if let value = object as? String {
                for (old, new) in [(oldTemplate, newTemplate), (legacy.path, directory.path)] {
                    if value == old || value.hasPrefix(old + "/") { return new + value.dropFirst(old.count) }
                }
                return value
            }
            if let values = object as? [Any] { return values.map(rewrite) }
            if let values = object as? [String: Any] {
                var updated = values.mapValues(rewrite)
                if values["id"] as? String == "menu.superright" {
                    updated["id"] = "menu.finderx"
                    if values["title"] as? String == "SuperRight" { updated["title"] = "FinderX" }
                }
                return updated
            }
            return object
        }
        let mapped = try JSONSerialization.data(withJSONObject: rewrite(JSONSerialization.jsonObject(with: original)), options: [.prettyPrinted, .sortedKeys])
        let object = try JSONSerialization.jsonObject(with: mapped) as? [String: Any]
        if object?["schemaVersion"] != nil { _ = try ConfigurationCodec.decode(mapped) }
        else {
            guard let object, Set(object.keys) == ["destinations"], let destinations = object["destinations"] as? [[String: String]],
                  destinations.allSatisfy({ Set($0.keys) == ["name", "path"] && ($0["path"]?.hasPrefix("/") ?? false) }) else {
                throw FrameworkError(code: "config.invalid", message: "旧版配置无效，尚未导入 FinderX。")
            }
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let backup = directory.appendingPathComponent("config.superright-backup.json")
        if !manager.fileExists(atPath: backup.path) { try original.write(to: backup, options: .atomic) }
        let oldScripts = legacy.appendingPathComponent("Scripts")
        if let entries = manager.enumerator(atPath: oldScripts.path) {
            for case let relative as String in entries {
                let entry = oldScripts.appendingPathComponent(relative)
                let output = scripts.appendingPathComponent(relative)
                if (try entry.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
                    try manager.createDirectory(at: output, withIntermediateDirectories: true)
                } else if !manager.fileExists(atPath: output.path) {
                    try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try manager.copyItem(at: entry, to: output)
                }
            }
        }
        try mapped.write(to: config, options: .atomic)
    }

    func install(from resources: URL) throws {
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let templates = try FileManager.default.contentsOfDirectory(at: resources.appendingPathComponent("Scripts"), includingPropertiesForKeys: nil)
        for template in templates where template.pathExtension == "zsh" {
            let output = scripts.appendingPathComponent(template.lastPathComponent)
            // Existing copies belong to the user. Never overwrite edited scripts.
            if !FileManager.default.fileExists(atPath: output.path) { try FileManager.default.copyItem(at: template, to: output) }
        }
    }

    // One-time upgrade for the bundled defaults. User-edited scripts are left alone:
    // only the exact published line is replaced, and a marker prevents a second pass.
    func migrateDefaultExitCodes() throws {
        let migrations: [(name: String, marker: String, from: String, to: String)] = [
            ("copy-to.zsh", "script.copy-to-exit-codes-migrated",
             "  [[ -n \"$destination\" ]] || { print -r -- '已取消拷贝。'; exit 0; }",
             "  [[ -n \"$destination\" ]] || { print -r -- '已取消拷贝。'; exit 130; }"),
            ("move.zsh", "script.move-skip-migrated",
             "  print -r -- '已跳过：已经位于目标目录。'\n  exit 0",
             "  print -r -- '已跳过：已经位于目标目录。'\n  exit 100")
        ]
        for migration in migrations {
            let marker = directory.appendingPathComponent(migration.marker)
            guard !FileManager.default.fileExists(atPath: marker.path) else { continue }
            let script = scripts.appendingPathComponent(migration.name)
            if let content = try? String(contentsOf: script, encoding: .utf8) {
                let updated = content.replacingOccurrences(of: migration.from, with: migration.to)
                if updated != content { try updated.write(to: script, atomically: true, encoding: .utf8) }
            }
            try Data().write(to: marker, options: .atomic)
        }
    }

    func create(id: String, body: String) throws -> URL {
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let url = scripts.appendingPathComponent(id + ".zsh")
        try Data(body.utf8).write(to: url, options: .withoutOverwriting)
        let checked = ProcessRunner().run(CommandJob(executable: "/bin/zsh", arguments: ["-n", url.path],
            workingDirectory: directory.path, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], input: Data(), timeout: 5, successExitCodes: [0]))
        guard checked.status == .succeeded else {
            try? FileManager.default.removeItem(at: url)
            throw FrameworkError(code: "script.invalid", message: checked.stderr)
        }
        return url
    }
}
