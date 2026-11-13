import Foundation

@main
enum QuotaClientTests {
    static func main() async throws {
        if CommandLine.arguments.contains("app-server") {
            try serveFixture()
            return
        }
        let seconds: TimeInterval = 1_700_000_000
        let expected = QuotaSnapshot(usedPercent: 37, resetsAt: Date(timeIntervalSince1970: seconds))
        let weekly = #"{"usedPercent":37,"windowDurationMins":10080,"resetsAt":1700000000}"#
        let short = #"{"usedPercent":72,"windowDurationMins":300,"resetsAt":1700000000}"#

        let primary = #"{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"primary":\#(weekly),"secondary":null}}}}"#
        let secondary = #"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":\#(short),"secondary":\#(weekly)}}}"#
        let unrelated = #"{"id":2,"result":{"rateLimits":{"limitId":"codex-spark","primary":\#(weekly)}}}"#
        let notWeekly = #"{"id":2,"result":{"rateLimits":{"primary":\#(short)}}}"#
        let missingReset = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":37,"windowDurationMins":10080}}}}"#
        let wrongID = #"{"id":1,"result":{"rateLimits":{"primary":\#(weekly)}}}"#
        let failure = #"{"id":2,"error":{"code":-32000,"message":"不应传给 UI 的内容"}}"#

        try check(try decode(primary) == expected, "Pro 主槽周额度")
        try check(try decode(secondary) == expected, "Plus 副槽周额度")
        for invalid in [unrelated, notWeekly, missingReset, wrongID, failure, "{" ] {
            do {
                _ = try decode(invalid)
                throw TestFailure("拒绝不符合预期的 RPC")
            } catch is QuotaClientError {}
        }

        let fixture = URL(fileURLWithPath: CommandLine.arguments[0])
        try check(try await QuotaClient(executableURL: fixture).readWeekly() == expected, "完整 JSONL 握手")
        do {
            _ = try await QuotaClient(executableURL: fixture, timeout: 0).readWeekly()
            throw TestFailure("超时后不得返回成功")
        } catch QuotaClientError.timeout {}
        do {
            _ = try await QuotaClient(executableURL: URL(fileURLWithPath: "/usr/bin/true")).readWeekly()
            throw TestFailure("提前退出后不得返回成功")
        } catch QuotaClientError.rpcFailed {}

        if CommandLine.arguments.contains("--live") {
            let actual = try await QuotaClient().readWeekly()
            try check((0...100).contains(actual.usedPercent), "真实额度百分比")
            try check(actual.resetsAt > Date(), "真实周额度重置时间")
            print("真实 Codex RPC 已读取：使用 \(actual.usedPercent)%，刷新 \(actual.resetsAt.ISO8601Format())")
        }
        print("QuotaClient tests passed")
    }

    private static func serveFixture() throws {
        try check(Array(CommandLine.arguments.dropFirst()) == [
            "-s", "read-only", "-a", "never", "app-server", "--listen", "stdio://",
        ], "只读 CLI 参数")
        try readMethod("initialize")
        try emit(#"{"id":1,"result":{}}"#)
        try readMethod("initialized")
        try readMethod("account/rateLimits/read")
        try emit(#"{"method":"unrelated"}"#)
        try emit(#"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":37,"windowDurationMins":10080,"resetsAt":1700000000}}}}"#)
    }

    private static func readMethod(_ expected: String) throws {
        guard let line = readLine(),
              let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              request["method"] as? String == expected else { throw TestFailure(expected) }
    }

    private static func emit(_ line: String) throws {
        try FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
    }

    private static func decode(_ json: String) throws -> QuotaSnapshot {
        try QuotaClient.decodeWeekly(Data(json.utf8))
    }

    private static func check(_ condition: Bool, _ description: String) throws {
        if !condition { throw TestFailure(description) }
    }
}

private struct TestFailure: Error {
    let description: String
    init(_ description: String) { self.description = description }
}
