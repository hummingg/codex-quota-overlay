import CoreGraphics
import Foundation

enum OverlayPolicy {
    struct Row {
        let title: String
        let detail: String?
    }

    static func isCodex(_ bundleID: String?) -> Bool {
        bundleID == "com.openai.codex"
    }

    static func countdown(to reset: Date, now: Date) -> String? {
        let seconds = reset.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        let minutes = Int(ceil(seconds / 60))
        let hours = minutes / 60
        if hours >= 24 { return "\(hours / 24)天\(hours % 24)小时" }
        if hours > 0 { return String(format: "%d小时%02d分", hours, minutes % 60) }
        return "\(minutes)分钟"
    }

    static func rows(snapshot: QuotaSnapshot?, failed: Bool, now: Date, formatDate: (Date) -> String) -> [Row] {
        guard let snapshot else {
            return [Row(title: "Codex · 额度", detail: failed ? "暂时无法读取额度" : "正在读取…")]
        }
        let stale = failed ? " · 旧数据" : ""
        var rows: [Row] = []
        for (label, window) in [("5 小时", snapshot.fiveHour), ("周额度", snapshot.weekly)] {
            guard let window else { continue }
            let remaining = Int((100 - window.usedPercent).rounded())
            let detail = window.resetsAt.map { reset in
                countdown(to: reset, now: now).map { "\(formatDate(reset)) 重置 · \($0)" }
                    ?? "等待确认下一次重置…"
            } ?? "重置时间未返回"
            rows.append(Row(title: "\(label) · 剩 \(remaining)%\(stale)", detail: detail))
        }
        let balance: String
        switch snapshot.credits {
        case .some(.balance(let value)): balance = value
        case .some(.unlimited): balance = "不限"
        case .some(.noBalance): balance = "无可用"
        case nil: balance = "未返回"
        }
        rows.append(Row(title: "额外额度（Credits） · \(balance)\(failed && snapshot.credits != nil ? stale : "")", detail: nil))
        return rows
    }

    static func origin(size: CGSize, window: CGRect, viewport: CGRect) -> CGPoint {
        CGPoint(
            x: max(viewport.minX, min(window.maxX - size.width - 12, viewport.maxX - size.width)),
            y: max(viewport.minY, min(window.minY + 12, viewport.maxY - size.height))
        )
    }
}
