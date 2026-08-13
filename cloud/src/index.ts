interface Env {
  DB: D1Database;
  RECORDINGS: R2Bucket;
  GOOGLE_CLIENT_ID: string;
  GOOGLE_CLIENT_SECRET: string;
  AUTH_SECRET: string;
  PUBLIC_BASE_URL: string;
}

interface GoogleProfile {
  sub: string;
  email: string;
  email_verified?: boolean;
  name?: string;
  picture?: string;
}

interface MeetingPayload {
  id: string;
  startedAt: string;
  endedAt: string;
  callApp?: string;
  callTitle?: string;
  transcript: string;
  durationSeconds: number;
  insights: {
    title: string;
    summary: string;
    aiNotes?: string;
    participants: string[];
    actionItems: unknown[];
    decisions: string[];
  };
}

interface MeetingRow {
  id: string;
  started_at: string;
  ended_at: string;
  duration_seconds: number;
  call_app: string | null;
  call_title: string | null;
  transcript: string | null;
  title: string;
  summary: string;
  ai_notes: string | null;
  participants_json: string;
  action_items_json: string;
  decisions_json: string;
  screen_object_key: string | null;
  audio_object_key: string | null;
  created_at: string;
  updated_at: string;
}

type MeetingSummaryRow = Omit<MeetingRow, "transcript">;
type MediaKind = "screen" | "audio";

interface MediaAccessClaims {
  v: 1;
  userID: string;
  meetingID: string;
  kind: MediaKind;
  objectKey: string;
  generation: string;
  etag: string;
  version: string;
  expiresAt: number;
}

interface MeetingMediaRow {
  object_key: string;
  generation: string;
  etag: string;
  version: string;
}

interface MediaPointer {
  objectKey: string;
  generation: string;
  etag: string;
  version: string;
  legacy: boolean;
}

type MediaUploadStatus = "uploading" | "completing" | "completed" | "attached" | "aborted";

interface MediaUploadRow {
  id: string;
  r2_upload_id: string;
  meeting_id: string;
  user_id: string;
  kind: MediaKind;
  object_key: string;
  generation: string;
  replaces_object_key: string | null;
  replaces_generation: string | null;
  status: MediaUploadStatus;
  completion_parts_json: string | null;
  completed_etag: string | null;
  completed_version: string | null;
}

const mediaAccessTokenContext = "openrec-media-access-v1";
const defaultMediaAccessTTLSeconds = 60 * 60;
const maximumMediaAccessTTLSeconds = 24 * 60 * 60;

const mediaDefinitions: Record<MediaKind, { extension: "mp4" | "m4a"; contentType: string }> = {
  screen: { extension: "mp4", contentType: "video/mp4" },
  audio: { extension: "m4a", contentType: "audio/mp4" },
};

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      if (request.method === "OPTIONS") return new Response(null, { status: 204 });
      const url = new URL(request.url);
      if (url.pathname === "/health") return json({ ok: true });
      if (url.pathname === "/v1/auth/google/start" && request.method === "GET") return await startGoogle(url, env);
      if (url.pathname === "/v1/auth/google/callback" && request.method === "GET") return await finishGoogle(url, env);
      if (url.pathname === "/v1/auth/exchange" && request.method === "POST") return await exchangeCode(request, env);
      const publicMedia = url.pathname.match(/^\/v1\/media\/access\/([^/]+)$/i);
      if (publicMedia && (request.method === "GET" || request.method === "HEAD")) {
        return await getMediaWithAccessToken(request, env, decodeAccessToken(publicMedia[1]));
      }

      const user = await authenticate(request, env);
      if (url.pathname === "/v1/auth/session" && request.method === "DELETE") return await revokeSession(request, env);
      if (url.pathname === "/v1/calendar/current" && request.method === "GET") return await currentCalendarEvent(env, user);
      if (url.pathname === "/v1/calendar/upcoming" && request.method === "GET") return await upcomingCalendarEvents(url, env, user);
      if (url.pathname === "/v1/calendar/connect/session" && request.method === "POST") return await createCalendarConnectSession(request, env, user);
      if (url.pathname === "/v1/calendar/status" && request.method === "GET") return await calendarConnectionStatus(env, user);
      if (url.pathname === "/v1/calendar/connection" && request.method === "DELETE") return await disconnectCalendar(url, env, user);
      const meeting = url.pathname.match(/^\/v1\/meetings\/([0-9a-f-]+)$/i);
      if (meeting && request.method === "PUT") return await putMeeting(request, env, user, meeting[1]);
      if (meeting && request.method === "GET") return await getMeeting(env, user, meeting[1]);
      if (meeting && request.method === "DELETE") return await deleteMeeting(env, user, meeting[1]);
      const media = url.pathname.match(/^\/v1\/meetings\/([0-9a-f-]+)\/media\/(screen|audio)$/i);
      if (media && request.method === "PUT") {
        return await putMedia(request, env, user, media[1], parseMediaKind(media[2]));
      }
      if (media && request.method === "GET") {
        return await getMedia(request, env, user, media[1], parseMediaKind(media[2]));
      }
      if (media && request.method === "HEAD") {
        return await getMedia(request, env, user, media[1], parseMediaKind(media[2]));
      }
      if (media && request.method === "DELETE") {
        return await deleteMedia(env, user, media[1], parseMediaKind(media[2]));
      }
      const mediaAccess = url.pathname.match(/^\/v1\/meetings\/([0-9a-f-]+)\/media\/(screen|audio)\/access$/i);
      if (mediaAccess && request.method === "GET") {
        return await createMediaAccessURL(url, env, user, mediaAccess[1], parseMediaKind(mediaAccess[2]));
      }
      const multipartCreate = url.pathname.match(/^\/v1\/meetings\/([0-9a-f-]+)\/media\/(screen|audio)\/multipart$/i);
      if (multipartCreate && request.method === "POST") {
        return await createMediaMultipartUpload(env, user, multipartCreate[1], parseMediaKind(multipartCreate[2]));
      }
      const multipartPart = url.pathname.match(/^\/v1\/meetings\/([0-9a-f-]+)\/media\/(screen|audio)\/multipart\/([^/]+)\/parts\/(\d+)$/i);
      if (multipartPart && request.method === "PUT") {
        return await putMediaMultipartPart(
          request,
          env,
          user,
          multipartPart[1],
          parseMediaKind(multipartPart[2]),
          decodeUploadID(multipartPart[3]),
          Number(multipartPart[4]),
        );
      }
      const multipartComplete = url.pathname.match(/^\/v1\/meetings\/([0-9a-f-]+)\/media\/(screen|audio)\/multipart\/([^/]+)\/complete$/i);
      if (multipartComplete && request.method === "POST") {
        return await completeMediaMultipartUpload(
          request,
          env,
          user,
          multipartComplete[1],
          parseMediaKind(multipartComplete[2]),
          decodeUploadID(multipartComplete[3]),
        );
      }
      const multipartAbort = url.pathname.match(/^\/v1\/meetings\/([0-9a-f-]+)\/media\/(screen|audio)\/multipart\/([^/]+)$/i);
      if (multipartAbort && request.method === "DELETE") {
        return await abortMediaMultipartUpload(
          env,
          user,
          multipartAbort[1],
          parseMediaKind(multipartAbort[2]),
          decodeUploadID(multipartAbort[3]),
        );
      }
      if (url.pathname === "/v1/meetings" && request.method === "GET") return await listMeetings(url, env, user);
      return json({ error: "Not found" }, 404);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Unknown error";
      const status = error instanceof HTTPError ? error.status : 500;
      return json({ error: message }, status);
    }
  },
};

async function startGoogle(url: URL, env: Env): Promise<Response> {
  const redirectURI = url.searchParams.get("redirect_uri");
  if (redirectURI !== "openrec://auth" && redirectURI !== "openrec-dev://auth") {
    throw new HTTPError(400, "Unsupported app callback URL");
  }
  const state = await signState({ redirectURI, expires: Date.now() + 10 * 60_000, nonce: randomToken(16) }, env.AUTH_SECRET);
  const google = new URL("https://accounts.google.com/o/oauth2/v2/auth");
  google.searchParams.set("client_id", env.GOOGLE_CLIENT_ID);
  google.searchParams.set("redirect_uri", `${env.PUBLIC_BASE_URL}/v1/auth/google/callback`);
  google.searchParams.set("response_type", "code");
  google.searchParams.set("scope", "openid email profile https://www.googleapis.com/auth/calendar.readonly");
  google.searchParams.set("state", state);
  google.searchParams.set("access_type", "offline");
  google.searchParams.set("prompt", "consent select_account");
  return Response.redirect(google.toString(), 302);
}

/// Start a calendar-only OAuth grant for the signed-in user. The chosen Google
/// account is independent of the sign-in identity: storage stays on the
/// account the user signed in with, while calendar context can come from any
/// account they pick in Google's account chooser.
async function createCalendarConnectSession(request: Request, env: Env, user: { id: string }): Promise<Response> {
  const body = (await request.json().catch(() => ({}))) as { redirect_uri?: string };
  const redirectURI = body.redirect_uri ?? "";
  if (redirectURI !== "openrec://calendar" && redirectURI !== "openrec-dev://calendar") {
    throw new HTTPError(400, "Unsupported app callback URL");
  }
  const state = await signState(
    { redirectURI, expires: Date.now() + 10 * 60_000, nonce: randomToken(16), purpose: "calendar", userID: user.id },
    env.AUTH_SECRET,
  );
  const google = new URL("https://accounts.google.com/o/oauth2/v2/auth");
  google.searchParams.set("client_id", env.GOOGLE_CLIENT_ID);
  google.searchParams.set("redirect_uri", `${env.PUBLIC_BASE_URL}/v1/auth/google/callback`);
  google.searchParams.set("response_type", "code");
  google.searchParams.set("scope", "openid email https://www.googleapis.com/auth/calendar.readonly");
  google.searchParams.set("state", state);
  google.searchParams.set("access_type", "offline");
  google.searchParams.set("prompt", "consent select_account");
  return json({ url: google.toString() });
}

