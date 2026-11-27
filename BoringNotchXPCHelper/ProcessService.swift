//
//  ProcessService.swift
//  BoringNotchXPCHelper
//
//  Memory, CPU and energy sampling (apps and VMs) and app termination for the Performance tab.
//  Runs in the unsandboxed helper because the sandboxed app can't inspect
//  or quit other processes.
//

import AppKit
import Darwin

extension BoringNotchXPCHelper {
    /// Apps the notch must never offer to quit.
    private static let protectedBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.loginwindow",
        "com.apple.systemuiserver",
        "theboringteam.boringnotch",
    ]

    /// Input: JSON array of app PIDs.
    /// Reply: JSON {"apps": {"<pid>": {"mem": bytes, "cpu": ns, "energy": nJ}},
    ///              "vms": [{"pid", "mem", "cpu", "energy", "label"?, "ownerPath"?}]}.
    /// App values are summed over the app and all of its child processes. "cpu" and "energy"
    /// are totals so far; the app turns two samples into a percentage / watts.
    /// "vms" lists Virtualization.framework VM processes (Lima, Docker, …). They run as XPC
    /// services under launchd, so they never show up as a child of the app that started them.
    @objc func appStatistics(_ pidsJSON: Data, with reply: @escaping (Data?) -> Void) {
        guard let pids = try? JSONSerialization.jsonObject(with: pidsJSON) as? [Int] else {
            reply(nil)
            return
        }

        // Build a parent -> children map once, so each app gets its helpers counted
        // (e.g. Chrome/Electron renderer processes are children of the main app).
        let all = Self.allPIDs()
        var children: [pid_t: [pid_t]] = [:]
        for pid in all {
            if let ppid = Self.parentPID(of: pid), ppid > 1 {
                children[ppid, default: []].append(pid)
            }
        }

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        // rusage CPU times are in mach absolute time units.
        func nanoseconds(_ ticks: UInt64) -> UInt64 {
            UInt64(Double(ticks) * Double(timebase.numer) / Double(max(timebase.denom, 1)))
        }

        var apps: [String: [String: UInt64]] = [:]
        for appPID in pids {
            var memory: UInt64 = 0
            var cpuTicks: UInt64 = 0
            var energy: UInt64 = 0
            var stack: [pid_t] = [pid_t(appPID)]
            var seen = Set<pid_t>()
            while let pid = stack.popLast() {
                guard seen.insert(pid).inserted else { continue }
                if let usage = Self.rusage(of: pid) {
                    memory += usage.ri_phys_footprint
                    cpuTicks += usage.ri_user_time + usage.ri_system_time
                    energy += usage.ri_energy_nj
                }
                stack.append(contentsOf: children[pid] ?? [])
            }
            apps[String(appPID)] = ["mem": memory, "cpu": nanoseconds(cpuTicks), "energy": energy]
        }

        var vms: [[String: Any]] = []
        let vmPIDs = all.filter { Self.path(of: $0)?.hasSuffix("/com.apple.Virtualization.VirtualMachine") == true }
        if !vmPIDs.isEmpty {
            let limaHosts = Self.limaHostAgents(in: all)
            for pid in vmPIDs {
                guard let usage = Self.rusage(of: pid) else { continue }
                var entry: [String: Any] = [
                    "pid": Int(pid),
                    "mem": usage.ri_phys_footprint,
                    "cpu": nanoseconds(usage.ri_user_time + usage.ri_system_time),
                    "energy": usage.ri_energy_nj,
                ]
                // Lima: the hostagent started right before the VM process.
                if let start = Self.startTime(of: pid),
                   let host = limaHosts.filter({ $0.start <= start + 2 && start - $0.start < 120 })
                       .max(by: { $0.start < $1.start }) {
                    entry["label"] = "Lima · \(host.instance)"
                } else if let owner = Self.responsiblePID(for: pid), owner != pid,
                          let ownerPath = Self.path(of: owner) {
                    entry["ownerPath"] = ownerPath
                }
                vms.append(entry)
            }
        }

        reply(try? JSONSerialization.data(withJSONObject: ["apps": apps, "vms": vms]))
    }

    @objc func terminateApp(_ pid: Int32, force: Bool, with reply: @escaping (Bool) -> Void) {
        guard let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular,
              !Self.protectedBundleIDs.contains(app.bundleIdentifier ?? "")
        else {
            reply(false)
            return
        }
        reply(force ? app.forceTerminate() : app.terminate())
    }

    // MARK: - libproc helpers

    private static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 128)
        let count = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// ri_phys_footprint is the "Memory" column of Activity Monitor,
    /// ri_energy_nj the energy macOS has billed to the process so far.
    private static func rusage(of pid: pid_t) -> rusage_info_v6? {
        var usage = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        return result == 0 ? usage : nil
    }

    private static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Process start time (seconds since 1970).
    private static func startTime(of pid: pid_t) -> Double? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
    }

    /// Command line arguments (argv) via sysctl KERN_PROCARGS2.
    private static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }     // executable path
        while index < size, buffer[index] == 0 { index += 1 }     // padding
        var args: [String] = []
        while index < size, args.count < Int(argc) {
            let begin = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[begin..<index], as: UTF8.self))
            index += 1
        }
        return args
    }

    /// Running `limactl hostagent … <instance>` processes with their start times.
    private static func limaHostAgents(in pids: [pid_t]) -> [(start: Double, instance: String)] {
        pids.compactMap { pid in
            guard path(of: pid)?.hasSuffix("/limactl") == true,
                  let args = arguments(of: pid), args.contains("hostagent"),
                  let instance = args.last, !instance.hasPrefix("-"),
                  let start = startTime(of: pid)
            else { return nil }
            return (start, instance)
        }
    }

    /// The process macOS holds responsible for `pid` (what Activity Monitor groups by).
    private static let responsibleFunction: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    private static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let function = responsibleFunction else { return nil }
        let owner = function(pid)
        return owner > 0 ? owner : nil
    }
}
