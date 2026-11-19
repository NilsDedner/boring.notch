//
//  ScreenRecorder.swift
//  boringNotch
//
//  Screen recording with ScreenCaptureKit (macOS 15+): video of a display or an
//  area of it, plus system audio and/or the microphone. Boring Notch's own windows
//  (the notch, the red area frame) are left out of the video.
//

import AppKit
import AVFoundation
import ScreenCaptureKit

@available(macOS 15.0, *)
final class ScreenRecorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, SCStreamOutput, @unchecked Sendable {
    enum RecorderError: LocalizedError {
        case noDisplay
        var errorDescription: String? { "Kein Bildschirm für die Aufnahme gefunden." }
    }

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var outputURL: URL?
    private var finishContinuation: CheckedContinuation<Bool, Never>?
    private var didFinish = false
    private var failed = false
    private let sampleQueue = DispatchQueue(label: "boringnotch.screenrecorder.samples")

    /// Called on the main actor when the recording ends without `stop()`
    /// (e.g. "Stop sharing" in the menu bar, display unplugged).
    var onUnexpectedStop: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - rect: Area in global Cocoa coordinates, or nil for the whole screen.
    ///   - screen: The screen to record (the one containing `rect`).
    func start(rect: CGRect?, screen: NSScreen, systemAudio: Bool, microphone: Bool, outputURL: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw RecorderError.noDisplay
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        if let rect {
            // sourceRect is in display points with the origin at the display's top-left.
            let local = CGRect(
                x: rect.minX - screen.frame.minX,
                y: screen.frame.maxY - rect.maxY,
                width: rect.width,
                height: rect.height
            )
            config.sourceRect = local
            config.width = Int((local.width * scale).rounded()) & ~1     // encoders want even sizes
            config.height = Int((local.height * scale).rounded()) & ~1
        } else {
            config.width = Int((CGFloat(display.width) * scale).rounded()) & ~1
            config.height = Int((CGFloat(display.height) * scale).rounded()) & ~1
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.queueDepth = 6
        config.capturesAudio = systemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = microphone

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        // SCRecordingOutput writes the file; these no-op outputs only keep
        // ScreenCaptureKit from logging "dropping frame" for unhandled types.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue) }
        if microphone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue) }

        let outputConfig = SCRecordingOutputConfiguration()
        outputConfig.outputURL = outputURL
        outputConfig.outputFileType = .mov
        outputConfig.videoCodecType = .h264     // plays everywhere (Teams, Slack, Mail)
        let output = SCRecordingOutput(configuration: outputConfig, delegate: self)
        try stream.addRecordingOutput(output)

        self.stream = stream
        self.recordingOutput = output
        self.outputURL = outputURL
        try await stream.startCapture()
    }

    /// Stops and waits until the movie file is finalised. Returns true if it was written.
    func stop() async -> Bool {
        guard let stream else { return false }
        self.stream = nil
        try? await stream.stopCapture()
        if didFinish { return !failed }
        return await withCheckedContinuation { continuation in
            sampleQueue.async {
                if self.didFinish {
                    continuation.resume(returning: !self.failed)
                } else {
                    self.finishContinuation = continuation
                    // Safety net in case the delegate never fires.
                    self.sampleQueue.asyncAfter(deadline: .now() + 10) {
                        if let pending = self.finishContinuation {
                            self.finishContinuation = nil
                            pending.resume(returning: self.outputURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
                        }
                    }
                }
            }
        }
    }

    private func finish(success: Bool) {
        sampleQueue.async {
            guard !self.didFinish else { return }
            self.didFinish = true
            self.failed = !success
            if let continuation = self.finishContinuation {
                self.finishContinuation = nil
                continuation.resume(returning: success)
            }
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Screen recording stopped: \(error.localizedDescription)")
        guard self.stream != nil else { return }   // we are already stopping
        self.stream = nil
        Task { @MainActor in self.onUnexpectedStop?() }
    }

    // MARK: SCRecordingOutputDelegate

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        finish(success: true)
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        NSLog("Screen recording failed: \(error.localizedDescription)")
        finish(success: false)
    }
}
