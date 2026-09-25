import AppKit
import CoreAudio
import Foundation

/// A process Core Audio knows about: anything that has opened an audio device.
public struct AudioProcess: Identifiable, Hashable, Sendable {
    /// Core Audio's process object. Pass it to ``SystemAudioSource/apps(_:)`` to tap this process.
    public let id: AudioObjectID
    public let pid: pid_t
    /// Bundle ID of the process. Helper processes report their own ID
    /// (for example `com.google.Chrome.helper`), see ``appBundleID``.
    public let bundleID: String?
    /// Whether the process is capturing audio right now (for example a call using the microphone).
    public let isRunningInput: Bool
    /// Whether the process is playing audio right now.
    public let isRunningOutput: Bool

    /// Bundle ID of the app that owns the process, following helpers back to their parent app.
    public var appBundleID: String? {
        if let app = NSRunningApplication(processIdentifier: pid), let id = app.bundleIdentifier,
           app.activationPolicy == .regular {
            return id
        }
        return bundleID.map(Self.parentBundleID(of:))
    }

    /// A human readable name: the owning app's name when there is one.
    public var name: String {
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
            return name
        }
        if let appID = appBundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID ?? "Process \(pid)"
    }

    /// `com.google.Chrome.helper.renderer` → `com.google.Chrome`.
    static func parentBundleID(of bundleID: String) -> String {
        let markers = [".helper", ".Helper", ".WebContent", ".GPU", ".Networking", ".renderer"]
        for marker in markers {
            if let range = bundleID.range(of: marker) {
                return String(bundleID[..<range.lowerBound])
            }
        }
        return bundleID
    }
}

/// Lists the processes Core Audio tracks.
public enum AudioProcesses {
    /// Every process with an audio connection, excluding this one.
    public static func all() -> [AudioProcess] {
        let ids = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList,
                                                       element: AudioObjectID(0))) ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return ids.compactMap { id in
            guard let pid = try? id.read(kAudioProcessPropertyPID, default: pid_t(-1)), pid > 0,
                  pid != ownPID else { return nil }
            return AudioProcess(
                id: id,
                pid: pid,
                bundleID: id.readString(kAudioProcessPropertyBundleID),
                isRunningInput: id.readBool(kAudioProcessPropertyIsRunningInput),
                isRunningOutput: id.readBool(kAudioProcessPropertyIsRunningOutput)
            )
        }
    }

    /// Processes that are playing audio right now, grouped per app.
    public static func playing() -> [AudioProcess] {
        all().filter(\.isRunningOutput)
    }

    /// Core Audio's process object for a PID, if the process has an audio connection.
    public static func objectID(for pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var objectID = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            .system, &addr, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &objectID
        )
        guard status == noErr, objectID.isValid else { return nil }
        return objectID
    }

    /// Process objects belonging to an app, including its helpers (browsers play audio from helpers).
    public static func objectIDs(forApp bundleID: String) -> [AudioObjectID] {
        all().filter { $0.bundleID == bundleID || $0.appBundleID == bundleID }.map(\.id)
    }
}
