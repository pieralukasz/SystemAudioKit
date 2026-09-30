import type { Metadata } from "next";
import { Geist, JetBrains_Mono } from "next/font/google";
import { Provider } from "@/components/provider";
import { appName, tagline } from "@/lib/shared";
import "./global.css";

const sans = Geist({
  subsets: ["latin", "latin-ext"],
  variable: "--font-geist",
});

const mono = JetBrains_Mono({
  subsets: ["latin", "latin-ext"],
  variable: "--font-jetbrains-mono",
});

/** DOCS_SITE_URL wins; on Vercel the production domain is set automatically. */
function siteUrl() {
  if (process.env.DOCS_SITE_URL) return process.env.DOCS_SITE_URL;
  const vercelHost = process.env.VERCEL_PROJECT_PRODUCTION_URL;
  return vercelHost ? `https://${vercelHost}` : "http://localhost:3000";
}

export const metadata: Metadata = {
  metadataBase: new URL(siteUrl()),
  title: {
    default: `${appName}: ${tagline}`,
    template: `%s · ${appName}`,
  },
  description:
    "SystemAudioKit is a Swift package that records the microphone and what the Mac plays as aligned tracks, through Core Audio process taps with a ScreenCaptureKit fallback. Built for call recorders. MIT licensed.",
};

export default function Layout({ children }: LayoutProps<"/">) {
  return (
    <html
      lang="en"
      className={`${sans.variable} ${mono.variable}`}
      suppressHydrationWarning
    >
      <body className="flex flex-col min-h-screen">
        <Provider>{children}</Provider>
      </body>
    </html>
  );
}
