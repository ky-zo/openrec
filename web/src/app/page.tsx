"use client";

import { Dithering } from "@paper-design/shaders-react";
import { useEffect, useState } from "react";

const REPO = "ky-zo/openrec";
const REPO_URL = `https://github.com/${REPO}`;
const DMG_URL = `${REPO_URL}/releases/latest/download/OpenRec.dmg`;

/* -------------------------------------------------------------------------- */
/*  Icons                                                                      */
/* -------------------------------------------------------------------------- */

function GithubIcon({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="currentColor"
      className={className}
      aria-hidden="true"
    >
      <path d="M12 0C5.37 0 0 5.37 0 12c0 5.31 3.435 9.795 8.205 11.385.6.105.825-.255.825-.57 0-.285-.015-1.23-.015-2.235-3.015.555-3.795-.735-4.035-1.41-.135-.345-.72-1.41-1.23-1.695-.42-.225-1.02-.78-.015-.795.945-.015 1.62.87 1.845 1.23 1.08 1.815 2.805 1.305 3.495.99.105-.78.42-1.305.765-1.605-2.67-.3-5.46-1.335-5.46-5.925 0-1.305.465-2.385 1.23-3.225-.12-.3-.54-1.53.12-3.18 0 0 1.005-.315 3.3 1.23.96-.27 1.98-.405 3-.405s2.04.135 3 .405c2.295-1.56 3.3-1.23 3.3-1.23.66 1.65.24 2.88.12 3.18.765.84 1.23 1.905 1.23 3.225 0 4.605-2.805 5.625-5.475 5.925.435.375.81 1.095.81 2.22 0 1.605-.015 2.895-.015 3.3 0 .315.225.69.825.57A12.02 12.02 0 0 0 24 12c0-6.63-5.37-12-12-12z" />
    </svg>
  );
}

function DownloadIcon({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      aria-hidden="true"
    >
      <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
      <polyline points="7,10 12,15 17,10" />
      <line x1="12" y1="15" x2="12" y2="3" />
    </svg>
  );
}

function StarIcon({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="currentColor"
      className={className}
      aria-hidden="true"
    >
      <path d="M12 .587l3.668 7.568 8.332 1.151-6.064 5.828 1.48 8.279-7.416-3.967-7.417 3.967 1.481-8.279-6.064-5.828 8.332-1.151z" />
    </svg>
  );
}

/* -------------------------------------------------------------------------- */
/*  Hero waveform                                                              */
/* -------------------------------------------------------------------------- */

/**
 * Deterministic pseudo-random so the server and client render identical bars.
 * Math.random() here would cause a hydration mismatch.
 */
function seeded(seed: number) {
  const x = Math.sin(seed * 12.9898) * 43758.5453;
  return x - Math.floor(x);
}

