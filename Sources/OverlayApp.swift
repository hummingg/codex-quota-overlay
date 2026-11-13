import AppKit
import CoreGraphics
import Foundation
import OSLog

@main
enum OverlayApp {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--check") {
            do {
                let quota = try await QuotaClient().readWeekly()
                print("周额度已用 \(quota.usedPercent)%；下次重置 \(ISO8601DateFormatter().string(from: quota.resetsAt))")
            } catch {
                fputs("无法读取 Codex 周额度：\(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        let app = NSApplication.shared
        let controller = OverlayController()
        app.setActivationPolicy(.accessory)
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }
}

private final class QuotaPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class OverlayController: NSObject, NSApplicationDelegate {
    private let client = QuotaClient()
    private let logger = Logger(subsystem: "com.hummingg.codex-quota-overlay", category: "visibility")
    private let size = CGSize(width: 250, height: 50)
    private let headline = NSTextField(labelWithString: "Codex · 周额度")
    private let detail = NSTextField(labelWithString: "正在读取…")
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()
    private var panel: QuotaPanel!
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var snapshot: QuotaSnapshot?
    private var lastAttempt: Date?
    private var failed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rect = CGRect(origin: .zero, size: size)
        panel = QuotaPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.title = "Codex 周额度浮窗"
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let surface = OverlaySurface(frame: rect)
        headline.font = .systemFont(ofSize: 13, weight: .semibold)
        headline.textColor = .white
        headline.frame = CGRect(x: 12, y: 27, width: 226, height: 17)
        detail.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        detail.textColor = .white.withAlphaComponent(0.84)
        detail.frame = CGRect(x: 12, y: 8, width: 226, height: 15)
        detail.lineBreakMode = .byTruncatingTail
        surface.addSubview(headline)
        surface.addSubview(detail)
        panel.contentView = surface

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(activated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(activated), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(activated),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        timer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        update()
    }

    @objc private func tick() { update() }
    @objc private func activated(_ notification: Notification) { update() }
    @objc private func woke(_ notification: Notification) {
        lastAttempt = nil
        update()
    }

    private func update() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              OverlayPolicy.isCodex(front.bundleIdentifier),
              let placement = position(for: front.processIdentifier)
        else {
            if panel.isVisible {
                panel.orderOut(nil)
                logger.notice("hidden")
            }
            return
        }
        let now = Date()
        let passedReset = snapshot.map { $0.resetsAt <= now } ?? false
        let refreshInterval: TimeInterval = passedReset ? 15 : 90
        if refreshTask == nil && lastAttempt.map({ now.timeIntervalSince($0) >= refreshInterval }) != false {
            lastAttempt = now
            refreshTask = Task {
                do {
                    snapshot = try await client.readWeekly()
                    failed = false
                } catch {
                    failed = true
                }
                refreshTask = nil
                update()
            }
        }
        if let quota = snapshot, let countdown = OverlayPolicy.countdown(to: quota.resetsAt, now: now) {
            headline.stringValue = "Codex · 周剩 \(Int((100 - quota.usedPercent).rounded()))%\(failed ? " · 旧数据" : "")"
            detail.stringValue = "\(dateFormatter.string(from: quota.resetsAt)) 重置 · \(countdown)"
        } else {
            headline.stringValue = "Codex · 周额度"
            detail.stringValue = failed ? "暂时无法读取额度" : (snapshot == nil ? "正在读取…" : "等待确认下一次重置…")
        }
        if panel.frame.origin != placement { panel.setFrameOrigin(placement) }
        if !panel.isVisible {
            panel.orderFrontRegardless()
            logger.notice("shown")
        }
    }

    private func position(for pid: pid_t) -> CGPoint? {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return nil }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        // 仅用系统窗口的进程、层级、位置，不读取窗口内容或标题。
        for info in windows {
            guard info[kCGWindowOwnerPID as String] as? Int32 == pid,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let raw = CGRect(dictionaryRepresentation: bounds),
                  raw.width >= 320, raw.height >= 220
            else { continue }
            let window = CGRect(x: raw.minX, y: primary.frame.maxY - raw.maxY, width: raw.width, height: raw.height)
            let screen = screens.max { a, b in
                intersectionArea(a.frame, window) < intersectionArea(b.frame, window)
            } ?? primary
            return OverlayPolicy.origin(size: size, window: window, viewport: screen.visibleFrame)
        }
        return nil
    }

    private func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let overlap = a.intersection(b)
        return overlap.width * overlap.height
    }
}
