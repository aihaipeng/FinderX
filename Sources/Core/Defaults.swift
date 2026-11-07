import Foundation

struct Destination: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    init(id: String = "move." + UUID().uuidString.lowercased(), name: String, path: String) {
        self.id = id; self.name = name; self.path = path
    }
}

enum DefaultConfiguration {
    static let scriptDirectory = "{home}/Library/Containers/com.finderx.app.finder/Data/Library/Application Support/FinderX/Scripts"
    static func scriptPath(_ name: String) -> String { scriptDirectory + "/" + name + ".zsh" }
    static func script(_ name: String, arguments: [String] = ["{paths}"], applications: [String]? = nil) -> ExecutionDefinition {
        ExecutionDefinition(type: .command, executable: "/bin/zsh", arguments: [scriptPath(name)] + arguments,
            requirements: Requirements(applications: applications, paths: [scriptPath(name)]))
    }
    static func destination(for action: ActionDefinition) -> Destination? {
        guard action.execution.type == .command, action.execution.arguments?.first == scriptPath("move"),
              let arguments = action.execution.arguments, arguments.count == 3 else { return nil }
        let path = (try? Template.expand(arguments[1], values: ["home": FileManager.default.homeDirectoryForCurrentUser.path])) ?? arguments[1]
        return Destination(id: action.id, name: action.title, path: path)
    }
    static func moveAction(_ destination: Destination) -> ActionDefinition {
        ActionDefinition(id: destination.id, title: destination.name, icon: "folder",
            when: MatchCondition(surfaces: [.items, .container, .sidebar], kinds: [.file, .directory]), batch: .each,
            execution: script("move", arguments: [Template.literal(destination.path), "{paths}"]))
    }
    static func reference(_ id: String) -> MenuDefinition { MenuDefinition(type: .action, id: "menu." + id, actionID: id) }

    static var copyToAction: ActionDefinition {
        var execution = script("copy-to", arguments: ["--choose", "{paths}"])
        execution.timeoutSeconds = 600
        return ActionDefinition(id: "files.copy-to", title: "拷贝到…", icon: "doc.on.doc",
            when: MatchCondition(surfaces: [.items, .container, .sidebar], kinds: [.file, .directory]), execution: execution)
    }

    static var openWithGroup: MenuDefinition {
        MenuDefinition(type: .group, id: "menu.open-with", title: "打开方式", children: [], showWhenEmpty: true)
    }

    static func hasOpenWith(_ configuration: FrameworkConfiguration) -> Bool {
        func contains(_ nodes: [MenuDefinition]) -> Bool {
            nodes.contains { ($0.id == openWithGroup.id && $0.type == .group && $0.showWhenEmpty == true) || contains($0.children ?? []) }
        }
        return contains(configuration.menu)
    }

    static func addingOpenWith(_ configuration: FrameworkConfiguration) -> FrameworkConfiguration {
        var updated = configuration
        func update(_ nodes: inout [MenuDefinition]) -> Bool {
            for index in nodes.indices {
                if nodes[index].id == openWithGroup.id {
                    if nodes[index].type == .group { nodes[index].showWhenEmpty = true }
                    return true
                }
                if var children = nodes[index].children, update(&children) {
                    nodes[index].children = children
                    return true
                }
            }
            return false
        }
        if update(&updated.menu) { return updated }
        func insert(into nodes: inout [MenuDefinition]) -> Bool {
            for index in nodes.indices {
                if nodes[index].id == "menu.finderx", nodes[index].type == .group {
                    var children = nodes[index].children ?? []
                    let position = children.firstIndex(where: { $0.type == .separator || $0.actionID == "app.add-destination" }) ?? children.endIndex
                    children.insert(openWithGroup, at: position)
                    nodes[index].children = children
                    return true
                }
                if var children = nodes[index].children, insert(into: &children) {
                    nodes[index].children = children
                    return true
                }
            }
            return false
        }
        if !insert(into: &updated.menu) { updated.menu.append(openWithGroup) }
        return updated
    }

    static func addingCopyTo(_ configuration: FrameworkConfiguration) -> FrameworkConfiguration {
        guard !configuration.actions.contains(where: { $0.id == copyToAction.id }) else { return configuration }
        var updated = configuration
        updated.actions.append(copyToAction)
        let node = reference(copyToAction.id)
        func insert(into nodes: inout [MenuDefinition]) -> Bool {
            for index in nodes.indices {
                if nodes[index].id == "menu.finderx", nodes[index].type == .group {
                    var children = nodes[index].children ?? []
                    let position = children.firstIndex(where: { $0.id == "menu.move" }) ?? children.endIndex
                    children.insert(node, at: position)
                    nodes[index].children = children
                    return true
                }
                if var children = nodes[index].children, insert(into: &children) {
                    nodes[index].children = children
                    return true
                }
            }
            return false
        }
        if !insert(into: &updated.menu) { updated.menu.append(node) }
        return updated
    }

    static func make(home: String, destinations: [Destination]? = nil) -> FrameworkConfiguration {
        let directories = MatchCondition(surfaces: [.items, .container, .sidebar], kinds: [.directory])
        let any = MatchCondition(surfaces: [.items, .container, .sidebar], kinds: [.file, .directory])
        let targets = destinations ?? ["Desktop", "Documents", "Downloads"].map {
            let url = URL(fileURLWithPath: home).appendingPathComponent($0)
            return Destination(name: FileManager.default.displayName(atPath: url.path), path: url.path)
        }
        var seen = Set<String>()
        let unique = targets.filter { seen.insert(URL(fileURLWithPath: $0.path).standardizedFileURL.path).inserted }
        let actions = [
            ActionDefinition(id: "open.terminal", title: "在终端中打开", icon: "terminal", when: directories,
                execution: script("terminal", applications: ["Terminal"])),
            ActionDefinition(id: "clipboard.paths", title: "复制路径", icon: "doc.on.doc", when: any,
                execution: script("copy-paths")),
            ActionDefinition(id: "dock.pin", title: "固定到程序坞", icon: "pin", when: directories,
                execution: script("pin-dock")),
            ActionDefinition(id: "send.localsend", title: "LocalSend", icon: "antenna.radiowaves.left.and.right", when: any,
                execution: script("localsend", applications: ["LocalSend"])),
            ActionDefinition(id: "shortcut.desktop", title: "桌面快捷方式", icon: "desktopcomputer", when: any, batch: .each,
                execution: script("symlink", arguments: ["{home}/Desktop", "{paths}"])),
            ActionDefinition(id: "app.add-destination", title: "添加目标文件夹…", when: any,
                execution: ExecutionDefinition(type: .builtin, operation: "app.add-destination", parameters: [:]))
        ] + unique.map(moveAction)
        return addingCopyTo(FrameworkConfiguration(schemaVersion: 1, actions: actions, menu: [
            MenuDefinition(type: .group, id: "menu.finderx", title: "FinderX", icon: "contextualmenu.and.cursorarrow", children: [
                reference("open.terminal"), reference("clipboard.paths"), reference("dock.pin"), openWithGroup, MenuDefinition(type: .separator, id: "menu.separator.files"),
                MenuDefinition(type: .group, id: "menu.move", title: "移动到", icon: "folder", children:
                    unique.map { reference($0.id) } + [MenuDefinition(type: .separator, id: "menu.separator.destinations"), reference("app.add-destination")]),
                MenuDefinition(type: .group, id: "menu.send", title: "发送到", icon: "paperplane", children: [reference("send.localsend"), reference("shortcut.desktop")])
            ])
        ]))
    }
}
