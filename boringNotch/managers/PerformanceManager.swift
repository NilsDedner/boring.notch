//
//  PerformanceManager.swift
//  boringNotch
//
//  Samples CPU, memory, network and battery stats for the Performance tab.
//  Sampling only runs while the Performance view is visible.
//

import AppKit
import Combine
import Darwin
import Foundation
import IOKit
import IOKit.ps
import Defaults

/// A regular app with memory footprint and CPU load summed over the app and its child processes.
struct TopApp: Identifiable, Equatable {
    let pid: pid_t
    let name: String
    let icon: NSImage?
    let bytes: UInt64
    /// CPU load like Activity Monitor: 1.0 = one full core (can exceed 1).
    let cpu: Double
    var id: pid_t { pid }

    static func == (lhs: TopApp, rhs: TopApp) -> Bool {
        lhs.pid == rhs.pid && lhs.bytes == rhs.bytes && lhs.cpu == rhs.cpu && lhs.name == rhs.name
    }
}

enum TopAppSort: String, CaseIterable, Defaults.Serializable {
    case memory, cpu
    var title: String { self == .memory ? "Arbeitsspeicher" : "CPU" }
}

/// Shown in the closed notch while the Mac is under heavy load.
struct PerformanceWarning: Equatable {
    enum Kind: Hashable { case thermal, memory, cpu }
    let kind: Kind
    let text: String
    let critical: Bool
}

/// Holds only the current warning, so the notch view doesn't redraw on every sample.
@MainActor
final class PerformanceWarningCenter: ObservableObject {
    static let shared = PerformanceWarningCenter()
    @Published fileprivate(set) var warning: PerformanceWarning?
    private init() {}

    /// Hides the current warning until its condition clears (user clicked it).
    func acknowledge() { PerformanceManager.shared.acknowledgeWarning() }
}

extension Defaults.Keys {
    static let topAppSort = Key<TopAppSort>("topAppSort", default: .memory)
    /// Show load warnings in the closed notch.
    static let performanceWarnings = Key<Bool>("performanceWarnings", default: true)
}

/// A group of CPU cores of the same kind (e.g. Apple Silicon "Super", "Performance", "Efficiency").
struct CoreGroup: Identifiable, Equatable {
    let name: String
    /// sysctl perf level: 0 = fastest.
    let level: Int
    /// Indices into `PerformanceManager.coreUsage`.
    let cores: Range<Int>
    var id: Int { level }

