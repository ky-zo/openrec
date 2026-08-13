import EventKit
import Foundation

/// A calendar event OpenRec can show in the Meetings window or use to name a
/// call, independent of whether it came from EventKit or Google Calendar.
struct UpcomingCalendarEvent: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date
}

/// Looks up the calendar event happening around "now" so a call can be
/// pre-named after the meeting the user is actually in. Google, Exchange,
/// and iCloud calendars all surface through EventKit once their accounts
/// are added to macOS Calendar.
final class CalendarMeetingSuggester {
    /// People usually hit record a few minutes before the scheduled start,
    /// so an event starting this soon already counts as the current meeting.
    private let upcomingGrace: TimeInterval = 10 * 60

    private let store = EKEventStore()

    /// The title of the ongoing or imminently starting calendar event, or nil
    /// when there is none or calendar access was declined.
    func currentMeetingTitle() async -> String? {
        guard await ensureAccess() else { return nil }
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now,
            end: now.addingTimeInterval(upcomingGrace),
            calendars: nil
        )
        return store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .compactMap { event -> (title: String, distance: TimeInterval)? in
                guard let start = event.startDate,
                      let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty else { return nil }
                return (title, abs(start.timeIntervalSince(now)))
            }
            .min { $0.distance < $1.distance }?
            .title
    }

    /// Ongoing and upcoming non-all-day events over the next few days, sorted
    /// by start time. Empty when there are none or access was declined.
    func upcomingEvents(withinDays days: Int = 7, maxCount: Int = 30) async -> [UpcomingCalendarEvent] {
        guard await ensureAccess() else { return [] }
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: max(1, days), to: now) ?? now.addingTimeInterval(86_400)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        var seen = Set<String>()
        return store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .compactMap { event -> UpcomingCalendarEvent? in
                guard let start = event.startDate,
                      let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty else { return nil }
                let id = event.eventIdentifier ?? "\(title)-\(start.timeIntervalSince1970)"
                guard seen.insert(id).inserted else { return nil }
                return UpcomingCalendarEvent(
                    id: id,
                    title: title,
                    start: start,
                    end: event.endDate ?? start
                )
            }
            .sorted { $0.start < $1.start }
            .prefix(maxCount)
            .map { $0 }
    }

    /// Ask for calendar access now (used by onboarding's optional step).
    func requestAccess() async -> Bool {
        await ensureAccess()
    }

    /// Whether the app already holds read access to the Mac's calendars.
    static var accessGranted: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            return status == .fullAccess
        }
        return status == .authorized
    }

    private func ensureAccess() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            switch status {
            case .fullAccess:
                return true
            case .notDetermined:
                return (try? await store.requestFullAccessToEvents()) ?? false
            default:
                return false
            }
        } else {
            switch status {
            case .authorized:
                return true
            case .notDetermined:
                return (try? await store.requestAccess(to: .event)) ?? false
            default:
                return false
            }
        }
    }
}
