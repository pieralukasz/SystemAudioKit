import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Records one microphone into an ``AlignedTrackWriter``.
public final class MicrophoneCapture: @unchecked Sendable {
    /// About 20 ms at 48 kHz.
    static let TAP_BUFFER_FRAMES: AVAudioFrameCount = 1024

    private var engine: AVAudioEngine?
    private let lock = NSLock()

    public init() {}

    /// Starts capturing. `deviceUID` nil means the system default input.
    public func start(deviceUID: String?, writer: AlignedTrackWriter) throws {
        stop()
        let engine = AVAudioEngine()
        if let deviceUID, let device = AudioDevices.input(uid: deviceUID),
           device.id != AudioDevices.defaultInputID {
            try Self.setInputDevice(device.id, on: engine)
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SystemAudioError.microphoneUnavailable
        }
        input.installTap(onBus: 0, bufferSize: Self.TAP_BUFFER_FRAMES, format: format) { buffer, time in
            writer.append(buffer, hostTime: time.isHostTimeValid ? time.hostTime : nil)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        lock.withLock { self.engine = engine }
    }

    public func stop() {
        let engine = lock.withLock { () -> AVAudioEngine? in
            defer { self.engine = nil }
            return self.engine
        }
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    static func setInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) throws {
        guard let unit = engine.inputNode.audioUnit else { throw SystemAudioError.microphoneUnavailable }
        var id = deviceID
        try check(
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size)),
            "Selecting input device"
        )
    }
}

/// Errors raised by SystemAudioKit.
public enum SystemAudioError: LocalizedError, Sendable {
    case microphoneUnavailable
    case microphonePermissionDenied
    case systemAudioPermissionDenied
    case noMatchingProcesses([String])
    case noDisplay
    case tapFormatUnavailable
    case alreadyRecording

    public var errorDescription: String? {
        switch self {
        case .microphoneUnavailable: return "No microphone is available."
        case .microphonePermissionDenied: return "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone."
        case .systemAudioPermissionDenied: return "System audio recording is off. Turn it on in System Settings → Privacy & Security → Screen & System Audio Recording."
        case .noMatchingProcesses(let ids): return "None of these apps is running with audio: \(ids.joined(separator: ", "))."
        case .noDisplay: return "No display is available for ScreenCaptureKit audio capture."
        case .tapFormatUnavailable: return "Could not read the audio format of the system audio tap."
        case .alreadyRecording: return "A recording is already running."
        }
    }
}
