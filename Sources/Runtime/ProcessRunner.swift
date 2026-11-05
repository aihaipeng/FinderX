import Foundation
import Darwin

final class CancellationToken {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

/// One nonblocking pump services stdin, stdout, stderr and the timeout together.
/// posix_spawn creates a process group so cancellation also reaches script children.
struct ProcessRunner {
    let outputLimit = 65_536

    func run(_ job: CommandJob, targets: [String] = [], cancellation: CancellationToken = CancellationToken()) -> JobResult {
        if cancellation.isCancelled { return JobResult(targets: targets, status: .cancelled) }
        var input: [Int32] = [-1, -1], output: [Int32] = [-1, -1], error: [Int32] = [-1, -1]
        guard pipe(&input) == 0, pipe(&output) == 0, pipe(&error) == 0 else {
            for fd in input + output + error where fd >= 0 { close(fd) }
            return JobResult(targets: targets, status: .failed, errorCode: "process.startFailed", message: "无法创建命令管道。")
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, error[1], STDERR_FILENO)
        let directoryError = job.workingDirectory.withCString {
            if #available(macOS 26.0, *) { return posix_spawn_file_actions_addchdir(&actions, $0) }
            return posix_spawn_file_actions_addchdir_np(&actions, $0)
        }
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv = ([job.executable] + job.arguments).map { strdup($0) } + [nil]
        let env = job.environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in argv + env { if let pointer { free(pointer) } } }
        var pid: pid_t = 0
        let spawnError = directoryError != 0 ? directoryError : job.executable.withCString { executable in
            argv.withUnsafeBufferPointer { arguments in
                env.withUnsafeBufferPointer { environment in
                    posix_spawn(&pid, executable, &actions, &attributes,
                                UnsafeMutablePointer(mutating: arguments.baseAddress!), UnsafeMutablePointer(mutating: environment.baseAddress!))
                }
            }
        }
        close(input[0]); close(output[1]); close(error[1])
        guard spawnError == 0 else {
            close(input[1]); close(output[0]); close(error[0])
            return JobResult(targets: targets, status: .failed, errorCode: "process.startFailed", message: String(cString: strerror(spawnError)))
        }
        var inputFD = input[1], outputFD = output[0], errorFD = error[0]
        for fd in [inputFD, outputFD, errorFD] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        _ = fcntl(inputFD, F_SETNOSIGPIPE, 1)
        defer { for fd in [inputFD, outputFD, errorFD] where fd >= 0 { close(fd) } }
        var stdout = Data(), stderr = Data()
        var stdoutTruncated = false, stderrTruncated = false
        var offset = 0
        var status: Int32 = 0
        var exited = false
        var exitTime: TimeInterval?
        var terminationTime: TimeInterval?
        var forcedStatus: ResultStatus?
        let started = ProcessInfo.processInfo.systemUptime
        func drain(_ fd: inout Int32, _ capture: inout Data, _ truncated: inout Bool) {
            guard fd >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            for _ in 0..<8 {
                let size = Darwin.read(fd, &buffer, buffer.count)
                if size > 0 {
                    let saved = min(size, max(0, outputLimit - capture.count))
                    capture.append(contentsOf: buffer.prefix(saved))
                    if saved < size { truncated = true }
                } else if size == 0 { close(fd); fd = -1; break }
                else if errno == EINTR { continue }
                else if errno == EAGAIN || errno == EWOULDBLOCK { break }
                else { close(fd); fd = -1; break }
            }
        }
        while !exited || outputFD >= 0 || errorFD >= 0 {
            let now = ProcessInfo.processInfo.systemUptime
            if forcedStatus == nil && (cancellation.isCancelled || now - started >= job.timeout) {
                forcedStatus = cancellation.isCancelled ? .cancelled : .timedOut
                terminationTime = now
                kill(-pid, SIGTERM)
            }
            if let time = terminationTime, now - time >= 0.5 { kill(-pid, SIGKILL) }
            if inputFD >= 0 {
                if offset >= job.input.count || exited || forcedStatus != nil { close(inputFD); inputFD = -1 }
                else {
                    let count = job.input.withUnsafeBytes { bytes in Darwin.write(inputFD, bytes.baseAddress!.advanced(by: offset), min(16_384, job.input.count - offset)) }
                    if count > 0 { offset += count }
                    else if count < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK { close(inputFD); inputFD = -1 }
                }
            }
            drain(&outputFD, &stdout, &stdoutTruncated)
            drain(&errorFD, &stderr, &stderrTruncated)
            if !exited {
                let waited = waitpid(pid, &status, WNOHANG)
                if waited == pid { exited = true; exitTime = now }
            }
            // A script may leave children holding its pipes open. They are managed
            // members of this group; do not let them keep the runner alive forever.
            if let end = exitTime, now - end >= 0.2, outputFD >= 0 || errorFD >= 0 {
                if terminationTime == nil { terminationTime = now; kill(-pid, SIGTERM) }
                if now - end >= 2 {
                    kill(-pid, SIGKILL)
                    if outputFD >= 0 { close(outputFD); outputFD = -1; stdoutTruncated = true }
                    if errorFD >= 0 { close(errorFD); errorFD = -1; stderrTruncated = true }
                }
            }
            if !exited || outputFD >= 0 || errorFD >= 0 { Thread.sleep(forTimeInterval: 0.005) }
        }
        // Also stop descendants which redirected their output and outlived the job.
        kill(-pid, SIGKILL)
        let signalled = status & 0x7f
        let code = signalled == 0 ? (status >> 8) & 0xff : 128 + signalled
        let success = signalled == 0 && job.successExitCodes.contains(code)
        let resultStatus = forcedStatus ?? (success ? .succeeded : .failed)
        let errorText = String(decoding: stderr, as: UTF8.self)
        return JobResult(targets: targets, status: resultStatus, exitCode: code,
            stdout: String(decoding: stdout, as: UTF8.self), stderr: errorText,
            stdoutTruncated: stdoutTruncated, stderrTruncated: stderrTruncated,
            errorCode: resultStatus == .succeeded ? nil : resultStatus == .timedOut ? "process.timedOut" : resultStatus == .cancelled ? "process.cancelled" : "process.failed",
            message: resultStatus == .succeeded ? (job.executable == "/usr/bin/open" ? "已提交打开请求。" : nil)
                : resultStatus == .timedOut ? "命令执行超时。" : resultStatus == .cancelled ? "操作已取消。" : "退出码 \(code)：\(String(errorText.prefix(2048)))")
    }
}