async function calendarConnectionStatus(env: Env, user: { id: string }): Promise<Response> {
  const connections = await env.DB.prepare(
    "SELECT email FROM calendar_connections WHERE user_id = ? ORDER BY created_at"
  ).bind(user.id).all<{ email: string }>();
  const emails = (connections.results ?? []).map((row) => row.email);
  if (emails.length > 0) {
    return json({ connected: true, email: emails[0], emails });
  }
  // Legacy fallback: the sign-in token also carries the calendar scope for
  // accounts connected before dedicated calendar connections existed.
  const record = await env.DB.prepare("SELECT google_refresh_token_cipher FROM users WHERE id = ?")
    .bind(user.id).first<{ google_refresh_token_cipher: string | null }>();
  if (record?.google_refresh_token_cipher) {
    return json({ connected: true, email: null, emails: [] });
  }
  return json({ connected: false, email: null, emails: [] });
}

async function disconnectCalendar(url: URL, env: Env, user: { id: string }): Promise<Response> {
  const email = url.searchParams.get("email");
  if (email) {
    await env.DB.prepare("DELETE FROM calendar_connections WHERE user_id = ? AND email = ?")
      .bind(user.id, email).run();
  } else {
    await env.DB.prepare("DELETE FROM calendar_connections WHERE user_id = ?").bind(user.id).run();
  }
  // Clear the legacy single-connection columns either way.
  await env.DB.prepare(
    "UPDATE users SET google_calendar_refresh_token_cipher = NULL, google_calendar_email = NULL, updated_at = ? WHERE id = ?"
  ).bind(new Date().toISOString(), user.id).run();
  return json({ ok: true });
}

async function finishGoogleCalendarConnect(
  code: string,
  state: { redirectURI: string; expires: number; userID?: string },
  env: Env,
): Promise<Response> {
  if (!state.userID) throw new HTTPError(400, "Invalid calendar connect request");
  const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code,
      client_id: env.GOOGLE_CLIENT_ID,
      client_secret: env.GOOGLE_CLIENT_SECRET,
      redirect_uri: `${env.PUBLIC_BASE_URL}/v1/auth/google/callback`,
      grant_type: "authorization_code",
    }),
  });
  if (!tokenResponse.ok) throw new HTTPError(502, "Google token exchange failed");
  const tokens = (await tokenResponse.json()) as { access_token?: string; refresh_token?: string };
  if (!tokens.access_token) throw new HTTPError(502, "Google returned no access token");
  if (!tokens.refresh_token) throw new HTTPError(502, "Google returned no offline calendar access. Try connecting again.");
  const profileResponse = await fetch("https://openidconnect.googleapis.com/v1/userinfo", {
    headers: { authorization: `Bearer ${tokens.access_token}` },
  });
  if (!profileResponse.ok) throw new HTTPError(502, "Google profile lookup failed");
  const profile = (await profileResponse.json()) as GoogleProfile;
  const email = profile.email ?? "Google account";

  // Additive: each granted account becomes its own connection; reconnecting
  // the same account just refreshes its token.
  await env.DB.prepare(`
    INSERT INTO calendar_connections (id, user_id, email, refresh_token_cipher, created_at)
    VALUES (?, ?, ?, ?, ?)
    ON CONFLICT(user_id, email) DO UPDATE SET refresh_token_cipher = excluded.refresh_token_cipher
  `).bind(
    crypto.randomUUID(),
    state.userID,
    email,
    await encryptSecret(tokens.refresh_token, env.AUTH_SECRET),
    new Date().toISOString(),
  ).run();

  const callback = new URL(state.redirectURI);
  callback.searchParams.set("status", "connected");
  callback.searchParams.set("email", email);
  return new Response(null, { status: 302, headers: { location: callback.toString(), "cache-control": "no-store" } });
}

async function finishGoogle(url: URL, env: Env): Promise<Response> {
  const oauthError = url.searchParams.get("error");
  if (oauthError) throw new HTTPError(400, `Google sign-in failed: ${oauthError}`);
  const code = url.searchParams.get("code");
  const stateValue = url.searchParams.get("state");
  if (!code || !stateValue) throw new HTTPError(400, "Missing Google authorization response");
  const state = await verifyState(stateValue, env.AUTH_SECRET);
  if (state.expires < Date.now()) throw new HTTPError(400, "Expired sign-in request");
  if (state.purpose === "calendar") {
    const supportedCalendarCallback = state.redirectURI === "openrec://calendar" || state.redirectURI === "openrec-dev://calendar";
    if (!supportedCalendarCallback) throw new HTTPError(400, "Unsupported calendar callback URL");
    return await finishGoogleCalendarConnect(code, state, env);
  }
  const supportedCallback = state.redirectURI === "openrec://auth" || state.redirectURI === "openrec-dev://auth";
  if (!supportedCallback) throw new HTTPError(400, "Expired sign-in request");

  const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code,
      client_id: env.GOOGLE_CLIENT_ID,
      client_secret: env.GOOGLE_CLIENT_SECRET,
      redirect_uri: `${env.PUBLIC_BASE_URL}/v1/auth/google/callback`,
      grant_type: "authorization_code",
    }),
  });
  if (!tokenResponse.ok) throw new HTTPError(502, "Google token exchange failed");
  const tokens = (await tokenResponse.json()) as { access_token?: string; refresh_token?: string };
  if (!tokens.access_token) throw new HTTPError(502, "Google returned no access token");
  const profileResponse = await fetch("https://openidconnect.googleapis.com/v1/userinfo", {
    headers: { authorization: `Bearer ${tokens.access_token}` },
  });
  if (!profileResponse.ok) throw new HTTPError(502, "Google profile lookup failed");
  const profile = (await profileResponse.json()) as GoogleProfile;
  if (!profile.sub || !profile.email || profile.email_verified === false) throw new HTTPError(403, "A verified Google email is required");

  const now = new Date().toISOString();
  const existing = await env.DB.prepare("SELECT id FROM users WHERE google_sub = ?").bind(profile.sub).first<{ id: string }>();
  const userID = existing?.id ?? crypto.randomUUID();
  await env.DB.prepare(`
    INSERT INTO users (id, google_sub, email, name, avatar_url, google_refresh_token_cipher, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(google_sub) DO UPDATE SET
      email=excluded.email, name=excluded.name, avatar_url=excluded.avatar_url,
      google_refresh_token_cipher=COALESCE(excluded.google_refresh_token_cipher, users.google_refresh_token_cipher),
      updated_at=excluded.updated_at
  `).bind(
    userID, profile.sub, profile.email, profile.name ?? null, profile.picture ?? null,
    tokens.refresh_token ? await encryptSecret(tokens.refresh_token, env.AUTH_SECRET) : null,
    now, now
  ).run();

  const appCode = randomToken(32);
  await env.DB.prepare("INSERT INTO auth_codes (code_hash, user_id, expires_at, created_at) VALUES (?, ?, ?, ?)")
    .bind(await sha256(appCode), userID, new Date(Date.now() + 5 * 60_000).toISOString(), now).run();
  const callback = new URL(state.redirectURI);
  callback.searchParams.set("code", appCode);
  return new Response(null, { status: 302, headers: { location: callback.toString(), "cache-control": "no-store" } });
}

async function exchangeCode(request: Request, env: Env): Promise<Response> {
  const body = await request.json<{ code?: string }>();
  if (!body.code) throw new HTTPError(400, "Missing authorization code");
  const hash = await sha256(body.code);
  const row = await env.DB.prepare(`
    SELECT auth_codes.user_id, auth_codes.expires_at, users.email
    FROM auth_codes JOIN users ON users.id = auth_codes.user_id
    WHERE auth_codes.code_hash = ?
  `).bind(hash).first<{ user_id: string; expires_at: string; email: string }>();
  await env.DB.prepare("DELETE FROM auth_codes WHERE code_hash = ?").bind(hash).run();
  if (!row || Date.parse(row.expires_at) < Date.now()) throw new HTTPError(401, "Authorization code is invalid or expired");

  const token = randomToken(48);
  const now = new Date().toISOString();
  await env.DB.prepare("INSERT INTO sessions (token_hash, user_id, expires_at, created_at) VALUES (?, ?, ?, ?)")
    .bind(await sha256(token), row.user_id, new Date(Date.now() + 90 * 24 * 60 * 60_000).toISOString(), now).run();
  return json({ token, email: row.email });
}

async function authenticate(request: Request, env: Env): Promise<{ id: string; email: string }> {
  const header = request.headers.get("authorization") ?? "";
  if (!header.startsWith("Bearer ")) throw new HTTPError(401, "Missing session token");
  const row = await env.DB.prepare(`
    SELECT users.id, users.email, sessions.expires_at
    FROM sessions JOIN users ON users.id = sessions.user_id
    WHERE sessions.token_hash = ?
  `).bind(await sha256(header.slice(7))).first<{ id: string; email: string; expires_at: string }>();
  if (!row || Date.parse(row.expires_at) < Date.now()) throw new HTTPError(401, "Session expired");
  return { id: row.id, email: row.email };
}

