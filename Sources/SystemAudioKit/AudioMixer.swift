import AVFoundation
import Foundation

/// Mixes aligned tracks into a single file.
public enum AudioMixer {
    public enum Error: LocalizedError {
        case noTracks
        case unsupportedExtension(String)

        public var errorDescription: String? {
            switch self {
            case .noTracks: return "There are no tracks to mix."
            case .unsupportedExtension(let ext): return "Cannot write audio as .\(ext); use .wav or .m4a."
            }
        }
    }

    /// Sums the tracks sample by sample. Each track is scaled by 1/√n rather than 1/n, which keeps
    /// speech from getting quiet when only one side talks, and the result is soft clipped.
    /// Tracks must share a sample rate and channel count (``AlignedTrackWriter`` guarantees that).
    public static func mix(_ inputs: [URL], to output: URL) throws {
        guard !inputs.isEmpty else { throw Error.noTracks }
        let files = try inputs.map { try AVAudioFile(forReading: $0, commonFormat: .pcmFormatFloat32, interleaved: false) }
        let format = files[0].processingFormat
        let settings = try outputSettings(for: output, format: format)
        try? FileManager.default.removeItem(at: output)
        let out = try AVAudioFile(forWriting: output, settings: settings,
                                  commonFormat: .pcmFormatFloat32, interleaved: false)

        let chunk: AVAudioFrameCount = 16_384
        let buffers = files.map { AVAudioPCMBuffer(pcmFormat: $0.processingFormat, frameCapacity: chunk)! }
        let mixed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
        let gain = 1 / Float(files.count).squareRoot()
        let channels = Int(format.channelCount)

        while files.contains(where: { $0.framePosition < $0.length }) {
            var frames: AVAudioFrameCount = 0
            for (file, buffer) in zip(files, buffers) {
                buffer.frameLength = 0
                if file.framePosition < file.length { try file.read(into: buffer, frameCount: chunk) }
                frames = max(frames, buffer.frameLength)
            }
            guard frames > 0, let destination = mixed.floatChannelData else { break }
            mixed.frameLength = frames
            for channel in 0..<channels {
                let target = destination[channel]
                target.update(repeating: 0, count: Int(frames))
                for buffer in buffers {
                    guard let source = buffer.floatChannelData else { continue }
                    let sourceChannel = min(channel, Int(buffer.format.channelCount) - 1)
                    for index in 0..<Int(buffer.frameLength) {
                        target[index] += source[sourceChannel][index] * gain
                    }
                }
                for index in 0..<Int(frames) { target[index] = softClip(target[index]) }
            }
            try out.write(from: mixed)
        }
    }

    @inline(__always)
    static func softClip(_ x: Float) -> Float {
        abs(x) < 0.9 ? x : tanh(x)
    }

    static func outputSettings(for url: URL, format: AVAudioFormat) throws -> [String: Any] {
        switch url.pathExtension.lowercased() {
        case "wav":
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        case "m4a", "aac":
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: format.sampleRate <= 16_000 ? 32_000 : 64_000,
            ]
        default:
            throw Error.unsupportedExtension(url.pathExtension)
        }
    }
}
