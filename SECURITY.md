# Security Policy

## Reporting a vulnerability

Please do not open a public GitHub issue for security problems.

Report vulnerabilities privately through
[GitHub Security Advisories](https://github.com/ky-zo/openrec/security/advisories/new).
Include what you found, how to reproduce it, and what an attacker could do with
it. You should get a first response within a few days.

## What OpenRec handles

OpenRec records calls, so a vulnerability here can expose unusually sensitive
data. Areas worth extra scrutiny:

- **Credentials.** AssemblyAI and OpenAI API keys and the OpenRec Cloud session
  token are stored in the macOS Keychain, never in plists or preferences.
- **Media.** Recordings stream to OpenRec Cloud or to your own Cloudflare R2
  bucket. Only meeting metadata and a non-secret upload-recovery journal are
  kept on the Mac.
- **Media links.** Webhook payloads carry private, expiring links to media.
  Anything that widens the scope or lifetime of those links is a security bug.
- **Cloud worker.** `cloud/src/index.ts` handles Google OAuth, session tokens,
  and R2 object access. Auth bypass, IDOR across users, and token forgery are
  all in scope.

## Supported versions

Only the latest release receives security fixes.
