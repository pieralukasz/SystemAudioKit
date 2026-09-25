import AVFoundation
import CoreGraphics
import Foundation

/// Permission checks for microphone and system audio.
public enum AudioPermissions {
    public enum Status: String, Sendable {
        case authorized, denied, notDetermined, unknown
    }

    // MARK: Microphone

    public static var microphone: Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .unknown
        }
    }

    @discardableResult
    public static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: System audio (process taps)

    /// Whether this app may record system audio through a process tap.
    ///
    /// There is no public API for this. The check uses the private TCC framework
    /// (`TCCAccessPreflight` for `kTCCServiceAudioCapture`), which is fine for
    /// Developer ID and locally built apps but not for the Mac App Store.
    /// Returns `.unknown` when the private symbols are unavailable; in that case
    /// just start capturing and let macOS show its prompt.
    public static var systemAudio: Status {
        guard let preflight = TCC.preflight else { return .unknown }
        switch preflight(TCC.audioCapture, nil) {
        case 0: return .authorized
        case 1: return .denied
        case 2: return .notDetermined
        default: return .unknown
        }
    }

    /// Shows the macOS prompt for system audio recording, if it has not been answered yet.
    @discardableResult
    public static func requestSystemAudio() async -> Bool {
        guard let request = TCC.request else { return false }
        return await withCheckedContinuation { continuation in
            request(TCC.audioCapture, nil) { granted in continuation.resume(returning: granted) }
        }
    }

    // MARK: Screen Recording (ScreenCaptureKit backend)

    public static var screenRecording: Status {
        CGPreflightScreenCaptureAccess() ? .authorized : .denied
    }

    // MARK: Settings

    public enum Pane: String, Sendable {
        case microphone = "Privacy_Microphone"
        case systemAudio = "Privacy_AudioCapture"
        case screenRecording = "Privacy_ScreenCapture"
    }

    public static func settingsURL(for pane: Pane) -> URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
    }
}

private enum TCC {
    typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @Sendable (Bool) -> Void) -> Void

    static var audioCapture: CFString { "kTCCServiceAudioCapture" as CFString }

    nonisolated(unsafe) static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static let preflight: Preflight? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: Preflight.self)
    }()

    static let request: Request? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(symbol, to: Request.self)
    }()
}
