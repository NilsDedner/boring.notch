//
//  ScreenshotManager.swift
//  boringNotch
//
//  Takes screenshots and screen recordings with the system `screencapture` tool,
//  stores them in ~/Pictures/Boring Notch Screenshots and lists recent captures
//  for the Screenshots tab. Optionally also lists the system screenshot folder
//  (e.g. ~/Desktop) once the user has granted access to it.
//

import AppKit
import AVFoundation
import Combine
import Defaults
import ImageIO
import UniformTypeIdentifiers

struct ScreenshotFile: Identifiable, Equatable {
    let url: URL
    let date: Date
    var id: URL { url }
    /// True for files in our own folder (editable in place).
    let isOwn: Bool

    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
    var isVideo: Bool { Self.videoExtensions.contains(url.pathExtension.lowercased()) }
}

enum CaptureMode: String, CaseIterable, Identifiable {
    case area, window, screen
    var id: String { rawValue }

    var title: String {
        switch self {
        case .area: return "Bereich"
        case .window: return "Fenster"
        case .screen: return "Bildschirm"
        }
    }

    var icon: String {
        switch self {
        case .area: return "rectangle.dashed"
        case .window: return "macwindow"
        case .screen: return "display"
        }
    }
}

enum RecordMode: String, CaseIterable, Identifiable {
    case area, screen
    var id: String { rawValue }

    var title: String {
        switch self {
        case .area: return "Bereich"
        case .screen: return "Bildschirm"
        }
    }

    var icon: String {
        switch self {
        case .area: return "rectangle.dashed.badge.record"
        case .screen: return "record.circle"
        }
    }
}

extension Defaults.Keys {
    /// Security-scoped bookmark of the user's system screenshot folder.
    static let screenshotFolderBookmark = Key<Data?>("screenshotFolderBookmark", default: nil)
    /// Screenshots tab shows the video (screen recording) buttons.
    static let screenshotTabVideoMode = Key<Bool>("screenshotTabVideoMode", default: false)
    /// Screen recordings include the Mac's sound / the microphone (macOS 15+).
    static let recordSystemAudio = Key<Bool>("recordSystemAudio", default: true)
    static let recordMicrophone = Key<Bool>("recordMicrophone", default: true)
}

enum RecordingTimer {
    static func text(since start: Date, now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

@MainActor
final class ScreenshotManager: ObservableObject {
    static let shared = ScreenshotManager()

    @Published private(set) var files: [ScreenshotFile] = []
    @Published private(set) var isCapturing = false
    @Published private(set) var linkedFolder: URL?
    /// Set while a screen recording runs (start time, for the timer in the notch).
    @Published private(set) var recordingStartedAt: Date?
    var isRecording: Bool { recordingStartedAt != nil }

    private let maxFiles = 40
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private var durationCache: [String: Double] = [:]
    private var refreshTimer: Timer?
    private var visibleCount = 0
    private var recordingPartialURL: URL?
    private var recordingWatchdog: Task<Void, Never>?
    /// The ScreenCaptureKit recorder (typed as AnyObject because it needs macOS 15).
    private var activeRecorder: AnyObject?
    private var isStoppingRecording = false
    private let recordingFrame = RecordingFrameWindow()

    /// ~/Pictures/Boring Notch Screenshots (real home, not the sandbox container).
    let folder: URL = {
        let home: String
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            home = String(cString: dir)
        } else {
            home = NSHomeDirectory()
        }
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Pictures", isDirectory: true)
            .appendingPathComponent("Boring Notch Screenshots", isDirectory: true)
    }()

    private init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        resolveLinkedFolder()
    }

    // MARK: - Visibility-driven refresh

    func viewAppeared() {
        visibleCount += 1
        refresh()
        guard refreshTimer == nil else { return }
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    func viewDisappeared() {
        visibleCount = max(0, visibleCount - 1)
        guard visibleCount == 0 else { return }
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Capture

    /// Takes a screenshot. The caller should close the notch first so it isn't in the way.
    /// Area mode shows our own adjustable selection and only captures on Enter.
    func capture(_ mode: CaptureMode) {
        guard !isCapturing, !isRecording else { return }
        isCapturing = true

        switch mode {
        case .area:
            // Let the notch animate away before the overlay appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                CaptureSelectionOverlay.present(confirmTitle: "Aufnehmen", confirmIcon: "camera.fill", accent: .accentColor) { [weak self] rect in
                    guard let self else { return }
                    guard let rect else { self.isCapturing = false; return }
                    // Give the window server a moment to remove the overlay.
                    self.runScreenshot(arguments: ["-R", CaptureSelectionOverlay.screencaptureRect(rect)], delay: 0.15)
                }
            }
        case .window:
            runScreenshot(arguments: ["-i", "-w"], delay: 0.35)   // click a window, Esc cancels
        case .screen:
            runScreenshot(arguments: ["-m"], delay: 0.35)         // main display
        }
    }

