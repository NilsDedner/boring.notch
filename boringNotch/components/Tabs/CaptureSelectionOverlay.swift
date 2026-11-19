//
//  CaptureSelectionOverlay.swift
//  boringNotch
//
//  Full-screen overlay to pick a capture area. Unlike `screencapture -i -s` the
//  selection stays adjustable (move, resize via handles, arrow keys) and is only
//  taken when the user presses Enter or clicks the confirm button. Esc cancels.
//  The last selection is remembered, so Enter right away repeats it.
//

import AppKit
import Defaults
import SwiftUI

extension Defaults.Keys {
    /// Last capture selection in global Cocoa coordinates ("{{x, y}, {w, h}}").
    static let lastCaptureSelection = Key<String?>("lastCaptureSelection", default: nil)
}

@MainActor
final class CaptureSelectionOverlay {
    private static var current: CaptureSelectionOverlay?

    fileprivate var selection: CGRect?          // global Cocoa coordinates
    fileprivate let confirmTitle: String
    fileprivate let confirmIcon: String
    fileprivate let accent: Color
    private var windows: [SelectionWindow] = []
    private var completion: ((CGRect?) -> Void)?

    /// Shows the overlay on every screen. `completion` gets the chosen rect in global
    /// Cocoa coordinates (origin bottom-left of the main screen), or nil if cancelled.
    static func present(confirmTitle: String, confirmIcon: String, accent: Color, completion: @escaping (CGRect?) -> Void) {
        current?.finish(nil)
        let overlay = CaptureSelectionOverlay(confirmTitle: confirmTitle, confirmIcon: confirmIcon, accent: accent, completion: completion)
        current = overlay
        overlay.show()
    }

    private init(confirmTitle: String, confirmIcon: String, accent: Color, completion: @escaping (CGRect?) -> Void) {
        self.confirmTitle = confirmTitle
        self.confirmIcon = confirmIcon
        self.accent = accent
        self.completion = completion

        if let stored = Defaults[.lastCaptureSelection] {
            let rect = NSRectFromString(stored)
            if rect.width >= 8, rect.height >= 8,
               NSScreen.screens.contains(where: { $0.frame.contains(rect) }) {
                selection = rect
            }
        }
    }

    private func show() {
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            let window = SelectionWindow(screen: screen, overlay: self)
            windows.append(window)
            window.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        let keyWindow = windows.first { $0.frame.contains(mouse) } ?? windows.first
        keyWindow?.makeKeyAndOrderFront(nil)
        keyWindow?.makeFirstResponder(keyWindow?.contentView)
        NSCursor.crosshair.set()
        redrawAll()
    }

    fileprivate func setSelection(_ rect: CGRect?) {
        selection = rect
        redrawAll()
    }

    fileprivate func redrawAll() {
        windows.forEach { $0.selectionView.selectionChanged() }
    }

    fileprivate func confirm() {
        guard let selection, selection.width >= 4, selection.height >= 4 else { return }
        Defaults[.lastCaptureSelection] = NSStringFromRect(selection)
        finish(selection.integral)
    }

    fileprivate func cancel() { finish(nil) }

    private func finish(_ rect: CGRect?) {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        NSCursor.arrow.set()
        let completion = self.completion
        self.completion = nil
        if Self.current === self { Self.current = nil }
        completion?(rect)
    }

    /// `screencapture -R` wants global coordinates with the origin at the top-left of the main display.
    static func screencaptureRect(_ rect: CGRect) -> String {
        let mainHeight = NSScreen.screens.first?.frame.height ?? rect.maxY
        let x = Int(rect.minX.rounded())
        let y = Int((mainHeight - rect.maxY).rounded())
        return "\(x),\(y),\(Int(rect.width.rounded())),\(Int(rect.height.rounded()))"
    }
}

// MARK: - Window

private final class SelectionWindow: NSWindow {
    let selectionView: SelectionView

