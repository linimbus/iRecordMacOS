import AudioToolbox
import CoreMedia
import Foundation

/// ScreenCaptureKit delivers audio as non-interleaved Float32 LPCM sample
/// buffers whose audio buffer list is not always consumable by AVAssetWriter's
/// AAC encoder. This builder copies the PCM data into a fresh, interleaved
/// stereo sample buffer with explicit timing and sample sizes.
struct AudioMetrics: Sendable {
    let peak: Float
    let rms: Float
}

struct BuiltAudioSample {
    let sampleBuffer: CMSampleBuffer
    let metrics: AudioMetrics
}

enum AudioSampleBuilder {
    static let outputSampleRate: Double = 48_000
    static let outputChannels: UInt32 = 2
    static let bytesPerFrame: UInt32 = 8 // 2 channels × Float32

    static func make(from sampleBuffer: CMSampleBuffer, presentationTime: CMTime) -> BuiltAudioSample? {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
            return nil
        }
        let sourceASBD = asbdPointer.pointee
        guard sourceASBD.mFormatID == kAudioFormatLinearPCM,
              sourceASBD.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              sourceASBD.mBitsPerChannel == 32,
              sourceASBD.mChannelsPerFrame > 0 else {
            // Fall back to retiming the original buffer if the format is unexpected.
            guard let copy = retimedCopy(sampleBuffer, presentationTime: presentationTime) else { return nil }
            return BuiltAudioSample(sampleBuffer: copy, metrics: AudioMetrics(peak: 0, rms: 0))
        }

        let sourceChannels = Int(sourceASBD.mChannelsPerFrame)
        let sourceRate = sourceASBD.mSampleRate > 0 ? sourceASBD.mSampleRate : outputSampleRate
        let frameBytes = frameCount * MemoryLayout<Float>.size
        let abl = AudioBufferList.allocate(maximumBuffers: sourceChannels)
        for index in 0..<sourceChannels {
            abl[index].mNumberChannels = 1
            abl[index].mDataByteSize = UInt32(frameBytes)
            abl[index].mData = malloc(frameBytes)
        }
        defer {
            for index in 0..<sourceChannels {
                free(abl[index].mData)
            }
            free(abl.unsafeMutablePointer)
        }

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: abl.unsafeMutablePointer
        )
        guard copyStatus == noErr else { return nil }

        let channelPointers: [UnsafeMutablePointer<Float>] = (0..<sourceChannels).compactMap {
            abl[$0].mData?.assumingMemoryBound(to: Float.self)
        }
        guard channelPointers.count == sourceChannels else { return nil }

        let outputBytes = frameCount * Int(bytesPerFrame)
        let interleaved = UnsafeMutablePointer<Float>.allocate(capacity: frameCount * Int(outputChannels))
        defer { interleaved.deallocate() }

        var peak: Float = 0
        var sumSquares: Double = 0
        if sourceChannels == 1 {
            let mono = channelPointers[0]
            for frame in 0..<frameCount {
                let value = mono[frame]
                peak = max(peak, abs(value))
                sumSquares += Double(value * value) * 2
                interleaved[frame * 2] = value
                interleaved[frame * 2 + 1] = value
            }
        } else {
            let left = channelPointers[0]
            let right = channelPointers[1]
            for frame in 0..<frameCount {
                let l = left[frame]
                let r = right[frame]
                peak = max(peak, max(abs(l), abs(r)))
                sumSquares += Double(l * l) + Double(r * r)
                interleaved[frame * 2] = l
                interleaved[frame * 2 + 1] = r
            }
        }
        let rms = frameCount > 0 ? Float(sqrt(sumSquares / Double(frameCount * 2))) : 0

        var outputASBD = AudioStreamBasicDescription(
            mSampleRate: sourceRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: outputChannels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var outputFormat: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &outputASBD,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &outputFormat
        )
        guard formatStatus == noErr, let outputFormat else { return nil }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: outputBytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: outputBytes,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let replaceStatus = interleaved.withMemoryRebound(to: UInt8.self, capacity: outputBytes) { pointer in
            CMBlockBufferReplaceDataBytes(
                with: pointer,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: outputBytes
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sourceRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleSize = Int(bytesPerFrame)
        var output: CMSampleBuffer?
        let bufferStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: outputFormat,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &output
        )
        guard bufferStatus == noErr, let output else { return nil }
        return BuiltAudioSample(
            sampleBuffer: output,
            metrics: AudioMetrics(peak: peak, rms: rms)
        )
    }

    private static func retimedCopy(_ sampleBuffer: CMSampleBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(outputSampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        return status == noErr ? copy : nil
    }
}
