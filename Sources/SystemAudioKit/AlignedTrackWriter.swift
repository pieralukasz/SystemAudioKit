import AVFoundation
import CoreAudio
import Foundation

/// The format a track is written in. The default, 16 kHz mono, is what speech models expect.
public struct TrackFormat: Sendable, Equatable {
    public var sampleRate: Double
    public var channels: AVAudioChannelCount

    public init(sampleRate: Double = 16_000, channels: AVAudioChannelCount = 1) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public static let speech = TrackFormat()

    var processingFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                      channels: channels, interleaved: false)!
    }

    /// 16-bit PCM WAV settings.
    var fileSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }
}

/// Converts incoming buffers to a fixed format and writes them to a WAV file on a
/// timeline anchored to host time. When the source goes quiet and stops delivering
/// buffers (Core Audio taps do this while nothing plays), the gap is filled with
/// silence, so separate tracks started together stay aligned sample for sample.
///
/// Thread safe: `append` may be called from any thread, but not from a real-time IO
/// thread (it allocates and does file IO). Hop off the IO thread first.
public final class AlignedTrackWriter: @unchecked Sendable {
    public let url: URL
    public let format: TrackFormat

    /// Gaps shorter than this are treated as scheduling jitter, not silence.
    static let GAP_TOLERANCE_SECONDS: Double = 0.08

    private let lock = NSLock()
    private var file: AVAudioFile?
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private let startHostTime: UInt64
    /// Frames actually in the file.
    private var writtenFrames: AVAudioFramePosition = 0
    /// Where the timeline stands, in output frames: written frames plus input still
    /// buffered inside the sample-rate converter. Gaps are measured against this, so the
    /// converter's latency is not mistaken for missing audio.
    private var timelineFrames: Double = 0
    private var peak: Float = 0

    /// Called with a 0...1 loudness per appended buffer, on the caller's thread.
    public var onLevel: (@Sendable (Float) -> Void)?

