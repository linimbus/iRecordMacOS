import AVFoundation
import CoreMedia
import Foundation

struct MicrophoneSample {
    let sampleBuffer: CMSampleBuffer
    let hostSeconds: Double
    let metrics: AudioMetrics
}

/// Captures the default microphone with AVAudioEngine. ScreenCaptureKit's
/// `captureMicrophone` flag can silently produce no microphone samples on some
/// systems and with some content filters, so microphone capture is kept
/// independent from the screen stream.
final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private var inputNode: AVAudioInputNode?
    private var converter: AVAudioConverter?
    private var converterOutputFormat: AVAudioFormat?
    private let lock = NSLock()
    private var paused = false
    private var started = false

    var onSample: ((MicrophoneSample) -> Void)?

    func start() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw CaptureError.microphonePermission
        }
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.captureFailed("No microphone input device is available.")
        }

        if inputFormat.sampleRate != 48_000 || inputFormat.channelCount > 2 {
            let channels: AVAudioChannelCount = inputFormat.channelCount == 1 ? 1 : 2
            guard let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: channels,
                interleaved: false
            ), let converter = AVAudioConverter(from: inputFormat, to: target) else {
                throw CaptureError.captureFailed("The microphone format is not supported.")
            }
            self.converter = converter
            self.converterOutputFormat = target
        }

        inputNode = input
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, time in
            self?.process(buffer: buffer, time: time)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            inputNode = nil
            throw CaptureError.captureFailed("Microphone could not start: \(error.localizedDescription)")
        }
        started = true
    }

    func setPaused(_ paused: Bool) {
        lock.lock()
        self.paused = paused
        lock.unlock()
    }

    func stop() {
        guard started || inputNode != nil else { return }
        inputNode?.removeTap(onBus: 0)
        engine.stop()
        inputNode = nil
        converter = nil
        converterOutputFormat = nil
        started = false
    }

    deinit {
        stop()
    }

    private func process(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        lock.lock()
        let isPaused = paused
        lock.unlock()
        guard !isPaused, buffer.frameLength > 0 else { return }

        guard let normalized = normalize(buffer) else { return }
        guard let sampleBuffer = makeSampleBuffer(from: normalized) else { return }

        let hostSeconds: Double
        if time.isHostTimeValid {
            hostSeconds = AVAudioTime.seconds(forHostTime: time.hostTime)
        } else {
            hostSeconds = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        }
        onSample?(MicrophoneSample(
            sampleBuffer: sampleBuffer,
            hostSeconds: hostSeconds,
            metrics: metrics(from: normalized)
        ))
    }

    private func normalize(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = buffer.format
        if format.commonFormat == .pcmFormatFloat32, format.sampleRate == 48_000 {
            switch format.channelCount {
            case 1: return duplicateMono(buffer)
            case 2: return buffer
            default: break
            }
        }
        if let converter, let target = converterOutputFormat {
            let ratio = target.sampleRate / format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
            var error: NSError?
            var supplied = false
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                if supplied {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard status == .haveData || status == .inputRanDry, output.frameLength > 0 else { return nil }
            if target.channelCount == 1 {
                return duplicateMono(output)
            }
            return output
        }
        return format.channelCount == 1 ? duplicateMono(buffer) : buffer
    }

    private func duplicateMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let source = buffer.floatChannelData?[0],
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: buffer.format.sampleRate,
                channels: 2,
                interleaved: false
              ),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        output.frameLength = buffer.frameLength
        guard let destination = output.floatChannelData else { return nil }
        for index in 0..<Int(buffer.frameLength) {
            let value = source[index]
            destination[0][index] = value
            destination[1][index] = value
        }
        return output
    }

    private func metrics(from buffer: AVAudioPCMBuffer) -> AudioMetrics {
        guard let channels = buffer.floatChannelData else {
            return AudioMetrics(peak: 0, rms: 0)
        }
        var peak: Float = 0
        var sumSquares: Double = 0
        let frames = Int(buffer.frameLength)
        for frame in 0..<frames {
            let left = channels[0][frame]
            let right = buffer.format.channelCount > 1 ? channels[1][frame] : left
            peak = max(peak, max(abs(left), abs(right)))
            sumSquares += Double(left * left) + Double(right * right)
        }
        let rms = frames > 0 ? Float(sqrt(sumSquares / Double(frames * 2))) : 0
        return AudioMetrics(peak: peak, rms: rms)
    }

    private func makeSampleBuffer(from buffer: AVAudioPCMBuffer) -> CMSampleBuffer? {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return nil }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else {
            return nil
        }

        let bytes = frames * 8
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: bytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else {
            return nil
        }

        let interleaved = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        defer { interleaved.deallocate() }
        for frame in 0..<frames {
            let left = channels[0][frame]
            let right = buffer.format.channelCount > 1 ? channels[1][frame] : left
            interleaved[frame * 2] = left
            interleaved[frame * 2 + 1] = right
        }
        let replaceStatus = interleaved.withMemoryRebound(to: UInt8.self, capacity: bytes) { pointer in
            CMBlockBufferReplaceDataBytes(
                with: pointer,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: bytes
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleSize = 8
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr else {
            return nil
        }
        return sampleBuffer
    }
}
