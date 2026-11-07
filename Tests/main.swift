import Foundation
import Darwin
import Cocoa

if let code = NativeCommands.handle(Array(CommandLine.arguments.dropFirst())) { exit(code) }
setbuf(stdout, nil)

struct TestFailure: Error, CustomStringConvertible { let description: String }
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure(description: message) }
}
func rejects(_ block: () throws -> Void) throws {
    do { try block() } catch { return }
    throw TestFailure(description: "Expected operation to be rejected")
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("FinderXTests-" + UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let home = root.appendingPathComponent("home")
try fm.createDirectory(at: home, withIntermediateDirectories: true)
let resources = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Resources")
let libraryDirectory = home.appendingPathComponent("Library/Containers/com.finderx.app.finder/Data/Library/Application Support/FinderX")
let library = ScriptLibrary(directory: libraryDirectory)
try library.install(from: resources)
let folder = home.appendingPathComponent("文件夹 with spaces")
try fm.createDirectory(at: folder, withIntermediateDirectories: true)
let file = folder.appendingPathComponent("计划 'quoted' $(date) {literal}\nline.md")
try Data("original".utf8).write(to: file)
let builder = PlanBuilder(home: home.path)
let context = ActionContext.capture(surface: .items, selection: [file], container: folder)
let defaults = DefaultConfiguration.make(home: home.path)
let processRunner = ProcessRunner()
var passed = 0
var failed = 0
func test(_ name: String, _ body: () throws -> Void) {
    do { try body(); passed += 1; print("PASS \(name)") }
    catch { failed += 1; print("FAIL \(name): \(error)") }
}
func command(_ executable: String, _ arguments: [String], input: Data = Data(), timeout: Double = 3) -> CommandJob {
    CommandJob(executable: executable, arguments: arguments, workingDirectory: home.path,
        environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path, "LANG": "en_US.UTF-8", "FINDERX_EXECUTABLE": Bundle.main.executableURL!.path],
        input: input, timeout: timeout, successExitCodes: [0])
}
func runScript(_ name: String, _ arguments: [String]) -> JobResult {
    processRunner.run(command("/bin/zsh", [library.scripts.appendingPathComponent(name + ".zsh").path] + arguments))
}

test("default configuration round trip and script presets") {
    let decoded = try ConfigurationCodec.decode(ConfigurationCodec.encode(defaults))
    try expect(decoded.actions.filter { $0.execution.type == .command }.count == 9, "six script actions plus three destination scripts expected")
    try expect(decoded.actions.filter { $0.execution.type == .builtin }.allSatisfy { $0.id == "app.add-destination" }, "file features must run scripts")
    for action in decoded.actions where action.execution.type == .command { try builder.checkDependencies(action.execution) }
}
test("copy-to uses one command for mixed selections and an editable destination") {
    let action = defaults.actions.first { $0.id == "files.copy-to" }!
    let mixed = ActionContext.capture(surface: .items, selection: [file, folder], container: folder)
    let plan = try builder.build(action: action, context: mixed)
    try expect(plan.jobs.count == 1 && action.batchMode == .all, "directory chooser would repeat per file")
    guard case .command(let job) = plan.jobs[0].payload else { throw TestFailure(description: "copy must be a script") }
    try expect(job.arguments.suffix(3) == ["--choose", file.path, folder.path], "selection arguments changed")
    try expect(job.timeout == 600, "interactive copy needs its declared timeout")
    var configured = action
    configured.execution.arguments?[1] = Template.literal(folder.path)
    try ConfigurationCodec.validate(FrameworkConfiguration(schemaVersion: 1, actions: [configured], menu: [DefaultConfiguration.reference(configured.id)]))
}
test("copy targets distinguish chooser and fixed destinations") {
    let chooser = defaults.actions.first { $0.id == "files.copy-to" }!
    try expect(DefaultConfiguration.copyTarget(for: chooser)?.isChooser == true, "default copy action must be the chooser")
    let oddPath = folder.appendingPathComponent("copy {literal} 'quoted'").path
    let fixed = DefaultConfiguration.copyAction(name: "归档", path: oddPath)
    let configuration = FrameworkConfiguration(schemaVersion: 1, actions: [fixed],
        menu: [DefaultConfiguration.reference(fixed.id)])
    try ConfigurationCodec.validate(configuration)
    let target = DefaultConfiguration.copyTarget(for: fixed)
    try expect(target?.path == oddPath && target?.isChooser == false, "fixed copy path lost")
    try expect(fixed.title == "拷贝到 归档" && fixed.execution.timeoutSeconds == 600, "fixed copy action shape changed")
}
test("copy-to upgrade backs up exact config once and preserves later customization") {
    var previous = defaults
    previous.actions.removeAll { $0.id == "files.copy-to" }
    previous.menu[0].children?.removeAll { $0.actionID == "files.copy-to" }
    previous.menu[0].title = "我的菜单"
    previous.actions[0].title = "我的终端"
    let directory = root.appendingPathComponent("copy-upgrade")
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("config.json")
    let original = try ConfigurationCodec.encode(previous)
    try original.write(to: url)
    let readOnly = ConfigurationRepository(url: url, home: home.path, writable: false)
    try expect(try readOnly.load().configuration.actions.count == previous.actions.count, "extension must not migrate")
    try expect(try Data(contentsOf: url) == original, "read-only load rewrote config")
    let repo = ConfigurationRepository(url: url, home: home.path, writable: true)
    let upgraded = try repo.load()
    try expect(repo.lastError == nil && upgraded.action("files.copy-to") != nil, "existing config not upgraded")
    try expect(upgraded.configuration.menu[0].children?.contains { $0.actionID == "files.copy-to" } == true, "copy menu missing")
    try expect(upgraded.configuration.menu[0].title == "我的菜单" && upgraded.action("open.terminal")?.title == "我的终端", "customizations changed")
    try expect(try Data(contentsOf: directory.appendingPathComponent("config.before-copy-to.json")) == original, "backup changed")
    try expect(try repo.load().revision == upgraded.revision, "upgrade duplicated action")
    try repo.save(previous)
    let restarted = ConfigurationRepository(url: url, home: home.path, writable: true)
    try expect(try restarted.load().action("files.copy-to") == nil, "deleted action was restored")
    let custom = directory.appendingPathComponent("custom/config.json")
    let customRepo = ConfigurationRepository(url: custom, home: home.path, writable: true)
    var alreadyCustomized = defaults
    alreadyCustomized.actions[alreadyCustomized.actions.count - 1].title = "自定义拷贝"
    try customRepo.save(alreadyCustomized)
    try expect(try customRepo.load().action("files.copy-to")?.title == "自定义拷贝", "existing copy action overwritten")
    var withoutRoot = previous
    withoutRoot.menu = [DefaultConfiguration.reference("open.terminal")]
    let fallback = DefaultConfiguration.addingCopyTo(withoutRoot)
    try ConfigurationCodec.validate(fallback)
    try expect(fallback.menu.last?.actionID == "files.copy-to", "custom root prevented copy menu installation")
}
test("open-with group stays visible when empty and is added once to existing config") {
    let snapshot = try ConfigurationCodec.snapshot(defaults)
    func flatten(_ nodes: [MenuModel]) -> [MenuModel] { nodes.flatMap { [$0] + flatten($0.children) } }
    let group = flatten(MenuBuilder.build(snapshot: snapshot, context: context)).first { $0.title == "打开方式" }
    try expect(group?.type == .group && group?.children.isEmpty == true, "empty open-with group was hidden")

    var previous = defaults
    previous.menu[0].children?.removeAll { $0.id == "menu.open-with" }
    previous.menu[0].title = "我的菜单"
    var emptyGroup = previous
    emptyGroup.menu[0].children?.insert(MenuDefinition(type: .group, id: "menu.open-with", title: "打开方式", children: []), at: 3)
    let upgradedEmpty = DefaultConfiguration.addingOpenWith(emptyGroup)
    try expect(upgradedEmpty.menu[0].children?.first { $0.id == "menu.open-with" }?.showWhenEmpty == true, "existing empty group not upgraded")
    let directory = root.appendingPathComponent("open-with-upgrade")
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("config.json")
    try ConfigurationCodec.encode(previous).write(to: url)
    let repo = ConfigurationRepository(url: url, home: home.path, writable: true)
    let upgraded = try repo.load()
    let inserted = upgraded.configuration.menu[0].children?.first { $0.id == "menu.open-with" }
    try expect(inserted?.showWhenEmpty == true && upgraded.configuration.menu[0].title == "我的菜单", "open-with group migration failed")
    try expect(try repo.load().revision == upgraded.revision, "open-with migration duplicated")
    var removed = upgraded.configuration
    removed.menu[0].children?.removeAll { $0.id == "menu.open-with" }
    try repo.save(removed)
    let restarted = ConfigurationRepository(url: url, home: home.path, writable: true)
    try expect(try restarted.load().configuration.menu[0].children?.contains { $0.id == "menu.open-with" } == false, "deleted open-with group was restored")
}
test("strict fields, references, versions and templates") {
    _ = try ConfigurationCodec.decode(Data(contentsOf: resources.deletingLastPathComponent().appendingPathComponent("docs/examples/framework-v1.json")))
    var object = try JSONSerialization.jsonObject(with: ConfigurationCodec.encode(defaults)) as! [String: Any]
    object["typo"] = true
    try rejects { _ = try ConfigurationCodec.decode(JSONSerialization.data(withJSONObject: object)) }
    var config = defaults
    config.schemaVersion = 2
    try rejects { try ConfigurationCodec.validate(config) }
    config = defaults
    config.actions[0].execution.arguments = ["--files={paths}"]
    try rejects { try ConfigurationCodec.validate(config) }
    config.actions[0].execution.arguments = ["{path}"]
    try rejects { try ConfigurationCodec.validate(config) }
    config.actions[0].batch = .each
    try ConfigurationCodec.validate(config)
    config.menu = [MenuDefinition(type: .action, id: "bad", actionID: "open.terminal", showWhenEmpty: true)]
    try rejects { try ConfigurationCodec.validate(config) }
    config.menu = [MenuDefinition(type: .action, id: "broken", actionID: "missing")]
    try rejects { try ConfigurationCodec.validate(config) }
}
test("container context ignores stale selection; mixed selection not filtered") {
    let container = ActionContext.capture(surface: .container, selection: [file], container: folder)
    try expect(container.targets.map(\.path) == [folder.path], "stale selection leaked")
    let mixed = ActionContext.capture(surface: .items, selection: [file, folder, file], container: folder)
    try expect(mixed.targets.count == 2, "paths should be deduplicated")
    try expect(!ConditionMatcher.matches(defaults.actions[0], context: mixed), "terminal must reject mixed selection")
    try expect(ConditionMatcher.matches(defaults.actions[1], context: mixed), "copy paths should accept mixed selection")
}
test("literal arguments, Unicode, quotes and braces") {
    let action = ActionDefinition(id: "test", title: "test", when: MatchCondition(surfaces: [.items], kinds: [.file]),
        execution: ExecutionDefinition(type: .command, executable: "/usr/bin/printf", arguments: ["%s", "{paths}"]))
    let plan = try builder.build(action: action, context: context)
    guard case .command(let job) = plan.jobs[0].payload else { throw TestFailure(description: "expected command") }
    let result = processRunner.run(job)
    try expect(result.status == .succeeded && result.stdout == file.path, "path was split, interpreted or escaped twice")
    try expect(try Template.expand("{{path}}", values: [:]) == "{path}", "brace escaping failed")
    try expect(try Template.expand(Template.literal("{home}"), values: ["home":"wrong"]) == "{home}", "literal interpreted")
}
test("menu pruning and unavailable dependencies") {
    var config = defaults
    config.menu[0].children?.removeAll { $0.id == "menu.open-with" }
    for index in config.actions.indices { config.actions[index].enabled = false }
    let snapshot = try ConfigurationCodec.snapshot(config)
    try expect(MenuBuilder.build(snapshot: snapshot, context: context).isEmpty, "empty groups should disappear")
    let model = MenuBuilder.build(snapshot: try ConfigurationCodec.snapshot(defaults), context: context, availability: ["send.localsend": "missing"])
    func flatten(_ nodes: [MenuModel]) -> [MenuModel] { nodes.flatMap { [$0] + flatten($0.children) } }
    try expect(flatten(model).first { $0.actionID == "send.localsend" }?.unavailableReason == "missing", "dependency state lost")
}
test("legacy migration backup, stable IDs and last-good recovery") {
    let configURL = root.appendingPathComponent("legacy/config.json")
    try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let old = try JSONSerialization.data(withJSONObject: ["destinations": [["name":"目标", "path":folder.path]]])
    try old.write(to: configURL)
    let repo = ConfigurationRepository(url: configURL, home: home.path, writable: true)
    let first = try repo.load()
    let second = try repo.load()
    try expect(first.revision == second.revision, "migration repeated")
    try expect(try Data(contentsOf: configURL.appendingPathExtension("legacy-backup")) == old, "backup changed")
    try Data("broken json".utf8).write(to: configURL)
    let recovered = try repo.load()
    try expect(recovered.revision == first.revision && repo.lastError != nil, "in-memory recovery failed")
    let restarted = ConfigurationRepository(url: configURL, home: home.path, writable: false)
    try expect(try restarted.load().revision == first.revision && restarted.lastError != nil, "disk recovery failed")
    try expect(try String(contentsOf: configURL, encoding: .utf8) == "broken json", "bad config overwritten")
    try fm.removeItem(at: configURL)
    let missing = ConfigurationRepository(url: configURL, home: home.path, writable: true)
    try expect(try missing.load().revision == first.revision && missing.lastError != nil, "deleted config lost saved actions")
    try expect(!fm.fileExists(atPath: configURL.path), "missing config replaced silently")
}
test("request file handoff, consume once, expiration and symlink rejection") {
    let queue = InvocationTransport(directory: root.appendingPathComponent("transport"))
    let request = Invocation(actionID: "clipboard.paths", revision: try ConfigurationCodec.snapshot(defaults).revision, context: context)
    let url = try queue.enqueue(request)
    let decoded = try queue.take(url)
    try expect(decoded?.requestID == request.requestID && decoded?.context == request.context, "snapshot changed")
    try expect(try queue.take(url) == nil, "request replayed")
    let next = Invocation(actionID: "clipboard.paths", revision: "r", context: context)
    let nextURL = try queue.enqueue(next)
    let requestFile = root.appendingPathComponent("transport/Requests/" + next.requestID.uuidString + ".json")
    try fm.removeItem(at: requestFile)
    try fm.createSymbolicLink(at: requestFile, withDestinationURL: file)
    try rejects { _ = try queue.take(nextURL) }
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
    json["createdAt"] = Date(timeIntervalSinceNow: -120).timeIntervalSinceReferenceDate
    let expiredFile = root.appendingPathComponent("transport/Requests/" + request.requestID.uuidString + ".json")
    try JSONSerialization.data(withJSONObject: json).write(to: expiredFile)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: expiredFile.path)
    try rejects { _ = try queue.take(url) }
}
test("menu action handoff stays in the background") {
    let options = BackgroundLaunch.configuration()
    try expect(!options.activates && !options.promptsUserIfNeeded && !options.addsToRecentItems, "action launch may steal focus or display unrelated UI")
}
test("Finder reconstructed menu items resolve using tags without representedObject") {
    let bindings = MenuBindings()
    let first = NSMenuItem(title: "复制路径", action: nil, keyEquivalent: "")
    bindings.bind(first, actionID: "clipboard.paths", revision: "original", context: context)
    let secondContext = ActionContext.capture(surface: .container, selection: [], container: folder)
    let second = NSMenuItem(title: "复制路径", action: nil, keyEquivalent: "")
    bindings.bind(second, actionID: "clipboard.paths", revision: "newer", context: secondContext)
    let callback = NSMenuItem(title: first.title, action: nil, keyEquivalent: "")
    callback.tag = first.tag
    try expect(callback.representedObject == nil, "callback must not carry custom objects")
    try expect(bindings.resolve(callback)?.context == context, "older menu lost its original selection")
    try expect(bindings.resolve(callback)?.revision == "original", "new menu replaced old revision")
    try expect(bindings.resolve(second)?.context == secondContext && first.tag != second.tag, "menu identity collision")
    bindings.discardExpired(now: Date(timeIntervalSinceNow: 601))
    try expect(bindings.resolve(callback) == nil, "expired snapshots retained")
}
test("bounded output drains stdout and stderr without deadlock") {
    let script = "for ((i=0;i<10000;i++)); do printf '0123456789abcdef'; printf 'fedcba9876543210' >&2; done"
    let result = processRunner.run(command("/bin/zsh", ["-c", script]))
    try expect(result.status == .succeeded, "large-output child failed")
    try expect(result.stdout.utf8.count == 65536 && result.stderr.utf8.count == 65536, "capture limit not honored")
    try expect(result.stdoutTruncated && result.stderrTruncated, "truncation flags missing")
}
test("stdin EOF and early exit") {
    let input = Data(repeating: 120, count: 300000)
    let cat = processRunner.run(command("/bin/cat", [], input: input))
    try expect(cat.status == .succeeded && cat.stdoutTruncated, "stdin or EOF stalled")
    let early = processRunner.run(command("/usr/bin/true", [], input: input))
    try expect(early.status == .succeeded, "closed stdin killed host")
}
test("timeout and cancellation terminate script descendants") {
    let pidFile = root.appendingPathComponent("child.pid")
    let script = "/bin/sleep 30 &\nprintf '%s' $! > \"$1\"\nwait"
    let result = processRunner.run(command("/bin/zsh", ["-c", script, "test", pidFile.path], timeout: 0.15))
    try expect(result.status == .timedOut, "timeout not reported")
    let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
    Thread.sleep(forTimeInterval: 0.05)
    try expect(kill(pid, 0) != 0, "descendant survived timeout")
    let token = CancellationToken()
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { token.cancel() }
    let cancelled = processRunner.run(command("/bin/sleep", ["30"]), cancellation: token)
    try expect(cancelled.status == .cancelled, "cancellation not reported")
}
test("copy-to preserves sources, directory contents, links, metadata and occupied paths") {
    let source = root.appendingPathComponent("copy-source")
    let destination = root.appendingPathComponent("copy-target")
    try fm.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: true)
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    let nested = source.appendingPathComponent("nested/.hidden")
    try Data("nested contents".utf8).write(to: nested)
    try fm.setAttributes([.posixPermissions: 0o751], ofItemAtPath: nested.path)
    let metadata = processRunner.run(command("/usr/bin/xattr", ["-w", "com.finderx.test", "metadata", nested.path]))
    try expect(metadata.status == .succeeded, metadata.stderr)
    try fm.createSymbolicLink(atPath: source.appendingPathComponent("nested/link").path, withDestinationPath: ".hidden")
    let dangling = root.appendingPathComponent("copy-dangling")
    try fm.createSymbolicLink(atPath: dangling.path, withDestinationPath: "/nonexistent/finderx-copy")
    let directoryLink = root.appendingPathComponent("copy-directory-link")
    try fm.createSymbolicLink(at: directoryLink, withDestinationURL: source)
    let occupied = destination.appendingPathComponent(file.lastPathComponent)
    try fm.createDirectory(at: occupied, withIntermediateDirectories: false)
    try fm.createSymbolicLink(atPath: occupied.path + " 2", withDestinationPath: "/nonexistent/finderx-copy")
    let result = runScript("copy-to", [destination.path, file.path, source.path, dangling.path, directoryLink.path])
    try expect(result.status == .succeeded, result.message ?? result.stderr)
    try expect(try Data(contentsOf: URL(fileURLWithPath: occupied.path + " 3")) == Data(contentsOf: file), "literal filename or contents changed")
    try expect(try fm.contentsOfDirectory(atPath: occupied.path).isEmpty, "copy nested inside occupied directory")
    let copied = destination.appendingPathComponent("copy-source/nested/.hidden")
    try expect(try Data(contentsOf: copied) == Data(contentsOf: nested), "nested hidden file lost")
    try expect(try fm.attributesOfItem(atPath: copied.path)[.posixPermissions] as? Int == 0o751, "file permissions lost")
    let copiedMetadata = processRunner.run(command("/usr/bin/xattr", ["-p", "com.finderx.test", copied.path]))
    try expect(copiedMetadata.status == .succeeded && copiedMetadata.stdout == "metadata\n", "extended attribute lost")
    try expect(try fm.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("copy-source/nested/link").path) == ".hidden", "nested symlink dereferenced")
    try expect(try fm.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("copy-dangling").path) == "/nonexistent/finderx-copy", "dangling link not copied")
    try expect(try fm.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("copy-directory-link").path) == source.path, "directory link dereferenced")
    try expect(fm.fileExists(atPath: file.path) && fm.fileExists(atPath: nested.path), "source changed")
    try expect(try fm.contentsOfDirectory(atPath: destination.path).allSatisfy { !$0.hasPrefix(".finderx-copy.") }, "staging directory leaked")
    let sameDirectory = runScript("copy-to", [folder.path, file.path])
    try expect(sameDirectory.status == .succeeded && fm.fileExists(atPath: file.path + " 2"), "same-directory file copy failed")
    let repeated = runScript("copy-to", [destination.path, source.path + "/"])
    try expect(repeated.status == .succeeded && fm.fileExists(atPath: destination.appendingPathComponent("copy-source 2/nested/.hidden").path), "directory collision merged or trailing slash changed copy semantics")
}
test("copy-to cancellation and timeout clean up partial staging copies") {
    let source = root.appendingPathComponent("copy-cancel-source")
    let destination = root.appendingPathComponent("copy-cancel-target")
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    for index in 0..<4000 { try Data(repeating: 120, count: 1024).write(to: source.appendingPathComponent("file-\(index)")) }
    let token = CancellationToken()
    let monitor = DispatchGroup()
    monitor.enter()
    DispatchQueue.global().async {
        defer { monitor.leave() }
        let deadline = Date(timeIntervalSinceNow: 5)
        while !token.isCancelled && Date() < deadline {
            if let stage = (try? fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil))?.first(where: { $0.lastPathComponent.hasPrefix(".finderx-copy.") }),
               (try? fm.contentsOfDirectory(atPath: stage.appendingPathComponent("payload").path).count) ?? 0 > 10 {
                token.cancel()
                return
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }
    let arguments = [library.scripts.appendingPathComponent("copy-to.zsh").path, destination.path, source.path]
    let cancelled = processRunner.run(command("/bin/zsh", arguments, timeout: 10), cancellation: token)
    token.cancel()
    monitor.wait()
    try expect(cancelled.status == .cancelled, "copy completed before cancellation was exercised")
    try expect(try fm.contentsOfDirectory(atPath: destination.path).isEmpty, "cancelled copy left partial staging data")
    let timedOut = processRunner.run(command("/bin/zsh", arguments, timeout: 0.05))
    try expect(timedOut.status == .timedOut, "copy timeout not exercised")
    try expect(try fm.contentsOfDirectory(atPath: destination.path).isEmpty, "timed out copy left partial staging data")
    try expect(try fm.contentsOfDirectory(atPath: source.path).count == 4000, "cancellation damaged source files")
}
test("copy-to rejects missing paths, self and descendant destinations including aliases") {
    let source = root.appendingPathComponent("copy-invalid")
    let child = source.appendingPathComponent("child")
    try fm.createDirectory(at: child, withIntermediateDirectories: true)
    let alias = root.appendingPathComponent("copy-alias")
    try fm.createSymbolicLink(at: alias, withDestinationURL: child)
    for destination in [source.path, child.path, alias.path] {
        let result = runScript("copy-to", [destination, source.path])
        try expect(result.status == .failed && result.stderr.contains("自身"), "recursive copy allowed: " + destination)
    }
    try expect(runScript("copy-to", [child.path, "/"]).status == .failed, "root copy allowed")
    try expect(runScript("copy-to", [source.appendingPathComponent("missing").path, file.path]).status == .failed, "missing destination accepted")
    let invalidBatch = runScript("copy-to", [child.path, file.path, source.appendingPathComponent("missing").path])
    try expect(invalidBatch.status == .failed && (try fm.contentsOfDirectory(atPath: child.path)).isEmpty, "invalid batch created partial files")
    try expect(runScript("copy-to", [child.path]).status == .failed, "empty source list accepted")
}
test("move script collision, no-op, descendant check and literal filenames") {
    let destination = root.appendingPathComponent("move-target")
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    let occupied = destination.appendingPathComponent(file.lastPathComponent)
    try Data("occupied".utf8).write(to: occupied)
    let result = runScript("move", [destination.path, file.path])
    try expect(result.status == .succeeded, result.message ?? result.stderr)
    let moved = destination.appendingPathComponent(file.lastPathComponent + " 2")
    try expect(fm.fileExists(atPath: moved.path) && !fm.fileExists(atPath: file.path), "source not moved to suffix")
    try expect(try String(contentsOf: occupied, encoding: .utf8) == "occupied", "existing file overwritten")
    let noop = runScript("move", [destination.path, moved.path])
    try expect(noop.status == .skipped && noop.stdout.contains("已跳过"), "same-directory move not reported as skipped")
    let child = folder.appendingPathComponent("child")
    try fm.createDirectory(at: child, withIntermediateDirectories: true)
    let invalid = runScript("move", [child.path, folder.path])
    try expect(invalid.status == .failed && fm.fileExists(atPath: folder.path), "descendant move allowed")
    try Data("original".utf8).write(to: file)
}
test("symlink preset preserves occupied directories and dangling links") {
    let destination = root.appendingPathComponent("links")
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    let occupied = destination.appendingPathComponent(file.lastPathComponent)
    try fm.createDirectory(at: occupied, withIntermediateDirectories: false)
    try fm.createSymbolicLink(atPath: occupied.path + " 2", withDestinationPath: "/nonexistent/finderx-test")
    let result = runScript("symlink", [destination.path, file.path])
    try expect(result.status == .succeeded, result.message ?? result.stderr)
    try expect(try fm.destinationOfSymbolicLink(atPath: occupied.path + " 3") == file.path, "suffix link not created")
    try expect(try fm.contentsOfDirectory(atPath: occupied.path).isEmpty, "link incorrectly nested into existing directory")
    try rejects { try NativeCommands.moveNoReplace(from: file, to: occupied) }
    try expect(fm.fileExists(atPath: file.path), "exclusive move damaged source")
    let dangling = ActionTarget.read(occupied.path + " 2")
    try expect(dangling.kind == .file, "dangling symlink should remain an actionable file")
}
test("script library preserves user edits across installs") {
    let script = library.scripts.appendingPathComponent("terminal.zsh")
    try Data("# user edit\n".utf8).write(to: script)
    try library.install(from: resources)
    try expect(try String(contentsOf: script, encoding: .utf8) == "# user edit\n", "user script overwritten")
}
test("default scripts migrate exit codes once without restoring deleted files") {
    let directory = root.appendingPathComponent("script-migration")
    let migration = ScriptLibrary(directory: directory)
    try fm.createDirectory(at: migration.scripts, withIntermediateDirectories: true)
    let copyTo = migration.scripts.appendingPathComponent("copy-to.zsh")
    let move = migration.scripts.appendingPathComponent("move.zsh")
    try Data("#!/bin/zsh\n  [[ -n \"$destination\" ]] || { print -r -- '已取消拷贝。'; exit 0; }\n".utf8).write(to: copyTo)
    try Data("#!/bin/zsh\nif true; then\n  print -r -- '已跳过：已经位于目标目录。'\n  exit 0\nfi\n".utf8).write(to: move)
    try migration.migrateDefaultExitCodes()
    try expect(try String(contentsOf: copyTo, encoding: .utf8).contains("exit 130"), "copy-to exit code not migrated")
    try expect(try String(contentsOf: move, encoding: .utf8).contains("exit 100"), "move exit code not migrated")
    try Data("#!/bin/zsh\nexit 0\n".utf8).write(to: copyTo)
    try fm.removeItem(at: move)
    try migration.migrateDefaultExitCodes()
    try expect(try String(contentsOf: copyTo, encoding: .utf8) == "#!/bin/zsh\nexit 0\n", "second migration overwrote user script")
    try expect(!fm.fileExists(atPath: move.path), "second migration restored deleted script")
}
test("FinderX imports legacy configuration and preserves user scripts once") {
    let old = root.appendingPathComponent("legacy-brand")
    let new = root.appendingPathComponent("new-brand")
    try fm.createDirectory(at: old.appendingPathComponent("Scripts/nested"), withIntermediateDirectories: true)
    let body = "#!/bin/zsh\nprintf '%s' \"$SUPERRIGHT_EXECUTABLE\"\n# user edit\n"
    try Data(body.utf8).write(to: old.appendingPathComponent("Scripts/nested/custom.zsh"))
    var config = DefaultConfiguration.make(home: home.path)
    config.menu[0].id = "menu.superright"
    config.menu[0].title = "SuperRight"
    config.actions[0].execution.arguments = [old.appendingPathComponent("Scripts/nested/custom.zsh").path, "{paths}"]
    config.actions[0].execution.requirements = Requirements(paths: ["{home}/Library/Containers/com.superright.app.finder/Data/Library/Application Support/SuperRight/Scripts/nested/custom.zsh"])
    let original = try ConfigurationCodec.encode(config)
    try original.write(to: old.appendingPathComponent("config.json"))
    let migratedLibrary = ScriptLibrary(directory: new)
    try migratedLibrary.migrateLegacy(from: old)
    let result = try ConfigurationCodec.decode(Data(contentsOf: new.appendingPathComponent("config.json")))
    try expect(result.menu[0].id == "menu.finderx" && result.menu[0].title == "FinderX", "root menu not renamed")
    try expect(result.actions[0].execution.arguments?.first == new.appendingPathComponent("Scripts/nested/custom.zsh").path, "absolute script path not migrated")
    try expect(result.actions[0].execution.requirements?.paths?.first == DefaultConfiguration.scriptDirectory + "/nested/custom.zsh", "template script path not migrated")
    try expect(try String(contentsOf: new.appendingPathComponent("Scripts/nested/custom.zsh"), encoding: .utf8) == body, "user script changed")
    try expect(try Data(contentsOf: new.appendingPathComponent("config.superright-backup.json")) == original, "backup changed")
    try expect(try Data(contentsOf: old.appendingPathComponent("config.json")) == original, "old config modified")
    let saved = try Data(contentsOf: new.appendingPathComponent("config.json"))
    try Data("invalid".utf8).write(to: old.appendingPathComponent("config.json"))
    try migratedLibrary.migrateLegacy(from: old)
    try expect(try Data(contentsOf: new.appendingPathComponent("config.json")) == saved, "migration overwrote existing FinderX config")
}
test("custom scripts are checked without running, and syntax failures are rejected") {
    let marker = root.appendingPathComponent("must-not-run")
    let script = try library.create(id: "custom", body: "#!/bin/zsh\n/usr/bin/touch " + ScriptLibrary.shellLiteral(marker.path) + "\n")
    try expect(fm.fileExists(atPath: script.path) && !fm.fileExists(atPath: marker.path), "saving a script executed it")
    try rejects { _ = try library.create(id: "invalid", body: "if then\n") }
    try expect(!fm.fileExists(atPath: library.scripts.appendingPathComponent("invalid.zsh").path), "invalid script was kept")
    let literal = "/Applications/a 'quoted' $(date) app.app"
    let result = processRunner.run(command("/bin/zsh", ["-c", "printf '%s' " + ScriptLibrary.shellLiteral(literal)]))
    try expect(result.stdout == literal, "generated script interpreted app path")
}
test("Dock script escapes Unicode URLs and XML without modifying Dock") {
    let source = try String(contentsOf: resources.appendingPathComponent("Scripts/pin-dock.zsh"), encoding: .utf8)
    let definitions = String(source.components(separatedBy: "for selected_path in")[0])
    let result = processRunner.run(command("/bin/zsh", ["-c", definitions + "\nfile_url \"$1\"; printf '%s\\n' \"$REPLY\"; xml_escape '<&>'; printf '%s' \"$REPLY\"", "test", "/测试 &.txt"]))
    try expect(result.status == .succeeded, result.stderr)
    try expect(result.stdout.contains("file:///%E6%B5%8B%E8%AF%95%20%26.txt"), "bad file URL: " + result.stdout)
    try expect(result.stdout.hasSuffix("&lt;&amp;&gt;"), "bad XML escaping: " + result.stdout)
}
test("partial failure and stop versus continue") {
    let registry = BuiltinRegistry()
    let dispatcher = ActionDispatcher(repository: ConfigurationRepository(url: root.appendingPathComponent("unused"), home: home.path, writable: false), builder: builder, builtins: registry)
    let ok = ExecutionJob(targets: [], payload: .command(command("/usr/bin/true", [])))
    let bad = ExecutionJob(targets: [], payload: .command(command("/usr/bin/false", [])))
    let stop = dispatcher.execute(ExecutionPlan(requestID: UUID(), actionID: "test", title: "test", onError: .stop, jobs: [ok,bad,ok]))
    let continued = dispatcher.execute(ExecutionPlan(requestID: UUID(), actionID: "test", title: "test", onError: .continue, jobs: [ok,bad,ok]))
    try expect(stop.status == .partiallySucceeded && stop.jobs.count == 2, "stop policy failed")
    try expect(continued.status == .partiallySucceeded && continued.jobs.count == 3, "continue policy failed")
}
test("stale configuration rejected and duplicate invocation executes once") {
    let repo = ConfigurationRepository(url: root.appendingPathComponent("dispatch/config.json"), home: home.path, writable: true)
    let action = ActionDefinition(id: "test", title: "test", when: MatchCondition(surfaces: [.items], kinds: [.file]), execution: ExecutionDefinition(type: .command, executable: "/usr/bin/true", arguments: []))
    try repo.save(FrameworkConfiguration(schemaVersion: 1, actions: [action], menu: [DefaultConfiguration.reference(action.id)]))
    let snapshot = try repo.load()
    let dispatcher = ActionDispatcher(repository: repo, builder: builder, builtins: BuiltinRegistry())
    let request = Invocation(actionID: "test", revision: snapshot.revision, context: context)
    var outputs: [ExecutionResult] = []
    dispatcher.submit(request) { outputs.append($0) }
    dispatcher.submit(request) { outputs.append($0) }
    let deadline = Date(timeIntervalSinceNow: 3)
    while outputs.isEmpty && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02)) }
    try expect(outputs.count == 1 && outputs[0].status == .succeeded, "duplicate invocation ran or dispatcher stalled")
    dispatcher.submit(Invocation(actionID: "test", revision: "outdated", context: context)) { outputs.append($0) }
    while outputs.count < 2 && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02)) }
    try expect(outputs.count == 2 && outputs[1].jobs[0].errorCode == "config.changed", "stale configuration executed")
}

