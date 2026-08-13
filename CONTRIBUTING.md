# Contributing to OpenRec

Thanks for your interest in OpenRec. This is a small project, so the process is
light — open an issue before starting anything large, and keep pull requests
focused.

## Repository layout

| Path | What it is |
| --- | --- |
| `OpenRec/` | The macOS app (Xcode project). This is the source of truth. |
| `OpenRecApp/` | Swift Package Manager mirror of the same sources, used by `build-dev.sh`. |
| `cloud/` | Cloudflare Worker backing OpenRec Cloud (D1 + R2). |
| `web/` | The openrec landing page (Next.js). |
| `assets/` | App icon sources. |
| `build-dev.sh` / `build-app.sh` | Development and release builds. |

> The Swift sources under `OpenRec/OpenRec/` and `OpenRecApp/Sources/OpenRecApp/`
> are kept in sync. If you change one, change the other.

## Building the app

Requirements: macOS 15.0 or later and Xcode Command Line Tools.

```bash
./build-dev.sh
```

This produces and launches `dist/dev/OpenRec Dev.app` with a stable development
signature and bundle ID, so macOS keeps your Screen Recording grant across
rebuilds. Use `./build-dev.sh --reset-onboarding` to replay onboarding while
keeping saved credentials.

A release build (`./build-app.sh`) requires an Apple Developer ID certificate
and notarization credentials, so it only works for maintainers. Contributors
should use `build-dev.sh`.

## Working on the website

```bash
cd web
npm install
npm run dev
```

Lint and format with `npm run lint` and `npm run format` (Biome).

## Working on the cloud worker

```bash
cd cloud
npm install
npm test
```

Deployment requires Cloudflare credentials and the worker's secrets
(`GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `AUTH_SECRET`), so it is
maintainer-only. See `cloud/README.md`.

## Pull requests

- Keep the diff scoped to one thing.
- Match the surrounding code style; there is no separate Swift formatter config.
- Describe how you tested the change. For app changes, say which macOS version
  you ran it on.
- Never commit API keys, certificates, `.env.build`, or recordings.

## Reporting bugs

Open an issue with your macOS version, the OpenRec version (shown in Settings),
what you expected, and what happened. If the app failed to save or upload a
call, include the visible error text — please redact anything private first.

## Security

Please do not open a public issue for security problems. See
[SECURITY.md](SECURITY.md).
