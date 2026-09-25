import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// What system audio to record.
public enum SystemAudioSource: Sendable, Equatable {
    /// Everything this Mac plays, except this app's own sound.
    case everything
    /// Only these apps (bundle IDs), including their helper processes.
    /// Browsers play call audio from helpers, which this follows.
    case apps([String])
    /// Everything except these apps.
    case everythingExcept([String])
}

/// How system audio is captured.
public enum SystemAudioBackend: String, Sendable, CaseIterable {
    /// Core Audio process tap (macOS 14.2+). Can isolate single apps and asks for the
    /// lighter "System Audio Recording Only" permission. Default.
    case processTap
    /// ScreenCaptureKit display audio. Needs Screen Recording permission and records
    /// only `.everything`, but its clock does not depend on any output device.
    case screenCaptureKit
}

/// Records system audio through a Core Audio process tap into an ``AlignedTrackWriter``.
///
/// The tap feeds a private, tap-only aggregate device (no physical subdevice), which keeps
/// it running when the output switches, for example to AirPods in a call at 24 kHz. When the
/// default output device changes, the tap is rebuilt; the writer's host-time timeline keeps
/// the track continuous across the rebuild.
public final class ProcessTapCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SystemAudioKit.ProcessTap", qos: .userInitiated)
    private let lock = NSLock()
    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var procID: AudioDeviceIOProcID?
    private var source: SystemAudioSource = .everything
    private var writer: AlignedTrackWriter?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var lastBufferHostTime: UInt64 = 0

    public init() {}

    /// Host time of the last buffer the tap delivered, 0 before the first one.
    public var lastBuffer: UInt64 { lock.withLock { lastBufferHostTime } }

    public func start(source: SystemAudioSource, writer: AlignedTrackWriter) throws {
        stop()
        lock.withLock {
            self.source = source
            self.writer = writer
        }
        try build()
        listenForOutputChanges()
    }

    public func stop() {
        removeOutputListener()
        teardown()
        lock.withLock { writer = nil }
    }

    // MARK: - Tap lifecycle

    private func build() throws {
        let (source, writer) = lock.withLock { (self.source, self.writer) }
        guard let writer else { return }

        let description = try Self.tapDescription(for: source)
        var newTap = AudioObjectID.unknown
        try check(AudioHardwareCreateProcessTap(description, &newTap), "Creating the process tap")

        do {
            var format = try newTap.read(kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
            guard let tapFormat = AVAudioFormat(streamDescription: &format) else {
                throw SystemAudioError.tapFormatUnavailable
            }

            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "SystemAudioKit Tap",
                kAudioAggregateDeviceUIDKey: "SystemAudioKit-\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
            var newAggregate = AudioObjectID.unknown
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregate),
                      "Creating the aggregate device")

            var newProc: AudioDeviceIOProcID?
            let status = AudioDeviceCreateIOProcIDWithBlock(&newProc, newAggregate, queue) {
                [weak self] _, input, inputTime, _, _ in
                guard let self,
                      let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: input, deallocator: nil)
                else { return }
                let time = inputTime.pointee
                let hostTime = time.mFlags.contains(.hostTimeValid) ? time.mHostTime : nil
                writer.append(buffer, hostTime: hostTime)
                self.lock.withLock { self.lastBufferHostTime = hostTime ?? HostClock.now }
            }
            guard status == noErr, let newProc else {
                AudioHardwareDestroyAggregateDevice(newAggregate)
                throw CoreAudioError("Creating the IO proc", status: status)
            }
            let startStatus = AudioDeviceStart(newAggregate, newProc)
            guard startStatus == noErr else {
                AudioDeviceDestroyIOProcID(newAggregate, newProc)
                AudioHardwareDestroyAggregateDevice(newAggregate)
                throw CoreAudioError("Starting the aggregate device", status: startStatus)
            }
            lock.withLock {
                tapID = newTap
                aggregateID = newAggregate
                procID = newProc
            }
        } catch {
            AudioHardwareDestroyProcessTap(newTap)
            throw error
        }
    }

    private func teardown() {
        let (tap, aggregate, proc) = lock.withLock { () -> (AudioObjectID, AudioObjectID, AudioDeviceIOProcID?) in
            defer {
                tapID = .unknown
                aggregateID = .unknown
                procID = nil
            }
            return (tapID, aggregateID, procID)
        }
        if aggregate.isValid {
            AudioDeviceStop(aggregate, proc)
            if let proc { AudioDeviceDestroyIOProcID(aggregate, proc) }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap.isValid { AudioHardwareDestroyProcessTap(tap) }
        // Let any IO block already queued finish before the caller closes the writer.
        queue.sync {}
    }

    static func tapDescription(for source: SystemAudioSource) throws -> CATapDescription {
        let description: CATapDescription
        switch source {
        case .everything:
            let own = AudioProcesses.objectID(for: ProcessInfo.processInfo.processIdentifier)
            description = CATapDescription(monoGlobalTapButExcludeProcesses: own.map { [$0] } ?? [])
        case .apps(let bundleIDs):
            let ids = bundleIDs.flatMap(AudioProcesses.objectIDs(forApp:))
            guard !ids.isEmpty else { throw SystemAudioError.noMatchingProcesses(bundleIDs) }
            description = CATapDescription(monoMixdownOfProcesses: ids)
        case .everythingExcept(let bundleIDs):
            var ids = bundleIDs.flatMap(AudioProcesses.objectIDs(forApp:))
            if let own = AudioProcesses.objectID(for: ProcessInfo.processInfo.processIdentifier) { ids.append(own) }
            description = CATapDescription(monoGlobalTapButExcludeProcesses: ids)
        }
        description.uuid = UUID()
        description.name = "SystemAudioKit"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        return description
    }

    // MARK: - Output device changes

    private func listenForOutputChanges() {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // Rebuild off the listener's queue; never set properties from inside a listener.
            DispatchQueue.global(qos: .userInitiated).async {
                guard self.lock.withLock({ self.writer != nil }) else { return }
                self.teardown()
                try? self.build()
            }
        }
        if AudioObjectAddPropertyListenerBlock(.system, &addr, DispatchQueue.global(qos: .utility), block) == noErr {
            lock.withLock { outputListener = block }
        }
    }

    private func removeOutputListener() {
        guard let block = lock.withLock({ () -> AudioObjectPropertyListenerBlock? in
            defer { outputListener = nil }
            return outputListener
        }) else { return }
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(.system, &addr, DispatchQueue.global(qos: .utility), block)
    }
}
