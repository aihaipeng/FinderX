import Cocoa
import SwiftUI

// The CLI SDK lacks SwiftUIMacros; use the existing State property wrapper.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct SettingsRootView: View {
    let controller: SettingsViewController
    @ObservedObject var navigation: SettingsNavigation
    @ViewState private var columns: NavigationSplitViewVisibility = .all
    @ViewState private var query = ""
    @ViewState private var collapsedGroups: Set<String> = []
    @ViewState private var pendingSelection: SettingsSection?
    @ViewState private var searchIndex: Int?
    @ViewState private var pickedInSidebar = false
    @FocusState private var searchFocused: Bool

    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var searchRows: [SettingsSearchRow] { SettingsSection.searchRows(query) }
    private var matches: [SettingsSearchRow] { searchRows.filter(\.selectable) }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .navigationSplitViewColumnWidth(min: 198, ideal: 210, max: 240)
        } detail: {
            // Keep the AppKit document's ideal height from resizing the window.
            GeometryReader { geometry in
                SettingsDetail(controller: controller)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: toggleSidebar) {
                    Label(columns == .detailOnly ? "显示边栏" : "隐藏边栏", systemImage: "sidebar.left")
                }
                .help(columns == .detailOnly ? "显示边栏" : "隐藏边栏")
            }
            ToolbarItemGroup(placement: .navigation) {
                Button(action: navigation.goBack) { Label("后退", systemImage: "chevron.backward") }
                    .disabled(!navigation.canGoBack)
                    .help("后退")
                Button(action: navigation.goForward) { Label("前进", systemImage: "chevron.forward") }
                    .disabled(!navigation.canGoForward)
                    .help("前进")
            }
        }
        .frame(minWidth: 772, maxWidth: .infinity, minHeight: 528, maxHeight: .infinity)
        .onChange(of: navigation.sidebarToggleRequest) { _ in toggleSidebar() }
    }

    @ViewBuilder private var sidebar: some View {
        if #available(macOS 27, *) {
            sidebarList
                .searchable(text: $query, placement: .sidebar, prompt: "搜索设置")
                .scrollEdgeEffectStyle(.hard, for: .top)
        } else if #available(macOS 26, *) {
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索设置", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onExitCommand { query = "" }
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除")
                    }
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 7)
                .background(.quaternary.opacity(0.5), in: Capsule())
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)
                sidebarList
            }
        } else {
            sidebarList.searchable(text: $query, placement: .sidebar, prompt: "搜索设置")
        }
    }

    private var sidebarList: some View {
        let groups = SettingsSection.groups.map { group in
            (title: group.title, sections: collapsedGroups.contains(group.title) ? [] : group.sections)
        }
        return ScrollViewReader { proxy in
            List(selection: Binding<SettingsSection?>(
                get: { pendingSelection ?? navigation.section },
                set: { section in
                    guard let section, section != navigation.section else { return }
                    pendingSelection = section
                }
            )) {
                if searching {
                    ForEach(searchRows) { row in
                        searchRow(row)
                    }
                } else {
                    ForEach(groups, id: \.title) { group in
                        Section {
                            ForEach(group.sections) { section in
                                HStack(spacing: 9) {
                                    Image(systemName: section.symbol)
                                        .foregroundStyle(navigation.section == section
                                            ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                                        .frame(width: 18)
                                    Text(section.title)
                                }
                                .tag(section)
                                .id(section)
                                .help(section.title)
                            }
                        } header: {
                            Button {
                                if !collapsedGroups.insert(group.title).inserted {
                                    collapsedGroups.remove(group.title)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: group.sections.isEmpty ? "chevron.right" : "chevron.down")
                                        .font(.system(size: 9, weight: .semibold))
                                        .frame(width: 12)
                                    Text(group.title)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            // List retains empty native sections when a collapsed group is reopened.
            .id(collapsedGroups)
            .onChange(of: pendingSelection) { section in
                guard let section else { return }
                pendingSelection = nil
                pickedInSidebar = true
                navigation.select(section)
            }
            .onChange(of: query) { _ in
                searchIndex = searching && !matches.isEmpty ? 0 : nil
                if !searching { revealSelection(proxy) }
            }
            .onChange(of: navigation.revision) { _ in
                let reveal = !pickedInSidebar || searching
                pickedInSidebar = false
                query = ""
                searchIndex = nil
                if reveal { revealSelection(proxy) }
            }
            .onChange(of: searchIndex) { index in
                guard let index, matches.indices.contains(index) else { return }
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    proxy.scrollTo(matches[index].id)
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(matches[index].id) }
                }
            }
            .background(SettingsSearchKeys(customFieldFocused: searchFocused) { code in
                guard searching, !matches.isEmpty else { return false }
                switch code {
                case 125, 126:
                    let count = matches.count
                    let current = searchIndex ?? (code == 125 ? count - 1 : 0)
                    searchIndex = (current + (code == 125 ? 1 : -1) + count) % count
                case 36, 76:
                    guard let index = searchIndex, matches.indices.contains(index) else { return false }
                    route(matches[index].section)
                default: return false
                }
                return true
            })
        }
    }

    private func searchRow(_ row: SettingsSearchRow) -> some View {
        let selected = matches.firstIndex(where: { $0.id == row.id }).map { $0 == searchIndex } ?? false
        return Button { route(row.section) } label: {
            Label(row.title, systemImage: row.section.symbol)
                .fontWeight(row.keyword == nil ? .semibold : .regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .foregroundStyle(selected ? Color.accentColor : .primary)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.18) : .clear))
                .padding(.leading, row.keyword == nil ? 0 : 18)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .id(row.id)
    }

    private func route(_ section: SettingsSection) {
        navigation.select(section)
    }

    private func revealSelection(_ proxy: ScrollViewProxy) {
        if let group = SettingsSection.groups.first(where: { $0.sections.contains(navigation.section) }) {
            collapsedGroups.remove(group.title)
        }
        DispatchQueue.main.async { proxy.scrollTo(navigation.section, anchor: .center) }
    }

    private func toggleSidebar() {
        let next: NavigationSplitViewVisibility = columns == .detailOnly ? .all : .detailOnly
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            columns = next
        } else {
            withAnimation { columns = next }
        }
    }
}

private struct SettingsDetail: NSViewControllerRepresentable {
    let controller: SettingsViewController
    func makeNSViewController(context: Context) -> SettingsViewController { controller }
    func updateNSViewController(_ controller: SettingsViewController, context: Context) {}
}

private struct SettingsSearchKeys: NSViewRepresentable {
    let customFieldFocused: Bool
    let handle: (UInt16) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view, weak coordinator = context.coordinator] event in
            guard let coordinator, let window = view?.window, event.window === window,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                  !editor.hasMarkedText(),
                  coordinator.customFieldFocused || editor.delegate is NSSearchField else { return event }
            return coordinator.handle(event.keyCode) ? nil : event
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.customFieldFocused = customFieldFocused
        context.coordinator.handle = handle
    }
    func makeCoordinator() -> Coordinator { Coordinator(customFieldFocused, handle) }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }
    final class Coordinator {
        var customFieldFocused: Bool
        var handle: (UInt16) -> Bool
        var monitor: Any?
        init(_ focused: Bool, _ handle: @escaping (UInt16) -> Bool) {
            customFieldFocused = focused
            self.handle = handle
        }
    }
}