async function revokeSession(request: Request, env: Env): Promise<Response> {
  const header = request.headers.get("authorization") ?? "";
  if (!header.startsWith("Bearer ")) throw new HTTPError(401, "Missing session token");
  await env.DB.prepare("DELETE FROM sessions WHERE token_hash = ?").bind(await sha256(header.slice(7))).run();
  return json({ ok: true });
}

async function putMeeting(request: Request, env: Env, user: { id: string }, id: string): Promise<Response> {
  const body = await request.json<MeetingPayload>();
  if (body.id.toLowerCase() !== id.toLowerCase()) throw new HTTPError(400, "Meeting ID mismatch");
  if (!body.startedAt || !body.endedAt || typeof body.transcript !== "string") throw new HTTPError(400, "Invalid meeting payload");
  const now = new Date().toISOString();
  const saved = await env.DB.prepare(`
    INSERT INTO meetings (
      id, user_id, started_at, ended_at, duration_seconds, call_app, call_title, transcript,
      title, summary, ai_notes, participants_json, action_items_json, decisions_json, created_at, updated_at
    )
    SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
    WHERE NOT EXISTS (
      SELECT 1 FROM meeting_deletions WHERE meeting_id = ? AND user_id = ?
    )
    ON CONFLICT(id, user_id) DO UPDATE SET
      started_at=excluded.started_at, ended_at=excluded.ended_at, duration_seconds=excluded.duration_seconds,
      call_app=excluded.call_app, call_title=excluded.call_title, transcript=excluded.transcript,
      title=excluded.title, summary=excluded.summary, ai_notes=excluded.ai_notes, participants_json=excluded.participants_json,
      action_items_json=excluded.action_items_json, decisions_json=excluded.decisions_json, updated_at=excluded.updated_at
    WHERE NOT EXISTS (
      SELECT 1 FROM meeting_deletions WHERE meeting_id = excluded.id AND user_id = excluded.user_id
    )
  `).bind(
    id.toLowerCase(), user.id, body.startedAt, body.endedAt, body.durationSeconds,
    body.callApp ?? null, body.callTitle ?? null, body.transcript,
    body.insights.title, body.insights.summary, body.insights.aiNotes ?? "", JSON.stringify(body.insights.participants),
    JSON.stringify(body.insights.actionItems), JSON.stringify(body.insights.decisions), now, now,
    id.toLowerCase(), user.id,
  ).run();
  if (changedRows(saved) === 0) throw new HTTPError(409, "Meeting is being deleted");
  return json({ ok: true, id: id.toLowerCase() });
}

async function putMedia(request: Request, env: Env, user: { id: string }, meetingID: string, kind: MediaKind): Promise<Response> {
  const normalizedMeetingID = meetingID.toLowerCase();
  await requireOwnedMeeting(env, user.id, normalizedMeetingID);
  if (!request.body) throw new HTTPError(400, "Missing media body");
  const definition = mediaDefinitions[kind];
  const previous = await currentMediaPointer(env, user.id, normalizedMeetingID, kind);
  const generation = crypto.randomUUID();
  const objectKey = managedMediaObjectKey(user.id, normalizedMeetingID, kind, generation);
  const completed = await env.RECORDINGS.put(objectKey, request.body, {
    httpMetadata: { contentType: definition.contentType },
    customMetadata: { openrecGeneration: generation },
  });
  const next: MediaPointer = {
    objectKey,
    generation,
    etag: completed.etag,
    version: completed.version,
    legacy: false,
  };
  const attached = await attachMediaPointer(env, user.id, normalizedMeetingID, kind, previous, next);
  if (!attached) {
    await env.RECORDINGS.delete(objectKey);
    throw new HTTPError(409, "Recording was replaced by a newer upload");
  }
  await deleteReplacedMediaObject(env, user.id, normalizedMeetingID, kind, previous, next);
  return json({ ok: true, objectKey, generation, etag: completed.etag, version: completed.version });
}

async function createMediaMultipartUpload(
  env: Env,
  user: { id: string },
  meetingID: string,
  kind: MediaKind,
): Promise<Response> {
  const normalizedMeetingID = meetingID.toLowerCase();
  await requireOwnedMeeting(env, user.id, normalizedMeetingID);
  const definition = mediaDefinitions[kind];
  const previous = await currentMediaPointer(env, user.id, normalizedMeetingID, kind);
  const generation = crypto.randomUUID();
  const objectKey = managedMediaObjectKey(user.id, normalizedMeetingID, kind, generation);
  let upload: R2MultipartUpload;
  try {
    upload = await env.RECORDINGS.createMultipartUpload(objectKey, {
      httpMetadata: { contentType: definition.contentType },
      customMetadata: { openrecGeneration: generation },
    });
  } catch (error) {
    throw mapMultipartError(error, "create");
  }

  const uploadToken = randomToken(32);
  const now = new Date().toISOString();
  try {
    const inserted = await env.DB.prepare(`
      INSERT INTO media_uploads (
        id, r2_upload_id, meeting_id, user_id, kind, object_key, generation,
        replaces_object_key, replaces_generation, status, created_at, updated_at
      )
      SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, 'uploading', ?, ?
      FROM meetings
      WHERE id = ? AND user_id = ?
        AND NOT EXISTS (
          SELECT 1 FROM meeting_deletions WHERE meeting_id = ? AND user_id = ?
        )
    `).bind(
      uploadToken, upload.uploadId, normalizedMeetingID, user.id, kind, objectKey, generation,
      previous?.objectKey ?? null, previous?.generation ?? null, now, now,
      normalizedMeetingID, user.id, normalizedMeetingID, user.id,
    ).run();
    if (changedRows(inserted) === 0) {
      await upload.abort();
      throw new HTTPError(409, "Meeting is being deleted");
    }
  } catch (error) {
    try { await upload.abort(); } catch { /* Best-effort cleanup after D1 failure. */ }
    throw error;
  }
  return json({ uploadId: uploadToken, generation });
}

async function putMediaMultipartPart(
  request: Request,
  env: Env,
  user: { id: string },
  meetingID: string,
  kind: MediaKind,
  uploadID: string,
  partNumber: number,
): Promise<Response> {
  if (!Number.isInteger(partNumber) || partNumber < 1 || partNumber > 10_000) {
    throw new HTTPError(400, "Part number must be between 1 and 10000");
  }
  if (!request.body) throw new HTTPError(400, "Missing multipart part body");
  const state = await requireOwnedMediaUpload(env, user.id, meetingID, kind, uploadID);
  if (state.status !== "uploading") {
    const existing = await storedUploadPart(env, state.id, partNumber);
    if (existing && (state.status === "completing" || state.status === "completed" || state.status === "attached")) {
      return json({ partNumber, etag: existing.etag });
    }
    throw new HTTPError(409, `Multipart upload is ${state.status}`);
  }

  let part: R2UploadedPart;
  try {
    const upload = env.RECORDINGS.resumeMultipartUpload(state.object_key, state.r2_upload_id);
    part = await upload.uploadPart(partNumber, request.body);
  } catch (error) {
    throw mapMultipartError(error, "part");
  }
  const stored = await env.DB.prepare(`
    INSERT INTO media_upload_parts (upload_id, part_number, etag, updated_at)
    SELECT ?, ?, ?, ?
    WHERE NOT EXISTS (
      SELECT 1 FROM meeting_deletions WHERE meeting_id = ? AND user_id = ?
    )
    ON CONFLICT(upload_id, part_number) DO UPDATE SET etag=excluded.etag, updated_at=excluded.updated_at
  `).bind(
    state.id, part.partNumber, part.etag, new Date().toISOString(), state.meeting_id, state.user_id,
  ).run();
  if (changedRows(stored) === 0) throw new HTTPError(409, "Meeting is being deleted");
  return json({ partNumber: part.partNumber, etag: part.etag });
}

