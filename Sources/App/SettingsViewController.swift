import Cocoa
import FinderSync

final class SettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: ConfigStore

    private let statusImage = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusDetail = NSTextField(labelWithString: "")
    private let enableButton = NSButton(title: "启用…", target: nil, action: nil)
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let addButton = NSButton(title: "添加文件夹…", target: nil, action: nil)
    private let removeButton = NSButton(title: "移除", target: nil, action: nil)

    init(store: ConfigStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 500))

        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 10

        statusImage.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        )
        statusImage.contentTintColor = .systemOrange
        statusImage.translatesAutoresizingMaskIntoConstraints = false
        statusImage.widthAnchor.constraint(equalToConstant: 22).isActive = true
        statusImage.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let statusText = NSStackView()
        statusText.orientation = .vertical
        statusText.alignment = .leading
        statusText.spacing = 2
        statusLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        statusDetail.font = .systemFont(ofSize: 11)
        statusDetail.textColor = .secondaryLabelColor
        statusDetail.lineBreakMode = .byWordWrapping
        statusDetail.maximumNumberOfLines = 2
        statusText.addArrangedSubview(statusLabel)
        statusText.addArrangedSubview(statusDetail)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        enableButton.target = self
        enableButton.action = #selector(toggleExtension)

        statusRow.addArrangedSubview(statusImage)
        statusRow.addArrangedSubview(statusText)
        statusRow.addArrangedSubview(spacer)
        statusRow.addArrangedSubview(enableButton)

        let separator = NSBox()
        separator.boxType = .separator

        let scriptRow = NSStackView(views: [
            NSButton(title: "添加打开方式…", target: self, action: #selector(addApplication)),
            NSButton(title: "添加自定义脚本…", target: self, action: #selector(addCustomScript)),
            NSButton(title: "打开脚本目录", target: self, action: #selector(openScripts)),
            NSButton(title: "编辑配置…", target: self, action: #selector(editConfiguration))
        ])
        scriptRow.orientation = .horizontal
        scriptRow.spacing = 8
        let scriptNote = NSTextField(labelWithString: "菜单执行可编辑脚本；修改配置后自动加载，也可在菜单栏查看执行结果。")
        scriptNote.font = .systemFont(ofSize: 11)
        scriptNote.textColor = .secondaryLabelColor

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        let headerLabel = NSTextField(labelWithString: "“移动到”目标文件夹")
        headerLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addButton.target = self
        addButton.action = #selector(addDestination)
        headerRow.addArrangedSubview(headerLabel)
        headerRow.addArrangedSubview(headerSpacer)
        headerRow.addArrangedSubview(addButton)

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "名称"
        nameColumn.width = 130
        let pathColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        pathColumn.title = "路径"
        pathColumn.width = 380
        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(pathColumn)
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.delegate = self
        tableView.dataSource = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(equalToConstant: 220).isActive = true

        let bottomRow = NSStackView()
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 8
        let note = NSTextField(labelWithString: "Dock 操作会重启 Dock；快捷方式为符号链接。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let bottomSpacer = NSView()
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        removeButton.target = self
        removeButton.action = #selector(removeDestination)
        removeButton.isEnabled = false
        let refreshButton = NSButton(title: "重新加载", target: self, action: #selector(reloadConfiguration))
        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeWindow))
        bottomRow.addArrangedSubview(note)
        bottomRow.addArrangedSubview(bottomSpacer)
        bottomRow.addArrangedSubview(removeButton)
        bottomRow.addArrangedSubview(refreshButton)
        bottomRow.addArrangedSubview(closeButton)

        let stack = NSStackView(views: [statusRow, separator, scriptRow, scriptNote, headerRow, scrollView, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottomRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        view = root
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

    @objc func refreshStatus() {
        let enabled = FIFinderSyncController.isExtensionEnabled
        statusImage.image = NSImage(
            systemSymbolName: enabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        )
        statusImage.contentTintColor = enabled ? .systemGreen : .systemOrange
        statusLabel.stringValue = enabled ? "Finder 扩展已启用" : "Finder 扩展未启用"
        statusDetail.stringValue = "在系统设置 > 通用 > 登录项与扩展 > 文件扩展中启用 FinderX Finder。"
        enableButton.title = enabled ? "扩展设置…" : "启用…"
        if let error = store.repository.lastError {
            statusLabel.stringValue = "配置状态需要处理"
            statusDetail.stringValue = error.localizedDescription
            statusImage.contentTintColor = .systemOrange
        }
    }

    private func refresh() {
        tableView.reloadData()
        refreshStatus()
        if tableView.selectedRow >= store.destinations.count {
            tableView.deselectAll(nil)
        }
        removeButton.isEnabled = tableView.selectedRow >= 0
    }

    @objc private func toggleExtension() {
        FIFinderSyncController.showExtensionManagementInterface()
    }

    @objc private func addDestination() {
        store.addViaPanel()
    }

    @objc private func addApplication() { store.addApplication() }
    @objc private func addCustomScript() { store.addCustomScript() }
    @objc private func openScripts() { store.openScripts() }
    @objc private func editConfiguration() { store.editConfiguration() }
    @objc private func reloadConfiguration() { store.reloadReportingErrors(); refreshStatus() }

    @objc private func removeDestination() {
        guard tableView.selectedRow >= 0 else { return }
        store.remove(at: IndexSet(integer: tableView.selectedRow))
    }

    @objc private func closeWindow() {
        view.window?.close()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        store.destinations.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        let identifier = tableColumn.identifier
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        let destination = store.destinations[row]
        cell.textField?.stringValue = identifier.rawValue == "name" ? destination.name : destination.path
        cell.textField?.textColor = identifier.rawValue == "name" ? .labelColor : .secondaryLabelColor
        cell.textField?.font = identifier.rawValue == "name"
            ? .systemFont(ofSize: 12)
            : .systemFont(ofSize: 11)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = tableView.selectedRow >= 0
    }
}
