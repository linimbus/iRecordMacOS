import AppKit
import iRecordCore

final class RegionSelectionView: NSView {
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var hintText: String = ""

    private var selection: CGRect = .zero
    private var startPoint: NSPoint?
    private var isDragging = false

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        startPoint = point
        selection = .zero
        isDragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(
            x: min(startPoint.x, point.x),
            y: min(startPoint.y, point.y),
            width: abs(point.x - startPoint.x),
            height: abs(point.y - startPoint.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        if selection.width < 16 || selection.height < 16 {
            selection = .zero
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            onCancel?()
        case 36, 76: // Return / Enter
            confirm()
        default:
            super.keyDown(with: event)
        }
    }

    private func confirm() {
        guard selection.width >= 16, selection.height >= 16 else {
            NSSound.beep()
            return
        }
        onComplete?(selection)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        if selection.width > 0, selection.height > 0 {
            NSGraphicsContext.saveGraphicsState()
            if let context = NSGraphicsContext.current?.cgContext {
                context.setBlendMode(.clear)
                context.fill(selection)
                context.setBlendMode(.normal)
            }
            NSGraphicsContext.restoreGraphicsState()

            let border = NSBezierPath(rect: selection)
            NSColor.white.setStroke()
            border.lineWidth = 1.5
            border.stroke()

            NSColor.controlAccentColor.setStroke()
            let inner = NSBezierPath(rect: selection.insetBy(dx: 1, dy: 1))
            inner.lineWidth = 1
            inner.stroke()

            drawDimensionLabel()
        }

        drawHint()
    }

    private func drawDimensionLabel() {
        let text = "\(Int(selection.width)) × \(Int(selection.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let padding = NSSize(width: 8, height: 4)
        var origin = NSPoint(
            x: selection.midX - (size.width + padding.width * 2) / 2,
            y: selection.minY - size.height - padding.height * 2 - 6
        )
        if origin.y < 8 {
            origin.y = selection.maxY + 6
        }
        let rect = NSRect(
            x: origin.x,
            y: origin.y,
            width: size.width + padding.width * 2,
            height: size.height + padding.height * 2
        )
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(
            at: NSPoint(x: origin.x + padding.width, y: origin.y + padding.height),
            withAttributes: attributes
        )
    }

    private func drawHint() {
        let text = hintText
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let rect = NSRect(
            x: bounds.midX - size.width / 2 - 16,
            y: bounds.maxY - 64,
            width: size.width + 32,
            height: size.height + 16
        )
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        (text as NSString).draw(
            at: NSPoint(x: rect.minX + 16, y: rect.minY + 8),
            withAttributes: attributes
        )
    }
}

final class RegionSelectorController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var view: RegionSelectionView?
    private var screen: NSScreen?
    private var completion: ((CaptureTarget) -> Void)?
    private var cancellation: (() -> Void)?

    func begin(on screen: NSScreen, completion: @escaping (CaptureTarget) -> Void, cancel: @escaping () -> Void) {
        self.screen = screen
        self.completion = completion
        self.cancellation = cancel

        let overlay = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        overlay.hintText = L10n.t("region.hint")
        overlay.onComplete = { [weak self] rect in
            self?.finish(rect: rect)
        }
        overlay.onCancel = { [weak self] in
            self?.cancelSelection()
        }

        let panel = RegionWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        // ARC owns this window; letting AppKit auto-release it on close while
        // the controller also drops its reference caused an over-release crash.
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.sharingType = .none
        panel.contentView = overlay
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(overlay)
        NSApp.activate(ignoringOtherApps: true)

        self.window = panel
        self.view = overlay
    }

    private func finish(rect: CGRect) {
        guard let screen else { return }
        let displayID = RegionSelectorController.displayID(for: screen)
        let topLeftRect = CGRect(
            x: rect.minX,
            y: screen.frame.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        let target = CaptureTarget.region(displayID: displayID, rect: topLeftRect)
        let callback = completion
        // Tear down outside the view's key/mouse event handler. Releasing the
        // window and its controller inside draw/keyDown can over-release AppKit
        // objects while the event is still on the stack.
        window?.orderOut(nil)
        DispatchQueue.main.async { [weak self] in
            self?.close()
            callback?(target)
        }
    }

    private func cancelSelection() {
        let callback = cancellation
        window?.orderOut(nil)
        DispatchQueue.main.async { [weak self] in
            self?.close()
            callback?()
        }
    }

    func close() {
        window?.delegate = nil
        window?.close()
        window = nil
        view = nil
        completion = nil
        cancellation = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        view = nil
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            ?? CGMainDisplayID()
    }
}

private final class RegionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
