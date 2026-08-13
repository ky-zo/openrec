# Agent notes for OpenRec

Read this before touching the backend, the database, or the release process.
It exists because these exact mistakes have already been made once.

## Architecture — what runs where

- **The Cloudflare Worker in `cloud/` is the only backend.** It owns Google
  OAuth (sign-in AND calendar connections), sessions, the D1 database, R2
  media, and the calendar endpoints. Deployed as `openrec-cloud`
  (`https://openrec-cloud.qstar0.workers.dev`) via `cd cloud && npm run deploy`.
- **openrec.co on Vercel is the marketing site only** (`web/`). Do NOT route
  auth or API traffic through Vercel — the OAuth callback must live on exactly
  one host, secrets live in the Worker, and the data (D1/R2) is on Cloudflare.
  If a nicer auth domain is wanted, the correct move is a Cloudflare custom
  domain (e.g. `api.openrec.co`) attached to the existing Worker, plus updating
  `PUBLIC_BASE_URL` and the Google OAuth client's redirect URIs. That is a
  config change, not a code split.
- **Google identity vs. calendar access are separate grants.** Sign-in
  (`/v1/auth/google/*`) owns the meeting library. Calendar connections
  (`/v1/calendar/connect/*`, stored in the `calendar_connections` table) are
  additive: a user connects any number of Google accounts and their events
  merge into one list. Never conflate the two, and never make "switch calendar
  account" touch the sign-in identity.

## Database — D1 migrations (no Drizzle)

- This project does **not** use Drizzle. There is no ORM; the Worker uses raw
  `env.DB.prepare(...)` SQL. Do not add Drizzle (or any ORM) casually — if it
  is ever adopted, that is a dedicated migration project requiring a Cloudflare
  API token decision, not a drive-by change.
- Migrations are plain SQL files in `cloud/migrations/`, numbered
  (`0005_multi_calendar_connections.sql`), applied with **wrangler's tracked
  migration system**:
  - `cd cloud && npm run db:migrate` → `wrangler d1 migrations apply openrec --remote`
  - `npm run db:migrate:local` for the local dev DB
  - Applied migrations are tracked in the `d1_migrations` table; the prod DB is
    baselined through `0005`. Never apply a migration file with a raw
    `wrangler d1 execute --file` — that bypasses tracking.
- New migration = add the next-numbered `.sql` file, mirror the change in
  `cloud/schema.sql` (used to bootstrap fresh local DBs via
  `npm run db:bootstrap:local`), run `npm run db:migrate`, then deploy the
  Worker. Keep migrations additive (`ALTER TABLE ... ADD COLUMN`,
  `CREATE TABLE IF NOT EXISTS`) — real users are on this DB.

## App source layout

- **`OpenRecApp/` (SwiftPM) is the source of truth.** `build-dev.sh` and
  `build-app.sh` build it. `OpenRec/OpenRec.xcodeproj` + `OpenRec/OpenRec/` is
  a file-level mirror kept in sync by copying the Swift files; Amore builds
  from this Xcode project. After changing Swift sources, copy them into
  `OpenRec/OpenRec/` and confirm both `swift build --package-path OpenRecApp`
  and the Xcode project still build. New Swift files must also be registered in
  `project.pbxproj`.

## Releasing

- **Bundle ID is `app.openrec.mac`** (dev builds: `app.openrec.mac.dev`).
  An old `com.fluar.openrec` app exists in Amore — ignore it, never release to
  it.
- **Version lives in three places and they must agree** before a release:
  1. `VERSION` (e.g. `v0.3.1`) and `BUILD_NUMBER` in the repo root — used by
     `build-app.sh` / `build-dev.sh`.
  2. `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
     `OpenRec/OpenRec.xcodeproj/project.pbxproj` — used by Amore builds.
- **Releasing with the Amore CLI:**
  - `amore release OpenRec/OpenRec.xcodeproj --scheme OpenRec --release-notes "…"`
    archives (Release config), signs, notarizes, builds a DMG, and uploads.
  - Per-app config is already set:
    `amore config show -b app.openrec.mac` → codesign identity
    `Developer ID Application: KAMIL ADRIAN ZOWCZAK (G58RTP74UP)` and
    notarization keychain profile `openrec-notary`.
  - **Amore prompts for confirmation after showing its Release Settings table
    and hangs forever without a TTY.** From automation, run it under
    `script -q <log> amore release …` and feed a delayed `y` (the prompt
    appears after the ~25s archive step), or run it interactively.
  - `--output <dir>` builds the signed/notarized artifact locally **without
    uploading** — use it to verify a build without publishing.
- The legacy Sparkle path (`release.sh` → tag → `build-app.sh` →
  `appcast.xml`) still exists; don't mix the two in one release. If a release
  goes out via Amore, the tag/commit should still be created so dist matches a
  commit.
