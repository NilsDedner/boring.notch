//
//  ScreenshotEditor.swift
//  boringNotch
//
//  Annotation editor window for screenshots: arrow, rectangle, pen, highlighter,
//  text, pixelate, spotlight (focus) and crop, with undo/redo, copy and save.
//  All annotation geometry is stored in image pixel coordinates (top-left origin),
//  and the same Core Graphics renderer draws the on-screen preview and the export.
//

import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

enum AnnotationTool: String, CaseIterable, Identifiable {
    case arrow, rectangle, pen, highlighter, text, pixelate, spotlight, crop
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .pixelate: return "checkerboard.rectangle"
        case .spotlight: return "flashlight.on.fill"
        case .crop: return "crop"
        }
    }

    var title: String {
        switch self {
        case .arrow: return "Pfeil"
        case .rectangle: return "Rechteck"
        case .pen: return "Stift"
        case .highlighter: return "Marker"
        case .text: return "Text"
        case .pixelate: return "Verpixeln"
        case .spotlight: return "Fokus"
        case .crop: return "Zuschneiden"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .arrow: return "a"
        case .rectangle: return "r"
        case .pen: return "p"
        case .highlighter: return "h"
        case .text: return "t"
        case .pixelate: return "b"
        case .spotlight: return "f"
        case .crop: return "c"
        }
    }
}

struct Annotation: Identifiable {
    enum Kind {
        case arrow(CGPoint, CGPoint)
        case rectangle(CGRect)
        case pen([CGPoint])
        case highlighter([CGPoint])
        case text(String, CGPoint)
        case pixelate(CGRect)
        case spotlight(CGRect)
    }

    let id = UUID()
    var kind: Kind
    var color: NSColor
    /// Stroke width in image pixels.
    var lineWidth: CGFloat
}

struct EditorState {
    var base: CGImage
    var annotations: [Annotation]
}

// MARK: - Renderer

