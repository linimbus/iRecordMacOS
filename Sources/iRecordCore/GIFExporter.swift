import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct GIFExportResult: Sendable {
    public let fileSize: Int64
    public let width: Int
    public let height: Int
}

public enum GIFExporter {
    public enum ExportError: Error, LocalizedError {
        case noVideoTrack
        case zeroDuration
        case destinationFailed
        case frameFailed

        public var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "The recording has no video track."
            case .zeroDuration: return "The recording has zero duration."
            case .destinationFailed: return "Could not create the GIF file."
            case .frameFailed: return "Could not render a video frame."
            }
        }
    }

    /// Converts a video file to an animated GIF using AVAssetImageGenerator and ImageIO.
    @discardableResult
    public static func convert(
        videoURL: URL,
        outputURL: URL,
        fps: Int,
        maxWidth: Int,
        progress: ((Double) -> Void)? = nil
    ) throws -> GIFExportResult {
        let asset = AVURLAsset(url: videoURL)
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration.isFinite, duration > 0.01 else { throw ExportError.zeroDuration }
        guard !asset.tracks(withMediaType: .video).isEmpty else { throw ExportError.noVideoTrack }

        var framesPerSecond = max(2, min(30, fps))
        // Keep memory and encoding time bounded for long recordings.
        let maxFrames = 1200
        if duration * Double(framesPerSecond) > Double(maxFrames) {
            framesPerSecond = max(2, Int(Double(maxFrames) / duration))
        }
        let frameCount = max(1, Int((duration * Double(framesPerSecond)).rounded()))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let width = max(120, maxWidth)
        generator.maximumSize = CGSize(width: CGFloat(width), height: CGFloat.greatestFiniteMagnitude)

        try? FileManager.default.removeItem(at: outputURL)
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else {
            throw ExportError.destinationFailed
        }

        let fileProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0
            ]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: 1.0 / Double(framesPerSecond),
                kCGImagePropertyGIFUnclampedDelayTime: 1.0 / Double(framesPerSecond)
            ]
        ]

        for index in 0..<frameCount {
            let seconds = min(duration - 0.001, Double(index) / Double(framesPerSecond))
            let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
            do {
                let image = try generator.copyCGImage(at: time, actualTime: nil)
                CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
            } catch {
                // Skip frames that cannot be decoded (e.g. at the very end).
                continue
            }
            progress?(Double(index + 1) / Double(frameCount))
        }

        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.destinationFailed
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        var pixelWidth = 0
        var pixelHeight = 0
        if let source = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        }
        if pixelWidth == 0 || pixelHeight == 0 {
            let aspect = asset.tracks(withMediaType: .video).first.map { $0.naturalSize } ?? .zero
            if aspect.width > 0 {
                pixelWidth = min(width, Int(aspect.width.rounded()))
                pixelHeight = Int((aspect.height * CGFloat(pixelWidth) / aspect.width).rounded())
            }
        }
        return GIFExportResult(fileSize: bytes, width: pixelWidth, height: pixelHeight)
    }
}
