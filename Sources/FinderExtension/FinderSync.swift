import Cocoa
import FinderSync

final class FinderSync: FIFinderSync {
    // Finder sends a reconstructed menu item back across its process boundary.
    // Arbitrary representedObject instances do not survive that round trip.
    // Keep snapshots here and use the integer tag as the transport identity.
    private let bindings = MenuBindings()
    private let repository = ConfigurationRepository(url: SharedConfig.configURLForExtension, home: "", writable: false)
    private let transport = InvocationTransport(directory: SharedConfig.directoryForExtension)

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let surface: Surface
        switch menuKind {
        case .contextualMenuForItems: surface = .items
        case .contextualMenuForContainer: surface = .container
        case .contextualMenuForSidebar: surface = .sidebar
        default: return nil
        }
        let controller = FIFinderSyncController.default()
        let context = ActionContext.capture(surface: surface, selection: controller.selectedItemURLs() ?? [], container: controller.targetedURL())
        guard !context.targets.isEmpty else { return nil }
        let menu = NSMenu(title: "FinderX")
        menu.autoenablesItems = false
        bindings.discardExpired()
        do {
            let snapshot = try repository.load()
            let availability = DependencyAvailability.read(directory: SharedConfig.directoryForExtension, snapshot: snapshot)
            let model = MenuBuilder.build(snapshot: snapshot, context: context, availability: availability)
            render(model, in: menu, snapshot: snapshot, context: context)
            if repository.lastError != nil { menu.addItem(settingsItem("配置有误，打开设置…")) }
        } catch { menu.addItem(settingsItem("FinderX 设置…")) }
        return menu.items.isEmpty ? nil : menu
    }

    private func render(_ nodes: [MenuModel], in menu: NSMenu, snapshot: ConfigurationSnapshot, context: ActionContext) {
        for node in nodes {
            if node.type == .separator { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: node.title, action: node.type == .action ? #selector(invoke(_:)) : nil, keyEquivalent: "")
            if let icon = node.icon { item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil) }
            if node.type == .group {
                let submenu = NSMenu(title: node.title)
                submenu.autoenablesItems = false
                render(node.children, in: submenu, snapshot: snapshot, context: context)
                item.submenu = submenu
            } else if let id = node.actionID {
                item.target = self
                bindings.bind(item, actionID: id, revision: snapshot.revision, context: context)
                item.isEnabled = node.unavailableReason == nil
                item.toolTip = node.unavailableReason
            }
            menu.addItem(item)
        }
    }

    @objc private func invoke(_ sender: NSMenuItem) {
        guard let binding = bindings.resolve(sender) else {
            NSLog("FinderX missing menu binding for tag %ld", sender.tag)
            return
        }
        do {
            let request = Invocation(actionID: binding.actionID, revision: binding.revision, context: binding.context)
            let url = try transport.enqueue(request)
            NSLog("FinderX queued action %@ request %@", request.actionID, request.requestID.uuidString)
            BackgroundLaunch.open(url)
        } catch { NSLog("FinderX request failed: %@", error.localizedDescription) }
    }

    private func settingsItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(openSettings), keyEquivalent: "")
        item.target = self
        return item
    }
    @objc private func openSettings() { NSWorkspace.shared.open(URL(string: "finderx://settings")!) }
}
