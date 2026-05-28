import AppKit
import Foundation
import Darwin
import Sparkle

// MARK: - Formatting helpers

// Shared with Metrics.swift (topProcesses) — must be internal, not file-private.
func fmtMem(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824.0
    if gb >= 1.0 { return String(format: "%.1f GB", gb) }
    return String(format: "%.0f MB", Double(bytes) / 1_048_576.0)
}

private func fmtGB(_ bytes: UInt64) -> String {
    String(format: "%.1f", Double(bytes) / 1_073_741_824.0)
}

private func fmtRate(_ bps: Double) -> String {
    if bps >= 1_048_576 { return String(format: "%.1f MB/s", bps / 1_048_576) }
    if bps >= 1_024 { return String(format: "%.0f KB/s", bps / 1_024) }
    return String(format: "%.0f B/s", bps)
}

private func clampInt(_ v: Int, _ lo: Int, _ hi: Int) -> Int { max(lo, min(hi, v)) }

private func sparkline(_ vals: [Double], maxValue: Double = 100) -> String {
    let blocks = Array("▁▂▃▄▅▆▇█")
    guard !vals.isEmpty else { return "" }
    return String(vals.suffix(24).map { v -> Character in
        let idx = clampInt(Int((v / maxValue) * Double(blocks.count - 1) + 0.5), 0, blocks.count - 1)
        return blocks[idx]
    })
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let metrics = Metrics()
    private let settings = SettingsStore()
    private let updater = Updater()
    private var settingsWC: SettingsWindowController?
    private var settingsObserver: NSObjectProtocol?
    private var timer: Timer?

    private var cpuHistory: [Double] = []
    private var lastCPU: Double = 0
    private var lastMem = Metrics.Mem(used: 0, total: 0, compressed: 0)

    private var lastNet: (rx: UInt64, tx: UInt64) = (0, 0)
    private var lastNetTime: Date?
    private var rxRate: Double = 0
    private var txRate: Double = 0

    private var lastGPU: Metrics.GPU?
    private var gpuHistory: [Double] = []

    private var lastDisk: (read: UInt64, write: UInt64) = (0, 0)
    private var lastDiskTime: Date?
    private var diskReadRate: Double = 0
    private var diskWriteRate: Double = 0

    private var lastBattery: Metrics.Battery?
    private var lastThermal: ProcessInfo.ThermalState = .nominal

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prime delta-based metrics so the first displayed value is real.
        _ = metrics.cpuUsage()
        lastNet = metrics.networkBytes()
        lastNetTime = Date()
        lastDisk = metrics.diskBytes()
        lastDiskTime = Date()

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        update()
        startTimer()

        // Re-apply when the user changes anything in the settings window.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.applySettings()
        }

        // Start Sparkle shortly after launch — its start() touches XPC + keychain.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.updater.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let token = settingsObserver { NotificationCenter.default.removeObserver(token) }
    }

    /// (Re)start the sampling timer at the current interval. Invalidating the old
    /// one first is essential — otherwise changing the interval leaves the previous
    /// timer running, double-sampling and corrupting the network-rate deltas.
    private func startTimer() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: TimeInterval(settings.refreshInterval), repeats: true) { [weak self] _ in self?.update() }
        RunLoop.current.add(t, forMode: .common)
        timer = t
    }

    private func applySettings() {
        startTimer()
        updateTitle(cpu: lastCPU, ram: ramPercent())
    }

    // MARK: Sampling

    private func update() {
        let cpu = metrics.cpuUsage()
        lastCPU = cpu
        cpuHistory.append(cpu)
        if cpuHistory.count > 60 { cpuHistory.removeFirst(cpuHistory.count - 60) }

        lastMem = metrics.memory()

        let now = Date()

        let net = metrics.networkBytes()
        if let prevTime = lastNetTime {
            let dt = now.timeIntervalSince(prevTime)
            if dt > 0 {
                rxRate = Double(net.rx &- lastNet.rx) / dt
                txRate = Double(net.tx &- lastNet.tx) / dt
            }
        }
        lastNet = net
        lastNetTime = now

        lastGPU = metrics.gpu()
        gpuHistory.append(lastGPU?.utilization ?? 0)
        if gpuHistory.count > 60 { gpuHistory.removeFirst(gpuHistory.count - 60) }

        let disk = metrics.diskBytes()
        if let prevTime = lastDiskTime {
            let dt = now.timeIntervalSince(prevTime)
            if dt > 0 {
                diskReadRate = Double(disk.read &- lastDisk.read) / dt
                diskWriteRate = Double(disk.write &- lastDisk.write) / dt
            }
        }
        lastDisk = disk
        lastDiskTime = now

        lastBattery = metrics.battery()
        lastThermal = ProcessInfo.processInfo.thermalState

        updateTitle(cpu: cpu, ram: ramPercent())
    }

    private func ramPercent() -> Double {
        guard lastMem.total > 0 else { return 0 }
        return Double(lastMem.used) / Double(lastMem.total) * 100.0
    }

    // MARK: Status bar title

    private var symbolCache: [String: NSAttributedString] = [:]

    private func symbolAttachment(_ name: String, fallback: String) -> NSAttributedString {
        if let cached = symbolCache[name] { return cached }
        let result: NSAttributedString
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            img.isTemplate = true
            let att = NSTextAttachment()
            att.image = img
            att.bounds = CGRect(x: 0, y: -2, width: 14, height: 13)
            result = NSAttributedString(attachment: att)
        } else {
            result = NSAttributedString(string: fallback)
        }
        symbolCache[name] = result
        return result
    }

    private func updateTitle(cpu: Double, ram: Double) {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let textAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]

        // The settings UI guarantees at least one is on, but never render an empty
        // (zero-width) title — that would make the menu-bar item appear to vanish.
        var showCPU = settings.showCPU
        let showRAM = settings.showRAM
        if !showCPU && !showRAM { showCPU = true }

        let title = NSMutableAttributedString()
        func appendMetric(symbol: String, label: String, value: Double) {
            if settings.useTextLabels {
                title.append(NSAttributedString(string: label, attributes: textAttrs))
            } else {
                title.append(symbolAttachment(symbol, fallback: label))
            }
            title.append(NSAttributedString(string: String(format: " %.0f%%", value), attributes: textAttrs))
        }

        if showCPU { appendMetric(symbol: "cpu", label: "CPU", value: cpu) }
        if showCPU && showRAM { title.append(NSAttributedString(string: "  ", attributes: textAttrs)) }
        if showRAM { appendMetric(symbol: "memorychip", label: "RAM", value: ram) }
        button.attributedTitle = title
    }

    // MARK: Menu

    /// Color-codes a load percentage: green (calm) → orange (busy) → red (hot).
    private func loadColor(_ pct: Double) -> NSColor {
        if pct >= 85 { return NSColor.systemRed }
        if pct >= 60 { return NSColor.systemOrange }
        return NSColor.systemGreen
    }

    private func infoItem(_ text: String, bold: Bool = false, color: NSColor = .labelColor, indent: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        // Enabled (not grayed): a disabled NSMenuItem is force-dimmed by AppKit and
        // ignores foregroundColor. These rows have no action, so they're inert anyway.
        item.isEnabled = true
        let weight: NSFont.Weight = bold ? .semibold : .regular
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: weight),
            .foregroundColor: color,
        ]
        item.attributedTitle = NSAttributedString(string: (indent ? "   " : "") + text, attributes: attrs)
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let ram = ramPercent()
        let spark = sparkline(cpuHistory)
        menu.addItem(infoItem(String(format: "%@%3.0f%%   %@", padded("CPU", 11) as NSString, lastCPU, spark as NSString),
                              color: loadColor(lastCPU)))
        if let gpu = lastGPU {
            menu.addItem(infoItem(String(format: "%@%3.0f%%   %@   %@", padded("GPU", 11) as NSString, gpu.utilization,
                                         sparkline(gpuHistory) as NSString, fmtMem(gpu.memUsed) as NSString),
                                  color: loadColor(gpu.utilization)))
        }
        menu.addItem(infoItem(String(format: "%@%3.0f%%   %@ / %@ GB", padded("RAM", 11) as NSString, ram,
                                     fmtGB(lastMem.used) as NSString, fmtGB(lastMem.total) as NSString),
                              color: loadColor(ram)))

        let level = metrics.memoryPressureLevel()
        let (pressureText, pressureColor): (String, NSColor)
        switch level {
        case 4: (pressureText, pressureColor) = ("🔴 Critical", .systemRed)
        case 2: (pressureText, pressureColor) = ("🟡 Warning", .systemOrange)
        default: (pressureText, pressureColor) = ("🟢 Normal", .systemGreen)
        }
        menu.addItem(infoItem(String(format: "%@%@   Pressure: ", padded("Compressed", 11) as NSString, fmtMem(lastMem.compressed) as NSString) + pressureText,
                              color: pressureColor))

        let sw = metrics.swap()
        if sw.total > 0 {
            menu.addItem(infoItem(String(format: "%@%@ / %@ GB", padded("Swap", 11) as NSString, fmtGB(sw.used) as NSString, fmtGB(sw.total) as NSString)))
        } else {
            menu.addItem(infoItem(String(format: "%@not in use", padded("Swap", 11) as NSString)))
        }

        menu.addItem(infoItem(String(format: "%@↓ %@   ↑ %@", padded("Disk", 11) as NSString, fmtRate(diskReadRate) as NSString, fmtRate(diskWriteRate) as NSString)))
        menu.addItem(infoItem(String(format: "%@↓ %@   ↑ %@", padded("Network", 11) as NSString, fmtRate(rxRate) as NSString, fmtRate(txRate) as NSString)))

        menu.addItem(.separator())

        if let bat = lastBattery {
            let batColor: NSColor = bat.level <= 20 ? .systemRed : (bat.level <= 40 ? .systemOrange : .systemGreen)
            var s = String(format: "%@%3.0f%%", padded("Battery", 11) as NSString, bat.level)
            if bat.charging { s += "  ⚡" }
            if let m = bat.minutesRemaining { s += String(format: "  %d:%02d %@", m / 60, m % 60, (bat.charging ? "to full" : "left") as NSString) }
            menu.addItem(infoItem(s, color: batColor))
        }

        let (thermalText, thermalColor): (String, NSColor)
        switch lastThermal {
        case .critical: (thermalText, thermalColor) = ("🔴 Critical", .systemRed)
        case .serious:  (thermalText, thermalColor) = ("🟠 Serious", .systemOrange)
        case .fair:     (thermalText, thermalColor) = ("🟡 Fair", .systemOrange)
        default:        (thermalText, thermalColor) = ("🟢 Nominal", .systemGreen)
        }
        menu.addItem(infoItem(String(format: "%@", padded("Thermal", 11) as NSString) + thermalText, color: thermalColor))

        menu.addItem(.separator())

        menu.addItem(infoItem("Top CPU", bold: true, color: .labelColor))
        let topCPU = metrics.topProcesses(byCPU: true, limit: 3)
        if topCPU.isEmpty { menu.addItem(infoItem("—", indent: true)) }
        for p in topCPU {
            menu.addItem(infoItem(String(format: "%-22@ %@", padded(p.name, 22) as NSString, p.value as NSString), indent: true))
        }

        menu.addItem(infoItem("Top RAM", bold: true, color: .labelColor))
        let topMem = metrics.topProcesses(byCPU: false, limit: 3)
        if topMem.isEmpty { menu.addItem(infoItem("—", indent: true)) }
        for p in topMem {
            menu.addItem(infoItem(String(format: "%@ %@", padded(p.name, 22) as NSString, p.value as NSString), indent: true))
        }

        menu.addItem(.separator())
        let updateItem = NSMenuItem(title: "Check for Updates…",
                                    action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                    keyEquivalent: "")
        updateItem.target = updater.controller
        updateItem.isEnabled = updater.canCheckForUpdates   // menu autoenable is off; reflect state manually
        menu.addItem(updateItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    @objc private func openSettings() {
        if settingsWC == nil { settingsWC = SettingsWindowController(settings: settings, updater: updater) }
        // The app is an .accessory agent, so it must be activated for the window
        // to come forward and accept keyboard focus.
        NSApp.activate(ignoringOtherApps: true)
        settingsWC?.showWindow(nil)
        settingsWC?.window?.makeKeyAndOrderFront(nil)
    }

    private func padded(_ s: String, _ width: Int) -> String {
        let truncated = s.count > width ? String(s.prefix(width - 1)) + "…" : s
        return truncated.padding(toLength: width, withPad: " ", startingAt: 0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
