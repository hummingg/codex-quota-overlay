import CoreGraphics
import Foundation

enum OverlayPolicy {
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

    static func origin(size: CGSize, window: CGRect, viewport: CGRect) -> CGPoint {
        CGPoint(
            x: max(viewport.minX, min(window.maxX - size.width - 12, viewport.maxX - size.width)),
            y: max(viewport.minY, min(window.maxY - size.height - 48, viewport.maxY - size.height))
        )
    }
}
