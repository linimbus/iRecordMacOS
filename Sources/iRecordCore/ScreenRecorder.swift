import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

public struct AudioLevelInfo: Sendable {
    /// Normalized meter level from 0 (silence) to 1 (0 dBFS).
    public let level: Float
    public let rmsDB: Float
    public let peakDB: Float

    public static let silent = AudioLevelInfo(level: 0, rmsDB: -60, peakDB: -60)

    public init(level: Float, rmsDB: Float, peakDB: Float) {
        self.level = level
        self.rmsDB = rmsDB
        self.peakDB = peakDB
    }
}

/// ScreenCaptureKit based recorder that writes H.264/HEVC/ProRes QuickTime or MP4 files.
/// GIF output is recorded to a temporary MP4 first and converted on stop.
public final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    public enum State: String, Codable, Sendable {
        case idle
        case preparing
        case recording
        case paused
        case finishing
        case converting

        public var isActive: Bool {
            switch self {
            case .preparing, .recording, .paused, .finishing, .converting: return true
            case .idle: return false
            }
        }
    }

    private var storedState: State = .idle
    private let stateLock = NSLock()

    public var state: State {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedState
    }

    public var onStateChange: ((State) -> Void)?
    public var onError: ((CaptureError) -> Void)?
    /// Real-time level of the audio actually being written to the recording.
    /// Updated at roughly 20 Hz; delivers `.silent` when audio is off or paused.
    public var onAudioLevel: ((AudioLevelInfo) -> Void)?

    private let workQueue = DispatchQueue(label: "com.irecord.capture", qos: .userInitiated)
    private var lastAudioLevelEmit: CFAbsoluteTime = 0
    private var smoothedAudioLevel: Float = 0

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var options: CaptureOptions = .init()
    private var finalOutputURL: URL?
    private var recordingURL: URL?
    private var info: RecordingInfo?

    private var firstPTS: CMTime?
    private var lastSeenPTS: CMTime = .zero
    private var lastVideoTime: CMTime = .zero
    private var lastAudioTime: CMTime = .zero
    private var pausedTotal: CMTime = .zero
    private var pauseStartPTS: CMTime?
    private var resumeAnchorPTS: CMTime = .zero
    private var awaitingResumeSample = false
    private var paused = false
    private var framesWritten = 0
    private var lastPixelBuffer: CVPixelBuffer?
    private var outputSize: CGSize = .zero
    private var audioEnabled = false
    private var micAudioEnabled = false
    private var microphoneCapture: MicrophoneCapture?
    private var lastMicPTS: CMTime = .negativeInfinity
    private var micPausedTotal: TimeInterval = 0
    private var micPauseStartedAt: TimeInterval?
    private var activityToken: NSObjectProtocol?

    private func setState(_ newState: State) {
        stateLock.lock()
        let oldState = storedState
        storedState = newState
        stateLock.unlock()
        if newState == .idle {
            endActivity()
        }
        if newState != .recording {
            resetAudioLevel()
        }
        if oldState != newState {
            onStateChange?(newState)
        }
    }

    private func resetAudioLevel() {
        smoothedAudioLevel = 0
        lastAudioLevelEmit = 0
        onAudioLevel?(.silent)
    }

    private func emitAudioLevel(_ metrics: AudioMetrics) {
        let rawRMS = metrics.rms > 0 ? 20 * log10(metrics.rms) : -60
        let rawPeak = metrics.peak > 0 ? 20 * log10(metrics.peak) : -60
        let rmsDB = max(-60, min(0, rawRMS))
        let peakDB = max(-60, min(0, rawPeak))
        let normalized = (rmsDB + 60) / 60
        // Fast attack, slower release so speech peaks remain readable.
        smoothedAudioLevel = normalized > smoothedAudioLevel ? normalized : smoothedAudioLevel * 0.82

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastAudioLevelEmit >= 0.05 else { return }
        lastAudioLevelEmit = now
        onAudioLevel?(AudioLevelInfo(level: smoothedAudioLevel, rmsDB: rmsDB, peakDB: peakDB))
    }

    private func beginActivity() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled, .idleSystemSleepDisabled],
            reason: "iRecord is capturing the screen"
        )
    }

    private func endActivity() {
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
            self.activityToken = nil
        }
    }

    // MARK: - Public API

    public func start(target: CaptureTarget, options: CaptureOptions, outputURL: URL) async throws -> RecordingInfo {
        if state.isActive { throw CaptureError.alreadyRecording }

        guard Permissions.hasScreenCapture else { throw CaptureError.screenPermission }
        beginActivity()
        let opts = options.sanitized()
        if opts.capturesMicrophone && !Permissions.hasMicrophone {
            throw CaptureError.microphonePermission
        }

        setState(.preparing)

        let filter: SCContentFilter
        do {
            filter = try await ShareableContentLoader.filter(for: target)
        } catch {
            setState(.idle)
            throw error
        }

        let fileManager = FileManager.default
        let outputDirectory = outputURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            setState(.idle)
            throw CaptureError.outputNotWritable(outputDirectory.path)
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RecordingInfo, Error>) in
            workQueue.async {
                do {
                    let info = try self.configure(filter: filter, target: target, options: opts, outputURL: outputURL)
                    guard let stream = self.stream else {
                        throw CaptureError.captureFailed("stream was not created")
                    }
                    stream.startCapture { error in
                        if let error {
                            Log.write("startCapture failed: \(error)")
                            self.workQueue.async {
                                self.abortLocked()
                            }
                            continuation.resume(throwing: CaptureError.captureFailed(error.localizedDescription))
                        } else {
                            self.setState(.recording)
                            continuation.resume(returning: info)
                        }
                    }
                } catch {
                    self.abortLocked()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func pause() {
        workQueue.async {
            guard self.state == .recording else { return }
            self.paused = true
            self.pauseStartPTS = self.lastSeenPTS
            self.microphoneCapture?.setPaused(true)
            self.micPauseStartedAt = self.currentHostSeconds()
            self.setState(.paused)
        }
    }

    public func resume() {
        workQueue.async {
            guard self.state == .paused else { return }
            self.paused = false
            self.resumeAnchorPTS = self.pauseStartPTS ?? self.lastSeenPTS
            self.awaitingResumeSample = true
            self.pauseStartPTS = nil
            self.microphoneCapture?.setPaused(false)
            if let startedAt = self.micPauseStartedAt {
                self.micPausedTotal += self.currentHostSeconds() - startedAt
            }
            self.micPauseStartedAt = nil
            self.setState(.recording)
        }
    }

    public func stop() async throws -> RecordingResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RecordingResult, Error>) in
            workQueue.async {
                self.stopLocked { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    public func abort() {
        workQueue.async {
            self.abortLocked()
        }
    }

    // MARK: - Configuration

    private func configure(filter: SCContentFilter, target: CaptureTarget, options: CaptureOptions, outputURL: URL) throws -> RecordingInfo {
        self.options = options
        self.finalOutputURL = outputURL
        let wantsSystemAudio = options.capturesSystemAudio
        let wantsMicrophone = options.capturesMicrophone

        let pixelScale = CGFloat(filter.pointPixelScale)
        var baseWidth: CGFloat
        var baseHeight: CGFloat
        if case .region(_, let rect) = target {
            baseWidth = rect.width
            baseHeight = rect.height
        } else {
            baseWidth = filter.contentRect.width
            baseHeight = filter.contentRect.height
        }
        if baseWidth <= 1 || baseHeight <= 1 {
            throw CaptureError.captureFailed("invalid content size")
        }

        var width = Int((baseWidth * pixelScale * options.scale).rounded())
        var height = Int((baseHeight * pixelScale * options.scale).rounded())
        width = max(2, width - (width % 2))
        height = max(2, height - (height % 2))
        outputSize = CGSize(width: width, height: height)

        let tempRecordingURL: URL
        if options.format.isGIF {
            tempRecordingURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("irecord-\(UUID().uuidString).mp4")
        } else {
            tempRecordingURL = outputURL
        }
        recordingURL = tempRecordingURL
        try? FileManager.default.removeItem(at: tempRecordingURL)

        let desiredFileType: AVFileType = options.format.isGIF ? .mp4 : options.format.fileType
        let codec: AVVideoCodecType = options.format.isGIF ? .h264 : options.format.codec

        let recorder = try AVAssetWriter(outputURL: tempRecordingURL, fileType: desiredFileType)
        // Network optimization (fast-start) makes AVAssetWriter write an extra
        // unoptimized sidecar that can be left behind if the process exits
        // immediately after finishing. Local recordings play fine without it.
        recorder.shouldOptimizeForNetworkUse = false

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        if codec != .proRes422 {
            let bitrate = max(
                1_500_000,
                min(150_000_000, Int(Double(width * height * options.fps) * options.quality.bitsPerPixel))
            )
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: options.fps,
                AVVideoMaxKeyFrameIntervalKey: options.fps * 2,
                AVVideoAllowFrameReorderingKey: true
            ]
            if codec == .h264 {
                compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            videoSettings[AVVideoCompressionPropertiesKey] = compression
        }
        videoSettings[AVVideoColorPropertiesKey] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        video.mediaTimeScale = CMTimeScale(options.fps)
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        let pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: attributes
        )
        guard recorder.canAdd(video) else {
            throw CaptureError.writerFailed("video input rejected")
        }
        recorder.add(video)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000
        ]
        var systemAudioInput: AVAssetWriterInput?
        var microphoneAudioInput: AVAssetWriterInput?

        // Add the microphone track first so players that select a single audio
        // track default to the voice track. System audio follows as a second
        // track when both sources are enabled.
        if wantsMicrophone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard recorder.canAdd(input) else {
                throw CaptureError.writerFailed("microphone audio input rejected")
            }
            recorder.add(input)
            microphoneAudioInput = input
        }
        if wantsSystemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard recorder.canAdd(input) else {
                throw CaptureError.writerFailed("system audio input rejected")
            }
            recorder.add(input)
            systemAudioInput = input
        }

        guard recorder.startWriting() else {
            throw CaptureError.writerFailed(recorder.error?.localizedDescription ?? "startWriting failed")
        }

        writer = recorder
        videoInput = video
        audioInput = systemAudioInput
        micInput = microphoneAudioInput
        micAudioEnabled = microphoneAudioInput != nil
        audioEnabled = systemAudioInput != nil || microphoneAudioInput != nil
        adaptor = pixelAdaptor
        framesWritten = 0
        firstPTS = nil
        lastSeenPTS = .zero
        lastVideoTime = .zero
        lastAudioTime = .zero
        lastMicPTS = .negativeInfinity
        micPausedTotal = 0
        micPauseStartedAt = nil
        pausedTotal = .zero
        pauseStartPTS = nil
        awaitingResumeSample = false
        paused = false
        lastPixelBuffer = nil

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        configuration.queueDepth = 6
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = options.showCursor
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.shouldBeOpaque = true
        configuration.captureResolution = .best
        // System audio comes from ScreenCaptureKit. Microphone capture is a
        // separate AVAudioEngine path so it does not depend on SCK's
        // captureMicrophone support.
        configuration.capturesAudio = wantsSystemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        if #available(macOS 15.0, *) {
            configuration.showMouseClicks = options.highlightClicks
        }
        if case .region(_, let rect) = target {
            configuration.sourceRect = rect
        }
        if case .window = target {
            configuration.ignoreShadowsSingleWindow = true
            configuration.includeChildWindows = true
        }

        let captureStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try captureStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: workQueue)
        if wantsSystemAudio {
            try captureStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: workQueue)
        }
        stream = captureStream

        if wantsMicrophone {
            guard micAudioEnabled else {
                throw CaptureError.writerFailed("microphone audio input rejected")
            }
            let microphone = MicrophoneCapture()
            microphone.onSample = { [weak self] sample in
                self?.enqueueMicrophoneSample(sample)
            }
            try microphone.start()
            microphoneCapture = microphone
        }

        let info = RecordingInfo(
            outputPath: outputURL.path,
            width: width,
            height: height,
            format: options.format,
            fps: options.fps,
            hasAudio: audioEnabled
        )
        self.info = info
        Log.write("Capture configured \(width)x\(height) @\(options.fps)fps audio=\(audioEnabled) format=\(options.format.rawValue) -> \(tempRecordingURL.path)")
        return info
    }

    // MARK: - Sample handling

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if pts.isValid, state != .paused, state != .finishing, state != .converting {
            lastSeenPTS = max(lastSeenPTS, pts)
        }
        switch type {
        case .screen:
            handleVideo(sampleBuffer, pts: pts)
        case .audio:
            handleAudio(sampleBuffer, pts: pts)
        default:
            break
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("SCStream stopped with error: \(error)")
        workQueue.async {
            guard self.state != .idle else { return }
            let captureError = CaptureError.captureFailed(error.localizedDescription)
            self.onError?(captureError)
            self.abortLocked()
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer, pts: CMTime) {
        guard state == .recording else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Only complete frames contain a new image. Idle frames are duplicate content.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw),
           status != .complete {
            return
        }

        if firstPTS == nil {
            firstPTS = pts
            writer?.startSession(atSourceTime: .zero)
        }
        guard let base = firstPTS, pts >= base else { return }
        guard let adjusted = adjustedTime(pts) else { return }
        guard adjusted >= lastVideoTime else { return }
        guard let videoInput, videoInput.isReadyForMoreMediaData, let adaptor else { return }
        if adaptor.append(pixelBuffer, withPresentationTime: adjusted) {
            lastVideoTime = adjusted
            lastPixelBuffer = pixelBuffer
            framesWritten += 1
        } else if let error = writer?.error {
            Log.write("Failed to append video frame: \(error)")
        }
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer, pts: CMTime) {
        guard audioEnabled, state == .recording, firstPTS != nil else { return }
        guard let adjusted = adjustedTime(pts) else { return }
        guard adjusted >= lastAudioTime, adjusted >= .zero else { return }
        guard let audioInput, audioInput.isReadyForMoreMediaData else { return }
        guard let built = AudioSampleBuilder.make(from: sampleBuffer, presentationTime: adjusted) else {
            Log.write("Could not prepare audio sample buffer")
            return
        }
        emitAudioLevel(built.metrics)
        if audioInput.append(built.sampleBuffer) {
            lastAudioTime = adjusted
        } else if let error = writer?.error {
            Log.write("Failed to append audio: \(error)")
        }
    }

    private func enqueueMicrophoneSample(_ sample: MicrophoneSample) {
        workQueue.async { [weak self] in
            self?.appendMicrophoneSample(sample)
        }
    }

    private func appendMicrophoneSample(_ sample: MicrophoneSample) {
        guard micAudioEnabled, let micInput, state == .recording, !paused, let firstPTS else { return }
        let seconds = sample.hostSeconds - CMTimeGetSeconds(firstPTS) - micPausedTotal
        guard seconds >= 0 else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 48_000)
        guard time > lastMicPTS else { return }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var retimed: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample.sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &retimed
        )
        guard status == noErr, let retimed, micInput.isReadyForMoreMediaData else { return }
        if micInput.append(retimed) {
            lastMicPTS = time
            emitAudioLevel(sample.metrics)
        } else if let error = writer?.error {
            Log.write("Failed to append microphone audio: \(error)")
        }
    }

    private func currentHostSeconds() -> TimeInterval {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }

    private func adjustedTime(_ pts: CMTime) -> CMTime? {
        guard let firstPTS else { return nil }
        if awaitingResumeSample {
            let gap = pts - resumeAnchorPTS
            if gap > .zero {
                pausedTotal = pausedTotal + gap
            }
            awaitingResumeSample = false
        }
        var value = pts - firstPTS - pausedTotal
        if value < .zero { value = .zero }
        return value
    }

    // MARK: - Stopping & finishing

    private func stopLocked(completion: @escaping (Result<RecordingResult, Error>) -> Void) {
        guard state == .recording || state == .paused else {
            completion(.failure(CaptureError.notRecording))
            return
        }
        setState(.finishing)
        paused = false
        microphoneCapture?.stop()
        microphoneCapture = nil

        guard let activeStream = stream else {
            completion(.failure(CaptureError.notRecording))
            return
        }
        stream = nil

        activeStream.stopCapture { error in
            if let error {
                Log.write("stopCapture error: \(error)")
            }
            self.workQueue.async {
                self.finalize(completion: completion)
            }
        }
    }

    private func finalize(completion: @escaping (Result<RecordingResult, Error>) -> Void) {
        guard let writer, let videoInput else {
            completion(.failure(CaptureError.notRecording))
            return
        }

        if framesWritten == 0 {
            writer.cancelWriting()
            setState(.idle)
            cleanupRecordingFile()
            completion(.failure(CaptureError.stoppedEarly))
            return
        }

        // Add a final frame at the end of the timeline so recordings of a static
        // screen keep their full duration.
        var endTime = max(lastVideoTime, lastAudioTime)
        if let pauseStartPTS, let firstPTS {
            endTime = max(endTime, pauseStartPTS - firstPTS - pausedTotal)
        } else if firstPTS != nil {
            endTime = max(endTime, lastSeenPTS - (firstPTS ?? .zero) - pausedTotal)
        }
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        if endTime <= lastVideoTime {
            endTime = lastVideoTime + frameDuration
        }
        if let buffer = lastPixelBuffer, videoInput.isReadyForMoreMediaData, let adaptor {
            if adaptor.append(buffer, withPresentationTime: endTime) {
                lastVideoTime = endTime
            }
        }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        micInput?.markAsFinished()

        let recordedURL = recordingURL
        let finalURL = finalOutputURL
        let format = options.format
        let duration = CMTimeGetSeconds(lastVideoTime)
        let size = outputSize
        let audio = audioEnabled

        writer.finishWriting {
            let status = writer.status
            let writerError = writer.error
            self.workQueue.async {
                guard status == .completed else {
                    self.setState(.idle)
                    self.cleanupRecordingFile()
                    completion(.failure(CaptureError.writerFailed(writerError?.localizedDescription ?? "finishWriting failed")))
                    return
                }
                guard let recordedURL, let finalURL else {
                    self.setState(.idle)
                    completion(.failure(CaptureError.exportFailed("missing output path")))
                    return
                }

                if format.isGIF {
                    self.setState(.converting)
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let gif = try GIFExporter.convert(
                                videoURL: recordedURL,
                                outputURL: finalURL,
                                fps: self.options.gifFPS,
                                maxWidth: self.options.gifMaxWidth
                            )
                            try? FileManager.default.removeItem(at: recordedURL)
                            self.setState(.idle)
                            let result = RecordingResult(
                                outputPath: finalURL.path,
                                format: format,
                                duration: duration,
                                width: gif.width,
                                height: gif.height,
                                fileSize: gif.fileSize,
                                hasAudio: false
                            )
                            completion(.success(result))
                        } catch {
                            try? FileManager.default.removeItem(at: recordedURL)
                            try? FileManager.default.removeItem(at: finalURL)
                            self.setState(.idle)
                            completion(.failure(CaptureError.exportFailed(error.localizedDescription)))
                        }
                    }
                } else {
                    let bytes = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                    self.setState(.idle)
                    let result = RecordingResult(
                        outputPath: finalURL.path,
                        format: format,
                        duration: duration,
                        width: Int(size.width),
                        height: Int(size.height),
                        fileSize: bytes,
                        hasAudio: audio
                    )
                    completion(.success(result))
                }
            }
        }
    }

    private func abortLocked() {
        let activeStream = stream
        let activeWriter = writer
        stream = nil
        writer = nil
        videoInput = nil
        audioInput = nil
        micInput = nil
        microphoneCapture?.stop()
        microphoneCapture = nil
        micAudioEnabled = false
        adaptor = nil
        setState(.idle)
        if let activeStream {
            activeStream.stopCapture { _ in }
        }
        if let activeWriter, activeWriter.status == .writing {
            activeWriter.cancelWriting()
        }
        cleanupRecordingFile()
    }

    private func cleanupRecordingFile() {
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
    }
}
