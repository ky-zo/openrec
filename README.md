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

## Download

**[Download Latest Release](https://github.com/ky-zo/openrec/releases/latest/download/OpenRec.dmg)**

The app is signed and notarized by Apple.

## Features

- Records full screen at native resolution
- Captures system audio (hear what others say in meetings)
- Captures microphone audio (your voice)
- Outputs to MP4 format (H.264 video, AAC audio)
- Segment recording for long sessions
- Simple floating control panel
- Menu bar integration

## Requirements

- macOS 15.0 or later

## Installation

1. Download [OpenRec.dmg](https://github.com/ky-zo/openrec/releases/latest/download/OpenRec.dmg)
2. Open the DMG and drag OpenRec to Applications
3. Launch OpenRec

### First Run Permissions

On first run, macOS will prompt for permissions. Grant them in:

**System Settings > Privacy & Security > Screen Recording**

You may also need to grant microphone access.

## Building from Source

### Prerequisites

- Xcode Command Line Tools
- Apple Developer ID certificate (for distribution)

### Quick Build (unsigned, for development)

```bash
cd OpenRecApp
swift build
.build/debug/OpenRecApp
```

### Signed & Notarized Build (for distribution)

1. **Set up notarization credentials** (one-time):

   Generate an app-specific password at [appleid.apple.com](https://appleid.apple.com/account/manage), then:

   ```bash
   xcrun notarytool store-credentials "openrec-notary" \
     --apple-id "your@email.com" \
     --team-id "YOUR_TEAM_ID" \
     --password "xxxx-xxxx-xxxx-xxxx"
   ```

2. **Configure build** (optional):

   ```bash
   cp .env.example .env.build
   # Edit .env.build if needed
   ```

3. **Build**:

   ```bash
   ./build-app.sh
   ```

   This will build, sign, create DMG, notarize, and staple.

   Output:
   - `dist/OpenRec.app`
   - `dist/OpenRec-X.X.X.dmg`

## Output Format

- **Video**: H.264, 30fps, 8 Mbps
- **Audio**: AAC, 48kHz, stereo, 128kbps
- **Container**: MP4

## License

MIT License - see [LICENSE](LICENSE) for details.
