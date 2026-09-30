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
    <main className="mx-auto flex w-full max-w-4xl flex-col px-6">
      <section className="pt-16 pb-12">
        <div className="mb-8 flex flex-wrap items-center gap-3 font-mono text-xs text-fd-muted-foreground">
          {/* biome-ignore lint/performance/noImgElement: static export serves plain files */}
          <img
            src={asset("/logo.svg")}
            alt=""
            width={32}
            height={32}
            className="rounded-md"
          />
          <span>{appName}</span>
          <span aria-hidden="true">/</span>
          <span>Swift package · MIT · macOS 14.2</span>
        </div>
        <h1 className="text-4xl font-bold sm:text-5xl">
          Your mic and the call,{" "}
          <span className="text-sak-accent">in sync.</span>
        </h1>
        <p className="mt-5 max-w-2xl text-lg text-fd-muted-foreground">
          SystemAudioKit records the microphone and what your Mac plays as
          separate WAV files on one timeline. Built for call and meeting
          recorders, with no virtual audio driver to install.
        </p>
        <p className="mt-6 overflow-x-auto rounded-md border bg-fd-card px-4 py-3 font-mono text-sm whitespace-nowrap">
          <span className="select-none text-sak-accent">$ </span>
          <span>swift package add-dependency {repoUrl}.git --from 0.1.0</span>
        </p>
        <CallToAction className="mt-8" />
      </section>

      <Rule />

      <div className="grid gap-10 py-12 [&>div]:min-w-0">
        <div>
          <Label>Package.swift</Label>
          <DynamicCodeBlock lang="swift" code={install} />
          <p className="mt-5 text-sm text-fd-muted-foreground">
            Swift 6. Add NSMicrophoneUsageDescription and
            NSAudioCaptureUsageDescription to your app’s Info.plist.
          </p>
        </div>
        <div>
          <Label>Record a call</Label>
          <DynamicCodeBlock lang="swift" code={example} />
        </div>
      </div>

      <Rule />

      <Section
        eyebrow="What you get"
        title="System audio capture without the driver"
      >
        <dl className="grid gap-x-10 gap-y-8 sm:grid-cols-2">
          {features.map((feature) => (
            <div key={feature.title}>
              <dt className="flex items-center gap-2 font-mono text-sm font-semibold">
                <feature.icon className="size-4 shrink-0 text-sak-accent" />
                {feature.title}
              </dt>
              <dd className="mt-2 text-sm text-fd-muted-foreground">
                {feature.text}
              </dd>
            </div>
          ))}
        </dl>
      </Section>

      <Rule />

      <section className="py-12">
        <h2 className="text-2xl font-bold">Two tracks, one timeline</h2>
        <p className="mt-3 max-w-xl text-fd-muted-foreground">
          Start a recorder, stop it, get microphone.wav and system.wav of the
          same length. The guides cover permissions, app selection and meeting
          detection.
        </p>
        <CallToAction className="mt-8" />
      </section>

      <footer className="border-t py-10 text-sm text-fd-muted-foreground">
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

function Rule() {
  return <hr className="border-fd-border" />;
}

function Label({ children }: { children: ReactNode }) {
  return (
    <p className="mb-2 font-mono text-xs text-fd-muted-foreground">
      <span className="text-sak-accent"># </span>
      {children}
    </p>
  );
}

function CallToAction({ className }: { className?: string }) {
  return (
    <div
      className={`flex flex-wrap gap-3 font-mono text-sm ${className ?? ""}`}
    >
      <Link
        href="/docs"
        className="rounded-md bg-fd-primary px-5 py-2.5 font-medium text-fd-primary-foreground transition hover:opacity-90"
      >
        Read the docs
      </Link>
      <a
        href={repoUrl}
        className="inline-flex items-center gap-2 rounded-md border px-5 py-2.5 font-medium transition hover:bg-fd-accent"
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
    <section className="py-12">
      <p className="font-mono text-xs text-fd-muted-foreground">
        <span className="text-sak-accent">## </span>
        {eyebrow}
      </p>
      <h2 className="mt-2 mb-8 text-2xl font-bold">{title}</h2>
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
