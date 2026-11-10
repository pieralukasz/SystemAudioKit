import Foundation

/// Which track a live chunk belongs to.
public enum LiveAudioTrack: String, Sendable, CaseIterable {
    case microphone
    case system
}

/// Audio exactly as it is written to a track file: output format (16 kHz mono by default),
/// first channel, with silence padding included, so `startFrame` is the sample position in
/// that file. Both tracks of one recording share sample 0.
public struct LiveAudioChunk: Sendable, Equatable {
    public var track: LiveAudioTrack
    public var startFrame: Int64
    public var samples: [Float]
    /// Frames of this track dropped right before this chunk because the consumer fell
    /// behind. The chunk's `startFrame` already skips them; nothing is lost silently.
    public var droppedFramesBefore: Int64

    public init(track: LiveAudioTrack, startFrame: Int64, samples: [Float], droppedFramesBefore: Int64 = 0) {
        self.track = track
        self.startFrame = startFrame
        self.samples = samples
        self.droppedFramesBefore = droppedFramesBefore
    }
}

/// A bounded hand-off from the recording threads to a live consumer (a speech model).
///
/// `push` never blocks on the consumer: it takes a short lock and appends. When more than
/// `capacitySeconds` of audio waits unread, new chunks are dropped and counted; the next
/// delivered chunk carries the drop in `droppedFramesBefore`, and ``droppedFrames`` keeps the
/// totals. The track files are written before the feed sees the audio and never depend on it.
public final class LiveAudioFeed: @unchecked Sendable {
    public let sampleRate: Double
    public let capacityFrames: Int

    private let lock = NSLock()
    private var queue: [LiveAudioChunk] = []
    private var queuedFrames = 0
    private var pendingDrops: [LiveAudioTrack: Int64] = [:]
    private var totalDrops: [LiveAudioTrack: Int64] = [:]
    private var waiter: CheckedContinuation<LiveAudioChunk?, Never>?
    private var closed = false

    public init(sampleRate: Double = 16_000, capacitySeconds: Double = 30) {
        self.sampleRate = sampleRate
        self.capacityFrames = max(1, Int(sampleRate * capacitySeconds))
    }

    /// Frames waiting for the consumer, both tracks together.
    public var backlogFrames: Int { lock.withLock { queuedFrames } }

    /// Frames dropped so far per track because the consumer was too slow.
    public var droppedFrames: [LiveAudioTrack: Int64] { lock.withLock { totalDrops } }

    /// Called by the recorder for every block written to a track.
    public func push(_ track: LiveAudioTrack, startFrame: Int64, samples: [Float]) {
        guard !samples.isEmpty else { return }
        let resume: (CheckedContinuation<LiveAudioChunk?, Never>, LiveAudioChunk)? = lock.withLock {
            guard !closed else { return nil }
            if queuedFrames + samples.count > capacityFrames {
                pendingDrops[track, default: 0] += Int64(samples.count)
                totalDrops[track, default: 0] += Int64(samples.count)
                return nil
            }
            let chunk = LiveAudioChunk(track: track, startFrame: startFrame, samples: samples,
                                       droppedFramesBefore: pendingDrops.removeValue(forKey: track) ?? 0)
            if let waiter {
                self.waiter = nil
                return (waiter, chunk)
            }
            queue.append(chunk)
            queuedFrames += chunk.samples.count
            return nil
        }
        if let (waiter, chunk) = resume { waiter.resume(returning: chunk) }
    }

    /// The next chunk in arrival order, or nil once the feed is finished and drained.
    /// One consumer at a time.
    public func next() async -> LiveAudioChunk? {
        await withCheckedContinuation { continuation in
            let ready: LiveAudioChunk?? = lock.withLock {
                if !queue.isEmpty {
                    let chunk = queue.removeFirst()
                    queuedFrames -= chunk.samples.count
                    return .some(chunk)
                }
                if closed { return .some(nil) }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    /// Ends the feed: chunks already queued are still delivered, then `next()` returns nil.
    public func finish() {
        let waiting = lock.withLock { () -> CheckedContinuation<LiveAudioChunk?, Never>? in
            closed = true
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(returning: nil)
    }
}
