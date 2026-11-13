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
        check(placed == CGPoint(x: -612, y: 734), "贴在 Codex 窗口右上角")
        let clipped = OverlayPolicy.origin(
            size: size, window: CGRect(x: -180, y: 820, width: 900, height: 760), viewport: viewport
        )
        check(viewport.contains(CGRect(origin: clipped, size: size)), "跨显示器时不超出可见区")
        print("9 个显示策略用例通过")
    }

    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else {
            fputs("失败：\(name)\n", stderr)
            exit(1)
        }
    }
}
