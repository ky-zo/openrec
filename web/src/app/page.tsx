"use client";

import { useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/button";

function GithubIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" className={className}>
      <path d="M12 0C5.37 0 0 5.37 0 12c0 5.31 3.435 9.795 8.205 11.385.6.105.825-.255.825-.57 0-.285-.015-1.23-.015-2.235-3.015.555-3.795-.735-4.035-1.41-.135-.345-.72-1.41-1.23-1.695-.42-.225-1.02-.78-.015-.795.945-.015 1.62.87 1.845 1.23 1.08 1.815 2.805 1.305 3.495.99.105-.78.42-1.305.765-1.605-2.67-.3-5.46-1.335-5.46-5.925 0-1.305.465-2.385 1.23-3.225-.12-.3-.54-1.53.12-3.18 0 0 1.005-.315 3.3 1.23.96-.27 1.98-.405 3-.405s2.04.135 3 .405c2.295-1.56 3.3-1.23 3.3-1.23.66 1.65.24 2.88.12 3.18.765.84 1.23 1.905 1.23 3.225 0 4.605-2.805 5.625-5.475 5.925.435.375.81 1.095.81 2.22 0 1.605-.015 2.895-.015 3.3 0 .315.225.69.825.57A12.02 12.02 0 0 0 24 12c0-6.63-5.37-12-12-12z" />
    </svg>
  );
}

function DownloadIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className={className}>
      <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
      <polyline points="7,10 12,15 17,10" />
      <line x1="12" y1="15" x2="12" y2="3" />
    </svg>
  );
}

function StarIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" className={className}>
      <path d="M12 .587l3.668 7.568 8.332 1.151-6.064 5.828 1.48 8.279-7.416-3.967-7.417 3.967 1.481-8.279-6.064-5.828 8.332-1.151z" />
    </svg>
  );
}

function FluarLogo({ className }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 158 228" fill="none" xmlns="http://www.w3.org/2000/svg">
      <path d="M105.52 0.854004C149.252 0.854004 173.256 44.187 144.915 84.62C121.664 117.797 62.303 108.599 56.453 146.195C53.02 168.243 76.982 180.137 80.812 194.965C89.058 226.9 62.721 233.166 47.29 222.404C36.057 214.573 23.814 200.345 16.743 186.346C-22.136 109.437 11.306 0.854004 105.52 0.854004Z" fill="currentColor" />
      <path d="M95.068 127.332C82.85 127.332 72.944 137.235 72.944 149.455C72.944 161.675 82.85 171.574 95.068 171.574C107.284 171.574 117.187 161.675 117.187 149.455C117.187 137.235 107.284 127.332 95.068 127.332Z" fill="currentColor" />
    </svg>
  );
}

function Waveform() {
  // Generate random heights and animation properties for each bar
  const bars = Array.from({ length: 50 }).map((_, i) => ({
    height: 20 + Math.random() * 80, // Random height between 20-100%
    delay: Math.random() * 2, // Random delay 0-2s
    duration: 0.8 + Math.random() * 1.2, // Random duration 0.8-2s
  }));

  return (
    <div className="waveform">
      <div className="waveform-inner">
        {bars.map((bar, i) => (
          <div
            key={i}
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

export default function Page() {
  const cursorRef = useRef<HTMLDivElement>(null);
  const [stars, setStars] = useState<number | null>(null);

  useEffect(() => {
    fetch("https://api.github.com/repos/ky-zo/openrec")
      .then((res) => res.json())
      .then((data) => {
        if (data.stargazers_count !== undefined) {
          setStars(data.stargazers_count);
        }
      })
      .catch(() => {});
  }, []);

  useEffect(() => {
    const cursor = cursorRef.current;
    if (!cursor) return;

    let mouseX = 0, mouseY = 0;
    let cursorX = 0, cursorY = 0;

    const handleMouseMove = (e: MouseEvent) => {
      mouseX = e.clientX;
      mouseY = e.clientY;
    };

    const animate = () => {
      const dx = mouseX - cursorX;
      const dy = mouseY - cursorY;
      cursorX += dx * 0.15;
      cursorY += dy * 0.15;
      cursor.style.left = cursorX - 10 + "px";
      cursor.style.top = cursorY - 10 + "px";
      requestAnimationFrame(animate);
    };

    document.addEventListener("mousemove", handleMouseMove);
    animate();

    const interactiveElements = document.querySelectorAll("a, button");
    interactiveElements.forEach((el) => {
      el.addEventListener("mouseenter", () => cursor.classList.add("active"));
      el.addEventListener("mouseleave", () => cursor.classList.remove("active"));
    });

    const handleMouseDown = () => (cursor.style.transform = "scale(0.8)");
    const handleMouseUp = () => (cursor.style.transform = "scale(1)");

    document.addEventListener("mousedown", handleMouseDown);
    document.addEventListener("mouseup", handleMouseUp);

    return () => {
      document.removeEventListener("mousemove", handleMouseMove);
      document.removeEventListener("mousedown", handleMouseDown);
      document.removeEventListener("mouseup", handleMouseUp);
    };
  }, []);

  return (
    <div className="landing-page">
      <div ref={cursorRef} className="cursor" />
      <div className="gradient-orb orb-1" />
      <div className="gradient-orb orb-2" />

      <header className="top-bar">
        <div className="logo">
          <span className="red-dot" />
          <span className="logo-text">OpenRec</span>
        </div>
      </header>

      <main>
        <h1>
          <span className="word word-1">Record</span>{" "}
          <span className="word word-2">your</span>{" "}
          <span className="word word-3">call</span>{" "}
          <span className="word word-4">meetings</span>{" "}
          <span className="word word-5">for free</span>
        </h1>
        <h2>open source free software</h2>

        <Waveform />

        <div className="buttons">
          <Button
            size="lg"
            className="btn-shadcn btn-shadcn-primary"
            render={<a href="https://github.com/ky-zo/openrec/releases/latest" />}
          >
            <DownloadIcon className="size-5" />
            Download
          </Button>
          <Button
            size="lg"
            variant="outline"
            className="btn-shadcn btn-shadcn-outline"
            render={<a href="https://github.com/ky-zo/openrec" />}
          >
            <GithubIcon className="size-5" />
            GitHub
            {stars !== null && (
              <span className="star-count">
                <StarIcon className="size-3.5" />
                {stars}
              </span>
            )}
          </Button>
        </div>

        <div className="sponsor">
          <span className="sponsor-text">sponsored by</span>
          <a href="https://fluar.com" target="_blank" rel="noopener noreferrer" className="sponsor-link">
            <FluarLogo className="sponsor-logo" />
            <span className="sponsor-name">Fluar.com</span>
          </a>
          <span className="sponsor-tagline">GTM Automation and Data Enrichment</span>
        </div>
      </main>

      <footer className="footer">
        <a href="#">MIT License</a> · <a href="#">Contribute</a> · v1.0.0
      </footer>

      <svg className="noise" xmlns="http://www.w3.org/2000/svg">
        <filter id="noiseFilter">
          <feTurbulence type="fractalNoise" baseFrequency="0.8" numOctaves={4} stitchTiles="stitch" />
        </filter>
        <rect width="100%" height="100%" filter="url(#noiseFilter)" />
      </svg>
    </div>
  );
}
