import AVFoundation
import AppKit
import CoreGraphics
import Foundation

public enum Permissions {
    public static var hasScreenCapture: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public static func requestScreenCapture() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    public static var microphoneAuthorization: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static var hasMicrophone: Bool {
        microphoneAuthorization == .authorized
    }

    public static func requestMicrophone() async -> Bool {
        switch microphoneAuthorization {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    public static func openScreenCaptureSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    public static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

public enum CaptureError: Error, LocalizedError, CustomStringConvertible {
    case screenPermission
    case microphonePermission
    case alreadyRecording
    case notRecording
    case noDisplay
    case noWindow
    case invalidRegion
    case outputNotWritable(String)
    case writerFailed(String)
    case captureFailed(String)
    case exportFailed(String)
    case stoppedEarly
    case outputExists(String)
    case invalidArguments(String)

    public var code: String {
        switch self {
        case .screenPermission: return "screen_permission_denied"
        case .microphonePermission: return "microphone_permission_denied"
        case .alreadyRecording: return "already_recording"
        case .notRecording: return "not_recording"
        case .noDisplay: return "no_display"
        case .noWindow: return "no_window"
        case .invalidRegion: return "invalid_region"
        case .outputNotWritable: return "output_not_writable"
        case .writerFailed: return "writer_failed"
        case .captureFailed: return "capture_failed"
        case .exportFailed: return "export_failed"
        case .stoppedEarly: return "no_frames"
        case .outputExists: return "output_exists"
        case .invalidArguments: return "invalid_arguments"
        }
    }

    public var localizedKey: String {
        switch self {
        case .screenPermission: return "error.screenPermission"
        case .microphonePermission: return "error.micPermission"
        case .alreadyRecording: return "error.alreadyRecording"
        case .notRecording: return "error.notRecording"
        case .noDisplay: return "error.noDisplay"
        case .noWindow: return "error.noWindow"
        case .invalidRegion: return "error.invalidRegion"
        case .outputNotWritable: return "error.outputNotWritable"
        case .writerFailed: return "error.writerFailed"
        case .captureFailed: return "error.captureFailed"
        case .exportFailed: return "error.exportFailed"
        case .stoppedEarly: return "error.stoppedEarly"
        case .outputExists: return "error.outputExists"
        case .invalidArguments: return "error.generic"
        }
    }

    public var detail: String? {
        switch self {
        case .outputNotWritable(let d), .writerFailed(let d), .captureFailed(let d),
             .exportFailed(let d), .outputExists(let d), .invalidArguments(let d):
            return d
        default:
            return nil
        }
    }

    public var errorDescription: String? {
        let base: String
        switch self {
        case .screenPermission:
            base = "Screen Recording permission is not granted. Enable it in System Settings → Privacy & Security → Screen Recording."
        case .microphonePermission:
            base = "Microphone permission is not granted."
        case .alreadyRecording:
            base = "A recording is already in progress."
        case .notRecording:
            base = "There is no active recording."
        case .noDisplay:
            base = "No display is available for recording."
        case .noWindow:
            base = "The selected window is no longer available."
        case .invalidRegion:
            base = "The selected capture region is too small."
        case .outputNotWritable:
            base = "The output folder is not writable."
        case .writerFailed:
            base = "The video writer could not be created."
        case .captureFailed:
            base = "Screen capture could not be started."
        case .exportFailed:
            base = "The recording could not be exported."
        case .stoppedEarly:
            base = "No video frames were captured."
        case .outputExists:
            base = "The output file already exists."
        case .invalidArguments:
            base = "Invalid arguments."
        }
        if let detail { return "\(base) \(detail)" }
        return base
    }

    public var description: String { errorDescription ?? code }

    public func localizedDescription(_ language: AppLanguage) -> String {
        var text = L10n.t(localizedKey, language)
        if let detail, !detail.isEmpty {
            text += " " + detail
        }
        return text
    }
}