    init(screen: NSScreen, overlay: CaptureSelectionOverlay) {
        selectionView = SelectionView(overlay: overlay)
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        contentView = selectionView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - View

private final class SelectionView: NSView {
    private unowned let overlay: CaptureSelectionOverlay
    private let toolbar: NSHostingView<SelectionToolbar>

    private enum DragMode {
        case creating(start: CGPoint)
        case moving(offset: CGSize)
        case resizing(anchor: CGPoint, horizontal: Bool, vertical: Bool, fixed: CGRect)
    }
    private var dragMode: DragMode?

    init(overlay: CaptureSelectionOverlay) {
        self.overlay = overlay
        toolbar = NSHostingView(rootView: SelectionToolbar(
            confirmTitle: overlay.confirmTitle,
            confirmIcon: overlay.confirmIcon,
            accent: overlay.accent,
            onConfirm: { [weak overlay] in overlay?.confirm() },
            onCancel: { [weak overlay] in overlay?.cancel() }
        ))
        super.init(frame: .zero)
        addSubview(toolbar)
        toolbar.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Selection in this view's coordinates, if it lies on this screen.
    private var localSelection: CGRect? {
        guard let window, let selection = overlay.selection else { return nil }
        let local = selection.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        return bounds.intersects(local) ? local : nil
    }

    private func setLocalSelection(_ rect: CGRect) {
        guard let window else { return }
        let clamped = rect.intersection(bounds)
        overlay.setSelection(clamped.offsetBy(dx: window.frame.minX, dy: window.frame.minY))
    }

    func selectionChanged() {
        needsDisplay = true
        layoutToolbar()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if let sel = localSelection {
            dim.append(NSBezierPath(rect: sel))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.4).setFill()
        dim.fill()

        guard let sel = localSelection else {
            drawHint("Bereich aufziehen  ·  Esc zum Abbrechen", centeredIn: bounds)
            return
        }

        // Border
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()

        // Handles
        for point in handlePoints(for: sel).map(\.point) {
            let r = NSRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9)
            let path = NSBezierPath(ovalIn: r)
            NSColor.white.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        // Size label above the top-left corner (inside if there is no room).
        let label = "\(Int(sel.width.rounded())) × \(Int(sel.height.rounded()))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (label as NSString).size(withAttributes: attrs)
        var origin = CGPoint(x: sel.minX, y: sel.maxY + 6)
        if origin.y + size.height + 6 > bounds.maxY { origin.y = sel.maxY - size.height - 10 }
        let pill = NSRect(x: origin.x, y: origin.y, width: size.width + 12, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
        (label as NSString).draw(at: CGPoint(x: pill.minX + 6, y: pill.minY + 2), withAttributes: attrs)
    }

    private func drawHint(_ text: String, centeredIn rect: CGRect) {
        guard window?.isKeyWindow == true || NSScreen.screens.count == 1 || window?.frame.contains(NSEvent.mouseLocation) == true else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let pill = NSRect(x: rect.midX - size.width / 2 - 14, y: rect.midY - size.height / 2 - 8,
                          width: size.width + 28, height: size.height + 16)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        (text as NSString).draw(at: CGPoint(x: pill.minX + 14, y: pill.minY + 8), withAttributes: attrs)
    }

    private func layoutToolbar() {
        guard let sel = localSelection, dragMode == nil else {
            toolbar.isHidden = true
            return
        }
        let size = toolbar.fittingSize
        var origin = CGPoint(x: sel.maxX - size.width, y: sel.minY - size.height - 10)
        if origin.y < bounds.minY + 8 { origin.y = sel.minY + 10 }   // no room below: inside, bottom
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)
        toolbar.frame = NSRect(origin: origin, size: size)
        toolbar.isHidden = false
    }

    // MARK: Handles & cursors

    private struct Handle { let point: CGPoint; let h: Int; let v: Int }  // -1 = min edge, 1 = max edge, 0 = none

    private func handlePoints(for r: CGRect) -> [Handle] {
        [
            Handle(point: CGPoint(x: r.minX, y: r.minY), h: -1, v: -1),
            Handle(point: CGPoint(x: r.maxX, y: r.minY), h: 1, v: -1),
            Handle(point: CGPoint(x: r.minX, y: r.maxY), h: -1, v: 1),
            Handle(point: CGPoint(x: r.maxX, y: r.maxY), h: 1, v: 1),
            Handle(point: CGPoint(x: r.midX, y: r.minY), h: 0, v: -1),
            Handle(point: CGPoint(x: r.midX, y: r.maxY), h: 0, v: 1),
            Handle(point: CGPoint(x: r.minX, y: r.midY), h: -1, v: 0),
            Handle(point: CGPoint(x: r.maxX, y: r.midY), h: 1, v: 0),
        ]
    }

    private func handle(at point: CGPoint, in r: CGRect) -> Handle? {
        handlePoints(for: r).first { hypot($0.point.x - point.x, $0.point.y - point.y) <= 9 }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        // While dragging the cursor is managed directly; tiny selections have no inner area.
        guard dragMode == nil, let sel = localSelection else { return }

        // AppKit throws on null/empty/infinite cursor rects, so only add valid ones.
        func add(_ rect: NSRect, _ cursor: NSCursor) {
            let r = rect.intersection(bounds)
            guard !r.isNull, !r.isInfinite, r.width > 0, r.height > 0 else { return }
            addCursorRect(r, cursor: cursor)
        }

        if sel.width > 16, sel.height > 16 {
            add(sel.insetBy(dx: 6, dy: 6), .openHand)
        }
        for handle in handlePoints(for: sel) {
            let r = NSRect(x: handle.point.x - 8, y: handle.point.y - 8, width: 16, height: 16)
            let cursor: NSCursor = handle.v == 0 ? .resizeLeftRight : (handle.h == 0 ? .resizeUpDown : .crosshair)
            add(r, cursor)
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        let p = convert(event.locationInWindow, from: nil)

        if event.clickCount == 2, let sel = localSelection, sel.contains(p) {
            overlay.confirm()
            return
        }

        if let sel = localSelection {
            if let h = handle(at: p, in: sel) {
                let anchor = CGPoint(x: h.h < 0 ? sel.maxX : sel.minX, y: h.v < 0 ? sel.maxY : sel.minY)
                dragMode = .resizing(anchor: anchor, horizontal: h.h != 0, vertical: h.v != 0, fixed: sel)
                return
            }
            if sel.contains(p) {
                dragMode = .moving(offset: CGSize(width: p.x - sel.minX, height: p.y - sel.minY))
                NSCursor.closedHand.set()
                return
            }
        }
        dragMode = .creating(start: p)
        overlay.setSelection(nil)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch dragMode {
        case .creating(let start):
            setLocalSelection(CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                                     width: abs(p.x - start.x), height: abs(p.y - start.y)))
        case .moving(let offset):
            guard let sel = localSelection else { return }
            var origin = CGPoint(x: p.x - offset.width, y: p.y - offset.height)
            origin.x = min(max(origin.x, bounds.minX), bounds.maxX - sel.width)
            origin.y = min(max(origin.y, bounds.minY), bounds.maxY - sel.height)
            setLocalSelection(CGRect(origin: origin, size: sel.size))
        case .resizing(let anchor, let horizontal, let vertical, let fixed):
            let x0 = horizontal ? min(anchor.x, p.x) : fixed.minX
            let x1 = horizontal ? max(anchor.x, p.x) : fixed.maxX
            let y0 = vertical ? min(anchor.y, p.y) : fixed.minY
            let y1 = vertical ? max(anchor.y, p.y) : fixed.maxY
            setLocalSelection(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let wasCreating: Bool
        if case .creating = dragMode { wasCreating = true } else { wasCreating = false }
        dragMode = nil
        if wasCreating, let sel = localSelection, sel.width < 4 || sel.height < 4 {
            overlay.setSelection(nil)
        }
        selectionChanged()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:                       // Return, Enter
            overlay.confirm()
        case 53:                           // Esc
            overlay.cancel()
        case 123, 124, 125, 126:           // arrows: move (⇧ = 10pt, ⌥ = resize)
            guard let sel = localSelection else { return }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            var dx: CGFloat = 0, dy: CGFloat = 0
            switch event.keyCode {
            case 123: dx = -step
            case 124: dx = step
            case 125: dy = -step
            default: dy = step
            }
            if event.modifierFlags.contains(.option) {
                setLocalSelection(CGRect(x: sel.minX, y: sel.minY - dy, width: max(4, sel.width + dx), height: max(4, sel.height + dy)))
            } else {
                setLocalSelection(sel.offsetBy(dx: dx, dy: dy))
            }
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - Toolbar

private struct SelectionToolbar: View {
    let confirmTitle: String
    let confirmIcon: String
    let accent: Color
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onCancel) {
                Text("Abbrechen")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help("Esc")

            Button(action: onConfirm) {
                HStack(spacing: 5) {
                    Image(systemName: confirmIcon)
                    Text(confirmTitle)
                    Text("↩").foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(accent))
            }
            .buttonStyle(.plain)
            .help("Enter oder Doppelklick in den Bereich")
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .padding(5)
        .background(Capsule().fill(Color.black.opacity(0.8)))
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Frame shown around an area while it is being recorded

@MainActor
final class RecordingFrameWindow {
    private var window: NSWindow?

    func show(around rect: CGRect) {
        let frame = rect.insetBy(dx: -3, dy: -3)    // just outside the recorded area
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:
            Rectangle()
                .strokeBorder(Color.red.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        )
        window.orderFrontRegardless()
        self.window = window
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

import os
private let captureLogger = Logger(subsystem: "theboringteam.boringnotch", category: "capture")
func bnCaptureLog(_ message: String) {
    captureLogger.notice("\(message, privacy: .public)")
}
