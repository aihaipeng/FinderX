import Foundation

enum Template {
    static func literal(_ text: String) -> String { text.replacingOccurrences(of: "{", with: "{{").replacingOccurrences(of: "}", with: "}}") }
    enum Part { case literal(String), variable(String) }
    static let variables: Set<String> = ["paths", "path", "name", "parent", "container", "home"]

    static func parse(_ string: String) throws -> [Part] {
        var parts: [Part] = []
        var literal = ""
        var index = string.startIndex
        while index < string.endIndex {
            let character = string[index]
            let next = string.index(after: index)
            if character == "{" || character == "}" {
                if next < string.endIndex && string[next] == character {
                    literal.append(character)
                    index = string.index(after: next)
                    continue
                }
                guard character == "{", let end = string[next...].firstIndex(of: "}") else {
                    throw FrameworkError(code: "config.invalid", message: "模板花括号不匹配：\(string)")
                }
                if !literal.isEmpty { parts.append(.literal(literal)); literal = "" }
                let name = String(string[next..<end])
                guard variables.contains(name) else {
                    throw FrameworkError(code: "config.invalid", message: "未知变量 {\(name)}。")
                }
                parts.append(.variable(name))
                index = string.index(after: end)
            } else {
                literal.append(character)
                index = next
            }
        }
        if !literal.isEmpty { parts.append(.literal(literal)) }
        return parts
    }

    static func names(in string: String) throws -> [String] {
        try parse(string).compactMap { if case .variable(let name) = $0 { return name }; return nil }
    }

    static func expand(_ string: String, values: [String: String]) throws -> String {
        try parse(string).map { part in
            switch part {
            case .literal(let text): return text
            case .variable(let name):
                guard let value = values[name] else {
                    throw FrameworkError(code: "context.mismatch", message: "本次操作无法解析变量 {\(name)}。")
                }
                return value
            }
        }.joined()
    }
}

struct PlanBuilder {
    let home: String
    var applicationExists: (String) -> Bool = { _ in true }
    var helperExecutable: String = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]

    func checkDependencies(_ execution: ExecutionDefinition) throws {
        let stable = ["home": home]
        if let executable = execution.executable {
            let expanded = try Template.expand(executable, values: stable)
            guard FileManager.default.isExecutableFile(atPath: expanded) else { throw FrameworkError(code: "dependency.missing", message: "命令不存在或不可执行：\(expanded)") }
        }
        for app in execution.requirements?.applications ?? [] {
            let expanded = try Template.expand(app, values: stable)
            guard applicationExists(expanded) else { throw FrameworkError(code: "dependency.missing", message: "找不到应用：\(expanded)。请安装应用或选择正确路径。") }
        }
        for path in execution.requirements?.paths ?? [] {
            let expanded = try Template.expand(path, values: stable)
            guard FileManager.default.fileExists(atPath: expanded) else { throw FrameworkError(code: "dependency.missing", message: "找不到依赖文件：\(expanded)") }
        }
    }

    func build(action: ActionDefinition, context: ActionContext, requestID: UUID = UUID()) throws -> ExecutionPlan {
        guard ConditionMatcher.matches(action, context: context) else {
            throw FrameworkError(code: "context.mismatch", message: "动作不适用于本次选择。")
        }
        let groups = action.batchMode == .all ? [context.targets] : context.targets.map { [$0] }
        guard groups.count <= 128 else { throw FrameworkError(code: "context.limit", message: "一次最多处理 128 个任务。") }
        let execution = action.execution
        let stable = ["home": home]
        try checkDependencies(execution)
        let jobs = try groups.map { targets -> ExecutionJob in
            var values = stable
            values["container"] = context.containerPath
            if targets.count == 1, let target = targets.first {
                values["path"] = target.path
                values["name"] = target.url.lastPathComponent
                values["parent"] = target.url.deletingLastPathComponent().path
            }
            if execution.type == .builtin {
                var parameters: [String: String] = [:]
                for (key, value) in execution.parameters ?? [:] { parameters[key] = try Template.expand(value, values: values) }
                return ExecutionJob(targets: targets, payload: .builtin(execution.operation!, parameters))
            }
            let executable = try Template.expand(execution.executable!, values: stable)
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                throw FrameworkError(code: "dependency.missing", message: "命令不存在或不可执行：\(executable)")
            }
            var arguments: [String] = []
            for argument in execution.arguments! {
                if argument == "{paths}" { arguments.append(contentsOf: targets.map(\.path)) }
                else { arguments.append(try Template.expand(argument, values: values)) }
            }
            guard arguments.count <= 256, arguments.reduce(0, { $0 + $1.utf8.count + 1 }) <= 65_536 else {
                throw FrameworkError(code: "context.limit", message: "参数超过上限，请减少选择项。")
            }
            let directory = try Template.expand(execution.workingDirectory ?? "{home}", values: values)
            var isDirectory: ObjCBool = false
            guard directory.hasPrefix("/"), FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
                  isDirectory.boolValue else { throw FrameworkError(code: "path.unavailable", message: "工作目录不存在：\(directory)") }
            var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home,
                               "USER": NSUserName(), "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8",
                               "FINDERX_EXECUTABLE": helperExecutable,
                               // Existing user scripts keep working after the rename.
                               "SUPERRIGHT_EXECUTABLE": helperExecutable]
            for (key, value) in execution.environment ?? [:] { environment[key] = try Template.expand(value, values: values) }
            var input = Data()
            if let definition = execution.stdin {
                let text: String
                if definition.source == "paths" {
                    let separator = definition.separator ?? "\n"
                    text = targets.map(\.path).joined(separator: separator) + ((definition.trailingSeparator ?? false) ? separator : "")
                } else { text = try Template.expand(definition.value ?? "", values: values) }
                input = Data(text.utf8)
            }
            guard input.count <= 1_048_576 else { throw FrameworkError(code: "context.limit", message: "标准输入超过 1 MiB。") }
            guard !([executable, directory] + arguments + Array(environment.values)).contains(where: { $0.utf8.contains(0) }) else {
                throw FrameworkError(code: "config.invalid", message: "命令参数不能包含 NUL 字符。")
            }
            return ExecutionJob(targets: targets, payload: .command(CommandJob(executable: executable, arguments: arguments,
                workingDirectory: directory, environment: environment, input: input,
                timeout: Double(execution.timeoutSeconds ?? 30), successExitCodes: execution.successExitCodes ?? [0])))
        }
        return ExecutionPlan(requestID: requestID, actionID: action.id, title: action.title, onError: action.errorPolicy, jobs: jobs)
    }
}
