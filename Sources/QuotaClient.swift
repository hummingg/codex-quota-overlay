import Darwin
import Foundation

struct QuotaWindow: Equatable, Sendable {
    let usedPercent: Double
    let resetsAt: Date?
}

enum QuotaCredits: Equatable, Sendable {
    case balance(String)
    case unlimited
    case noBalance
}

struct QuotaSnapshot: Equatable, Sendable {
    let fiveHour: QuotaWindow?
    let weekly: QuotaWindow?
    let credits: QuotaCredits?
}

enum QuotaClientError: LocalizedError {
    case cliUnavailable
    case timeout
    case rpcFailed
    case quotaUnavailable

    var errorDescription: String? {
        switch self {
        case .cliUnavailable: "找不到 Codex 内置命令行"
        case .timeout: "读取额度超时"
        case .rpcFailed: "无法读取 Codex 额度"
        case .quotaUnavailable: "未返回可显示的 Codex 额度"
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

    func read() async throws -> QuotaSnapshot {
        try await Task.detached(priority: .utility) { try self.requestSnapshot() }.value
    }

    static func decode(_ data: Data) throws -> QuotaSnapshot {
        guard let reply = try? JSONDecoder().decode(QuotaReply.self, from: data), reply.id == 2,
              reply.error == nil, let result = reply.result else {
            throw QuotaClientError.rpcFailed
        }
        let legacy = result.rateLimits
        let fallback = legacy?.limitId == nil || legacy?.limitId == "codex" ? legacy : nil
        guard let limits = result.rateLimitsByLimitId?.codex ?? fallback else {
            throw QuotaClientError.quotaUnavailable
        }
        let windows = [limits.primary, limits.secondary].compactMap { $0 }
        let fiveHour = windows.first { $0.windowDurationMins == 300 && $0.displayWindow != nil }?.displayWindow
        let weekly = windows.first { $0.windowDurationMins == 10_080 && $0.displayWindow != nil }?.displayWindow
        let credits = limits.credits?.displayBalance
        guard fiveHour != nil || weekly != nil || credits != nil else {
            throw QuotaClientError.quotaUnavailable
        }
        return QuotaSnapshot(fiveHour: fiveHour, weekly: weekly, credits: credits)
    }

    private func requestSnapshot() throws -> QuotaSnapshot {
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
        return try Self.decode(transport.receive(id: 2))
    }
}

private struct QuotaReply: Decodable {
    struct RPCError: Decodable {}
    struct Payload: Decodable {
        let rateLimits: Limits?
        let rateLimitsByLimitId: Buckets?
    }
    struct Buckets: Decodable {
        let codex: Limits?
    }
    struct Limits: Decodable {
        let limitId: String?
        let primary: Window?
        let secondary: Window?
        let credits: Credits?

        private enum CodingKeys: String, CodingKey {
            case limitId, primary, secondary, credits
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            limitId = try values.decodeIfPresent(String.self, forKey: .limitId)
            // 一个窗口或余额的坏字段不应吞掉另外两个正常值。
            primary = try? values.decode(Window.self, forKey: .primary)
            secondary = try? values.decode(Window.self, forKey: .secondary)
            credits = try? values.decode(Credits.self, forKey: .credits)
        }
    }
    struct Window: Decodable {
        let usedPercent: Double
        let windowDurationMins: Int
        let resetsAt: Int64?

        private enum CodingKeys: String, CodingKey {
            case usedPercent, windowDurationMins, resetsAt
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = try values.decode(Double.self, forKey: .usedPercent)
            windowDurationMins = try values.decode(Int.self, forKey: .windowDurationMins)
            resetsAt = try? values.decode(Int64.self, forKey: .resetsAt)
        }

        var displayWindow: QuotaWindow? {
            guard (0...100).contains(usedPercent) else { return nil }
            let reset = resetsAt.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
            return QuotaWindow(usedPercent: usedPercent, resetsAt: reset)
        }
    }
    struct Credits: Decodable {
        let balance: String?
        let hasCredits: Bool?
        let unlimited: Bool?

        var displayBalance: QuotaCredits? {
            if unlimited == true { return .unlimited }
            if let balance {
                let text = balance.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let value = Double(text), value.isFinite, value >= 0 else { return nil }
                return .balance(text)
            }
            return hasCredits == false ? .noBalance : nil
        }
    }
    let id: Int
    let error: RPCError?
    let result: Payload?
}

private struct JSONLineTransport {
    private struct Header: Decodable {
        let id: Int
        let error: QuotaReply.RPCError?
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
