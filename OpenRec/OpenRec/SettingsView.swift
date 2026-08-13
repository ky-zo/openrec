import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics

private enum SettingsSection: String, CaseIterable, Identifiable {
    case account = "Account & Storage"
    case aiModels = "AI Models"
    case recording = "Recording"
    case integrations = "Integrations"
    case permissions = "Permissions"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .account: return "person.crop.circle"
        case .aiModels: return "waveform"
        case .recording: return "record.circle"
        case .integrations: return "arrow.triangle.branch"
        case .permissions: return "hand.raised.fill"
        }
    }
}

private enum ConnectionCheck: Equatable {
    case idle
    case running
    case success(String)
    case failure(String)
}

private enum CalendarConnectionCheck: Equatable {
    case idle
    case checking
    case connected
    case needsReconnect
    case failed(String)
}

struct OpenRecSettingsView: View {
    @ObservedObject var recorderManager: RecorderManager
    @State private var section: SettingsSection = .account
    @State private var assemblyAICheck: ConnectionCheck = .idle
    @State private var openAICheck: ConnectionCheck = .idle
    @State private var r2Check: ConnectionCheck = .idle
    @State private var webhookCheck: ConnectionCheck = .idle
    @State private var calendarCheck: CalendarConnectionCheck = .idle
    @StateObject private var assemblyAIKeyVerifier = APIKeyAutoVerifier()
    @StateObject private var openAIKeyVerifier = APIKeyAutoVerifier()
    @State private var microphoneGranted = false
    @State private var screenGranted = false

    private let background = Color(red: 0.105, green: 0.11, blue: 0.115)
    private let sidebar = Color(red: 0.13, green: 0.135, blue: 0.14)
    private let primary = Color.white.opacity(0.9)
    private let secondary = Color.white.opacity(0.5)

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
                .frame(width: 190)
            Color.white.opacity(0.08).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    settingsHeader
                    sectionContent
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(background)
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear {
            refreshPermissions()
            if recorderManager.transcriptionManager.isAssemblyAIAPIKeyVerified {
                assemblyAICheck = .success("Key verified with AssemblyAI")
            }
            if recorderManager.transcriptionManager.isOpenAIAPIKeyVerified {
                openAICheck = .success("Key verified with OpenAI")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 7, height: 7)
                Text("OpenRec")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(primary)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)

