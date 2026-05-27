import Foundation
import AVFoundation
import AudioToolbox

/// PCM → AAC-LC ADTS frame encoder used by the live stream. Implemented by the hardware-codec
/// path (`AacAdtsStreamEncoder`, AVAudioConverter) and the forced-software path
/// (`AacAdtsSoftwareEncoder`, AudioConverterNewSpecific).
protocol AacFrameEncoder: AnyObject {
    func encode(_ pcmBuffer: AVAudioPCMBuffer) -> [Data]
}

/// Encodes PCM buffers (the same tap format used to write the file) into AAC-LC and returns
/// self-contained ADTS frames (7-byte ADTS header + AAC payload) as `Data`.
///
/// This is intentionally a SECOND, independent encode path: the on-disk file is written by
/// `ExtAudioFile` and is the source of truth. `ExtAudioFileWrite` does not hand back the encoded
/// bytes, so the live stream re-encodes here. A failure in this encoder only affects the optional
/// stream — never the recording.
final class AacAdtsStreamEncoder: AacFrameEncoder {

    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let sampleRateIndex: Int
    private let channelConfig: Int
    private let maxPacketSize: Int

    /// Returns nil if an AAC encoder cannot be created for this PCM format (caller then skips
    /// streaming for this recording — the file path is unaffected).
    init?(pcmFormat: AVAudioFormat) {
        let channels = Int(pcmFormat.channelCount)
        guard channels > 0,
              let freqIndex = AacAdtsStreamEncoder.adtsSampleRateIndex(pcmFormat.sampleRate) else {
            return nil
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: pcmFormat.sampleRate,
            AVNumberOfChannelsKey: channels
        ]

        guard let outFormat = AVAudioFormat(settings: settings),
              let converter = AVAudioConverter(from: pcmFormat, to: outFormat) else {
            return nil
        }

        self.converter = converter
        self.outputFormat = outFormat
        self.sampleRateIndex = freqIndex
        self.channelConfig = channels
        let reported = converter.maximumOutputPacketSize
        self.maxPacketSize = reported > 0 ? reported : 1536
    }

    /// Encode one PCM buffer into zero or more complete ADTS frames.
    func encode(_ pcmBuffer: AVAudioPCMBuffer) -> [Data] {
        var output: [Data] = []
        var consumed = false

        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return pcmBuffer
        }

        while true {
            let compressed = AVAudioCompressedBuffer(
                format: outputFormat,
                packetCapacity: 8,
                maximumPacketSize: maxPacketSize
            )

            var error: NSError?
            let status = converter.convert(to: compressed, error: &error, withInputFrom: inputBlock)

            if compressed.packetCount > 0 {
                appendFrames(from: compressed, into: &output)
            }

            if status == .haveData {
                // The output buffer may have filled before input ran dry — loop for more.
                continue
            }
            // .inputRanDry / .endOfStream / .error → done with this PCM buffer.
            break
        }

        return output
    }

    // MARK: - Private

    private func appendFrames(from buffer: AVAudioCompressedBuffer, into output: inout [Data]) {
        let count = Int(buffer.packetCount)
        guard count > 0, let descriptions = buffer.packetDescriptions else { return }
        let base = buffer.data.assumingMemoryBound(to: UInt8.self)

        for i in 0..<count {
            let desc = descriptions[i]
            let size = Int(desc.mDataByteSize)
            guard size > 0 else { continue }
            let offset = Int(desc.mStartOffset)
            var frame = adtsHeader(payloadLength: size)
            frame.append(base + offset, count: size)
            output.append(frame)
        }
    }

    /// Build a 7-byte ADTS header (AAC-LC, no CRC) for a payload of `payloadLength` bytes.
    private func adtsHeader(payloadLength: Int) -> Data {
        let aacObjectType = 2                       // AAC LC
        let profileField = aacObjectType - 1        // ADTS stores object type minus 1
        let frameLength = payloadLength + 7

        var header = [UInt8](repeating: 0, count: 7)
        header[0] = 0xFF
        header[1] = 0xF1                            // syncword + MPEG-4 + Layer 0 + protection_absent
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
        case 12000: return 9
        case 11025: return 10
        case 8000:  return 11
        case 7350:  return 12
        default:    return nil
        }
    }
}
