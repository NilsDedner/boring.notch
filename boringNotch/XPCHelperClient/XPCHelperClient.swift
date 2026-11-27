import Foundation
import Cocoa
import AsyncXPCConnection

final class XPCHelperClient: NSObject {
    nonisolated static let shared = XPCHelperClient()
    
    private let serviceName = "theboringteam.boringnotch.BoringNotchXPCHelper"
    
    private var remoteService: RemoteXPCService<BoringNotchXPCHelperProtocol>?
    private var connection: NSXPCConnection?
    private var lastKnownAuthorization: Bool?
    private var monitoringTask: Task<Void, Never>?
    
    deinit {
        connection?.invalidate()
        stopMonitoringAccessibilityAuthorization()
    }
    
    // MARK: - Connection Management (Main Actor Isolated)
    
    @MainActor
    private func ensureRemoteService() -> RemoteXPCService<BoringNotchXPCHelperProtocol> {
        if let existing = remoteService {
            return existing
        }
        
        let conn = NSXPCConnection(serviceName: serviceName)
        
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.remoteService = nil
            }
        }
        
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.remoteService = nil
            }
        }
        
        conn.resume()
        
        let service = RemoteXPCService<BoringNotchXPCHelperProtocol>(
            connection: conn,
            remoteInterface: BoringNotchXPCHelperProtocol.self
        )
        
        connection = conn
        remoteService = service
        return service
    }
    
    @MainActor
    private func getRemoteService() -> RemoteXPCService<BoringNotchXPCHelperProtocol>? {
        remoteService
    }
    
    @MainActor
    private func notifyAuthorizationChange(_ granted: Bool) {
        guard lastKnownAuthorization != granted else { return }
        lastKnownAuthorization = granted
        NotificationCenter.default.post(
            name: .accessibilityAuthorizationChanged,
            object: nil,
            userInfo: ["granted": granted]
        )
    }

    // MARK: - Monitoring
    nonisolated func startMonitoringAccessibilityAuthorization(every interval: TimeInterval = 3.0) {
        // Ensure only one monitor exists
        stopMonitoringAccessibilityAuthorization()
        monitoringTask = Task.detached { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                // Call the helper method periodically which will notify on change
                _ = await self.isAccessibilityAuthorized()
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch { break }
            }
        }
    }

    nonisolated func stopMonitoringAccessibilityAuthorization() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    // Expose whether the client is actively monitoring (useful for tests/debug)
    var isMonitoring: Bool {
        return monitoringTask != nil
    }
    
    // MARK: - Accessibility
    
    nonisolated func requestAccessibilityAuthorization() {
        Task {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            try? await service.withService { service in
                service.requestAccessibilityAuthorization()
            }
        }
    }
    
    nonisolated func isAccessibilityAuthorized() async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let result: Bool = try await service.withContinuation { service, continuation in
                service.isAccessibilityAuthorized { authorized in
                    continuation.resume(returning: authorized)
                }
            }
            await MainActor.run {
                notifyAuthorizationChange(result)
            }
            return result
        } catch {
            return false
        }
    }
    
    nonisolated func ensureAccessibilityAuthorization(promptIfNeeded: Bool) async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let result: Bool = try await service.withContinuation { service, continuation in
                service.ensureAccessibilityAuthorization(promptIfNeeded) { authorized in
                    continuation.resume(returning: authorized)
                }
            }
            await MainActor.run {
                notifyAuthorizationChange(result)
            }
            return result
        } catch {
            return false
        }
    }
    
    // MARK: - Keyboard Brightness
    
    nonisolated func isKeyboardBrightnessAvailable() async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.isKeyboardBrightnessAvailable { available in
                    continuation.resume(returning: available)
                }
            }
        } catch {
            return false
        }
    }
    
    nonisolated func currentKeyboardBrightness() async -> Float? {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let result: NSNumber? = try await service.withContinuation { service, continuation in
                service.currentKeyboardBrightness { value in
                    continuation.resume(returning: value)
                }
            }
            return result?.floatValue
        } catch {
            return nil
        }
    }
    
    nonisolated func setKeyboardBrightness(_ value: Float) async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.setKeyboardBrightness(value) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            return false
        }
    }
    
    // MARK: - Screen Brightness
    
    nonisolated func isScreenBrightnessAvailable() async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.isScreenBrightnessAvailable { available in
                    continuation.resume(returning: available)
                }
            }
        } catch {
            return false
        }
    }
    
    nonisolated func currentScreenBrightness() async -> Float? {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let result: NSNumber? = try await service.withContinuation { service, continuation in
                service.currentScreenBrightness { value in
                    continuation.resume(returning: value)
                }
            }
            return result?.floatValue
        } catch {
            return nil
        }
    }
    
    nonisolated func setScreenBrightness(_ value: Float) async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.setScreenBrightness(value) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            return false
        }
    }

    // MARK: - Processes

    struct ProcessSample: Sendable {
        /// Memory footprint in bytes, total CPU time in ns, total energy in nJ.
        let memory: UInt64
        let cpuNanoseconds: UInt64
        let energyNanojoules: UInt64
    }

    struct VMSample: Sendable {
        let pid: pid_t
        let sample: ProcessSample
        /// e.g. "Lima · default", when the helper could identify the VM.
        let label: String?
        /// Executable of the process macOS holds responsible for the VM (e.g. inside Docker.app).
        let ownerPath: String?
    }

    struct AppStatistics: Sendable {
        var apps: [pid_t: ProcessSample] = [:]
        var vms: [VMSample] = []
    }

    /// Per app (children included) memory, CPU time and energy, plus running virtual machines.
    nonisolated func appStatistics(for pids: [pid_t]) async -> AppStatistics {
        guard let payload = try? JSONSerialization.data(withJSONObject: pids.map { Int($0) }) else { return AppStatistics() }
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let data: Data? = try await service.withContinuation { service, continuation in
                service.appStatistics(payload) { reply in
                    continuation.resume(returning: reply)
                }
            }
            guard let data,
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return AppStatistics() }

            func sample(_ values: [String: Any]) -> ProcessSample {
                ProcessSample(
                    memory: (values["mem"] as? NSNumber)?.uint64Value ?? 0,
                    cpuNanoseconds: (values["cpu"] as? NSNumber)?.uint64Value ?? 0,
                    energyNanojoules: (values["energy"] as? NSNumber)?.uint64Value ?? 0
                )
            }
            var result = AppStatistics()
            for (key, value) in dict["apps"] as? [String: [String: Any]] ?? [:] {
                guard let pid = pid_t(key) else { continue }
                result.apps[pid] = sample(value)
            }
            for value in dict["vms"] as? [[String: Any]] ?? [] {
                guard let pid = (value["pid"] as? NSNumber)?.int32Value else { continue }
                result.vms.append(VMSample(pid: pid, sample: sample(value),
                                           label: value["label"] as? String,
                                           ownerPath: value["ownerPath"] as? String))
            }
            return result
        } catch {
            return AppStatistics()
        }
    }

    struct SensorReading: Sendable {
        struct Fan: Sendable { let rpm: Double; let min: Double; let max: Double }
        let fans: [Fan]
        let powerWatts: Double?
    }

    /// Fan speeds and system power from the SMC (via the helper).
    nonisolated func readSensors() async -> SensorReading? {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            let data: Data? = try await service.withContinuation { service, continuation in
                service.readSensors { reply in
                    continuation.resume(returning: reply)
                }
            }
            guard let data, let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let fans = (dict["fans"] as? [[String: NSNumber]] ?? []).map {
                SensorReading.Fan(rpm: $0["rpm"]?.doubleValue ?? 0, min: $0["min"]?.doubleValue ?? 0, max: $0["max"]?.doubleValue ?? 0)
            }
            return SensorReading(fans: fans, powerWatts: (dict["power"] as? NSNumber)?.doubleValue)
        } catch {
            return nil
        }
    }

    nonisolated func terminateApp(pid: pid_t, force: Bool) async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.terminateApp(pid, force: force) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            return false
        }
    }

    // MARK: - Screen recording (runs in the helper; screencapture -v fails in the sandbox)

    nonisolated func startScreenRecording(arguments: [String], outputPath: String) async -> Bool {
        guard let payload = try? JSONSerialization.data(withJSONObject: arguments) else { return false }
        do {
            let service = await MainActor.run { ensureRemoteService() }
            return try await service.withContinuation { service, continuation in
                service.startScreenRecording(payload, outputPath: outputPath) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            return false
        }
    }

    nonisolated func stopScreenRecording() async -> Bool {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            return try await service.withContinuation { service, continuation in
                service.stopScreenRecording { written in
                    continuation.resume(returning: written)
                }
            }
        } catch {
            return false
        }
    }

    nonisolated func isScreenRecording() async -> Bool {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            return try await service.withContinuation { service, continuation in
                service.isScreenRecording { running in
                    continuation.resume(returning: running)
                }
            }
        } catch {
            return false
        }
    }
}

extension Notification.Name {
    static let accessibilityAuthorizationChanged = Notification.Name("accessibilityAuthorizationChanged")
}


