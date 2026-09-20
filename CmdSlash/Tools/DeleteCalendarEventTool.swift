import EventKit

/// The `delete_calendar_event` tool (Docs/PLANNING.md §21). Destructive, so it's classified
/// high-risk (§30) and — just as importantly — refuses to guess: it only deletes when exactly one
/// event matches the search, and reports back rather than picking one if the search is ambiguous.
struct DeleteCalendarEventTool {
    struct Result {
        let deletedTitle: String
        let deletedStart: Date
    }

    enum ToolError: Error, LocalizedError {
        case noCriteria
        case noMatch
        case ambiguous(count: Int)
        case deleteFailed(String)
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .noCriteria:
                "Need a title or an approximate time to find the event to delete."
            case .noMatch:
                "No matching event found."
            case .ambiguous(let count):
                "Found \(count) matching events — be more specific, e.g. include the exact title or time."
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
    /// `titleQuery` and `aroundTime` are both optional but at least one must be provided; when
    /// both are given, an event must match both to be considered.
    func execute(titleQuery: String?, aroundTime: Date?, searchWindowDays: Int = 60) throws -> Result {
        guard titleQuery?.isEmpty == false || aroundTime != nil else {
            throw ToolError.noCriteria
        }

        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -searchWindowDays, to: now) ?? now
        let end = Calendar.current.date(byAdding: .day, value: searchWindowDays, to: now) ?? now

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        var matches = store.events(matching: predicate)

        if let titleQuery, !titleQuery.isEmpty {
            matches = matches.filter { $0.title?.localizedCaseInsensitiveContains(titleQuery) == true }
        }

        if let aroundTime {
            let tolerance: TimeInterval = 30 * 60 // 30 minutes either side
            matches = matches.filter { event in
                guard let eventStart = event.startDate else { return false }
                return abs(eventStart.timeIntervalSince(aroundTime)) <= tolerance
            }
        }

        guard !matches.isEmpty else {
            throw ToolError.noMatch
        }
        guard matches.count == 1, let event = matches.first else {
            throw ToolError.ambiguous(count: matches.count)
        }

        let title = event.title ?? titleQuery ?? "event"
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
