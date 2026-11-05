import Foundation

enum ConditionMatcher {
    static func matches(_ action: ActionDefinition, context: ActionContext) -> Bool {
        let condition = action.when
        guard action.isEnabled, condition.surfaces.contains(context.surface),
              context.targets.count >= (condition.minCount ?? 1),
              context.targets.count <= (condition.maxCount ?? Int.max),
              context.targets.allSatisfy({ condition.kinds.contains($0.kind) }) else { return false }
        if let extensions = condition.extensions {
            let allowed = Set(extensions.map { $0.lowercased() })
            return context.targets.allSatisfy { $0.kind == .file && allowed.contains($0.url.pathExtension.lowercased()) }
        }
        return true
    }
}

struct MenuModel {
    let type: MenuKind
    let title: String
    let icon: String?
    let actionID: String?
    let unavailableReason: String?
    let children: [MenuModel]
}

enum MenuBuilder {
    static func build(snapshot: ConfigurationSnapshot, context: ActionContext,
                      availability: [String: String] = [:]) -> [MenuModel] {
        let actions = Dictionary(uniqueKeysWithValues: snapshot.configuration.actions.map { ($0.id, $0) })
        func nodes(_ definitions: [MenuDefinition]) -> [MenuModel] {
            var result: [MenuModel] = []
            for node in definitions {
                switch node.type {
                case .action:
                    guard let id = node.actionID, let action = actions[id],
                          ConditionMatcher.matches(action, context: context) else { continue }
                    result.append(MenuModel(type: .action, title: node.title ?? action.title,
                                            icon: node.icon ?? action.icon, actionID: id,
                                            unavailableReason: availability[id], children: []))
                case .group:
                    let children = nodes(node.children ?? [])
                    if !children.isEmpty {
                        result.append(MenuModel(type: .group, title: node.title ?? "", icon: node.icon,
                                                actionID: nil, unavailableReason: nil, children: children))
                    }
                case .separator:
                    if let previous = result.last, previous.type != .separator {
                        result.append(MenuModel(type: .separator, title: "", icon: nil, actionID: nil,
                                                unavailableReason: nil, children: []))
                    }
                }
            }
            if result.last?.type == .separator { result.removeLast() }
            return result
        }
        return nodes(snapshot.configuration.menu)
    }
}
