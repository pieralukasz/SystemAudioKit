import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Records the audio of the main display through ScreenCaptureKit into an ``AlignedTrackWriter``.
/// The fallback backend: needs Screen Recording permission and cannot isolate apps,
/// but keeps running regardless of which output device is active.
public final class ScreenCaptureAudioCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SystemAudioKit.ScreenCapture", qos: .userInitiated)
    private var stream: SCStream?
    private var writer: AlignedTrackWriter?

    public override init() {}

    public func start(writer: AlignedTrackWriter, excludingOwnAudio: Bool = true) async throws {
        await stop()
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw SystemAudioError.systemAudioPermissionDenied
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
            ?? content.displays.first else { throw SystemAudioError.noDisplay }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = excludingOwnAudio
        configuration.sampleRate = Int(writer.format.sampleRate)
        configuration.channelCount = Int(writer.format.channels)
        // The video pipeline cannot be switched off; keep it as small and slow as possible.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 1

        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                              configuration: configuration, delegate: nil)
        self.writer = writer
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    public func stop() async {
        if let stream {
            try? await stream.stopCapture()
            await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        }
        stream = nil
        writer = nil
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let writer else { return }
        let pts = sampleBuffer.presentationTimeStamp
        let hostTime: UInt64? = pts.isValid ? CMClockConvertHostTimeToSystemUnits(pts) : nil
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
                  let format = AVAudioFormat(standardFormatWithSampleRate: description.mSampleRate,
                                             channels: description.mChannelsPerFrame),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer)
            else { return }
            writer.append(buffer, hostTime: hostTime)
        }
    }
}
