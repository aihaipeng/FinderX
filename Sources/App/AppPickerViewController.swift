import Cocoa
import UniformTypeIdentifiers

private func pickerFont(_ style: NSFont.TextStyle, weight: NSFont.Weight = .regular) -> NSFont {
    .systemFont(ofSize: NSFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
}

struct InstalledApplication {
    let name: String
    let bundleID: String
    let url: URL
    let icon: NSImage

    static func load(from url: URL) -> InstalledApplication? {
        guard url.pathExtension == "app", let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else { return nil }
        let localizedName = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.localizedInfoDictionary?["CFBundleName"] as? String
            ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.infoDictionary?["CFBundleName"] as? String
            ?? FileManager.default.displayName(atPath: url.path)
        let name = (localizedName as NSString).deletingPathExtension
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 28, height: 28)
        return InstalledApplication(name: name, bundleID: bundleID, url: url, icon: icon)
    }
}

enum ApplicationCatalog {
    static func load() -> [InstalledApplication] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            home.appendingPathComponent("Applications")
        ]
        var seen = Set<String>()
        var applications: [InstalledApplication] = []

        func add(_ url: URL) {
            guard let application = InstalledApplication.load(from: url),
                  application.bundleID != "com.finderx.app",
                  seen.insert(application.bundleID).inserted else { return }
            applications.append(application)
        }

        for root in roots {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for url in urls {
                if url.pathExtension == "app" {
                    add(url)
                } else if url.pathExtension != "app",
                          (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          let nested = try? FileManager.default.contentsOfDirectory(
                              at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                          ) {
                    for child in nested where child.pathExtension == "app" { add(child) }
                }
            }
        }
        return applications.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

final class AppPickerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let applications: [InstalledApplication]
    private let addedIdentifiers: Set<String>
    private var filtered: [InstalledApplication]
    private let onSelect: (InstalledApplication) -> Void
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "没有匹配的 App")
    private let addButton = NSButton(title: "添加", target: nil, action: nil)
    private var isClosing = false

    init(applications: [InstalledApplication], addedIdentifiers: Set<String> = [],
         onSelect: @escaping (InstalledApplication) -> Void) {
        self.applications = applications
        self.addedIdentifiers = addedIdentifiers
        self.filtered = applications
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 520, height: 560)
        title = "选择 App"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 560))

        let title = NSTextField(labelWithString: "选择 App")
        title.font = pickerFont(.title2, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancel.controlSize = .small
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.keyEquivalentModifierMask = []
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true

        addButton.target = self
        addButton.action = #selector(selectApp)
        addButton.controlSize = .small
        addButton.bezelStyle = .rounded
        addButton.keyEquivalent = "\r"
        addButton.keyEquivalentModifierMask = []
        addButton.isEnabled = false
        addButton.setAccessibilityLabel("添加选中的 App")
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        addButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true

        let footer = NSStackView(views: [cancel, addButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        let otherButton = NSButton(title: "其他 App…", target: self, action: #selector(chooseOtherApp))
        otherButton.controlSize = .small
        otherButton.bezelStyle = .rounded
        otherButton.translatesAutoresizingMaskIntoConstraints = false
        otherButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        otherButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        otherButton.setAccessibilityLabel("从磁盘选择 App")

        searchField.placeholderString = "搜索 App"
        searchField.font = pickerFont(.body)
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(filterApps)
        searchField.delegate = self
        searchField.setAccessibilityLabel("搜索 App")
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        column.width = 484
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.style = .plain
        tableView.headerView = nil
        tableView.rowHeight = 45
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClickApp)
        tableView.setAccessibilityLabel("App 列表")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = pickerFont(.callout)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(title)
        root.addSubview(searchField)
        root.addSubview(scrollView)
        root.addSubview(emptyLabel)
        root.addSubview(footer)
        root.addSubview(otherButton)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),

            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            searchField.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 15),
            searchField.heightAnchor.constraint(equalToConstant: 24),

            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 15),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),

            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            otherButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            otherButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),

            emptyLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 20),
            emptyLabel.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -20),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateTableSize()
        selectFirstMatch()
        updateEmptyState()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateTableSize()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    @objc private func cancel() {
        close()
    }

    @objc private func selectApp() {
        let row = tableView.selectedRow
        guard filtered.indices.contains(row), !isAdded(filtered[row]) else { return }
        commit(filtered[row])
    }

    @objc private func doubleClickApp() {
        let row = tableView.clickedRow
        guard filtered.indices.contains(row), !isAdded(filtered[row]) else { return }
        commit(filtered[row])
    }

    private func commit(_ application: InstalledApplication) {
        close()
        DispatchQueue.main.async { [onSelect] in
            onSelect(application)
        }
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        presentingViewController?.dismiss(self)
    }

    private func isAdded(_ application: InstalledApplication) -> Bool {
        let path = application.url.standardizedFileURL.path
        let fileName = application.url.deletingPathExtension().lastPathComponent
        return addedIdentifiers.contains {
            $0 == path || $0 == fileName || $0 == "\(fileName).app"
                || $0 == application.name || $0 == "\(application.name).app"
                || $0 == application.bundleID
        }
    }

    @objc private func filterApps() {
        let term = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = term.isEmpty ? applications : applications.filter {
            $0.name.localizedCaseInsensitiveContains(term) || $0.bundleID.localizedCaseInsensitiveContains(term)
        }
        tableView.reloadData()
        updateEmptyState()
        updateTableSize()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        selectFirstMatch()
    }

    @objc private func chooseOtherApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "选择"
        panel.message = "选择要加入“打开方式”的 App"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let application = InstalledApplication.load(from: url) else {
            showPickerAlert("无法添加 App", "请选择有效的 .app 应用。")
            return
        }
        guard !isAdded(application) else {
            showPickerAlert("无法添加 App", "该 App 已在“打开方式”中。")
            return
        }
        commit(application)
    }

    private func showPickerAlert(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func updateEmptyState() {
        let searching = !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        emptyLabel.stringValue = (searching ? "没有匹配的 App" : "没有可添加的 App") + "\n可用“其他 App…”选择"
        emptyLabel.isHidden = !filtered.isEmpty
    }

    private func selectFirstMatch() {
        guard let row = filtered.firstIndex(where: { !isAdded($0) }) else {
            tableView.deselectAll(nil)
            addButton.isEnabled = false
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        addButton.isEnabled = true
    }

    private func updateTableSize() {
        let rowsHeight = filtered.isEmpty ? 0
            : max(CGFloat(filtered.count) * 47, tableView.rect(ofRow: filtered.count - 1).maxY)
        let height = max(scrollView.contentSize.height, rowsHeight)
        let width = scrollView.contentSize.width > 0 ? scrollView.contentSize.width : 484
        tableView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        tableView.sizeLastColumnToFit()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("app")
        let cell: AppPickerCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? AppPickerCellView {
            cell = reused
        } else {
            cell = AppPickerCellView()
            cell.identifier = identifier
        }
        let application = filtered[row]
        cell.configure(application, added: isAdded(application))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        addButton.isEnabled = filtered.indices.contains(row) && !isAdded(filtered[row])
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        filtered.indices.contains(row) && !isAdded(filtered[row])
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField, commandSelector == #selector(NSResponder.insertNewline(_:)) else {
            return false
        }
        selectApp()
        return true
    }
}

