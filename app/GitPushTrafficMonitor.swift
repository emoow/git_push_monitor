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

private func writeConfig(_ config: MonitorConfig) throws {
    let url = configURL()
    let directory = url.deletingLastPathComponent()
    let body = """
    # Git Push Monitor config
    #
    # Change DAILY_LIMIT_MB to adjust the daily upload limit.
    # Change WARN_RATIO to adjust when the desktop monitor and hook warn.

    DAILY_LIMIT_MB=\(String(format: "%.2f", config.dailyLimitMB))
    WARN_RATIO=\(String(format: "%.2f", config.warnRatio))
    """

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try body.write(to: url, atomically: true, encoding: .utf8)
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

private func todayProjectsFile() -> URL {
    todayStateFile()
        .deletingLastPathComponent()
        .appendingPathComponent(todayStateFile().deletingPathExtension().lastPathComponent + ".projects.tsv")
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

private struct ProjectUsage {
    let path: String
    let name: String
    let bytes: Int
}

private func readProjectUsage() -> [ProjectUsage] {
    let file = todayProjectsFile()

    guard let raw = try? String(contentsOf: file, encoding: .utf8) else {
        return []
    }

    return raw.components(separatedBy: .newlines).compactMap { line in
        let parts = line.components(separatedBy: "\t")

        guard parts.count >= 3, let bytes = Int(parts[2]) else {
            return nil
        }

        return ProjectUsage(path: parts[0], name: parts[1], bytes: max(0, bytes))
    }
    .sorted { left, right in
        if left.bytes == right.bytes {
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }

        return left.bytes > right.bytes
    }
}

private func mbString(_ bytes: Int) -> String {
    String(format: "%.2f", Double(bytes) / 1_048_576.0)
}

private final class TrafficMonitorView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Git Push Traffic")
    private let amountLabel = NSTextField(labelWithString: "0.00 / 0.99 MB")
    private let statusLabel = NSTextField(labelWithString: "Today looks clear")
    private let progress = NSProgressIndicator()
    private let refreshButton = NSButton()
    private let detailsButton = NSButton()
    private let settingsButton = NSButton()
    var onSettingsRequested: (() -> Void)?
    var onDetailsRequested: ((NSButton) -> Void)?

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

        if #available(macOS 11.0, *) {
            refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        } else {
            refreshButton.title = "Refresh"
        }
        refreshButton.bezelStyle = .texturedRounded
        refreshButton.imagePosition = .imageOnly
        refreshButton.isBordered = false
        refreshButton.target = self
        refreshButton.action = #selector(refreshNow)
        refreshButton.toolTip = "Refresh usage now"

        if #available(macOS 11.0, *) {
            detailsButton.image = NSImage(systemSymbolName: "chevron.down.circle", accessibilityDescription: "Project uploads")
        } else {
            detailsButton.title = "More"
        }
        detailsButton.bezelStyle = .texturedRounded
        detailsButton.imagePosition = .imageOnly
        detailsButton.isBordered = false
        detailsButton.target = self
        detailsButton.action = #selector(openDetails)
        detailsButton.toolTip = "Show today's project uploads"

        if #available(macOS 11.0, *) {
            settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        } else {
            settingsButton.title = "Set"
        }
        settingsButton.bezelStyle = .texturedRounded
        settingsButton.imagePosition = .imageOnly
        settingsButton.isBordered = false
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        settingsButton.toolTip = "Change daily push limit"

        amountLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        amountLabel.textColor = .labelColor

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor

        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        progress.style = .bar

        [titleLabel, refreshButton, detailsButton, settingsButton, amountLabel, statusLabel, progress].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: refreshButton.leadingAnchor, constant: -8),

            refreshButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: detailsButton.leadingAnchor, constant: -4),
            refreshButton.widthAnchor.constraint(equalToConstant: 26),
            refreshButton.heightAnchor.constraint(equalToConstant: 26),

            detailsButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            detailsButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -4),
            detailsButton.widthAnchor.constraint(equalToConstant: 26),
            detailsButton.heightAnchor.constraint(equalToConstant: 26),

            settingsButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            settingsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            settingsButton.widthAnchor.constraint(equalToConstant: 26),
            settingsButton.heightAnchor.constraint(equalToConstant: 26),

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

    @objc private func openSettings() {
        onSettingsRequested?()
    }

    @objc private func openDetails() {
        onDetailsRequested?(detailsButton)
    }

    @objc private func refreshNow() {
        refresh()
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
    private var settingsPanel: NSPanel?
    private var settingsSaveTarget: SettingsSaveTarget?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        showPanel()

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.monitorView?.refresh()
        }
    }

    private func showPanel() {
        let size = NSSize(width: 296, height: 138)
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screenFrame.maxX - size.width - 22,
            y: screenFrame.maxY - size.height - 22
        )

        let view = TrafficMonitorView(frame: NSRect(origin: .zero, size: size))
        view.onSettingsRequested = { [weak self] in
            self?.showSettings()
        }
        view.onDetailsRequested = { [weak self] button in
            self?.showProjectDetails(from: button)
        }

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
        if notification.object as? NSWindow === panel {
            NSApp.terminate(nil)
        }
    }

    private func showSettings() {
        let config = readConfig()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 224),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Git Push Monitor Settings"
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 224))
        let title = NSTextField(labelWithString: "Git Push Monitor Settings")
        let detail = NSTextField(labelWithString: "These values apply to the desktop monitor and pre-push hook.")
        let limitLabel = NSTextField(labelWithString: "Daily limit MB")
        let limitField = NSTextField(string: String(format: "%.2f", config.dailyLimitMB))
        let warnLabel = NSTextField(labelWithString: "Warn ratio")
        let warnField = NSTextField(string: String(format: "%.2f", config.warnRatio))
        let saveButton = NSButton(title: "Save", target: nil, action: nil)
        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

        [limitField, warnField].forEach {
            $0.alignment = .right
            $0.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        }

        title.font = .systemFont(ofSize: 17, weight: .semibold)
        detail.font = .systemFont(ofSize: 12, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byWordWrapping

        [title, detail, limitLabel, limitField, warnLabel, warnField, saveButton, cancelButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }

        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),

            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            limitLabel.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 24),
            limitLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            limitField.centerYAnchor.constraint(equalTo: limitLabel.centerYAnchor),
            limitField.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            limitField.widthAnchor.constraint(equalToConstant: 112),

            warnLabel.topAnchor.constraint(equalTo: limitLabel.bottomAnchor, constant: 16),
            warnLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            warnField.centerYAnchor.constraint(equalTo: warnLabel.centerYAnchor),
            warnField.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            warnField.widthAnchor.constraint(equalToConstant: 112),

            saveButton.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            saveButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            saveButton.widthAnchor.constraint(equalToConstant: 82),

            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -10),
            cancelButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 82)
        ])

        panel.contentView = content
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        settingsPanel = panel

        cancelButton.target = self
        cancelButton.action = #selector(closeSettings)
        settingsSaveTarget = SettingsSaveTarget { [weak self, weak panel] in
            self?.saveSettings(limitField: limitField, warnField: warnField, panel: panel)
        }
        saveButton.target = settingsSaveTarget
        saveButton.action = #selector(SettingsSaveTarget.save)

        panel.makeKeyAndOrderFront(nil)
    }

    private func saveSettings(limitField: NSTextField, warnField: NSTextField, panel: NSPanel?) {
        let limit = Double(limitField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        let warn = Double(warnField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))

        guard
            let limit,
            let warn,
            limit > 0,
            warn > 0,
            warn <= 1
        else {
            showValidationError()
            return
        }

        do {
            try writeConfig(MonitorConfig(dailyLimitMB: limit, warnRatio: warn))
            monitorView?.refresh()
            panel?.close()
        } catch {
            showWriteError(error)
        }
    }

    @objc private func closeSettings() {
        settingsPanel?.close()
    }

    private func showProjectDetails(from button: NSButton) {
        let usages = readProjectUsage()
        let menu = NSMenu()

        if usages.isEmpty {
            let item = NSMenuItem(title: "No project uploads recorded today", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let total = usages.reduce(0) { $0 + $1.bytes }
            let titleItem = NSMenuItem(title: "Today by project: \(mbString(total)) MB", action: nil, keyEquivalent: "")
            titleItem.isEnabled = false
            menu.addItem(titleItem)
            menu.addItem(.separator())

            for usage in usages {
                let item = NSMenuItem(title: "\(usage.name)  \(mbString(usage.bytes)) MB", action: nil, keyEquivalent: "")
                item.toolTip = usage.path
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func showValidationError() {
        let alert = NSAlert()
        alert.messageText = "Invalid settings"
        alert.informativeText = "Daily limit must be greater than 0. Warn ratio must be greater than 0 and no more than 1."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showWriteError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "Could not save settings"
        alert.runModal()
    }
}

private final class SettingsSaveTarget: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func save() {
        handler()
    }
}

private let app = NSApplication.shared
private let delegate = MonitorApp()
app.delegate = delegate
app.run()