            VStack(spacing: 4) {
                ForEach(SettingsSection.allCases) { item in
                    Button {
                        section = item
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: item.icon)
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 16)
                            Text(item.rawValue)
                                .font(.system(size: 11, weight: section == item ? .semibold : .medium))
                            Spacer()
                        }
                        .foregroundColor(Color.white.opacity(section == item ? 0.9 : 0.5))
                        .padding(.horizontal, 11)
                        .frame(height: 34)
                        .background(section == item ? Color.white.opacity(0.085) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SettingsPressStyle())
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            Button {
                if let url = URL(string: "https://x.com/messages/compose?recipient_id=945756809356300294&text=Hey%2C%20some%20OpenRec%20feedback%3A%20") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "ladybug")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 16)
                    Text("Bugs and feedback")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .foregroundColor(Color.white.opacity(0.5))
                .padding(.horizontal, 11)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(SettingsPressStyle())
            .padding(.horizontal, 8)

            Text("Changes save automatically")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(Color.white.opacity(0.3))
                .padding(16)
        }
        .background(sidebar)
    }

    private var settingsHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(section.rawValue)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(primary)
            Text(sectionDescription)
                .font(.system(size: 11))
                .foregroundColor(secondary)
        }
    }

    private var sectionDescription: String {
        switch section {
        case .account: return "Choose the private home for meeting memory and recordings."
        case .aiModels: return "AssemblyAI transcribes each call; OpenAI turns it into useful meeting memory."
        case .recording: return "Set defaults for new calls. During-call changes apply only to that call."
        case .integrations: return "Deliver completed meeting metadata and recordings to your systems."
        case .permissions: return "OpenRec only captures your screen and microphone while recording."
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .account: accountSection
        case .aiModels: aiModelsSection
        case .recording: recordingSection
        case .integrations: integrationsSection
        case .permissions: permissionsSection
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(title: "Meeting storage") {
                VStack(spacing: 8) {
                    StorageSettingsChoice(
                        icon: "icloud.fill",
                        title: "OpenRec Cloud",
                        detail: "Google sign-in · searchable transcripts · private recordings",
                        selected: recorderManager.cloudStorage.mode == .managed
                    ) {
                        recorderManager.cloudStorage.mode = .managed
                    }
                    StorageSettingsChoice(
                        icon: "shippingbox.fill",
                        title: "My Cloudflare R2",
                        detail: "Your bucket · live media streaming · private meeting index",
                        selected: recorderManager.cloudStorage.mode == .ownR2
                    ) {
                        recorderManager.cloudStorage.mode = .ownR2
                    }
                }
            }

            if recorderManager.cloudStorage.mode == .managed {
                SettingsCard(title: "OpenRec Cloud account") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: recorderManager.cloudStorage.isManagedSignedIn ? "checkmark.circle.fill" : "person.crop.circle.badge.plus")
                                .foregroundColor(recorderManager.cloudStorage.isManagedSignedIn ? .green : secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(recorderManager.cloudStorage.managedEmail ?? "Not signed in")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundColor(primary)
                                Text(recorderManager.cloudStorage.isManagedSignedIn ? "Meeting database and private R2 are connected" : "Google sign-in is required")
                                    .font(.system(size: 10))
                                    .foregroundColor(secondary)
                            }
                            Spacer()
                            if recorderManager.cloudStorage.isManagedSignedIn {
                                Button("Sign out") { recorderManager.cloudStorage.signOut() }
                                    .buttonStyle(SettingsButtonStyle(prominent: false))
                            } else {
                                Button(recorderManager.cloudStorage.isSigningIn ? "Opening Google…" : "Continue with Google") {
                                    Task { await recorderManager.cloudStorage.signInWithGoogle() }
                                }
                                .buttonStyle(SettingsButtonStyle(prominent: true))
                                .disabled(recorderManager.cloudStorage.isSigningIn)
                            }
                        }

                        if let message = recorderManager.cloudStorage.statusMessage, !message.isEmpty {
                            let isSignedOutMessage = message == "Signed out"
                            Label(
                                message,
                                systemImage: recorderManager.cloudStorage.isManagedSignedIn
                                    ? "checkmark.circle.fill"
                                    : (isSignedOutMessage ? "info.circle.fill" : "exclamationmark.circle.fill")
                            )
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(
                                recorderManager.cloudStorage.isManagedSignedIn
                                    ? .green.opacity(0.86)
                                    : (isSignedOutMessage ? secondary : .orange.opacity(0.9))
                            )
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                SettingsCard(title: "Cloudflare R2 credentials") {
                    VStack(spacing: 9) {
                        HStack(spacing: 9) {
                            SettingsTextField(
                                prompt: "R2 account ID",
                                text: Binding(get: { recorderManager.cloudStorage.r2AccountID }, set: { recorderManager.cloudStorage.r2AccountID = $0; r2Check = .idle })
                            )
                            SettingsTextField(
                                prompt: "Bucket name",
                                text: Binding(get: { recorderManager.cloudStorage.r2Bucket }, set: { recorderManager.cloudStorage.r2Bucket = $0; r2Check = .idle })
                            )
                        }
                        SettingsTextField(
                            prompt: "Access key ID",
                            text: Binding(get: { recorderManager.cloudStorage.r2AccessKeyID }, set: { recorderManager.cloudStorage.r2AccessKeyID = $0; r2Check = .idle })
                        )
                        SettingsSecureField(
                            prompt: "Secret access key",
                            text: Binding(get: { recorderManager.cloudStorage.r2SecretAccessKey }, set: { recorderManager.cloudStorage.r2SecretAccessKey = $0; r2Check = .idle })
                        )
                        SettingsTestRow(state: r2Check, idleText: "Credentials are stored in Keychain") {
                            testR2()
                        }
                    }
                }
            }

            googleCalendarCard
        }
    }

    private var googleCalendarCard: some View {
        SettingsCard(title: "Google Calendar") {
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .foregroundColor(calendarStatusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Meeting name auto-fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(primary)
                    Text(calendarStatusText)
                        .font(.system(size: 10))
                        .foregroundColor(secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if recorderManager.cloudStorage.mode == .managed && recorderManager.cloudStorage.isManagedSignedIn {
                    Button(calendarConnectButtonTitle) {
                        Task {
                            if await recorderManager.cloudStorage.connectGoogleCalendar() {
                                probeCalendarAccess()
                            }
                        }
                    }
                    .buttonStyle(SettingsButtonStyle(prominent: calendarCheck == .needsReconnect))
                    .disabled(recorderManager.cloudStorage.isConnectingCalendar)
                    .help("Pick any Google account for calendar access — the meeting library stays on the account you signed in with.")
                    if calendarCheck != .needsReconnect {
                        Button(calendarCheck == .checking ? "Checking…" : "Check access") { probeCalendarAccess() }
                            .buttonStyle(SettingsButtonStyle(prominent: false))
                            .disabled(calendarCheck == .checking)
                    }
                }
            }
        }
        .onAppear { probeCalendarAccess() }
        .onChange(of: recorderManager.cloudStorage.isManagedSignedIn) { _ in probeCalendarAccess() }
        .onChange(of: recorderManager.cloudStorage.mode) { _ in probeCalendarAccess() }
        // A reconnect keeps isManagedSignedIn true throughout, but completing
        // it updates statusMessage — re-check calendar access then.
        .onChange(of: recorderManager.cloudStorage.statusMessage) { _ in probeCalendarAccess() }
    }

    private var calendarStatusColor: Color {
        switch calendarCheck {
        case .connected: return .green.opacity(0.86)
        case .needsReconnect, .failed: return .orange.opacity(0.9)
        case .idle, .checking: return secondary
        }
    }

    private var calendarConnectButtonTitle: String {
        if recorderManager.cloudStorage.isConnectingCalendar { return "Opening Google…" }
        return recorderManager.cloudStorage.calendarEmails.isEmpty ? "Connect calendar" : "Add account"
    }

    private var calendarStatusText: String {
        guard recorderManager.cloudStorage.mode == .managed else {
            return "New calls are named after the current event in the calendars enabled in the macOS Calendar app."
        }
        guard recorderManager.cloudStorage.isManagedSignedIn else {
            return "Sign in above first — calendar connections attach to your OpenRec Cloud account."
        }
        let emails = recorderManager.cloudStorage.calendarEmails
        switch calendarCheck {
        case .connected:
            let accounts = emails.isEmpty
                ? (recorderManager.cloudStorage.managedEmail ?? "Google")
                : emails.joined(separator: ", ")
            return "Reading \(accounts) — every calendar in each account is checked, merged into one list. Connect as many Google accounts as needed; storage is unaffected."
        case .needsReconnect:
            return "No calendar is connected yet. Connect any Google account — read-only, and separate from your sign-in."
        case .failed(let message):
            return message
        case .checking:
            return "Checking calendar access…"
        case .idle:
            return "Read-only access is used to name new calls after the current meeting."
        }
    }

    private func probeCalendarAccess() {
        guard recorderManager.cloudStorage.mode == .managed,
              recorderManager.cloudStorage.isManagedSignedIn else {
            calendarCheck = .idle
            return
        }
        calendarCheck = .checking
        Task {
            await recorderManager.cloudStorage.refreshCalendarConnectionStatus()
            do {
                _ = try await recorderManager.cloudStorage.currentCalendarCall()
                calendarCheck = .connected
            } catch OpenRecError.requestFailed(let status, _) where status == 409 {
                calendarCheck = .needsReconnect
            } catch {
                calendarCheck = .failed(error.localizedDescription)
            }
        }
    }

    private var aiModelsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(title: "Transcription · AssemblyAI") {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsSecureField(
                        prompt: "AssemblyAI API key",
                        text: Binding(
                            get: { recorderManager.transcriptionManager.assemblyAIAPIKey },
                            set: { assemblyAIKeyChanged(to: $0) }
                        )
                    )
                    HStack(spacing: 8) {
                        Label("Universal-3.5 Pro", systemImage: "waveform")
                        Text("·")
                        Text("speaker diarization")
                        Spacer()
                        Button("Create API key") {
                            if let url = URL(string: "https://www.assemblyai.com/dashboard/signup") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(secondary)
                    SettingsTestRow(
                        state: assemblyAICheck,
                        idleText: "Paste to verify automatically · stored in Keychain"
                    ) {
                        testAssemblyAI()
                    }
                }
            }

            SettingsCard(title: "Meeting memory · OpenAI") {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsSecureField(
                        prompt: "sk-proj-…",
                        text: Binding(
                            get: { recorderManager.transcriptionManager.openAIAPIKey },
                            set: { openAIKeyChanged(to: $0) }
                        )
                    )
                    HStack(spacing: 8) {
                        Label("gpt-5-mini", systemImage: "sparkles")
                        Text("·")
                        Text("summaries, decisions, and next steps")
                        Spacer()
                        Button("Create API key") {
                            if let url = URL(string: "https://platform.openai.com/api-keys") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(secondary)
                    SettingsTestRow(
                        state: openAICheck,
                        idleText: "Paste to verify automatically · used only for meeting memory"
                    ) {
                        testOpenAI()
                    }
                }
            }
        }
    }

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(title: "New call defaults") {
                VStack(spacing: 0) {
                    SettingsToggleRow(title: "Keep screen recording", detail: "Stream the call video directly to your selected storage", value: preference(\.keepScreenRecording))
                    SettingsDivider()
                    SettingsToggleRow(title: "Keep audio recording", detail: "Stream a separate call-audio file to your selected storage", value: preference(\.keepAudioRecording))
                    SettingsDivider()
                    SettingsToggleRow(
                        title: "Store transcript",
                        detail: "Make the transcript searchable in Meetings",
                        value: preference(\.storeTranscriptInCloud)
                    )
                    SettingsDivider()
                    SettingsToggleRow(title: "Send to webhook", detail: "Deliver metadata and generated recordings after analysis", value: preference(\.sendToWebhook))
                }
            }

            SettingsCard(title: "Capture") {
                VStack(spacing: 0) {
                    SettingsToggleRow(
                        title: "Show recording border",
                        detail: "Draw a red outline around the captured display",
                        value: Binding(get: { recorderManager.showRecordingBorder }, set: { recorderManager.setShowRecordingBorder($0) })
                    )
                    SettingsDivider()
                    SettingsToggleRow(
                        title: "Detect calls",
                        detail: "Show a compact side prompt for Meet, Zoom, Teams, FaceTime, and Webex",
                        value: $recorderManager.callDetectionEnabled
                    )
                }
            }

            SettingsCard(title: "Capture storage") {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "icloud.and.arrow.up.fill")
                        .foregroundColor(.red.opacity(0.9))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Cloud-first recording")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(primary)
                        Text("Media uploads while you record. OpenRec keeps no permanent recordings folder on this Mac.")
                            .font(.system(size: 10))
                            .foregroundColor(secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(.vertical, 3)
            }

        }
    }

    private var integrationsSection: some View {
        SettingsCard(title: "Recording webhook") {
            VStack(spacing: 10) {
                SettingsToggleRow(
                    title: "Send completed calls",
                    detail: "POST metadata with short-lived private recording links",
                    value: preference(\.sendToWebhook)
                )
                if recorderManager.callPreferences.sendToWebhook {
                    SettingsDivider()
                    SettingsTextField(
                        prompt: "https://example.com/openrec",
                        text: Binding(get: { recorderManager.webhookSettings.url }, set: { recorderManager.webhookSettings.url = $0; webhookCheck = .idle })
                    )
                    SettingsSecureField(
                        prompt: "Optional bearer secret",
                        text: Binding(get: { recorderManager.webhookSettings.secret }, set: { recorderManager.webhookSettings.secret = $0; webhookCheck = .idle })
                    )
                    SettingsTestRow(state: webhookCheck, idleText: "Test sends a connection.test event without meeting data") {
                        testWebhook()
                    }
                }
            }
        }
    }

    private var permissionsSection: some View {
        VStack(spacing: 10) {
            SettingsPermissionRow(
                icon: "mic.fill",
                title: "Microphone",
                detail: "Your voice in the conversation",
                granted: microphoneGranted,
                action: requestMicrophone
            )
            SettingsPermissionRow(
                icon: "rectangle.dashed.badge.record",
                title: "Screen & system audio",
                detail: "The call window and everyone else",
                granted: screenGranted,
                action: requestScreen
            )
            Button("Open Privacy & Security") { openPrivacySettings() }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(secondary)
                .padding(.top, 4)
        }
    }

    private func preference(_ path: WritableKeyPath<CallPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { recorderManager.callPreferences[keyPath: path] },
            set: {
                var preferences = recorderManager.callPreferences
                preferences[keyPath: path] = $0
                recorderManager.callPreferences = preferences
            }
        )
    }

    private func assemblyAIKeyChanged(to key: String) {
        recorderManager.transcriptionManager.assemblyAIAPIKey = key
        assemblyAICheck = .idle
        verifyAssemblyAIKey(key, trigger: .automatic)
    }

    private func testAssemblyAI() {
        verifyAssemblyAIKey(
            recorderManager.transcriptionManager.assemblyAIAPIKey,
            trigger: .immediate
        )
    }

    private func verifyAssemblyAIKey(
        _ key: String,
        trigger: APIKeyAutoVerifier.Trigger
    ) {
        assemblyAIKeyVerifier.submit(
            key: key,
            trigger: trigger,
            currentKey: { recorderManager.transcriptionManager.assemblyAIAPIKey },
            onRunning: { assemblyAICheck = .running },
            validate: { try await AssemblyAIService(apiKey: $0).validateAccess() },
            onCompletion: { normalizedKey, result in
                switch result {
                case .success:
                    recorderManager.transcriptionManager.assemblyAIAPIKey = normalizedKey
                    UserDefaults.standard.set(true, forKey: "AssemblyAIKeyVerified")
                    assemblyAICheck = .success("Key verified with AssemblyAI")
                case .failure(let error):
                    if AssemblyAIService.isAuthenticationFailure(error) {
                        UserDefaults.standard.set(false, forKey: "AssemblyAIKeyVerified")
                    }
                    assemblyAICheck = .failure(error.localizedDescription)
                }
            }
        )
    }

    private func openAIKeyChanged(to key: String) {
        recorderManager.transcriptionManager.openAIAPIKey = key
        openAICheck = .idle
        verifyOpenAIKey(key, trigger: .automatic)
    }

    private func testOpenAI() {
        verifyOpenAIKey(
            recorderManager.transcriptionManager.openAIAPIKey,
            trigger: .immediate
        )
    }

    private func verifyOpenAIKey(
        _ key: String,
        trigger: APIKeyAutoVerifier.Trigger
    ) {
        openAIKeyVerifier.submit(
            key: key,
            trigger: trigger,
            currentKey: { recorderManager.transcriptionManager.openAIAPIKey },
            onRunning: { openAICheck = .running },
            validate: { try await OpenAIService(apiKey: $0).validateAccess() },
            onCompletion: { normalizedKey, result in
                switch result {
                case .success:
                    recorderManager.transcriptionManager.openAIAPIKey = normalizedKey
                    UserDefaults.standard.set(true, forKey: "OpenAIKeyVerified")
                    openAICheck = .success("Key verified with OpenAI")
                case .failure(let error):
                    if OpenAIService.isCredentialOrModelAccessFailure(error) {
                        UserDefaults.standard.set(false, forKey: "OpenAIKeyVerified")
                    }
                    openAICheck = .failure(error.localizedDescription)
                }
            }
        )
    }

    private func testR2() {
        r2Check = .running
        Task {
            do {
                try await recorderManager.cloudStorage.validateR2Connection()
                r2Check = .success("Upload and cleanup succeeded")
            } catch { r2Check = .failure(error.localizedDescription) }
        }
    }

    private func testWebhook() {
        webhookCheck = .running
        Task {
            do {
                guard let url = URL(string: recorderManager.webhookSettings.url) else {
                    throw OpenRecError.invalidConfiguration("Enter a valid HTTPS webhook URL.")
                }
                try await WebhookDeliveryService(url: url, secret: recorderManager.webhookSettings.secret).testConnection()
                webhookCheck = .success("Webhook accepted the test event")
            } catch { webhookCheck = .failure(error.localizedDescription) }
        }
    }

    private func refreshPermissions() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        screenGranted = CGPreflightScreenCaptureAccess()
    }

    private func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { refreshPermissions() } }
    }

    private func requestScreen() {
        if !CGRequestScreenCaptureAccess() { openPrivacySettings() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { refreshPermissions() }
    }

    private func openPrivacySettings() {
        let pane = screenGranted
            ? "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            : "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.38))
            content
        }
        .padding(14)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.white.opacity(0.055)))
    }
}