    /// - Parameter startHostTime: Host time (`mach_absolute_time`) that sample 0 represents.
    ///   Pass the same value to every track of one recording.
    public init(url: URL, format: TrackFormat = .speech, startHostTime: UInt64) throws {
        self.url = url
        self.format = format
        self.outputFormat = format.processingFormat
        self.startHostTime = startHostTime
        file = try AVAudioFile(forWriting: url, settings: format.fileSettings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Seconds on the timeline so far, including padded silence.
    public var duration: TimeInterval {
        lock.withLock { timelineFrames / format.sampleRate }
    }

    /// Loudest normalized level since the last call, then resets. Useful for "is this track silent?" checks.
    public func takePeak() -> Float {
        lock.withLock {
            defer { peak = 0 }
            return peak
        }
    }

    /// Appends a buffer captured at `hostTime`. Pass nil when the time is unknown; the
    /// buffer is then placed right after the previous one.
    public func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64?) {
        guard buffer.frameLength > 0 else { return }
        let level = AudioLevel.normalized(buffer)
        onLevel?(level)

        lock.lock()
        defer { lock.unlock() }
        guard let file else { return }
        peak = max(peak, level)

        if let hostTime, hostTime > startHostTime {
            let expected = frames(at: hostTime)
            if expected - timelineFrames > Self.GAP_TOLERANCE_SECONDS * format.sampleRate {
                // Close the previous stretch of audio, then pad up to where this buffer belongs.
                drainConverter(into: file)
                writeSilence(frames: AVAudioFramePosition(expected) - writtenFrames, to: file)
            }
        }

        let input = Self.reduceChannels(buffer, to: outputFormat.channelCount)
        timelineFrames += Double(input.frameLength) * outputFormat.sampleRate / input.format.sampleRate
        if let converted = convert(input) { write(converted, to: file) }
    }

    /// Pads the track with silence up to `hostTime` (normally the recording's stop time),
    /// so every track of a recording ends at the same moment, then closes the file.
    public func finish(at hostTime: UInt64? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard let file else { return }
        drainConverter(into: file)
        if let hostTime, hostTime > startHostTime {
            let expected = AVAudioFramePosition(frames(at: hostTime))
            if expected > writtenFrames { writeSilence(frames: expected - writtenFrames, to: file) }
        }
        self.file = nil
        converter = nil
    }

    private func frames(at hostTime: UInt64) -> Double {
        HostClock.seconds(from: startHostTime, to: hostTime) * format.sampleRate
    }

    private func write(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile) {
        do {
            try file.write(from: buffer)
            writtenFrames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            // A failed write drops one buffer; the next gap check restores alignment.
        }
    }

    private func writeSilence(frames: AVAudioFramePosition, to file: AVAudioFile) {
        var remaining = frames
        let chunk: AVAudioFrameCount = 16_384
        guard remaining > 0,
              let silence = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: chunk) else { return }
        while remaining > 0 {
            let count = AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))
            silence.frameLength = count
            for channel in 0..<Int(outputFormat.channelCount) {
                silence.floatChannelData?[channel].update(repeating: 0, count: Int(count))
            }
            let before = writtenFrames
            write(silence, to: file)
            guard writtenFrames > before else { break }
            remaining -= AVAudioFramePosition(count)
        }
        timelineFrames = Double(writtenFrames)
    }

    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if input.format == outputFormat { return input }

        if converter == nil || converterInput != input.format {
            if let file { drainConverter(into: file) }
            converter = AVAudioConverter(from: input.format, to: outputFormat)
            converterInput = input.format
        }
        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        let feed = OneShotInput(input)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard let buffer = feed.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }

    /// Flushes the audio the converter still holds, then resets it for the next stretch.
    private func drainConverter(into file: AVAudioFile) {
        guard let converter else { return }
        let capacity: AVAudioFrameCount = 4096
        while let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if output.frameLength > 0 { write(output, to: file) }
            if error != nil || status != .haveData || output.frameLength < capacity { break }
        }
        converter.reset()
        timelineFrames = Double(writtenFrames)
    }

    /// AVAudioConverter only downmixes layouts it understands. Inputs with more than two
    /// channels (another app enabling voice processing reshapes the mic to 3+ channels)
    /// are reduced here: channel 0 is kept, since an unknown layout cannot be averaged safely.
    static func reduceChannels(_ buffer: AVAudioPCMBuffer, to target: AVAudioChannelCount) -> AVAudioPCMBuffer {
        let source = buffer.format
        guard source.channelCount > 2, target <= 2,
              let data = buffer.floatChannelData, !source.isInterleaved,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.sampleRate,
                                       channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength)
        else { return buffer }
        out.frameLength = buffer.frameLength
        out.floatChannelData![0].update(from: data[0], count: Int(buffer.frameLength))
        return out
    }
}

/// Hands one buffer to AVAudioConverter's input block exactly once. The block runs
/// synchronously inside `convert`, so no locking is needed.
private final class OneShotInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

/// Host clock helpers.
public enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static var now: UInt64 { mach_absolute_time() }

    public static func seconds(from start: UInt64, to end: UInt64) -> Double {
        guard end > start else { return 0 }
        let nanos = Double(end - start) * Double(timebase.numer) / Double(timebase.denom)
        return nanos / 1_000_000_000
    }
}

/// Loudness helpers for level meters.
public enum AudioLevel {
    /// RMS of the first channel mapped from -50…0 dBFS onto 0…1.
    public static func normalized(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        if let data = buffer.floatChannelData {
            let samples = data[0]
            let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
            for index in 0..<frames {
                let sample = samples[index * stride]
                sum += sample * sample
            }
        } else if let data = buffer.int16ChannelData {
            let samples = data[0]
            for index in 0..<frames {
                let sample = Float(samples[index]) / Float(Int16.max)
                sum += sample * sample
            }
        } else {
            return 0
        }
        let rms = (sum / Float(frames)).squareRoot()
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return max(0, min(1, (decibels + 50) / 50))
    }
}
