//
//  ProcessService.swift
//  BoringNotchXPCHelper
//
//  Memory footprint sampling and app termination for the Performance tab.
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

    /// Input: JSON array of app PIDs. Reply: JSON {"<pid>": {"mem": bytes, "cpu": nanoseconds}}
    /// summed over each app and all of its child processes. "cpu" is the total CPU time used
    /// so far; the app turns two samples into a percentage.
    @objc func appStatistics(_ pidsJSON: Data, with reply: @escaping (Data?) -> Void) {
        guard let pids = try? JSONSerialization.jsonObject(with: pidsJSON) as? [Int] else {
            reply(nil)
            return
        }

        // Build a parent -> children map once, so each app gets its helpers counted
        // (e.g. Chrome/Electron renderer processes are children of the main app).
        var children: [pid_t: [pid_t]] = [:]
        for pid in Self.allPIDs() {
            if let ppid = Self.parentPID(of: pid), ppid > 1 {
                children[ppid, default: []].append(pid)
            }
        }

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)

        var result: [String: [String: UInt64]] = [:]
        for appPID in pids {
            var memory: UInt64 = 0
            var cpuTicks: UInt64 = 0
            var stack: [pid_t] = [pid_t(appPID)]
            var seen = Set<pid_t>()
            while let pid = stack.popLast() {
                guard seen.insert(pid).inserted else { continue }
                if let usage = Self.rusage(of: pid) {
                    memory += usage.ri_phys_footprint
                    cpuTicks += usage.ri_user_time + usage.ri_system_time
                }
                stack.append(contentsOf: children[pid] ?? [])
            }
            // rusage CPU times are in mach absolute time units.
            let nanoseconds = UInt64(Double(cpuTicks) * Double(timebase.numer) / Double(max(timebase.denom, 1)))
            result[String(appPID)] = ["mem": memory, "cpu": nanoseconds]
        }
        reply(try? JSONSerialization.data(withJSONObject: result))
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

    /// ri_phys_footprint is the "Memory" column of Activity Monitor.
    private static func rusage(of pid: pid_t) -> rusage_info_v4? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? usage : nil
    }
}
