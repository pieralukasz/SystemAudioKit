import Foundation
import SystemAudioKit

/// A small command line front end, mostly for trying the package out and for QA.
///
///     sysaudio devices
///     sysaudio processes
///     sysaudio meetings
///     sysaudio record <seconds> <directory> [--no-mic] [--no-system] [--app <bundle id>] [--screencapture]
///     sysaudio mix <out.wav|out.m4a> <track.wav>...
@main
struct SysAudio {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { return usage() }
        args.removeFirst()

        do {
            switch command {
            case "devices": devices()
            case "processes": processes()
            case "meetings": meetings()
            case "permissions": permissions()
            case "record": try await record(args)
            case "mix":
                guard args.count >= 2 else { return usage() }
                try AudioMixer.mix(args.dropFirst().map { URL(fileURLWithPath: $0) },
                                   to: URL(fileURLWithPath: args[0]))
                print("Mixed into \(args[0])")
            default: usage()
            }
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func usage() {
        print("""
        usage: sysaudio devices | processes | meetings | permissions
               sysaudio record <seconds> <directory> [--no-mic] [--no-system] [--app <bundle id>]... [--screencapture]
               sysaudio mix <out.wav|out.m4a> <track.wav>...
        """)
    }

    static func devices() {
        print("Inputs:")
        for device in AudioDevices.inputs() {
            print("  \(device.isDefault ? "*" : " ") \(device.name)  [\(device.transport.rawValue)]  \(device.uid)")
        }
        print("Outputs:")
        for device in AudioDevices.outputs() {
            print("  \(device.isDefault ? "*" : " ") \(device.name)  [\(device.transport.rawValue)]  \(device.uid)")
        }
    }

    static func processes() {
        for process in AudioProcesses.all().sorted(by: { $0.name < $1.name }) {
            let flags = (process.isRunningInput ? "in " : "   ") + (process.isRunningOutput ? "out" : "   ")
            print("\(flags)  \(process.pid)\t\(process.name)\t\(process.bundleID ?? "-") → \(process.appBundleID ?? "-")")
        }
    }

    static func meetings() {
        let current = MeetingDetector().currentMeetings()
        if current.isEmpty { print("No call app is using the microphone.") }
        for meeting in current { print("\(meeting.appName) (\(meeting.bundleID))") }
    }

    static func permissions() {
        print("Microphone:      \(AudioPermissions.microphone.rawValue)")
        print("System audio:    \(AudioPermissions.systemAudio.rawValue)")
        print("Screen Recording: \(AudioPermissions.screenRecording.rawValue)")
    }

    static func record(_ args: [String]) async throws {
        guard args.count >= 2, let seconds = Double(args[0]) else { return usage() }
        let directory = URL(fileURLWithPath: args[1])
        var configuration = AudioRecorder.Configuration()
        var apps: [String] = []
        var index = 2
        while index < args.count {
            switch args[index] {
            case "--no-mic": configuration.microphone = nil
            case "--no-system": configuration.systemAudio = nil
            case "--screencapture": configuration.backend = .screenCaptureKit
            case "--app":
                index += 1
                if index < args.count { apps.append(args[index]) }
            default: break
            }
            index += 1
        }
        if !apps.isEmpty, configuration.systemAudio != nil { configuration.systemAudio = .apps(apps) }

        let recorder = AudioRecorder()
        let meter = LevelMeter()
        recorder.onLevels = { mic, system in meter.update(mic: mic, system: system) }
        try await recorder.start(configuration, in: directory)
        print("Recording \(seconds)s into \(directory.path)…")
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(250))
            meter.render()
        }
        print("")
        guard let recording = await recorder.stop() else { return }
        for track in recording.tracks {
            let file = try? AVAudioFileInfo(url: track)
            print("  \(track.lastPathComponent): \(file.map { String(format: "%.2fs, peak %.3f", $0.duration, $0.peak) } ?? "?")")
        }
        if recording.tracks.count > 1 {
            let mixed = directory.appendingPathComponent("mixed.m4a")
            try recording.mix(to: mixed)
            print("  mixed.m4a written")
        }
    }
}

final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var mic: Float = 0
    private var system: Float = 0

    func update(mic: Float, system: Float) {
        lock.withLock {
            self.mic = max(self.mic, mic)
            self.system = max(self.system, system)
        }
    }

    func render() {
        let (mic, system) = lock.withLock { () -> (Float, Float) in
            defer { self.mic = 0; self.system = 0 }
            return (self.mic, self.system)
        }
        func bar(_ value: Float) -> String {
            let filled = Int(value * 20)
            return String(repeating: "█", count: filled) + String(repeating: "·", count: 20 - filled)
        }
        print("\rmic \(bar(mic))  system \(bar(system))", terminator: "")
        fflush(stdout)
    }
}

import AVFoundation

struct AVAudioFileInfo {
    let duration: Double
    let peak: Float

    init(url: URL) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        duration = Double(file.length) / file.processingFormat.sampleRate
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384)!
        var peak: Float = 0
        while file.framePosition < file.length {
            try file.read(into: buffer)
            let samples = buffer.floatChannelData![0]
            for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[index])) }
        }
        self.peak = peak
    }
}
