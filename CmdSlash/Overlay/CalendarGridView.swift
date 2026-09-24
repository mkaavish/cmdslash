import SwiftUI

/// A real visual calendar grid — day columns across an hourly time axis, events drawn as blocks
/// positioned/sized by their actual start time and duration — rendered when
/// `OverlayViewModel.calendarEventsForDisplay` is populated by list_calendar_events. Deliberately
/// not just a nicer text list: the user asked for something that actually looks like Calendar.app.
struct CalendarGridView: View {
    let events: [ListCalendarEventsTool.EventSummary]
    /// The exact range that was queried — days shown come from THIS, not from the events' own
    /// dates. EventKit correctly returns a multi-day all-day event that merely overlaps the query
    /// range (e.g. an assignment window that started days earlier), and deriving day columns from
    /// event dates alone would show an extra day nobody asked about ("what's on my calendar
    /// today" showing a Monday column because of one ongoing multi-day event).
    let rangeStart: Date
    let rangeEnd: Date

    private static let maxDays = 7
    private let hourHeight: CGFloat = 28
    private let timeGutterWidth: CGFloat = 40

    private static let dayLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE M/d")
        return formatter
    }()

    private static let hourLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        return formatter
    }()

    private var days: [Date] {
        let calendar = Calendar.current
        var result: [Date] = []
        var cursor = calendar.startOfDay(for: rangeStart)
        let endDay = calendar.startOfDay(for: rangeEnd)
        while cursor < endDay, result.count < Self.maxDays {
            result.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? endDay
        }
        // A range shorter than a day (shouldn't normally happen — list_calendar_events requires
        // end > start) still shows the one day it does cover, rather than an empty grid.
        return result.isEmpty ? [calendar.startOfDay(for: rangeStart)] : result
    }

    private var timedEvents: [ListCalendarEventsTool.EventSummary] {
        events.filter { !$0.isAllDay }
    }

    private var allDayEvents: [ListCalendarEventsTool.EventSummary] {
        events.filter { $0.isAllDay }
    }

    /// Padded an hour on each side of the earliest/latest timed event, clamped to a sane default
    /// (7am–9pm) so a single early/late outlier doesn't stretch the grid to a nearly-24-hour,
    /// mostly-empty view.
    private var hourRange: (start: Int, end: Int) {
        let calendar = Calendar.current
        guard !timedEvents.isEmpty else { return (7, 21) }
        let startHours = timedEvents.map { calendar.component(.hour, from: $0.startDate) }
        let endHours = timedEvents.map { event -> Int in
            let hour = calendar.component(.hour, from: event.endDate)
            let minute = calendar.component(.minute, from: event.endDate)
            return minute > 0 ? hour + 1 : hour
        }
        let earliest = min(startHours.min() ?? 7, 7)
        let latest = max(endHours.max() ?? 21, 21)
        return (max(0, earliest - 1), min(24, latest + 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            dayHeaderRow
            if !allDayEvents.isEmpty {
                allDayRow
            }
            Divider().opacity(0.2)
            ScrollView {
                timeGrid
            }
        }
    }

    private var dayHeaderRow: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: timeGutterWidth)
            ForEach(days, id: \.self) { day in
                Text(Self.dayLabelFormatter.string(from: day))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, 4)
    }

    private var allDayRow: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer().frame(width: timeGutterWidth)
            ForEach(days, id: \.self) { day in
                VStack(spacing: 2) {
                    ForEach(allDayEvents(on: day)) { event in
                        Text(event.title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Self.color(for: event).opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.bottom, 4)
    }

    private var timeGrid: some View {
        let range = hourRange
        let hours = Array(range.start..<range.end)
        return HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(hours, id: \.self) { hour in
                    Text(Self.hourLabelFormatter.string(from: Self.date(forHour: hour)))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(width: timeGutterWidth, height: hourHeight, alignment: .top)
                }
            }
            ForEach(days, id: \.self) { day in
                dayColumn(day: day, hours: hours)
            }
        }
    }

    private func dayColumn(day: Date, hours: [Int]) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(hours, id: \.self) { _ in
                    VStack(spacing: 0) {
                        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                        Spacer(minLength: 0)
                    }
                    .frame(height: hourHeight)
                }
            }
            ForEach(timedEvents(on: day)) { event in
                eventBlock(event, dayStartHour: hours.first ?? 0)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: CGFloat(hours.count) * hourHeight)
    }

    private func eventBlock(_ event: ListCalendarEventsTool.EventSummary, dayStartHour: Int) -> some View {
        let calendar = Calendar.current
        let startMinutesIntoDay = (calendar.component(.hour, from: event.startDate) - dayStartHour) * 60
            + calendar.component(.minute, from: event.startDate)
        let durationMinutes = max(20, event.endDate.timeIntervalSince(event.startDate) / 60)
        let yOffset = CGFloat(startMinutesIntoDay) / 60 * hourHeight
        let blockHeight = max(CGFloat(durationMinutes) / 60 * hourHeight, 16)

        return Text(event.title)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(2)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: blockHeight, alignment: .top)
            .background(Self.color(for: event).opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 2)
            .offset(y: yOffset)
    }

    /// Falls back to the app's accent color for an event whose calendar has no color set (rare,
    /// but not something EventKit guarantees against).
    private static func color(for event: ListCalendarEventsTool.EventSummary) -> Color {
        event.calendarColor.map { Color($0) } ?? Color.accentColor
    }

    private func timedEvents(on day: Date) -> [ListCalendarEventsTool.EventSummary] {
        let calendar = Calendar.current
        return timedEvents.filter { calendar.isDate($0.startDate, inSameDayAs: day) }
    }

    private func allDayEvents(on day: Date) -> [ListCalendarEventsTool.EventSummary] {
        let calendar = Calendar.current
        return allDayEvents.filter { event in
            let startDay = calendar.startOfDay(for: event.startDate)
            let endDay = calendar.startOfDay(for: event.endDate)
            // EventKit's all-day endDate is exclusive (the day after the last active day) for a
            // genuine multi-day span, but can equal startDate for a single-day event — treat that
            // as covering just that one day, not zero. This overlap check (not an exact same-day
            // match) is what makes a multi-day event show on every day it's actually active,
            // instead of only its nominal start day.
            return day >= startDay && (endDay > startDay ? day < endDay : day == startDay)
        }
    }

    private static func date(forHour hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
    }
}
