import AppKit
import iRecordCore
import SwiftUI

struct ShortcutField: NSViewRepresentable {
    @Binding var hotkey: Hotkey
    var isConflicting: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> ShortcutNSView {
        let view = ShortcutNSView()
        view.hotkey = hotkey
        view.onCapture = { captured in
            context.coordinator.parent.hotkey = captured
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutNSView, context: Context) {
        context.coordinator.parent = self
        nsView.hotkey = hotkey
        nsView.isConflicting = isConflicting
        nsView.needsDisplay = true
    }

    final class Coordinator {
        var parent: ShortcutField

        init(_ parent: ShortcutField) {
            self.parent = parent
        }
    }
}

final class ShortcutNSView: NSView {
    var hotkey: Hotkey = .startDefault
    var isConflicting = false
    var onCapture: ((Hotkey) -> Void)?

    private var isCapturing = false

    override var intrinsicContentSize: NSSize {
        NSSize(width: 132, height: 24)
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        isCapturing = true
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isCapturing = false
        needsDisplay = true
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            window?.makeFirstResponder(nil)
            return
        }

        var modifiers: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers |= Hotkey.commandKey }
        if flags.contains(.option) { modifiers |= Hotkey.optionKey }
        if flags.contains(.control) { modifiers |= Hotkey.controlKey }
        if flags.contains(.shift) { modifiers |= Hotkey.shiftKey }
        guard modifiers != 0 else {
            NSSound.beep()
            return
        }
        let captured = Hotkey(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        guard hotkey != captured else {
            window?.makeFirstResponder(nil)
            return
        }
        hotkey = captured
        onCapture?(captured)
        window?.makeFirstResponder(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)

        if isCapturing {
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        } else {
            NSColor.controlBackgroundColor.withAlphaComponent(0.7).setFill()
        }
        path.fill()

        let borderColor: NSColor
        if isConflicting {
            borderColor = .systemRed
        } else if isCapturing {
            borderColor = .controlAccentColor
        } else {
            borderColor = .separatorColor
        }
        borderColor.setStroke()
        path.lineWidth = isCapturing || isConflicting ? 1.5 : 1
        path.stroke()

        let text: String
        let color: NSColor
        if isCapturing {
            text = L10n.t("hotkey.press")
            color = .secondaryLabelColor
        } else {
            text = hotkey.displayString
            color = isConflicting ? .systemRed : .labelColor
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: color
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2 + 1
        )
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}