    private func runScreenshot(arguments: [String], delay: TimeInterval) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments + [tempURL.path]

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isCapturing = false
                // Esc / cancelled selection leaves no file.
                guard let destination = self.store(tempURL, fileExtension: "png") else { return }
                ScreenshotEditorWindowController.open(url: destination)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            do {
                try process.run()
            } catch {
                NSLog("screencapture failed to start: \(error)")
                self.isCapturing = false
            }
        }
    }

    /// Moves a finished capture into our folder. Returns nil if there is no file (cancelled).
    private func store(_ tempURL: URL, fileExtension: String) -> URL? {
        guard FileManager.default.fileExists(atPath: tempURL.path) else { return nil }
        let prefix = fileExtension == "png" ? "Screenshot" : "Bildschirmaufnahme"
        let destination = folder.appendingPathComponent(Self.makeFileName(prefix: prefix, fileExtension: fileExtension))
        do {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            NSLog("Capture move failed: \(error)")
            return nil
        }
        refresh()
        return destination
    }

    static func makeFileName(prefix: String = "Screenshot", suffix: String = "", fileExtension: String = "png") -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'um' HH.mm.ss"
        return "\(prefix) \(formatter.string(from: Date()))\(suffix).\(fileExtension)"
    }

    // MARK: - Screen recording

    /// Starts a video recording. Stopped via `stopRecording()` (the red timer in the
    /// closed notch or the stop button in the tab).
    func startRecording(_ mode: RecordMode) {
        guard !isCapturing, !isRecording else { return }
        isCapturing = true

        switch mode {
        case .area:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                CaptureSelectionOverlay.present(confirmTitle: "Aufnahme starten", confirmIcon: "record.circle", accent: .red) { [weak self] rect in
                    guard let self else { return }
                    guard let rect else { self.isCapturing = false; return }
                    let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main ?? NSScreen.screens[0]
                    self.recordingFrame.show(around: rect)
                    self.runRecording(rect: rect, screen: screen, delay: 0.15)
                }
            }
        case .screen:
            // Record the display the mouse is on.
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
            runRecording(rect: nil, screen: screen, delay: 0.35)
        }
    }

    private func runRecording(rect: CGRect?, screen: NSScreen, delay: TimeInterval) {
        let partialURL = folder.appendingPathComponent(".recording-\(UUID().uuidString).mov")
        recordingPartialURL = partialURL

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            let started: Bool
            if #available(macOS 15.0, *) {
                started = await startScreenCaptureKitRecording(rect: rect, screen: screen, outputURL: partialURL)
            } else {
                started = await startHelperRecording(rect: rect, screen: screen, outputURL: partialURL)
            }
            bnCaptureLog("recording started: \(started)")
            guard started else {
                self.finishRecording(written: false)
                return
            }
            self.recordingStartedAt = Date()
            BoringViewCoordinator.shared.currentView = .screenshots
        }
    }

    /// macOS 15+: ScreenCaptureKit with system audio and microphone; our own windows are excluded.
    @available(macOS 15.0, *)
    private func startScreenCaptureKitRecording(rect: CGRect?, screen: NSScreen, outputURL: URL) async -> Bool {
        var microphone = Defaults[.recordMicrophone]
        if microphone {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: break
            case .notDetermined: microphone = await AVCaptureDevice.requestAccess(for: .audio)
            default: microphone = false
            }
        }
        let recorder = ScreenRecorder()
        recorder.onUnexpectedStop = { [weak self] in self?.stopRecording() }
        do {
            try await recorder.start(rect: rect, screen: screen, systemAudio: Defaults[.recordSystemAudio],
                                     microphone: microphone, outputURL: outputURL)
            activeRecorder = recorder
            return true
        } catch {
            NSLog("ScreenCaptureKit recording failed to start: \(error)")
            return false
        }
    }

    /// macOS 14: `screencapture -v` via the unsandboxed XPC helper (it exits immediately
    /// inside the app sandbox). No audio.
    private func startHelperRecording(rect: CGRect?, screen: NSScreen, outputURL: URL) async -> Bool {
        let arguments: [String]
        if let rect {
            arguments = ["-R", CaptureSelectionOverlay.screencaptureRect(rect)]
        } else {
            let index = (NSScreen.screens.firstIndex(of: screen) ?? 0) + 1   // 1 = main display
            arguments = ["-D", "\(index)"]
        }
        let started = await XPCHelperClient.shared.startScreenRecording(arguments: arguments, outputPath: outputURL.path)
        if started { watchHelperRecording() }
        return started
    }

    /// Notices when the helper's screencapture ends on its own (e.g. display disconnected).
    private func watchHelperRecording() {
        recordingWatchdog?.cancel()
        recordingWatchdog = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, self.isRecording else { continue }
                if await !XPCHelperClient.shared.isScreenRecording() {
                    self.stopRecording()
                    return
                }
            }
        }
    }

    /// Ends the recording and saves the movie.
    func stopRecording() {
        guard isRecording, !isStoppingRecording else { return }
        isStoppingRecording = true
        recordingWatchdog?.cancel()
        recordingWatchdog = nil
        Task { @MainActor in
            let written: Bool
            if #available(macOS 15.0, *), let recorder = self.activeRecorder as? ScreenRecorder {
                written = await recorder.stop()
                self.activeRecorder = nil
            } else {
                written = await XPCHelperClient.shared.stopScreenRecording()
            }
            bnCaptureLog("recording stopped, written=\(written)")
            self.finishRecording(written: written)
        }
    }

    private func finishRecording(written: Bool) {
        recordingFrame.hide()
        recordingStartedAt = nil
        isStoppingRecording = false
        isCapturing = false
        guard let partialURL = recordingPartialURL else { return }
        recordingPartialURL = nil
        if written, let destination = store(partialURL, fileExtension: "mov") {
            // QuickTime can trim (⌘T) and export the clip.
            NSWorkspace.shared.open(destination)
        } else {
            try? FileManager.default.removeItem(at: partialURL)
        }
    }

    // MARK: - Listing

    func refresh() {
        var result: [ScreenshotFile] = []
        result += listImages(in: folder, isOwn: true, screenshotsOnly: false)
        if let linkedFolder {
            result += listImages(in: linkedFolder, isOwn: false, screenshotsOnly: true)
        }
        let sorted = Array(result.sorted { $0.date > $1.date }.prefix(maxFiles))
        if sorted != files { files = sorted }
    }

    private func listImages(in directory: URL, isOwn: Bool, screenshotsOnly: Bool) -> [ScreenshotFile] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        let mediaExtensions = Set(["png", "jpg", "jpeg", "heic", "tiff"]).union(ScreenshotFile.videoExtensions)
        return urls.compactMap { url in
            guard mediaExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            if screenshotsOnly && !Self.isScreenshot(url) { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { return nil }
            return ScreenshotFile(url: url, date: values?.contentModificationDate ?? .distantPast, isOwn: isOwn)
        }
    }

    /// macOS tags its screenshots with kMDItemIsScreenCapture; fall back to the file name.
    private static func isScreenshot(_ url: URL) -> Bool {
        let attr = "com.apple.metadata:kMDItemIsScreenCapture"
        if getxattr(url.path, attr, nil, 0, 0, 0) > 0 { return true }
        let name = url.lastPathComponent.lowercased()
        return name.hasPrefix("bildschirmfoto") || name.hasPrefix("screenshot") || name.hasPrefix("screen shot")
            || name.hasPrefix("bildschirmaufnahme") || name.hasPrefix("screen recording")
    }

    // MARK: - Thumbnails

    func thumbnail(for file: ScreenshotFile, maxPixel: Int = 720) -> NSImage? {
        let key = "\(file.url.path)|\(file.date.timeIntervalSince1970)|\(maxPixel)" as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }

        if file.isVideo {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            guard let cg = try? generator.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil)
            else { return nil }
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            thumbnailCache.setObject(image, forKey: key)
            return image
        }

        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbnailCache.setObject(image, forKey: key)
        return image
    }

    /// Video length as "m:ss", cached per file version.
    func durationText(for file: ScreenshotFile) -> String? {
        guard file.isVideo else { return nil }
        let key = "\(file.url.path)|\(file.date.timeIntervalSince1970)"
        let seconds: Double
        if let cached = durationCache[key] {
            seconds = cached
        } else {
            seconds = AVURLAsset(url: file.url).duration.seconds
            guard seconds.isFinite else { return nil }
            durationCache[key] = seconds
        }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - File actions

    func copyToClipboard(_ file: ScreenshotFile) {
        NSPasteboard.general.clearContents()
        if file.isVideo {
            // Paste as file (Finder, Mail, Slack, Teams …)
            NSPasteboard.general.writeObjects([file.url as NSURL])
            return
        }
        guard let image = NSImage(contentsOf: file.url) else { return }
        NSPasteboard.general.writeObjects([image])
    }

    func open(_ file: ScreenshotFile) {
        NSWorkspace.shared.open(file.url)
    }

    func revealInFinder(_ file: ScreenshotFile) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    func openFolder() {
        NSWorkspace.shared.open(folder)
    }

    func moveToTrash(_ file: ScreenshotFile) {
        NSWorkspace.shared.recycle([file.url]) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - Linked system screenshot folder

    /// Asks the user to pick the folder macOS saves screenshots to (default: Desktop).
    func linkSystemFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Verbinden"
        panel.message = "Wähle den Ordner, in dem macOS deine Screenshots speichert (meist der Schreibtisch)."
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            panel.directoryURL = URL(fileURLWithPath: String(cString: dir)).appendingPathComponent("Desktop")
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            Defaults[.screenshotFolderBookmark] = bookmark
            linkedFolder?.stopAccessingSecurityScopedResource()
            resolveLinkedFolder()
            refresh()
        } catch {
            NSLog("Could not bookmark screenshot folder: \(error)")
        }
    }

    func unlinkSystemFolder() {
        linkedFolder?.stopAccessingSecurityScopedResource()
        linkedFolder = nil
        Defaults[.screenshotFolderBookmark] = nil
        refresh()
    }

    private func resolveLinkedFolder() {
        guard let data = Defaults[.screenshotFolderBookmark] else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource()
        else { return }
        linkedFolder = url
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            Defaults[.screenshotFolderBookmark] = fresh
        }
    }
}