async function completeMediaMultipartUpload(
  request: Request,
  env: Env,
  user: { id: string },
  meetingID: string,
  kind: MediaKind,
  uploadID: string,
): Promise<Response> {
  const parts = await readMultipartParts(request);
  let state = await requireOwnedMediaUpload(env, user.id, meetingID, kind, uploadID);
  if (state.status === "aborted") throw new HTTPError(409, "Multipart upload was aborted");
  await verifyStoredMultipartParts(env, state, parts);

  const completionPartsJSON = JSON.stringify(parts);
  if (state.completion_parts_json && state.completion_parts_json !== completionPartsJSON) {
    throw new HTTPError(409, "Multipart completion parts do not match the original completion request");
  }

  if (state.status === "uploading") {
    await env.DB.prepare(`
      UPDATE media_uploads SET status = 'completing', completion_parts_json = ?, updated_at = ?
      WHERE id = ? AND status = 'uploading'
    `).bind(completionPartsJSON, new Date().toISOString(), state.id).run();
    state = await requireOwnedMediaUpload(env, user.id, meetingID, kind, uploadID);
  }

  let completed = await completedUploadObject(env, state);
  if (!completed && state.status === "completing") {
    try {
      completed = await env.RECORDINGS.resumeMultipartUpload(state.object_key, state.r2_upload_id).complete(parts);
    } catch (error) {
      // R2 may have completed atomically while the Worker failed before updating D1.
      // This key is unique to this upload, so HEAD is authoritative reconciliation.
      completed = await env.RECORDINGS.head(state.object_key);
      if (!completed) throw mapMultipartError(error, "complete");
    }
    await env.DB.prepare(`
      UPDATE media_uploads
      SET status = 'completed', completed_etag = ?, completed_version = ?, updated_at = ?
      WHERE id = ? AND status IN ('completing', 'completed')
    `).bind(completed.etag, completed.version, new Date().toISOString(), state.id).run();
    state = await requireOwnedMediaUpload(env, user.id, meetingID, kind, uploadID);
  }

  if (!completed) completed = await completedUploadObject(env, state);
  if (!completed) throw new HTTPError(409, "Multipart upload is not ready to complete");

  const previous = await uploadPreviousPointer(env, state);
  const next: MediaPointer = {
    objectKey: state.object_key,
    generation: state.generation,
    etag: completed.etag,
    version: completed.version,
    legacy: false,
  };
  const attached = await attachMediaPointer(env, user.id, state.meeting_id, kind, previous, next, state.id);
  if (!attached) {
    const current = await currentMediaPointer(env, user.id, state.meeting_id, kind);
    if (!sameMediaPointer(current, next)) {
      await env.RECORDINGS.delete(state.object_key);
      await markUploadAborted(env, state.id);
      throw new HTTPError(409, "Recording was replaced by a newer upload");
    }
  }
  await deleteReplacedMediaObject(env, user.id, state.meeting_id, kind, previous, next);
  return json({
    ok: true,
    objectKey: state.object_key,
    generation: state.generation,
    etag: completed.etag,
    version: completed.version,
  });
}

async function abortMediaMultipartUpload(
  env: Env,
  user: { id: string },
  meetingID: string,
  kind: MediaKind,
  uploadID: string,
): Promise<Response> {
  const state = await requireOwnedMediaUpload(env, user.id, meetingID, kind, uploadID);
  if (state.status === "attached" || state.status === "aborted") return json({ ok: true });

  if (state.status === "uploading" || state.status === "completing") {
    try {
      await env.RECORDINGS.resumeMultipartUpload(state.object_key, state.r2_upload_id).abort();
    } catch (error) {
      const completed = await env.RECORDINGS.head(state.object_key);
      if (!completed && !isMissingMultipartError(error)) throw mapMultipartError(error, "abort");
    }
  }
  await env.RECORDINGS.delete(state.object_key);
  await markUploadAborted(env, state.id);
  return json({ ok: true });
}

async function deleteMedia(
  env: Env,
  user: { id: string },
  meetingID: string,
  kind: MediaKind,
): Promise<Response> {
  const normalizedMeetingID = meetingID.toLowerCase();
  await requireOwnedMeeting(env, user.id, normalizedMeetingID);
  const pointer = await currentMediaPointer(env, user.id, normalizedMeetingID, kind);
  if (!pointer) return json({ ok: true });
  requireValidMediaPointer(user.id, normalizedMeetingID, kind, pointer);

  // Generation-specific keys make it safe to delete this exact object before
  // the pointer CAS. If D1 then fails, a retry can finish clearing the pointer;
  // if a replacement won the race, its different key is never touched.
  await env.RECORDINGS.delete(pointer.objectKey);

  const column = mediaObjectKeyColumn(kind);
  const now = new Date().toISOString();
  let cleared = false;
  if (pointer.legacy) {
    const result = await env.DB.prepare(`
      UPDATE meetings SET ${column} = NULL, updated_at = ?
      WHERE id = ? AND user_id = ? AND ${column} = ?
        AND NOT EXISTS (
          SELECT 1 FROM meeting_media WHERE meeting_id = ? AND user_id = ? AND kind = ?
        )
    `).bind(now, normalizedMeetingID, user.id, pointer.objectKey, normalizedMeetingID, user.id, kind).run();
    cleared = changedRows(result) > 0;
  } else {
    const results = await env.DB.batch([
      env.DB.prepare(`
        DELETE FROM meeting_media
        WHERE meeting_id = ? AND user_id = ? AND kind = ?
          AND object_key = ? AND generation = ? AND etag = ? AND version = ?
      `).bind(
        normalizedMeetingID, user.id, kind,
        pointer.objectKey, pointer.generation, pointer.etag, pointer.version,
      ),
      env.DB.prepare(`
        UPDATE meetings SET ${column} = NULL, updated_at = ?
        WHERE id = ? AND user_id = ? AND ${column} = ?
          AND NOT EXISTS (
            SELECT 1 FROM meeting_media WHERE meeting_id = ? AND user_id = ? AND kind = ?
          )
      `).bind(now, normalizedMeetingID, user.id, pointer.objectKey, normalizedMeetingID, user.id, kind),
    ]);
    cleared = changedRows(results[0]) > 0;
  }
  if (!cleared) throw new HTTPError(409, "Recording changed while it was being deleted");
  return json({ ok: true });
}

async function deleteMeeting(env: Env, user: { id: string }, meetingID: string): Promise<Response> {
  const normalizedMeetingID = meetingID.toLowerCase();
  const exists = await env.DB.prepare("SELECT id FROM meetings WHERE id = ? AND user_id = ?")
    .bind(normalizedMeetingID, user.id).first<{ id: string }>();
  if (!exists) {
    await env.DB.prepare("DELETE FROM meeting_deletions WHERE meeting_id = ? AND user_id = ?")
      .bind(normalizedMeetingID, user.id).run();
    return json({ ok: true });
  }

  await env.DB.prepare(`
    INSERT INTO meeting_deletions (meeting_id, user_id, created_at)
    SELECT id, user_id, ? FROM meetings WHERE id = ? AND user_id = ?
    ON CONFLICT(meeting_id, user_id) DO NOTHING
  `).bind(new Date().toISOString(), normalizedMeetingID, user.id).run();

  const uploadResult = await env.DB.prepare(`
    SELECT id, r2_upload_id, meeting_id, user_id, kind, object_key, generation,
           replaces_object_key, replaces_generation, status, completion_parts_json,
           completed_etag, completed_version
    FROM media_uploads WHERE meeting_id = ? AND user_id = ?
  `).bind(normalizedMeetingID, user.id).all<MediaUploadRow>();
  const uploads = uploadResult.results;
  const objectKeys = new Set<string>();

  for (const upload of uploads) {
    requireValidUploadState(upload);
    objectKeys.add(upload.object_key);
    if (upload.status !== "uploading" && upload.status !== "completing") continue;
    try {
      await env.RECORDINGS.resumeMultipartUpload(upload.object_key, upload.r2_upload_id).abort();
    } catch (error) {
      const completed = await env.RECORDINGS.head(upload.object_key);
      if (!completed && !isMissingMultipartError(error)) throw mapMultipartError(error, "abort");
    }
  }

  for (const kind of ["screen", "audio"] as const) {
    const pointer = await currentMediaPointer(env, user.id, normalizedMeetingID, kind);
    if (!pointer) continue;
    requireValidMediaPointer(user.id, normalizedMeetingID, kind, pointer);
    objectKeys.add(pointer.objectKey);
  }

  for (const objectKey of objectKeys) await env.RECORDINGS.delete(objectKey);

  await env.DB.batch([
    env.DB.prepare(`
      DELETE FROM media_upload_parts
      WHERE upload_id IN (SELECT id FROM media_uploads WHERE meeting_id = ? AND user_id = ?)
    `).bind(normalizedMeetingID, user.id),
    env.DB.prepare("DELETE FROM media_uploads WHERE meeting_id = ? AND user_id = ?")
      .bind(normalizedMeetingID, user.id),
    env.DB.prepare("DELETE FROM meeting_media WHERE meeting_id = ? AND user_id = ?")
      .bind(normalizedMeetingID, user.id),
    env.DB.prepare("DELETE FROM meetings WHERE id = ? AND user_id = ?")
      .bind(normalizedMeetingID, user.id),
    env.DB.prepare("DELETE FROM meeting_deletions WHERE meeting_id = ? AND user_id = ?")
      .bind(normalizedMeetingID, user.id),
  ]);
  return json({ ok: true });
}

async function requireOwnedMeeting(env: Env, userID: string, meetingID: string): Promise<void> {
  const exists = await env.DB.prepare(`
    SELECT id FROM meetings WHERE id = ? AND user_id = ?
      AND NOT EXISTS (
        SELECT 1 FROM meeting_deletions WHERE meeting_id = ? AND user_id = ?
      )
  `).bind(meetingID.toLowerCase(), userID, meetingID.toLowerCase(), userID).first();
  if (!exists) throw new HTTPError(404, "Meeting not found");
}

function mediaObjectKeyColumn(kind: MediaKind): "screen_object_key" | "audio_object_key" {
  return kind === "screen" ? "screen_object_key" : "audio_object_key";
}

function mediaObjectKey(
  row: Pick<MeetingRow, "screen_object_key" | "audio_object_key">,
  kind: MediaKind,
): string | null {
  return kind === "screen" ? row.screen_object_key : row.audio_object_key;
}

function legacyManagedMediaObjectKey(userID: string, meetingID: string, kind: MediaKind): string {
  const definition = mediaDefinitions[kind];
  return `${userID}/meetings/${meetingID.toLowerCase()}/${kind}.${definition.extension}`;
}

function managedMediaObjectKey(userID: string, meetingID: string, kind: MediaKind, generation: string): string {
  const definition = mediaDefinitions[kind];
  return `${userID}/meetings/${meetingID.toLowerCase()}/${kind}/${generation}.${definition.extension}`;
}

