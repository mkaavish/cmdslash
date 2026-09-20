import EventKit

/// The `delete_calendar_event` tool (Docs/PLANNING.md §21). Destructive, so it's classified
/// high-risk (§30) and — just as importantly — refuses to guess: it only deletes when exactly one
/// event matches the search, and reports back rather than picking one if the title is ambiguous.
struct DeleteCalendarEventTool {
    struct Result {
        let deletedTitle: String
        let deletedStart: Date
    }

    enum ToolError: Error, LocalizedError {
        case noMatch(String)
        case ambiguous(String, count: Int)
        case deleteFailed(String)
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .noMatch(let title):
                "No event found matching \"\(title)\"."
            case .ambiguous(let title, let count):
                "Found \(count) events matching \"\(title)\" — be more specific, e.g. include the date."
            case .deleteFailed(let reason):
                "Couldn't delete the event: \(reason)"
            case .verificationFailed:
                "The event still appears in the calendar after deletion."
            }
        }
    }

    private let store = EKEventStore()

    /// Searches roughly two months back and forward — wide enough for "delete the lunch with sam
    /// thing" to find an event scheduled last week or next week, narrow enough to stay fast.
    func execute(titleQuery: String, searchWindowDays: Int = 60) throws -> Result {
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -searchWindowDays, to: now) ?? now
        let end = Calendar.current.date(byAdding: .day, value: searchWindowDays, to: now) ?? now

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let matches = store.events(matching: predicate).filter {
            $0.title?.localizedCaseInsensitiveContains(titleQuery) == true
        }

        guard !matches.isEmpty else {
            throw ToolError.noMatch(titleQuery)
        }
        guard matches.count == 1, let event = matches.first else {
            throw ToolError.ambiguous(titleQuery, count: matches.count)
        }

        let title = event.title ?? titleQuery
        let eventStart = event.startDate ?? now
        let identifier = event.eventIdentifier

        do {
            try store.remove(event, span: .thisEvent)
        } catch {
            throw ToolError.deleteFailed(error.localizedDescription)
        }

        if let identifier, store.event(withIdentifier: identifier) != nil {
            throw ToolError.verificationFailed
        }

        return Result(deletedTitle: title, deletedStart: eventStart)
    }
}
