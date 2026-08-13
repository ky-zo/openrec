import SwiftUI
import AVKit
import AppKit
import Combine

struct RecordingLibrarySelectionRequest: Equatable {
    let meetingID: UUID
    let token = UUID()
}

@MainActor
final class RecordingLibraryNavigation: ObservableObject {
    @Published private(set) var request: RecordingLibrarySelectionRequest?

    func select(_ meetingID: UUID) {
        request = RecordingLibrarySelectionRequest(meetingID: meetingID)
    }
}

enum MeetingLibraryPresentation {
    static func emptyTranscriptMessage(for meeting: MeetingRecord) -> String {
        meeting.preferences.storeTranscriptInCloud
            ? "Transcript storage was enabled, but no transcript is available for this meeting."
            : "No transcript was stored for this call."
    }
}

private enum MeetingDetailTab: String, CaseIterable, Identifiable {
    case summary = "AI Notes"
    case transcript = "Transcript"

    var id: String { rawValue }
}

private enum LibraryTab: Int, CaseIterable {
    case comingUp
    case past

    var label: String {
        switch self {
        case .comingUp: return "Coming up"
        case .past: return "Past"
        }
    }
}

private struct UpcomingDayGroup {
    let day: Date
    let events: [UpcomingCalendarEvent]
}

struct RecordingLibraryView: View {
    @ObservedObject var recorderManager: RecorderManager
    @ObservedObject var navigation: RecordingLibraryNavigation
    var onOpenSettings: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Coming up is the main view; opening a specific meeting switches to Past.
    @State private var tab: LibraryTab = .comingUp
    @State private var tabMovesForward = true
    @State private var adoptedEventID: String?
    @State private var localCalendarGranted = CalendarMeetingSuggester.accessGranted
    @State private var searchText = ""
    @State private var selectedID: UUID?
    @State private var detail: MeetingRecord?
    @State private var selectedTab: MeetingDetailTab = .summary
    @State private var isLoadingDetail = false
    @State private var detailError: String?
    @State private var mediaError: String?
    @State private var loadingMedia: MeetingMediaKind?
    @State private var player: AVPlayer?
    @State private var playerKind: MeetingMediaKind?
    @State private var copied = false
    @State private var detailTask: Task<Void, Never>?
    @State private var mediaTask: Task<Void, Never>?
    @State private var remoteSearchResults: [MeetingRecord] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var handledSelectionToken: UUID?
    @State private var deletingMeetingID: UUID?

    private let background = Color(red: 0.105, green: 0.11, blue: 0.115)
    private let sidebar = Color(red: 0.13, green: 0.135, blue: 0.14)
    private let card = Color.white.opacity(0.055)
    private let primary = Color.white.opacity(0.92)
    private let secondary = Color.white.opacity(0.58)
    private let accent = Color(red: 1, green: 0.25, blue: 0.28)