enum AnnotationRenderer {
    /// Draws image + annotations into a context whose coordinate system is y-down in image pixels.
    static func draw(base: CGImage, pixelated: CGImage?, annotations: [Annotation], extra: Annotation?, in ctx: CGContext) {
        let size = CGSize(width: base.width, height: base.height)
        drawImage(base, in: CGRect(origin: .zero, size: size), ctx: ctx)

        let all = annotations + (extra.map { [$0] } ?? [])
        // Spotlights first combine into a single dimmed overlay with holes.
        let spotlights = all.compactMap { a -> CGRect? in
            if case .spotlight(let r) = a.kind { return r.standardized } else { return nil }
        }

        for a in all {
            switch a.kind {
            case .pixelate(let rect):
                guard let pixelated else { continue }
                ctx.saveGState()
                ctx.clip(to: rect.standardized)
                drawImage(pixelated, in: CGRect(origin: .zero, size: size), ctx: ctx)
                ctx.restoreGState()
            default:
                break
            }
        }

        if !spotlights.isEmpty {
            ctx.saveGState()
            let path = CGMutablePath()
            path.addRect(CGRect(origin: .zero, size: size))
            for r in spotlights {
                path.addRoundedRect(in: r, cornerWidth: min(12, r.width / 4), cornerHeight: min(12, r.height / 4))
            }
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        }

        for a in all {
            ctx.saveGState()
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            switch a.kind {
            case .arrow(let from, let to):
                drawArrow(from: from, to: to, color: a.color, width: a.lineWidth, ctx: ctx)
            case .rectangle(let rect):
                ctx.setStrokeColor(a.color.cgColor)
                ctx.setLineWidth(a.lineWidth)
                let r = rect.standardized
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(a.lineWidth * 1.5, r.width / 2),
                                   cornerHeight: min(a.lineWidth * 1.5, r.height / 2), transform: nil))
                ctx.strokePath()
            case .pen(let points):
                stroke(points, color: a.color.cgColor, width: a.lineWidth, ctx: ctx)
            case .highlighter(let points):
                ctx.setBlendMode(.multiply)
                stroke(points, color: a.color.withAlphaComponent(0.4).cgColor, width: a.lineWidth * 5, ctx: ctx)
            case .text(let string, let origin):
                drawText(string, at: origin, color: a.color, fontSize: a.lineWidth * 6, ctx: ctx)
            case .pixelate, .spotlight:
                break
            }
            ctx.restoreGState()
        }
    }

    /// CGContext.draw assumes y-up; flip locally so images aren't upside down.
    static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    private static func stroke(_ points: [CGPoint], color: CGColor, width: CGFloat, ctx: CGContext) {
        guard let first = points.first else { return }
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.move(to: first)
        if points.count == 1 {
            ctx.addLine(to: CGPoint(x: first.x + 0.1, y: first.y))
        } else {
            for p in points.dropFirst() { ctx.addLine(to: p) }
        }
        ctx.strokePath()
    }

    private static func drawArrow(from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat, ctx: CGContext) {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        let angle = atan2(dy, dx)
        let headLength = min(max(width * 4.5, 14), length * 0.6)
        let headAngle: CGFloat = .pi / 7
        let base = CGPoint(x: to.x - cos(angle) * headLength * 0.8, y: to.y - sin(angle) * headLength * 0.8)

        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.move(to: from)
        ctx.addLine(to: base)
        ctx.strokePath()

        ctx.move(to: to)
        ctx.addLine(to: CGPoint(x: to.x - cos(angle - headAngle) * headLength, y: to.y - sin(angle - headAngle) * headLength))
        ctx.addLine(to: CGPoint(x: to.x - cos(angle + headAngle) * headLength, y: to.y - sin(angle + headAngle) * headLength))
        ctx.closePath()
        ctx.fillPath()
    }

    static func textAttributes(color: NSColor, fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = fontSize * 0.08
        shadow.shadowOffset = NSSize(width: 0, height: -fontSize * 0.03)
        return [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: color,
            .shadow: shadow,
        ]
    }

    private static func drawText(_ string: String, at origin: CGPoint, color: NSColor, fontSize: CGFloat, ctx: CGContext) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSAttributedString(string: string, attributes: textAttributes(color: color, fontSize: fontSize)).draw(at: origin)
        NSGraphicsContext.current = previous
    }

    /// Renders the final image at full resolution.
    static func export(state: EditorState, pixelated: CGImage?) -> CGImage? {
        let w = state.base.width, h = state.base.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: state.base.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        draw(base: state.base, pixelated: pixelated, annotations: state.annotations, extra: nil, in: ctx)
        return ctx.makeImage()
    }

    static func pixelate(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(max(CGFloat(max(image.width, image.height)) / 70, 8), forKey: kCIInputScaleKey)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext().createCGImage(output, from: input.extent)
    }
}

// MARK: - Editor model

@MainActor
final class ScreenshotEditorModel: ObservableObject {
    let fileURL: URL
    @Published var state: EditorState
    @Published var tool: AnnotationTool = .arrow
    @Published var color: NSColor = .systemRed
    @Published var widthLevel: Int = 1   // 0 thin, 1 medium, 2 thick
    @Published var draft: Annotation?
    @Published var cropDraft: CGRect?
    @Published var pendingText: (point: CGPoint, text: String)?
    @Published var statusMessage: String?

    private(set) var pixelated: CGImage?
    private var undoStack: [EditorState] = []
    private var redoStack: [EditorState] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var imageSize: CGSize { CGSize(width: state.base.width, height: state.base.height) }

