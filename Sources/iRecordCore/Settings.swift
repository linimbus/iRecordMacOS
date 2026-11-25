import AVFoundation
import Foundation

public enum VideoFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case mp4H264 = "mp4-h264"
    case mp4HEVC = "mp4-hevc"
    case movH264 = "mov-h264"
    case movHEVC = "mov-hevc"
    case movProRes = "mov-prores"
    case gif = "gif"

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .mp4H264, .mp4HEVC: return "mp4"
        case .movH264, .movHEVC, .movProRes: return "mov"
        case .gif: return "gif"
        }
    }

    public var displayName: String {
        switch self {
        case .mp4H264: return "MP4 · H.264"
        case .mp4HEVC: return "MP4 · HEVC"
        case .movH264: return "MOV · H.264"
        case .movHEVC: return "MOV · HEVC"
        case .movProRes: return "MOV · ProRes 422"
        case .gif: return "GIF · Animated"
        }
    }

    public var shortName: String {
        switch self {
        case .mp4H264: return "MP4"
        case .mp4HEVC: return "MP4 HEVC"
        case .movH264: return "MOV"
        case .movHEVC: return "MOV HEVC"
        case .movProRes: return "ProRes"
        case .gif: return "GIF"
        }
    }

    public var fileType: AVFileType {
        switch self {
        case .mp4H264, .mp4HEVC: return .mp4
        case .movH264, .movHEVC, .movProRes: return .mov
        case .gif: return .mp4 // GIF is recorded to a temporary MP4 first.
        }
    }

    public var codec: AVVideoCodecType {
        switch self {
        case .mp4H264, .movH264, .gif: return .h264
        case .mp4HEVC, .movHEVC: return .hevc
        case .movProRes: return .proRes422
        }
    }

    public var supportsAudio: Bool { self != .gif }

    public var isGIF: Bool { self == .gif }

    /// Temporary recording extension used before GIF conversion.
    public var recordingExtension: String {
        isGIF ? "mp4" : fileExtension
    }

    public static func parse(_ raw: String) -> VideoFormat? {
        let normalized = raw.lowercased().replacingOccurrences(of: "_", with: "-")
        if let exact = VideoFormat(rawValue: normalized) { return exact }
        switch normalized {
        case "mp4", "h264", "avc": return .mp4H264
        case "hevc", "h265": return .mp4HEVC
        case "mov", "quicktime": return .movH264
        case "prores", "prores422": return .movProRes
        case "gif", "animated-gif": return .gif
        default: return nil
        }
    }

    public static var supportedList: String {
        allCases.map(\.rawValue).joined(separator: ", ")
    }
}

public enum CaptureQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case low, medium, high

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .low: return L10n.t("quality.low")
        case .medium: return L10n.t("quality.medium")
        case .high: return L10n.t("quality.high")
        }
    }

    /// Bits per pixel per frame used to derive an average bitrate.
    public var bitsPerPixel: Double {
        switch self {
        case .low: return 0.035
        case .medium: return 0.075
        case .high: return 0.14
        }
    }
}

public enum AudioSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case system
    case microphone
    case both

    public var id: String { rawValue }

    public var captureSystemAudio: Bool { self == .system || self == .both }
    public var captureMicrophone: Bool { self == .microphone || self == .both }
    public var hasAudio: Bool { self != .off }

    public var displayName: String {
        switch self {
        case .off: return L10n.t("audio.off")
        case .system: return L10n.t("audio.system")
        case .microphone: return L10n.t("audio.microphone")
        case .both: return L10n.t("audio.both")
        }
    }
}

