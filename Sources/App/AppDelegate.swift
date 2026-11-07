import Cocoa
import FinderSync
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var settingsController: SettingsViewController?
    private let store = ConfigStore()
    private let transport = InvocationTransport(directory: SharedConfig.directoryForHost)
    private var latestResult: ExecutionResult?
    private var timer: Timer?
    private var extensionMenuItem: NSMenuItem?
    private var actionStatusMenuItem: NSMenuItem?
    private var submissionErrorMenuItem: NSMenuItem?
    private var cancelMenuItem: NSMenuItem?
    private var activeActions: [UUID: String] = [:]
    private var submissionError: String?
    private lazy var dispatcher = ActionDispatcher(
        repository: ConfigurationRepository(url: SharedConfig.configURLForHost, home: FileManager.default.homeDirectoryForCurrentUser.path, writable: true),
        builder: PlanBuilder(home: FileManager.default.homeDirectoryForCurrentUser.path, applicationExists: ApplicationLocator.exists),
        builtins: FileActions.registry(addDestination: { [weak self] in self?.store.addViaPanel() }, settings: { [weak self] in self?.showSettings() }))

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        do {
            let library = ScriptLibrary(directory: SharedConfig.directoryForHost)
            try library.migrateLegacy(from: SharedConfig.legacyDirectoryForHost)
            if let resources = Bundle.main.resourceURL { try library.install(from: resources) }
            try library.migrateDefaultExitCodes()
        } catch { recordBackgroundError(error) }
        store.load()
        refreshAvailability()
        refreshSubmissionError()
        refreshMenuState()
        transport.removeExpired()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.store.load()
            self?.refreshAvailability()
            self?.refreshSubmissionError()
            self?.refreshMenuState()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        // Menu actions can cold-launch this agent. Extension state must never
        // turn a background action into a settings/onboarding window.
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handle(url) }
    }
    // LaunchServices may send a reopen event while delivering a URL. Settings
    // are opened only by an explicit Settings menu item or settings URL.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        dispatcher.cancelAll()
        NotificationCenter.default.removeObserver(self)
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 FinderX",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 FinderX", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 FinderX", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        let editMenuItem = NSMenuItem()
        mainMenu.insertItem(editMenuItem, at: 1)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let navigationMenuItem = NSMenuItem()
        let navigationMenu = NSMenu(title: "前往")
        navigationMenu.addItem(withTitle: "后退", action: #selector(SettingsWindow.goBack(_:)), keyEquivalent: "[")
        navigationMenu.addItem(withTitle: "前进", action: #selector(SettingsWindow.goForward(_:)), keyEquivalent: "]")
        navigationMenuItem.submenu = navigationMenu
        mainMenu.insertItem(navigationMenuItem, at: 2)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        let sidebarItem = NSMenuItem(title: "切换边栏", action: #selector(SettingsWindow.toggleSettingsSidebar(_:)), keyEquivalent: "s")
        sidebarItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(sidebarItem)
        viewMenuItem.submenu = viewMenu
        mainMenu.insertItem(viewMenuItem, at: 3)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "contextualmenu.and.cursorarrow", accessibilityDescription: "FinderX")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "FinderX"
        statusItem.button?.setAccessibilityLabel("FinderX")
        let menu = NSMenu()
        for (title, selector) in [("设置…", #selector(showSettings)), ("编辑动作配置…", #selector(editConfiguration)),
                                   ("重新加载配置", #selector(reloadConfiguration)), ("最近执行结果…", #selector(showLatestResult))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }

        let actionStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        actionStatus.isEnabled = false
        actionStatus.isHidden = true
        menu.addItem(actionStatus)
        actionStatusMenuItem = actionStatus

        let submission = NSMenuItem(title: "上次提交失败…", action: #selector(showSubmissionError), keyEquivalent: "")
        submission.target = self
        submission.isHidden = true
        menu.addItem(submission)
        submissionErrorMenuItem = submission

        let cancel = NSMenuItem(title: "取消执行中的动作", action: #selector(cancelActions), keyEquivalent: "")
        cancel.target = self
        cancel.isEnabled = false
        menu.addItem(cancel)
        cancelMenuItem = cancel

        let extensionItem = NSMenuItem(title: "启用 Finder 扩展…", action: #selector(enableExtension), keyEquivalent: "")
        extensionItem.target = self
        menu.addItem(extensionItem)
        extensionMenuItem = extensionItem

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 FinderX", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        statusItem.menu = menu
    }
    @objc private func showSettings() {
        NSApp.setActivationPolicy(.regular)
        if settingsWindow == nil {
            let controller = SettingsViewController(store: store)
            let host = NSHostingController(rootView: SettingsRootView(controller: controller, navigation: controller.navigation))
            host.sizingOptions = []
            let window = SettingsWindow(contentViewController: host)
            window.navigation = controller.navigation
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.title = "FinderX 设置"
            host.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 772).isActive = true
            host.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 528).isActive = true
            window.minSize = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 772, height: 528)).size
            window.contentMinSize = NSSize(width: 772, height: 528)
            let defaults = UserDefaults.standard
            let savedWidth = defaults.double(forKey: "settingsWindowWidth")
            let savedHeight = defaults.double(forKey: "settingsWindowHeight")
            let hasSavedSize = savedWidth >= 772 && savedHeight >= 528
            let availableHeight = (NSScreen.main?.visibleFrame.height ?? 878) - 40
            window.setContentSize(NSSize(width: hasSavedSize ? savedWidth : 772,
                height: hasSavedSize ? savedHeight : min(838, max(528, availableHeight))))
            window.delegate = window
            window.isRestorable = false
            window.hidesOnDeactivate = false
            window.canHide = false
            window.isReleasedWhenClosed = false
            window.center()
            settingsController = controller; settingsWindow = window
        }
        settingsController?.reload()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func editConfiguration() { store.editConfiguration() }
    @objc private func reloadConfiguration() { store.reloadReportingErrors(); refreshAvailability() }
    @objc private func enableExtension() { FIFinderSyncController.showExtensionManagementInterface() }
    @objc private func cancelActions() {
        guard !activeActions.isEmpty else { return }
        dispatcher.cancelAll()
        cancelMenuItem?.isEnabled = false
        actionStatusMenuItem?.title = "正在取消 \(activeActions.count) 个操作…"
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func showLatestResult() {
        let alert = NSAlert()
        alert.messageText = "最近执行结果"
        guard let result = latestResult else {
            alert.informativeText = "尚未执行动作。"
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        alert.informativeText = "\(result.title)：\(result.status.displayName)"
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 240))
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = result.summary
        let scroll = NSScrollView(frame: text.frame)
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = text
        scroll.widthAnchor.constraint(equalToConstant: 520).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 240).isActive = true
        alert.accessoryView = scroll
        alert.addButton(withTitle: "好")
        let output = SharedConfig.directoryForHost.appendingPathComponent("last-execution.json")
        if FileManager.default.fileExists(atPath: output.path) { alert.addButton(withTitle: "显示记录") }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([output])
        }
    }
    @objc private func applicationDidBecomeActive() {
        refreshMenuState()
        refreshSubmissionError()
    }
    private func beginAction(_ invocation: Invocation) {
        activeActions[invocation.requestID] = store.snapshot?.action(invocation.actionID)?.title ?? "操作"
        refreshMenuState()
    }
    private func finishAction(_ invocation: Invocation, result: ExecutionResult) {
        activeActions.removeValue(forKey: invocation.requestID)
        present(result)
        refreshMenuState()
    }
    private func refreshMenuState() {
        let enabled = FIFinderSyncController.isExtensionEnabled
        extensionMenuItem?.title = enabled ? "管理 Finder 扩展…" : "启用 Finder 扩展…"
        if activeActions.isEmpty {
            actionStatusMenuItem?.isHidden = true
            cancelMenuItem?.isEnabled = false
        } else {
            actionStatusMenuItem?.isHidden = false
            actionStatusMenuItem?.title = activeActions.count == 1
                ? "正在执行：\(activeActions.values.first ?? "操作")"
                : "正在执行 \(activeActions.count) 个操作…"
            cancelMenuItem?.isEnabled = true
        }
        updateStatusAppearance()
    }
    private func updateStatusAppearance() {
        let imageName: String
        let tooltip: String
        if !activeActions.isEmpty {
            imageName = "hourglass"
            tooltip = "FinderX：正在执行操作。"
        } else if submissionError != nil {
            imageName = "exclamationmark.circle"
            tooltip = "FinderX：上次操作未能提交，可在菜单中查看。"
        } else if let result = latestResult, result.status != .succeeded,
                  result.status != .cancelled, result.status != .skipped {
            imageName = "exclamationmark.circle"
            tooltip = "FinderX：操作未完成，可在菜单中查看最近执行结果。"
        } else {
            imageName = "contextualmenu.and.cursorarrow"
            tooltip = "FinderX"
        }
        statusItem.button?.image = NSImage(systemSymbolName: imageName, accessibilityDescription: "FinderX")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = tooltip
    }
    private func refreshSubmissionError() {
        let text = try? String(contentsOf: SharedConfig.submissionErrorURLForHost, encoding: .utf8)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty == false) ? trimmed : nil
        guard value != submissionError else { return }
        submissionError = value
        submissionErrorMenuItem?.isHidden = value == nil
        updateStatusAppearance()
    }
    @objc private func showSubmissionError() {
        guard let submissionError else { return }
        let alert = NSAlert()
        alert.messageText = "上次操作未能提交"
        alert.informativeText = submissionError
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    private func refreshAvailability() {
        guard let snapshot = store.snapshot else { return }
        do { try DependencyAvailability.write(directory: SharedConfig.directoryForHost, snapshot: snapshot) }
        catch { NSLog("FinderX dependencies: %@", error.localizedDescription) }
    }
    private func handle(_ url: URL) {
        guard url.scheme == "finderx" else { return }
        if url.host == "settings" { showSettings(); return }
        if url.host == "add-destination" { store.addViaPanel(); return }
        do {
            let invocation: Invocation?
            if url.host == "invoke" { invocation = try transport.take(url) }
            else { invocation = nil }
            if let invocation {
                try? FileManager.default.removeItem(at: SharedConfig.submissionErrorURLForHost)
                refreshSubmissionError()
                beginAction(invocation)
                dispatcher.submit(invocation) { [weak self] result in
                    self?.finishAction(invocation, result: result)
                }
            }
        } catch { recordBackgroundError(error) }
    }
    private func present(_ result: ExecutionResult) {
        latestResult = result
        // Save one bounded result for inspecting commands whose UI stays quiet.
        let output = SharedConfig.directoryForHost.appendingPathComponent("last-execution.json")
        do { try JSONEncoder().encode(result).write(to: output, options: .atomic) }
        catch { NSLog("FinderX result: %@", error.localizedDescription) }
        updateStatusAppearance()
        announce("\(result.title)：\(result.status.displayName)")
    }
    private func recordBackgroundError(_ error: Error) {
        let now = Date()
        present(ExecutionResult(requestID: UUID(), actionID: "", title: "FinderX", startedAt: now, finishedAt: now, status: .failed,
            jobs: [JobResult(targets: [], status: .failed, errorCode: (error as? FrameworkError)?.code ?? "action.failed", message: error.localizedDescription)]))
    }
}
