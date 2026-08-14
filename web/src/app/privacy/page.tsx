import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = {
  title: "Privacy Policy — OpenRec",
  description:
    "How OpenRec handles account, calendar, meeting, and recording data.",
};

export default function PrivacyPage() {
  return (
    <div className="legal-page">
      <header className="legal-header">
        <Link className="logo" href="/">
          <span className="red-dot" />
          <span className="logo-text">OpenRec</span>
        </Link>
      </header>

      <main className="legal-content">
        <p className="legal-kicker">Effective August 13, 2026</p>
        <h1>Privacy Policy</h1>
        <p className="legal-intro">
          OpenRec is an open-source macOS meeting recorder. This policy explains
          what the OpenRec app and optional OpenRec Cloud service process, why,
          and what choices you control.
        </p>

        <section>
          <h2>Data OpenRec processes</h2>
          <p>
            When you sign in to OpenRec Cloud with Google, we receive your
            Google account identifier, email address, name, and profile image.
            We use that information to create and secure your OpenRec Cloud
            account.
          </p>
          <p>
            If you separately connect Google Calendar, OpenRec requests
            read-only access. It reads calendar names, event titles, times, and
            attendees to show upcoming meetings, suggest a call name, and
            identify participants. OpenRec cannot create, edit, or delete
            calendar events.
          </p>
          <p>
            Depending on the choices you make for each call, OpenRec may process
            screen and audio recordings, transcripts, participants, summaries,
            AI notes, decisions, and next steps.
          </p>
        </section>

        <section>
          <h2>Where data is stored</h2>
          <p>
            In OpenRec Cloud mode, meeting metadata and account records are
            stored in Cloudflare D1 and retained recordings are stored privately
            in Cloudflare R2. Google refresh tokens are encrypted before
            storage. Session tokens and API keys kept on your Mac are stored in
            the macOS Keychain.
          </p>
          <p>
            If you choose your own R2 bucket, recording media is sent to that
            bucket using credentials you provide. Your settings determine
            whether recordings and transcripts are retained.
          </p>
        </section>

        <section>
          <h2>Service providers</h2>
          <p>
            OpenRec uses Cloudflare for the optional cloud backend and Google
            for sign-in and calendar access. When you enable transcription and
            AI notes, meeting audio or transcripts are sent to the transcription
            and AI providers configured in the app using your API keys. Those
            providers process data under their own privacy terms.
          </p>
          <p>
            OpenRec does not sell personal data or use meeting contents for
            advertising.
          </p>
        </section>

        <section>
          <h2>Your choices and deletion</h2>
          <p>
            You can disconnect individual Google Calendar accounts, revoke
            access from your Google Account, sign out of OpenRec Cloud, choose
            what each call retains, and delete meetings from the app. Deleting a
            cloud meeting removes its stored metadata and associated OpenRec
            Cloud recording objects.
          </p>
        </section>

        <section>
          <h2>Security and changes</h2>
          <p>
            OpenRec uses encrypted transport, private cloud storage, encrypted
            calendar credentials, short-lived authorization codes, and expiring
            media links. No system can guarantee absolute security. We may
            update this policy as the product changes and will revise the
            effective date above.
          </p>
        </section>

        <section>
          <h2>Contact</h2>
          <p>
            Questions or deletion requests can be sent to{" "}
            <a href="mailto:kamil@kyzo.io">kamil@kyzo.io</a>. You can also
            inspect the complete source code on{" "}
            <a href="https://github.com/ky-zo/openrec">GitHub</a>.
          </p>
        </section>

        <Link className="legal-back" href="/">
          ← Back to OpenRec
        </Link>
      </main>
    </div>
  );
}
