import AppKit
import iRecordCore

/// Draws a screen-only border around the area currently being recorded.
/// The overlay uses `sharingType = .none`, so it is visible to the user but is
/// not included in the captured video.
final class RecordingBorderController {
    private var window: NSWindow?
    private var borderView: RecordingBorderView?

    func show(target: CaptureTarget, color: NSColor) {
        hide()
        guard let screen = screen(for: target) else { return }

        let view = RecordingBorderView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.color = color

        switch target {
        case .display:
            view.borderRect = view.bounds.insetBy(dx: 3, dy: 3)
        case .region(_, let rect):
            let local = NSRect(
                x: rect.minX,
                y: screen.frame.height - rect.minY - rect.height,
                width: rect.width,
                height: rect.height
            )
            let clipped = local.intersection(view.bounds.insetBy(dx: 2, dy: 2))
            guard clipped.width > 1, clipped.height > 1 else { return }
            view.borderRect = clipped
        case .window:
            // Window capture does not display a region border.
            return
        }

        let overlay = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        overlay.level = .screenSaver
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        overlay.sharingType = .none
        overlay.contentView = view
        overlay.orderFrontRegardless()

        window = overlay
        borderView = view
    }

    func updateColor(_ color: NSColor) {
        borderView?.color = color
        borderView?.needsDisplay = true
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
        borderView = nil
    }

    private func screen(for target: CaptureTarget) -> NSScreen? {
        let displayID: CGDirectDisplayID?
        switch target {
        case .display(let id):
            displayID = id
        case .region(let id, _):
            displayID = id
        case .window:
            displayID = nil
        }
        guard let displayID else { return nil }
        return NSScreen.screens.first {
            (($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value) == displayID
        } ?? NSScreen.main
    }
}

private final class RecordingBorderView: NSView {
    var borderRect: NSRect = .zero {
        didSet { needsDisplay = true }
    }
    var color: NSColor = .systemRed {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard borderRect.width > 1, borderRect.height > 1 else { return }
        color.setStroke()
        let path = NSBezierPath(rect: borderRect)
        path.lineWidth = 4
        path.stroke()
    }
}