async function currentMediaPointer(
  env: Env,
  userID: string,
  meetingID: string,
  kind: MediaKind,
): Promise<MediaPointer | null> {
  const modern = await env.DB.prepare(`
    SELECT object_key, generation, etag, version
    FROM meeting_media WHERE meeting_id = ? AND user_id = ? AND kind = ?
  `).bind(meetingID.toLowerCase(), userID, kind).first<MeetingMediaRow>();
  if (modern) {
    const pointer: MediaPointer = {
      objectKey: modern.object_key,
      generation: modern.generation,
      etag: modern.etag,
      version: modern.version,
      legacy: false,
    };
    requireValidMediaPointer(userID, meetingID, kind, pointer);
    return pointer;
  }

  const legacyRow = await meetingMediaKeys(env, userID, meetingID);
  const objectKey = legacyRow ? mediaObjectKey(legacyRow, kind) : null;
  if (!objectKey) return null;
  const object = await env.RECORDINGS.head(objectKey);
  return {
    objectKey,
    generation: `legacy-${await sha256(objectKey)}`,
    etag: object?.etag ?? "",
    version: object?.version ?? "",
    legacy: true,
  };
}

function requireValidMediaPointer(
  userID: string,
  meetingID: string,
  kind: MediaKind,
  pointer: MediaPointer,
): void {
  if (pointer.legacy) {
    if (pointer.objectKey !== legacyManagedMediaObjectKey(userID, meetingID, kind) || !pointer.generation.startsWith("legacy-")) {
      throw new HTTPError(409, "Stored recording pointer is invalid");
    }
    return;
  }
  const validGeneration = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(pointer.generation);
  if (
    !validGeneration || !pointer.etag || !pointer.version ||
    pointer.objectKey !== managedMediaObjectKey(userID, meetingID, kind, pointer.generation)
  ) {
    throw new HTTPError(409, "Stored recording pointer is invalid");
  }
}

function requireValidUploadState(state: MediaUploadRow): void {
  const pointer: MediaPointer = {
    objectKey: state.object_key,
    generation: state.generation,
    etag: state.completed_etag ?? "pending",
    version: state.completed_version ?? "pending",
    legacy: false,
  };
  requireValidMediaPointer(state.user_id, state.meeting_id, state.kind, pointer);
}

async function requireOwnedMediaUpload(
  env: Env,
  userID: string,
  meetingID: string,
  kind: MediaKind,
  uploadID: string,
): Promise<MediaUploadRow> {
  const state = await env.DB.prepare(`
    SELECT id, r2_upload_id, meeting_id, user_id, kind, object_key, generation,
           replaces_object_key, replaces_generation, status, completion_parts_json,
           completed_etag, completed_version
    FROM media_uploads
    WHERE id = ? AND user_id = ? AND meeting_id = ? AND kind = ?
      AND NOT EXISTS (
        SELECT 1 FROM meeting_deletions
        WHERE meeting_id = media_uploads.meeting_id AND user_id = media_uploads.user_id
      )
  `).bind(uploadID, userID, meetingID.toLowerCase(), kind).first<MediaUploadRow>();
  if (!state) throw new HTTPError(404, "Multipart upload not found");
  requireValidUploadState(state);
  return state;
}

async function storedUploadPart(
  env: Env,
  uploadID: string,
  partNumber: number,
): Promise<{ part_number: number; etag: string } | null> {
  return env.DB.prepare("SELECT part_number, etag FROM media_upload_parts WHERE upload_id = ? AND part_number = ?")
    .bind(uploadID, partNumber).first<{ part_number: number; etag: string }>();
}

async function verifyStoredMultipartParts(
  env: Env,
  state: MediaUploadRow,
  parts: R2UploadedPart[],
): Promise<void> {
  const result = await env.DB.prepare(`
    SELECT part_number, etag FROM media_upload_parts WHERE upload_id = ? ORDER BY part_number ASC
  `).bind(state.id).all<{ part_number: number; etag: string }>();
  if (
    result.results.length !== parts.length ||
    result.results.some((stored, index) => stored.part_number !== parts[index].partNumber || stored.etag !== parts[index].etag)
  ) {
    throw new HTTPError(409, "Multipart completion parts do not match the uploaded parts");
  }
}

async function completedUploadObject(env: Env, state: MediaUploadRow): Promise<R2Object | null> {
  if (state.status !== "completed" && state.status !== "attached") return null;
  if (!state.completed_etag || !state.completed_version) {
    throw new HTTPError(409, "Completed multipart upload metadata is missing");
  }
  const object = await env.RECORDINGS.head(state.object_key);
  if (!object) throw new HTTPError(409, "Completed multipart object is missing");
  if (object.etag !== state.completed_etag || object.version !== state.completed_version) {
    throw new HTTPError(409, "Completed multipart object version changed unexpectedly");
  }
  return object;
}

async function uploadPreviousPointer(env: Env, state: MediaUploadRow): Promise<MediaPointer | null> {
  if (!state.replaces_object_key || !state.replaces_generation) return null;
  const current = await currentMediaPointer(env, state.user_id, state.meeting_id, state.kind);
  if (current?.objectKey === state.replaces_object_key && current.generation === state.replaces_generation) return current;
  return {
    objectKey: state.replaces_object_key,
    generation: state.replaces_generation,
    etag: "",
    version: "",
    legacy: state.replaces_object_key === legacyManagedMediaObjectKey(state.user_id, state.meeting_id, state.kind),
  };
}

async function attachMediaPointer(
  env: Env,
  userID: string,
  meetingID: string,
  kind: MediaKind,
  previous: MediaPointer | null,
  next: MediaPointer,
  uploadID?: string,
): Promise<boolean> {
  requireValidMediaPointer(userID, meetingID, kind, next);
  const normalizedMeetingID = meetingID.toLowerCase();
  const previousObjectKey = previous?.objectKey ?? null;
  const previousGeneration = previous?.generation ?? null;
  const now = new Date().toISOString();
  const column = mediaObjectKeyColumn(kind);
  const statements = [
    env.DB.prepare(`
      INSERT INTO meeting_media (
        meeting_id, user_id, kind, object_key, generation, etag, version, created_at, updated_at
      )
      SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?
      FROM meetings
      WHERE id = ? AND user_id = ? AND ${column} IS ?
        AND NOT EXISTS (
          SELECT 1 FROM meeting_deletions WHERE meeting_id = ? AND user_id = ?
        )
      ON CONFLICT(meeting_id, user_id, kind) DO UPDATE SET
        object_key=excluded.object_key, generation=excluded.generation,
        etag=excluded.etag, version=excluded.version, updated_at=excluded.updated_at
      WHERE meeting_media.object_key IS ? AND meeting_media.generation IS ?
    `).bind(
      normalizedMeetingID, userID, kind, next.objectKey, next.generation, next.etag, next.version, now, now,
      normalizedMeetingID, userID, previousObjectKey, normalizedMeetingID, userID,
      previousObjectKey, previousGeneration,
    ),
    env.DB.prepare(`
      UPDATE meetings SET ${column} = ?, updated_at = ?
      WHERE id = ? AND user_id = ?
        AND EXISTS (
          SELECT 1 FROM meeting_media
          WHERE meeting_id = ? AND user_id = ? AND kind = ?
            AND object_key = ? AND generation = ? AND etag = ? AND version = ?
        )
    `).bind(
      next.objectKey, now, normalizedMeetingID, userID,
      normalizedMeetingID, userID, kind, next.objectKey, next.generation, next.etag, next.version,
    ),
  ];
  if (uploadID) {
    statements.push(env.DB.prepare(`
      UPDATE media_uploads
      SET status = 'attached', completed_etag = ?, completed_version = ?, updated_at = ?
      WHERE id = ? AND status IN ('completed', 'attached')
    `).bind(next.etag, next.version, now, uploadID));
  }
  const results = await env.DB.batch(statements);
  if (changedRows(results[0]) > 0) return true;
  return sameMediaPointer(await currentMediaPointer(env, userID, normalizedMeetingID, kind), next);
}

function sameMediaPointer(left: MediaPointer | null, right: MediaPointer): boolean {
  return Boolean(
    left && left.objectKey === right.objectKey && left.generation === right.generation &&
    left.etag === right.etag && left.version === right.version,
  );
}

async function deleteReplacedMediaObject(
  env: Env,
  userID: string,
  meetingID: string,
  kind: MediaKind,
  previous: MediaPointer | null,
  next: MediaPointer,
): Promise<void> {
  if (!previous || previous.objectKey === next.objectKey) return;
  requireValidMediaPointer(userID, meetingID, kind, previous);
  await env.RECORDINGS.delete(previous.objectKey);
}

async function markUploadAborted(env: Env, uploadID: string): Promise<void> {
  await env.DB.prepare(`
    UPDATE media_uploads SET status = 'aborted', updated_at = ? WHERE id = ? AND status != 'attached'
  `).bind(new Date().toISOString(), uploadID).run();
}

function changedRows(result: D1Result<unknown>): number {
  return typeof result.meta?.changes === "number" ? result.meta.changes : 0;
}

function isMissingMultipartError(error: unknown): boolean {
  const message = error instanceof Error ? error.message.toLowerCase() : String(error).toLowerCase();
  return message.includes("nosuchupload") || message.includes("does not exist") || message.includes("not found");
}

