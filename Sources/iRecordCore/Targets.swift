import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

public struct DisplayInfo: Codable, Identifiable, Sendable {
    public var id: UInt32
    public var name: String
    public var width: Int
    public var height: Int
    public var scale: Double
    public var frame: CGRect
    public var isMain: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, width, height, scale, frame, isMain
    }

    public init(display: SCDisplay, isMain: Bool) {
        id = display.displayID
        name = "Display \(display.displayID)"
        let screen = NSScreen.screens.first {
            (($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value) == display.displayID
        }
        let backingScale = Double(screen?.backingScaleFactor ?? 1)
        scale = backingScale
        let pointWidth = display.frame.width > 0 ? display.frame.width : CGFloat(display.width)
        let pointHeight = display.frame.height > 0 ? display.frame.height : CGFloat(display.height)
        width = Int((pointWidth * CGFloat(backingScale)).rounded())
        height = Int((pointHeight * CGFloat(backingScale)).rounded())
        frame = screen?.frame ?? display.frame
        self.isMain = isMain
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UInt32.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        scale = try c.decode(Double.self, forKey: .scale)
        frame = try c.decode(CGRect.self, forKey: .frame)
        isMain = try c.decode(Bool.self, forKey: .isMain)
    }
}

public struct WindowInfo: Codable, Identifiable, Sendable {
    public var id: UInt32
    public var title: String
    public var appName: String
    public var bundleIdentifier: String?
    public var width: Int
    public var height: Int
    public var frame: CGRect
    public var isOnScreen: Bool

    public init(window: SCWindow) {
        id = window.windowID
        title = window.title ?? ""
        appName = window.owningApplication?.applicationName ?? ""
        bundleIdentifier = window.owningApplication?.bundleIdentifier
        width = Int(window.frame.width)
        height = Int(window.frame.height)
        frame = window.frame
        isOnScreen = window.isOnScreen
    }

    public var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return appName.isEmpty ? "Window \(id)" : appName }
        return appName.isEmpty ? t : "\(appName) — \(t)"
    }
}

public enum CaptureTarget: Equatable {
    case display(displayID: CGDirectDisplayID)
    case window(windowID: CGWindowID, title: String)
    case region(displayID: CGDirectDisplayID, rect: CGRect)
}

public enum CaptureTargetKind: String, Codable, CaseIterable, Sendable {
    case screen
    case window
    case region
}

public struct ShareableContentLoader {
    public static func load() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    public static func displays() async throws -> [DisplayInfo] {
        let content = try await load()
        let mainID = CGMainDisplayID()
        return content.displays
            .sorted { $0.displayID < $1.displayID }
            .map { DisplayInfo(display: $0, isMain: $0.displayID == mainID) }
    }

    public static func windows(includeSystemWindows: Bool = false) async throws -> [WindowInfo] {
        let content = try await load()
        return content.windows
            .filter { window in
                guard window.windowLayer == 0 else { return false }
                guard window.frame.width >= 120, window.frame.height >= 80 else { return false }
                guard let app = window.owningApplication else { return false }
                if !includeSystemWindows {
                    let own = Bundle.main.bundleIdentifier ?? AppInfo.bundleIdentifier
                    if app.bundleIdentifier == own { return false }
                    let excluded = ["com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.WindowManager"]
                    if excluded.contains(app.bundleIdentifier) { return false }
                }
                return true
            }
            .sorted { lhs, rhs in
                let l = lhs.owningApplication?.applicationName ?? ""
                let r = rhs.owningApplication?.applicationName ?? ""
                if l == r { return (lhs.title ?? "") < (rhs.title ?? "") }
                return l < r
            }
            .map(WindowInfo.init(window:))
    }

    public static func filter(for target: CaptureTarget) async throws -> SCContentFilter {
        let content = try await load()
        switch target {
        case .display(let displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureError.noDisplay
            }
            return SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        case .window(let windowID, _):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw CaptureError.noWindow
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            return filter
        case .region(let displayID, _):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureError.noDisplay
            }
            return SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        }
    }

    public static func mainDisplayID() -> CGDirectDisplayID? {
        let content = CGMainDisplayID()
        return content != 0 ? content : nil
    }
}
