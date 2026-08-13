# OpenRec Cloud

The managed storage service is a Cloudflare Worker backed by D1 for meeting memory and a private R2 bucket for media. Google OAuth returns a one-time code to the macOS app. The app stores its OpenRec session token in the macOS Keychain, while Google refresh tokens are encrypted before D1 storage.

## Setup

1. Create a D1 database and private R2 bucket, then replace the IDs/names in `wrangler.toml`.
2. Create a Google OAuth web client, enable the Google Calendar API, and add this redirect URI:

   `https://openrec-cloud.qstar0.workers.dev/v1/auth/google/callback`

3. Configure Worker secrets:

   ```bash
   npx wrangler secret put GOOGLE_CLIENT_ID
   npx wrangler secret put GOOGLE_CLIENT_SECRET
   npx wrangler secret put AUTH_SECRET
   ```

4. Apply the schema and deploy:

   ```bash
   npm install
   npm run db:migrate
   npm run deploy
   ```

For an existing database, apply the non-destructive, idempotent immutable-media migration before deploying this Worker version:

```bash
npm run db:migrate:media
```

## Authentication

The OAuth flow requests `calendar.readonly` so meeting titles and attendees can be matched without editing calendar data.

1. Start sign-in with `GET /v1/auth/google/start?redirect_uri=<app-callback>`. The only accepted app callbacks are `openrec://auth` and `openrec-dev://auth`.
2. Google returns to the configured Worker callback, `/v1/auth/google/callback`, which redirects to the requested app callback with a short-lived one-time code.
3. Exchange that code with `POST /v1/auth/exchange` and `{ "code": "..." }` to receive the app session token.
4. Revoke the current session with authenticated `DELETE /v1/auth/session`; the response is `{ "ok": true }`.

All routes below require `Authorization: Bearer <session-token>`. Metadata queries and R2 keys are scoped to the authenticated user.

## Meeting read API

- `GET /v1/meetings?q=<query>&offset=<offset>` returns a page of up to 100 camel-case meeting summaries and `nextOffset`, which is an integer when another page exists or `null` at the end. `q` is optional and searches title, call title, summary, transcript, participants, action items, and decisions. The query is limited to 200 characters; offset must be a non-negative integer.
- `GET /v1/meetings/:id` returns the full structured meeting, transcript, media-availability booleans, and relative authenticated media URLs.
- `GET /v1/meetings/:id/media/screen` streams the user's screen recording from private R2.
- `GET /v1/meetings/:id/media/audio` streams the user's audio recording from private R2.
- `HEAD` is also supported on both authenticated media routes.

Media responses preserve R2 HTTP metadata and support full or byte-range responses for playback and resumable downloads. The R2 bucket remains private.

## Managed media uploads

Managed uploads use immutable, server-derived generation keys such as `…/screen/<generation>.mp4` and `…/audio/<generation>.m4a`. Clients never supply or derive an R2 key. Every replacement receives a new key, and D1 atomically changes the current generation pointer. The existing single-request route remains available:

- `PUT /v1/meetings/:id/media/:kind`

Large recordings can use authenticated multipart uploads:

1. `POST /v1/meetings/:id/media/:kind/multipart` returns `{ "uploadId": "...", "generation": "..." }`. `uploadId` is an opaque OpenRec token, not an R2 upload ID.
2. `PUT /v1/meetings/:id/media/:kind/multipart/:uploadId/parts/:partNumber` uploads one raw part and returns `{ "partNumber": 1, "etag": "..." }`.
3. `POST /v1/meetings/:id/media/:kind/multipart/:uploadId/complete` with `{ "parts": [{ "partNumber": 1, "etag": "..." }] }` atomically assembles the object and returns its immutable key, generation, ETag, and R2 version.
4. `DELETE /v1/meetings/:id/media/:kind/multipart/:uploadId` aborts an unfinished upload.

Part numbers must be unique integers from 1 through 10,000. Upload state and returned part ETags are journaled in D1. Completion is retry-safe: if R2 completes but the Worker loses its response or D1 attachment fails, a repeated identical completion reconciles the generation from R2 and attaches it once. A completion based on a superseded generation returns `409` and cannot overwrite newer media. Every request re-checks the authenticated user and deletion state.

The macOS app creates a provisional meeting with `PUT /v1/meetings/:id` before capture and begins the required multipart uploads. The Worker journals the opaque upload ID and each returned part ETag in D1; the Mac keeps only non-secret upload identity metadata so it can abort an exact stale upload after a crash. No media bytes are journaled locally. Repeating a part number replaces that R2 multipart part, so an interrupted request can safely retry that numbered part before completion. OpenRec uses 5 MiB parts, which is R2's minimum for every part except the final one.

## Temporary media access and deletion

External processors and native players cannot attach the OpenRec session header. An authenticated client can request a short-lived, bearerless URL after media upload:

- `GET /v1/meetings/:id/media/:kind/access` returns `{ "url": "https://…", "expiresAt": "…" }` with a one-hour lifetime.
- `GET /v1/meetings/:id/media/:kind/access?ttl=86400` requests a custom lifetime between 60 seconds and 24 hours.
- The returned URL accepts `GET` and `HEAD`. GET supports one HTTP byte range and returns `416` with `Content-Range: bytes */<size>` for invalid or unsatisfiable ranges. HEAD deliberately ignores Range and returns full-object metadata with `200`. This supports AssemblyAI ingestion, AVPlayer playback, and external webhook consumers without exposing an OpenRec session token.

The URL carries HMAC-authenticated claims binding the user, meeting, media kind, immutable R2 key, generation, ETag, R2 version, and expiry. Each request checks the live D1 generation pointer and the exact R2 object version. An old URL therefore cannot revive after replacement, deletion, or reupload. The R2 bucket and raw object endpoint remain private.

Use authenticated `DELETE /v1/meetings/:id/media/:kind` to remove completed transient or retained media. The operation is idempotent, deletes the private R2 object, and clears only the matching media key from that user's meeting. Use the multipart `DELETE` route above for uploads that have not completed.

Use authenticated `DELETE /v1/meetings/:id` to abandon a provisional recording session. It always returns `{ "ok": true }`, including for an absent or non-owned ID, without revealing another user's meeting. OpenRec blocks new parts/attachments, aborts that owner's active multipart uploads, removes only validated generation-specific objects and current pointers, then deletes upload parts, upload state, and the provisional meeting.