function mapMultipartError(error: unknown, operation: "create" | "part" | "complete" | "abort"): HTTPError {
  const message = error instanceof Error ? error.message.toLowerCase() : String(error).toLowerCase();
  if (isMissingMultipartError(error)) return new HTTPError(404, "Multipart upload not found");
  if (message.includes("abort") || message.includes("already complete") || message.includes("completed")) {
    return new HTTPError(409, "Multipart upload is no longer active");
  }
  if (
    message.includes("invalidpart") || message.includes("invalid part") || message.includes("etag") ||
    message.includes("too small") || message.includes("minimum") || message.includes("part number") ||
    message.includes("order") || message.includes("malformed")
  ) {
    return new HTTPError(400, "Multipart upload parts are invalid");
  }
  return new HTTPError(502, `R2 multipart ${operation} failed`);
}

function parseMediaKind(value: string): MediaKind {
  const normalized = value.toLowerCase();
  if (normalized === "screen" || normalized === "audio") return normalized;
  throw new HTTPError(400, "Unsupported media kind");
}

function decodeUploadID(encoded: string): string {
  try {
    const value = decodeURIComponent(encoded);
    if (!value || value.length > 2048) throw new Error("Invalid upload ID");
    return value;
  } catch {
    throw new HTTPError(400, "Invalid multipart upload ID");
  }
}

async function readMultipartParts(request: Request): Promise<R2UploadedPart[]> {
  let decoded: unknown;
  try {
    decoded = await request.json<unknown>();
  } catch {
    throw new HTTPError(400, "Multipart completion body must be valid JSON");
  }
  if (!decoded || typeof decoded !== "object" || !("parts" in decoded)) {
    throw new HTTPError(400, "Multipart completion requires a parts array");
  }
  const rawParts = (decoded as { parts: unknown }).parts;
  if (!Array.isArray(rawParts) || rawParts.length === 0 || rawParts.length > 10_000) {
    throw new HTTPError(400, "Multipart completion requires between 1 and 10000 parts");
  }

  const seen = new Set<number>();
  const parts = rawParts.map((rawPart) => {
    if (!rawPart || typeof rawPart !== "object") {
      throw new HTTPError(400, "Every multipart part must be an object");
    }
    const part = rawPart as { partNumber?: unknown; etag?: unknown };
    if (!Number.isInteger(part.partNumber) || (part.partNumber as number) < 1 || (part.partNumber as number) > 10_000) {
      throw new HTTPError(400, "Every multipart part number must be between 1 and 10000");
    }
    if (typeof part.etag !== "string" || part.etag.length === 0 || part.etag.length > 1024) {
      throw new HTTPError(400, "Every multipart part requires a valid etag");
    }
    const partNumber = part.partNumber as number;
    if (seen.has(partNumber)) throw new HTTPError(400, "Multipart part numbers must be unique");
    seen.add(partNumber);
    return { partNumber, etag: part.etag };
  });
  return parts.sort((left, right) => left.partNumber - right.partNumber);
}

async function listMeetings(url: URL, env: Env, user: { id: string }): Promise<Response> {
  const rawQuery = (url.searchParams.get("q") ?? "").trim();
  if (rawQuery.length > 200) throw new HTTPError(400, "Meeting search is limited to 200 characters");
  const rawOffset = url.searchParams.get("offset") ?? "0";
  if (!/^\d+$/.test(rawOffset)) throw new HTTPError(400, "Meeting offset must be a non-negative integer");
  const offset = Number(rawOffset);
  if (!Number.isSafeInteger(offset) || offset > 1_000_000) throw new HTTPError(400, "Meeting offset is out of range");
  const pageSize = 100;
  const result = await env.DB.prepare(`
    SELECT id, started_at, ended_at, duration_seconds, call_app, call_title, title, summary, ai_notes,
           participants_json, action_items_json, decisions_json,
           screen_object_key, audio_object_key, created_at, updated_at
    FROM meetings
    WHERE user_id = ?
      AND NOT EXISTS (
        SELECT 1 FROM meeting_deletions
        WHERE meeting_id = meetings.id AND user_id = meetings.user_id
      )
      AND (
        ? = '' OR instr(
          lower(
            coalesce(title, '') || ' ' || coalesce(call_title, '') || ' ' || coalesce(summary, '') || ' ' ||
            coalesce(ai_notes, '') || ' ' ||
            coalesce(transcript, '') || ' ' || coalesce(participants_json, '') || ' ' ||
            coalesce(action_items_json, '') || ' ' || coalesce(decisions_json, '')
          ),
          lower(?)
        ) > 0
      )
    ORDER BY started_at DESC, id DESC LIMIT ? OFFSET ?
  `).bind(user.id, rawQuery, rawQuery, pageSize + 1, offset).all<MeetingSummaryRow>();
  const hasMore = result.results.length > pageSize;
  const page = result.results.slice(0, pageSize);
  return json({ meetings: page.map(meetingSummary), nextOffset: hasMore ? offset + pageSize : null });
}

async function getMeeting(env: Env, user: { id: string }, meetingID: string): Promise<Response> {
  const row = await env.DB.prepare(`
    SELECT id, started_at, ended_at, duration_seconds, call_app, call_title, transcript,
           title, summary, ai_notes, participants_json, action_items_json, decisions_json,
           screen_object_key, audio_object_key, created_at, updated_at
    FROM meetings WHERE id = ? AND user_id = ?
      AND NOT EXISTS (
        SELECT 1 FROM meeting_deletions
        WHERE meeting_id = meetings.id AND user_id = meetings.user_id
      )
  `).bind(meetingID.toLowerCase(), user.id).first<MeetingRow>();
  if (!row) throw new HTTPError(404, "Meeting not found");

  const summary = meetingSummary(row);
  return json({
    meeting: {
      ...summary,
      transcript: row.transcript ?? "",
      media: {
        screenURL: row.screen_object_key ? `/v1/meetings/${row.id}/media/screen` : null,
        audioURL: row.audio_object_key ? `/v1/meetings/${row.id}/media/audio` : null,
      },
    },
  });
}

async function getMedia(
  request: Request,
  env: Env,
  user: { id: string },
  meetingID: string,
  kind: MediaKind,
): Promise<Response> {
  const normalizedMeetingID = meetingID.toLowerCase();
  await requireOwnedMeeting(env, user.id, normalizedMeetingID);
  const pointer = await currentMediaPointer(env, user.id, normalizedMeetingID, kind);
  if (!pointer) throw new HTTPError(404, `${kind === "screen" ? "Screen" : "Audio"} recording not found`);
  requireValidMediaPointer(user.id, normalizedMeetingID, kind, pointer);
  return serveMediaObject(request, env, pointer, normalizedMeetingID, kind);
}

async function createMediaAccessURL(
  url: URL,
  env: Env,
  user: { id: string },
  meetingID: string,
  kind: MediaKind,
): Promise<Response> {
  const normalizedMeetingID = meetingID.toLowerCase();
  const ttlSeconds = parseMediaAccessTTL(url.searchParams.get("ttl"));
  await requireOwnedMeeting(env, user.id, normalizedMeetingID);
  const pointer = await currentMediaPointer(env, user.id, normalizedMeetingID, kind);
  if (!pointer) throw new HTTPError(404, `${kind === "screen" ? "Screen" : "Audio"} recording not found`);
  requireValidMediaPointer(user.id, normalizedMeetingID, kind, pointer);
  const object = await env.RECORDINGS.head(pointer.objectKey);
  if (!object) throw new HTTPError(404, "Recording object not found");
  if (pointer.etag && (object.etag !== pointer.etag || object.version !== pointer.version)) {
    throw new HTTPError(409, "Stored recording version no longer matches R2");
  }
  const exactPointer: MediaPointer = {
    ...pointer,
    etag: object.etag,
    version: object.version,
  };

  const expiresAtMilliseconds = Date.now() + ttlSeconds * 1_000;
  const token = await signMediaAccessToken({
    v: 1,
    userID: user.id,
    meetingID: normalizedMeetingID,
    kind,
    objectKey: exactPointer.objectKey,
    generation: exactPointer.generation,
    etag: exactPointer.etag,
    version: exactPointer.version,
    expiresAt: expiresAtMilliseconds,
  }, env.AUTH_SECRET);
  const publicBaseURL = parsePublicBaseURL(env.PUBLIC_BASE_URL);
  const accessURL = new URL(`/v1/media/access/${encodeURIComponent(token)}`, publicBaseURL);
  return json({ url: accessURL.toString(), expiresAt: new Date(expiresAtMilliseconds).toISOString() });
}

async function getMediaWithAccessToken(request: Request, env: Env, token: string): Promise<Response> {
  const claims = await verifyMediaAccessToken(token, env.AUTH_SECRET);
  await requireOwnedMeeting(env, claims.userID, claims.meetingID);
  const pointer = await currentMediaPointer(env, claims.userID, claims.meetingID, claims.kind);
  const claimedPointer: MediaPointer = {
    objectKey: claims.objectKey,
    generation: claims.generation,
    etag: claims.etag,
    version: claims.version,
    legacy: claims.generation.startsWith("legacy-"),
  };
  if (!pointer || !sameMediaPointer(pointer, claimedPointer)) throw new HTTPError(404, "Recording not found");
  requireValidMediaPointer(claims.userID, claims.meetingID, claims.kind, claimedPointer);
  return serveMediaObject(request, env, claimedPointer, claims.meetingID, claims.kind);
}

