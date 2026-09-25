# SystemAudioKit

Record the microphone and what the Mac plays, as separate tracks on one timeline. Built for call and meeting recorders.

- **System audio through Core Audio process taps** (macOS 14.2+): everything the Mac plays, or only selected apps
  (including their helper processes, which is where browsers play calls). Uses the light "System Audio Recording Only"
  permission, not Screen Recording.
- **ScreenCaptureKit fallback** for setups where a tap cannot be used.
- **Microphone** from the default input or a chosen device.
- **Aligned tracks.** Each track is written against the host clock, and gaps (a silent app, a paused stream) are filled
  with silence, so `microphone.wav` and `system.wav` always line up. That lets a transcriber label everything on the
  microphone as you and diarize only the other side.
- **Meeting detection**: notices when Zoom, Teams, Slack, FaceTime, Discord, Webex, WhatsApp, Signal, Telegram or a
  browser (for Meet and other web calls) starts using the microphone, and when it stops.
- Mixing to a single M4A or WAV, permission checks, device and process listing.

Used by [EchoPad](https://github.com/pieralukasz/echopad).

## Install

```swift
.package(url: "https://github.com/pieralukasz/SystemAudioKit.git", from: "0.1.0")
```

Your app's Info.plist needs `NSMicrophoneUsageDescription` and `NSAudioCaptureUsageDescription`
(plus `NSScreenCaptureUsageDescription` if you use the ScreenCaptureKit backend).

## Use

```swift
import SystemAudioKit

let recorder = AudioRecorder()
recorder.onLevels = { mic, system in /* 0...1, for meters */ }

try await recorder.start(.init(microphone: .systemDefault, systemAudio: .everything), in: folder)
// …
let recording = await recorder.stop()!
print(recording.microphoneURL!, recording.systemAudioURL!, recording.duration)
try recording.mix(to: folder.appendingPathComponent("call.m4a"))
```

Only one app:

```swift
try await recorder.start(.init(systemAudio: .apps(["us.zoom.xos"])), in: folder)
```

Meetings:

```swift
let detector = MeetingDetector()
detector.onChange = { started, ended in
    for meeting in started { print("\(meeting.appName) call started") }
}
detector.start()
```

## Command line

```bash
swift run -c release sysaudio devices
swift run -c release sysaudio processes
swift run -c release sysaudio meetings
swift run -c release sysaudio record 10 ./out            # microphone + everything
swift run -c release sysaudio record 10 ./out --app us.zoom.xos --no-mic
```

The first recording triggers the macOS permission prompt, and the system track is silent until you allow it.

## Notes

- The tap excludes the recording process itself, so your app's own sounds are not recorded.
- The tap is rebuilt when the default output device changes (for example when headphones connect). The gap while it
  rebuilds is filled with silence, so the tracks stay aligned.

## License

MIT
