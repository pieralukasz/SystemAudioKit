import AVFoundation
import XCTest
@testable import SystemAudioKit

final class AlignedTrackWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func tone(seconds: Double, sampleRate: Double = 48_000, channels: AVAudioChannelCount = 2) -> AVAudioPCMBuffer {
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
        let format = channels <= 2
            ? AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
            : AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for index in 0..<Int(frames) {
                buffer.floatChannelData![channel][index] = 0.5 * sin(Float(index) * 2 * .pi * 440 / Float(sampleRate))
            }
        }
        return buffer
    }

    private func hostTime(after start: UInt64, seconds: Double) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanos = seconds * 1_000_000_000
        return start + UInt64(nanos * Double(info.denom) / Double(info.numer))
    }

    private func length(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    func testConvertsToSixteenKilohertzMono() throws {
        let url = directory.appendingPathComponent("a.wav")
        let start = HostClock.now
        let writer = try AlignedTrackWriter(url: url, startHostTime: start)
        writer.append(tone(seconds: 1), hostTime: start)
        writer.finish()

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(try length(of: url), 1, accuracy: 0.02)
    }

    func testFillsGapsWithSilence() throws {
        let url = directory.appendingPathComponent("gap.wav")
        let start = HostClock.now
        let writer = try AlignedTrackWriter(url: url, startHostTime: start)
        writer.append(tone(seconds: 0.5), hostTime: start)
        // Next buffer arrives 3 s after start: 2.5 s of nothing in between.
        writer.append(tone(seconds: 0.5), hostTime: hostTime(after: start, seconds: 3))
        writer.finish()
        XCTAssertEqual(try length(of: url), 3.5, accuracy: 0.03)
    }

    func testIgnoresSmallJitter() throws {
        let url = directory.appendingPathComponent("jitter.wav")
        let start = HostClock.now
        let writer = try AlignedTrackWriter(url: url, startHostTime: start)
        writer.append(tone(seconds: 0.5), hostTime: start)
        writer.append(tone(seconds: 0.5), hostTime: hostTime(after: start, seconds: 0.53))
        writer.finish()
        XCTAssertEqual(try length(of: url), 1.0, accuracy: 0.02)
    }

    func testFinishPadsToStopTime() throws {
        let url = directory.appendingPathComponent("pad.wav")
        let start = HostClock.now
        let writer = try AlignedTrackWriter(url: url, startHostTime: start)
        writer.append(tone(seconds: 1), hostTime: start)
        writer.finish(at: hostTime(after: start, seconds: 5))
        XCTAssertEqual(try length(of: url), 5, accuracy: 0.02)
    }

    func testReducesManyChannelsToFirst() throws {
        let buffer = tone(seconds: 0.1, channels: 4)
        let reduced = AlignedTrackWriter.reduceChannels(buffer, to: 1)
        XCTAssertEqual(reduced.format.channelCount, 1)
        XCTAssertEqual(reduced.frameLength, buffer.frameLength)
    }

    func testMixAlignsAndKeepsLength() throws {
        let start = HostClock.now
        let a = try AlignedTrackWriter(url: directory.appendingPathComponent("mic.wav"), startHostTime: start)
        let b = try AlignedTrackWriter(url: directory.appendingPathComponent("sys.wav"), startHostTime: start)
        let stop = hostTime(after: start, seconds: 2)
        a.append(tone(seconds: 1), hostTime: start)
        b.append(tone(seconds: 0.5), hostTime: hostTime(after: start, seconds: 1.2))
        a.finish(at: stop)
        b.finish(at: stop)

        for ext in ["wav", "m4a"] {
            let out = directory.appendingPathComponent("mixed.\(ext)")
            try AudioMixer.mix([a.url, b.url], to: out)
            XCTAssertEqual(try length(of: out), 2, accuracy: 0.1, ext)
        }
    }

    func testMixRejectsUnknownExtension() {
        XCTAssertThrowsError(try AudioMixer.mix([directory.appendingPathComponent("x.wav")],
                                                to: directory.appendingPathComponent("x.ogg")))
    }

    func testLevelOfSilenceIsZero() {
        let buffer = tone(seconds: 0.1)
        for channel in 0..<2 { buffer.floatChannelData![channel].update(repeating: 0, count: Int(buffer.frameLength)) }
        XCTAssertEqual(AudioLevel.normalized(buffer), 0)
        XCTAssertGreaterThan(AudioLevel.normalized(tone(seconds: 0.1)), 0.8)
    }
}

final class ProcessTests: XCTestCase {
    func testParentBundleID() {
        XCTAssertEqual(AudioProcess.parentBundleID(of: "com.google.Chrome.helper.renderer"), "com.google.Chrome")
        XCTAssertEqual(AudioProcess.parentBundleID(of: "com.apple.WebKit.WebContent"), "com.apple.WebKit")
        XCTAssertEqual(AudioProcess.parentBundleID(of: "us.zoom.xos"), "us.zoom.xos")
    }

    func testStatusDescription() {
        XCTAssertEqual(CoreAudioError.describe(OSStatus(bitPattern: 0x77686F3F)), "'who?'")
        XCTAssertEqual(CoreAudioError.describe(-50), "-50")
    }

    func testListingDoesNotCrash() {
        _ = AudioDevices.inputs()
        _ = AudioDevices.outputs()
        _ = AudioProcesses.all()
        _ = MeetingDetector().currentMeetings()
    }
}
