//
//  SensorService.swift
//  BoringNotchXPCHelper
//
//  Fan speeds and system power from the SMC for the Performance tab.
//  The sandboxed app may not open the AppleSMC user client, the helper can.
//

import Foundation
import IOKit

/// Mirrors the C `SMCKeyData_t` struct used by the AppleSMC user client (80 bytes).
private struct SMCKeyData {
    struct Vers { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
    struct PLimit { var version: UInt16 = 0; var length: UInt16 = 0; var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0 }
    struct KeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
    var key: UInt32 = 0
    var vers = Vers()
    var pLimitData = PLimit()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

/// Read-only SMC access (only key info and key reads, never writes).
private final class SMC: @unchecked Sendable {
    static let shared = SMC()
    private let lock = NSLock()
    private var connection: io_connect_t = 0

    private init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, 0, &connection) != kIOReturnSuccess { connection = 0 }
    }

    private static func fourCC(_ key: String) -> UInt32 { key.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

    private func call(_ input: inout SMCKeyData) -> SMCKeyData? {
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCKeyData>.stride, &output, &outputSize)
        return result == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    /// Reads a numeric key (types flt, ui8, ui16, fpe2); nil if missing.
    func number(_ key: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard connection != 0 else { return nil }

        var infoRequest = SMCKeyData()
        infoRequest.key = Self.fourCC(key)
        infoRequest.data8 = 9                                   // kSMCGetKeyInfo
        guard let info = call(&infoRequest) else { return nil }

        var readRequest = SMCKeyData()
        readRequest.key = Self.fourCC(key)
        readRequest.keyInfo.dataSize = info.keyInfo.dataSize
        readRequest.data8 = 5                                   // kSMCReadKey
        guard let output = call(&readRequest) else { return nil }

        let size = Int(info.keyInfo.dataSize)
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(size)) }
        switch info.keyInfo.dataType {
        case Self.fourCC("flt ") where size == 4:
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) })
        case Self.fourCC("ui8 ") where size >= 1:
            return Double(bytes[0])
        case Self.fourCC("ui16") where size >= 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case Self.fourCC("fpe2") where size >= 2:
            return Double((Int(bytes[0]) << 6) + (Int(bytes[1]) >> 2))
        default:
            return nil
        }
    }
}

extension BoringNotchXPCHelper {
    /// Reply: JSON {"fans": [{"rpm": n, "min": n, "max": n}], "power": watts?}.
    @objc func readSensors(with reply: @escaping (Data?) -> Void) {
        let smc = SMC.shared
        var fans: [[String: Double]] = []
        let count = Int(smc.number("FNum") ?? 0)
        for index in 0..<min(count, 4) {
            guard let rpm = smc.number("F\(index)Ac") else { continue }
            fans.append([
                "rpm": rpm,
                "min": smc.number("F\(index)Mn") ?? 0,
                "max": smc.number("F\(index)Mx") ?? 0,
            ])
        }
        var result: [String: Any] = ["fans": fans]
        // PSTR = total system power on Apple Silicon.
        if let power = smc.number("PSTR"), power.isFinite, power >= 0 {
            result["power"] = power
        }
        reply(try? JSONSerialization.data(withJSONObject: result))
    }
}
