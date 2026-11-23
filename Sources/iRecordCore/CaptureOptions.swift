import Foundation

public struct CaptureOptions: Codable, Equatable, Sendable {
    public var format: VideoFormat
    public var fps: Int
    public var quality: CaptureQuality
    public var scale: Double
    public var audioSource: AudioSource
    public var showCursor: Bool
    public var highlightClicks: Bool
    public var gifMaxWidth: Int
    public var gifFPS: Int

    public init(
        format: VideoFormat = .mp4H264,
        fps: Int = 30,
        quality: CaptureQuality = .high,
        scale: Double = 1.0,
        audioSource: AudioSource = .system,
        showCursor: Bool = true,
        highlightClicks: Bool = true,
        gifMaxWidth: Int = 720,
        gifFPS: Int = 12
    ) {
        self.format = format
        self.fps = fps
        self.quality = quality
        self.scale = scale
        self.audioSource = audioSource
        self.showCursor = showCursor
        self.highlightClicks = highlightClicks
        self.gifMaxWidth = gifMaxWidth
        self.gifFPS = gifFPS
    }

    public var wantsAudio: Bool {
        format.supportsAudio && audioSource.hasAudio
    }

    public var capturesSystemAudio: Bool {
        wantsAudio && audioSource.captureSystemAudio
    }

    public var capturesMicrophone: Bool {
        wantsAudio && audioSource.captureMicrophone
    }

    public func sanitized() -> CaptureOptions {
        var c = self
        if !(5...120).contains(c.fps) { c.fps = 30 }
        if !(0.25...1.0).contains(c.scale) { c.scale = 1.0 }
        if c.gifFPS < 2 { c.gifFPS = 12 }
        if c.gifFPS > 30 { c.gifFPS = 30 }
        if c.gifMaxWidth < 120 { c.gifMaxWidth = 720 }
        return c
    }
}

public struct RecordingInfo: Codable, Sendable {
    public var outputPath: String
    public var width: Int
    public var height: Int
    public var format: VideoFormat
    public var fps: Int
    public var hasAudio: Bool
    public var startedAt: Date

    public init(outputPath: String, width: Int, height: Int, format: VideoFormat, fps: Int, hasAudio: Bool, startedAt: Date = Date()) {
        self.outputPath = outputPath
        self.width = width
        self.height = height
        self.format = format
        self.fps = fps
        self.hasAudio = hasAudio
        self.startedAt = startedAt
    }
}

public struct RecordingResult: Codable, Sendable {
    public var outputPath: String
    public var format: VideoFormat
    public var duration: Double
    public var width: Int
    public var height: Int
    public var fileSize: Int64
    public var hasAudio: Bool

    public init(outputPath: String, format: VideoFormat, duration: Double, width: Int, height: Int, fileSize: Int64, hasAudio: Bool) {
        self.outputPath = outputPath
        self.format = format
        self.duration = duration
        self.width = width
        self.height = height
        self.fileSize = fileSize
        self.hasAudio = hasAudio
    }
}
