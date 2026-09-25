import AppKit
import CoreAudio
import Foundation

/// A call app that is using the microphone right now.
public struct DetectedMeeting: Hashable, Sendable {
    /// Bundle ID of the app, for example `us.zoom.xos`.
    public let bundleID: String
    public let appName: String
    /// Core Audio process objects of the app (and its helpers) that are capturing audio.
    public let processIDs: [AudioObjectID]
}

/// Notices when a call app starts or stops using the microphone, which is the most
/// reliable signal that a meeting started. It reads Core Audio's per-process
/// "is running input" flag, so it needs no permission and never touches audio data.
///
/// ```swift
/// let detector = MeetingDetector()
/// detector.onChange = { started, ended in … }
/// detector.start()
/// ```
public final class MeetingDetector: @unchecked Sendable {
    /// Known call apps. Browsers are included because Meet and Teams web run in them;
    /// a browser only counts while it is using the microphone.
    public static let knownApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
        "com.apple.FaceTime": "FaceTime",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.webex.meetingmanager": "Webex",
        "com.google.Chrome": "Google Chrome",
        "com.brave.Browser": "Brave",
        "com.microsoft.edgemac": "Microsoft Edge",
        "company.thebrowser.Browser": "Arc",
        "com.apple.Safari": "Safari",
        "org.mozilla.firefox": "Firefox",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "com.operasoftware.Opera": "Opera",
        "org.whispersystems.signal-desktop": "Signal",
        "ru.keepcoder.Telegram": "Telegram",
    ]

    /// Apps to watch. Defaults to ``knownApps``.
    public var watchedApps: [String: String]
    /// Seconds a meeting must keep the microphone before it is reported, so a quick
    /// voice note or permission check does not trigger anything.
    public var startDelay: TimeInterval
    /// Seconds without microphone use before a meeting counts as ended (mute toggles briefly release it in some apps).
    public var endDelay: TimeInterval

    /// Called on the main queue with meetings that started and ended since the last call.
    public var onChange: (@MainActor (_ started: [DetectedMeeting], _ ended: [DetectedMeeting]) -> Void)?

    public private(set) var active: [DetectedMeeting] = []

    private var timer: Timer?
    private var firstSeen: [String: Date] = [:]
    private var lastSeen: [String: Date] = [:]

    public init(watchedApps: [String: String] = MeetingDetector.knownApps,
                startDelay: TimeInterval = 4, endDelay: TimeInterval = 8) {
        self.watchedApps = watchedApps
        self.startDelay = startDelay
        self.endDelay = endDelay
    }

    /// Polls once per `interval` seconds on the main run loop. Polling is used because
    /// process-list listeners do not fire when an existing process starts using input.
    @MainActor
    public func start(interval: TimeInterval = 2) {
        stop()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    @MainActor
    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Meetings using the microphone at this moment, without any delay.
    public func currentMeetings() -> [DetectedMeeting] {
        var grouped: [String: [AudioObjectID]] = [:]
        for process in AudioProcesses.all() where process.isRunningInput {
            guard let appID = process.appBundleID, watchedApps[appID] != nil else { continue }
            grouped[appID, default: []].append(process.id)
        }
        return grouped.map { id, processes in
            DetectedMeeting(bundleID: id, appName: watchedApps[id] ?? id, processIDs: processes)
        }.sorted { $0.appName < $1.appName }
    }

    @MainActor
    private func poll() {
        let now = Date()
        let current = currentMeetings()
        let currentIDs = Set(current.map(\.bundleID))

        for meeting in current {
            if firstSeen[meeting.bundleID] == nil { firstSeen[meeting.bundleID] = now }
            lastSeen[meeting.bundleID] = now
        }

        let activeIDs = Set(active.map(\.bundleID))
        let started = current.filter { meeting in
            !activeIDs.contains(meeting.bundleID)
                && now.timeIntervalSince(firstSeen[meeting.bundleID] ?? now) >= startDelay
        }
        let ended = active.filter { meeting in
            !currentIDs.contains(meeting.bundleID)
                && now.timeIntervalSince(lastSeen[meeting.bundleID] ?? .distantPast) >= endDelay
        }

        for meeting in ended {
            firstSeen[meeting.bundleID] = nil
            lastSeen[meeting.bundleID] = nil
        }
        // Forget candidates that let go of the microphone before the start delay passed.
        for id in firstSeen.keys where !currentIDs.contains(id) && !activeIDs.contains(id) {
            firstSeen[id] = nil
        }

        guard !started.isEmpty || !ended.isEmpty else { return }
        let endedIDs = Set(ended.map(\.bundleID))
        active = active.filter { !endedIDs.contains($0.bundleID) } + started
        onChange?(started, ended)
    }
}
