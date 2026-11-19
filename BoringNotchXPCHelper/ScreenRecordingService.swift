//
//  ScreenRecordingService.swift
//  BoringNotchXPCHelper
//
//  Screen recordings for the Screenshots tab. `screencapture -v` exits immediately
//  inside the app sandbox, so the unsandboxed helper runs it. The helper belongs to
//  the app bundle, so the app's Screen Recording permission applies.
//

import Foundation

private final class RecordingState: @unchecked Sendable {
    static let shared = RecordingState()
    let lock = NSLock()
    var process: Process?
    var outputPath: String?
}

extension BoringNotchXPCHelper {
    /// Input: JSON array of extra screencapture arguments ("-R", "x,y,w,h" or "-D", "n").
    /// Replies true once the recording is running.
    @objc func startScreenRecording(_ argumentsJSON: Data, outputPath: String, with reply: @escaping (Bool) -> Void) {
        guard let arguments = try? JSONSerialization.jsonObject(with: argumentsJSON) as? [String],
              Self.isAllowedRecording(arguments: arguments, outputPath: outputPath)
        else {
            reply(false)
            return
        }

        let state = RecordingState.shared
        state.lock.lock()
        if let running = state.process, running.isRunning {
            state.lock.unlock()
            reply(false)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-v", "-x"] + arguments + [outputPath]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            state.lock.unlock()
            reply(false)
            return
        }
        state.process = process
        state.outputPath = outputPath
        state.lock.unlock()

        // screencapture quits right away if the permission is missing.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) {
            reply(process.isRunning)
        }
    }

    /// Stops the recording (SIGINT lets screencapture finalise the movie).
    /// Replies true if the movie file exists afterwards.
    @objc func stopScreenRecording(with reply: @escaping (Bool) -> Void) {
        let state = RecordingState.shared
        state.lock.lock()
        let process = state.process
        let outputPath = state.outputPath
        state.process = nil
        state.outputPath = nil
        state.lock.unlock()

        guard let process, let outputPath else {
            reply(false)
            return
        }

        DispatchQueue.global().async {
            if process.isRunning { process.interrupt() }
            let deadline = Date().addingTimeInterval(20)
            while process.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if process.isRunning { process.terminate() }
            reply(FileManager.default.fileExists(atPath: outputPath))
        }
    }

    @objc func isScreenRecording(with reply: @escaping (Bool) -> Void) {
        let state = RecordingState.shared
        state.lock.lock()
        let running = state.process?.isRunning == true
        state.lock.unlock()
        reply(running)
    }

    /// Only the argument shapes the app uses, and only .mov files in the user's Pictures folder.
    private static func isAllowedRecording(arguments: [String], outputPath: String) -> Bool {
        guard arguments.count == 2 else { return false }
        let value = arguments[1]
        switch arguments[0] {
        case "-R":
            let parts = value.split(separator: ",")
            guard parts.count == 4, parts.allSatisfy({ Int($0) != nil }) else { return false }
        case "-D":
            guard let display = Int(value), (1...16).contains(display) else { return false }
        default:
            return false
        }

        let url = URL(fileURLWithPath: outputPath).standardizedFileURL
        guard url.pathExtension == "mov",
              let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir
        else { return false }
        let pictures = URL(fileURLWithPath: String(cString: dir)).appendingPathComponent("Pictures").path + "/"
        return url.path.hasPrefix(pictures)
    }
}
