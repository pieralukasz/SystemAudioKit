import AVFoundation
import XCTest
@testable import SystemAudioKit

final class LiveAudioFeedTests: XCTestCase {
    func testWriterForwardsWrittenAudioWithFilePositionsIncludingPaddedSilence() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let start = HostClock.now
        let writer = try AlignedTrackWriter(url: url, format: .speech, startHostTime: start)
        let feed = LiveAudioFeed(capacitySeconds: 10)
        writer.onSamples = { feed.push(.microphone, startFrame: $0, samples: $1) }

        let format = TrackFormat.speech.processingFormat
        func buffer(_ frames: Int, value: Float) -> AVAudioPCMBuffer {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            buffer.floatChannelData![0].update(repeating: value, count: frames)
            return buffer
        }
        // 0.5 s of audio, then a buffer that belongs 1 s later than the first one ended.
        writer.append(buffer(8_000, value: 0.5), hostTime: nil)
        let oneAndHalfSeconds = UInt64(1.5 * 1_000_000_000 * Double(Self.ticksPerNano))
        writer.append(buffer(1_600, value: 0.25), hostTime: start + oneAndHalfSeconds)
        writer.finish()
        feed.finish()

        var chunks: [LiveAudioChunk] = []
        while let chunk = await feed.next() { chunks.append(chunk) }
        var position: Int64 = 0
        for chunk in chunks {
            XCTAssertEqual(chunk.startFrame, position, "chunks are contiguous file positions")
            position += Int64(chunk.samples.count)
        }
        XCTAssertEqual(position, 24_000 + 1_600, "audio, padded silence up to 1.5 s, then the late buffer")
        XCTAssertEqual(chunks.last?.samples.first, 0.25)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, position, "the file and the feed agree")
    }

    func testFullFeedDropsNewAudioAndReportsItInsteadOfBlockingTheRecorder() async {
        let feed = LiveAudioFeed(sampleRate: 100, capacitySeconds: 1) // 100 frames
        feed.push(.system, startFrame: 0, samples: [Float](repeating: 0, count: 80))
        feed.push(.system, startFrame: 80, samples: [Float](repeating: 0, count: 40)) // over capacity: dropped
        feed.push(.microphone, startFrame: 0, samples: [Float](repeating: 0, count: 20))
        XCTAssertEqual(feed.droppedFrames[.system], 40)

        let first = await feed.next()
        XCTAssertEqual(first?.startFrame, 0)
        _ = await feed.next() // microphone
        feed.push(.system, startFrame: 120, samples: [Float](repeating: 1, count: 10))
        let resumed = await feed.next()
        XCTAssertEqual(resumed?.startFrame, 120)
        XCTAssertEqual(resumed?.droppedFramesBefore, 40, "the consumer learns about the dropped stretch")
        feed.finish()
        let end = await feed.next()
        XCTAssertNil(end)
    }

    func testWaitingConsumerIsWokenByPushAndByFinish() async {
        let feed = LiveAudioFeed(capacitySeconds: 1)
        async let first = feed.next()
        try? await Task.sleep(for: .milliseconds(20))
        feed.push(.microphone, startFrame: 0, samples: [1, 2, 3])
        let chunk = await first
        XCTAssertEqual(chunk?.samples, [1, 2, 3])
        async let last = feed.next()
        try? await Task.sleep(for: .milliseconds(20))
        feed.finish()
        let end = await last
        XCTAssertNil(end)
    }

    private static let ticksPerNano: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.denom) / Double(info.numer)
    }()
}
