import Foundation

enum Surface: String, Codable { case items, container, sidebar }
enum TargetKind: String, Codable { case file, directory, unknown }
enum BatchMode: String, Codable { case all, each }
enum ErrorPolicy: String, Codable { case stop, `continue` }
enum ExecutionKind: String, Codable { case command, builtin }
enum MenuKind: String, Codable { case group, action, separator }

struct FrameworkError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { "[\(code)] \(message)" }
}

struct ActionTarget: Codable, Equatable {
    let path: String
    let kind: TargetKind
    var url: URL { URL(fileURLWithPath: path) }

    static func read(_ path: String) -> ActionTarget {
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &directory)
        let link = (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
        return ActionTarget(path: path, kind: exists ? (directory.boolValue ? .directory : .file) : link ? .file : .unknown)
    }
}

struct ActionContext: Codable, Equatable {
    let surface: Surface
    let selection: [ActionTarget]
    let containerPath: String?
    let targets: [ActionTarget]
    let createdAt: Date

    static func capture(surface: Surface, selection: [URL], container: URL?) -> ActionContext {
        var seen = Set<String>()
        let selected = selection.filter { $0.isFileURL }.map { $0.standardizedFileURL.path }
            .filter { seen.insert($0).inserted }.map(ActionTarget.read)
        let directory = container?.isFileURL == true ? container?.standardizedFileURL.path : nil
        let targets = surface == .container ? directory.map { [ActionTarget.read($0)] } ?? [] : selected
        return ActionContext(surface: surface, selection: selected, containerPath: directory,
                             targets: targets, createdAt: Date())
    }

    func refreshed() throws -> ActionContext {
        guard !targets.isEmpty, targets.count <= 128,
              targets.allSatisfy({ $0.path.hasPrefix("/") && !$0.path.utf8.contains(0) }) else {
            throw FrameworkError(code: "context.invalid", message: "选择项为空、过多或路径无效。")
        }
        let updated = targets.map { ActionTarget.read($0.path) }
        guard updated.allSatisfy({ $0.kind != .unknown }) else {
            throw FrameworkError(code: "path.unavailable", message: "所选文件已移动、不可访问或不再存在。")
        }
        return ActionContext(surface: surface, selection: selection, containerPath: containerPath,
                             targets: updated, createdAt: createdAt)
    }
}

struct MatchCondition: Codable {
    var surfaces: [Surface]
    var kinds: [TargetKind]
    var minCount: Int? = nil
    var maxCount: Int? = nil
    var extensions: [String]? = nil
}

struct Requirements: Codable {
    var applications: [String]? = nil
    var paths: [String]? = nil
}

struct InputDefinition: Codable {
    var source: String
    var value: String? = nil
    var separator: String? = nil
    var trailingSeparator: Bool? = nil
}

struct ExecutionDefinition: Codable {
    var type: ExecutionKind
    var executable: String? = nil
    var arguments: [String]? = nil
    var workingDirectory: String? = nil
    var environment: [String: String]? = nil
    var stdin: InputDefinition? = nil
    var timeoutSeconds: Int? = nil
    var successExitCodes: [Int32]? = nil
    var requirements: Requirements? = nil
    var operation: String? = nil
    var parameters: [String: String]? = nil
}

struct ActionDefinition: Codable {
    var id: String
    var title: String
    var icon: String? = nil
    var enabled: Bool? = nil
    var when: MatchCondition
    var batch: BatchMode? = nil
    var onError: ErrorPolicy? = nil
    var execution: ExecutionDefinition
    var isEnabled: Bool { enabled ?? true }
    var batchMode: BatchMode { batch ?? .all }
    var errorPolicy: ErrorPolicy { onError ?? .stop }
}

struct MenuDefinition: Codable {
    var type: MenuKind
    var id: String
    var title: String? = nil
    var icon: String? = nil
    var children: [MenuDefinition]? = nil
    var actionID: String? = nil
    var showWhenEmpty: Bool? = nil
}

