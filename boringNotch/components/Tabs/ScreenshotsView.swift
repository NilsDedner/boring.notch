//
//  ScreenshotsView.swift
//  boringNotch
//
//  Screenshots tab: capture buttons on the left, recent screenshots on the right.
//  Click a thumbnail to annotate it, drag it into any app.
//

import Defaults
import SwiftUI

struct ScreenshotsView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var manager = ScreenshotManager.shared
    @Default(.screenshotTabVideoMode) private var videoMode
    @Default(.recordSystemAudio) private var recordSystemAudio
    @Default(.recordMicrophone) private var recordMicrophone

    /// Audio needs ScreenCaptureKit's recording output (macOS 15+).
    private var audioSupported: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 10) {
            captureColumn
            gallery
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { manager.viewAppeared() }
        .onDisappear {
            manager.viewDisappeared()
            vm.isHoveringScrollable = false
        }
    }

    // MARK: - Capture
    private var captureColumn: some View {
        VStack(spacing: 5) {
            if let started = manager.recordingStartedAt {
                stopButton(startedAt: started)
            } else {
                modePicker

                if videoMode {
                    ForEach(RecordMode.allCases) { mode in
                        captureButton(icon: mode.icon, title: mode.title, tint: .red) {
                            vm.close()
                            manager.startRecording(mode)
                        }
                    }
                } else {
                    ForEach(CaptureMode.allCases) { mode in
                        captureButton(icon: mode.icon, title: mode.title, tint: nil) {
                            vm.close()
                            manager.capture(mode)
                        }
                    }
                }
            }

            HStack(spacing: 5) {
                if videoMode && audioSupported {
                    toggleButton(on: $recordSystemAudio, onIcon: "speaker.wave.2.fill", offIcon: "speaker.slash",
                                 help: recordSystemAudio ? "Systemton wird aufgenommen" : "Systemton aus")
                    toggleButton(on: $recordMicrophone, onIcon: "mic.fill", offIcon: "mic.slash",
                                 help: recordMicrophone ? "Mikrofon wird aufgenommen" : "Mikrofon aus")
                }
                smallButton(icon: "folder", help: "Screenshot-Ordner öffnen") { manager.openFolder() }
                if manager.linkedFolder == nil {
                    smallButton(icon: "link.badge.plus", help: "macOS-Screenshot-Ordner verbinden (z. B. Schreibtisch), damit auch ⇧⌘4-Screenshots hier erscheinen") {
                        manager.linkSystemFolder()
                    }
                } else {
                    smallButton(icon: "link", help: "Verbunden: \(manager.linkedFolder?.lastPathComponent ?? ""). Klicken zum Trennen") {
                        manager.unlinkSystemFolder()
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .frame(width: 112)
    }

    private var modePicker: some View {
        HStack(spacing: 0) {
            modeSegment(icon: "camera.fill", help: "Screenshot", selected: !videoMode) { videoMode = false }
            modeSegment(icon: "video.fill", help: "Bildschirmaufnahme (Video)", selected: videoMode) { videoMode = true }
        }
        .padding(2)
        .frame(height: 22)
        .background(Capsule().fill(Color(nsColor: .secondarySystemFill)))
    }

    private func modeSegment(icon: String, help: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.2)) { action() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(selected ? .white : .gray)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if selected { Capsule().fill(Color.white.opacity(0.18)) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func captureButton(icon: String, title: String, tint: Color?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(tint ?? .white)
                    .frame(width: 16)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .secondarySystemFill)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(manager.isCapturing)
    }

    private func stopButton(startedAt: Date) -> some View {
        Button {
            manager.stopRecording()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "stop.fill").font(.system(size: 16))
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(RecordingTimer.text(since: startedAt, now: context.date))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                }
                Text("Aufnahme beenden").font(.caption2).opacity(0.8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.75)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleButton(on: Binding<Bool>, onIcon: String, offIcon: String, help: String) -> some View {
        Button {
            on.wrappedValue.toggle()
        } label: {
            Image(systemName: on.wrappedValue ? onIcon : offIcon)
                .font(.caption)
                .foregroundStyle(on.wrappedValue ? .white : .gray)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(
                    on.wrappedValue ? Color.red.opacity(0.35) : Color(nsColor: .secondarySystemFill)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func smallButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .secondarySystemFill)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Gallery
    @ViewBuilder
    private var gallery: some View {
        if manager.files.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 22))
                Text("Noch keine Screenshots").font(.callout)
                Text("Nimm links einen auf oder verbinde deinen Screenshot-Ordner.")
                    .font(.caption2)
            }
            .foregroundStyle(.gray)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(manager.files) { file in
                        ScreenshotThumbnail(file: file)
                    }
                }
                .padding(.vertical, 2)
            }
            .onHover { vm.isHoveringScrollable = $0 }
        }
    }
}

private struct ScreenshotThumbnail: View {
    let file: ScreenshotFile
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var manager = ScreenshotManager.shared
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                if let image = manager.thumbnail(for: file) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    Color(nsColor: .secondarySystemFill)
                }

                if file.isVideo && !hovering {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 8))
                        if let duration = manager.durationText(for: file) {
                            Text(duration).font(.system(size: 10, weight: .semibold).monospacedDigit())
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.6)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(5)
                }

                if hovering {
                    HStack(spacing: 10) {
                        if file.isVideo {
                            icon("play.fill", "Abspielen (QuickTime: ⌘T zum Kürzen)") { openEditor() }
                        } else {
                            icon("pencil", "Bearbeiten") { openEditor() }
                        }
                        icon("doc.on.doc", "Kopieren") { manager.copyToClipboard(file) }
                        icon("magnifyingglass", "Im Finder zeigen") { manager.revealInFinder(file) }
                        icon("trash", "In den Papierkorb") { manager.moveToTrash(file) }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(.black.opacity(0.65))
                    .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(hovering ? 0.35 : 0.1), lineWidth: 1))
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { h in withAnimation(.smooth(duration: 0.15)) { hovering = h } }
        .onTapGesture { openEditor() }
        .onDrag { NSItemProvider(contentsOf: file.url) ?? NSItemProvider() }
        .help(file.url.lastPathComponent)
    }

    private func openEditor() {
        vm.close()   // the open notch would cover the editor's toolbar
        if file.isVideo {
            manager.open(file)
        } else {
            ScreenshotEditorWindowController.open(url: file.url)
        }
    }

    private func icon(_ name: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .help(help)
    }
}
