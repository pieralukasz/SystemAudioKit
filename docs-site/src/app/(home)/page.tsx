import { DynamicCodeBlock } from "fumadocs-ui/components/dynamic-codeblock";
import { AppWindow, AudioLines, Bell, Mic, Monitor, Timer } from "lucide-react";
import Link from "next/link";
import type { ReactNode } from "react";
import { appName, asset, authorUrl, repoUrl } from "@/lib/shared";

const features = [
  {
    icon: AudioLines,
    title: "Process taps, not screen capture",
    text: "Core Audio process taps (macOS 14.2+) record what the Mac plays under the lighter “System Audio Recording Only” permission.",
  },
  {
    icon: AppWindow,
    title: "One app or everything",
    text: "Record the whole system minus your own app, only chosen apps with their helper processes, or everything except a list.",
  },
  {
    icon: Mic,
    title: "Microphone on the same clock",
    text: "The mic goes to its own file. Both tracks are timed against the host clock, so sample N means the same moment in each.",
  },
  {
    icon: Timer,
    title: "Gaps filled with silence",
    text: "Taps go quiet when nothing plays. The writer pads those gaps, so the tracks stay aligned for the whole recording.",
  },
  {
    icon: Bell,
    title: "Meeting detection",
    text: "Notices when Zoom, Teams, Slack, FaceTime, Meet in a browser and others start and stop using the microphone. No permission needed.",
  },
  {
    icon: Monitor,
    title: "ScreenCaptureKit fallback",
    text: "When a tap is not an option, record display audio through ScreenCaptureKit with the same aligned output.",
  },
];

const example = `import SystemAudioKit

let recorder = AudioRecorder()
try await recorder.start(
    .init(microphone: .systemDefault, systemAudio: .everything),
    in: folder
)

// … the call happens …

let recording = await recorder.stop()!
print(recording.microphoneURL!, recording.systemAudioURL!)
try recording.mix(to: folder.appendingPathComponent("call.m4a"))`;

const install = `dependencies: [
    .package(
        url: "https://github.com/pieralukasz/SystemAudioKit.git",
        from: "0.1.0"
    ),
]`;

export default function HomePage() {
  return (
    <main className="flex flex-col">
      <section className="hero-glow">
        <div className="mx-auto flex max-w-5xl flex-col items-center px-6 pt-20 pb-14 text-center">
          {/* biome-ignore lint/performance/noImgElement: static export serves plain files */}
          <img
            src={asset("/logo.svg")}
            alt=""
            width={88}
            height={88}
            className="mb-6 drop-shadow-xl"
          />
          <span className="mb-5 rounded-full border bg-fd-card px-3 py-1 text-xs font-medium text-fd-muted-foreground">
            Swift package · MIT · macOS 14.2
          </span>
          <h1 className="text-5xl font-bold tracking-tight sm:text-6xl">
            Your mic and the call,{" "}
            <span className="text-fd-primary">in sync.</span>
          </h1>
          <p className="mt-5 max-w-2xl text-lg text-fd-muted-foreground">
            SystemAudioKit records the microphone and what your Mac plays as
            separate WAV files on one timeline. Built for call and meeting
            recorders, with no virtual audio driver to install.
          </p>
          <CallToAction className="mt-8 justify-center" />
        </div>
        <div className="mx-auto grid w-full gap-6 px-6 pb-20 text-left max-w-3xl [&>div]:min-w-0">
          <div>
            <p className="mb-2 text-sm font-semibold text-fd-muted-foreground">
              Package.swift
            </p>
            <DynamicCodeBlock lang="swift" code={install} />
            <p className="mt-5 text-sm text-fd-muted-foreground">
              Swift 6. Add NSMicrophoneUsageDescription and
              NSAudioCaptureUsageDescription to your app’s Info.plist.
            </p>
          </div>
          <div>
            <p className="mb-2 text-sm font-semibold text-fd-muted-foreground">
              Record a call
            </p>
            <DynamicCodeBlock lang="swift" code={example} />
          </div>
        </div>
      </section>

      <Section
        eyebrow="What you get"
        title="System audio capture without the driver"
      >
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {features.map((feature) => (
            <div
              key={feature.title}
              className="rounded-2xl border bg-fd-card p-6"
            >
              <feature.icon className="mb-4 size-6 text-fd-primary" />
              <h3 className="font-semibold">{feature.title}</h3>
              <p className="mt-1 text-sm text-fd-muted-foreground">
                {feature.text}
              </p>
            </div>
          ))}
        </div>
      </Section>

      <section className="mx-auto w-full max-w-5xl px-6 pb-24">
        <div className="hero-glow rounded-3xl border bg-fd-card px-8 py-14 text-center">
          <h2 className="text-3xl font-bold tracking-tight">
            Two tracks, one timeline
          </h2>
          <p className="mx-auto mt-3 max-w-xl text-fd-muted-foreground">
            Start a recorder, stop it, get microphone.wav and system.wav of the
            same length. The guides cover permissions, app selection and meeting
            detection.
          </p>
          <CallToAction className="mt-8 justify-center" />
        </div>
      </section>

      <footer className="border-t py-10 text-center text-sm text-fd-muted-foreground">
        <p>
          {appName} is MIT licensed. Made by{" "}
          <a
            className="font-medium text-fd-foreground underline underline-offset-4"
            href={authorUrl}
          >
            Lucas Piera
          </a>
          .
        </p>
        <p className="mt-2">
          Uses Core Audio process taps and ScreenCaptureKit. No kernel
          extension, no virtual device.
        </p>
      </footer>
    </main>
  );
}

function CallToAction({ className }: { className?: string }) {
  return (
    <div className={`flex flex-wrap gap-3 ${className ?? ""}`}>
      <Link
        href="/docs"
        className="rounded-full bg-fd-primary px-6 py-3 font-medium text-fd-primary-foreground transition hover:opacity-90"
      >
        Read the docs
      </Link>
      <a
        href={repoUrl}
        className="inline-flex items-center gap-2 rounded-full border bg-fd-card px-6 py-3 font-medium transition hover:bg-fd-accent"
      >
        <GitHubMark /> View on GitHub
      </a>
    </div>
  );
}

function Section({
  eyebrow,
  title,
  children,
}: {
  eyebrow: string;
  title: string;
  children: ReactNode;
}) {
  return (
    <section className="mx-auto w-full max-w-5xl px-6 py-16">
      <p className="text-sm font-semibold uppercase tracking-wider text-fd-primary">
        {eyebrow}
      </p>
      <h2 className="mt-2 mb-8 text-3xl font-bold tracking-tight">{title}</h2>
      {children}
    </section>
  );
}

function GitHubMark() {
  return (
    <svg
      viewBox="0 0 16 16"
      className="size-4"
      fill="currentColor"
      aria-hidden="true"
    >
      <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z" />
    </svg>
  );
}
