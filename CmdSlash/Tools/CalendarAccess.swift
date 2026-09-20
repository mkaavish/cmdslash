import EventKit

/// Shared Calendar permission gate for both calendar tools (Docs/PLANNING.md §45).
enum CalendarAccess {
    static func requestFullAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            EKEventStore().requestFullAccessToEvents { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }
}
