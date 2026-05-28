import Foundation
import Darwin
import IOKit
import IOKit.ps

// MARK: - Metrics

/// Reads system resource usage straight from the kernel / IORegistry — no
/// third-party dependencies, no elevated privileges.
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

    // MARK: GPU (IORegistry — IOAccelerator/PerformanceStatistics)

    struct GPU { var utilization: Double; var memUsed: UInt64 }

    /// GPU utilization % + in-use video/unified memory. nil if no accelerator
    /// exposes the stats (key names vary by GPU/OS — we fall back gracefully).
    func gpu() -> GPU? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var result: GPU?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let props = Self.ioProperties(service),
               let perf = props["PerformanceStatistics"] as? [String: Any] {
                let util = (perf["Device Utilization %"] as? NSNumber)?.doubleValue
                        ?? (perf["GPU Activity(%)"] as? NSNumber)?.doubleValue
                if let util = util {
                    let mem = (perf["In use system memory"] as? NSNumber)?.uint64Value ?? 0
                    result = GPU(utilization: util, memUsed: mem)
                    IOObjectRelease(service)
                    break
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return result
    }

    // MARK: Disk I/O (IOBlockStorageDriver)

    /// Cumulative bytes read / written across all block storage drivers.
    func diskBytes() -> (read: UInt64, write: UInt64) {
        var read: UInt64 = 0, write: UInt64 = 0
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let props = Self.ioProperties(service),
               let stats = props["Statistics"] as? [String: Any] {
                read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return (read, write)
    }

    // MARK: Battery (IOPowerSources)

    struct Battery { var level: Double; var charging: Bool; var minutesRemaining: Int? }

    /// Internal battery state, or nil on a machine without one (desktop).
    func battery() -> Battery? {
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as NSArray
        for ps in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps as CFTypeRef)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = (desc[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue ?? 0
            let max = (desc[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue ?? 100
            let level = max > 0 ? cur / max * 100 : 0
            let charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            // macOS time-to-full estimates are unreliable on Apple Silicon (pmset's
            // IOPS estimate disagrees with the battery's own AvgTimeToFull), so only
            // surface a time while discharging — time-to-empty is far more stable.
            let mins = charging ? -1 : ((desc[kIOPSTimeToEmptyKey] as? NSNumber)?.intValue ?? -1)
            return Battery(level: level, charging: charging, minutesRemaining: mins > 0 ? mins : nil)
        }
        return nil
    }

    /// All IORegistry properties of a service entry as a Swift dictionary.
    private static func ioProperties(_ entry: io_registry_entry_t) -> [String: Any]? {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        return dict
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