final class SettingsWindow: NSWindow, NSWindowDelegate {
    weak var navigation: SettingsNavigation?
    private var navigationButtons: Set<Int> = []
    private var canNavigate: Bool { isKeyWindow && attachedSheet == nil && NSApp.modalWindow == nil }

    @objc func toggleSettingsSidebar(_ sender: Any?) { if canNavigate { navigation?.toggleSidebar() } }
    @objc func goBack(_ sender: Any?) { if canNavigate { navigation?.goBack() } }
    @objc func goForward(_ sender: Any?) { if canNavigate { navigation?.goForward() } }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleSettingsSidebar(_:)): return canNavigate
        case #selector(goBack(_:)): return canNavigate && navigation?.canGoBack == true
        case #selector(goForward(_:)): return canNavigate && navigation?.canGoForward == true
        default: return super.validateMenuItem(item)
        }
    }

    func windowWillClose(_ notification: Notification) { NSApp.setActivationPolicy(.accessory) }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let size = contentView?.frame.size, size.width >= 772, size.height >= 528 else { return }
        UserDefaults.standard.set(size.width, forKey: "settingsWindowWidth")
        UserDefaults.standard.set(size.height, forKey: "settingsWindowHeight")
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .otherMouseDown where canNavigate && [3, 4].contains(event.buttonNumber):
            navigationButtons.insert(event.buttonNumber)
            if event.buttonNumber == 3 { goBack(nil) } else { goForward(nil) }
        case .otherMouseUp, .otherMouseDragged:
            if navigationButtons.contains(event.buttonNumber) {
                if event.type == .otherMouseUp { navigationButtons.remove(event.buttonNumber) }
                return
            }
            super.sendEvent(event)
        default: super.sendEvent(event)
        }
    }
}
