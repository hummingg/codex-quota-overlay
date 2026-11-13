import AppKit
import CoreGraphics
import Foundation
import OSLog

@main
enum OverlayApp {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--check") {
            do {
                let quota = try await QuotaClient().read()
                let formatter = ISO8601DateFormatter()
                for row in OverlayPolicy.rows(snapshot: quota, failed: false, now: Date(), formatDate: formatter.string(from:)) {
                    print(row.detail.map { "\(row.title) · \($0)" } ?? row.title)
                }
            } catch {
                fputs("无法读取 Codex 额度：\(error.localizedDescription)\n", stderr)
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
    private let width: CGFloat = 250
    private let labels = (0..<5).map { _ in NSTextField(labelWithString: "") }
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
        let rect = CGRect(x: 0, y: 0, width: width, height: 50)
        panel = QuotaPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.title = "Codex 额度浮窗"
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let surface = OverlaySurface(frame: rect)
        for label in labels {
            label.lineBreakMode = .byTruncatingTail
            surface.addSubview(label)
        }
        surface.autoresizingMask = [.width, .height]
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
        let now = Date()
        let rows = OverlayPolicy.rows(snapshot: snapshot, failed: failed, now: now, formatDate: dateFormatter.string(from:))
        let lines: [(text: String, isTitle: Bool)] = rows.flatMap { row in
            [(row.title, true)] + (row.detail.map { [($0, false)] } ?? [])
        }
        let size = CGSize(width: width, height: CGFloat(lines.count * 17 + (rows.count - 1) * 4 + 16))
        guard let front = NSWorkspace.shared.frontmostApplication,
              OverlayPolicy.isCodex(front.bundleIdentifier),
              let placement = position(for: front.processIdentifier, size: size)
        else {
            if panel.isVisible {
                panel.orderOut(nil)
                logger.notice("hidden")
            }
            return
        }
        let passedReset = [snapshot?.fiveHour?.resetsAt, snapshot?.weekly?.resetsAt]
            .compactMap { $0 }.contains { $0 <= now }
        let refreshInterval: TimeInterval = passedReset ? 15 : 90
        if refreshTask == nil && lastAttempt.map({ now.timeIntervalSince($0) >= refreshInterval }) != false {
            lastAttempt = now
            refreshTask = Task {
                do {
                    snapshot = try await client.read()
                    failed = false
                } catch {
                    failed = true
                }
                refreshTask = nil
                update()
            }
        }
        let frame = CGRect(origin: placement, size: size)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.contentView?.needsDisplay = true
        }
        var y = size.height - 8
        for (index, label) in labels.enumerated() {
            label.isHidden = index >= lines.count
            guard index < lines.count else { continue }
            let (text, isTitle) = lines[index]
            if index > 0 && isTitle { y -= 4 }
            y -= 17
            label.frame = CGRect(x: 12, y: y, width: width - 24, height: 17)
            if label.stringValue != text { label.stringValue = text }
            label.font = isTitle ? .systemFont(ofSize: 13, weight: .semibold)
                : .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.textColor = .white.withAlphaComponent(isTitle ? 0.88 : 0.72)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
            logger.notice("shown")
        }
    }

    private func position(for pid: pid_t, size: CGSize) -> CGPoint? {
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
