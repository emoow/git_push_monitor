#!/usr/bin/env swift

import Cocoa

private struct MonitorConfig {
    let dailyLimitMB: Double
    let warnRatio: Double

    var limitBytes: Int {
        max(1, Int(dailyLimitMB * 1_048_576.0))
    }

    var warningBytes: Int {
        max(1, Int(Double(limitBytes) * warnRatio))
    }
}

private func configURL() -> URL {
    let environment = ProcessInfo.processInfo.environment

    if let override = environment["GIT_PUSH_MONITOR_CONFIG"], !override.isEmpty {
        return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
    }

    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/git-push-monitor/config")
}

private func readConfig() -> MonitorConfig {
    let fallback = MonitorConfig(dailyLimitMB: 0.99, warnRatio: 0.80)
    let url = configURL()

    guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
        return fallback
    }

    var values: [String: String] = [:]

    for line in raw.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty || trimmed.hasPrefix("#") {
            continue
        }

        let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)

        if parts.count == 2 {
            values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
    }

    let limit = Double(values["DAILY_LIMIT_MB"] ?? "") ?? fallback.dailyLimitMB
    let warnRatio = Double(values["WARN_RATIO"] ?? "") ?? fallback.warnRatio

    return MonitorConfig(
        dailyLimitMB: limit > 0 ? limit : fallback.dailyLimitMB,
        warnRatio: warnRatio > 0 && warnRatio <= 1 ? warnRatio : fallback.warnRatio
    )
}

private func todayStateFile() -> URL {
    let environment = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let stateBase = environment["XDG_STATE_HOME"] ?? "\(home)/.local/state"

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"

    return URL(fileURLWithPath: stateBase)
        .appendingPathComponent("git-push-monitor", isDirectory: true)
        .appendingPathComponent("\(formatter.string(from: Date())).bytes")
}

private func readTodayBytes() -> Int {
    let file = todayStateFile()

    guard
        let raw = try? String(contentsOf: file, encoding: .utf8),
        let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
        return 0
    }

    return max(0, value)
}

private func mbString(_ bytes: Int) -> String {
    String(format: "%.2f", Double(bytes) / 1_048_576.0)
}

private final class TrafficMonitorView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Git Push Traffic")
    private let amountLabel = NSTextField(labelWithString: "0.00 / 0.99 MB")
    private let statusLabel = NSTextField(labelWithString: "Today looks clear")
    private let progress = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.86).cgColor

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor

        amountLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        amountLabel.textColor = .labelColor

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor

        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        progress.style = .bar

        [titleLabel, amountLabel, statusLabel, progress].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),

            amountLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            amountLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            amountLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),

            progress.topAnchor.constraint(equalTo: amountLabel.bottomAnchor, constant: 12),
            progress.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),

            statusLabel.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18)
        ])
    }

    func refresh() {
        let config = readConfig()
        let usedBytes = readTodayBytes()
        let ratio = min(1.0, Double(usedBytes) / Double(config.limitBytes))

        amountLabel.stringValue = "\(mbString(usedBytes)) / \(mbString(config.limitBytes)) MB"
        progress.doubleValue = ratio

        switch usedBytes {
        case let value where value >= config.limitBytes:
            statusLabel.stringValue = "Daily limit reached. Stop pushing."
            statusLabel.textColor = .systemRed
        case let value where value >= config.warningBytes:
            statusLabel.stringValue = "Close to limit. Avoid more pushes."
            statusLabel.textColor = .systemOrange
        default:
            let remaining = max(0, config.limitBytes - usedBytes)
            statusLabel.stringValue = "\(mbString(remaining)) MB remaining today"
            statusLabel.textColor = .secondaryLabelColor
        }
    }
}

private final class MonitorApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: NSPanel?
    private var monitorView: TrafficMonitorView?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        showPanel()

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.monitorView?.refresh()
        }
    }

    private func showPanel() {
        let size = NSSize(width: 268, height: 138)
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screenFrame.maxX - size.width - 22,
            y: screenFrame.maxY - size.height - 22
        )

        let view = TrafficMonitorView(frame: NSRect(origin: .zero, size: size))
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.title = "Git Push Traffic"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.contentView = view
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)

        self.monitorView = view
        self.panel = panel
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}

private let app = NSApplication.shared
private let delegate = MonitorApp()
app.delegate = delegate
app.run()
