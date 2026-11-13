import Darwin
import Foundation

struct QuotaSnapshot: Equatable, Sendable {
    let usedPercent: Double
    let resetsAt: Date
}

enum QuotaClientError: LocalizedError {
    case cliUnavailable
    case timeout
    case rpcFailed
    case weeklyUnavailable

    var errorDescription: String? {
        switch self {
        case .cliUnavailable: "找不到 Codex 内置命令行"
        case .timeout: "读取额度超时"
        case .rpcFailed: "无法读取 Codex 额度"
        case .weeklyUnavailable: "未返回有效的周额度"
        }
    }
}

/// 只调用本机 Codex 的只读额度接口，不解析凭据、聊天记录或兑换重置卡。
struct QuotaClient: Sendable {
    private let executableURL: URL
    private let timeout: TimeInterval

    init(executableURL: URL? = nil, timeout: TimeInterval = 15) {
        self.executableURL = executableURL ?? URL(fileURLWithPath:
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        self.timeout = timeout
    }

    func readWeekly() async throws -> QuotaSnapshot {
        try await Task.detached(priority: .utility) { try self.read() }.value
    }

    static func decodeWeekly(_ data: Data) throws -> QuotaSnapshot {
        guard let reply = try? JSONDecoder().decode(WeeklyReply.self, from: data), reply.id == 2,
              reply.error == nil, let result = reply.result else {
            throw QuotaClientError.rpcFailed
        }
        let legacy = result.rateLimits
        let fallback = legacy?.limitId == nil || legacy?.limitId == "codex" ? legacy : nil
        guard let limits = result.rateLimitsByLimitId?["codex"] ?? fallback,
              let window = [limits.primary, limits.secondary].compactMap({ $0 }).first(where: {
                  $0.windowDurationMins == 10_080
              }),
              let used = window.usedPercent, (0...100).contains(used),
              let reset = window.resetsAt, reset > 0 else {
            throw QuotaClientError.weeklyUnavailable
        }
        return QuotaSnapshot(usedPercent: used, resetsAt: Date(timeIntervalSince1970: TimeInterval(reset)))
    }

    private func read() throws -> QuotaSnapshot {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw QuotaClientError.cliUnavailable
        }
        let child = Process()
        let input = Pipe()
        let output = Pipe()
        child.executableURL = executableURL
        child.arguments = ["-s", "read-only", "-a", "never", "app-server", "--listen", "stdio://"]
        child.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice

        let writer = input.fileHandleForWriting
        let reader = output.fileHandleForReading
        // 对端退出时将 SIGPIPE 转成普通写入错误，避免关闭浮窗进程。
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        do { try child.run() } catch { throw QuotaClientError.cliUnavailable }
        defer {
            try? writer.close()
            try? reader.close()
            if child.isRunning { child.terminate() }
            for _ in 0..<10 where child.isRunning { Thread.sleep(forTimeInterval: 0.02) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
        }

        var transport = JSONLineTransport(
            writer: writer,
            reader: reader,
            deadline: ProcessInfo.processInfo.systemUptime + timeout)
        try transport.send(#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex_quota_overlay","version":"0.1.0"}}}"#)
        _ = try transport.receive(id: 1)
        try transport.send(#"{"method":"initialized"}"#)
        try transport.send(#"{"id":2,"method":"account/rateLimits/read","params":null}"#)
        return try Self.decodeWeekly(transport.receive(id: 2))
    }
}

private struct WeeklyReply: Decodable {
    struct RPCError: Decodable {}
    struct Payload: Decodable {
        let rateLimits: Limits?
        let rateLimitsByLimitId: [String: Limits]?
    }
    struct Limits: Decodable {
        let limitId: String?
        let primary: Window?
        let secondary: Window?
    }
    struct Window: Decodable {
        let usedPercent: Double?
        let windowDurationMins: Int?
        let resetsAt: Int64?
    }
    let id: Int
    let error: RPCError?
    let result: Payload?
}

private struct JSONLineTransport {
    private struct Header: Decodable {
        let id: Int
        let error: WeeklyReply.RPCError?
    }

    let writer: FileHandle
    let reader: FileHandle
    let deadline: TimeInterval
    private var buffer = Data()

    init(writer: FileHandle, reader: FileHandle, deadline: TimeInterval) {
        self.writer = writer
        self.reader = reader
        self.deadline = deadline
    }

    func send(_ line: String) throws {
        do { try writer.write(contentsOf: Data((line + "\n").utf8)) }
        catch { throw QuotaClientError.rpcFailed }
    }

    mutating func receive(id: Int) throws -> Data {
        let decoder = JSONDecoder()
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw QuotaClientError.timeout }
            if let end = buffer.firstIndex(of: 10) {
                let line = buffer[..<end]
                buffer.removeSubrange(...end)
                guard let header = try? decoder.decode(Header.self, from: line), header.id == id else { continue }
                guard header.error == nil else { throw QuotaClientError.rpcFailed }
                return line
            }

            var descriptor = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1000 + 1, Double(Int32.max))))
            if result < 0 && errno == EINTR { continue }
            if result == 0 { throw QuotaClientError.timeout }
            guard result > 0, descriptor.revents & Int16(POLLIN) != 0 else {
                throw QuotaClientError.rpcFailed
            }

            // read(upToCount:) 可能等到凑满请求长度；availableData 在可读时只取已到达的字节。
            let chunk = reader.availableData
            guard !chunk.isEmpty, buffer.count + chunk.count <= 512 * 1024 else {
                throw QuotaClientError.rpcFailed
            }
            buffer.append(chunk)
        }
    }
}
