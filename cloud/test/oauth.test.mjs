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
  temporaryDirectory = await mkdtemp(join(tmpdir(), "openrec-oauth-test-"));
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

test("Google sign-in uses the canonical API callback and identity scopes only", async () => {
  const response = await worker.fetch(
    new Request("https://api.openrec.co/v1/auth/google/start?redirect_uri=openrec%3A%2F%2Fauth"),
    {
      AUTH_SECRET: "test-auth-secret",
      GOOGLE_CLIENT_ID: "test-client-id",
      PUBLIC_BASE_URL: "https://api.openrec.co",
    },
  );

  assert.equal(response.status, 302);
  const authorizationURL = new URL(response.headers.get("location"));
  assert.equal(authorizationURL.origin, "https://accounts.google.com");
  assert.equal(
    authorizationURL.searchParams.get("redirect_uri"),
    "https://api.openrec.co/v1/auth/google/callback",
  );
  assert.deepEqual(
    new Set(authorizationURL.searchParams.get("scope").split(" ")),
    new Set(["openid", "email", "profile"]),
  );
  assert.equal(authorizationURL.searchParams.get("access_type"), null);
  assert.equal(authorizationURL.searchParams.get("prompt"), "select_account");
});

test("calendar connection is a separate offline, read-only grant", async () => {
  const response = await worker.fetch(
    new Request("https://api.openrec.co/v1/calendar/connect/session", {
      method: "POST",
      headers: {
        authorization: "Bearer test-session-token",
        "content-type": "application/json",
      },
      body: JSON.stringify({ redirect_uri: "openrec://calendar" }),
    }),
    authenticatedEnvironment(),
  );

  assert.equal(response.status, 200);
  const authorizationURL = new URL((await response.json()).url);
  assert.equal(
    authorizationURL.searchParams.get("redirect_uri"),
    "https://api.openrec.co/v1/auth/google/callback",
  );
  assert.deepEqual(
    new Set(authorizationURL.searchParams.get("scope").split(" ")),
    new Set(["openid", "email", "https://www.googleapis.com/auth/calendar.readonly"]),
  );
  assert.equal(authorizationURL.searchParams.get("access_type"), "offline");
  assert.equal(authorizationURL.searchParams.get("prompt"), "consent select_account");
});

test("disconnecting calendars clears every legacy calendar credential", async () => {
  const updates = [];
  const response = await worker.fetch(
    new Request("https://api.openrec.co/v1/calendar/connection", {
      method: "DELETE",
      headers: { authorization: "Bearer test-session-token" },
    }),
    authenticatedEnvironment(updates),
  );

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true });
  assert.equal(updates.length, 1);
  assert.match(updates[0], /google_refresh_token_cipher = NULL/);
  assert.match(updates[0], /google_calendar_refresh_token_cipher = NULL/);
  assert.match(updates[0], /google_calendar_email = NULL/);
});

function authenticatedEnvironment(updates = []) {
  return {
    AUTH_SECRET: "test-auth-secret",
    GOOGLE_CLIENT_ID: "test-client-id",
    PUBLIC_BASE_URL: "https://api.openrec.co",
    DB: {
      prepare(sql) {
        return {
          bind() {
            return {
              async first() {
                if (sql.includes("FROM sessions JOIN users")) {
                  return {
                    id: "test-user-id",
                    email: "user@example.com",
                    expires_at: new Date(Date.now() + 60_000).toISOString(),
                  };
                }
                return null;
              },
              async run() {
                if (sql.includes("UPDATE users SET")) updates.push(sql);
                return { success: true };
              },
            };
          },
        };
      },
    },
  };
}
