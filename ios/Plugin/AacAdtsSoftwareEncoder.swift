import Foundation
import AVFoundation
import AudioToolbox

/// PCM → AAC-LC encoder that FORCES Apple's *software* AAC codec via AudioConverterNewSpecific
/// (kAppleSoftwareAudioCodecManufacturer). The hardware AAC encoder is unavailable while the
/// audio session uses `.mixWithOthers` and silently yields empty/silent output on some devices
/// (notably iPhone) — the software codec is not subject to that limitation.
///
/// Same public surface as `AacAdtsStreamEncoder`: `init?(pcmFormat:)` + `encode(_:) -> [Data]`
/// returning self-contained ADTS frames. Independent of the on-disk file path.
final class AacAdtsSoftwareEncoder: AacFrameEncoder {

    private var converter: AudioConverterRef?
    private let sampleRateIndex: Int
    private let channelConfig: Int
    private let channels: Int

    /// Per-encode context handed to the C input proc via `inUserData`.
    private final class InputContext {
        var bufferList: UnsafePointer<AudioBufferList>?
        var packets: UInt32 = 0
        var consumed = false
    }
    private let inputContext = InputContext()

    init?(pcmFormat: AVAudioFormat) {
        let channels = Int(pcmFormat.channelCount)
        guard channels > 0,
              let freqIndex = AacAdtsSoftwareEncoder.adtsSampleRateIndex(pcmFormat.sampleRate) else {
            return nil
        }
        self.channels = channels
        self.sampleRateIndex = freqIndex
        self.channelConfig = channels

        var inASBD = pcmFormat.streamDescription.pointee
        var outASBD = AudioStreamBasicDescription(
            mSampleRate: pcmFormat.sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,                 // AAC-LC is implied; matches the on-disk ExtAudioFile output
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )

        // Explicitly request the SOFTWARE AAC encoder.
        var classDesc = AudioClassDescription(
            mType: kAudioEncoderComponentType,
            mSubType: kAudioFormatMPEG4AAC,
            mManufacturer: kAppleSoftwareAudioCodecManufacturer
        )

        var ref: AudioConverterRef?
        let status = AudioConverterNewSpecific(&inASBD, &outASBD, 1, &classDesc, &ref)
        guard status == noErr, let converter = ref else {
            NSLog("AacAdtsSoftwareEncoder: AudioConverterNewSpecific failed: %d", status)
            return nil
        }
        self.converter = converter
    }

    deinit {
        if let converter = converter { AudioConverterDispose(converter) }
    }

    /// C input proc — supplies the current PCM buffer exactly once, then reports "no more data".
    private static let inputProc: AudioConverterComplexInputDataProc = {
        _, ioNumberDataPackets, ioData, _, inUserData in
        guard let inUserData = inUserData else {
            ioNumberDataPackets.pointee = 0
            return noErr
        }
        let ctx = Unmanaged<InputContext>.fromOpaque(inUserData).takeUnretainedValue()
        if ctx.consumed || ctx.bufferList == nil {
            ioNumberDataPackets.pointee = 0
            return noErr
        }
        // Point the converter's input AudioBufferList at the PCM buffer's storage.
        let src = ctx.bufferList!.pointee
        let dst = UnsafeMutableAudioBufferListPointer(ioData)
        let srcList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: ctx.bufferList!))
        dst.count = Int(src.mNumberBuffers)
        for i in 0..<Int(src.mNumberBuffers) {
            dst[i] = srcList[i]
        }
        ioNumberDataPackets.pointee = ctx.packets
        ctx.consumed = true
        return noErr
    }

    func encode(_ pcmBuffer: AVAudioPCMBuffer) -> [Data] {
        guard let converter = converter, pcmBuffer.frameLength > 0 else { return [] }

        inputContext.bufferList = pcmBuffer.audioBufferList
        inputContext.packets = pcmBuffer.frameLength
        inputContext.consumed = false

        var output: [Data] = []
        let maxPacketSize = 1536
        let packetCapacity = 8
        let outData = UnsafeMutableRawPointer.allocate(byteCount: maxPacketSize * packetCapacity, alignment: 1)
        defer { outData.deallocate() }

        let ctxPtr = Unmanaged.passUnretained(inputContext).toOpaque()

        while true {
            var ioPackets = UInt32(packetCapacity)
            var abl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: UInt32(maxPacketSize * packetCapacity),
                    mData: outData
                )
            )
            var packetDescs = [AudioStreamPacketDescription](repeating: AudioStreamPacketDescription(), count: packetCapacity)

            let status = AudioConverterFillComplexBuffer(
                converter, AacAdtsSoftwareEncoder.inputProc, ctxPtr,
                &ioPackets, &abl, &packetDescs
            )

            if ioPackets > 0 {
                let base = outData.assumingMemoryBound(to: UInt8.self)
                for i in 0..<Int(ioPackets) {
                    let size = Int(packetDescs[i].mDataByteSize)
                    guard size > 0 else { continue }
                    let offset = Int(packetDescs[i].mStartOffset)
                    var frame = adtsHeader(payloadLength: size)
                    frame.append(base + offset, count: size)
                    output.append(frame)
                }
            }

            // status noErr with ioPackets>0 means more may be available; loop. Otherwise done.
            if status != noErr || ioPackets == 0 { break }
        }

        return output
    }

    // MARK: - ADTS header (AAC-LC, no CRC) — identical layout to AacAdtsStreamEncoder.
    private func adtsHeader(payloadLength: Int) -> Data {
        let profileField = 1                 // AAC LC object type (2) minus 1
        let frameLength = payloadLength + 7
        var header = [UInt8](repeating: 0, count: 7)
        header[0] = 0xFF
        header[1] = 0xF1
        header[2] = UInt8(truncatingIfNeeded: (profileField << 6) | (sampleRateIndex << 2) | ((channelConfig >> 2) & 0x1))
        header[3] = UInt8(truncatingIfNeeded: ((channelConfig & 0x3) << 6) | ((frameLength >> 11) & 0x3))
        header[4] = UInt8(truncatingIfNeeded: (frameLength >> 3) & 0xFF)
        header[5] = UInt8(truncatingIfNeeded: ((frameLength & 0x7) << 5) | 0x1F)
        header[6] = 0xFC
        return Data(header)
    }

    private static func adtsSampleRateIndex(_ sampleRate: Double) -> Int? {
        switch Int(sampleRate.rounded()) {
        case 96000: return 0
        case 88200: return 1
        case 64000: return 2
        case 48000: return 3
        case 44100: return 4
        case 32000: return 5
        case 24000: return 6
        case 22050: return 7
        case 16000: return 8
        default: return nil
        }
    }
}