    /// Reads hw.perflevelN.* and orders the groups like the kernel numbers the CPUs:
    /// the slowest level gets the lowest CPU indices, the fastest level the highest.
    static func detect(totalCores: Int) -> [CoreGroup] {
        let levels = sysctlInt("hw.nperflevels") ?? 1
        var groups: [CoreGroup] = []
        var next = 0
        for level in (0..<max(levels, 1)).reversed() {
            let count = sysctlInt("hw.perflevel\(level).logicalcpu") ?? (levels == 1 ? totalCores : 0)
            guard count > 0 else { continue }
            let name = sysctlString("hw.perflevel\(level).name") ?? "Kerne"
            groups.append(CoreGroup(name: name, level: level, cores: next..<min(next + count, totalCores)))
            next += count
        }
        // Fallback if sysctl and the CPU count disagree (Intel, VMs).
        if next != totalCores || groups.isEmpty {
            return [CoreGroup(name: "Kerne", level: 0, cores: 0..<totalCores)]
        }
        return groups.sorted { $0.level < $1.level }    // fastest first for display
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

@MainActor
final class PerformanceManager: ObservableObject {
    static let shared = PerformanceManager()

    // MARK: - Published values
    @Published private(set) var cpuUsage: Double = 0          // 0...1 (all cores)
    /// Load per logical CPU, 0...1, in kernel CPU order.
    @Published private(set) var coreUsage: [Double] = []
    /// Core kinds of this Mac, fastest first.
    let coreGroups: [CoreGroup] = CoreGroup.detect(totalCores: ProcessInfo.processInfo.processorCount)
    /// Total CPU load per second for the last `historyLength` seconds (kept in the background too).
    @Published private(set) var cpuHistory: [Double] = Array(repeating: 0, count: PerformanceManager.historyLength)
    static let historyLength = 120
    // GPU (Apple Silicon: shares RAM with the CPU, so "VRAM" = RAM the GPU currently uses)
    @Published private(set) var gpuUsage: Double?              // nil if the driver gives no stats
    @Published private(set) var gpuHistory: [Double] = Array(repeating: 0, count: PerformanceManager.historyLength)
    @Published private(set) var gpuMemoryBytes: UInt64 = 0
    /// Shader (renderer) and geometry (tiler) load, 0...1.
    @Published private(set) var gpuRenderer: Double = 0
    @Published private(set) var gpuTiler: Double = 0
    private(set) var gpuCoreCount: Int?

    @Published private(set) var memoryUsedBytes: UInt64 = 0
    @Published private(set) var memoryTotalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    @Published private(set) var memoryPressure: Double = 0    // 0...1
    /// Breakdown like Activity Monitor.
    @Published private(set) var memoryAppBytes: UInt64 = 0
    @Published private(set) var memoryWiredBytes: UInt64 = 0
    @Published private(set) var memoryCompressedBytes: UInt64 = 0
    @Published private(set) var memoryCachedBytes: UInt64 = 0
    @Published private(set) var swapUsedBytes: UInt64 = 0
    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical.
    @Published private(set) var memoryPressureLevel: Int = 1

    @Published private(set) var downloadBytesPerSec: Double = 0
    @Published private(set) var uploadBytesPerSec: Double = 0
    @Published private(set) var downloadHistory: [Double] = Array(repeating: 0, count: 60)
    @Published private(set) var uploadHistory: [Double] = Array(repeating: 0, count: 60)
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var isCharging: Bool = false
    @Published private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    @Published private(set) var topApps: [TopApp] = []
    /// Sort order of the top apps list (persisted).
    @Published var topAppSort: TopAppSort = Defaults[.topAppSort] {
        didSet {
            Defaults[.topAppSort] = topAppSort
            rankTopApps()
        }
    }
    private var allApps: [TopApp] = []
    private var previousAppCPU: [pid_t: (nanoseconds: UInt64, time: UInt64)] = [:]

    // SMC sensors (read by the helper)
    struct Fan: Equatable { let rpm: Double; let min: Double; let max: Double }
    @Published private(set) var fans: [Fan] = []
    @Published private(set) var powerWatts: Double?
    @Published private(set) var powerHistory: [Double] = Array(repeating: 0, count: 60)
    private var sensorTask: Task<Void, Never>?

    // Warnings in the closed notch (published through PerformanceWarningCenter)
    private var warning: PerformanceWarning? {
        didSet { if warning != oldValue { PerformanceWarningCenter.shared.warning = warning } }
    }
    private var cpuAlertActive = false
    private var acknowledgedWarnings: Set<PerformanceWarning.Kind> = []
    /// PIDs currently being quit, so the UI can show progress.
    @Published private(set) var terminating: Set<pid_t> = []

    /// How many apps the list shows.
    let topAppLimit = 4

    var memoryUsage: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return Double(memoryUsedBytes) / Double(memoryTotalBytes)
    }

    // MARK: - Sampling state
    private var timer: Timer?
    private var visibleCount = 0
    private var previousCPUTicks: [UInt32]?
    private var previousNet: (rx: UInt64, tx: UInt64, time: Date)?
    private var tick = 0
    private var topAppsTask: Task<Void, Never>?

    private init() {
        gpuCoreCount = Self.readGPUCoreCount()
        // CPU, GPU and network history are sampled all the time (well under a millisecond
        // per second), so the charts are already filled when the tab opens.
        // Everything else only runs while the tab is visible.
        sampleCPU()
        sampleGPU()
        sampleNetwork()
        sampleWarningInputs()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Lifecycle
    /// Call when the Performance view appears. Calls are reference counted.
    func startSampling() {
        visibleCount += 1
        guard visibleCount == 1 else { return }
        tick = 0
        sampleVisibleStats()
        refreshTopApps()
        refreshSensors()
    }

    /// Call when the Performance view disappears.
    func stopSampling() {
        visibleCount = max(0, visibleCount - 1)
        guard visibleCount == 0 else { return }
        topAppsTask?.cancel()
        topAppsTask = nil
        sensorTask?.cancel()
        sensorTask = nil
    }

    private func sample() {
        sampleCPU()
        sampleGPU()
        sampleNetwork()
        sampleWarningInputs()
        evaluateWarnings()
        guard visibleCount > 0 else { return }
        tick += 1
        sampleVisibleStats()
        refreshSensors()
        // The process scan is the expensive part, so refresh it every 2 seconds.
        if tick % 2 == 0 { refreshTopApps() }
    }

    private func sampleVisibleStats() {
        sampleMemory()
        sampleBattery()
    }

    // MARK: - Sensors (fans, power)
    private func refreshSensors() {
        guard sensorTask == nil else { return }
        sensorTask = Task { [weak self] in
            let reading = await XPCHelperClient.shared.readSensors()
            guard let self, !Task.isCancelled else { return }
            self.sensorTask = nil
            guard let reading else { return }
            self.fans = reading.fans.map { Fan(rpm: $0.rpm, min: $0.min, max: $0.max) }
            self.powerWatts = reading.powerWatts
            if let watts = reading.powerWatts {
                self.powerHistory.append(watts)
                if self.powerHistory.count > 60 { self.powerHistory.removeFirst(self.powerHistory.count - 60) }
            }
        }
    }

    // MARK: - Warnings
    /// Cheap values the warnings need even while the tab is closed.
    private func sampleWarningInputs() {
        thermalState = ProcessInfo.processInfo.thermalState
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            memoryPressureLevel = Int(level)
        }
    }

    private func evaluateWarnings() {
        // CPU: average of the last 20 s, with hysteresis so it doesn't flicker.
        let recent = cpuHistory.suffix(20)
        let average = recent.isEmpty ? 0 : recent.reduce(0, +) / Double(recent.count)
        if average >= 0.85 { cpuAlertActive = true } else if average < 0.7 { cpuAlertActive = false }

        var active: [PerformanceWarning] = []
        switch thermalState {
        case .critical: active.append(PerformanceWarning(kind: .thermal, text: "Kritisch", critical: true))
        case .serious: active.append(PerformanceWarning(kind: .thermal, text: "Heiß", critical: false))
        default: break
        }
        if memoryPressureLevel >= 4 {
            active.append(PerformanceWarning(kind: .memory, text: "RAM voll", critical: true))
        } else if memoryPressureLevel >= 2 {
            active.append(PerformanceWarning(kind: .memory, text: "RAM knapp", critical: false))
        }
        if cpuAlertActive {
            active.append(PerformanceWarning(kind: .cpu, text: "CPU \(Int((average * 100).rounded()))%", critical: average >= 0.95))
        }

        // A dismissed warning comes back only after its condition has cleared once.
        let activeKinds = Set(active.map(\.kind))
        acknowledgedWarnings.formIntersection(activeKinds)

        let next = Defaults[.performanceWarnings]
            ? active.first { !acknowledgedWarnings.contains($0.kind) }
            : nil
        warning = next
    }

    /// Hides the current warning until its condition clears (called when the user clicks it).
    func acknowledgeWarning() {
        if let warning { acknowledgedWarnings.insert(warning.kind) }
        warning = nil
    }

    // MARK: - Top apps (memory + CPU)
    func refreshTopApps() {
        guard topAppsTask == nil else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID && !$0.isTerminated
                && $0.bundleIdentifier != "com.apple.finder"
        }
        let pids = apps.map(\.processIdentifier)
        topAppsTask = Task { [weak self] in
            let stats = await XPCHelperClient.shared.appStatistics(for: pids)
            let now = DispatchTime.now().uptimeNanoseconds
            guard let self, !Task.isCancelled else { return }
            var cpuSamples: [pid_t: (nanoseconds: UInt64, time: UInt64)] = [:]
            self.allApps = apps.compactMap { app -> TopApp? in
                let pid = app.processIdentifier
                guard let stat = stats[pid], stat.memory > 0 else { return nil }
                // CPU % = CPU time used since the last sample / wall time since then.
                var cpu = 0.0
                if let previous = self.previousAppCPU[pid], now > previous.time, stat.cpuNanoseconds >= previous.nanoseconds {
                    cpu = Double(stat.cpuNanoseconds - previous.nanoseconds) / Double(now - previous.time)
                }
                cpuSamples[pid] = (stat.cpuNanoseconds, now)
                return TopApp(
                    pid: pid,
                    name: app.localizedName ?? app.bundleIdentifier ?? "PID \(pid)",
                    icon: app.icon,
                    bytes: stat.memory,
                    cpu: cpu
                )
            }
            self.previousAppCPU = cpuSamples
            self.rankTopApps()
            self.topAppsTask = nil
        }
    }

