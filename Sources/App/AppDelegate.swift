import Cocoa
import FinderSync

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var settingsController: SettingsViewController?
    private let store = ConfigStore()
    private let transport = InvocationTransport(directory: SharedConfig.directoryForHost)
    private var latestResult: ExecutionResult?
    private var timer: Timer?
    private lazy var dispatcher = ActionDispatcher(
        repository: ConfigurationRepository(url: SharedConfig.configURLForHost, home: FileManager.default.homeDirectoryForCurrentUser.path, writable: true),
        builder: PlanBuilder(home: FileManager.default.homeDirectoryForCurrentUser.path, applicationExists: ApplicationLocator.exists),
        builtins: FileActions.registry(addDestination: { [weak self] in self?.store.addViaPanel() }, settings: { [weak self] in self?.showSettings() }))

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        do {
            let library = ScriptLibrary(directory: SharedConfig.directoryForHost)
            try library.migrateLegacy(from: SharedConfig.legacyDirectoryForHost)
            if let resources = Bundle.main.resourceURL { try library.install(from: resources) }
        } catch { recordBackgroundError(error) }
        store.load()
        refreshAvailability()
        transport.removeExpired()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.store.load()
            self?.refreshAvailability()
        }
        // Menu actions can cold-launch this agent. Extension state must never
        // turn a background action into a settings/onboarding window.
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handle(url) }
    }
    // LaunchServices may send a reopen event while delivering a URL. Settings
    // are opened only by an explicit Settings menu item or settings URL.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate(); dispatcher.cancelAll() }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "contextualmenu.and.cursorarrow", accessibilityDescription: "FinderX")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "FinderX"
        let menu = NSMenu()
        for (title, selector) in [("设置…", #selector(showSettings)), ("编辑动作配置…", #selector(editConfiguration)),
                                   ("重新加载配置", #selector(reloadConfiguration)), ("最近执行结果…", #selector(showLatestResult)),
                                   ("取消执行中的动作", #selector(cancelActions)), ("启用 Finder 扩展…", #selector(enableExtension))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 FinderX", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        statusItem.menu = menu
    }
    @objc private func showSettings() {
        if settingsWindow == nil {
            let controller = SettingsViewController(store: store)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "FinderX"; window.center(); window.isReleasedWhenClosed = false
            window.contentViewController = controller
            settingsController = controller; settingsWindow = window
        }
        settingsController?.reload()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func editConfiguration() { store.editConfiguration() }
    @objc private func reloadConfiguration() { store.reloadReportingErrors(); refreshAvailability() }
    @objc private func enableExtension() { FIFinderSyncController.showExtensionManagementInterface() }
    @objc private func cancelActions() { dispatcher.cancelAll() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func showLatestResult() {
        let alert = NSAlert()
        alert.messageText = "最近执行结果"
        alert.informativeText = latestResult?.summary ?? "尚未执行动作。"
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
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
            if let invocation { dispatcher.submit(invocation) { [weak self] result in self?.present(result) } }
        } catch { recordBackgroundError(error) }
    }
    private func present(_ result: ExecutionResult) {
        latestResult = result
        // Save one bounded result for inspecting commands whose UI stays quiet.
        let output = SharedConfig.directoryForHost.appendingPathComponent("last-execution.json")
        do { try JSONEncoder().encode(result).write(to: output, options: .atomic) }
        catch { NSLog("FinderX result: %@", error.localizedDescription) }
        let failed = result.status != .succeeded && result.status != .cancelled
        statusItem?.button?.image = NSImage(systemSymbolName: failed ? "exclamationmark.circle" : "contextualmenu.and.cursorarrow", accessibilityDescription: "FinderX")
        statusItem?.button?.image?.isTemplate = true
        statusItem?.button?.toolTip = failed ? "FinderX：操作未完成，可在菜单中查看最近执行结果。" : "FinderX"
    }
    private func recordBackgroundError(_ error: Error) {
        let now = Date()
        present(ExecutionResult(requestID: UUID(), actionID: "", title: "FinderX", startedAt: now, finishedAt: now, status: .failed,
            jobs: [JobResult(targets: [], status: .failed, errorCode: (error as? FrameworkError)?.code ?? "action.failed", message: error.localizedDescription)]))
    }
}