    private var visibleMeetings: [MeetingRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return recorderManager.cloudStorage.libraryMeetings }
        let localMatches = recorderManager.cloudStorage.libraryMeetings.filter { meeting in
            [
                meeting.title,
                meeting.callTitle ?? "",
                meeting.callApp ?? "",
                meeting.insights.summary,
                meeting.insights.aiNotes,
                meeting.insights.participants.joined(separator: " "),
                meeting.transcript ?? "",
            ].joined(separator: " ").localizedCaseInsensitiveContains(query)
        }
        guard recorderManager.cloudStorage.mode == .managed else { return localMatches }
        var byID = Dictionary(uniqueKeysWithValues: localMatches.map { ($0.id, $0) })
        for remote in remoteSearchResults {
            byID[remote.id] = recorderManager.cloudStorage.libraryMeetings.first(where: { $0.id == remote.id }) ?? remote
        }
        return byID.values.sorted { $0.startedAt > $1.startedAt }
    }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            HStack(spacing: 0) {
                librarySidebar
                    .frame(width: 300)
                Color.white.opacity(0.08).frame(width: 1)
                detailPane
            }
        }
        // The titlebar is hidden and the window uses fullSizeContentView, so
        // reclaim its safe-area strip; the header row leaves room for the
        // traffic lights instead.
        .ignoresSafeArea()
        .frame(minWidth: 860, minHeight: 580)
        .task {
            recorderManager.refreshUpcomingEvents()
            await recorderManager.cloudStorage.refreshLibrary()
            selectInitialMeeting()
        }
        .task(id: searchText) {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            remoteSearchResults = []
            searchError = nil
            guard !query.isEmpty,
                  recorderManager.cloudStorage.mode == .managed,
                  recorderManager.cloudStorage.isManagedSignedIn else { return }
            isSearching = true
            defer { isSearching = false }
            do {
                try await Task.sleep(for: .milliseconds(250))
                let results = try await recorderManager.cloudStorage.searchManagedMeetings(query: query)
                guard !Task.isCancelled else { return }
                remoteSearchResults = results
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                searchError = error.localizedDescription
            }
        }
        .onChange(of: navigation.request) { _ in
            if !applyPendingSelection() {
                Task { await recorderManager.cloudStorage.refreshLibrary() }
            }
        }
        .onChange(of: recorderManager.cloudStorage.isManagedSignedIn) { _ in
            recorderManager.refreshUpcomingEvents()
        }
        .onChange(of: recorderManager.cloudStorage.libraryMeetings) { _ in
            selectInitialMeeting()
            if let id = selectedID, let updated = recorderManager.cloudStorage.libraryMeetings.first(where: { $0.id == id }) {
                detail = mergeVisibleDetail(updated)
            }
        }
        .onChange(of: selectedID) { id in
            guard let id else { return }
            guard let meeting = visibleMeetings.first(where: { $0.id == id })
                    ?? recorderManager.cloudStorage.libraryMeetings.first(where: { $0.id == id }) else {
                detail = nil
                return
            }
            loadDetail(meeting)
        }
        .onDisappear {
            detailTask?.cancel()
            mediaTask?.cancel()
            player?.pause()
        }
    }

    private var librarySidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(accent).frame(width: 7, height: 7)
                Text("Meetings")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(primary)
                Spacer()
                if let onOpenSettings {
                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(secondary)
                    .disabled(recorderManager.isRecording || recorderManager.isProcessing)
                    .opacity(recorderManager.isRecording || recorderManager.isProcessing ? 0.4 : 1)
                    .help("Settings")
                }
                Button {
                    Task { await recorderManager.cloudStorage.refreshLibrary() }
                    recorderManager.refreshUpcomingEvents()
                } label: {
                    if recorderManager.cloudStorage.isLoadingLibrary {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(secondary)
                .disabled(recorderManager.cloudStorage.isLoadingLibrary)
                .help("Refresh meetings")
            }
            // The window titlebar is reclaimed as content, so the header sits
            // beside the traffic lights instead of below an empty bar.
            .padding(.leading, 74)
            .padding(.trailing, 14)
            .padding(.top, 9)
            .padding(.bottom, 8)

            libraryTabBar
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            if tab == .past {
                searchField
                if let searchError {
                    Label(searchError, systemImage: "magnifyingglass")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(Color.orange.opacity(0.88))
                        .lineLimit(3)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }
                if let error = recorderManager.cloudStorage.libraryError {
                    Label(error, systemImage: "icloud.slash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.orange.opacity(0.9))
                        .lineLimit(4)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
            }

            // One persistent list; the tabs only filter which half of the
            // timeline is visible (future ascending vs. past descending).
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if tab == .comingUp {
                        comingUpContent
                            .transition(tabTransition)
                    } else {
                        pastListContent
                            .transition(tabTransition)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .clipped()

            if tab == .comingUp {
                calendarSourcesBar
            }

            HStack(spacing: 6) {
                Image(systemName: recorderManager.cloudStorage.mode == .managed ? "icloud" : "shippingbox")
                Text(recorderManager.cloudStorage.mode.label)
                Spacer()
                Text(
                    tab == .comingUp
                        ? "\(recorderManager.upcomingEvents.count) upcoming"
                        : "\(recorderManager.cloudStorage.libraryMeetings.count)"
                )
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(Color.white.opacity(0.4))
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(Color.black.opacity(0.12))
        }
        .background(sidebar)
    }

    private var libraryTabBar: some View {
        HStack(spacing: 2) {
            ForEach(LibraryTab.allCases, id: \.rawValue) { candidate in
                let isSelected = candidate == tab
                Button {
                    switchTab(to: candidate)
                } label: {
                    Text(candidate.label)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? primary : secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var tabTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let insertion = AnyTransition.opacity
            .combined(with: .offset(x: tabMovesForward ? 30 : -30))
        let removal = AnyTransition.opacity
            .combined(with: .offset(x: tabMovesForward ? -18 : 18))
        return .asymmetric(insertion: insertion, removal: removal)
    }

    private func switchTab(to newTab: LibraryTab) {
        guard newTab != tab else { return }
        tabMovesForward = newTab.rawValue > tab.rawValue
        withAnimation(
            reduceMotion
                ? .easeOut(duration: 0.12)
                : .timingCurve(0.23, 1, 0.32, 1, duration: 0.26)
        ) {
            tab = newTab
        }
        if newTab == .comingUp { recorderManager.refreshUpcomingEvents() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(secondary)
            TextField(
                "",
                text: $searchText,
                prompt: Text("Search meetings").foregroundColor(Color.white.opacity(0.34))
            )
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(primary)
            if isSearching { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var pastListContent: some View {
        if visibleMeetings.isEmpty {
            VStack(spacing: 9) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.22))
                Text(searchText.isEmpty ? "Your calls will appear here" : "No matching meetings")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(secondary)
                if searchText.isEmpty {
                    Text("Record a call and OpenRec will keep its transcript, next steps, and selected recordings together.")
                        .font(.system(size: 10))
                        .foregroundColor(Color.white.opacity(0.38))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 210)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 70)
        } else {
            LazyVStack(spacing: 4) {
                ForEach(visibleMeetings) { meeting in
                    MeetingRow(
                        meeting: meeting,
                        selected: selectedID == meeting.id,
                        accent: accent
                    ) {
                        selectMeeting(meeting, forceReload: true)
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            confirmAndDelete(meeting)
                        } label: {
                            Label("Delete Meeting…", systemImage: "trash")
                        }
                        .disabled(meeting.saveStatus == .processing || deletingMeetingID != nil)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    private var upcomingDayGroups: [UpcomingDayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: recorderManager.upcomingEvents) {
            calendar.startOfDay(for: $0.start)
        }
        var days = grouped.keys.sorted().map { day in
            UpcomingDayGroup(day: day, events: grouped[day]!.sorted { $0.start < $1.start })
        }
        // Granola-style: today is always shown, even when it has nothing left.
        let today = calendar.startOfDay(for: Date())
        if !days.contains(where: { $0.day == today }) {
            days.insert(UpcomingDayGroup(day: today, events: []), at: 0)
        }
        return days
    }

    @ViewBuilder
    private var comingUpContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if recorderManager.cloudStorage.calendarEmails.isEmpty {
                connectCalendarCard
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 10)
            }

            if recorderManager.upcomingEvents.isEmpty && recorderManager.isLoadingUpcomingEvents {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .padding(.top, 40)
            } else if recorderManager.upcomingEvents.isEmpty {
                if recorderManager.googleCalendarActive || localCalendarGranted {
                    VStack(spacing: 9) {
                        Image(systemName: "calendar")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.22))
                        Text("Nothing on the calendar")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(secondary)
                        Text("Ongoing and upcoming meetings from your connected calendars will appear here, ready to record.")
                            .font(.system(size: 10))
                            .foregroundColor(Color.white.opacity(0.38))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 220)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 56)
                }
                // Otherwise the connect card above is the whole story.
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(upcomingDayGroups.enumerated()), id: \.element.day) { index, group in
                        if index > 0 {
                            Color.white.opacity(0.07)
                                .frame(height: 1)
                                .padding(.horizontal, 4)
                        }
                        UpcomingDayRow(
                            group: group,
                            accent: accent,
                            adoptedEventID: adoptedEventID,
                            onAdopt: adoptEvent
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
        .onAppear {
            localCalendarGranted = CalendarMeetingSuggester.accessGranted
            recorderManager.refreshUpcomingEvents()
            Task { await recorderManager.cloudStorage.refreshCalendarConnectionStatus() }
        }
    }

    private var sourceRowDivider: some View {
        Color.white.opacity(0.06).frame(height: 1)
            .padding(.leading, 30)
    }

    /// Pinned calendar-sources bar: one row per connected Google account
    /// (additive — connect as many as needed, all merged into one list), plus
    /// the Mac's calendars. Never scrolls away or depends on an empty state.
    private var calendarSourcesBar: some View {
        VStack(spacing: 0) {
            ForEach(recorderManager.cloudStorage.calendarEmails, id: \.self) { email in
                sourceRow(
                    icon: "calendar",
                    title: email,
                    value: "Google Calendar",
                    actionTitle: "Remove",
                    busy: false,
                    help: "Stop reading this account's calendars"
                ) {
                    Task {
                        await recorderManager.cloudStorage.disconnectCalendar(email: email)
                        recorderManager.refreshUpcomingEvents()
                    }
                }
                sourceRowDivider
            }

            sourceRow(
                icon: recorderManager.cloudStorage.calendarEmails.isEmpty ? "calendar.badge.plus" : "plus",
                title: recorderManager.cloudStorage.calendarEmails.isEmpty
                    ? "Google Calendar"
                    : "Add another Google account",
                value: recorderManager.cloudStorage.calendarEmails.isEmpty
                    ? "Not connected"
                    : "All accounts merge into one list",
                actionTitle: recorderManager.cloudStorage.isConnectingCalendar ? "Opening…" : "Connect",
                busy: recorderManager.cloudStorage.isConnectingCalendar,
                help: "Grant read-only calendar access for any Google account — your meeting library stays on the account you signed in with."
            ) {
                connectGoogleCalendar()
            }

            if !localCalendarGranted {
                sourceRowDivider
                sourceRow(
                    icon: "desktopcomputer",
                    title: "Mac calendars",
                    value: "Not connected",
                    actionTitle: "Allow",
                    busy: false,
                    help: "Include calendars from the macOS Calendar app"
                ) {
                    Task {
                        localCalendarGranted = await recorderManager.requestLocalCalendarAccess()
                        recorderManager.refreshUpcomingEvents()
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func sourceRow(
        icon: String,
        title: String,
        value: String,
        actionTitle: String,
        busy: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(Color.white.opacity(0.45))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.78))
                Text(value)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.42))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(action: action) {
                Text(actionTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.88))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.1))
                    )
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .help(help)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
    }

    private var connectCalendarCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Google Calendar", systemImage: "calendar.badge.plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(primary)
            Text("Connect one or more Google accounts and their meetings appear here on one list — each call starts pre-named after the one you're in.")
                .font(.system(size: 10.5))
                .foregroundColor(Color.white.opacity(0.52))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Button(
                recorderManager.cloudStorage.isConnectingCalendar
                    ? "Opening Google…"
                    : "Connect Google Calendar"
            ) {
                connectGoogleCalendar()
            }
            .buttonStyle(LibraryButtonStyle(prominent: true))
            .disabled(recorderManager.cloudStorage.isConnectingCalendar)
            .padding(.top, 3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    private func connectGoogleCalendar() {
        if recorderManager.cloudStorage.mode == .managed && recorderManager.cloudStorage.isManagedSignedIn {
            Task {
                if await recorderManager.cloudStorage.connectGoogleCalendar() {
                    recorderManager.refreshUpcomingEvents()
                }
            }
        } else {
            // Calendar connections attach to the OpenRec Cloud account, so
            // signed-out and own-R2 users start from Settings.
            onOpenSettings?()
        }
    }

    private func adoptEvent(_ event: UpcomingCalendarEvent) {
        recorderManager.adoptUpcomingEvent(event)
        withAnimation(.easeOut(duration: 0.15)) { adoptedEventID = event.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if adoptedEventID == event.id {
                withAnimation(.easeOut(duration: 0.2)) { adoptedEventID = nil }
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let meeting = detail {
            VStack(spacing: 0) {
                detailHeader(meeting)
                Color.white.opacity(0.08).frame(height: 1)
                if isLoadingDetail {
                    ProgressView("Loading meeting…")
                        .controlSize(.small)
                        .foregroundColor(secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    detailContent(meeting)
                        .id(meeting.id)
                        .transition(.opacity)
                }
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "waveform.and.magnifyingglass")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.2))
                Text("Choose a meeting")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(_ meeting: MeetingRecord) -> some View {
        let recovery = MeetingSaveRecovery.live(for: meeting)
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text(meeting.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(primary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(Self.dateFormatter.string(from: meeting.startedAt))
                    Text("·")
                    Text(formatDuration(meeting.durationSeconds))
                    if let app = meeting.callApp, !app.isEmpty {
                        Text("·")
                        Text(app)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(secondary)
            }
            Spacer()
            if meeting.saveStatus == .failed, recovery.canRetry {
                Button("Retry save") { recorderManager.retryFailedMeeting(meeting) }
                    .buttonStyle(LibraryButtonStyle(prominent: false))
                    .disabled(recorderManager.isRecording || recorderManager.isProcessing || recorderManager.isStarting)
                    .help(
                        recovery.cloudMediaAvailable
                            ? "Retry transcription and meeting processing from the cloud recording"
                            : "Retry transcription, upload, and webhook delivery using the legacy recovery file"
                    )
            }
            if meeting.webhookDeliveryStatus == .failed {
                Button("Retry webhook") { recorderManager.retryWebhook(for: meeting) }
                    .buttonStyle(LibraryButtonStyle(prominent: false))
                    .disabled(recorderManager.isRecording || recorderManager.isProcessing || recorderManager.isStarting)
                    .help("Retry only the external webhook; the OpenRec meeting is already safe")
            }
            Button {
                copyMeeting(meeting)
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(LibraryButtonStyle(prominent: false))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private func detailContent(_ meeting: MeetingRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error = detailError ?? meeting.errorMessage {
                    StatusBanner(message: error, icon: "exclamationmark.triangle.fill", color: .orange)
                }
                if let recoveryIssue = MeetingSaveRecovery.live(for: meeting).unavailableReason {
                    StatusBanner(message: recoveryIssue, icon: "externaldrive.badge.xmark", color: .orange)
                }
                if let webhookError = meeting.webhookErrorMessage {
                    StatusBanner(
                        message: "Meeting saved. Webhook delivery needs attention: \(webhookError)",
                        icon: "arrow.triangle.2.circlepath.circle.fill",
                        color: .orange
                    )
                }
                if let mediaError {
                    StatusBanner(message: mediaError, icon: "play.slash.fill", color: .orange)
                }
                if meeting.screenDeletionScheduledAt != nil || meeting.audioDeletionScheduledAt != nil {
                    StatusBanner(
                        message: "Temporary recording access remains available for webhook delivery, then clears automatically.",
                        icon: "clock.badge.checkmark.fill",
                        color: .blue
                    )
                }

                mediaCard(meeting)

                HStack(spacing: 4) {
                    ForEach(MeetingDetailTab.allCases) { tab in
                        Button(tab.rawValue) {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { selectedTab = tab }
                        }
                        .buttonStyle(LibraryTabStyle(selected: selectedTab == tab))
                    }
                    Spacer()
                }

                if selectedTab == .summary {
                    summaryContent(meeting)
                } else {
                    transcriptContent(meeting)
                }
            }
            .padding(22)
        }
    }

    private func mediaCard(_ meeting: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let player {
                NativePlayerView(player: player)
                    .frame(height: playerKind == .screen ? 260 : 72)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 8) {
                if meeting.hasPlayableScreen {
                    mediaButton(meeting, kind: .screen, title: playerKind == .screen ? "Playing screen" : "Play screen")
                }
                if meeting.hasPlayableAudio {
                    mediaButton(meeting, kind: .audio, title: playerKind == .audio ? "Playing audio" : "Play audio")
                }
                if !meeting.hasPlayableScreen && !meeting.hasPlayableAudio {
                    Label("No recording was retained for this call", systemImage: "nosign")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(secondary)
                }
                Spacer()
                if let local = meeting.localScreenURL ?? meeting.localAudioURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([local])
                    } label: {
                        Label("Reveal local copy", systemImage: "finder")
                    }
                    .buttonStyle(LibraryButtonStyle(prominent: false))
                }
            }
        }
        .padding(14)
        .background(card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.06)))
    }

    private func mediaButton(_ meeting: MeetingRecord, kind: MeetingMediaKind, title: String) -> some View {
        Button {
            play(meeting, kind: kind)
        } label: {
            if loadingMedia == kind {
                HStack(spacing: 7) { ProgressView().controlSize(.small); Text("Loading…") }
            } else {
                Label(title, systemImage: kind == .screen ? "play.rectangle.fill" : "waveform.circle.fill")
            }
        }
        .buttonStyle(LibraryButtonStyle(prominent: playerKind != kind))
        .disabled(loadingMedia != nil)
    }

    @ViewBuilder
    private func summaryContent(_ meeting: MeetingRecord) -> some View {
        let insights = meeting.insights
        if !insights.participants.isEmpty {
            MeetingSection(title: "Participants", icon: "person.2.fill") {
                FlowLayout(spacing: 6) {
                    ForEach(insights.participants, id: \.self) { participant in
                        Text(participant)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(primary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Capsule())
                    }
                }
            }
        }

        MeetingSection(title: "AI Notes", icon: "sparkles") {
            if !insights.aiNotes.isEmpty {
                MarkdownNotesView(markdown: insights.aiNotes, textColor: primary, secondaryColor: secondary)
            } else if !insights.summary.isEmpty {
                // Meetings analyzed before AI Notes existed only carry a summary.
                Text(insights.summary)
                    .font(.system(size: 12))
                    .foregroundColor(primary.opacity(0.82))
                    .lineSpacing(3)
                    .textSelection(.enabled)
            } else {
                Text("OpenRec could not generate notes for this call.")
                    .font(.system(size: 12))
                    .foregroundColor(secondary)
            }
        }

        MeetingSection(title: "Next steps", icon: "arrow.up.right.circle.fill") {
            if insights.actionItems.isEmpty {
                Text("No concrete next steps were detected.")
                    .font(.system(size: 12))
                    .foregroundColor(secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(insights.actionItems) { item in
                        HStack(alignment: .top, spacing: 9) {
                            Circle().fill(accent.opacity(0.9)).frame(width: 5, height: 5).padding(.top, 6)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.task)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(primary.opacity(0.88))
                                let metadata = [item.owner.isEmpty ? nil : item.owner, item.dueDate].compactMap { $0 }.joined(separator: " · ")
                                if !metadata.isEmpty {
                                    Text(metadata)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(secondary)
                                }
                            }
                        }
                    }
                }
            }
        }

        MeetingSection(title: "Decisions", icon: "checkmark.seal.fill") {
            if insights.decisions.isEmpty {
                Text("No explicit decisions were detected.")
                    .font(.system(size: 12))
                    .foregroundColor(secondary)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(insights.decisions, id: \.self) { decision in
                        Label(decision, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(primary.opacity(0.82))
                    }
                }
            }
        }
    }

    private func transcriptContent(_ meeting: MeetingRecord) -> some View {
        MeetingSection(title: "Transcript", icon: "text.quote") {
            if let transcript = meeting.transcript, !transcript.isEmpty {
                Text(transcript)
                    .font(.system(size: 12))
                    .foregroundColor(primary.opacity(0.82))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(MeetingLibraryPresentation.emptyTranscriptMessage(for: meeting))
                    .font(.system(size: 12))
                    .foregroundColor(secondary)
            }
        }
    }

    private func selectInitialMeeting() {
        if applyPendingSelection() { return }
        if let selectedID, visibleMeetings.contains(where: { $0.id == selectedID }) { return }
        selectedID = visibleMeetings.first?.id
        if selectedID == nil { detail = nil }
    }

    @discardableResult
    private func applyPendingSelection() -> Bool {
        guard let request = navigation.request,
              handledSelectionToken != request.token,
              let meeting = recorderManager.cloudStorage.libraryMeetings.first(where: { $0.id == request.meetingID }) else {
            return false
        }
        handledSelectionToken = request.token
        searchText = ""
        remoteSearchResults = []
        searchError = nil
        switchTab(to: .past)
        selectMeeting(meeting, forceReload: true)
        return true
    }

    private func selectMeeting(_ meeting: MeetingRecord, forceReload: Bool) {
        if selectedID == meeting.id {
            if forceReload { loadDetail(meeting) }
        } else {
            selectedID = meeting.id
        }
    }

    private func loadDetail(_ meeting: MeetingRecord) {
        detailTask?.cancel()
        mediaTask?.cancel()
        player?.pause()
        player = nil
        playerKind = nil
        loadingMedia = nil
        selectedTab = .summary
        detail = meeting
        detailError = nil
        mediaError = nil
        let shouldLoadCloudDetail = meeting.storageMode == .managed
            && meeting.saveStatus == .saved
            && recorderManager.cloudStorage.isManagedSignedIn
        isLoadingDetail = shouldLoadCloudDetail
        guard shouldLoadCloudDetail else { return }
        let requestedID = meeting.id
        detailTask = Task { @MainActor in
            do {
                let loaded = try await recorderManager.cloudStorage.meetingDetail(for: meeting)
                guard !Task.isCancelled, selectedID == requestedID else { return }
                detail = loaded
            } catch {
                guard !Task.isCancelled, selectedID == requestedID else { return }
                detailError = error.localizedDescription
            }
            if selectedID == requestedID { isLoadingDetail = false }
        }
    }

    private func mergeVisibleDetail(_ updated: MeetingRecord) -> MeetingRecord {
        guard var current = detail, current.id == updated.id else { return updated }
        current.saveStatus = updated.saveStatus
        current.saveStage = updated.saveStage
        current.errorMessage = updated.errorMessage
        current.webhookDeliveryStatus = updated.webhookDeliveryStatus
        current.webhookErrorMessage = updated.webhookErrorMessage
        current.screenDeletionScheduledAt = updated.screenDeletionScheduledAt
        current.audioDeletionScheduledAt = updated.audioDeletionScheduledAt
        current.localScreenPath = updated.localScreenPath
        current.localAudioPath = updated.localAudioPath
        current.hasScreenRecording = updated.hasScreenRecording
        current.hasAudioRecording = updated.hasAudioRecording
        return current
    }

    private func play(_ meeting: MeetingRecord, kind: MeetingMediaKind) {
        mediaTask?.cancel()
        player?.pause()
        loadingMedia = kind
        mediaError = nil
        let requestedID = meeting.id
        mediaTask = Task { @MainActor in
            do {
                let url = try await recorderManager.cloudStorage.mediaURL(for: meeting, kind: kind)
                guard !Task.isCancelled, selectedID == requestedID else { return }
                player?.pause()
                let next = AVPlayer(url: url)
                player = next
                playerKind = kind
                next.play()
            } catch {
                guard !Task.isCancelled, selectedID == requestedID else { return }
                mediaError = error.localizedDescription
            }
            if selectedID == requestedID { loadingMedia = nil }
        }
    }

    /// Deleting is permanent across every copy of the meeting, so spell out
    /// exactly what will be removed before doing anything.
    private func confirmAndDelete(_ meeting: MeetingRecord) {
        var removals = ["its transcript and AI notes"]
        if meeting.hasScreenRecording || meeting.hasAudioRecording { removals.append("the cloud recording") }
        if meeting.localScreenPath != nil || meeting.localAudioPath != nil { removals.append("the local recording file") }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Delete “\(meeting.title)”?"
        alert.informativeText = "This permanently deletes the meeting, including \(removals.joined(separator: ", ")). It cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete Meeting")
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        deletingMeetingID = meeting.id
        Task {
            defer { deletingMeetingID = nil }
            do {
                try await recorderManager.cloudStorage.deleteMeeting(meeting)
                if selectedID == meeting.id {
                    player?.pause()
                    player = nil
                    playerKind = nil
                    selectedID = nil
                    detail = nil
                    selectInitialMeeting()
                }
            } catch {
                let failure = NSAlert()
                failure.messageText = "Could not delete “\(meeting.title)”"
                failure.informativeText = error.localizedDescription
                failure.alertStyle = .warning
                failure.addButton(withTitle: "OK")
                failure.runModal()
            }
        }
    }

    private func copyMeeting(_ meeting: MeetingRecord) {
        var sections = [meeting.title]
        if !meeting.insights.participants.isEmpty { sections.append("Participants: " + meeting.insights.participants.joined(separator: ", ")) }
        if !meeting.insights.aiNotes.isEmpty { sections.append(meeting.insights.aiNotes) }
        else if !meeting.insights.summary.isEmpty { sections.append(meeting.insights.summary) }
        if !meeting.insights.actionItems.isEmpty {
            sections.append("Next steps\n" + meeting.insights.actionItems.map { "• " + ($0.owner.isEmpty ? $0.task : "\($0.owner): \($0.task)") }.joined(separator: "\n"))
        }
        if !meeting.insights.decisions.isEmpty { sections.append("Decisions\n" + meeting.insights.decisions.map { "• \($0)" }.joined(separator: "\n")) }
        if let transcript = meeting.transcript, !transcript.isEmpty { sections.append("Transcript\n\(transcript)") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sections.joined(separator: "\n\n"), forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, remainder) : String(format: "%d:%02d", minutes, remainder)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct UpcomingDayRow: View {
    let group: UpcomingDayGroup
    let accent: Color
    let adoptedEventID: String?
    let onAdopt: (UpcomingCalendarEvent) -> Void

    private var isToday: Bool {
        Calendar.current.isDateInToday(group.day)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .top, spacing: 4) {
                    Text(Self.dayNumberFormatter.string(from: group.day))
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                    if isToday {
                        Circle().fill(accent).frame(width: 5, height: 5).padding(.top, 5)
                    }
                }
                Text(Self.monthFormatter.string(from: group.day))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                Text(Self.weekdayFormatter.string(from: group.day))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
            }
            .frame(width: 56, alignment: .leading)

            VStack(alignment: .leading, spacing: 9) {
                if group.events.isEmpty {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.white.opacity(0.18))
                            .frame(width: 3, height: 26)
                        Text("No more events today")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(.white.opacity(0.38))
                    }
                    .padding(.vertical, 2)
                } else {
                    ForEach(group.events) { event in
                        UpcomingEventRow(
                            event: event,
                            accent: accent,
                            adopted: adoptedEventID == event.id,
                            onAdopt: { onAdopt(event) }
                        )
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
    }

    private static let dayNumberFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d")
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM")
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter
    }()
}

private struct UpcomingEventRow: View {
    let event: UpcomingCalendarEvent
    let accent: Color
    let adopted: Bool
    let onAdopt: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onAdopt) {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isOngoing ? accent : accent.opacity(0.55))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.88))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text("\(Self.timeFormatter.string(from: event.start)) – \(Self.timeFormatter.string(from: event.end))")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.42))
                        if adopted {
                            Label("Set as call name", systemImage: "checkmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.green.opacity(0.85))
                                .transition(.opacity)
                        } else if hovering {
                            Text("Use as call name")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.white.opacity(0.45))
                                .transition(.opacity)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.07 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { value in
            withAnimation(.easeOut(duration: 0.12)) { hovering = value }
        }
        .help("Pre-fill the recorder's call name with this meeting")
    }

    private var isOngoing: Bool {
        let now = Date()
        return event.start <= now && event.end >= now
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

private struct MeetingRow: View {
    let meeting: MeetingRecord
    let selected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(selected ? accent : Color.white.opacity(0.16))
                    .frame(width: 3, height: 34)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(meeting.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color.white.opacity(selected ? 0.94 : 0.78))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if meeting.saveStatus == .failed {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        } else if meeting.webhookDeliveryStatus == .failed {
                            Image(systemName: "arrow.triangle.2.circlepath.circle.fill").foregroundColor(.orange)
                        } else if meeting.saveStatus == .processing {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(Self.rowDate.string(from: meeting.startedAt))
                        if !meeting.insights.participants.isEmpty {
                            Text("·")
                            Text(meeting.insights.participants.prefix(2).joined(separator: ", "))
                        }
                        Spacer(minLength: 2)
                        if meeting.hasPlayableScreen { Image(systemName: "rectangle.inset.filled.and.person.filled") }
                        if meeting.hasPlayableAudio { Image(systemName: "waveform") }
                    }
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.4))
                    .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 9)
            .background(selected ? Color.white.opacity(0.085) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(LibraryPressStyle())
    }

    private static let rowDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d · h:mm a"
        return formatter
    }()
}