test("script exit conventions distinguish cancellation and skips") {
    let cancelled = processRunner.run(command("/bin/zsh", ["-c", "exit 130"]))
    let skipped = processRunner.run(command("/bin/zsh", ["-c", "exit 100"]))
    let failed = processRunner.run(command("/bin/zsh", ["-c", "exit 1"]))
    try expect(cancelled.status == .cancelled && cancelled.errorCode == "process.cancelled", "exit 130 not cancelled")
    try expect(skipped.status == .skipped && skipped.errorCode == nil, "exit 100 not skipped")
    try expect(failed.status == .failed, "exit 1 not failed")
}
test("result summary reports targets, skips and unprocessed items") {
    let first = home.appendingPathComponent("first").path
    let second = home.appendingPathComponent("second").path
    let result = ExecutionResult(requestID: UUID(), actionID: "test", title: "移动",
        startedAt: Date(), finishedAt: Date(), status: .partiallySucceeded,
        jobs: [
            JobResult(targets: [first], status: .succeeded, stdout: "完成"),
            JobResult(targets: [second], status: .skipped, stdout: "已跳过")
        ], requestedCount: 3)
    let summary = result.summary
    for expected in ["完成 1", "跳过 1", "未执行 1", first, second] {
        try expect(summary.contains(expected), "summary missing \(expected): \(summary)")
    }
    let longJobs = (0..<5).map {
        JobResult(targets: [home.appendingPathComponent("item-\($0)").path], status: .succeeded,
            stdout: String(repeating: "x", count: 2048))
    }
    let truncated = ExecutionResult(requestID: UUID(), actionID: "test", title: "测试",
        startedAt: Date(), finishedAt: Date(), status: .succeeded, jobs: longJobs, requestedCount: 5)
    try expect(truncated.summary.contains("结果已截断"), "summary truncation is not disclosed")
}
test("all skipped jobs produce skipped overall status") {
    let registry = BuiltinRegistry()
    let dispatcher = ActionDispatcher(repository: ConfigurationRepository(url: root.appendingPathComponent("unused-skip"), home: home.path, writable: false), builder: builder, builtins: registry)
    let first = ExecutionJob(targets: [], payload: .command(command("/bin/zsh", ["-c", "exit 100"])))
    let second = ExecutionJob(targets: [], payload: .command(command("/bin/zsh", ["-c", "exit 100"])))
    let result = dispatcher.execute(ExecutionPlan(requestID: UUID(), actionID: "test", title: "test", onError: .continue, jobs: [first, second]))
    try expect(result.status == .skipped && result.jobs.allSatisfy { $0.status == .skipped }, "skipped jobs reported as success")
}
test("dependency reasons expose short visible labels") {
    try expect(DependencyAvailability.shortReason("找不到应用：/Applications/LocalSend.app。请安装应用或选择正确路径。") == "应用未安装", "application reason")
    try expect(DependencyAvailability.shortReason("找不到依赖文件：/tmp/script.zsh") == "脚本缺失", "script reason")
    try expect(DependencyAvailability.shortReason("请等待主程序检查脚本依赖，稍后重新打开菜单。") == "正在检查依赖", "wait reason")
}

