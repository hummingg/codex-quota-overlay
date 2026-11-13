import AppKit

final class OverlaySurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        // 直接绘制圆角灰底，让面板四角保持透明，不让系统材质从裁切边缘透出。
        NSColor(srgbRed: 0.43, green: 0.43, blue: 0.43, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11).fill()
    }
}