    /// Stroke width in image pixels, relative to the image size so it looks the same on any capture.
    var lineWidth: CGFloat {
        let base = max(imageSize.width, imageSize.height) / 400
        return max(2, base * [1.0, 2.0, 3.5][widthLevel])
    }

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        fileURL = url
        state = EditorState(base: image, annotations: [])
        pixelated = AnnotationRenderer.pixelate(image)
    }

    private func pushUndo() {
        undoStack.append(state)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        apply(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        apply(next)
    }

    private func apply(_ newState: EditorState) {
        let baseChanged = newState.base !== state.base
        state = newState
        if baseChanged { pixelated = AnnotationRenderer.pixelate(newState.base) }
        objectWillChange.send()
    }

    // MARK: Gestures (image coordinates)

    func dragChanged(start: CGPoint, current: CGPoint) {
        let rect = CGRect(x: start.x, y: start.y, width: current.x - start.x, height: current.y - start.y)
        switch tool {
        case .arrow:
            draft = Annotation(kind: .arrow(start, current), color: color, lineWidth: lineWidth)
        case .rectangle:
            draft = Annotation(kind: .rectangle(rect), color: color, lineWidth: lineWidth)
        case .pixelate:
            draft = Annotation(kind: .pixelate(rect), color: color, lineWidth: lineWidth)
        case .spotlight:
            draft = Annotation(kind: .spotlight(rect), color: color, lineWidth: lineWidth)
        case .pen, .highlighter:
            if case .pen(var points)? = draft?.kind, tool == .pen {
                points.append(current)
                draft?.kind = .pen(points)
            } else if case .highlighter(var points)? = draft?.kind, tool == .highlighter {
                points.append(current)
                draft?.kind = .highlighter(points)
            } else {
                draft = Annotation(kind: tool == .pen ? .pen([start, current]) : .highlighter([start, current]),
                                   color: color, lineWidth: lineWidth)
            }
        case .crop:
            cropDraft = rect.standardized.intersection(CGRect(origin: .zero, size: imageSize))
        case .text:
            break
        }
    }

    func dragEnded(start: CGPoint, end: CGPoint) {
        if tool == .text {
            commitPendingText()
            pendingText = (start, "")
            return
        }
        if tool == .crop {
            // Crop waits for confirmation (Enter / button), so it can be adjusted.
            return
        }
        guard let draft else { return }
        self.draft = nil
        if isTooSmall(draft) { return }
        pushUndo()
        state.annotations.append(draft)
    }

    private func isTooSmall(_ a: Annotation) -> Bool {
        switch a.kind {
        case .arrow(let p, let q): return hypot(q.x - p.x, q.y - p.y) < 4
        case .rectangle(let r), .pixelate(let r), .spotlight(let r):
            return abs(r.width) < 4 || abs(r.height) < 4
        default: return false
        }
    }

    func commitPendingText() {
        guard let pending = pendingText else { return }
        pendingText = nil
        let text = pending.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        pushUndo()
        state.annotations.append(Annotation(kind: .text(text, pending.point), color: color, lineWidth: lineWidth))
    }

    func applyCrop() {
        guard let crop = cropDraft?.integral, crop.width >= 8, crop.height >= 8,
              let flattened = AnnotationRenderer.export(state: state, pixelated: pixelated),
              let cropped = flattened.cropping(to: crop)
        else { cropDraft = nil; return }
        pushUndo()
        cropDraft = nil
        apply(EditorState(base: cropped, annotations: []))
    }

    func cancelCrop() { cropDraft = nil }

    // MARK: Output

    func renderedImage() -> CGImage? {
        commitPendingText()
        return AnnotationRenderer.export(state: state, pixelated: pixelated)
    }

    func copyToClipboard() {
        guard let cg = renderedImage() else { return }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        flash("In die Zwischenablage kopiert")
    }

    /// Saves over our own file, or as a copy in our folder for files from elsewhere.
    @discardableResult
    func save() -> URL? {
        guard let cg = renderedImage() else { return nil }
        let manager = ScreenshotManager.shared
        let ownFolder = manager.folder.standardizedFileURL.path
        let target: URL
        if fileURL.deletingLastPathComponent().standardizedFileURL.path == ownFolder {
            target = fileURL
        } else {
            target = manager.folder.appendingPathComponent(ScreenshotManager.makeFileName(suffix: " (bearbeitet)"))
        }
        guard let dest = CGImageDestinationCreateWithURL(target as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            flash("Speichern fehlgeschlagen")
            return nil
        }
        manager.refresh()
        flash("Gespeichert")
        return target
    }

    private func flash(_ message: String) {
        statusMessage = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            if self?.statusMessage == message { self?.statusMessage = nil }
        }
    }
}