private struct SettingsTextField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        TextField("", text: $text, prompt: Text(prompt).foregroundColor(Color.white.opacity(0.34)))
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .foregroundColor(Color.white.opacity(0.86))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct SettingsSecureField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        SecureField("", text: $text, prompt: Text(prompt).foregroundColor(Color.white.opacity(0.34)))
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .foregroundColor(Color.white.opacity(0.86))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var value: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundColor(Color.white.opacity(0.88))
                Text(detail).font(.system(size: 10)).foregroundColor(Color.white.opacity(0.44))
            }
            Spacer()
            Toggle("", isOn: $value)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.red)
        }
        .padding(.vertical, 10)
    }
}

private struct SettingsDivider: View {
    var body: some View { Color.white.opacity(0.06).frame(height: 1) }
}

private struct StorageSettingsChoice: View {
    let icon: String
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 11.5, weight: .semibold))
                    Text(detail).font(.system(size: 10)).foregroundColor(Color.white.opacity(0.43))
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected ? .red : Color.white.opacity(0.2))
            }
            .foregroundColor(Color.white.opacity(0.86))
            .padding(.horizontal, 11)
            .frame(height: 50)
            .background(Color.white.opacity(selected ? 0.085 : 0.025))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsPressStyle())
    }
}

private struct SettingsTestRow: View {
    let state: ConnectionCheck
    let idleText: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .idle:
                Label(idleText, systemImage: "lock.fill").foregroundColor(Color.white.opacity(0.42))
            case .running:
                ProgressView().controlSize(.small)
                Text("Testing connection…").foregroundColor(Color.white.opacity(0.5))
            case .success(let message):
                Label(message, systemImage: "checkmark.circle.fill").foregroundColor(.green.opacity(0.86))
            case .failure(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange.opacity(0.9))
            }
            Spacer()
            Button("Test") { action() }
                .buttonStyle(SettingsButtonStyle(prominent: false))
                .disabled(state == .running)
        }
        .font(.system(size: 9.5, weight: .medium))
    }
}

private struct SettingsPermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundColor(Color.white.opacity(0.5)).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundColor(Color.white.opacity(0.88))
                Text(detail).font(.system(size: 10)).foregroundColor(Color.white.opacity(0.44))
            }
            Spacer()
            Button(granted ? "Allowed" : "Allow", action: action)
                .buttonStyle(SettingsButtonStyle(prominent: !granted))
                .disabled(granted)
        }
        .padding(14)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.055)))
    }
}

private struct SettingsPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct SettingsButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(prominent ? .white : Color.white.opacity(0.68))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(prominent ? Color.red.opacity(0.9) : Color.white.opacity(0.075))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