function Waveform() {
  const totalBars = 50;
  const center = totalBars / 2;

  const bars = Array.from({ length: totalBars }).map((_, i) => {
    // Bell curve: taller in the middle, shorter at the edges.
    const distanceFromCenter = Math.abs(i - center) / center;
    const bellCurve = Math.cos(distanceFromCenter * Math.PI * 0.5);
    const baseHeight = 15 + bellCurve * 85;
    const randomVariation = (seeded(i + 1) - 0.5) * 30;
    const height = Math.max(10, Math.min(100, baseHeight + randomVariation));

    // Round to fixed precision: SSR serializes floats differently than the
    // client computes them, which triggers hydration mismatches otherwise.
    return {
      height: Number(height.toFixed(2)),
      delay: Number((seeded(i + 101) * 2).toFixed(3)),
      duration: Number((0.6 + seeded(i + 201)).toFixed(3)),
    };
  });

  return (
    <div className="waveform" aria-hidden="true">
      <div className="waveform-inner">
        {bars.map((bar) => (
          <div
            key={`${bar.height}-${bar.delay}`}
            className="waveform-bar"
            style={{
              height: `${bar.height}%`,
              animationDelay: `${bar.delay}s`,
              animationDuration: `${bar.duration}s`,
            }}
          />
        ))}
      </div>
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/*  Features                                                                   */
/* -------------------------------------------------------------------------- */

const FEATURES = [
  {
    title: "No bot joins your call",
    body: "OpenRec captures the screen and audio on your Mac. Nobody sees a notetaker sitting in the participant list.",
  },
  {
    title: "System audio and your mic",
    body: "Hears what everyone else says and what you say, mixed into a single AAC track at 48 kHz.",
  },
  {
    title: "Nothing sits on your disk",
    body: "Fragmented MP4 streams straight to storage while the call runs. No recordings folder, no full file left behind.",
  },
  {
    title: "Speaker-labelled transcripts",
    body: "AssemblyAI Universal-3.5 Pro with diarization, running on your own API key. Live during the call or after it ends.",
  },
  {
    title: "Meeting memory",
    body: "Participants, a summary, the decisions that were made, and the next steps with owners — extracted for every call.",
  },
  {
    title: "Knows when you're on a call",
    body: "Detects Meet, Zoom, Teams, Slack Huddles, FaceTime, Webex and more, and offers to start recording.",
  },
  {
    title: "Your storage, your keys",
    body: "Use OpenRec Cloud with Google sign-in, or point it at your own Cloudflare R2 bucket. API keys live in the macOS Keychain.",
  },
  {
    title: "Webhooks that carry the meeting",
    body: "A meeting.completed webhook fires with private, expiring media links, so the call lands in your own tooling.",
  },
  {
    title: "Retention you control",
    body: "Decide per call what is kept: video, audio, transcript sync, webhook delivery. Failed uploads stay recoverable.",
  },
];

/* -------------------------------------------------------------------------- */
/*  Page                                                                       */
/* -------------------------------------------------------------------------- */

export default function Page() {
  const [stars, setStars] = useState<number | null>(null);
  const [version, setVersion] = useState<string | null>(null);

  useEffect(() => {
    fetch(`https://api.github.com/repos/${REPO}`)
      .then((res) => res.json())
      .then((data) => {
        if (typeof data?.stargazers_count === "number")
          setStars(data.stargazers_count);
      })
      .catch(() => {});

    fetch(`https://api.github.com/repos/${REPO}/releases/latest`)
      .then((res) => res.json())
      .then((data) => {
        if (typeof data?.tag_name === "string") setVersion(data.tag_name);
      })
      .catch(() => {});
  }, []);

  return (
    <div className="landing-page">
      <div className="shader-background" aria-hidden="true">
        <Dithering
          width={1280}
          height={720}
          colorBack="#301c2a"
          colorFront="#00ff95"
          shape="warp"
          type="4x4"
          size={1}
          speed={0.26}
          scale={0.72}
          rotation={24}
          offsetX={-0.3}
          offsetY={0.36}
          className="shader-canvas"
          style={{ width: "100%", height: "100%" }}
        />
      </div>

      <div className="gradient-orb orb-1" />
      <div className="gradient-orb orb-2" />

      <header className="top-bar">
        <a className="logo" href="#top">
          <span className="red-dot" />
          <span className="logo-text">OpenRec</span>
        </a>
        <nav className="top-nav">
          <a href="#features">Features</a>
          <a href={REPO_URL}>GitHub</a>
        </nav>
      </header>

      <main id="top">
        <section className="hero">
          <p className="eyebrow">Open source · MIT · macOS</p>

          <h1>
            <span className="word word-1">Record</span>{" "}
            <span className="word word-2">your</span>{" "}
            <span className="word word-3">call</span>{" "}
            <span className="word word-4">meetings</span>{" "}
            <span className="word word-5">for free</span>
          </h1>

          <h2>
            OpenRec is a macOS recorder that captures the call, transcribes it,
            and remembers what was decided — without adding a bot to the
            meeting.
          </h2>

          <Waveform />

          <div className="buttons">
            <a className="btn btn-primary" href={DMG_URL}>
              <DownloadIcon className="btn-icon" />
              Download for macOS
            </a>
            <a className="btn btn-outline" href={REPO_URL}>
              <GithubIcon className="btn-icon" />
              GitHub
              {stars !== null && (
                <span className="star-count">
                  <StarIcon className="btn-icon-sm" />
                  {stars}
                </span>
              )}
            </a>
          </div>

          <p className="requirement">
            Requires macOS 15 or later · Signed and notarized by Apple
            {version ? ` · ${version}` : ""}
          </p>
        </section>

        <section className="features" id="features">
          <div className="section-head">
            <h3>Everything it does</h3>
            <p>
              One menu bar app: capture, transcript, and meeting memory, with
              your own keys and your own storage.
            </p>
          </div>

          <div className="feature-grid">
            {FEATURES.map((f) => (
              <article key={f.title} className="feature-card">
                <h4>{f.title}</h4>
                <p>{f.body}</p>
              </article>
            ))}
          </div>
        </section>

        <section className="closer">
          <h3>It's yours to read and change</h3>
          <p>
            The Mac app, the Cloudflare Worker behind OpenRec Cloud, and this
            site are all in one MIT-licensed repository.
          </p>
          <div className="buttons">
            <a className="btn btn-primary" href={DMG_URL}>
              <DownloadIcon className="btn-icon" />
              Download
            </a>
            <a
              className="btn btn-outline"
              href={`${REPO_URL}/blob/main/CONTRIBUTING.md`}
            >
              Read the source
            </a>
          </div>
        </section>
      </main>

      <footer className="footer">
        <a href="/privacy">Privacy</a>
        <span className="dot-sep">·</span>
        <a href={`${REPO_URL}/blob/main/LICENSE`}>MIT License</a>
        <span className="dot-sep">·</span>
        <a href={`${REPO_URL}/blob/main/CONTRIBUTING.md`}>Contribute</a>
        <span className="dot-sep">·</span>
        <a href={`${REPO_URL}/releases`}>Releases</a>
        {version && (
          <>
            <span className="dot-sep">·</span>
            <span>{version}</span>
          </>
        )}
      </footer>

      <svg
        className="noise"
        xmlns="http://www.w3.org/2000/svg"
        aria-hidden="true"
      >
        <filter id="noiseFilter">
          <feTurbulence
            type="fractalNoise"
            baseFrequency="0.8"
            numOctaves={4}
            stitchTiles="stitch"
          />
        </filter>
        <rect width="100%" height="100%" filter="url(#noiseFilter)" />
      </svg>
    </div>
  );
}