private struct MeetingSection<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.54))
                .textCase(.uppercase)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.055)))
    }
}

private struct StatusBanner: View {
    let message: String
    let icon: String
    let color: Color

    var body: some View {
        // Errors recorded before body sanitation existed can be entire web
        // pages; never let a banner grow past a few lines.
        Label(message, systemImage: icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(color.opacity(0.95))
            .lineLimit(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

private struct LibraryPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct LibraryButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(prominent ? .white : Color.white.opacity(0.72))
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(prominent ? Color(red: 1, green: 0.25, blue: 0.28) : Color.white.opacity(0.075))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct LibraryTabStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: selected ? .semibold : .medium))
            .foregroundColor(Color.white.opacity(selected ? 0.92 : 0.46))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(selected ? Color.white.opacity(0.09) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Compact wrapping layout for participant pills (macOS 13+).
private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Renders Granola-style markdown meeting notes: section headers, bullet and
/// numbered lists, and inline emphasis. Intentionally small — it covers the
/// markdown the insights prompt asks for rather than the full spec.
struct MarkdownNotesView: View {
    let markdown: String
    var textColor: Color = .white
    var secondaryColor: Color = Color.white.opacity(0.55)

    private enum Block: Identifiable {
        case header(level: Int, text: String)
        case bullet(indent: Int, text: String)
        case numbered(label: String, text: String)
        case paragraph(text: String)
        case divider

        var id: UUID { UUID() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            let blocks = Self.parse(markdown)
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .header(let level, let text):
            inlineText(text)
                .font(.system(size: level <= 1 ? 14 : (level == 2 ? 13 : 12), weight: .semibold))
                .foregroundColor(textColor.opacity(0.95))
                .padding(.top, 7)
        case .bullet(let indent, let text):
            HStack(alignment: .top, spacing: 7) {
                Text("•")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(secondaryColor)
                inlineText(text)
                    .font(.system(size: 12))
                    .foregroundColor(textColor.opacity(0.82))
                    .lineSpacing(3)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .numbered(let label, let text):
            HStack(alignment: .top, spacing: 7) {
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(secondaryColor)
                inlineText(text)
                    .font(.system(size: 12))
                    .foregroundColor(textColor.opacity(0.82))
                    .lineSpacing(3)
            }
        case .paragraph(let text):
            inlineText(text)
                .font(.system(size: 12))
                .foregroundColor(textColor.opacity(0.82))
                .lineSpacing(3)
        case .divider:
            Color.white.opacity(0.1)
                .frame(height: 1)
                .padding(.vertical, 4)
        }
    }

    private func inlineText(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(text)
    }

    private static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == "---" || line == "***" {
                blocks.append(.divider)
                continue
            }
            if let headerMatch = line.range(of: #"^#{1,4} "#, options: .regularExpression) {
                let level = line.prefix(upTo: headerMatch.upperBound).filter { $0 == "#" }.count
                blocks.append(.header(level: level, text: String(line[headerMatch.upperBound...])))
                continue
            }
            if let bulletMatch = rawLine.range(of: #"^\s*[-*•] "#, options: .regularExpression) {
                let leadingSpaces = rawLine.prefix { $0 == " " || $0 == "\t" }.count
                blocks.append(.bullet(indent: min(leadingSpaces / 2, 3), text: String(rawLine[bulletMatch.upperBound...])))
                continue
            }
            if let numberMatch = line.range(of: #"^\d{1,2}[.)] "#, options: .regularExpression) {
                let label = line.prefix(upTo: numberMatch.upperBound).trimmingCharacters(in: .whitespaces)
                blocks.append(.numbered(label: label, text: String(line[numberMatch.upperBound...])))
                continue
            }
            blocks.append(.paragraph(text: line))
        }
        return blocks
    }
}
