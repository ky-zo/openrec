import type { Metadata, Viewport } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

const title = "OpenRec — Record your call meetings for free";
const description =
  "Open source macOS call recorder. Captures screen, system audio, and mic without adding a bot to the meeting, then gives you a transcript, summary, decisions, and next steps.";

export const metadata: Metadata = {
  metadataBase: new URL("https://openrec.co"),
  title,
  description,
  applicationName: "OpenRec",
  keywords: [
    "call recorder",
    "meeting recorder",
    "macOS",
    "open source",
    "transcription",
    "meeting notes",
  ],
  openGraph: {
    title,
    description,
    type: "website",
    siteName: "OpenRec",
  },
  twitter: {
    card: "summary_large_image",
    title,
    description,
  },
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
  themeColor: "#0a0a0a",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body
        className={`${geistSans.variable} ${geistMono.variable} antialiased`}
      >
        {children}
      </body>
    </html>
  );
}