    private func rankTopApps() {
        let sorted: [TopApp]
        switch topAppSort {
        case .memory: sorted = allApps.sorted { $0.bytes > $1.bytes }
        case .cpu: sorted = allApps.sorted { $0.cpu == $1.cpu ? $0.bytes > $1.bytes : $0.cpu > $1.cpu }
        }
        topApps = Array(sorted.prefix(topAppLimit))
    }

    /// Quit an app via the helper. `force` skips the app's own quit handling (unsaved work is lost).
    func terminate(_ app: TopApp, force: Bool) {
        terminating.insert(app.pid)
        Task { [weak self] in
            _ = await XPCHelperClient.shared.terminateApp(pid: app.pid, force: force)
            // Give the app a moment to quit (it may show a "save changes?" dialog).
            try? await Task.sleep(for: .seconds(1.5))
            guard let self else { return }
            self.terminating.remove(app.pid)
            self.refreshTopApps()
        }
    }

    // MARK: - CPU
    private func sampleCPU() {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let stride = Int(CPU_STATE_MAX)
        var ticks = [UInt32]()
        ticks.reserveCapacity(Int(cpuCount) * stride)
        for i in 0..<Int(cpuCount) * stride {
            ticks.append(UInt32(bitPattern: info[i]))
        }

        if let prev = previousCPUTicks, prev.count == ticks.count {
            var busy: UInt64 = 0
            var total: UInt64 = 0
            var perCore = [Double]()
            perCore.reserveCapacity(Int(cpuCount))
            for core in 0..<Int(cpuCount) {
                let base = core * stride
                let user = UInt64(ticks[base + Int(CPU_STATE_USER)] &- prev[base + Int(CPU_STATE_USER)])
                let system = UInt64(ticks[base + Int(CPU_STATE_SYSTEM)] &- prev[base + Int(CPU_STATE_SYSTEM)])
                let nice = UInt64(ticks[base + Int(CPU_STATE_NICE)] &- prev[base + Int(CPU_STATE_NICE)])
                let idle = UInt64(ticks[base + Int(CPU_STATE_IDLE)] &- prev[base + Int(CPU_STATE_IDLE)])
                let coreBusy = user + system + nice
                let coreTotal = coreBusy + idle
                busy += coreBusy
                total += coreTotal
                perCore.append(coreTotal > 0 ? Double(coreBusy) / Double(coreTotal) : 0)
            }
            let usage = total > 0 ? Double(busy) / Double(total) : 0
            cpuUsage = usage
            coreUsage = perCore
            cpuHistory.append(usage)
            if cpuHistory.count > Self.historyLength { cpuHistory.removeFirst(cpuHistory.count - Self.historyLength) }

        }
        previousCPUTicks = ticks
    }