test("settings toggles, copy targets and send references update configuration") {
    let directory = root.appendingPathComponent("config-store")
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let repo = ConfigurationRepository(url: directory.appendingPathComponent("config.json"), home: home.path, writable: true)
    let store = ConfigStore(repository: repo)
    store.load()
    try expect(store.snapshot != nil, "store failed to load")

    try expect(store.setActionEnabled(id: "send.localsend", enabled: false), "disable send action")
    try expect(store.snapshot?.action("send.localsend")?.isEnabled == false, "disabled action not persisted")
    let hidden = MenuBuilder.build(snapshot: store.snapshot!, context: context)
    func flatten(_ nodes: [MenuModel]) -> [MenuModel] { nodes.flatMap { [$0] + flatten($0.children) } }
    try expect(!flatten(hidden).contains { $0.actionID == "send.localsend" }, "disabled send action still in menu")

    try expect(store.addSendReference(actionID: "clipboard.paths"), "add send reference")
    try expect(store.sendActions.contains { $0.id == "clipboard.paths" }, "send reference missing")
    try expect(store.removeSendReference(actionID: "clipboard.paths"), "remove send reference")
    try expect(!store.sendActions.contains { $0.id == "clipboard.paths" }, "send reference retained")
    try expect(store.snapshot?.action("clipboard.paths") != nil, "removing send reference deleted action")

    var withoutSend = store.snapshot!.configuration
    withoutSend.menu[0].children?.removeAll { $0.id == "menu.send" }
    try repo.save(withoutSend)
    store.load()
    try expect(store.addSendReference(actionID: "send.localsend"), "send group not created")
    try expect(store.actions(inGroup: "menu.send").contains { $0.id == "send.localsend" }, "send group missing action")

    let fixed = DefaultConfiguration.copyAction(name: "归档", path: folder.path)
    var withFixed = store.snapshot!.configuration
    withFixed.actions.append(fixed)
    try repo.save(withFixed)
    store.load()
    try expect(store.copyTargets.contains { $0.id == fixed.id }, "fixed copy target missing")
    try expect(store.removeCopyTarget(actionID: fixed.id), "fixed copy target not removable")
    try expect(store.snapshot?.action(fixed.id) == nil, "fixed copy action retained")
    try expect(store.removeCopyTarget(actionID: "files.copy-to") == false, "chooser must not be removable")

    let copyFolder = root.appendingPathComponent("copy-fixed")
    try fm.createDirectory(at: copyFolder, withIntermediateDirectories: true)
    try expect(store.addCopyTargets(at: [copyFolder]) == [SharedConfig.displayName(for: copyFolder)], "fixed target not added")
    let addedTarget = store.copyTargets.first { $0.path == copyFolder.path }
    try expect(addedTarget != nil, "added fixed target missing")
    try expect(store.addCopyTargets(at: [copyFolder]).isEmpty, "duplicate fixed target added")
    let addedID = addedTarget!.id
    try expect(store.snapshot?.configuration.menu.contains { node in
        node.children?.contains { $0.actionID == addedID } == true
    } == true, "fixed target menu reference missing")
    try expect(store.removeCopyTarget(actionID: addedID), "added fixed target not removable")
    try expect(store.snapshot?.action(addedID) == nil, "added fixed target action retained")
    try expect(store.snapshot?.configuration.menu.contains { node in
        node.children?.contains { $0.actionID == addedID } == true
    } == false, "added fixed target menu reference retained")

    var withoutCopy = store.snapshot!.configuration
    withoutCopy.actions.removeAll { $0.id == "files.copy-to" }
    withoutCopy.menu[0].children?.removeAll { $0.actionID == "files.copy-to" }
    try repo.save(withoutCopy)
    store.load()
    try expect(store.restoreDefaultCopyAction(), "default copy action not restored")
    try expect(store.snapshot?.action("files.copy-to") != nil, "default copy action missing after restore")
}
test("settings list reordering persists menu order and preserves other items") {
    let directory = root.appendingPathComponent("settings-reorder")
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let repo = ConfigurationRepository(url: directory.appendingPathComponent("config.json"), home: home.path, writable: true)
    let store = ConfigStore(repository: repo)
    store.load()
    let fixed = DefaultConfiguration.copyAction(name: "归档", path: folder.path)
    var config = store.snapshot!.configuration
    config.actions.append(fixed)
    config.menu[0].children?.insert(DefaultConfiguration.reference(fixed.id), at: 0)
    let openIndex = config.menu[0].children!.firstIndex { $0.id == "menu.open-with" }!
    config.menu[0].children![openIndex].children = [MenuDefinition(type: .action, id: "test.open.clipboard", actionID: "clipboard.paths"), MenuDefinition(type: .action, id: "test.open.dock", actionID: "dock.pin")]
    try repo.save(config)
    store.load()

    for (group, ids) in [
        ("menu.open-with", store.actions(inGroup: "menu.open-with").map(\.id)),
        ("menu.move", store.destinations.map(\.id)),
        ("menu.finderx", store.copyTargets.map(\.id)),
        ("menu.send", store.sendActions.map(\.id))
    ] {
        let reversed = Array(ids.reversed())
        try expect(store.reorder(group: group, ids: reversed), "reorder failed for \(group)")
        let actual: [String]
        switch group {
        case "menu.move": actual = store.destinations.map(\.id)
        case "menu.finderx": actual = store.copyTargets.map(\.id)
        default: actual = store.actions(inGroup: group).map(\.id)
        }
        try expect(actual == reversed, "display order failed for \(group)")
        let menuIDs = store.actions(inGroup: group).map(\.id).filter { ids.contains($0) }
        try expect(menuIDs == reversed, "menu order failed for \(group)")
    }
    let moveChildren = store.snapshot!.configuration.menu[0].children!.first { $0.id == "menu.move" }!.children!
    try expect(moveChildren.suffix(2).map(\.id) == ["menu.separator.destinations", "menu.app.add-destination"], "non-list items moved")
    try expect(!store.reorder(group: "menu.send", ids: ["send.localsend", "send.localsend"]), "duplicate ids accepted")
    let expected = store.copyTargets.map(\.id)
    let reloaded = ConfigStore(repository: ConfigurationRepository(url: repo.url, home: home.path, writable: true))
    reloaded.load()
    try expect(reloaded.copyTargets.map(\.id) == expected, "order did not persist")
}
test("settings groups follow menu/operation, advanced, overview order") {
    try expect(SettingsSection.groups.map(\.title) == ["菜单与操作", "进阶", "概览"], "group order changed")
    try expect(SettingsSection.groups[0].sections == [.openWith, .destinations, .copyTo, .sendTo], "menu group changed")
    try expect(SettingsSection.groups[1].sections == [.scripts, .advanced], "advanced group changed")
    try expect(SettingsSection.groups[2].sections == [.status], "overview group changed")
}
test("settings navigation history branches and ignores repeated selections") {
    let navigation = SettingsNavigation()
    var changes = 0
    navigation.onSelection = { changes += 1 }
    navigation.goBack()
    navigation.goForward()
    try expect(!navigation.canGoBack && !navigation.canGoForward, "initial history")
    navigation.select(.openWith)
    navigation.select(.scripts)
    navigation.goBack()
    try expect(navigation.section == .openWith && navigation.canGoForward, "back visit")
    navigation.select(.destinations)
    try expect(!navigation.canGoForward, "new visit must discard forward history")
    navigation.select(.destinations)
    navigation.goBack()
    try expect(navigation.section == .openWith, "duplicate visit added to history")
    navigation.goBack()
    navigation.goBack()
    try expect(navigation.section == .status && !navigation.canGoBack, "history boundary")
    navigation.goForward()
    try expect(navigation.section == .openWith && changes == 7, "forward visit and detail callbacks")
}
test("settings search trims whitespace and matches page titles and keywords") {
    try expect(SettingsSection.matching("  ") == SettingsSection.allCases, "blank search")
    try expect(SettingsSection.matching("app") == [.openWith], "case-insensitive keyword")
    try expect(SettingsSection.matching(" 自定义 ") == [.scripts], "trimmed page title")
    try expect(SettingsSection.matching("Finder") == [.advanced, .status], "multiple results retain sidebar order")
    try expect(SettingsSection.matching("no-such-page").isEmpty, "no search results")
}

test("settings search groups keyword suggestions and ranks matching page titles first") {
    let rows = SettingsSection.searchRows("配置")
    try expect(rows.map(\.title) == ["高级", "配置文件", "状态", "配置"], "keyword rows and page headings")
    try expect(rows.filter(\.selectable).map(\.title) == ["配置文件", "配置"], "nonmatching parent must not consume keyboard selection")
    try expect(rows.map(\.id).count == Set(rows.map(\.id)).count, "search row identities")
    try expect(SettingsSection.searchRows("高级").first?.selectable == true, "matching title is selectable")
    try expect(SettingsSection.searchRows("Ａｐｐ").map(\.title) == ["打开方式", "App"], "fullwidth query normalization")
    try expect(SettingsSection.searchRows("  ").isEmpty, "blank query uses normal sidebar")
}

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
