import Cocoa
import UniformTypeIdentifiers

final class ConfigStore {
    let repository: ConfigurationRepository
    init(repository: ConfigurationRepository = ConfigurationRepository(url: SharedConfig.configURLForHost,
        home: FileManager.default.homeDirectoryForCurrentUser.path, writable: true)) { self.repository = repository }
    private(set) var snapshot: ConfigurationSnapshot?
    private var lastNotification = ""
    var onChange: (() -> Void)?
    var destinations: [Destination] {
        (snapshot?.configuration.actions ?? []).compactMap(DefaultConfiguration.destination)
    }

    func load() {
        do { snapshot = try repository.load() }
        catch { /* Background reloads keep repository.lastError for the settings UI. */ }
        let signature = (snapshot?.revision ?? "") + (repository.lastError?.localizedDescription ?? "")
        if signature != lastNotification { lastNotification = signature; onChange?() }
    }

    @discardableResult
    func addViaPanel() -> [String] {
        do {
            _ = try repository.load()
            if let error = blockingError(repository.lastError) { throw error }
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false
            panel.allowsMultipleSelection = true; panel.canCreateDirectories = true
            panel.prompt = "添加"; panel.message = "选择“移动到”的目标文件夹"
            guard panel.runModal() == .OK else { return [] }
            var configuration = try editableConfiguration()
            var known = Set(configuration.actions.compactMap(DefaultConfiguration.destination).map(\.path))
            var added: [String] = []
            for url in panel.urls where known.insert(url.path).inserted {
                let destination = Destination(name: SharedConfig.displayName(for: url), path: url.path)
                configuration.actions.append(DefaultConfiguration.moveAction(destination))
                if !append(DefaultConfiguration.reference(destination.id), to: "menu.move", nodes: &configuration.menu) {
                    throw FrameworkError(code: "config.invalid", message: "配置中缺少 menu.move 分组，请在配置中恢复该分组。")
                }
                added.append(destination.name)
            }
            guard !added.isEmpty else { return [] }
            try repository.save(configuration)
            snapshot = repository.snapshot
            onChange?()
            return added
        } catch {
            FileActions.showError(error)
            return []
        }
    }

    @discardableResult
    func remove(at offsets: IndexSet) -> Bool {
        let displayed = destinations
        let ids = Set(offsets.compactMap { displayed.indices.contains($0) ? displayed[$0].id : nil })
        return removeActions(ids)
    }

    private func removeActions(_ ids: Set<String>) -> Bool {
        guard !ids.isEmpty else { return false }
        do {
            var configuration = try editableConfiguration()
            guard configuration.actions.contains(where: { ids.contains($0.id) }) else { return false }
            configuration.actions.removeAll { ids.contains($0.id) }
            func prune(_ nodes: [MenuDefinition]) -> [MenuDefinition] {
                nodes.filter { !ids.contains($0.actionID ?? "") }.map { node in
                    var node = node
                    if let children = node.children { node.children = prune(children) }
                    return node
                }
            }
            configuration.menu = prune(configuration.menu)
            try repository.save(configuration)
            snapshot = repository.snapshot
            onChange?()
            return true
        } catch {
            FileActions.showError(error)
            return false
        }
    }

    @discardableResult
    func restore(_ configuration: FrameworkConfiguration) -> Bool {
        do {
            try repository.save(configuration)
            snapshot = repository.snapshot
            onChange?()
            return true
        } catch {
            FileActions.showError(error)
            return false
        }
    }

    func editConfiguration() {
        NSWorkspace.shared.open(repository.url)
    }

    func openScripts() {
        NSWorkspace.shared.open(ScriptLibrary(directory: SharedConfig.directoryForHost).scripts)
    }

