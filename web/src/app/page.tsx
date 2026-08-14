"use client";

import { MeshGradient } from "@paper-design/shaders-react";
import { useEffect, useState } from "react";

const REPO = "ky-zo/openrec";
const REPO_URL = `https://github.com/${REPO}`;
const DMG_URL = "https://api.amore.computer/v1/apps/app.openrec.mac/download";

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

function CheckIcon({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="currentColor"
      className={className}
      aria-hidden="true"
    >
      <path d="M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm-1.2 14.5-4-4 1.4-1.4 2.6 2.6 5.6-5.6L17.8 9.5l-7 7z" />
    </svg>
  );
}

function SearchIcon({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.2"
      strokeLinecap="round"
      className={className}
      aria-hidden="true"
    >
      <circle cx="11" cy="11" r="7" />
      <line x1="16.5" y1="16.5" x2="21" y2="21" />
    </svg>
  );
}

function MicIcon({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      className={className}
      aria-hidden="true"
    >
      <rect x="9" y="2" width="6" height="12" rx="3" />
      <path d="M5 11a7 7 0 0 0 14 0" />
      <line x1="12" y1="18" x2="12" y2="22" />
    </svg>
  );
}

function ChevronUpDownIcon({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.4"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      aria-hidden="true"
    >
      <polyline points="8,9 12,5 16,9" />
      <polyline points="8,15 12,19 16,15" />
    </svg>
  );
}

function CopyIcon({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinejoin="round"
      className={className}
      aria-hidden="true"
    >
      <rect x="9" y="9" width="12" height="12" rx="2.5" />
      <path d="M5 15H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v1" />
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
/*  App mockup                                                                 */
/* -------------------------------------------------------------------------- */

const MEETINGS = [
  {
    title: "Acme — pricing review",
    meta: "Today, 14:20 · 42:18 · Google Meet",
    active: true,
  },
  { title: "Design sync", meta: "Today, 10:05 · 28:44 · Zoom" },
  { title: "Onboarding call — Northwind", meta: "Yesterday · 51:02 · Teams" },
  { title: "Weekly standup", meta: "Yesterday · 14:37 · Slack Huddle" },
  { title: "Investor update", meta: "Mon · 33:51 · Zoom" },
];

const NEXT_STEPS = [
  {
    task: "Send the revised pricing sheet with the volume tier",
    meta: "Kamil · Thursday",
  },
  {
    task: "Set up a shared R2 bucket for their recordings",
    meta: "Kamil · this week",
  },
  { task: "Confirm the security review timeline with legal", meta: "Dana" },
];

const DECISIONS = [
  "Move to annual billing starting next quarter",
  "Keep the pilot scoped to the support team for now",
];

function AppMockup() {
  const levels = [0.35, 0.62, 0.88, 0.71, 0.94, 0.66, 0.83, 0.48, 0.29];

  return (
    <div
      className="showcase"
      role="img"
      aria-label="The OpenRec meetings window on macOS, showing a call's participants, summary, next steps, and decisions, with the menu bar recorder panel floating over it."
    >
      <div className="app-window">
        <div className="titlebar">
          <span className="traffic">
            <i className="tl tl-red" />
            <i className="tl tl-yellow" />
            <i className="tl tl-green" />
          </span>
          <span className="titlebar-title">OpenRec</span>
        </div>

        <div className="app-body">
          <aside className="app-sidebar">
            <div className="sidebar-head">
              <span className="accent-dot" />
              <span className="sidebar-title">Meetings</span>
              <span className="sidebar-count">128</span>
            </div>

            <div className="search-field">
              <SearchIcon className="icon-11" />
              <span className="search-placeholder">Search meetings</span>
            </div>

            <ul className="meeting-list">
              {MEETINGS.map((m) => (
                <li
                  key={m.title}
                  className={m.active ? "meeting-row is-active" : "meeting-row"}
                >
                  <span className="meeting-title">{m.title}</span>
                  <span className="meeting-meta">{m.meta}</span>
                </li>
              ))}
            </ul>
          </aside>

          <section className="app-detail">
            <header className="detail-head">
              <div>
                <h3 className="detail-title">Acme — pricing review</h3>
                <p className="detail-meta">
                  Today, 14:20 · 42:18 · Google Meet
                </p>
              </div>
              <span className="ghost-btn">
                <CopyIcon className="icon-12" />
                Copy
              </span>
            </header>

            <div className="detail-scroll">
              <div className="detail-section">
                <div className="section-label">Participants</div>
                <div className="pills">
                  {["Kamil", "Dana Whitfield", "Marcus Lee", "Priya N."].map(
                    (p) => (
                      <span key={p} className="pill">
                        {p}
                      </span>
                    ),
                  )}
                </div>
              </div>

              <div className="detail-section">
                <div className="section-label">Summary</div>
                <p className="section-body">
                  Acme walked through their current seat count and pushed back
                  on the per-seat price at the 200+ tier. We agreed to move them
                  to annual billing next quarter in exchange for a volume
                  discount, and to keep the pilot scoped to the support team
                  until the security review clears.
                </p>
              </div>

              <div className="detail-section">
                <div className="section-label">Next steps</div>
                <ul className="steps">
                  {NEXT_STEPS.map((s) => (
                    <li key={s.task}>
                      <span className="step-dot" />
                      <span>
                        <span className="step-task">{s.task}</span>
                        <span className="step-meta">{s.meta}</span>
                      </span>
                    </li>
                  ))}
                </ul>
              </div>

              <div className="detail-section">
                <div className="section-label">Decisions</div>
                <ul className="decisions">
                  {DECISIONS.map((d) => (
                    <li key={d}>
                      <CheckIcon className="icon-13 check" />
                      {d}
                    </li>
                  ))}
                </ul>
              </div>
            </div>
          </section>
        </div>
      </div>

      {/* Menu bar recorder panel */}
      <div className="recorder-panel">
        <div className="panel-top">
          <div className="record-btn">
            <span className="record-stop" />
          </div>
          <div className="panel-timer">12:47</div>
          <div className="panel-levels">
            {levels.map((l, i) => (
              <span
                key={`level-${l}`}
                className="level-bar"
                style={{
                  height: `${Math.round(l * 20)}px`,
                  animationDelay: `${i * 0.09}s`,
                }}
              />
            ))}
          </div>
        </div>

        <div className="panel-rows">
          <div className="panel-row">
            <MicIcon className="icon-11 dim" />
            <span className="row-text">MacBook Pro Microphone</span>
            <ChevronUpDownIcon className="icon-9 dim" />
          </div>

          <div className="panel-row panel-row--toggle">
            <span className="row-text">Show red border</span>
            <span className="switch">
              <span className="knob" />
            </span>
          </div>

          <div className="segmented">
            <span className="seg is-active">Live</span>
            <span className="seg">After</span>
          </div>
        </div>
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
        <MeshGradient
          width={1280}
          height={720}
          colors={["#000000", "#000000", "#000000", "#750000"]}
          distortion={1}
          swirl={0.1}
          grainMixer={0}
          grainOverlay={0}
          speed={1}
          className="shader-canvas"
          style={{ width: "100%", height: "100%" }}
        />
      </div>

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

        <section className="showcase-section">
          <AppMockup />
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
