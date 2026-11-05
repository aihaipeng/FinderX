import Foundation
import Darwin

/// macOS mv has no --no-target-directory option. This small CLI primitive gives
/// editable shell scripts an atomic, non-overwriting rename without nesting a
/// source inside a directory which another process just created.
enum NativeCommands {
    static func handle(_ arguments: [String]) -> Int32? {
        guard arguments.first == "--move-no-replace" else { return nil }
        guard arguments.count == 3, arguments[1].hasPrefix("/"), arguments[2].hasPrefix("/") else { return 64 }
        do { try moveNoReplace(from: URL(fileURLWithPath: arguments[1]), to: URL(fileURLWithPath: arguments[2])); return 0 }
        catch {
            let ns = error as NSError
            let exists = ns.domain == NSPOSIXErrorDomain && ns.code == Int(EEXIST)
            if !exists { FileHandle.standardError.write(Data(("移动失败：" + error.localizedDescription + "\n").utf8)) }
            return exists ? 17 : 1
        }
    }

    static func moveNoReplace(from source: URL, to destination: URL) throws {
        func rename(_ source: URL, _ destination: URL) throws {
            let result = source.path.withCString { input in destination.path.withCString { output in renamex_np(input, output, UInt32(RENAME_EXCL)) } }
            if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        do { try rename(source, destination) }
        catch let error as POSIXError where error.code == .EXDEV {
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".finderx-move." + UUID().uuidString)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: staging) }
            let temporary = staging.appendingPathComponent("payload")
            try FileManager.default.copyItem(at: source, to: temporary)
            try rename(temporary, destination)
            do { try FileManager.default.removeItem(at: source) }
            catch { throw FrameworkError(code: "file.partialMove", message: "已复制到 \(destination.path)，但删除源文件失败：\(error.localizedDescription)") }
        }
    }
}
