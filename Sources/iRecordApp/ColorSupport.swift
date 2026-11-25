import AppKit
import SwiftUI

struct RecordingBorderColorOption: Identifiable {
    let hex: String
    let name: String
    var id: String { hex }
}

enum RecordingBorderPalette {
    static let colors: [RecordingBorderColorOption] = [
        RecordingBorderColorOption(hex: "#FF3B30", name: "Red"),
        RecordingBorderColorOption(hex: "#FF9500", name: "Orange"),
        RecordingBorderColorOption(hex: "#FFCC00", name: "Yellow"),
        RecordingBorderColorOption(hex: "#34C759", name: "Green"),
        RecordingBorderColorOption(hex: "#007AFF", name: "Blue"),
        RecordingBorderColorOption(hex: "#AF52DE", name: "Purple"),
        RecordingBorderColorOption(hex: "#FFFFFF", name: "White")
    ]
}

extension NSColor {
    convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        let red = CGFloat((number >> 16) & 0xFF) / 255.0
        let green = CGFloat((number >> 8) & 0xFF) / 255.0
        let blue = CGFloat(number & 0xFF) / 255.0
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

extension Color {
    init(hex: String, fallback: NSColor = .systemRed) {
        self.init(nsColor: NSColor(hex: hex) ?? fallback)
    }
}
