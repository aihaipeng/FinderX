import Foundation

final class BuiltinRegistry {
    typealias Handler = ([ActionTarget], [String: String]) throws -> JobResult
    private var handlers: [String: Handler] = [:]
    func register(_ name: String, handler: @escaping Handler) { handlers[name] = handler }
    func run(_ name: String, parameters: [String: String], targets: [ActionTarget]) throws -> JobResult {
        guard let handler = handlers[name] else { throw FrameworkError(code: "action.unavailable", message: "未注册操作：\(name)") }
        return try handler(targets, parameters)
    }
}

final class ActionDispatcher {
    private let queue = DispatchQueue(label: "com.finderx.actions", qos: .userInitiated)
    private let repository: ConfigurationRepository
    private let builder: PlanBuilder
    private let builtins: BuiltinRegistry
    private let lock = NSLock()
    private var tokens: [UUID: CancellationToken] = [:]
    // IDs are also consumed durably by InvocationTransport before being submitted.
    private var seen = Set<UUID>()

    init(repository: ConfigurationRepository, builder: PlanBuilder, builtins: BuiltinRegistry) {
        self.repository = repository; self.builder = builder; self.builtins = builtins
    }

    func submit(_ invocation: Invocation, completion: @escaping (ExecutionResult) -> Void) {
        lock.lock()
        guard seen.insert(invocation.requestID).inserted else { lock.unlock(); return }
        let token = CancellationToken()
        tokens[invocation.requestID] = token
        lock.unlock()
        queue.async { [self] in
            let started = Date()
            let result: ExecutionResult
            do {
                let snapshot = try repository.load()
                guard snapshot.revision == invocation.configRevision else { throw FrameworkError(code: "config.changed", message: "配置已更新，请重新打开右键菜单。") }
                guard let action = snapshot.action(invocation.actionID) else { throw FrameworkError(code: "action.missing", message: "动作不存在。") }
                let context = try invocation.context.refreshed()
                let plan = try builder.build(action: action, context: context, requestID: invocation.requestID)
                result = execute(plan, cancellation: token, startedAt: started)
            } catch {
                result = ExecutionResult(requestID: invocation.requestID, actionID: invocation.actionID, title: "FinderX",
                    startedAt: started, finishedAt: Date(), status: .failed,
                    jobs: [JobResult(targets: invocation.context.targets.map(\.path), status: .failed,
                        errorCode: (error as? FrameworkError)?.code ?? "action.failed", message: error.localizedDescription)],
                    requestedCount: invocation.context.targets.count)
            }
            lock.lock(); tokens.removeValue(forKey: invocation.requestID); lock.unlock()
            DispatchQueue.main.async { completion(result) }
        }
    }

    func cancelAll() { lock.lock(); let values = Array(tokens.values); lock.unlock(); values.forEach { $0.cancel() } }

    func execute(_ plan: ExecutionPlan, cancellation: CancellationToken = CancellationToken(), startedAt: Date = Date()) -> ExecutionResult {
        var results: [JobResult] = []
        for job in plan.jobs {
            if cancellation.isCancelled { break }
            let result: JobResult
            do {
                switch job.payload {
                case .command(let command): result = ProcessRunner().run(command, targets: job.targets.map(\.path), cancellation: cancellation)
                case .builtin(let operation, let parameters): result = try builtins.run(operation, parameters: parameters, targets: job.targets)
                }
            } catch {
                result = JobResult(targets: job.targets.map(\.path), status: .failed,
                    errorCode: (error as? FrameworkError)?.code ?? "file.failed", message: error.localizedDescription)
            }
            results.append(result)
            if result.status == .cancelled || result.status == .timedOut { break }
            if result.status == .failed && plan.onError == .stop { break }
        }
        let status: ResultStatus
        if results.last?.status == .timedOut { status = .timedOut }
        else if cancellation.isCancelled || results.last?.status == .cancelled { status = .cancelled }
        else if results.contains(where: { $0.status == .failed }) {
            status = results.contains(where: { $0.status == .succeeded }) ? .partiallySucceeded : .failed
        } else if !results.isEmpty && results.allSatisfy({ $0.status == .skipped }) { status = .skipped }
        else { status = .succeeded }
        return ExecutionResult(requestID: plan.requestID, actionID: plan.actionID, title: plan.title,
            startedAt: startedAt, finishedAt: Date(), status: status, jobs: results,
            requestedCount: plan.jobs.reduce(0) { $0 + $1.targets.count })
    }
}
