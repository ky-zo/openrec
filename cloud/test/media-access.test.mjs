import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import ts from "typescript";

const here = dirname(fileURLToPath(import.meta.url));
const sourcePath = join(here, "..", "src", "index.ts");
let temporaryDirectory;
let worker;

before(async () => {
  temporaryDirectory = await mkdtemp(join(tmpdir(), "openrec-cloud-test-"));
  const source = await readFile(sourcePath, "utf8");
  const transpiled = ts.transpileModule(source, {
    compilerOptions: {
      target: ts.ScriptTarget.ES2022,
      module: ts.ModuleKind.ESNext,
    },
  });
  const modulePath = join(temporaryDirectory, "worker.mjs");
  await writeFile(modulePath, transpiled.outputText, "utf8");
  worker = (await import(pathToFileURL(modulePath).href)).default;
});

after(async () => {
  if (temporaryDirectory) await rm(temporaryDirectory, { recursive: true, force: true });
});

test("signed media URLs are owner-scoped, ranged, revocable, and bearerless", async () => {
  const ownerID = "11111111-1111-4111-8111-111111111111";
  const otherUserID = "22222222-2222-4222-8222-222222222222";
  const meetingID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  const generation = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa";
  const objectKey = `${ownerID}/meetings/${meetingID}/screen/${generation}.mp4`;
  const objectVersion = versionForKey(objectKey);
  const ownerToken = "owner-session-token";
  const otherToken = "other-session-token";
  const media = new TextEncoder().encode("0123456789");
  const env = await testEnvironment({
    sessions: new Map([
      [await sha256(ownerToken), { id: ownerID, email: "owner@example.com" }],
      [await sha256(otherToken), { id: otherUserID, email: "other@example.com" }],
    ]),
    meetings: new Map([
      [`${ownerID}:${meetingID}`, { screen_object_key: objectKey, audio_object_key: null }],
    ]),
    pointers: new Map([
      [`${ownerID}:${meetingID}:screen`, {
        object_key: objectKey,
        generation,
        etag: "test-etag",
        version: objectVersion,
      }],
    ]),
    objects: new Map([[objectKey, media]]),
  });

  const issued = await worker.fetch(new Request(
    `https://api.example.test/v1/meetings/${meetingID}/media/screen/access?ttl=600`,
    { headers: { authorization: `Bearer ${ownerToken}` } },
  ), env);
  assert.equal(issued.status, 200);
  const access = await issued.json();
  assert.match(access.url, /^http:\/\/localhost\/v1\/media\/access\//);
  assert.ok(Date.parse(access.expiresAt) > Date.now());

  const full = await worker.fetch(new Request(access.url), env);
  assert.equal(full.status, 200);
  assert.equal(full.headers.get("accept-ranges"), "bytes");
  assert.equal(full.headers.get("content-type"), "video/mp4");
  assert.equal(await full.text(), "0123456789");

  const range = await worker.fetch(new Request(access.url, { headers: { range: "bytes=2-5" } }), env);
  assert.equal(range.status, 206);
  assert.equal(range.headers.get("content-range"), "bytes 2-5/10");
  assert.equal(range.headers.get("content-length"), "4");
  assert.equal(await range.text(), "2345");

  const head = await worker.fetch(new Request(access.url, { method: "HEAD" }), env);
  assert.equal(head.status, 200);
  assert.equal(head.headers.get("content-length"), "10");
  assert.equal(await head.text(), "");

  const rangedHead = await worker.fetch(new Request(access.url, {
    method: "HEAD",
    headers: { range: "bytes=2-5" },
  }), env);
  assert.equal(rangedHead.status, 200);
  assert.equal(rangedHead.headers.get("content-length"), "10");
  assert.equal(rangedHead.headers.get("content-range"), null);

  const unsatisfiable = await worker.fetch(new Request(access.url, { headers: { range: "bytes=99-100" } }), env);
  assert.equal(unsatisfiable.status, 416);
  assert.equal(unsatisfiable.headers.get("content-range"), "bytes */10");

  const tamperedURL = new URL(access.url);
  const token = tamperedURL.pathname.split("/").at(-1);
  const [payload, signature] = token.split(".");
  const replacement = signature[0] === "A" ? "B" : "A";
  tamperedURL.pathname = `/v1/media/access/${payload}.${replacement}${signature.slice(1)}`;
  const tampered = await worker.fetch(new Request(tamperedURL), env);
  assert.equal(tampered.status, 401);

  const crossUser = await worker.fetch(new Request(
    `https://api.example.test/v1/meetings/${meetingID}/media/screen/access`,
    { headers: { authorization: `Bearer ${otherToken}` } },
  ), env);
  assert.equal(crossUser.status, 404);

  const removed = await worker.fetch(new Request(
    `https://api.example.test/v1/meetings/${meetingID}/media/screen`,
    { method: "DELETE", headers: { authorization: `Bearer ${ownerToken}` } },
  ), env);
  assert.equal(removed.status, 200);
  assert.deepEqual(await removed.json(), { ok: true });
  assert.equal(env.RECORDINGS.objects.has(objectKey), false);
  assert.equal(env.DB.meetings.get(`${ownerID}:${meetingID}`).screen_object_key, null);

  const revoked = await worker.fetch(new Request(access.url), env);
  assert.equal(revoked.status, 404);

  const removedAgain = await worker.fetch(new Request(
    `https://api.example.test/v1/meetings/${meetingID}/media/screen`,
    { method: "DELETE", headers: { authorization: `Bearer ${ownerToken}` } },
  ), env);
  assert.equal(removedAgain.status, 200);
  assert.deepEqual(await removedAgain.json(), { ok: true });
});

test("replacing and reuploading media never revives an old signed URL", async () => {
  const userID = "44444444-4444-4444-8444-444444444444";
  const meetingID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
  const firstGeneration = "11111111-aaaa-4111-8111-111111111111";
  const secondGeneration = "22222222-bbbb-4222-8222-222222222222";
  const thirdGeneration = "33333333-cccc-4333-8333-333333333333";
  const keyFor = (generation) => `${userID}/meetings/${meetingID}/screen/${generation}.mp4`;
  const firstKey = keyFor(firstGeneration);
  const token = "replacement-session";
  const meetings = new Map([[`${userID}:${meetingID}`, { screen_object_key: firstKey, audio_object_key: null }]]);
  const pointers = new Map([[`${userID}:${meetingID}:screen`, {
    object_key: firstKey,
    generation: firstGeneration,
    etag: "test-etag",
    version: versionForKey(firstKey),
  }]]);
  const objects = new Map([[firstKey, new TextEncoder().encode("first")]]);
  const env = await testEnvironment({
    sessions: new Map([[await sha256(token), { id: userID, email: "user@example.com" }]]),
    meetings,
    pointers,
    objects,
  });

  const issued = await worker.fetch(new Request(
    `https://api.example.test/v1/meetings/${meetingID}/media/screen/access`,
    { headers: { authorization: `Bearer ${token}` } },
  ), env);
  const oldURL = (await issued.json()).url;

  for (const [generation, content] of [[secondGeneration, "second"], [thirdGeneration, "third"]]) {
    const key = keyFor(generation);
    meetings.get(`${userID}:${meetingID}`).screen_object_key = key;
    pointers.set(`${userID}:${meetingID}:screen`, {
      object_key: key,
      generation,
      etag: "test-etag",
      version: versionForKey(key),
    });
    objects.set(key, new TextEncoder().encode(content));
    assert.equal((await worker.fetch(new Request(oldURL), env)).status, 404);
  }
});

test("media deletion is CAS-safe when a replacement wins the race", async () => {
  const userID = "55555555-5555-4555-8555-555555555555";
  const meetingID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
  const oldGeneration = "aaaaaaaa-dddd-4aaa-8aaa-aaaaaaaaaaaa";
  const newGeneration = "bbbbbbbb-dddd-4bbb-8bbb-bbbbbbbbbbbb";
  const oldKey = `${userID}/meetings/${meetingID}/screen/${oldGeneration}.mp4`;
  const newKey = `${userID}/meetings/${meetingID}/screen/${newGeneration}.mp4`;
  const token = "delete-race-session";
  const meetings = new Map([[`${userID}:${meetingID}`, { screen_object_key: oldKey, audio_object_key: null }]]);
  const pointers = new Map([[`${userID}:${meetingID}:screen`, {
    object_key: oldKey,
    generation: oldGeneration,
    etag: "test-etag",
    version: versionForKey(oldKey),
  }]]);
  const objects = new Map([
    [oldKey, new TextEncoder().encode("old")],
    [newKey, new TextEncoder().encode("new")],
  ]);
  const env = await testEnvironment({
    sessions: new Map([[await sha256(token), { id: userID, email: "user@example.com" }]]),
    meetings,
    pointers,
    objects,
  });
  env.DB.beforeBatch = () => {
    meetings.get(`${userID}:${meetingID}`).screen_object_key = newKey;
    pointers.set(`${userID}:${meetingID}:screen`, {
      object_key: newKey,
      generation: newGeneration,
      etag: "test-etag",
      version: versionForKey(newKey),
    });
  };

  const response = await worker.fetch(new Request(
    `https://api.example.test/v1/meetings/${meetingID}/media/screen`,
    { method: "DELETE", headers: { authorization: `Bearer ${token}` } },
  ), env);
  assert.equal(response.status, 409);
  assert.equal(objects.has(oldKey), false);
  assert.equal(objects.has(newKey), true);
  assert.equal(pointers.get(`${userID}:${meetingID}:screen`).object_key, newKey);
});

test("provisional meeting deletion is owner-scoped and removes exact media/state", async () => {
  const ownerID = "66666666-6666-4666-8666-666666666666";
  const otherID = "77777777-7777-4777-8777-777777777777";
  const meetingID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const generation = "cccccccc-eeee-4ccc-8ccc-cccccccccccc";
  const objectKey = `${ownerID}/meetings/${meetingID}/screen/${generation}.mp4`;
  const ownerToken = "meeting-owner-session";
  const otherToken = "meeting-other-session";
  const meetings = new Map([[`${ownerID}:${meetingID}`, { screen_object_key: objectKey, audio_object_key: null }]]);
  const pointers = new Map([[`${ownerID}:${meetingID}:screen`, {
    object_key: objectKey,
    generation,
    etag: "test-etag",
    version: versionForKey(objectKey),
  }]]);
  const objects = new Map([[objectKey, new TextEncoder().encode("recording")]]);
  const env = await testEnvironment({
    sessions: new Map([
      [await sha256(ownerToken), { id: ownerID, email: "owner@example.com" }],
      [await sha256(otherToken), { id: otherID, email: "other@example.com" }],
    ]),
    meetings,
    pointers,
    objects,
  });

  const crossUser = await worker.fetch(new Request(
    `https://api.example.test/v1/meetings/${meetingID}`,
    { method: "DELETE", headers: { authorization: `Bearer ${otherToken}` } },
  ), env);
  assert.equal(crossUser.status, 200);
  assert.deepEqual(await crossUser.json(), { ok: true });
  assert.equal(meetings.has(`${ownerID}:${meetingID}`), true);
  assert.equal(objects.has(objectKey), true);

  const owner = await worker.fetch(new Request(
    `https://api.example.test/v1/meetings/${meetingID}`,
    { method: "DELETE", headers: { authorization: `Bearer ${ownerToken}` } },
  ), env);
  assert.equal(owner.status, 200);
  assert.deepEqual(await owner.json(), { ok: true });
  assert.equal(meetings.has(`${ownerID}:${meetingID}`), false);
  assert.equal(pointers.has(`${ownerID}:${meetingID}:screen`), false);
  assert.equal(objects.has(objectKey), false);

  const repeated = await worker.fetch(new Request(
    `https://api.example.test/v1/meetings/${meetingID}`,
    { method: "DELETE", headers: { authorization: `Bearer ${ownerToken}` } },
  ), env);
  assert.equal(repeated.status, 200);
  assert.deepEqual(await repeated.json(), { ok: true });
});

test("multipart completion reconciles R2 success after a D1 attachment failure", async () => {
  const userID = "88888888-8888-4888-8888-888888888888";
  const meetingID = "ffffffff-ffff-4fff-8fff-ffffffffffff";
  const token = "multipart-retry-session";
  const meetings = new Map([[`${userID}:${meetingID}`, { screen_object_key: null, audio_object_key: null }]]);
  const env = await testEnvironment({
    sessions: new Map([[await sha256(token), { id: userID, email: "user@example.com" }]]),
    meetings,
    pointers: new Map(),
    objects: new Map(),
  });
  const authorization = { authorization: `Bearer ${token}` };

  const created = await worker.fetch(new Request(
    `https://api.example.test/v1/meetings/${meetingID}/media/screen/multipart`,
    { method: "POST", headers: authorization },
  ), env);
  assert.equal(created.status, 200);
  const upload = await created.json();
  assert.equal(typeof upload.uploadId, "string");
  assert.match(upload.generation, /^[0-9a-f-]{36}$/);

  env.RECORDINGS.nextPartError = new Error("multipart part is too small for the minimum size");
  const invalidPart = await worker.fetch(new Request(
    `https://api.example.test/v1/meetings/${meetingID}/media/screen/multipart/${upload.uploadId}/parts/1`,
    { method: "PUT", headers: authorization, body: "recording-bytes" },
  ), env);
  assert.equal(invalidPart.status, 400);

  const uploaded = await worker.fetch(new Request(
    `https://api.example.test/v1/meetings/${meetingID}/media/screen/multipart/${upload.uploadId}/parts/1`,
    { method: "PUT", headers: authorization, body: "recording-bytes" },
  ), env);
  assert.equal(uploaded.status, 200);
  const part = await uploaded.json();

  env.RECORDINGS.failCompleteAfterStoreOnce = true;
  env.DB.failNextAttach = true;
  const completeURL = `https://api.example.test/v1/meetings/${meetingID}/media/screen/multipart/${upload.uploadId}/complete`;
  const completionBody = JSON.stringify({ parts: [part] });
  const lostAttachment = await worker.fetch(new Request(completeURL, {
    method: "POST",
    headers: { ...authorization, "content-type": "application/json" },
    body: completionBody,
  }), env);
  assert.equal(lostAttachment.status, 500);
  assert.equal(env.DB.uploads.get(upload.uploadId).status, "completed");
  assert.equal(env.DB.pointers.has(`${userID}:${meetingID}:screen`), false);

  const retried = await worker.fetch(new Request(completeURL, {
    method: "POST",
    headers: { ...authorization, "content-type": "application/json" },
    body: completionBody,
  }), env);
  assert.equal(retried.status, 200);
  const completed = await retried.json();
  assert.equal(completed.ok, true);
  assert.equal(completed.generation, upload.generation);
  assert.equal(env.DB.uploads.get(upload.uploadId).status, "attached");
  assert.equal(env.DB.pointers.get(`${userID}:${meetingID}:screen`).object_key, completed.objectKey);

  const repeated = await worker.fetch(new Request(completeURL, {
    method: "POST",
    headers: { ...authorization, "content-type": "application/json" },
    body: completionBody,
  }), env);
  assert.equal(repeated.status, 200);
  assert.equal((await repeated.json()).objectKey, completed.objectKey);
});

test("access URL issuance rejects unsafe lifetimes and unmanaged object keys", async () => {
  const userID = "33333333-3333-4333-8333-333333333333";
  const meetingID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
  const token = "session-token";
  const env = await testEnvironment({
    sessions: new Map([[await sha256(token), { id: userID, email: "user@example.com" }]]),
    meetings: new Map([
      [`${userID}:${meetingID}`, { screen_object_key: "someone-else/object.mp4", audio_object_key: null }],
    ]),
    pointers: new Map(),
    objects: new Map(),
  });

  const shortTTL = await worker.fetch(new Request(
    `https://api.example.test/v1/meetings/${meetingID}/media/screen/access?ttl=59`,
    { headers: { authorization: `Bearer ${token}` } },
  ), env);
  assert.equal(shortTTL.status, 400);

  const unmanaged = await worker.fetch(new Request(
    `https://api.example.test/v1/meetings/${meetingID}/media/screen/access`,
    { headers: { authorization: `Bearer ${token}` } },
  ), env);
  assert.equal(unmanaged.status, 409);
});

async function testEnvironment({ sessions, meetings, pointers = new Map(), objects }) {
  return {
    AUTH_SECRET: "test-only-auth-secret-that-is-long-enough",
    GOOGLE_CLIENT_ID: "unused",
    GOOGLE_CLIENT_SECRET: "unused",
    PUBLIC_BASE_URL: "http://localhost",
    DB: new FakeD1(sessions, meetings, pointers),
    RECORDINGS: new FakeR2(objects),
  };
}

class FakeD1 {
  constructor(sessions, meetings, pointers) {
    this.sessions = sessions;
    this.meetings = meetings;
    this.pointers = pointers;
    this.uploads = new Map();
    this.parts = new Map();
    this.deletions = new Set();
    this.failNextAttach = false;
  }

  prepare(sql) {
    return new FakeD1Statement(this, sql);
  }

  async batch(statements) {
    if (this.beforeBatch) {
      const callback = this.beforeBatch;
      this.beforeBatch = null;
      callback();
    }
    if (this.failNextAttach && statements.some((statement) => statement.sql.startsWith("INSERT INTO meeting_media"))) {
      this.failNextAttach = false;
      throw new Error("simulated D1 attachment failure");
    }
    const results = [];
    for (const statement of statements) results.push(await statement.run());
    return results;
  }
}

class FakeD1Statement {
  constructor(database, sql) {
    this.database = database;
    this.sql = sql.replace(/\s+/g, " ").trim();
    this.values = [];
  }

  bind(...values) {
    this.values = values;
    return this;
  }

  async first() {
    if (this.sql.includes("FROM sessions JOIN users")) {
      const session = this.database.sessions.get(this.values[0]);
      return session ? { ...session, expires_at: new Date(Date.now() + 60_000).toISOString() } : null;
    }
    if (this.sql.includes("FROM meeting_media WHERE meeting_id")) {
      return this.database.pointers.get(`${this.values[1]}:${this.values[0]}:${this.values[2]}`) ?? null;
    }
    if (this.sql.includes("SELECT screen_object_key, audio_object_key")) {
      return this.database.meetings.get(`${this.values[1]}:${this.values[0]}`) ?? null;
    }
    if (this.sql.startsWith("SELECT id FROM meetings WHERE")) {
      const meeting = this.database.meetings.get(`${this.values[1]}:${this.values[0]}`);
      const deleting = this.database.deletions.has(`${this.values[1]}:${this.values[0]}`);
      return meeting && !deleting ? { id: this.values[0] } : null;
    }
    if (this.sql.includes("FROM media_uploads") && this.sql.includes("WHERE id = ?")) {
      const upload = this.database.uploads.get(this.values[0]);
      if (!upload || upload.user_id !== this.values[1] || upload.meeting_id !== this.values[2] || upload.kind !== this.values[3]) return null;
      if (this.database.deletions.has(`${upload.user_id}:${upload.meeting_id}`)) return null;
      return { ...upload };
    }
    if (this.sql.startsWith("SELECT part_number, etag FROM media_upload_parts")) {
      return this.database.parts.get(`${this.values[0]}:${this.values[1]}`) ?? null;
    }
    throw new Error(`Unexpected D1 first query: ${this.sql}`);
  }

  async all() {
    if (this.sql.startsWith("SELECT part_number, etag FROM media_upload_parts")) {
      const uploadID = this.values[0];
      return {
        results: [...this.database.parts.values()]
          .filter((part) => part.upload_id === uploadID)
          .sort((left, right) => left.part_number - right.part_number),
      };
    }
    if (this.sql.includes("FROM media_uploads WHERE meeting_id")) {
      return {
        results: [...this.database.uploads.values()]
          .filter((upload) => upload.meeting_id === this.values[0] && upload.user_id === this.values[1]),
      };
    }
    throw new Error(`Unexpected D1 all query: ${this.sql}`);
  }

  async run() {
    if (this.sql.startsWith("INSERT INTO meeting_deletions")) {
      const [, meetingID, userID] = this.values;
      if (this.database.meetings.has(`${userID}:${meetingID}`)) this.database.deletions.add(`${userID}:${meetingID}`);
      return { success: true, meta: { changes: 1 } };
    }
    if (this.sql.startsWith("INSERT INTO media_uploads")) {
      const [id, r2UploadID, meetingID, userID, kind, objectKey, generation, replacesObjectKey, replacesGeneration, createdAt] = this.values;
      if (this.database.deletions.has(`${userID}:${meetingID}`)) return { success: true, meta: { changes: 0 } };
      this.database.uploads.set(id, {
        id,
        r2_upload_id: r2UploadID,
        meeting_id: meetingID,
        user_id: userID,
        kind,
        object_key: objectKey,
        generation,
        replaces_object_key: replacesObjectKey,
        replaces_generation: replacesGeneration,
        status: "uploading",
        completion_parts_json: null,
        completed_etag: null,
        completed_version: null,
        created_at: createdAt,
        updated_at: createdAt,
      });
      return { success: true, meta: { changes: 1 } };
    }
    if (this.sql.startsWith("INSERT INTO media_upload_parts")) {
      const [uploadID, partNumber, etag] = this.values;
      const upload = this.database.uploads.get(uploadID);
      if (!upload || this.database.deletions.has(`${upload.user_id}:${upload.meeting_id}`)) {
        return { success: true, meta: { changes: 0 } };
      }
      this.database.parts.set(`${uploadID}:${partNumber}`, { upload_id: uploadID, part_number: partNumber, etag });
      return { success: true, meta: { changes: 1 } };
    }
    if (this.sql.startsWith("UPDATE media_uploads SET status = 'completing'")) {
      const [partsJSON, , uploadID] = this.values;
      const upload = this.database.uploads.get(uploadID);
      if (upload?.status === "uploading") {
        upload.status = "completing";
        upload.completion_parts_json = partsJSON;
        return { success: true, meta: { changes: 1 } };
      }
      return { success: true, meta: { changes: 0 } };
    }
    if (this.sql.startsWith("UPDATE media_uploads SET status = 'completed'") || this.sql.includes("SET status = 'completed'")) {
      const [etag, version, , uploadID] = this.values;
      const upload = this.database.uploads.get(uploadID);
      if (upload) {
        upload.status = "completed";
        upload.completed_etag = etag;
        upload.completed_version = version;
      }
      return { success: true, meta: { changes: upload ? 1 : 0 } };
    }
    if (this.sql.startsWith("UPDATE media_uploads") && this.sql.includes("SET status = 'attached'")) {
      const [etag, version, , uploadID] = this.values;
      const upload = this.database.uploads.get(uploadID);
      if (upload) {
        upload.status = "attached";
        upload.completed_etag = etag;
        upload.completed_version = version;
      }
      return { success: true, meta: { changes: upload ? 1 : 0 } };
    }
    if (this.sql.startsWith("INSERT INTO meeting_media")) {
      const [meetingID, userID, kind, objectKey, generation, etag, version] = this.values;
      const previousObjectKey = this.values[11];
      const previousGeneration = this.values[15];
      const key = `${userID}:${meetingID}:${kind}`;
      const current = this.database.pointers.get(key);
      const legacy = this.database.meetings.get(`${userID}:${meetingID}`)?.[kind === "screen" ? "screen_object_key" : "audio_object_key"] ?? null;
      const canAttach = legacy === previousObjectKey && (
        (!current && previousGeneration === null) ||
        (current && current.object_key === previousObjectKey && current.generation === previousGeneration)
      );
      if (canAttach) this.database.pointers.set(key, { object_key: objectKey, generation, etag, version });
      return { success: true, meta: { changes: canAttach ? 1 : 0 } };
    }
    if (this.sql.startsWith("UPDATE meetings SET screen_object_key = ?") || this.sql.startsWith("UPDATE meetings SET audio_object_key = ?")) {
      const [objectKey, , meetingID, userID, , , kind, expectedObjectKey, generation, etag, version] = this.values;
      const pointer = this.database.pointers.get(`${userID}:${meetingID}:${kind}`);
      const matches = pointer && pointer.object_key === expectedObjectKey && pointer.generation === generation &&
        pointer.etag === etag && pointer.version === version;
      if (matches) this.database.meetings.get(`${userID}:${meetingID}`)[kind === "screen" ? "screen_object_key" : "audio_object_key"] = objectKey;
      return { success: true, meta: { changes: matches ? 1 : 0 } };
    }
    if (this.sql.startsWith("DELETE FROM meeting_media")) {
      if (this.values.length === 2) {
        const [meetingID, userID] = this.values;
        let changes = 0;
        for (const key of [...this.database.pointers.keys()]) {
          if (key.startsWith(`${userID}:${meetingID}:`)) {
            this.database.pointers.delete(key);
            changes += 1;
          }
        }
        return { success: true, meta: { changes } };
      }
      const [meetingID, userID, kind, objectKey, generation, etag, version] = this.values;
      const key = `${userID}:${meetingID}:${kind}`;
      const pointer = this.database.pointers.get(key);
      const matches = pointer && pointer.object_key === objectKey && pointer.generation === generation &&
        pointer.etag === etag && pointer.version === version;
      if (matches) this.database.pointers.delete(key);
      return { success: true, meta: { changes: matches ? 1 : 0 } };
    }
    if (this.sql.startsWith("UPDATE meetings SET screen_object_key = NULL")) {
      const [, meetingID, userID, objectKey] = this.values;
      const meeting = this.database.meetings.get(`${userID}:${meetingID}`);
      if (meeting?.screen_object_key === objectKey) meeting.screen_object_key = null;
      return { success: true, meta: { changes: 1 } };
    }
    if (this.sql.startsWith("UPDATE meetings SET audio_object_key = NULL")) {
      const [, meetingID, userID, objectKey] = this.values;
      const meeting = this.database.meetings.get(`${userID}:${meetingID}`);
      if (meeting?.audio_object_key === objectKey) meeting.audio_object_key = null;
      return { success: true, meta: { changes: 1 } };
    }
    if (this.sql.startsWith("DELETE FROM media_upload_parts")) {
      const [meetingID, userID] = this.values;
      let changes = 0;
      for (const [key, part] of [...this.database.parts]) {
        const upload = this.database.uploads.get(part.upload_id);
        if (upload?.meeting_id === meetingID && upload.user_id === userID) {
          this.database.parts.delete(key);
          changes += 1;
        }
      }
      return { success: true, meta: { changes } };
    }
    if (this.sql.startsWith("DELETE FROM media_uploads")) {
      const [meetingID, userID] = this.values;
      let changes = 0;
      for (const [key, upload] of [...this.database.uploads]) {
        if (upload.meeting_id === meetingID && upload.user_id === userID) {
          this.database.uploads.delete(key);
          changes += 1;
        }
      }
      return { success: true, meta: { changes } };
    }
    if (this.sql.startsWith("DELETE FROM meetings")) {
      const [meetingID, userID] = this.values;
      const changes = this.database.meetings.delete(`${userID}:${meetingID}`) ? 1 : 0;
      return { success: true, meta: { changes } };
    }
    if (this.sql.startsWith("DELETE FROM meeting_deletions")) {
      const [meetingID, userID] = this.values;
      const changes = this.database.deletions.delete(`${userID}:${meetingID}`) ? 1 : 0;
      return { success: true, meta: { changes } };
    }
    throw new Error(`Unexpected D1 run query: ${this.sql}`);
  }
}

class FakeR2 {
  constructor(objects) {
    this.objects = objects;
    this.multipart = new Map();
    this.nextUploadID = 1;
    this.failCompleteAfterStoreOnce = false;
    this.nextPartError = null;
  }

  async createMultipartUpload(key) {
    const uploadId = `fake-r2-upload-${this.nextUploadID++}`;
    this.multipart.set(uploadId, { key, parts: new Map(), status: "uploading" });
    return this.resumeMultipartUpload(key, uploadId);
  }

  resumeMultipartUpload(key, uploadId) {
    const bucket = this;
    const state = this.multipart.get(uploadId);
    if (!state || state.key !== key) throw new Error("NoSuchUpload: multipart upload not found");
    return {
      uploadId,
      key,
      async uploadPart(partNumber, body) {
        if (bucket.nextPartError) {
          const error = bucket.nextPartError;
          bucket.nextPartError = null;
          throw error;
        }
        if (state.status !== "uploading") throw new Error("multipart upload already completed");
        const bytes = new Uint8Array(await new Response(body).arrayBuffer());
        const etag = `part-${partNumber}-etag`;
        state.parts.set(partNumber, { bytes, etag });
        return { partNumber, etag };
      },
      async complete(parts) {
        if (state.status !== "uploading") throw new Error("multipart upload already completed");
        const chunks = parts.map(({ partNumber, etag }) => {
          const part = state.parts.get(partNumber);
          if (!part || part.etag !== etag) throw new Error("InvalidPart: etag mismatch");
          return part.bytes;
        });
        const size = chunks.reduce((total, chunk) => total + chunk.byteLength, 0);
        const combined = new Uint8Array(size);
        let offset = 0;
        for (const chunk of chunks) {
          combined.set(chunk, offset);
          offset += chunk.byteLength;
        }
        bucket.objects.set(key, combined);
        state.status = "completed";
        if (bucket.failCompleteAfterStoreOnce) {
          bucket.failCompleteAfterStoreOnce = false;
          throw new Error("simulated response loss after R2 completion");
        }
        return fakeR2Object(key, combined, null);
      },
      async abort() {
        if (state.status !== "uploading") throw new Error("multipart upload already completed");
        state.status = "aborted";
      },
    };
  }

  async get(key, options) {
    const value = this.objects.get(key);
    if (!value) return null;
    const requestedRange = options?.range instanceof Headers ? options.range.get("range") : null;
    let offset = 0;
    let length = value.byteLength;
    let range;
    if (requestedRange) {
      const match = requestedRange.match(/^bytes=(\d+)-(\d+)$/);
      if (!match) throw new Error("Test only supports bounded byte ranges");
      offset = Number(match[1]);
      length = Number(match[2]) - offset + 1;
      range = { offset, length };
    } else if (options?.range && typeof options.range.offset === "number" && typeof options.range.length === "number") {
      offset = options.range.offset;
      length = options.range.length;
      range = { offset, length };
    }
    return fakeR2Object(key, value, value.slice(offset, offset + length), range);
  }

  async head(key) {
    const value = this.objects.get(key);
    return value ? fakeR2Object(key, value, null) : null;
  }

  async delete(key) {
    this.objects.delete(key);
  }
}

function fakeR2Object(key, fullValue, bodyValue, range) {
  return {
    key,
    size: fullValue.byteLength,
    etag: "test-etag",
    httpEtag: '"test-etag"',
    version: versionForKey(key),
    uploaded: new Date("2026-08-10T00:00:00.000Z"),
    range,
    body: bodyValue === null ? undefined : new Blob([bodyValue]).stream(),
    writeHttpMetadata(headers) {
      headers.set("content-type", "video/mp4");
    },
  };
}

function versionForKey(key) {
  return `version-${key}`;
}

async function sha256(value) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
  let binary = "";
  for (const byte of digest) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}
