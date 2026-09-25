import AVFoundation
import Foundation

/// Records a microphone and system audio together, each to its own WAV file on one
/// shared timeline. Keeping the tracks separate lets a transcriber tell the local
/// speaker apart from everyone else; ``Recording/mix(to:)`` merges them when needed.
///
/// ```swift
/// let recorder = AudioRecorder()
/// try await recorder.start(.init(microphone: .systemDefault, systemAudio: .everything),
///                          in: FileManager.default.temporaryDirectory)
/// // …
/// let recording = try await recorder.stop()
/// try recording.mix(to: url)
/// ```
public final class AudioRecorder: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public enum Microphone: Sendable, Equatable {
            case systemDefault
            /// A device UID from ``AudioDevices/inputs()``. Falls back to the default when disconnected.
            case device(uid: String)
        }

        /// nil records no microphone.
        public var microphone: Microphone?
        /// nil records no system audio.
        public var systemAudio: SystemAudioSource?
        public var backend: SystemAudioBackend
        public var format: TrackFormat

        public init(microphone: Microphone? = .systemDefault,
                    systemAudio: SystemAudioSource? = .everything,
                    backend: SystemAudioBackend = .processTap,
                    format: TrackFormat = .speech) {
            self.microphone = microphone
            self.systemAudio = systemAudio
            self.backend = backend
            self.format = format
        }
    }

    /// Live loudness, 0…1, per track. Called on audio threads; hop to the main actor for UI.
    public var onLevels: (@Sendable (_ microphone: Float, _ system: Float) -> Void)?

    private let lock = NSLock()
    private var microphone: MicrophoneCapture?
    private var tap: ProcessTapCapture?
    private var screenCapture: ScreenCaptureAudioCapture?
    private var microphoneWriter: AlignedTrackWriter?
    private var systemWriter: AlignedTrackWriter?
    private var startDate: Date?
    private var levels = (microphone: Float(0), system: Float(0))

    public init() {}

    public var isRecording: Bool { lock.withLock { startDate != nil } }

    /// Seconds since ``start(_:in:)``.
    public var elapsed: TimeInterval {
        lock.withLock { startDate.map { Date().timeIntervalSince($0) } ?? 0 }
    }

    /// Starts recording into `directory`, creating `microphone.wav` and/or `system.wav`.
    /// When system audio fails to start (for example permission was refused), the error is
    /// thrown and nothing keeps running.
    public func start(_ configuration: Configuration, in directory: URL) async throws {
        guard !isRecording else { throw SystemAudioError.alreadyRecording }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Sample 0 of every track and `Recording.startDate` refer to this same moment, even
        // when creating the tap takes a while (the first run after an update waits for TCC).
        let startHostTime = HostClock.now
        let startedAt = Date()

        var micWriter: AlignedTrackWriter?
        var sysWriter: AlignedTrackWriter?
        var mic: MicrophoneCapture?
        var tap: ProcessTapCapture?
        var screen: ScreenCaptureAudioCapture?

        do {
            if let source = configuration.systemAudio {
                let writer = try AlignedTrackWriter(url: directory.appendingPathComponent("system.wav"),
                                                    format: configuration.format, startHostTime: startHostTime)
                writer.onLevel = { [weak self] level in self?.update(system: level) }
                sysWriter = writer
                switch configuration.backend {
                case .processTap:
                    let capture = ProcessTapCapture()
                    try capture.start(source: source, writer: writer)
                    tap = capture
                case .screenCaptureKit:
                    let capture = ScreenCaptureAudioCapture()
                    try await capture.start(writer: writer)
                    screen = capture
                }
            }
            if let choice = configuration.microphone {
                if AudioPermissions.microphone == .notDetermined { await AudioPermissions.requestMicrophone() }
                guard AudioPermissions.microphone != .denied else { throw SystemAudioError.microphonePermissionDenied }
                let writer = try AlignedTrackWriter(url: directory.appendingPathComponent("microphone.wav"),
                                                    format: configuration.format, startHostTime: startHostTime)
                writer.onLevel = { [weak self] level in self?.update(microphone: level) }
                micWriter = writer
                let capture = MicrophoneCapture()
                let uid: String? = if case .device(let uid) = choice { uid } else { nil }
                try capture.start(deviceUID: uid, writer: writer)
                mic = capture
            }
        } catch {
            mic?.stop()
            tap?.stop()
            await screen?.stop()
            micWriter?.finish()
            sysWriter?.finish()
            throw error
        }

        lock.withLock {
            microphone = mic
            self.tap = tap
            screenCapture = screen
            microphoneWriter = micWriter
            systemWriter = sysWriter
            startDate = startedAt
        }
    }

    /// Stops recording and returns the finished tracks, padded to the same length.
    public func stop() async -> Recording? {
        let state = lock.withLock { () -> (MicrophoneCapture?, ProcessTapCapture?, ScreenCaptureAudioCapture?,
                                           AlignedTrackWriter?, AlignedTrackWriter?, Date?) in
            defer {
                microphone = nil; tap = nil; screenCapture = nil
                microphoneWriter = nil; systemWriter = nil; startDate = nil
            }
            return (microphone, tap, screenCapture, microphoneWriter, systemWriter, startDate)
        }
        guard let startDate = state.5 else { return nil }
        let stopHostTime = HostClock.now
        state.0?.stop()
        state.1?.stop()
        await state.2?.stop()
        state.3?.finish(at: stopHostTime)
        state.4?.finish(at: stopHostTime)
        return Recording(
            microphoneURL: state.3?.url,
            systemAudioURL: state.4?.url,
            startDate: startDate,
            duration: Date().timeIntervalSince(startDate)
        )
    }

    /// Whether system audio has delivered sound recently. A false value during a call
    /// usually means the permission is missing or audio goes to an unexpected device.
    public func systemAudioPeak() -> Float? {
        lock.withLock { systemWriter }?.takePeak()
    }

    private func update(microphone level: Float) {
        let values = lock.withLock { () -> (Float, Float) in
            levels.microphone = level
            return (levels.microphone, levels.system)
        }
        onLevels?(values.0, values.1)
    }

    private func update(system level: Float) {
        let values = lock.withLock { () -> (Float, Float) in
            levels.system = level
            return (levels.microphone, levels.system)
        }
        // With a microphone present, the microphone drives the callback cadence.
        if lock.withLock({ microphone == nil }) { onLevels?(values.0, values.1) }
    }
}

/// A finished recording: one file per track, all the same length.
public struct Recording: Sendable, Equatable {
    public let microphoneURL: URL?
    public let systemAudioURL: URL?
    public let startDate: Date
    public let duration: TimeInterval

    public init(microphoneURL: URL?, systemAudioURL: URL?, startDate: Date, duration: TimeInterval) {
        self.microphoneURL = microphoneURL
        self.systemAudioURL = systemAudioURL
        self.startDate = startDate
        self.duration = duration
    }

    public var tracks: [URL] { [microphoneURL, systemAudioURL].compactMap { $0 } }

    /// Mixes all tracks into one file. The output format follows the extension:
    /// `.wav` (16-bit PCM) or `.m4a` (AAC).
    public func mix(to url: URL) throws {
        try AudioMixer.mix(tracks, to: url)
    }
}
