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

    func addViaPanel() {
        do {
            _ = try repository.load()
            if let error = repository.lastError { throw error }
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false
            panel.allowsMultipleSelection = true; panel.canCreateDirectories = true
            panel.prompt = "添加"; panel.message = "选择“移动到”的目标文件夹"
            guard panel.runModal() == .OK else { return }
            var configuration = try editableConfiguration()
            var known = Set(configuration.actions.compactMap(DefaultConfiguration.destination).map(\.path))
            for url in panel.urls where known.insert(url.path).inserted {
                let destination = Destination(name: SharedConfig.displayName(for: url), path: url.path)
                configuration.actions.append(DefaultConfiguration.moveAction(destination))
                if !append(DefaultConfiguration.reference(destination.id), to: "menu.move", nodes: &configuration.menu) {
                    throw FrameworkError(code: "config.invalid", message: "配置中缺少 menu.move 分组，请在配置中恢复该分组。")
                }
            }
            try repository.save(configuration)
            snapshot = repository.snapshot
            onChange?()
        } catch { FileActions.showError(error) }
    }

    func remove(at offsets: IndexSet) {
        do {
            let displayed = destinations
            let ids = Set(offsets.compactMap { displayed.indices.contains($0) ? displayed[$0].id : nil })
            var configuration = try repository.load().configuration
            if let error = repository.lastError { throw error }
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
        } catch { FileActions.showError(error) }
    }

    func editConfiguration() {
        NSWorkspace.shared.open(repository.url)
    }

    func openScripts() {
        NSWorkspace.shared.open(ScriptLibrary(directory: SharedConfig.directoryForHost).scripts)
    }

    func addApplication() {
        do {
            var configuration = try editableConfiguration()
            let panel = NSOpenPanel()
            panel.canChooseFiles = true; panel.canChooseDirectories = false
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.message = "选择应用，FinderX 会生成打开文件的脚本动作"
            panel.prompt = "添加打开方式"
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let app = panel.url else { return }
            configuration = try editableConfiguration()
            let id = "open." + UUID().uuidString.lowercased()
            let body = "#!/bin/zsh\nset -euo pipefail\n/usr/bin/open -a \(ScriptLibrary.shellLiteral(app.path)) \"$@\"\nprintf '%s\\n' '已提交打开请求。'\n"
            let generated = try ScriptLibrary(directory: SharedConfig.directoryForHost).create(id: id, body: body)
            let script = Template.literal(generated.path)
            let action = ActionDefinition(id: id, title: app.deletingPathExtension().lastPathComponent, icon: "app",
                when: MatchCondition(surfaces: [.items, .container, .sidebar], kinds: [.file, .directory]),
                execution: ExecutionDefinition(type: .command, executable: "/bin/zsh", arguments: [script, "{paths}"],
                    requirements: Requirements(applications: [Template.literal(app.path)], paths: [script])))
            configuration.actions.append(action)
            addReference(DefaultConfiguration.reference(id), group: "menu.open-with", title: "打开方式", configuration: &configuration)
            do { try save(configuration) }
            catch { try? FileManager.default.removeItem(at: generated); throw error }
        } catch { FileActions.showError(error) }
    }

    func addCustomScript() {
        do {
            var configuration = try editableConfiguration()
            let alert = NSAlert()
            alert.messageText = "添加自定义脚本"
            alert.informativeText = "使用 zsh 编写操作。所选文件作为独立参数传入，通过 \"$@\" 读取。"
            alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
            let title = NSTextField(string: "自定义操作")
            title.placeholderString = "菜单名称"
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 260))
            text.isRichText = false; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            text.isAutomaticQuoteSubstitutionEnabled = false
            text.isAutomaticDashSubstitutionEnabled = false
            text.string = "#!/bin/zsh\nset -euo pipefail\n\n# 示例：在 Finder 中显示所选文件。\nfor selected_path in \"$@\"; do\n  /usr/bin/open -R \"$selected_path\"\ndone\n"
            let scroll = NSScrollView(frame: text.frame)
            scroll.hasVerticalScroller = true; scroll.documentView = text
            let stack = NSStackView(views: [title, scroll])
            stack.orientation = .vertical; stack.spacing = 10
            stack.frame = NSRect(x: 0, y: 0, width: 560, height: 300)
            title.widthAnchor.constraint(equalToConstant: 560).isActive = true
            scroll.widthAnchor.constraint(equalToConstant: 560).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 260).isActive = true
            alert.accessoryView = stack
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            guard !title.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.string.utf8.count <= 1_048_576 else {
                throw FrameworkError(code: "script.invalid", message: "名称不能为空，脚本不能超过 1 MiB。")
            }
            configuration = try editableConfiguration()
            let id = "custom." + UUID().uuidString.lowercased()
            let script = try ScriptLibrary(directory: SharedConfig.directoryForHost).create(id: id, body: text.string)
            do {
                let path = Template.literal(script.path)
                configuration.actions.append(ActionDefinition(id: id, title: title.stringValue, icon: "terminal",
                    when: MatchCondition(surfaces: [.items, .container, .sidebar], kinds: [.file, .directory]),
                    execution: ExecutionDefinition(type: .command, executable: "/bin/zsh", arguments: [path, "{paths}"], requirements: Requirements(paths: [path]))))
                addReference(DefaultConfiguration.reference(id), group: "menu.custom", title: "自定义", configuration: &configuration)
                try save(configuration)
            } catch { try? FileManager.default.removeItem(at: script); throw error }
        } catch { FileActions.showError(error) }
    }

    private func editableConfiguration() throws -> FrameworkConfiguration {
        let snapshot = try repository.load()
        if let error = repository.lastError { throw error }
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
        if let error = repository.lastError { FileActions.showError(error) }
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