public struct Hotkey: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let startDefault = Hotkey(keyCode: 15, modifiers: Hotkey.optionKey | Hotkey.commandKey)   // ⌥⌘R
    public static let pauseDefault = Hotkey(keyCode: 35, modifiers: Hotkey.optionKey | Hotkey.commandKey)  // ⌥⌘P
    public static let stopDefault = Hotkey(keyCode: 1, modifiers: Hotkey.optionKey | Hotkey.commandKey)    // ⌥⌘S

    // Carbon modifier masks.
    public static let commandKey: UInt32 = 256
    public static let shiftKey: UInt32 = 512
    public static let optionKey: UInt32 = 2048
    public static let controlKey: UInt32 = 4096

    public var isValid: Bool {
        keyCode != 0 && modifiers != 0
    }

    public var displayString: String {
        var result = ""
        if modifiers & Hotkey.controlKey != 0 { result += "⌃" }
        if modifiers & Hotkey.optionKey != 0 { result += "⌥" }
        if modifiers & Hotkey.shiftKey != 0 { result += "⇧" }
        if modifiers & Hotkey.commandKey != 0 { result += "⌘" }
        result += Hotkey.keyName(for: keyCode)
        return result
    }

    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7",
        28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 50: "`",
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
        64: "F17", 65: ".", 67: "*", 69: "+", 71: "Clear", 75: "/", 76: "Enter",
        78: "-", 79: "F18", 80: "F19", 81: "=", 82: "0", 83: "1", 84: "2", 85: "3",
        86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9", 96: "F5", 97: "F6",
        98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13",
        107: "F14", 109: "F10", 111: "F12", 113: "F15", 115: "Home", 116: "Page Up",
        117: "Forward Delete", 118: "F4", 119: "End", 120: "F2", 121: "Page Down",
        122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]

    public static func keyName(for keyCode: UInt32) -> String {
        if let name = keyNames[keyCode] { return name }
        return "Key\(keyCode)"
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var format: VideoFormat
    public var fps: Int
    public var quality: CaptureQuality
    public var scale: Double
    public var audioSource: AudioSource
    public var showCursor: Bool
    public var highlightClicks: Bool
    public var language: AppLanguage
    public var outputDirectory: String
    public var gifMaxWidth: Int
    public var gifFPS: Int
    public var showFloatingButton: Bool
    public var launcherOpacity: Double
    public var showRecordingBorder: Bool
    public var recordingBorderColorHex: String
    public var launchAtLogin: Bool
    public var revealWhenDone: Bool
    public var playSoundWhenDone: Bool
    public var startHotkey: Hotkey
    public var pauseHotkey: Hotkey
    public var stopHotkey: Hotkey

    public static let `default` = AppSettings(
        format: .mp4H264,
        fps: 30,
        quality: .high,
        scale: 1.0,
        audioSource: .system,
        showCursor: true,
        highlightClicks: true,
        language: .system,
        outputDirectory: AppPaths.defaultOutputDirectory.path,
        gifMaxWidth: 720,
        gifFPS: 12,
        showFloatingButton: true,
        launcherOpacity: 1.0,
        showRecordingBorder: true,
        recordingBorderColorHex: "#FF3B30",
        launchAtLogin: false,
        revealWhenDone: false,
        playSoundWhenDone: true,
        startHotkey: .startDefault,
        pauseHotkey: .pauseDefault,
        stopHotkey: .stopDefault
    )

    public init(
        format: VideoFormat,
        fps: Int,
        quality: CaptureQuality,
        scale: Double,
        audioSource: AudioSource,
        showCursor: Bool,
        highlightClicks: Bool,
        language: AppLanguage,
        outputDirectory: String,
        gifMaxWidth: Int,
        gifFPS: Int,
        showFloatingButton: Bool,
        launcherOpacity: Double,
        showRecordingBorder: Bool,
        recordingBorderColorHex: String,
        launchAtLogin: Bool,
        revealWhenDone: Bool,
        playSoundWhenDone: Bool,
        startHotkey: Hotkey,
        pauseHotkey: Hotkey,
        stopHotkey: Hotkey
    ) {
        self.format = format
        self.fps = fps
        self.quality = quality
        self.scale = scale
        self.audioSource = audioSource
        self.showCursor = showCursor
        self.highlightClicks = highlightClicks
        self.language = language
        self.outputDirectory = outputDirectory
        self.gifMaxWidth = gifMaxWidth
        self.gifFPS = gifFPS
        self.showFloatingButton = showFloatingButton
        self.launcherOpacity = launcherOpacity
        self.showRecordingBorder = showRecordingBorder
        self.recordingBorderColorHex = recordingBorderColorHex
        self.launchAtLogin = launchAtLogin
        self.revealWhenDone = revealWhenDone
        self.playSoundWhenDone = playSoundWhenDone
        self.startHotkey = startHotkey
        self.pauseHotkey = pauseHotkey
        self.stopHotkey = stopHotkey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings.default
        format = try c.decodeIfPresent(VideoFormat.self, forKey: .format) ?? d.format
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? d.fps
        quality = try c.decodeIfPresent(CaptureQuality.self, forKey: .quality) ?? d.quality
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? d.scale
        audioSource = try c.decodeIfPresent(AudioSource.self, forKey: .audioSource) ?? d.audioSource
        showCursor = try c.decodeIfPresent(Bool.self, forKey: .showCursor) ?? d.showCursor
        highlightClicks = try c.decodeIfPresent(Bool.self, forKey: .highlightClicks) ?? d.highlightClicks
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? d.language
        outputDirectory = try c.decodeIfPresent(String.self, forKey: .outputDirectory) ?? d.outputDirectory
        gifMaxWidth = try c.decodeIfPresent(Int.self, forKey: .gifMaxWidth) ?? d.gifMaxWidth
        gifFPS = try c.decodeIfPresent(Int.self, forKey: .gifFPS) ?? d.gifFPS
        showFloatingButton = try c.decodeIfPresent(Bool.self, forKey: .showFloatingButton) ?? d.showFloatingButton
        launcherOpacity = try c.decodeIfPresent(Double.self, forKey: .launcherOpacity) ?? d.launcherOpacity
        showRecordingBorder = try c.decodeIfPresent(Bool.self, forKey: .showRecordingBorder) ?? d.showRecordingBorder
        recordingBorderColorHex = try c.decodeIfPresent(String.self, forKey: .recordingBorderColorHex) ?? d.recordingBorderColorHex
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        revealWhenDone = try c.decodeIfPresent(Bool.self, forKey: .revealWhenDone) ?? d.revealWhenDone
        playSoundWhenDone = try c.decodeIfPresent(Bool.self, forKey: .playSoundWhenDone) ?? d.playSoundWhenDone
        startHotkey = try c.decodeIfPresent(Hotkey.self, forKey: .startHotkey) ?? d.startHotkey
        pauseHotkey = try c.decodeIfPresent(Hotkey.self, forKey: .pauseHotkey) ?? d.pauseHotkey
        stopHotkey = try c.decodeIfPresent(Hotkey.self, forKey: .stopHotkey) ?? d.stopHotkey
        sanitize()
    }

    public mutating func sanitize() {
        if !(5...120).contains(fps) { fps = 30 }
        if !(0.25...1.0).contains(scale) { scale = 1.0 }
        if gifMaxWidth < 120 { gifMaxWidth = 720 }
        if gifMaxWidth > 3840 { gifMaxWidth = 3840 }
        if gifFPS < 2 { gifFPS = 12 }
        if gifFPS > 30 { gifFPS = 30 }
        if !launcherOpacity.isFinite || launcherOpacity < 0.3 { launcherOpacity = 0.3 }
        if launcherOpacity > 1.0 { launcherOpacity = 1.0 }
        let borderColor = recordingBorderColorHex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if borderColor.count == 7, borderColor.hasPrefix("#"), UInt32(borderColor.dropFirst(), radix: 16) != nil {
            recordingBorderColorHex = borderColor
        } else {
            recordingBorderColorHex = "#FF3B30"
        }
        if outputDirectory.trimmingCharacters(in: .whitespaces).isEmpty {
            outputDirectory = AppPaths.defaultOutputDirectory.path
        }
        if !startHotkey.isValid { startHotkey = .startDefault }
        if !pauseHotkey.isValid { pauseHotkey = .pauseDefault }
        if !stopHotkey.isValid { stopHotkey = .stopDefault }
    }

    public var outputDirectoryURL: URL {
        URL(fileURLWithPath: outputDirectory, isDirectory: true)
    }

    public var videoOptions: CaptureOptions {
        CaptureOptions(
            format: format,
            fps: fps,
            quality: quality,
            scale: scale,
            audioSource: audioSource,
            showCursor: showCursor,
            highlightClicks: highlightClicks,
            gifMaxWidth: gifMaxWidth,
            gifFPS: gifFPS
        )
    }
}