    @discardableResult
    func addApplication(at app: URL) -> Bool {
        do {
            var configuration = try editableConfiguration()
            let path = app.standardizedFileURL.path
            let bundle = Bundle(url: app)
            let name = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle?.localizedInfoDictionary?["CFBundleName"] as? String)
                ?? app.deletingPathExtension().lastPathComponent
            let bundleID = bundle?.bundleIdentifier
            let fileName = app.deletingPathExtension().lastPathComponent
            let existing = openWithIdentifiers(in: configuration)
            guard !existing.contains(where: {
                $0 == path || $0 == fileName || $0 == "\(fileName).app"
                    || $0 == name || $0 == "\(name).app" || $0 == bundleID
            }) else { return false }
            let id = "open." + UUID().uuidString.lowercased()
            let body = "#!/bin/zsh\nset -euo pipefail\n/usr/bin/open -a \(ScriptLibrary.shellLiteral(path)) \"$@\"\nprintf '%s\\n' '已提交打开请求。'\n"
            let generated = try ScriptLibrary(directory: SharedConfig.directoryForHost).create(id: id, body: body)
            let script = Template.literal(generated.path)
            let action = ActionDefinition(id: id, title: name, icon: "app",
                when: MatchCondition(surfaces: [.items, .container, .sidebar], kinds: [.file, .directory]),
                execution: ExecutionDefinition(type: .command, executable: "/bin/zsh", arguments: [script, "{paths}"],
                    requirements: Requirements(applications: [Template.literal(path)], paths: [script])))
            configuration.actions.append(action)
            addReference(DefaultConfiguration.reference(id), group: "menu.open-with", title: "打开方式", configuration: &configuration)
            do { try save(configuration) }
            catch { try? FileManager.default.removeItem(at: generated); throw error }
            return true
        } catch {
            FileActions.showError(error)
            return false
        }
    }

    @discardableResult
    func removeApplication(actionID: String) -> Bool {
        removeActions([actionID])
    }

    @discardableResult
    func removeCustomScript(actionID: String) -> Bool {
        removeActions([actionID])
    }

    @discardableResult
    func addCustomScript() -> String? {
        let alert = NSAlert()
        alert.messageText = "添加自定义脚本"
        alert.informativeText = "使用 zsh 编写操作。所选文件作为独立参数传入，通过 \"$@\" 读取。按 ⌘S 保存，Esc 取消。"
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        alert.buttons.first?.keyEquivalent = "s"
        alert.buttons.first?.keyEquivalentModifierMask = [.command]
        let nameLabel = NSTextField(labelWithString: "菜单名称")
        nameLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        nameLabel.textColor = .secondaryLabelColor
        let title = NSTextField(string: "自定义操作")
        title.placeholderString = "菜单中显示的名称"
        title.setAccessibilityLabel("菜单名称")
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 260))
        text.isRichText = false; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.setAccessibilityLabel("脚本内容")
        text.string = "#!/bin/zsh\nset -euo pipefail\n\n# 示例：在 Finder 中显示所选文件。\nfor selected_path in \"$@\"; do\n  /usr/bin/open -R \"$selected_path\"\ndone\n"
        let scroll = NSScrollView(frame: text.frame)
        scroll.hasVerticalScroller = true; scroll.documentView = text
        let stack = NSStackView(views: [nameLabel, title, scroll])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 560, height: 316)
        title.widthAnchor.constraint(equalToConstant: 560).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 560).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 260).isActive = true
        alert.accessoryView = stack
        NSApp.activate(ignoringOtherApps: true)
        var scriptName = ""
        var focus: NSView = title
        while true {
            alert.window.initialFirstResponder = focus
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            scriptName = title.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if scriptName.isEmpty {
                focus = title
                showCustomScriptWarning("菜单名称不能为空。")
                continue
            }
            if text.string.utf8.count > 1_048_576 {
                focus = text
                showCustomScriptWarning("脚本不能超过 1 MiB。")
                continue
            }
            do {
                var configuration = try editableConfiguration()
                let id = "custom." + UUID().uuidString.lowercased()
                let script = try ScriptLibrary(directory: SharedConfig.directoryForHost).create(id: id, body: text.string)
                do {
                    let path = Template.literal(script.path)
                    configuration.actions.append(ActionDefinition(id: id, title: scriptName, icon: "terminal",
                        when: MatchCondition(surfaces: [.items, .container, .sidebar], kinds: [.file, .directory]),
                        execution: ExecutionDefinition(type: .command, executable: "/bin/zsh", arguments: [path, "{paths}"], requirements: Requirements(paths: [path]))))
                    addReference(DefaultConfiguration.reference(id), group: "menu.custom", title: "自定义", configuration: &configuration)
                    try save(configuration)
                    return scriptName
                } catch {
                    try? FileManager.default.removeItem(at: script)
                    throw error
                }
            } catch {
                focus = text
                showCustomScriptWarning(error.localizedDescription)
            }
        }
    }

    private func showCustomScriptWarning(_ message: String) {
        let warning = NSAlert()
        warning.messageText = "无法保存自定义脚本"
        warning.informativeText = message
        warning.alertStyle = .warning
        warning.addButton(withTitle: "好")
        warning.runModal()
    }

    private func openWithIdentifiers(in configuration: FrameworkConfiguration) -> [String] {
        func find(_ nodes: [MenuDefinition]) -> [MenuDefinition]? {
            for node in nodes {
                if node.id == "menu.open-with", node.type == .group { return node.children }
                if let children = node.children, let found = find(children) { return found }
            }
            return nil
        }
        guard let children = find(configuration.menu) else { return [] }
        let ids = Set(children.compactMap(\.actionID))
        return configuration.actions.filter { ids.contains($0.id) }
            .flatMap { $0.execution.requirements?.applications ?? [] }
            .map {
                (try? Template.expand($0, values: ["home": FileManager.default.homeDirectoryForCurrentUser.path])) ?? $0
            }
    }

    private func blockingError(_ error: Error?) -> Error? {
        guard let error else { return nil }
        return (error as? FrameworkError)?.code == "config.backupFailed" ? nil : error
    }

    private func editableConfiguration() throws -> FrameworkConfiguration {
        let snapshot = try repository.load()
        if let error = blockingError(repository.lastError) { throw error }
        return snapshot.configuration
    }
    private func save(_ configuration: FrameworkConfiguration) throws {
        try repository.save(configuration)
        snapshot = repository.snapshot
        onChange?()
    }
    private func addReference(_ node: MenuDefinition, group: String, title: String, configuration: inout FrameworkConfiguration) {
        if append(node, to: group, nodes: &configuration.menu) { return }
        let definition = MenuDefinition(type: .group, id: group, title: title, children: [node])
        if !append(definition, to: "menu.finderx", nodes: &configuration.menu) { configuration.menu.append(definition) }
    }

    func reloadReportingErrors() {
        load()
        if let error = repository.lastError,
           (error as? FrameworkError)?.code != "config.backupFailed" {
            FileActions.showError(error)
        }
    }

    private func append(_ reference: MenuDefinition, to group: String, nodes: inout [MenuDefinition]) -> Bool {
        for index in nodes.indices {
            if nodes[index].id == group, nodes[index].type == .group {
                var children = nodes[index].children ?? []
                let position = children.firstIndex(where: { $0.type == .separator || $0.actionID == "app.add-destination" }) ?? children.endIndex
                children.insert(reference, at: position)
                nodes[index].children = children
                return true
            }
            if var children = nodes[index].children, append(reference, to: group, nodes: &children) {
                nodes[index].children = children
                return true
            }
        }
        return false
    }
}
