import CoreAudio
import Foundation

/// A physical audio device, as reported by Core Audio.
public struct AudioDevice: Identifiable, Hashable, Sendable {
    /// Core Audio's numeric ID. Not stable across reboots or replugs; persist ``uid`` instead.
    public let id: AudioDeviceID
    /// Stable identifier, safe to store in settings.
    public let uid: String
    public let name: String
    public let isDefault: Bool
    public let transport: Transport

    public enum Transport: String, Sendable {
        case builtIn, usb, bluetooth, virtual, aggregate, other
    }
}

/// Lists and resolves audio devices.
public enum AudioDevices {
    /// Physical input devices (microphones). Virtual and aggregate devices are left out,
    /// which also hides the private aggregates ``SystemAudioCapture`` creates.
    public static func inputs() -> [AudioDevice] {
        devices(scope: kAudioObjectPropertyScopeInput, defaultID: defaultInputID)
    }

    /// Physical output devices.
    public static func outputs() -> [AudioDevice] {
        devices(scope: kAudioObjectPropertyScopeOutput, defaultID: defaultOutputID)
    }

    public static var defaultInputID: AudioDeviceID {
        (try? AudioObjectID.system.read(kAudioHardwarePropertyDefaultInputDevice, default: AudioDeviceID(0))) ?? 0
    }

    public static var defaultOutputID: AudioDeviceID {
        (try? AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, default: AudioDeviceID(0))) ?? 0
    }

    /// Finds the device currently carrying a stored UID, or nil if it is not connected.
    public static func input(uid: String) -> AudioDevice? {
        inputs().first { $0.uid == uid }
    }

    static func devices(scope: AudioObjectPropertyScope, defaultID: AudioDeviceID) -> [AudioDevice] {
        let ids = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, element: AudioDeviceID(0))) ?? []
        return ids.compactMap { id in
            guard hasStreams(id, scope: scope),
                  let uid = id.readString(kAudioDevicePropertyDeviceUID),
                  let name = id.readString(kAudioObjectPropertyName) else { return nil }
            let transport = transport(of: id)
            guard transport != .virtual, transport != .aggregate else { return nil }
            return AudioDevice(id: id, uid: uid, name: name, isDefault: id == defaultID, transport: transport)
        }
    }

    static func hasStreams(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    static func transport(of id: AudioDeviceID) -> AudioDevice.Transport {
        let raw = (try? id.read(kAudioDevicePropertyTransportType, default: UInt32(0))) ?? 0
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeVirtual: return .virtual
        case kAudioDeviceTransportTypeAggregate: return .aggregate
        default: return .other
        }
    }
}
