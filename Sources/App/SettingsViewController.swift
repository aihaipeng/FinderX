import Cocoa
import FinderSync

private func settingsFont(_ style: NSFont.TextStyle, weight: NSFont.Weight = .regular) -> NSFont {
    .systemFont(ofSize: NSFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
}

private extension NSColor {
    static let settingsPageBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .windowBackgroundColor : .underPageBackgroundColor
    }

    static let settingsCardBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .underPageBackgroundColor : .controlBackgroundColor
    }
}

final class SettingsViewController: NSViewController, NSUserInterfaceValidations {
    let navigation = SettingsNavigation()
    private let store: ConfigStore
    private let detailContainer = NSView()
    private var detailScroll: NSScrollView?
    private var pendingRemovalFocus: Int?
    private let settingsUndoManager = UndoManager()

    private var statusIcon: NSImageView?
    private var statusTitle: NSTextField?
    private var statusDetail: NSTextField?
    private var statusButton: NSButton?
    private var configIcon: NSImageView?
    private var configTitle: NSTextField?
    private var configDetail: NSTextField?

    init(store: ConfigStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        navigation.onSelection = { [weak self] in
            guard let self, self.isViewLoaded else { return }
            self.rebuildDetail()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        detailContainer.frame = NSRect(x: 0, y: 0, width: 562, height: 948)
        detailContainer.autoresizingMask = [.width, .height]
        view = detailContainer
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        store.onChange = { [weak self] in
            self?.refresh()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshStatus),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        store.load()
        refresh()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func reload() {
        store.load()
        if isViewLoaded { refresh() }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        detailScroll?.frame = detailContainer.bounds
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if view.window?.firstResponder is NSTextView {
            view.window?.makeFirstResponder(nil)
        }
    }

    private func refresh() {
        guard isViewLoaded else { return }
        let origin = detailScroll?.contentView.bounds.origin ?? .zero
        rebuildDetail()
        view.layoutSubtreeIfNeeded()
        if let scroll = detailScroll {
            var proposed = scroll.contentView.bounds
            proposed.origin = origin
            let clamped = scroll.contentView.constrainBoundsRect(proposed).origin
            scroll.contentView.scroll(to: clamped)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func rebuildDetail() {
        let removalIndex = pendingRemovalFocus
        pendingRemovalFocus = nil
        let focusToken = removalIndex == nil ? focusedToken() : nil
        detailScroll?.removeFromSuperview()
        statusIcon = nil
        statusTitle = nil
        statusDetail = nil
        statusButton = nil
        configIcon = nil
        configTitle = nil
        configDetail = nil

        let page: NSView
        switch navigation.section {
        case .status: page = makeStatusPage()
        case .openWith: page = makeOpenWithPage()
        case .scripts: page = makeScriptsPage()
        case .destinations: page = makeDestinationsPage()
        case .advanced: page = makeAdvancedPage()
        }

        let scroll = NSScrollView(frame: detailContainer.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .settingsPageBackground
        scroll.contentView.drawsBackground = true
        scroll.contentView.backgroundColor = .settingsPageBackground
        scroll.borderType = .noBorder

        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: max(0, detailContainer.bounds.width),
            height: max(0, detailContainer.bounds.height)))
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        document.addSubview(page)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            page.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            page.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            page.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            page.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -28)
        ])
        detailContainer.addSubview(scroll)
        detailScroll = scroll
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        restoreFocus(in: page, removalIndex: removalIndex, token: focusToken)
        refreshStatus()
    }

    private func focusedToken() -> String? {
        guard let control = view.window?.firstResponder as? NSControl,
              control.isDescendant(of: detailContainer) else { return nil }
        if let identifier = control.identifier?.rawValue { return "id:" + identifier }
        if let label = control.accessibilityLabel() { return "label:" + label }
        return nil
    }

    private func restoreFocus(in page: NSView, removalIndex: Int?, token: String?) {
        guard let window = view.window else { return }
        if let removalIndex {
            let buttons = removeButtons(in: page)
            if buttons.indices.contains(removalIndex) {
                window.makeFirstResponder(buttons[removalIndex])
            } else if let last = buttons.last {
                window.makeFirstResponder(last)
            } else if let add = firstAddButton(in: page) {
                window.makeFirstResponder(add)
            }
            return
        }
        guard let token, let control = control(in: page, matching: token) else { return }
        window.makeFirstResponder(control)
    }

