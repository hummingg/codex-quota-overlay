import Foundation
import CoreGraphics

@main
enum DisplayPolicyTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let future = now.addingTimeInterval(3720)
        let viewport = CGRect(x: -1440, y: 40, width: 1440, height: 830)
        let window = CGRect(x: -1250, y: 70, width: 900, height: 760)
        check(OverlayPolicy.isCodex("com.openai.codex"), "当前桌面版 bundle ID")
        check(!OverlayPolicy.isCodex("com.openai.chat"), "其他应用不显示")
        check(!OverlayPolicy.isCodex(nil), "未激活不显示")
        check(OverlayPolicy.countdown(to: future, now: now) == "1小时02分", "小时倒计时")
        check(OverlayPolicy.countdown(to: now.addingTimeInterval(1), now: now) == "1分钟", "不足一分钟仍为 1 分钟")
        check(OverlayPolicy.countdown(to: now.addingTimeInterval(172800 + 3600), now: now) == "2天1小时", "天数倒计时")
        check(OverlayPolicy.countdown(to: now, now: now) == nil, "不假定已完成自然重置")
        let size = CGSize(width: 250, height: 48)
        let placed = OverlayPolicy.origin(size: size, window: window, viewport: viewport)
        check(placed == CGPoint(x: -612, y: 82), "贴在 Codex 窗口右下角")
        let clipped = OverlayPolicy.origin(
            size: size, window: CGRect(x: -180, y: -80, width: 900, height: 760), viewport: viewport
        )
        check(clipped == CGPoint(x: -250, y: 40), "跨显示器时限制在可见区右下角")
        let quota = QuotaWindow(usedPercent: 12, resetsAt: future)
        let expired = QuotaWindow(usedPercent: 12, resetsAt: now)
        let both = QuotaSnapshot(fiveHour: expired, weekly: quota, credits: .balance("0"))
        let rows = OverlayPolicy.rows(snapshot: both, failed: false, now: now) { _ in "1月2日 03:04" }
        check(rows.map(\.title) == ["5 小时 · 剩 88%", "周额度 · 剩 88%", "额外额度（Credits） · 0"],
              "分别展示两种订阅窗口和额外额度")
        check(rows[0].detail == "等待确认下一次重置…" && rows[1].detail == "1月2日 03:04 重置 · 1小时02分",
              "单个窗口到期不影响另一个窗口的时间")
        let weeklyOnly = QuotaSnapshot(fiveHour: nil, weekly: quota, credits: nil)
        let weeklyRows = OverlayPolicy.rows(snapshot: weeklyOnly, failed: true, now: now) { _ in "1月2日 03:04" }
        check(weeklyRows.map(\.title) == ["周额度 · 剩 88% · 旧数据", "额外额度（Credits） · 未返回"],
              "缺失 5 小时窗口不占行，未知余额不显示为零")
        let onlyFiveHour = QuotaSnapshot(fiveHour: QuotaWindow(usedPercent: 12, resetsAt: nil),
                                        weekly: nil, credits: .unlimited)
        let fiveHourRows = OverlayPolicy.rows(snapshot: onlyFiveHour, failed: false, now: now) { _ in "测试" }
        check(fiveHourRows.map(\.title) == ["5 小时 · 剩 88%", "额外额度（Credits） · 不限"],
              "仅有 5 小时窗口也能显示")
        check(fiveHourRows[0].detail == "重置时间未返回", "缺失重置时间时仍显示剩余比例")
        print("14 个显示策略用例通过")
    }

    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else {
            fputs("失败：\(name)\n", stderr)
            exit(1)
        }
    }
}