    // MARK: - Memory
    private func sampleMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize)

        // Same idea as Activity Monitor's "Memory Used": app + wired + compressed.
        let app = UInt64(stats.internal_page_count &- stats.purgeable_count) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        memoryUsedBytes = min(app + wired + compressed, memoryTotalBytes)
        memoryAppBytes = app
        memoryWiredBytes = wired
        memoryCompressedBytes = compressed
        // File cache + purgeable memory: used, but macOS hands it back on demand.
        memoryCachedBytes = UInt64(stats.external_page_count + stats.purgeable_count) * page

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            swapUsedBytes = swap.xsu_used
        }

        // Rough pressure indicator: share of RAM held by the compressor + wired.
        memoryPressure = memoryTotalBytes > 0
            ? min(1, Double(wired + compressed) / Double(memoryTotalBytes))
            : 0
    }

    // MARK: - Network
    private func sampleNetwork() {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return }
        defer { freeifaddrs(ifaddr) }

        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0 && (flags & IFF_LOOPBACK) == 0
            if isUp,
               let addr = current.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_LINK),
               let data = current.pointee.ifa_data
            {
                let netData = data.assumingMemoryBound(to: if_data.self).pointee
                rx += UInt64(netData.ifi_ibytes)
                tx += UInt64(netData.ifi_obytes)
            }
            ptr = current.pointee.ifa_next
        }

        let now = Date()
        if let prev = previousNet {
            let dt = now.timeIntervalSince(prev.time)
            if dt > 0 {
                // 32-bit counters can wrap; ignore negative deltas.
                downloadBytesPerSec = rx >= prev.rx ? Double(rx - prev.rx) / dt : 0
                uploadBytesPerSec = tx >= prev.tx ? Double(tx - prev.tx) / dt : 0
                downloadHistory.append(downloadBytesPerSec)
                uploadHistory.append(uploadBytesPerSec)
                if downloadHistory.count > 60 { downloadHistory.removeFirst(downloadHistory.count - 60) }
                if uploadHistory.count > 60 { uploadHistory.removeFirst(uploadHistory.count - 60) }
            }
        }
        previousNet = (rx, tx, now)
    }

    // MARK: - GPU
    /// Reads the GPU driver's PerformanceStatistics from the IORegistry (no special rights needed).
    private func sampleGPU() {
        guard let stats = Self.gpuStatistics() else {
            gpuUsage = nil
            return
        }
        if let utilization = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
            let usage = min(max(utilization / 100, 0), 1)
            gpuUsage = usage
            gpuHistory.append(usage)
            if gpuHistory.count > Self.historyLength { gpuHistory.removeFirst(gpuHistory.count - Self.historyLength) }
        }
        gpuRenderer = min(max(((stats["Renderer Utilization %"] as? NSNumber)?.doubleValue ?? 0) / 100, 0), 1)
        gpuTiler = min(max(((stats["Tiler Utilization %"] as? NSNumber)?.doubleValue ?? 0) / 100, 0), 1)
        if let inUse = (stats["In use system memory"] as? NSNumber)?.uint64Value {
            gpuMemoryBytes = inUse
        }
    }

    private static func gpuStatistics() -> [String: Any]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            if let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any], stats["Device Utilization %"] != nil {
                return stats
            }
        }
        return nil
    }

    private static func readGPUCoreCount() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            if let count = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber {
                return count.intValue
            }
        }
        return nil
    }

    // MARK: - Battery
    private func sampleBattery() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any]
        else {
            batteryPercent = nil
            return
        }
        if let current = desc[kIOPSCurrentCapacityKey] as? Int,
           let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0
        {
            batteryPercent = Int((Double(current) / Double(max) * 100).rounded())
        }
        isCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
    }
}