    private func removeButtons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { subview -> [NSButton] in
            let nested = removeButtons(in: subview)
            guard let button = subview as? NSButton,
                  button.identifier?.rawValue.hasPrefix("remove.") == true else { return nested }
            return [button] + nested
        }
    }

    private func control(in view: NSView, matching token: String) -> NSControl? {
        if let control = view as? NSControl {
            if token == "id:" + (control.identifier?.rawValue ?? "") { return control }
            if token == "label:" + (control.accessibilityLabel() ?? "") { return control }
        }
        for subview in view.subviews {
            if let match = control(in: subview, matching: token) { return match }
        }
        return nil
    }

    private func firstAddButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title.hasPrefix("添加") { return button }
        for subview in view.subviews {
            if let match = firstAddButton(in: subview) { return match }
        }
        return nil
    }

    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private func registerRemovalUndo(name: String, previous: FrameworkConfiguration) {
        settingsUndoManager.registerUndo(withTarget: self) { target in
            let current = target.store.snapshot?.configuration
            if target.store.restore(previous) {
                target.announce("已撤销移除 \(name)。")
                if let current { target.registerRemovalUndo(name: name, previous: current) }
            }
        }
        settingsUndoManager.setActionName("移除 \(name)")
    }

    @objc func undo(_ sender: Any?) { settingsUndoManager.undo() }
    @objc func redo(_ sender: Any?) { settingsUndoManager.redo() }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) {
            if let menuItem = item as? NSMenuItem, settingsUndoManager.canUndo {
                menuItem.title = settingsUndoManager.undoMenuItemTitle
            }
            return settingsUndoManager.canUndo
        }
        if item.action == #selector(redo(_:)) {
            if let menuItem = item as? NSMenuItem, settingsUndoManager.canRedo {
                menuItem.title = settingsUndoManager.redoMenuItemTitle
            }
            return settingsUndoManager.canRedo
        }
        return true
    }

    private func makeStatusPage() -> NSView {
        let header = pageHeader("状态", "查看 Finder 扩展和菜单配置的运行情况。")

        let extensionIcon = NSImageView()
        extensionIcon.imageScaling = .scaleProportionallyUpOrDown
        extensionIcon.translatesAutoresizingMaskIntoConstraints = false
        extensionIcon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        extensionIcon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        extensionIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        extensionIcon.contentTintColor = .systemGreen
        statusIcon = extensionIcon

        let extensionTitle = NSTextField(labelWithString: "Finder 扩展")
        extensionTitle.font = settingsFont(.body, weight: .medium)
        extensionTitle.lineBreakMode = .byTruncatingTail
        extensionTitle.translatesAutoresizingMaskIntoConstraints = false
        statusTitle = extensionTitle

        let extensionDetail = NSTextField(labelWithString: "")
        extensionDetail.font = settingsFont(.subheadline)
        extensionDetail.textColor = .secondaryLabelColor
        extensionDetail.lineBreakMode = .byTruncatingTail
        extensionDetail.translatesAutoresizingMaskIntoConstraints = false
        statusDetail = extensionDetail

        let extensionText = NSStackView(views: [extensionTitle, extensionDetail])
        extensionText.orientation = .vertical
        extensionText.alignment = .leading
        extensionText.spacing = 2
        extensionText.translatesAutoresizingMaskIntoConstraints = false
        extensionText.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let button = smallButton("扩展设置…", action: #selector(toggleExtension))
        statusButton = button
        let extensionRow = rowContainer(height: 54, icon: extensionIcon, text: extensionText, trailing: button)
        let extensionCard = card([extensionRow])

        let configIcon = NSImageView()
        configIcon.imageScaling = .scaleProportionallyUpOrDown
        configIcon.translatesAutoresizingMaskIntoConstraints = false
        configIcon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        configIcon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        self.configIcon = configIcon
        let configTitle = NSTextField(labelWithString: "")
        configTitle.font = settingsFont(.body, weight: .medium)
        configTitle.lineBreakMode = .byTruncatingTail
        configTitle.translatesAutoresizingMaskIntoConstraints = false
        self.configTitle = configTitle
        let configDetail = NSTextField(labelWithString: "")
        configDetail.font = settingsFont(.subheadline)
        configDetail.textColor = .secondaryLabelColor
        configDetail.lineBreakMode = .byTruncatingTail
        configDetail.translatesAutoresizingMaskIntoConstraints = false
        self.configDetail = configDetail
        let configText = NSStackView(views: [configTitle, configDetail])
        configText.orientation = .vertical
        configText.alignment = .leading
        configText.spacing = 2
        configText.translatesAutoresizingMaskIntoConstraints = false
        configText.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let reloadButton = smallButton("重新加载", action: #selector(reloadConfiguration))
        let configRow = rowContainer(height: 54, icon: configIcon, text: configText, trailing: reloadButton)

        let extensionHeading = sectionTitle("Finder 扩展")
        let configHeading = sectionTitle("配置")
        let stack = pageStack([header, extensionHeading, extensionCard, configHeading, card([configRow])])
        stack.setCustomSpacing(24, after: header)
        stack.setCustomSpacing(10, after: extensionHeading)
        stack.setCustomSpacing(24, after: extensionCard)
        stack.setCustomSpacing(10, after: configHeading)
        return stack
    }

    private func makeOpenWithPage() -> NSView {
        let header = pageHeader("打开方式", "把常用应用加入右键菜单，用于打开所选项目。",
            addTitle: "添加 App…", addAction: #selector(openAppPicker), addWidth: 114)
        let heading = sectionTitle("已添加的应用")
        let actions = actions(inGroup: "menu.open-with")
        let rows: [NSView] = actions.isEmpty
            ? [emptyRow(emptyMessage("尚未添加应用。"))]
            : actions.map { appRow($0) }
        let listCard = card(rows)
        let banner = configErrorBanner()
        var views: [NSView] = [header]
        if let banner { views.append(banner) }
        views += [heading, listCard]
        let stack = pageStack(views)
        stack.setCustomSpacing(24, after: header)
        if let banner { stack.setCustomSpacing(24, after: banner) }
        stack.setCustomSpacing(10, after: heading)
        return stack
    }

    private func makeScriptsPage() -> NSView {
        let header = pageHeader("自定义脚本", "用脚本扩展 FinderX 的右键操作。")
        let heading = sectionTitle("已添加的脚本")
        let actions = actions(inGroup: "menu.custom")
        let rows: [NSView] = actions.isEmpty
            ? [emptyRow(emptyMessage("尚未添加自定义脚本。"))]
            : actions.map { scriptRow($0) }
        let listCard = card(rows)
        let add = smallButton("添加自定义脚本…", action: #selector(addCustomScript))
        let open = smallButton("打开脚本目录", action: #selector(openScripts))
        let buttons = NSStackView(views: [add, open])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let note = noteLabel("脚本使用 zsh 编写，所选文件会作为独立参数传入。")
        let banner = configErrorBanner()
        var views: [NSView] = [header]
        if let banner { views.append(banner) }
        views += [heading, listCard, buttons, note]
        let stack = pageStack(views)
        stack.setCustomSpacing(24, after: header)
        if let banner { stack.setCustomSpacing(24, after: banner) }
        stack.setCustomSpacing(10, after: heading)
        stack.setCustomSpacing(14, after: listCard)
        stack.setCustomSpacing(14, after: buttons)
        return stack
    }

    private func makeDestinationsPage() -> NSView {
        let header = pageHeader("移动目标", "管理“移动到”子菜单中显示的目标文件夹。")
        let heading = sectionTitle("目标文件夹")
        let destinations = store.destinations
        let rows: [NSView] = destinations.isEmpty
            ? [emptyRow(emptyMessage("尚未添加移动目标。"))]
            : destinations.enumerated().map { index, destination in
                destinationRow(destination, index: index)
            }
        let listCard = card(rows)
        let add = smallButton("添加文件夹…", action: #selector(addDestination))
        let buttons = NSStackView(views: [add])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let banner = configErrorBanner()
        var views: [NSView] = [header]
        if let banner { views.append(banner) }
        views += [heading, listCard, buttons]
        let stack = pageStack(views)
        stack.setCustomSpacing(24, after: header)
        if let banner { stack.setCustomSpacing(24, after: banner) }
        stack.setCustomSpacing(10, after: heading)
        stack.setCustomSpacing(14, after: listCard)
        return stack
    }

    private func makeAdvancedPage() -> NSView {
        let header = pageHeader("高级", "直接查看或编辑 FinderX 使用的文件。")
        let configPath = (store.repository.url.path as NSString).abbreviatingWithTildeInPath
        let scriptsPath = (ScriptLibrary(directory: SharedConfig.directoryForHost).scripts.path as NSString)
            .abbreviatingWithTildeInPath
        let configRow = infoRow(symbol: "doc.text", tint: .systemGray,
            title: "配置文件", detail: configPath, buttonTitle: "编辑…", action: #selector(editConfiguration))
        let scriptsRow = infoRow(symbol: "folder", tint: .systemIndigo,
            title: "脚本目录", detail: scriptsPath, buttonTitle: "打开", action: #selector(openScripts))
        let filesHeading = sectionTitle("文件与目录")
        let filesCard = card([configRow, scriptsRow])

        let reloadRow = infoRow(symbol: "arrow.clockwise", tint: .systemBlue,
            title: "重新加载配置", detail: "从磁盘重新读取配置并刷新扩展状态。",
            buttonTitle: "重新加载", action: #selector(reloadConfiguration))
        let extensionRow = infoRow(symbol: "puzzlepiece.extension", tint: .systemGreen,
            title: "Finder 扩展", detail: "在系统设置中启用或管理 Finder 扩展。",
            buttonTitle: "扩展设置…", action: #selector(toggleExtension))
        let maintenanceHeading = sectionTitle("维护")
        let maintenanceCard = card([reloadRow, extensionRow])

        let banner = configErrorBanner()
        var views: [NSView] = [header]
        if let banner { views.append(banner) }
        views += [filesHeading, filesCard, maintenanceHeading, maintenanceCard]
        let stack = pageStack(views)
        stack.setCustomSpacing(24, after: header)
        if let banner { stack.setCustomSpacing(24, after: banner) }
        stack.setCustomSpacing(10, after: filesHeading)
        stack.setCustomSpacing(24, after: filesCard)
        stack.setCustomSpacing(10, after: maintenanceHeading)
        return stack
    }

    private func configErrorBanner() -> NSView? {
        guard let error = store.repository.lastError else { return nil }
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        icon.contentTintColor = .systemOrange
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true

        let title = NSTextField(labelWithString: store.snapshot == nil
            ? "配置加载失败" : "配置有误，继续使用上次有效配置")
        title.font = settingsFont(.body, weight: .medium)
        title.translatesAutoresizingMaskIntoConstraints = false
        let detail = NSTextField(labelWithString: error.localizedDescription)
        detail.font = settingsFont(.subheadline)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 0
        detail.toolTip = error.localizedDescription
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [icon, text])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 9
        header.translatesAutoresizingMaskIntoConstraints = false

        let edit = smallButton("编辑配置…", action: #selector(editConfiguration))
        let reload = smallButton("重新加载", action: #selector(reloadConfiguration))
        let buttons = NSStackView(views: [edit, reload])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [header, buttons])
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        content.translatesAutoresizingMaskIntoConstraints = false
        return SettingsCardView(content: content)
    }

    private func pageStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func pageHeader(_ title: String, _ subtitle: String,
                            addTitle: String? = nil, addAction: Selector? = nil,
                            addWidth: CGFloat = 0) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = settingsFont(.title2, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = settingsFont(.callout)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let left = NSStackView(views: [titleLabel, subtitleLabel])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 4
        left.translatesAutoresizingMaskIntoConstraints = false
        left.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(left)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            left.topAnchor.constraint(equalTo: container.topAnchor),
            left.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        if let addTitle, let addAction {
            let button = smallButton(addTitle, action: addAction)
            button.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                button.topAnchor.constraint(equalTo: container.topAnchor),
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: addWidth),
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
                left.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -16)
            ])
        } else {
            left.trailingAnchor.constraint(equalTo: container.trailingAnchor).isActive = true
        }
        return container
    }

    private func sectionTitle(_ text: String) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(greaterThanOrEqualToConstant: 16).isActive = true
        let label = NSTextField(labelWithString: text)
        label.font = settingsFont(.body, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor),
            label.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -10)
        ])
        return container
    }

    private func card(_ rows: [NSView]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, row) in rows.enumerated() {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if index < rows.count - 1 {
                let separator = NSBox()
                separator.boxType = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
            }
        }
        return SettingsCardView(content: stack)
    }

    private func rowContainer(height: CGFloat, icon: NSImageView, text: NSStackView,
                              trailing: NSView?) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true
        row.addSubview(icon)
        row.addSubview(text)
        var constraints = [
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            text.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            text.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 8),
            text.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -8)
        ]
        if let trailing {
            trailing.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(trailing)
            constraints += [
                trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
                trailing.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                trailing.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
                text.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -10)
            ]
        } else {
            constraints.append(text.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -10))
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    private func appRow(_ action: ActionDefinition) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 41).isActive = true

        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = applicationIcon(for: action)
        if icon.image == nil {
            icon.image = NSImage(systemSymbolName: "questionmark.app", accessibilityDescription: "应用未找到")
            icon.contentTintColor = .systemOrange
        }

        let name = NSTextField(labelWithString: action.title)
        name.font = settingsFont(.body, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.translatesAutoresizingMaskIntoConstraints = false
        if let path = applicationPath(for: action) {
            name.toolTip = FileManager.default.fileExists(atPath: path)
                ? "\(action.title)\n\(path)" : "\(action.title)\n应用未找到：\(path)"
        } else {
            name.toolTip = action.title
        }

        let remove = removeButton(action: #selector(removeApplication(_:)), label: action.title)
        remove.identifier = NSUserInterfaceItemIdentifier("remove." + action.id)
        row.addSubview(icon)
        row.addSubview(name)
        row.addSubview(remove)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            name.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 8),
            name.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -8),
            name.trailingAnchor.constraint(lessThanOrEqualTo: remove.leadingAnchor, constant: -8),
            remove.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -7),
            remove.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: 24),
            remove.heightAnchor.constraint(equalToConstant: 24)
        ])
        return row
    }

    private func scriptRow(_ action: ActionDefinition) -> NSView {
        let edit = iconButton(symbol: "pencil", label: "编辑脚本：\(action.title)",
            action: #selector(editCustomScript(_:)))
        edit.identifier = NSUserInterfaceItemIdentifier("script.edit." + action.id)
        let reveal = iconButton(symbol: "folder", label: "在 Finder 中显示脚本：\(action.title)",
            action: #selector(revealCustomScript(_:)))
        reveal.identifier = NSUserInterfaceItemIdentifier("script.reveal." + action.id)
        let remove = removeButton(action: #selector(removeCustomScript(_:)), label: action.title)
        remove.identifier = NSUserInterfaceItemIdentifier("remove." + action.id)
        return listRow(title: action.title, detail: scriptPath(for: action), symbol: "terminal",
            tint: .systemOrange, trailing: [edit, reveal, remove])
    }

    private func destinationRow(_ destination: Destination, index: Int) -> NSView {
        let remove = removeButton(action: #selector(removeDestination(_:)), label: destination.name)
        remove.tag = index
        remove.identifier = NSUserInterfaceItemIdentifier("remove." + destination.id)
        return listRow(title: destination.name, detail: destination.path,
            symbol: "folder", tint: .systemIndigo, trailing: [remove])
    }

    private func listRow(title: String, detail: String?, symbol: String, tint: NSColor,
                         trailing: [NSButton]) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 41).isActive = true

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint
        icon.imageScaling = .scaleProportionallyUpOrDown

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = settingsFont(.body, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.toolTip = title
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [titleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false
        if let detail {
            let detailLabel = NSTextField(labelWithString: (detail as NSString).abbreviatingWithTildeInPath)
            detailLabel.font = settingsFont(.subheadline)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.lineBreakMode = .byTruncatingMiddle
            detailLabel.toolTip = detail
            detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            detailLabel.translatesAutoresizingMaskIntoConstraints = false
            textStack.addArrangedSubview(detailLabel)
        }
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        row.addSubview(icon)
        row.addSubview(textStack)
        var constraints = [
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            textStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 6),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -6)
        ]
        if trailing.isEmpty {
            constraints.append(textStack.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -10))
        } else {
            for button in trailing {
                button.translatesAutoresizingMaskIntoConstraints = false
                button.widthAnchor.constraint(equalToConstant: 24).isActive = true
                button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            }
            let controls = NSStackView(views: trailing)
            controls.orientation = .horizontal
            controls.alignment = .centerY
            controls.spacing = 2
            controls.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(controls)
            constraints += [
                controls.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -7),
                controls.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                textStack.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor, constant: -8)
            ]
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    private func emptyRow(_ text: String) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 41).isActive = true
        let label = NSTextField(labelWithString: text)
        label.font = settingsFont(.callout)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 8),
            label.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -10)
        ])
        return row
    }

    private func infoRow(symbol: String, tint: NSColor, title: String, detail: String,
                         buttonTitle: String, action: Selector) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = settingsFont(.body, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = settingsFont(.subheadline)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.toolTip = detail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let button = smallButton(buttonTitle, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        return rowContainer(height: 54, icon: icon, text: text, trailing: button)
    }

    private func noteLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = settingsFont(.callout)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func smallButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.controlSize = .small
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        return button
    }

    private func removeButton(action: Selector, label: String) -> NSButton {
        let button = iconButton(symbol: "minus.circle.fill", label: "移除 \(label)", action: action)
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    private func iconButton(symbol: String, label: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityLabel(label)
        return button
    }

    private func scriptPath(for action: ActionDefinition) -> String? {
        guard let raw = action.execution.arguments?.first else { return nil }
        let path = (try? Template.expand(raw, values: ["home": NSHomeDirectory()])) ?? raw
        return path.hasPrefix("/") ? path : nil
    }

    private func emptyMessage(_ normal: String) -> String {
        store.snapshot == nil ? "配置加载失败，请前往“高级”页处理。" : normal
    }

    private func applicationPath(for action: ActionDefinition) -> String? {
        guard let raw = action.execution.requirements?.applications?.first else { return nil }
        return (try? Template.expand(raw, values: ["home": NSHomeDirectory()])) ?? raw
    }

    private func applicationIcon(for action: ActionDefinition) -> NSImage? {
        guard let path = applicationPath(for: action),
              FileManager.default.fileExists(atPath: path) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 20, height: 20)
        return icon
    }

    private func actions(inGroup id: String) -> [ActionDefinition] {
        guard let configuration = store.snapshot?.configuration else { return [] }
        func find(_ nodes: [MenuDefinition]) -> [MenuDefinition]? {
            for node in nodes {
                if node.id == id, node.type == .group { return node.children }
                if let children = node.children, let found = find(children) { return found }
            }
            return nil
        }
        guard let children = find(configuration.menu) else { return [] }
        var seen = Set<String>()
        return children.compactMap { node in
            guard node.type == .action, let actionID = node.actionID, seen.insert(actionID).inserted else {
                return nil
            }
            return configuration.actions.first { $0.id == actionID }
        }
    }

    @objc func refreshStatus() {
        let enabled = FIFinderSyncController.isExtensionEnabled
        statusIcon?.image = NSImage(
            systemSymbolName: enabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        )
        statusIcon?.contentTintColor = enabled ? .systemGreen : .systemOrange
        statusTitle?.stringValue = enabled ? "Finder 扩展已启用" : "Finder 扩展未启用"
        statusDetail?.stringValue = enabled
            ? "可在系统设置中管理扩展与权限。"
            : "在系统设置中启用 Finder 扩展。"
        statusDetail?.toolTip = statusDetail?.stringValue
        statusButton?.title = enabled ? "扩展设置…" : "启用…"

        let error = store.repository.lastError
        configIcon?.image = NSImage(
            systemSymbolName: error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        )
        configIcon?.contentTintColor = error == nil ? .systemGreen : .systemOrange
        configTitle?.stringValue = error == nil ? "配置已加载"
            : store.snapshot == nil ? "配置加载失败" : "配置有误，使用上次有效配置"
        let count = store.snapshot?.configuration.actions.count ?? 0
        configDetail?.stringValue = error?.localizedDescription
            ?? "\(count) 个动作 · \(store.destinations.count) 个移动目标"
        configDetail?.toolTip = configDetail?.stringValue
    }

    @objc private func openAppPicker() {
        let applications = ApplicationCatalog.load()
        let picker = AppPickerViewController(applications: applications,
            addedIdentifiers: addedApplicationIdentifiers()) { [weak self] application in
            guard let self else { return }
            if self.store.addApplication(at: application.url) {
                self.announce("已添加 \(application.name)。")
            }
        }
        presentAsSheet(picker)
    }

    private func addedApplicationIdentifiers() -> Set<String> {
        Set(actions(inGroup: "menu.open-with").flatMap { action in
            (action.execution.requirements?.applications ?? []).map {
                (try? Template.expand($0, values: ["home": NSHomeDirectory()])) ?? $0
            }
        })
    }

    @objc private func toggleExtension() {
        FIFinderSyncController.showExtensionManagementInterface()
    }

    @objc private func addDestination() {
        let names = store.addViaPanel()
        if !names.isEmpty { announce("已添加移动目标 \(names.joined(separator: "、"))。") }
    }
    @objc private func addCustomScript() {
        if let name = store.addCustomScript() { announce("已添加自定义脚本 \(name)。") }
    }
    @objc private func openScripts() { store.openScripts() }
    @objc private func editConfiguration() { store.editConfiguration() }
    @objc private func reloadConfiguration() {
        store.reloadReportingErrors()
        refreshStatus()
        refresh()
    }

    @objc private func editCustomScript(_ sender: NSButton) {
        guard let action = scriptAction(for: sender, prefix: "script.edit."),
              let path = scriptPath(for: action) else { return }
        guard FileManager.default.fileExists(atPath: path) else {
            FileActions.showError(FrameworkError(code: "script.missing", message: "脚本不存在：\(path)"))
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func revealCustomScript(_ sender: NSButton) {
        guard let action = scriptAction(for: sender, prefix: "script.reveal."),
              let path = scriptPath(for: action) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func removeApplication(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("remove.") else { return }
        let actionID = String(raw.dropFirst("remove.".count))
        let list = actions(inGroup: "menu.open-with")
        guard let index = list.firstIndex(where: { $0.id == actionID }) else { return }
        let name = list[index].title
        let previous = store.snapshot?.configuration
        pendingRemovalFocus = index
        guard store.removeApplication(actionID: actionID), let previous else {
            pendingRemovalFocus = nil
            return
        }
        registerRemovalUndo(name: name, previous: previous)
        announce("已移除 \(name)。")
    }

    @objc private func removeCustomScript(_ sender: NSButton) {
        guard let action = scriptAction(for: sender, prefix: "remove.") else { return }
        let list = actions(inGroup: "menu.custom")
        let index = list.firstIndex(where: { $0.id == action.id })
        let previous = store.snapshot?.configuration
        pendingRemovalFocus = index
        guard store.removeCustomScript(actionID: action.id), let previous else {
            pendingRemovalFocus = nil
            return
        }
        registerRemovalUndo(name: action.title, previous: previous)
        announce("已从菜单移除 \(action.title)，脚本文件已保留。")
    }

    private func scriptAction(for sender: NSButton, prefix: String) -> ActionDefinition? {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix(prefix) else { return nil }
        let actionID = String(raw.dropFirst(prefix.count))
        return actions(inGroup: "menu.custom").first { $0.id == actionID }
    }

    @objc private func removeDestination(_ sender: NSButton) {
        guard store.destinations.indices.contains(sender.tag) else { return }
        let destination = store.destinations[sender.tag]
        let previous = store.snapshot?.configuration
        pendingRemovalFocus = sender.tag
        guard store.remove(at: IndexSet(integer: sender.tag)), let previous else {
            pendingRemovalFocus = nil
            return
        }
        registerRemovalUndo(name: destination.name, previous: previous)
        announce("已移除移动目标 \(destination.name)。")
    }

}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class SettingsCardView: NSView {
    init(content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.settingsCardBackground.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
