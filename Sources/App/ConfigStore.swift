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
        orderedActions(inGroup: "menu.move").compactMap(DefaultConfiguration.destination)
    }
    var copyTargets: [CopyTarget] {
        orderedActions(inGroup: "menu.finderx").compactMap(DefaultConfiguration.copyTarget)
    }
    var sendActions: [ActionDefinition] { actions(inGroup: "menu.send") }

    private func orderedActions(inGroup group: String) -> [ActionDefinition] {
        guard let configuration = snapshot?.configuration else { return [] }
        return orderedActions(inGroup: group, configuration: configuration)
    }

    private func orderedActions(inGroup group: String, configuration: FrameworkConfiguration) -> [ActionDefinition] {
        let ordered = actions(inGroup: group, configuration: configuration)
        let ids = Set(ordered.map(\.id))
        return ordered + configuration.actions.filter { !ids.contains($0.id) }
    }

    @discardableResult
    func reorder(group: String, ids: [String]) -> Bool {
        guard Set(ids).count == ids.count, ids.count > 1 else { return false }
        do {
            var configuration = try editableConfiguration()
            let current: [String]
            switch group {
            case "menu.move": current = orderedActions(inGroup: group, configuration: configuration).compactMap(DefaultConfiguration.destination).map(\.id)
            case "menu.finderx": current = orderedActions(inGroup: group, configuration: configuration).compactMap(DefaultConfiguration.copyTarget).map(\.id)
            default: current = actions(inGroup: group, configuration: configuration).map(\.id)
            }
            guard Set(current) == Set(ids), current != ids else { return false }
            let ranks = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
            func reorderNodes(_ nodes: inout [MenuDefinition]) {
                for index in nodes.indices {
                    if nodes[index].id == group, nodes[index].type == .group, var children = nodes[index].children {
                        let positions = children.indices.filter { children[$0].type == .action && ranks[children[$0].actionID ?? ""] != nil }
                        let sorted = positions.map { children[$0] }.sorted {
                            ranks[$0.actionID!]! < ranks[$1.actionID!]!
                        }
                        for (position, node) in zip(positions, sorted) { children[position] = node }
                        nodes[index].children = children
                    } else if var children = nodes[index].children {
                        reorderNodes(&children)
                        nodes[index].children = children
                    }
                }
            }
            reorderNodes(&configuration.menu)
            if group == "menu.move" || group == "menu.finderx" {
                let positions = configuration.actions.indices.filter { ranks[configuration.actions[$0].id] != nil }
                let sorted = positions.map { configuration.actions[$0] }.sorted { ranks[$0.id]! < ranks[$1.id]! }
                for (position, action) in zip(positions, sorted) { configuration.actions[position] = action }
            }
            try save(configuration)
            return true
        } catch {
            FileActions.showError(error)
            return false
        }
    }

    func actions(inGroup id: String) -> [ActionDefinition] {
        guard let configuration = snapshot?.configuration else { return [] }
        return actions(inGroup: id, configuration: configuration)
    }

    @discardableResult
    func setActionEnabled(id: String, enabled: Bool) -> Bool {
        do {
            var configuration = try editableConfiguration()
            guard let index = configuration.actions.firstIndex(where: { $0.id == id }) else { return false }
            guard configuration.actions[index].isEnabled != enabled else { return true }
            configuration.actions[index].enabled = enabled
            try save(configuration)
            return true
        } catch {
            FileActions.showError(error)
            return false
        }
    }

    @discardableResult
    func removeCopyTarget(actionID: String) -> Bool {
        guard let action = snapshot?.action(actionID),
              DefaultConfiguration.copyTarget(for: action)?.path != nil else { return false }
        return removeActions([actionID])
    }

    @discardableResult
    func restoreDefaultCopyAction() -> Bool {
        let action = DefaultConfiguration.copyToAction
        do {
            var configuration = try editableConfiguration()
            guard !configuration.actions.contains(where: { $0.id == action.id }) else { return false }
            configuration.actions.append(action)
            if !insertCopyReference(DefaultConfiguration.reference(action.id), into: &configuration.menu) {
                configuration.menu.append(DefaultConfiguration.reference(action.id))
            }
            try save(configuration)
            return true
        } catch {
            FileActions.showError(error)
            return false
        }
    }

    @discardableResult
    func addSendReference(actionID: String) -> Bool {
        do {
            var configuration = try editableConfiguration()
            guard configuration.actions.contains(where: { $0.id == actionID }),
                  !actions(inGroup: "menu.send", configuration: configuration).contains(where: { $0.id == actionID }) else {
                return false
            }
            let node = MenuDefinition(type: .action, id: "menu.send." + UUID().uuidString.lowercased(), actionID: actionID)
            if !append(node, to: "menu.send", nodes: &configuration.menu) {
                let group = MenuDefinition(type: .group, id: "menu.send", title: "发送到", icon: "paperplane", children: [node])
                if !append(group, to: "menu.finderx", nodes: &configuration.menu) { configuration.menu.append(group) }
            }
            try save(configuration)
            return true
        } catch {
            FileActions.showError(error)
            return false
        }
    }

    @discardableResult
    func removeSendReference(actionID: String) -> Bool {
        do {
            var configuration = try editableConfiguration()
            guard removeReference(actionID, fromGroup: "menu.send", nodes: &configuration.menu) else { return false }
            try save(configuration)
            return true
        } catch {
            FileActions.showError(error)
            return false
        }
    }

    @discardableResult
    func addCopyTargetsViaPanel() -> [String] {
        do {
            _ = try repository.load()
            if let error = blockingError(repository.lastError) { throw error }
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false
            panel.allowsMultipleSelection = true; panel.canCreateDirectories = true
            panel.prompt = "添加"; panel.message = "选择固定的“拷贝到”目标文件夹"
            guard panel.runModal() == .OK else { return [] }
            return addCopyTargets(at: panel.urls)
        } catch {
            FileActions.showError(error)
            return []
        }
    }

    @discardableResult
    func addCopyTargets(at urls: [URL]) -> [String] {
        do {
            var configuration = try editableConfiguration()
            var known = Set(configuration.actions.compactMap(DefaultConfiguration.copyTarget).compactMap(\.path)
                .map { URL(fileURLWithPath: $0).standardizedFileURL.path })
            var added: [String] = []
            for url in urls {
                let path = url.standardizedFileURL.path
                guard known.insert(path).inserted else { continue }
                let name = SharedConfig.displayName(for: url)
                let destination = DefaultConfiguration.copyAction(name: name, path: path)
                configuration.actions.append(destination)
                if !insertCopyReference(DefaultConfiguration.reference(destination.id), into: &configuration.menu) {
                    configuration.menu.append(DefaultConfiguration.reference(destination.id))
                }
                added.append(name)
            }
            guard !added.isEmpty else { return [] }
            try save(configuration)
            return added
        } catch {
            FileActions.showError(error)
            return []
        }
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
    private func actions(inGroup id: String, configuration: FrameworkConfiguration) -> [ActionDefinition] {
        guard let children = menuChildren(id, in: configuration.menu) else { return [] }
        var seen = Set<String>()
        return children.compactMap { node in
            guard node.type == .action, let actionID = node.actionID, seen.insert(actionID).inserted else { return nil }
            return configuration.actions.first { $0.id == actionID }
        }
    }
    private func menuChildren(_ id: String, in nodes: [MenuDefinition]) -> [MenuDefinition]? {
        for node in nodes {
            if node.id == id, node.type == .group { return node.children ?? [] }
            if let children = node.children, let found = menuChildren(id, in: children) { return found }
        }
        return nil
    }
    private func insertCopyReference(_ node: MenuDefinition, into nodes: inout [MenuDefinition]) -> Bool {
        for index in nodes.indices {
            if nodes[index].id == "menu.finderx", nodes[index].type == .group {
                var children = nodes[index].children ?? []
                let position = children.firstIndex { $0.id == "menu.move" } ?? children.endIndex
                children.insert(node, at: position)
                nodes[index].children = children
                return true
            }
            if var children = nodes[index].children, insertCopyReference(node, into: &children) {
                nodes[index].children = children
                return true
            }
        }
        return false
    }
    private func removeReference(_ actionID: String, fromGroup id: String, nodes: inout [MenuDefinition]) -> Bool {
        for index in nodes.indices {
            if nodes[index].id == id, nodes[index].type == .group {
                let before = nodes[index].children?.count ?? 0
                nodes[index].children?.removeAll { $0.type == .action && $0.actionID == actionID }
                if (nodes[index].children?.count ?? 0) != before { return true }
            }
            if var children = nodes[index].children, removeReference(actionID, fromGroup: id, nodes: &children) {
                nodes[index].children = children
                return true
            }
        }
        return false
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
