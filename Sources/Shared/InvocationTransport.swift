import Foundation
import Darwin

/// The URL contains only an opaque UUID. Commands and contexts are read exclusively
/// from a bounded, private, same-user request file in the extension container.
/// This is a local transport, not code-signature authentication of the sender.
struct InvocationTransport {
    let directory: URL
    private var requests: URL { directory.appendingPathComponent("Requests", isDirectory: true) }

    func enqueue(_ invocation: Invocation) throws -> URL {
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(invocation)
        guard data.count <= 524_288 else { throw FrameworkError(code: "request.limit", message: "所选路径过多。") }
        let path = requests.appendingPathComponent(invocation.requestID.uuidString + ".json")
        let temporary = requests.appendingPathComponent(UUID().uuidString + ".pending")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard renamex_np(temporary.path, path.path, UInt32(RENAME_EXCL)) == 0 else {
            throw FrameworkError(code: "request.invalid", message: "无法发布动作请求。")
        }
        var components = URLComponents()
        components.scheme = "finderx"; components.host = "invoke"
        components.queryItems = [URLQueryItem(name: "request", value: invocation.requestID.uuidString)]
        return components.url!
    }

    func take(_ url: URL) throws -> Invocation? {
        guard url.scheme == "finderx", url.host == "invoke", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.count == 1, components.queryItems?.first?.name == "request",
              let value = components.queryItems?.first?.value, let id = UUID(uuidString: value) else {
            throw FrameworkError(code: "request.invalid", message: "无效的动作请求。")
        }
        let path = requests.appendingPathComponent(id.uuidString + ".json").path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 && errno == ENOENT { return nil } // consumed or never existed
        guard fd >= 0 else { throw FrameworkError(code: "request.invalid", message: "无法读取请求文件。") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), (info.st_mode & S_IFMT) == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 524_288 else {
            throw FrameworkError(code: "request.invalid", message: "请求文件类型、权限或大小无效。")
        }
        // Consume before decoding/execution: a replay cannot run a file action twice,
        // including after restarting the host. Failed jobs are not auto-retried.
        guard unlink(path) == 0 else { return nil }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while data.count <= 524_288 {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw FrameworkError(code: "request.invalid", message: "请求读取失败。")
            }
            data.append(contentsOf: bytes.prefix(count))
        }
        guard data.count <= 524_288 else { throw FrameworkError(code: "request.limit", message: "请求超过大小上限。") }
        let invocation = try JSONDecoder().decode(Invocation.self, from: data)
        guard invocation.requestID == id, abs(invocation.createdAt.timeIntervalSinceNow) <= 60 else {
            throw FrameworkError(code: "request.expired", message: "请求已过期，请重新打开右键菜单。")
        }
        return invocation
    }

    func removeExpired() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: requests, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files where file.pathExtension == "json" {
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(date) > 120 { try? FileManager.default.removeItem(at: file) }
        }
    }
}
