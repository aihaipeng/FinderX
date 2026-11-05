import Cocoa
import ApplicationServices

// This runs against the installed Finder extension, not an in-process menu mock.
// Usage: finder-smoke PATH FinderX [GROUP ...] ACTION
setbuf(stdout, nil)
let arguments = Array(CommandLine.arguments.dropFirst())
func fail(_ message: String) -> Never { fputs(message + "\n", stderr); exit(1) }
guard arguments.count >= 3, arguments[0].hasPrefix("/") else { fail("Usage: scripts/finder-smoke.sh /absolute/path FinderX [group ...] action") }
guard AXIsProcessTrusted() else { fail("当前终端需要已有的辅助功能权限才能操作 Finder 菜单。") }
guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { fail("Finder 未运行。") }
let root = AXUIElementCreateApplication(finder.processIdentifier)
AXUIElementSetMessagingTimeout(root, 2)
func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, key as CFString, &value)
    return value
}
func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func find(_ node: AXUIElement, roles: Set<String>, name: String, depth: Int = 0) -> AXUIElement? {
    guard depth < 20 else { return nil }
    let role = attribute(node, kAXRoleAttribute) as? String ?? ""
    let names = [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute].compactMap { attribute(node, $0) as? String }
    if roles.contains(role) && names.contains(name) { return node }
    for child in children(node) { if let found = find(child, roles: roles, name: name, depth: depth + 1) { return found } }
    return nil
}
func windows() -> [AXUIElement] { attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? [] }
let resultURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
    "Library/Containers/com.finderx.app.finder/Data/Library/Application Support/FinderX/last-execution.json")
func result() -> [String: Any]? {
    guard let data = try? Data(contentsOf: resultURL) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}
let previousID = result()?["requestID"] as? String
let target = URL(fileURLWithPath: arguments[0])
NSWorkspace.shared.activateFileViewerSelecting([target])
Thread.sleep(forTimeInterval: 0.8)
guard let window = windows().first, let item = find(window, roles: ["AXTextField", "AXImage"], name: target.lastPathComponent) else { fail("找不到 Finder 中的目标项：\(target.lastPathComponent)") }
// Some macOS releases return cannotComplete while leaving the menu visible.
// Verify the actual menu rather than treating that AX return code as the outcome.
_ = AXUIElementPerformAction(item, kAXShowMenuAction as CFString)
Thread.sleep(forTimeInterval: 0.3)
for title in arguments.dropFirst() {
    let deadline = Date(timeIntervalSinceNow: 3)
    var element: AXUIElement?
    repeat {
        element = windows().compactMap { find($0, roles: ["AXMenuItem"], name: title) }.first
        if element == nil { Thread.sleep(forTimeInterval: 0.05) }
    } while element == nil && Date() < deadline
    guard let element else { fail("右键菜单中找不到：\(title)") }
    guard attribute(element, kAXEnabledAttribute) as? Bool != false else { fail("菜单项已禁用：\(title)") }
    let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard status == .success else { fail("菜单点击失败：\(title)，AX \(status.rawValue)") }
    print("Clicked: \(title)")
    Thread.sleep(forTimeInterval: 0.3)
}
let deadline = Date(timeIntervalSinceNow: 35)
while Date() < deadline {
    if let output = result(), let id = output["requestID"] as? String, id != previousID {
        guard let jobs = output["jobs"] as? [[String: Any]], jobs.contains(where: { ($0["targets"] as? [String])?.contains(target.path) == true }) else { fail("收到其他操作的结果，未通过本次验证。") }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
        guard output["status"] as? String == "succeeded" else { fail("动作失败，见上方真实执行结果。") }
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.1)
}
fail("点击后 35 秒内没有对应执行结果：Finder → 主程序链路失败。")
