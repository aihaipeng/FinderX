import Combine
import Foundation

enum SettingsSection: Int, CaseIterable, Identifiable {
    case openWith, destinations, copyTo, sendTo, scripts, advanced, status

    var id: Self { self }

    var title: String {
        switch self {
        case .openWith: return "打开方式"
        case .destinations: return "移动到"
        case .copyTo: return "拷贝到"
        case .sendTo: return "发送到"
        case .scripts: return "自定义脚本"
        case .advanced: return "高级"
        case .status: return "状态"
        }
    }

    var symbol: String {
        switch self {
        case .openWith: return "square.grid.2x2"
        case .destinations: return "folder"
        case .copyTo: return "doc.on.doc"
        case .sendTo: return "paperplane"
        case .scripts: return "terminal"
        case .advanced: return "gearshape"
        case .status: return "info.circle"
        }
    }

    var keywords: [String] {
        switch self {
        case .openWith: return ["App", "应用", "打开", "添加", "其他", "浏览"]
        case .destinations: return ["文件夹", "移动", "移动到", "目标", "Dock", "快捷方式", "符号链接"]
        case .copyTo: return ["拷贝", "复制", "目标", "文件夹", "固定", "选择"]
        case .sendTo: return ["发送", "LocalSend", "快捷方式", "桌面", "符号链接", "动作"]
        case .scripts: return ["脚本", "zsh", "终端", "目录", "编辑", "移除", "自定义"]
        case .advanced: return ["Finder", "配置文件", "路径", "重新加载", "维护", "扩展", "权限"]
        case .status: return ["Finder", "扩展", "配置", "加载", "启用", "权限", "概览"]
        }
    }

    static let groups: [(title: String, sections: [Self])] = [
        ("菜单与操作", [.openWith, .destinations, .copyTo, .sendTo]),
        ("进阶", [.scripts, .advanced]),
        ("概览", [.status])
    ]

    static func matching(_ query: String) -> [Self] {
        let term = folded(query)
        return allCases.filter { section in
            term.isEmpty || ([section.title] + section.keywords).contains { folded($0).contains(term) }
        }
    }

    static func searchRows(_ query: String) -> [SettingsSearchRow] {
        let term = folded(query)
        guard !term.isEmpty else { return [] }
        func rank(_ section: Self) -> Int {
            let title = folded(section.title)
            return title == term ? 0 : title.contains(term) ? 1 : 2
        }
        let sections = matching(query).sorted {
            rank($0) == rank($1) ? $0.rawValue < $1.rawValue : rank($0) < rank($1)
        }
        return sections.flatMap { section in
            var seen: Set<String> = []
            let suggestions = section.keywords.filter {
                folded($0).contains(term) && seen.insert(folded($0)).inserted
            }
            return [SettingsSearchRow(section: section, keyword: nil, selectable: rank(section) < 2)]
                + suggestions.map { SettingsSearchRow(section: section, keyword: $0, selectable: true) }
        }
    }

    private static func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SettingsSearchRow: Identifiable, Equatable {
    let section: SettingsSection
    let keyword: String?
    let selectable: Bool
    var id: String { "\(section.rawValue):" + (keyword ?? "") }
    var title: String { keyword ?? section.title }
}

final class SettingsNavigation: ObservableObject {
    @Published private(set) var section: SettingsSection = .status
    @Published private(set) var revision = 0
    @Published private(set) var sidebarToggleRequest = 0
    private var history: [SettingsSection] = [.status]
    private var index = 0
    var onSelection: (() -> Void)?

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index + 1 < history.count }

    func toggleSidebar() { sidebarToggleRequest += 1 }

    func select(_ destination: SettingsSection) {
        if destination != section {
            history.removeSubrange((index + 1)..<history.count)
            history.append(destination)
            index = history.count - 1
            show(destination)
        } else {
            revision += 1
        }
    }

    func goBack() {
        guard canGoBack else { return }
        index -= 1
        show(history[index])
    }

    func goForward() {
        guard canGoForward else { return }
        index += 1
        show(history[index])
    }

    private func show(_ destination: SettingsSection) {
        section = destination
        revision += 1
        onSelection?()
    }
}