struct FrameworkConfiguration: Codable {
    var schemaVersion: Int
    var actions: [ActionDefinition]
    var menu: [MenuDefinition]
}

struct ConfigurationSnapshot {
    let configuration: FrameworkConfiguration
    let revision: String
    func action(_ id: String) -> ActionDefinition? { configuration.actions.first { $0.id == id } }
}

struct Invocation: Codable {
    let requestID: UUID
    let actionID: String
    let configRevision: String
    let context: ActionContext
    let createdAt: Date

    init(actionID: String, revision: String, context: ActionContext) {
        self.requestID = UUID()
        self.actionID = actionID
        self.configRevision = revision
        self.context = context
        self.createdAt = Date()
    }
}

struct CommandJob {
    let executable: String
    let arguments: [String]
    let workingDirectory: String
    let environment: [String: String]
    let input: Data
    let timeout: TimeInterval
    let successExitCodes: [Int32]
}

enum JobPayload {
    case command(CommandJob)
    case builtin(String, [String: String])
}

struct ExecutionJob {
    let targets: [ActionTarget]
    let payload: JobPayload
}

struct ExecutionPlan {
    let requestID: UUID
    let actionID: String
    let title: String
    let onError: ErrorPolicy
    let jobs: [ExecutionJob]
}

enum ResultStatus: String, Codable {
    case succeeded, skipped, failed, partiallySucceeded, cancelled, timedOut
    var displayName: String {
        switch self {
        case .succeeded: return "成功"
        case .skipped: return "已跳过"
        case .failed: return "失败"
        case .partiallySucceeded: return "部分完成"
        case .cancelled: return "已取消"
        case .timedOut: return "超时"
        }
    }
}

struct JobResult: Codable {
    var targets: [String]
    var status: ResultStatus
    var exitCode: Int32? = nil
    var stdout: String = ""
    var stderr: String = ""
    var stdoutTruncated: Bool = false
    var stderrTruncated: Bool = false
    var errorCode: String? = nil
    var message: String? = nil
}

struct ExecutionResult: Codable {
    let requestID: UUID
    let actionID: String
    let title: String
    let startedAt: Date
    let finishedAt: Date
    let status: ResultStatus
    let jobs: [JobResult]
    var requestedCount: Int? = nil

    private func count(_ status: ResultStatus) -> Int {
        jobs.reduce(0) { total, job in
            guard job.status == status else { return total }
            return total + max(1, job.targets.count)
        }
    }

    var summary: String {
        let completed = count(.succeeded)
        let skipped = count(.skipped)
        let failed = count(.failed) + count(.timedOut)
        let cancelled = count(.cancelled)
        var counts = ["完成 \(completed)"]
        if skipped > 0 { counts.append("跳过 \(skipped)") }
        if failed > 0 { counts.append("失败 \(failed)") }
        if cancelled > 0 { counts.append("取消 \(cancelled)") }
        let processed = jobs.reduce(0) { $0 + max(1, $1.targets.count) }
        let unprocessed = max(0, (requestedCount ?? processed) - processed)
        if unprocessed > 0 { counts.append("未执行 \(unprocessed)") }
        let raw = jobs.map { job -> String in
            let targets = job.targets.map { ($0 as NSString).abbreviatingWithTildeInPath }
                .joined(separator: "、")
            let output = [job.message, job.stdout.isEmpty ? nil : String(job.stdout.prefix(2048)),
                          job.message == nil && !job.stderr.isEmpty ? String(job.stderr.prefix(2048)) : nil]
                .compactMap { $0 }.joined(separator: "\n")
            return [targets, output].filter { !$0.isEmpty }.joined(separator: "\n")
        }.filter { !$0.isEmpty }.joined(separator: "\n")
        let details = raw.count > 8192
            ? String(raw.prefix(8192)) + "\n…（结果已截断）"
            : raw
        return "\(title)：\(status.displayName)（\(counts.joined(separator: "，"))）" +
            (details.isEmpty ? "" : "\n\(details)")
    }
}
