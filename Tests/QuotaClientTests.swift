import Foundation

@main
enum QuotaClientTests {
    static func main() async throws {
        if CommandLine.arguments.contains("app-server") {
            try serveFixture()
            return
        }
        let seconds: TimeInterval = 1_700_000_000
        let weekWindow = QuotaWindow(usedPercent: 37, resetsAt: Date(timeIntervalSince1970: seconds))
        let shortWindow = QuotaWindow(usedPercent: 72, resetsAt: Date(timeIntervalSince1970: seconds + 300))
        let expected = QuotaSnapshot(fiveHour: nil, weekly: weekWindow, credits: .balance("0"))
        let weekly = #"{"usedPercent":37,"windowDurationMins":10080,"resetsAt":1700000000}"#
        let short = #"{"usedPercent":72,"windowDurationMins":300,"resetsAt":1700000300}"#
        let zeroCredits = #"{"hasCredits":false,"unlimited":false,"balance":"0"}"#

        let primary = #"{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"primary":\#(weekly),"secondary":null,"credits":\#(zeroCredits)}},"rateLimitResetCredits":{"availableCount":2}}}"#
        let dual = QuotaSnapshot(fiveHour: shortWindow, weekly: weekWindow, credits: nil)
        let secondary = #"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":\#(short),"secondary":\#(weekly)}}}"#
        let swapped = #"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":\#(weekly),"secondary":\#(short)}}}"#
        let unrelated = #"{"id":2,"result":{"rateLimits":{"limitId":"codex-spark","primary":\#(weekly)}}}"#
        let shortOnly = #"{"id":2,"result":{"rateLimits":{"primary":\#(short)}}}"#
        let unsupportedDuration = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":37,"windowDurationMins":60,"resetsAt":1700000000}}}}"#
        let missingReset = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":37,"windowDurationMins":10080}}}}"#
        let invalidReset = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":37,"windowDurationMins":10080,"resetsAt":-1}}}}"#
        let malformedReset = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":37,"windowDurationMins":10080,"resetsAt":"unknown"}}}}"#
        let brokenSibling = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":"broken","windowDurationMins":10080},"secondary":\#(short),"credits":{"balance":false}}}}"#
        let wrongID = #"{"id":1,"result":{"rateLimits":{"primary":\#(weekly)}}}"#
        let failure = #"{"id":2,"error":{"code":-32000,"message":"不应传给 UI 的内容"}}"#

        try check(try decode(primary) == expected, "Pro 主槽周额度，额外余额 0 不受重置卡数影响")
        try check(try decode(secondary) == dual, "5 小时和周额度独立解码")
        try check(try decode(swapped) == dual, "按周期时长而不是槽位识别额度")
        let shortSnapshot = QuotaSnapshot(fiveHour: shortWindow, weekly: nil, credits: nil)
        try check(try decode(shortOnly) == shortSnapshot, "只返回 5 小时额度")
        try check(try decode(brokenSibling) == shortSnapshot, "损坏字段不影响其他窗口")
        let noReset = QuotaSnapshot(fiveHour: nil, weekly: QuotaWindow(usedPercent: 37, resetsAt: nil), credits: nil)
        try check(try decode(missingReset) == noReset, "重置时间缺失时仍显示有效百分比")
        try check(try decode(invalidReset) == noReset, "无效重置时间不冒充有效时间")
        try check(try decode(malformedReset) == noReset, "坏重置字段不影响有效百分比")

        let creditsCases: [(String, QuotaCredits?)] = [
            (#"{"hasCredits":true,"unlimited":false,"balance":"12.75"}"#, .balance("12.75")),
            (#"{"hasCredits":false,"unlimited":false,"balance":null}"#, .noBalance),
            (#"{"hasCredits":true,"unlimited":true,"balance":null}"#, .unlimited),
            (#"{"hasCredits":true,"unlimited":false,"balance":null}"#, nil),
            (#"{"hasCredits":false,"unlimited":false,"balance":"NaN"}"#, nil),
            ("null", nil),
        ]
        for (payload, expectedCredits) in creditsCases {
            let response = #"{"id":2,"result":{"rateLimits":{"primary":\#(weekly),"credits":\#(payload)}}}"#
            try check(try decode(response).credits == expectedCredits, "区分余额、不可用和无限额")
        }

        for invalid in [unrelated, unsupportedDuration, wrongID, failure, "{"] {
            do {
                _ = try decode(invalid)
                throw TestFailure("拒绝不符合预期的 RPC")
            } catch is QuotaClientError {}
        }

        let fixture = URL(fileURLWithPath: CommandLine.arguments[0])
        try check(try await QuotaClient(executableURL: fixture).read() == expected, "完整 JSONL 握手")
        do {
            _ = try await QuotaClient(executableURL: fixture, timeout: 0).read()
            throw TestFailure("超时后不得返回成功")
        } catch QuotaClientError.timeout {}
        do {
            _ = try await QuotaClient(executableURL: URL(fileURLWithPath: "/usr/bin/true")).read()
            throw TestFailure("提前退出后不得返回成功")
        } catch QuotaClientError.rpcFailed {}

        if CommandLine.arguments.contains("--live") {
            let actual = try await QuotaClient().read()
            print("真实 Codex RPC 已读取：周额度 \(actual.weekly != nil)，5 小时额度 \(actual.fiveHour != nil)，额外额度 \(String(describing: actual.credits))")
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
        try emit(#"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":37,"windowDurationMins":10080,"resetsAt":1700000000},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"}}}}"#)
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
        try QuotaClient.decode(Data(json.utf8))
    }

    private static func check(_ condition: Bool, _ description: String) throws {
        if !condition { throw TestFailure(description) }
    }
}

private struct TestFailure: Error {
    let description: String
    init(_ description: String) { self.description = description }
}