// MARK: - Editor view

struct ScreenshotEditorView: View {
    @ObservedObject var model: ScreenshotEditorModel
    var onClose: () -> Void
    @FocusState private var textFocused: Bool

    private let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .white, .black]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            canvas
        }
        .frame(minWidth: 1000, minHeight: 480)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: Toolbar
    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(AnnotationTool.allCases) { tool in
                    Button {
                        model.commitPendingText()
                        if model.tool == .crop && tool != .crop { model.cancelCrop() }
                        model.tool = tool
                    } label: {
                        Image(systemName: tool.icon)
                            .frame(width: 28, height: 24)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(model.tool == tool ? Color.accentColor.opacity(0.35) : .clear))
                    }
                    .buttonStyle(.plain)
                    // Single-letter shortcuts are off while typing a text annotation.
                    .optionalShortcut(model.pendingText == nil ? tool.shortcut : nil)
                    .help("\(tool.title) (\(String(tool.shortcut.character).uppercased()))")
                }
            }

            Divider().frame(height: 20)

            HStack(spacing: 4) {
                ForEach(palette, id: \.self) { color in
                    Circle()
                        .fill(Color(nsColor: color))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Color.primary.opacity(model.color == color ? 0.9 : 0.2),
                                                 lineWidth: model.color == color ? 2 : 1))
                        .onTapGesture { model.color = color }
                }
            }

            Picker("Stärke", selection: $model.widthLevel) {
                Image(systemName: "line.diagonal").tag(0)
                Image(systemName: "line.diagonal").fontWeight(.bold).tag(1)
                Image(systemName: "line.diagonal").fontWeight(.black).tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 96)
            .help("Linienstärke")

            Divider().frame(height: 20)

            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)
                .help("Rückgängig (⌘Z)")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
                .help("Wiederholen (⇧⌘Z)")

            Spacer()

            if let status = model.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary).transition(.opacity)
            }

            if model.tool == .crop, model.cropDraft != nil {
                Button("Abbrechen") { model.cancelCrop() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Zuschneiden") { model.applyCrop() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
            }

            Button {
                model.copyToClipboard()
            } label: {
                Label("Kopieren", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: .command)
            .fixedSize()
            .help("Ergebnis in die Zwischenablage (⌘C)")

            Button {
                if model.save() != nil { onClose() }
            } label: {
                Label("Fertig", systemImage: "checkmark")
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .help("Speichern und schließen (⌘S)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(.smooth(duration: 0.2), value: model.statusMessage)
    }

    // MARK: Canvas
    private var canvas: some View {
        GeometryReader { geo in
            let imageSize = model.imageSize
            let available = CGSize(width: max(geo.size.width - 40, 10), height: max(geo.size.height - 40, 10))
            // Never enlarge beyond 100% (one image pixel per screen pixel).
            let scale = min(available.width / imageSize.width, available.height / imageSize.height, 1 / (NSScreen.main?.backingScaleFactor ?? 2))
            let displaySize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let origin = CGPoint(x: (geo.size.width - displaySize.width) / 2, y: (geo.size.height - displaySize.height) / 2)

            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    context.withCGContext { cg in
                        cg.translateBy(x: origin.x, y: origin.y)
                        cg.scaleBy(x: scale, y: scale)
                        AnnotationRenderer.draw(base: model.state.base, pixelated: model.pixelated,
                                                annotations: model.state.annotations, extra: model.draft, in: cg)
                        if let crop = model.cropDraft {
                            drawCropOverlay(crop, imageSize: imageSize, scale: scale, ctx: cg)
                        }
                    }
                }
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)

                if let pending = model.pendingText {
                    textField(for: pending.point, scale: scale, origin: origin)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let toImage = { (p: CGPoint) in
                            CGPoint(x: (p.x - origin.x) / scale, y: (p.y - origin.y) / scale)
                        }
                        model.dragChanged(start: toImage(value.startLocation), current: toImage(value.location))
                    }
                    .onEnded { value in
                        let toImage = { (p: CGPoint) in
                            CGPoint(x: (p.x - origin.x) / scale, y: (p.y - origin.y) / scale)
                        }
                        model.dragEnded(start: toImage(value.startLocation), end: toImage(value.location))
                    }
            )
            .onHover { inside in
                if inside { cursor.push() } else { NSCursor.pop() }
            }
        }
    }

    private var cursor: NSCursor {
        switch model.tool {
        case .text: return .iBeam
        default: return .crosshair
        }
    }

    private func drawCropOverlay(_ crop: CGRect, imageSize: CGSize, scale: CGFloat, ctx: CGContext) {
        ctx.saveGState()
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: imageSize))
        path.addRect(crop)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5 / scale)
        ctx.setLineDash(phase: 0, lengths: [6 / scale, 4 / scale])
        ctx.stroke(crop)
        ctx.restoreGState()
    }

    private func textField(for point: CGPoint, scale: CGFloat, origin: CGPoint) -> some View {
        let fontSize = model.lineWidth * 6 * scale
        return TextField("Text", text: Binding(
            get: { model.pendingText?.text ?? "" },
            set: { model.pendingText?.text = $0 }
        ))
        .textFieldStyle(.plain)
        .font(.system(size: max(fontSize, 10), weight: .bold))
        .foregroundStyle(Color(nsColor: model.color))
        .frame(minWidth: 120)
        .fixedSize()
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 3).stroke(Color.accentColor, lineWidth: 1))
        .offset(x: origin.x + point.x * scale - 2, y: origin.y + point.y * scale - 2)
        .focused($textFocused)
        .onAppear { textFocused = true }
        .onSubmit { finishTextEditing() }
        .onExitCommand {
            model.pendingText = nil
            finishTextEditing()
        }
    }

    /// Drops keyboard focus from the text field, otherwise it keeps ⌘Z/⌘C for itself.
    private func finishTextEditing() {
        model.commitPendingText()
        textFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
}

private extension View {
    @ViewBuilder
    func optionalShortcut(_ key: KeyEquivalent?) -> some View {
        if let key {
            keyboardShortcut(key, modifiers: [])
        } else {
            self
        }
    }
}

// MARK: - Window

@MainActor
final class ScreenshotEditorWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [ScreenshotEditorWindowController] = []
    private let model: ScreenshotEditorModel

    static func open(url: URL) {
        // Reuse an existing window for the same file.
        if let existing = open.first(where: { $0.model.fileURL == url }) {
            NSApp.activate(ignoringOtherApps: true)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let model = ScreenshotEditorModel(url: url) else { return }
        let controller = ScreenshotEditorWindowController(model: model)
        open.append(controller)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(model: ScreenshotEditorModel) {
        self.model = model
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Fit the image (in points) plus toolbar into ~85% of the screen.
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        let imagePoints = CGSize(width: model.imageSize.width / backing, height: model.imageSize.height / backing)
        let width = min(max(imagePoints.width + 40, 1000), screen.width * 0.9)
        let height = min(max(imagePoints.height + 90, 480), screen.height * 0.85)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = model.fileURL.lastPathComponent
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: ScreenshotEditorView(model: model) { [weak window] in
            window?.close()
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }
}
