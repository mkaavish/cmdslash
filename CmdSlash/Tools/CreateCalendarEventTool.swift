import EventKit

/// The `create_calendar_event` tool (Docs/PLANNING.md §21) — via `EventKit`, structured rather
/// than clicking through Calendar.app (§22). This is CmdSlash's first medium-risk tool (§30), so
/// it's gated behind explicit confirmation at the call site, not just permission + verification.
struct CreateCalendarEventTool {
    struct Result {
        let eventIdentifier: String
        let title: String
        let startDate: Date
    }

    enum ToolError: Error, LocalizedError {
        case accessDenied
        case invalidDates
        case saveFailed(String)
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                "Calendar access wasn't granted."
            case .invalidDates:
                "Couldn't understand the event's start/end time."
            case .saveFailed(let reason):
                "Couldn't save the event: \(reason)"
            case .verificationFailed:
                "The event didn't appear in the calendar after saving."
            }
        }
    }

    private let store = EKEventStore()

    // Full access, not write-only: verification (below) needs to read the event back after
    // saving it, and it's not confirmed that write-only access still permits reading back an
    // event created in the same session. Worth revisiting once that's confirmed — but getting
    // real verification working correctly matters more than trimming the permission scope now.
    // Callers request access via the shared `CalendarAccess.requestFullAccess()` before calling
    // `execute`.

    func execute(title: String, start: Date, end: Date, notes: String?) throws -> Result {
        guard end > start else { throw ToolError.invalidDates }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.notes = notes
        event.calendar = store.defaultCalendarForNewEvents

        do {
            try store.save(event, span: .thisEvent)
        } catch {
            throw ToolError.saveFailed(error.localizedDescription)
        }

        guard
            let identifier = event.eventIdentifier,
            store.event(withIdentifier: identifier) != nil
        else {
            throw ToolError.verificationFailed
        }

        return Result(eventIdentifier: identifier, title: title, startDate: start)
    }
}