public final class SettingsStore {
    public static let shared = SettingsStore()

    public private(set) var settings: AppSettings

    private let lock = NSLock()

    private init() {
        settings = AppSettings.default
        reload()
    }

    public func reload() {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: AppPaths.settingsFile),
              var decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            settings = .default
            L10n.current = settings.language.resolved
            return
        }
        decoded.sanitize()
        settings = decoded
        L10n.current = decoded.language.resolved
    }

    public var current: AppSettings {
        lock.lock()
        defer { lock.unlock() }
        return settings
    }

    public func update(_ transform: (inout AppSettings) -> Void) {
        lock.lock()
        var copy = settings
        lock.unlock()
        transform(&copy)
        copy.sanitize()
        lock.lock()
        settings = copy
        lock.unlock()
        L10n.current = copy.language.resolved
        save(copy)
    }

    public func replace(with newValue: AppSettings) {
        var copy = newValue
        copy.sanitize()
        lock.lock()
        settings = copy
        lock.unlock()
        L10n.current = copy.language.resolved
        save(copy)
    }

    public func save(_ value: AppSettings? = nil) {
        let value = value ?? current
        AppPaths.ensureDirectories()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            try data.write(to: AppPaths.settingsFile, options: .atomic)
        } catch {
            Log.write("Failed to save settings: \(error)")
        }
    }
}
