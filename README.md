# OpenRec

An open-source macOS call recorder and meeting memory tool. OpenRec captures screen, system audio, and microphone without adding a bot to the call, then creates a transcript, participant list, summary, decisions, and next steps.

## Download

**[Download Latest Release](https://github.com/ky-zo/openrec/releases/latest/download/OpenRec.dmg)**

The app is signed and notarized by Apple.

## Features

- Records full screen at native resolution
- Captures system audio (hear what others say in meetings)
- Captures microphone audio (your voice)
- Streams fragmented MP4 media directly to OpenRec Cloud or your own Cloudflare R2 bucket while the call is running
- Keeps no permanent recordings folder or full recording file on the Mac for new calls
- Uses 5 MiB multipart uploads with a strict 96 MiB in-memory backlog limit
- Per-call video, audio, transcript-sync, and webhook retention controls
- AssemblyAI Universal-3.5 Pro transcription with speaker diarization using your own AssemblyAI API key
- Google sign-in for managed R2/D1 storage or direct upload to your own R2 bucket
- Call detection for Meet, Zoom, Teams, Slack Huddles, FaceTime, Webex, and more
- Participant, decision, summary, and next-step extraction
- External `meeting.completed` webhooks with private, expiring media links
- Recoverable upload/save failures with visible progress and errors
- Menu bar integration

## Requirements

- macOS 15.0 or later

## Installation

1. Download [OpenRec.dmg](https://github.com/ky-zo/openrec/releases/latest/download/OpenRec.dmg)
2. Open the DMG and drag OpenRec to Applications
3. Launch OpenRec

### First Run Setup

OpenRec opens a focused onboarding flow before showing the recorder. It walks through:

- Your AssemblyAI key for transcription and OpenAI key for meeting memory, both stored in the macOS Keychain
- OpenRec Cloud with Google sign-in, or your own Cloudflare R2 bucket
- Default recording and transcript retention
- An optional external webhook
- Microphone and Screen Recording permissions

You can replay the same flow later from the recorder's Settings button.

## Building from Source

### Prerequisites

- Xcode Command Line Tools
- Apple Developer ID certificate (for distribution)

### Quick Build (signed development app)

```bash
./build-dev.sh
```

This creates and launches `dist/dev/OpenRec Dev.app` with a stable development
signature and bundle ID. Grant Screen Recording access to **OpenRec Dev** once;
macOS will retain it across rebuilds. To replay onboarding while keeping saved
credentials, run `./build-dev.sh --reset-onboarding`.

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

New recordings are cloud-first. OpenRec keeps only small meeting metadata and a non-secret upload-recovery journal on the Mac—never recording bytes. For your own R2, that journal can also finish a manifest after an interrupted launch without orphaning completed media. Existing recordings from older versions remain available as read-only legacy files and are never deleted automatically.

## Output Format

- **Video**: H.264, up to 30fps, approximately 3 Mbps
- **Audio**: mixed microphone and system audio, AAC, 48kHz mono, 128kbps
- **Container**: fragmented MP4 (Apple HLS profile for the muxed screen movie; CMAF profile for audio-only)

## License

MIT License - see [LICENSE](LICENSE) for details.
