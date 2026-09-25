import CoreAudio
import Foundation

/// An error from a Core Audio call, carrying the `OSStatus` and what was being attempted.
public struct CoreAudioError: LocalizedError, Sendable, Equatable {
    public let status: OSStatus
    public let operation: String

    public init(_ operation: String, status: OSStatus) {
        self.operation = operation
        self.status = status
    }

    public var errorDescription: String? {
        "\(operation) failed (\(Self.describe(status)))"
    }

    /// Renders a status as its four-character code when it is one, otherwise as a number.
    static func describe(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return "'" + String(decoding: bytes, as: UTF8.self) + "'"
        }
        return String(status)
    }
}

@inline(__always)
func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(operation(), status: status) }
}

func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != .unknown }

    func read<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 default value: T) throws -> T {
        var addr = address(selector, scope: scope)
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &result),
                  "Reading property \(CoreAudioError.describe(OSStatus(bitPattern: selector)))")
        return result
    }

    func readArray<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                      element: T) throws -> [T] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size), "Sizing property list")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var items = [T](repeating: element, count: count)
        try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &items), "Reading property list")
        return Array(items.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    /// Reads a CFString property. These follow the Create Rule, so the value is taken retained.
    func readString(_ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = address(selector, scope: scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &value)
        guard status == noErr, let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }

    func readBool(_ selector: AudioObjectPropertySelector) -> Bool {
        ((try? read(selector, default: UInt32(0))) ?? 0) != 0
    }

    func hasProperty(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var addr = address(selector, scope: scope)
        return AudioObjectHasProperty(self, &addr)
    }
}
