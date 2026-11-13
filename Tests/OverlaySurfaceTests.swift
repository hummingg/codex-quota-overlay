import AppKit

@main
enum OverlaySurfaceTests {
    @MainActor static func main() {
        let rect = CGRect(x: 0, y: 0, width: 250, height: 50)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 250, pixelsHigh: 50, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fatalError("无法创建透明测试画布")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(rect)
        OverlaySurface(frame: rect).draw(rect)
        NSGraphicsContext.restoreGraphicsState()
        for (x, y) in [(0, 0), (249, 0), (0, 49), (249, 49)] {
            precondition(bitmap.colorAt(x: x, y: y)!.alphaComponent == 0, "四角必须透明")
        }
        let center = bitmap.colorAt(x: 125, y: 25)!.usingColorSpace(.deviceRGB)!
        precondition(center.alphaComponent == 1 && center.redComponent > 0.3 &&
            center.redComponent < 0.6 && center.redComponent == center.greenComponent &&
            center.greenComponent == center.blueComponent, "内部应为实心灰色")
        print("浮窗四角透明、内部灰色测试通过")
    }
}