private final class AppPickerCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let bundleLabel = NSTextField(labelWithString: "")
    private let addedLabel = NSTextField(labelWithString: "已添加")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityElement(false)
        iconView.cell?.setAccessibilityElement(false)
        nameLabel.font = pickerFont(.body, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        bundleLabel.font = pickerFont(.subheadline)
        bundleLabel.lineBreakMode = .byTruncatingMiddle
        addedLabel.font = pickerFont(.body, weight: .medium)
        addedLabel.textColor = .secondaryLabelColor
        addedLabel.isHidden = true
        addedLabel.setContentHuggingPriority(.required, for: .horizontal)
        addedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let textStack = NSStackView(views: [nameLabel, bundleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let contentStack = NSStackView(views: [textStack, addedLabel])
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.distribution = .fill
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
            contentStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 11),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 7),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -7)
        ])
        updateTextColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateTextColors() }
    }

    private func updateTextColors() {
        let emphasized = backgroundStyle == .emphasized
        nameLabel.textColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
        bundleLabel.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        addedLabel.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }

    func configure(_ application: InstalledApplication, added: Bool) {
        iconView.image = application.icon
        iconView.alphaValue = added ? 0.55 : 1
        nameLabel.stringValue = application.name
        nameLabel.alphaValue = 1
        bundleLabel.stringValue = application.bundleID
        addedLabel.isHidden = !added
        nameLabel.toolTip = added ? "\(application.name)\n已在打开方式中" : application.name
        bundleLabel.toolTip = application.bundleID
        setAccessibilityEnabled(!added)
    }
}
