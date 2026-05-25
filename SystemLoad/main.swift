import AppKit
import Foundation
import Darwin

// MARK: - Formatting helpers

private func fmtMem(_ bytes: UInt64) -> String {
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

// MARK: - Metrics

final class Metrics {
    private var prevCPUTicks: (UInt64, UInt64, UInt64, UInt64)?
    private let pageSize = UInt64(vm_kernel_page_size)
    let totalRAM = ProcessInfo.processInfo.physicalMemory

    /// Returns CPU busy percentage since the previous call (0 on first call).
    func cpuUsage() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        defer { prevCPUTicks = (user, system, idle, nice) }
        guard let prev = prevCPUTicks else { return 0 }
        let dUser = Double(user &- prev.0)
        let dSystem = Double(system &- prev.1)
        let dIdle = Double(idle &- prev.2)
        let dNice = Double(nice &- prev.3)
        let total = dUser + dSystem + dIdle + dNice
        guard total > 0 else { return 0 }
        return (dUser + dSystem + dNice) / total * 100.0
    }

    struct Mem { var used: UInt64; var total: UInt64; var compressed: UInt64 }

    func memory() -> Mem {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return Mem(used: 0, total: totalRAM, compressed: 0) }
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        // "Memory Used" matches Activity Monitor: App Memory + Wired + Compressed.
        // (Reclaimable file cache and free/speculative pages are NOT counted as used,
        //  so the figure isn't pegged near 100% the way top's total-minus-free is.)
        let appMemory = (UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let used = appMemory + wired + compressed
        return Mem(used: min(used, totalRAM), total: totalRAM, compressed: compressed)
    }

    /// 1 = normal, 2 = warning, 4 = critical.
    func memoryPressureLevel() -> Int {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) != 0 { return 1 }
        return Int(level)
    }

    func swap() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &usage, &size, nil, 0) != 0 { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }

    /// Cumulative bytes received / sent across physical interfaces (excludes loopback).
    func networkBytes() -> (rx: UInt64, tx: UInt64) {
        var rx: UInt64 = 0, tx: UInt64 = 0
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return (0, 0) }
        defer { freeifaddrs(ifaddrPtr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let ifa = cur.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK) {
                let name = String(cString: ifa.ifa_name)
                if !name.hasPrefix("lo"), let dataPtr = ifa.ifa_data {
                    let d = dataPtr.assumingMemoryBound(to: if_data.self).pointee
                    rx += UInt64(d.ifi_ibytes)
                    tx += UInt64(d.ifi_obytes)
                }
            }
            ptr = ifa.ifa_next
        }
        return (rx, tx)
    }

    /// Top processes via `ps`. byCPU=true → sorted by %CPU, else by RSS. Sampled on demand (menu open).
    func topProcesses(byCPU: Bool, limit: Int) -> [(name: String, value: String)] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        if byCPU {
            task.arguments = ["-axco", "%cpu=,comm=", "-r"]
        } else {
            task.arguments = ["-axco", "rss=,comm=", "-m"]
        }
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return [] }
        var result: [(String, String)] = []
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let sp = trimmed.firstIndex(of: " ") else { continue }
            let numStr = String(trimmed[..<sp])
            let name = String(trimmed[trimmed.index(after: sp)...]).trimmingCharacters(in: .whitespaces)
            if name.isEmpty || name == "ps" || name == "Pulse" { continue }
            if byCPU {
                guard let cpu = Double(numStr), cpu >= 0.1 else { continue }
                result.append((name, String(format: "%.0f%%", cpu)))
            } else {
                guard let rssKB = Double(numStr) else { continue }
                result.append((name, fmtMem(UInt64(rssKB) * 1024)))
            }
            if result.count >= limit { break }
        }
        return result
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let metrics = Metrics()
    private var timer: Timer?

    private var cpuHistory: [Double] = []
    private var lastCPU: Double = 0
    private var lastMem = Metrics.Mem(used: 0, total: 0, compressed: 0)

    private var lastNet: (rx: UInt64, tx: UInt64) = (0, 0)
    private var lastNetTime: Date?
    private var rxRate: Double = 0
    private var txRate: Double = 0

    private let interval: TimeInterval = 2.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prime delta-based metrics so the first displayed value is real.
        _ = metrics.cpuUsage()
        lastNet = metrics.networkBytes()
        lastNetTime = Date()

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        update()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.current.add(t, forMode: .common)
        timer = t
    }

    // MARK: Sampling

    private func update() {
        let cpu = metrics.cpuUsage()
        lastCPU = cpu
        cpuHistory.append(cpu)
        if cpuHistory.count > 60 { cpuHistory.removeFirst(cpuHistory.count - 60) }

        lastMem = metrics.memory()

        let net = metrics.networkBytes()
        let now = Date()
        if let prevTime = lastNetTime {
            let dt = now.timeIntervalSince(prevTime)
            if dt > 0 {
                rxRate = Double(net.rx &- lastNet.rx) / dt
                txRate = Double(net.tx &- lastNet.tx) / dt
            }
        }
        lastNet = net
        lastNetTime = now

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
        let title = NSMutableAttributedString()
        title.append(symbolAttachment("cpu", fallback: "CPU"))
        title.append(NSAttributedString(string: String(format: " %.0f%%  ", cpu), attributes: textAttrs))
        title.append(symbolAttachment("memorychip", fallback: "RAM"))
        title.append(NSAttributedString(string: String(format: " %.0f%%", ram), attributes: textAttrs))
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

        menu.addItem(infoItem(String(format: "%@↓ %@   ↑ %@", padded("Network", 11) as NSString, fmtRate(rxRate) as NSString, fmtRate(txRate) as NSString)))

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
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
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
