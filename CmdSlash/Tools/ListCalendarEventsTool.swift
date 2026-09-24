import EventKit
import CoreGraphics

/// The `list_calendar_events` tool (Docs/PLANNING.md §21). Read-only, unlike create/delete, so
/// it's low risk (§30) — no confirmation needed.
struct ListCalendarEventsTool {
    /// Identifiable (not just Equatable) so CalendarGridView can hand these straight to ForEach —
    /// title alone isn't a safe id (e.g. a recurring "Gym" appearing twice the same day).
    struct EventSummary: Identifiable {
        let id = UUID()
        let title: String
        let startDate: Date
        let endDate: Date
        let isAllDay: Bool
        let location: String?
        let calendarTitle: String
        /// The source calendar's own color (as set in Calendar.app), so CalendarGridView can
        /// color-code events by calendar the same way Calendar.app itself does, instead of every
        /// event looking identical.
        let calendarColor: CGColor?
    }

    enum ToolError: Error, LocalizedError {
        case invalidDates

        var errorDescription: String? {
            switch self {
            case .invalidDates:
                "Couldn't understand the requested date range."
            }
        }
    }

    private let store = EKEventStore()

    func execute(start: Date, end: Date, maxResults: Int = 25) throws -> [EventSummary] {
        guard end > start else {
            throw ToolError.invalidDates
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            .prefix(maxResults)

        return events.map {
            EventSummary(
                title: $0.title ?? "(untitled)",
                startDate: $0.startDate ?? start,
                endDate: $0.endDate ?? end,
                isAllDay: $0.isAllDay,
                location: $0.location,
                calendarTitle: $0.calendar?.title ?? "Calendar",
                calendarColor: $0.calendar?.cgColor
            )
        }
    }
}
