<p align="center">
  <a href="https://fluar.com">
    <img src="assets/fluar-logo.png" alt="Fluar" width="150">
  </a>
  <br>
  <em>Sponsored by <a href="https://fluar.com">Fluar.com</a> - Go To Market and Data Enrichment platform for your startup</em>
</p>

---

# OpenRec

A lightweight macOS screen recorder that captures screen, system audio, and microphone. Perfect for recording meetings, tutorials, and presentations.

## Features

- Records full screen at native resolution
- Captures system audio (hear what others say in meetings)
- Captures microphone audio (your voice)
- Outputs to MP4 format (H.264 video, AAC audio)
- Simple macOS app

## Requirements

- macOS 15.0 or later
- Xcode Command Line Tools

## Download (latest)

https://github.com/ky-zo/openrec/releases/latest/download/OpenRec.dmg

## Installation

### Build from source

```bash
# Clone the repo
git clone git@github.com:ky-zo/openrec.git
cd openrec

# Build
./build-app.sh
```

### First run permissions

On first run, macOS will prompt for permissions. Grant them in:

**System Settings > Privacy & Security > Screen Recording**

You may also need to grant microphone access.

## Usage

Launch `OpenRec.app` and start recording from the floating control window.

## Output Format

- **Video**: H.264, 30fps, 8 Mbps
- **Audio**: AAC, 48kHz, stereo, 128kbps
- **Container**: MP4

## License

MIT License - see [LICENSE](LICENSE) for details.
