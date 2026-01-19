# OpenRecorder

A lightweight macOS screen recorder that captures screen, system audio, and microphone. Perfect for recording meetings, tutorials, and presentations.

## Features

- Records full screen at native resolution
- Captures system audio (hear what others say in meetings)
- Captures microphone audio (your voice)
- Outputs to MP4 format (H.264 video, AAC audio)
- Simple command-line interface
- Graceful stop with Ctrl+C

## Requirements

- macOS 12.3 or later (requires ScreenCaptureKit)
- Xcode Command Line Tools

## Installation

### Build from source

```bash
# Clone the repo
git clone git@github.com:ky-zo/openrecorder.git
cd openrecorder

# Build
./build.sh

# Run
./meetrec
```

### First run permissions

On first run, macOS will prompt for permissions. Grant them in:

**System Settings > Privacy & Security > Screen Recording**

You may also need to grant microphone access.

## Usage

```bash
# Start recording
./meetrec

# Stop recording
# Press Ctrl+C
```

Recordings are saved to the `Recordings/` folder with timestamps:
```
Recordings/meeting_2024-01-19_143022.mp4
```

## Output Format

- **Video**: H.264, 30fps, 8 Mbps
- **Audio**: AAC, 48kHz, stereo, 128kbps
- **Container**: MP4

## License

MIT License - see [LICENSE](LICENSE) for details.

---

<p align="center">
  <a href="https://fluar.com">
    <img src="assets/fluar-logo.png" alt="Fluar" width="150">
  </a>
  <br>
  <em>Sponsored by <a href="https://fluar.com">Fluar.com</a></em>
</p>