async function meetingMediaKeys(
  env: Env,
  userID: string,
  meetingID: string,
): Promise<Pick<MeetingRow, "screen_object_key" | "audio_object_key"> | null> {
  return env.DB.prepare(`
    SELECT screen_object_key, audio_object_key
    FROM meetings WHERE id = ? AND user_id = ?
  `).bind(meetingID.toLowerCase(), userID).first<Pick<MeetingRow, "screen_object_key" | "audio_object_key">>();
}

async function serveMediaObject(
  request: Request,
  env: Env,
  pointer: MediaPointer,
  meetingID: string,
  kind: MediaKind,
): Promise<Response> {
  const head = await env.RECORDINGS.head(pointer.objectKey);
  if (!head) throw new HTTPError(404, "Recording object not found");
  if (head.etag !== pointer.etag || head.version !== pointer.version) {
    throw new HTTPError(404, "Recording object version not found");
  }
  const headers = mediaResponseHeaders(head, meetingID, kind);

  // RFC 9110 defines Range for GET. HEAD returns the metadata GET would have
  // returned without applying Range, so AVPlayer probes always receive 200.
  if (request.method === "HEAD") {
    headers.set("content-length", String(head.size));
    return new Response(null, { status: 200, headers });
  }

  const rangeHeader = request.headers.get("range");
  if (rangeHeader !== null) {
    const range = parseByteRange(rangeHeader, head.size);
    if (!range) {
      headers.set("content-range", `bytes */${head.size}`);
      headers.set("content-length", "0");
      return new Response(null, { status: 416, headers });
    }
    const object = await env.RECORDINGS.get(pointer.objectKey, { range });
    if (!object) throw new HTTPError(404, "Recording object not found");
    if (object.etag !== pointer.etag || object.version !== pointer.version) {
      throw new HTTPError(404, "Recording object version not found");
    }
    const rangeHeaders = mediaResponseHeaders(object, meetingID, kind);
    rangeHeaders.set("content-length", String(range.length));
    rangeHeaders.set("content-range", `bytes ${range.offset}-${range.offset + range.length - 1}/${head.size}`);
    return new Response(object.body, { status: 206, headers: rangeHeaders });
  }

  const object = await env.RECORDINGS.get(pointer.objectKey);
  if (!object) throw new HTTPError(404, "Recording object not found");
  if (object.etag !== pointer.etag || object.version !== pointer.version) {
    throw new HTTPError(404, "Recording object version not found");
  }
  const fullHeaders = mediaResponseHeaders(object, meetingID, kind);
  fullHeaders.set("content-length", String(head.size));
  return new Response(object.body, { status: 200, headers: fullHeaders });
}

function mediaResponseHeaders(object: R2Object, meetingID: string, kind: MediaKind): Headers {
  const headers = new Headers();
  object.writeHttpMetadata(headers);
  if (!headers.has("content-type")) headers.set("content-type", mediaDefinitions[kind].contentType);
  headers.set("accept-ranges", "bytes");
  headers.set("cache-control", "private, no-store");
  headers.set("content-disposition", `inline; filename="${meetingID.toLowerCase()}-${kind}.${mediaDefinitions[kind].extension}"`);
  headers.set("etag", object.httpEtag);
  headers.set("last-modified", object.uploaded.toUTCString());
  headers.set("x-content-type-options", "nosniff");
  return headers;
}

function meetingSummary(row: MeetingSummaryRow) {
  return {
    id: row.id,
    startedAt: row.started_at,
    endedAt: row.ended_at,
    durationSeconds: row.duration_seconds,
    callApp: row.call_app,
    callTitle: row.call_title,
    insights: {
      title: row.title,
      summary: row.summary,
      aiNotes: row.ai_notes ?? "",
      participants: parseJSONArray<string>(row.participants_json, "participants"),
      actionItems: parseJSONArray<unknown>(row.action_items_json, "action items"),
      decisions: parseJSONArray<string>(row.decisions_json, "decisions"),
    },
    hasScreenRecording: row.screen_object_key !== null,
    hasAudioRecording: row.audio_object_key !== null,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function parseJSONArray<T>(value: string, field: string): T[] {
  try {
    const parsed = JSON.parse(value) as unknown;
    if (Array.isArray(parsed)) return parsed as T[];
  } catch {
    // Fall through to a consistent server error for corrupt stored metadata.
  }
  throw new HTTPError(500, `Stored meeting ${field} are invalid`);
}

function parseByteRange(value: string, objectSize: number): { offset: number; length: number } | null {
  if (objectSize <= 0 || value.includes(",")) return null;
  const match = /^bytes=(\d*)-(\d*)$/i.exec(value.trim());
  if (!match || (!match[1] && !match[2])) return null;
  if (!match[1]) {
    const suffix = Number(match[2]);
    if (!Number.isSafeInteger(suffix) || suffix <= 0) return null;
    const length = Math.min(suffix, objectSize);
    return { offset: objectSize - length, length };
  }
  const offset = Number(match[1]);
  if (!Number.isSafeInteger(offset) || offset >= objectSize) return null;
  const requestedEnd = match[2] ? Number(match[2]) : objectSize - 1;
  if (!Number.isSafeInteger(requestedEnd) || requestedEnd < offset) return null;
  const end = Math.min(requestedEnd, objectSize - 1);
  return { offset, length: end - offset + 1 };
}

function parseMediaAccessTTL(value: string | null): number {
  if (value === null || value === "") return defaultMediaAccessTTLSeconds;
  if (!/^\d+$/.test(value)) throw new HTTPError(400, "Media access TTL must be an integer number of seconds");
  const ttl = Number(value);
  if (!Number.isSafeInteger(ttl) || ttl < 60 || ttl > maximumMediaAccessTTLSeconds) {
    throw new HTTPError(400, `Media access TTL must be between 60 and ${maximumMediaAccessTTLSeconds} seconds`);
  }
  return ttl;
}

function parsePublicBaseURL(value: string): URL {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new HTTPError(500, "PUBLIC_BASE_URL is not configured correctly");
  }
  const localHTTP = url.protocol === "http:" && (url.hostname === "localhost" || url.hostname === "127.0.0.1");
  if (url.protocol !== "https:" && !localHTTP) {
    throw new HTTPError(500, "PUBLIC_BASE_URL must use HTTPS");
  }
  return url;
}

function decodeAccessToken(value: string): string {
  try {
    const decoded = decodeURIComponent(value);
    if (!decoded || decoded.length > 8_192) throw new Error("Invalid access token");
    return decoded;
  } catch {
    throw new HTTPError(401, "Media access URL is invalid or expired");
  }
}

async function signMediaAccessToken(claims: MediaAccessClaims, secret: string): Promise<string> {
  if (!secret) throw new HTTPError(500, "AUTH_SECRET is not configured");
  const payload = base64url(new TextEncoder().encode(JSON.stringify(claims)));
  const signature = await signMediaAccessPayload(payload, secret);
  return `${payload}.${signature}`;
}

async function verifyMediaAccessToken(token: string, secret: string): Promise<MediaAccessClaims> {
  if (!secret) throw new HTTPError(500, "AUTH_SECRET is not configured");
  const pieces = token.split(".");
  if (pieces.length !== 2 || !pieces[0] || !pieces[1]) {
    throw new HTTPError(401, "Media access URL is invalid or expired");
  }
  const [payload, signature] = pieces;
  let valid = false;
  try {
    const key = await mediaAccessHMACKey(secret, ["verify"]);
    valid = await crypto.subtle.verify(
      "HMAC",
      key,
      fromBase64url(signature),
      new TextEncoder().encode(`${mediaAccessTokenContext}.${payload}`),
    );
  } catch {
    valid = false;
  }
  if (!valid) throw new HTTPError(401, "Media access URL is invalid or expired");

  let decoded: unknown;
  try {
    decoded = JSON.parse(new TextDecoder().decode(fromBase64url(payload))) as unknown;
  } catch {
    throw new HTTPError(401, "Media access URL is invalid or expired");
  }
  const claims = parseMediaAccessClaims(decoded);
  const now = Date.now();
  if (claims.expiresAt <= now || claims.expiresAt > now + maximumMediaAccessTTLSeconds * 1_000 + 5_000) {
    throw new HTTPError(401, "Media access URL is invalid or expired");
  }
  return claims;
}

function parseMediaAccessClaims(value: unknown): MediaAccessClaims {
  if (!value || typeof value !== "object") throw new HTTPError(401, "Media access URL is invalid or expired");
  const claims = value as Partial<MediaAccessClaims>;
  const validUserID = typeof claims.userID === "string" && claims.userID.length > 0 && claims.userID.length <= 128;
  const validMeetingID = typeof claims.meetingID === "string" && /^[0-9a-f-]+$/.test(claims.meetingID) && claims.meetingID.length <= 128;
  const validKind = claims.kind === "screen" || claims.kind === "audio";
  const validObjectKey = typeof claims.objectKey === "string" && claims.objectKey.length > 0 && claims.objectKey.length <= 1_024;
  const validGeneration = typeof claims.generation === "string" && claims.generation.length > 0 && claims.generation.length <= 128;
  const validETag = typeof claims.etag === "string" && claims.etag.length > 0 && claims.etag.length <= 1_024;
  const validVersion = typeof claims.version === "string" && claims.version.length > 0 && claims.version.length <= 1_024;
  const validExpiry = typeof claims.expiresAt === "number" && Number.isSafeInteger(claims.expiresAt);
  if (
    claims.v !== 1 || !validUserID || !validMeetingID || !validKind || !validObjectKey ||
    !validGeneration || !validETag || !validVersion || !validExpiry
  ) {
    throw new HTTPError(401, "Media access URL is invalid or expired");
  }
  return claims as MediaAccessClaims;
}

async function signMediaAccessPayload(payload: string, secret: string): Promise<string> {
  const key = await mediaAccessHMACKey(secret, ["sign"]);
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`${mediaAccessTokenContext}.${payload}`),
  );
  return base64url(new Uint8Array(signature));
}

