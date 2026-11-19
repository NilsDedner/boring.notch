//
//  PerformanceManager.swift
//  boringNotch
//
//  Samples CPU, memory, network and battery stats for the Performance tab.
//  Sampling only runs while the Performance view is visible.
//

import Combine
import Darwin
import Foundation
import IOKit.ps

@MainActor
final class PerformanceManager: ObservableObject {
    static let shared = PerformanceManager()

    // MARK: - Published values
    @Published private(set) var cpuUsage: Double = 0          // 0...1 (all cores)
    @Published private(set) var cpuHistory: [Double] = Array(repeating: 0, count: 40)
    @Published private(set) var memoryUsedBytes: UInt64 = 0
    @Published private(set) var memoryTotalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    @Published private(set) var memoryPressure: Double = 0    // 0...1
    @Published private(set) var downloadBytesPerSec: Double = 0
    @Published private(set) var uploadBytesPerSec: Double = 0
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var isCharging: Bool = false
    @Published private(set) var thermalState: ProcessInfo.ThermalState = .nominal

    var memoryUsage: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return Double(memoryUsedBytes) / Double(memoryTotalBytes)
    }

    // MARK: - Sampling state
    private var timer: Timer?
    private var visibleCount = 0
    private var previousCPUTicks: [UInt32]?
    private var previousNet: (rx: UInt64, tx: UInt64, time: Date)?

    private init() {}

    // MARK: - Lifecycle
    /// Call when the Performance view appears. Calls are reference counted.
    func startSampling() {
        visibleCount += 1
        guard timer == nil else { return }
        sample()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Call when the Performance view disappears.
    func stopSampling() {
        visibleCount = max(0, visibleCount - 1)
        guard visibleCount == 0 else { return }
        timer?.invalidate()
        timer = nil
        previousCPUTicks = nil
        previousNet = nil
    }

    private func sample() {
        sampleCPU()
        sampleMemory()
        sampleNetwork()
        sampleBattery()
        thermalState = ProcessInfo.processInfo.thermalState
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
            for core in 0..<Int(cpuCount) {
                let base = core * stride
                let user = UInt64(ticks[base + Int(CPU_STATE_USER)] &- prev[base + Int(CPU_STATE_USER)])
                let system = UInt64(ticks[base + Int(CPU_STATE_SYSTEM)] &- prev[base + Int(CPU_STATE_SYSTEM)])
                let nice = UInt64(ticks[base + Int(CPU_STATE_NICE)] &- prev[base + Int(CPU_STATE_NICE)])
                let idle = UInt64(ticks[base + Int(CPU_STATE_IDLE)] &- prev[base + Int(CPU_STATE_IDLE)])
                busy += user + system + nice
                total += user + system + nice + idle
            }
            let usage = total > 0 ? Double(busy) / Double(total) : 0
            cpuUsage = usage
            cpuHistory.append(usage)
            if cpuHistory.count > 40 { cpuHistory.removeFirst(cpuHistory.count - 40) }
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
            }
        }
        previousNet = (rx, tx, now)
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