async function mediaAccessHMACKey(secret: string, usages: Array<"sign" | "verify">): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    usages,
  );
}

/// Fetch, dedupe, and time-sort events from every calendar the user keeps
/// ticked in Google Calendar (falling back to "primary"), for the given window.
/// Fetch events for one granted Google account across every calendar in its
/// list. Returns [] on any per-account failure so one dead connection cannot
/// take down the merged view.
async function fetchEventsForConnection(
  env: Env,
  refreshTokenCipher: string,
  timeMin: Date,
  timeMax: Date,
): Promise<GoogleCalendarEvent[]> {
  try {
    const refreshToken = await decryptSecret(refreshTokenCipher, env.AUTH_SECRET);
    const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: env.GOOGLE_CLIENT_ID,
        client_secret: env.GOOGLE_CLIENT_SECRET,
        refresh_token: refreshToken,
        grant_type: "refresh_token",
      }),
    });
    if (!tokenResponse.ok) return [];
    const token = (await tokenResponse.json()) as { access_token?: string };
    if (!token.access_token) return [];

    // Read every calendar in the account's list, not just "primary" —
    // secondary, shared, and subscribed calendars all count. Primary and
    // Google-"selected" calendars go first so the cap trims the least-relevant.
    let calendarIDs = ["primary"];
    const listURL = new URL("https://www.googleapis.com/calendar/v3/users/me/calendarList");
    listURL.searchParams.set("maxResults", "100");
    listURL.searchParams.set("fields", "items(id,primary,selected,deleted)");
    const listResponse = await fetch(listURL, { headers: { authorization: `Bearer ${token.access_token}` } });
    if (listResponse.ok) {
      const list = (await listResponse.json()) as { items?: Array<{ id?: string; primary?: boolean; selected?: boolean; deleted?: boolean }> };
      const rank = (calendar: { primary?: boolean; selected?: boolean }) =>
        calendar.primary ? 0 : calendar.selected ? 1 : 2;
      const chosen = (list.items ?? [])
        .filter((calendar) => calendar.id && !calendar.deleted)
        .sort((a, b) => rank(a) - rank(b))
        .map((calendar) => calendar.id!)
        .slice(0, 10);
      if (chosen.length > 0) calendarIDs = chosen;
    }

    const responses = await Promise.all(calendarIDs.map(async (calendarID) => {
      const calendarURL = new URL(`https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(calendarID)}/events`);
      calendarURL.searchParams.set("timeMin", timeMin.toISOString());
      calendarURL.searchParams.set("timeMax", timeMax.toISOString());
      calendarURL.searchParams.set("singleEvents", "true");
      calendarURL.searchParams.set("orderBy", "startTime");
      calendarURL.searchParams.set("maxResults", "30");
      const eventsResponse = await fetch(calendarURL, { headers: { authorization: `Bearer ${token.access_token}` } });
      // A single unreadable calendar (revoked share, permissions) must not
      // break calendar context for the rest.
      if (!eventsResponse.ok) return [] as GoogleCalendarEvent[];
      const result = (await eventsResponse.json()) as { items?: GoogleCalendarEvent[] };
      return result.items ?? [];
    }));
    return responses.flat();
  } catch {
    return [];
  }
}

async function fetchGoogleCalendarEvents(
  env: Env,
  user: { id: string },
  timeMin: Date,
  timeMax: Date,
): Promise<GoogleCalendarEvent[]> {
  const connections = await env.DB.prepare(
    "SELECT refresh_token_cipher FROM calendar_connections WHERE user_id = ? ORDER BY created_at"
  ).bind(user.id).all<{ refresh_token_cipher: string }>();
  let ciphers = (connections.results ?? []).map((row) => row.refresh_token_cipher);

  if (ciphers.length === 0) {
    // Legacy fallback from before dedicated calendar connections existed.
    const record = await env.DB.prepare("SELECT google_refresh_token_cipher FROM users WHERE id = ?")
      .bind(user.id).first<{ google_refresh_token_cipher: string | null }>();
    if (!record?.google_refresh_token_cipher) throw new HTTPError(409, "Connect Google Calendar to enable calendar context");
    ciphers = [record.google_refresh_token_cipher];
  }

  const perAccount = await Promise.all(
    ciphers.slice(0, 5).map((cipher) => fetchEventsForConnection(env, cipher, timeMin, timeMax)),
  );
  const seenEventIDs = new Set<string>();
  return perAccount
    .flat()
    .filter((event) => event.status !== "cancelled" && event.start?.dateTime && event.end?.dateTime)
    // The same meeting shows up on every calendar the user was invited
    // through; keep the first copy only.
    .filter((event) => {
      if (!event.id) return true;
      if (seenEventIDs.has(event.id)) return false;
      seenEventIDs.add(event.id);
      return true;
    })
    .sort((a, b) => Date.parse(a.start!.dateTime!) - Date.parse(b.start!.dateTime!));
}

function calendarEventPayload(event: GoogleCalendarEvent) {
  return {
    id: event.id,
    title: event.summary ?? "Calendar call",
    startsAt: event.start?.dateTime,
    endsAt: event.end?.dateTime,
    participants: (event.attendees ?? [])
      .filter((attendee) => attendee.responseStatus !== "declined")
      .map((attendee) => attendee.displayName || attendee.email)
      .filter(Boolean),
  };
}

async function currentCalendarEvent(env: Env, user: { id: string }): Promise<Response> {
  const now = Date.now();
  const events = await fetchGoogleCalendarEvents(
    env,
    user,
    new Date(now - 30 * 60_000),
    new Date(now + 60 * 60_000),
  );
  const active = events.find((event) => Date.parse(event.start!.dateTime!) <= now && Date.parse(event.end!.dateTime!) >= now);
  const upcoming = events.find((event) => {
    const start = Date.parse(event.start!.dateTime!);
    return start > now && start <= now + 15 * 60_000;
  });
  const event = active ?? upcoming;
  if (!event) return json({ event: null });
  return json({ event: calendarEventPayload(event) });
}

/// Ongoing and upcoming events for the Meetings window's "Coming up" list.
async function upcomingCalendarEvents(url: URL, env: Env, user: { id: string }): Promise<Response> {
  const days = Math.max(1, Math.min(31, Number(url.searchParams.get("days")) || 7));
  const now = Date.now();
  const events = await fetchGoogleCalendarEvents(
    env,
    user,
    new Date(now),
    new Date(now + days * 24 * 60 * 60_000),
  );
  return json({ events: events.slice(0, 30).map(calendarEventPayload) });
}

interface GoogleCalendarEvent {
  id: string;
  status?: string;
  summary?: string;
  start?: { dateTime?: string };
  end?: { dateTime?: string };
  attendees?: Array<{ email?: string; displayName?: string; responseStatus?: string }>;
}

class HTTPError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

function json(value: unknown, status = 200): Response {
  return Response.json(value, { status, headers: { "cache-control": "no-store" } });
}

function randomToken(bytes: number): string {
  const value = crypto.getRandomValues(new Uint8Array(bytes));
  return base64url(value);
}

async function sha256(value: string): Promise<string> {
  return base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))));
}

async function signState(payload: object, secret: string): Promise<string> {
  if (!secret) throw new HTTPError(500, "AUTH_SECRET is not configured");
  const encoded = base64url(new TextEncoder().encode(JSON.stringify(payload)));
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(encoded));
  return `${encoded}.${base64url(new Uint8Array(signature))}`;
}

async function verifyState(
  value: string,
  secret: string,
): Promise<{ redirectURI: string; expires: number; purpose?: string; userID?: string }> {
  const [payload, signature] = value.split(".");
  if (!payload || !signature) throw new HTTPError(400, "Invalid OAuth state");
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  const valid = await crypto.subtle.verify("HMAC", key, fromBase64url(signature), new TextEncoder().encode(payload));
  if (!valid) throw new HTTPError(400, "Invalid OAuth state signature");
  return JSON.parse(new TextDecoder().decode(fromBase64url(payload))) as {
    redirectURI: string;
    expires: number;
    purpose?: string;
    userID?: string;
  };
}

function base64url(value: Uint8Array): string {
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function fromBase64url(value: string): Uint8Array {
  const padded = value.replaceAll("-", "+").replaceAll("_", "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  const binary = atob(padded);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

async function encryptionKey(secret: string): Promise<CryptoKey> {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(secret));
  return crypto.subtle.importKey("raw", bytes, "AES-GCM", false, ["encrypt", "decrypt"]);
}

async function encryptSecret(value: string, secret: string): Promise<string> {
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const cipher = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, await encryptionKey(secret), new TextEncoder().encode(value)));
  const combined = new Uint8Array(nonce.length + cipher.length);
  combined.set(nonce);
  combined.set(cipher, nonce.length);
  return base64url(combined);
}

async function decryptSecret(value: string, secret: string): Promise<string> {
  const combined = fromBase64url(value);
  const nonce = combined.slice(0, 12);
  const cipher = combined.slice(12);
  const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: nonce }, await encryptionKey(secret), cipher);
  return new TextDecoder().decode(plain);
}
