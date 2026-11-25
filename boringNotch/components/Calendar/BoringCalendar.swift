//
//  BoringCalendar.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 08/09/24.
//

import Defaults
import EventKit
import SwiftUI

struct Config: Equatable {
    //    var count: Int = 10  // 3 days past + today + 7 days future
    var past: Int = 7
    var future: Int = 14
    var steps: Int = 1  // Each step is one day
    var spacing: CGFloat = 0
    var showsText: Bool = true
    var offset: Int = 3  // Half of the seven visible dates
}

struct WheelPicker: View {
    @EnvironmentObject var vm: BoringViewModel
    @Binding var selectedDate: Date
    @State private var scrollPosition: Int?
    @State private var haptics: Bool = false
    @State private var byClick: Bool = false
    let config: Config
    var rowHeight: CGFloat = 50

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: config.spacing) {
                let spacerNum = config.offset
                let dateCount = totalDateItems()
                let totalItems = dateCount + 2 * spacerNum
                ForEach(0..<totalItems, id: \.self) { index in
                    if index < spacerNum || index >= spacerNum + dateCount {
                        // Leading/trailing spacers sized to match a date cell
                        Color.clear
                            .frame(height: rowHeight)
                            .containerRelativeFrame(.horizontal, count: 7, spacing: config.spacing)
                            .id(index)
                    } else {
                        let date = dateForItemIndex(index: index, spacerNum: spacerNum)
                        let isSelected = Calendar.current.isDate(date, inSameDayAs: selectedDate)
                        dateButton(date: date, isSelected: isSelected, id: index) {
                            selectedDate = date
                            byClick = true
                            withAnimation {
                                scrollPosition = index
                            }
                            if Defaults[.enableHaptics] {
                                haptics.toggle()
                            }
                        }
                        .containerRelativeFrame(.horizontal, count: 7, spacing: config.spacing)
                    }
                }
            }
            .frame(height: rowHeight)
            .scrollTargetLayout()
        }
        .scrollIndicators(.never)
        .reservesHorizontalNotchScrolling()
        .scrollPosition(id: $scrollPosition, anchor: .center)
        .scrollTargetBehavior(.viewAligned)  // Ensures scroll view snaps the centered view
        .sensoryFeedback(.alignment, trigger: haptics)
        .onChange(of: scrollPosition) { oldValue, newValue in
            if !byClick {
                handleScrollChange(newValue: newValue, config: config)
            } else {
                byClick = false
            }
        }
        .onAppear {
            scrollToToday(config: config)
        }
        // When parent updates the bound selectedDate (e.g., view reopen), center the wheel on it
        .onChange(of: selectedDate) { _, newValue in
            let targetIndex = indexForDate(newValue)
            if scrollPosition != targetIndex {
                byClick = true
                withAnimation {
                    scrollPosition = targetIndex
                }
            }
        }
    }

    private func dateButton(
        date: Date, isSelected: Bool, id: Int, onClick: @escaping () -> Void
    ) -> some View {
        let isToday = Calendar.current.isDateInToday(date)
        return Button(action: onClick) {
            VStack(spacing: rowHeight < 45 ? 2 : 8) {
                dayText(date: dateToString(for: date), isToday: isToday, isSelected: isSelected)
                dateCircle(date: date, isToday: isToday, isSelected: isSelected)
            }
            .padding(.vertical, rowHeight < 45 ? 1 : 4)
            .padding(.horizontal, 4)
            .background(isSelected ? Color.effectiveAccentBackground : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(PlainButtonStyle())
        .id(id)
    }

    private func dayText(date: String, isToday: Bool, isSelected: Bool) -> some View {
        Text(date)
            .font(.caption)
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
    }

    private func dateCircle(date: Date, isToday: Bool, isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(isToday ? Color.effectiveAccent : .clear)
                .frame(width: 20, height: 20)
                .overlay(
                    Circle()
                        .stroke(Color.gray.opacity(0.3), lineWidth: 0)
                )
            Text("\(date.date)")
                .font(.body)
                .fontWeight(.medium)
                .foregroundStyle(isSelected || isToday ? Color.white : Color.secondary)
        }
    }

    func handleScrollChange(newValue: Int?, config: Config) {
        guard let newIndex = newValue else { return }
        let spacerNum = config.offset
        let dateCount = totalDateItems()
        guard (spacerNum..<(spacerNum + dateCount)).contains(newIndex) else { return }
        let date = dateForItemIndex(index: newIndex, spacerNum: spacerNum)
        if !Calendar.current.isDate(date, inSameDayAs: selectedDate) {
            selectedDate = date
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        }
    }

    private func scrollToToday(config: Config) {
        let today = Date()
        byClick = true
        scrollPosition = indexForDate(today)
        selectedDate = today
    }

    // MARK: - Index/Date mapping with steps and spacers
    private func indexForDate(_ date: Date) -> Int {
        let spacerNum = config.offset
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let startDate = cal.startOfDay(for: cal.date(byAdding: .day, value: -config.past, to: today) ?? today)
        let target = cal.startOfDay(for: date)
        let days = cal.dateComponents([.day], from: startDate, to: target).day ?? 0
        let stepIndex = max(0, min(days / max(config.steps, 1), totalDateItems() - 1))
        return spacerNum + stepIndex
    }

    private func dateForItemIndex(index: Int, spacerNum: Int) -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let startDate = cal.date(byAdding: .day, value: -config.past, to: today) ?? today
        let stepIndex = index - spacerNum
        return cal.date(byAdding: .day, value: stepIndex * max(config.steps, 1), to: startDate) ?? today
    }

    private func totalDateItems() -> Int {
        let range = config.past + config.future
        let step = max(config.steps, 1)
        return Int(ceil(Double(range) / Double(step))) + 1
    }

    private func dateToString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "E"
        return formatter.string(from: date)
    }
}

struct CalendarView: View {
    @ObservedObject private var calendarManager = CalendarManager.shared
    @State private var selectedDate = Date()

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .center, spacing: 7) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedDate.formatted(.dateTime.month(.abbreviated))).notchReadableText()
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Text(selectedDate.formatted(.dateTime.year()))
                        .font(.caption)
                        .fontWeight(.light)
                        .foregroundColor(Color.secondary)
                }
                .fixedSize(horizontal: true, vertical: false)

                WheelPicker(selectedDate: $selectedDate, config: Config(), rowHeight: 33)
                    .mask {
                        HStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 20)
                            Rectangle().fill(.black)
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 20)
                        }
                    }
                    .frame(height: 33)
                if calendarManager.hasCalendarAccess {
                    Menu {
                        Button("刷新系统日历来源") { Task { await calendarManager.refreshCalendarSources() } }
                        if calendarManager.selectedEventCalendarCount < calendarManager.eventCalendars.count {
                            Button("显示全部日历") { Task { await calendarManager.selectAllCalendars() } }
                        }
                    } label: {
                        let available = calendarManager.eventCalendars.count
                        let shown = calendarManager.selectedEventCalendarCount
                        Label("\(shown)/\(available)", systemImage: "calendar.badge.checkmark")
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(shown < available ? .primary : .secondary)
                    }
                    .fixedSize()
                    .menuStyle(.borderlessButton)
                    .help("已启用 \(calendarManager.selectedEventCalendarCount) 个，共 \(calendarManager.eventCalendars.count) 个系统日历")
                }
            }
            .padding(.horizontal, 8)
            if !calendarManager.hasCalendarAccess {
                CalendarConnectionView()
            } else if calendarManager.isLoading && calendarManager.events.isEmpty {
                ProgressView("正在读取日程…").controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 35)
            } else if calendarManager.eventCalendars.isEmpty || !calendarManager.hasSelectedEventCalendar {
                VStack(spacing: 6) {
                    Text(calendarManager.eventCalendars.isEmpty ? "系统没有返回可读日历" : "当前没有选中任何日历")
                        .font(.subheadline)
                    Button(calendarManager.eventCalendars.isEmpty ? "重新读取" : "显示所有日历") {
                        if calendarManager.eventCalendars.isEmpty {
                            Task { await calendarManager.refreshCalendarSources() }
                        } else {
                            Task { await calendarManager.selectAllCalendars() }
                        }
                    }
                    .buttonStyle(.bordered)
                    if !calendarManager.events.isEmpty {
                        EventListView(events: calendarManager.events, days: calendarManager.agendaDays, compact: true)
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                EventListView(events: calendarManager.events, days: calendarManager.agendaDays, compact: true)
            }
        }
        .listRowBackground(Color.clear)
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: calendarManager.currentDay) { _, day in
            if calendarManager.currentWeekStartDate == day { selectedDate = day }
        }
        .task(id: Calendar.current.startOfDay(for: selectedDate)) {
            await calendarManager.updateCurrentDate(selectedDate)
        }
    }

}

private struct CalendarConnectionView: View {
    @ObservedObject private var manager = CalendarManager.shared
    @State private var checking = false
    var body: some View {
        VStack(spacing: 4) {
            Text(manager.calendarConnectionError ?? (manager.calendarAuthorizationStatus == .restricted
                 ? "系统限制了日历访问" : "查看今天和明天的日程需要日历完整访问权限"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 5) {
                if manager.calendarAuthorizationStatus == .notDetermined || manager.calendarAuthorizationStatus == .writeOnly {
                    Button(checking ? "正在申请…" : "连接系统日历") {
                        checking = true
                        Task {
                            await manager.checkCalendarAuthorization()
                            checking = false
                        }
                    }
                    .disabled(checking)
                    .buttonStyle(.bordered)
                }
                Button("打开日历权限设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("重新读取") { Task { await manager.reloadCalendarAndReminderLists() } }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .task {
            while !Task.isCancelled && !manager.hasCalendarAccess {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                if EKEventStore.authorizationStatus(for: .event) != manager.calendarAuthorizationStatus {
                    await manager.reloadCalendarAndReminderLists()
                }
            }
        }
    }
}

struct EmptyEventsView: View {
    @Environment(\.usesSharedGlassShell) private var usesSharedGlassShell
    let selectedDate: Date
    var includesTomorrow = false
    var hasFilteredEvents = false

    var body: some View {
        VStack {
            Image(systemName: "calendar.badge.checkmark")
                .font(.title)
                .foregroundColor(usesSharedGlassShell ? Color.primary.opacity(0.85) : Color.secondary)
                .sharedGlassForeground()
            Text(hasFilteredEvents ? "当前筛选隐藏了日程" : includesTomorrow ? "今天和明天暂无日程" : "当天暂无日程")
                .font(.subheadline)
                .foregroundColor(.primary)
                .sharedGlassForeground()
            Text(hasFilteredEvents ? "可在设置中调整全天事件与已完成提醒" : "新日程会自动出现在这里")
                .font(.caption)
                .foregroundColor(usesSharedGlassShell ? Color.primary.opacity(0.85) : Color.secondary)
                .sharedGlassForeground()
        }
    }
}

struct EventListView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject private var calendarManager = CalendarManager.shared
    let events: [EventModel]
    var days: [Date] = []
    var compact = false
    @Default(.autoScrollToNextEvent) private var autoScrollToNextEvent
    @Default(.showFullEventTitles) private var showFullEventTitles


    static func filteredEvents(events: [EventModel]) -> [EventModel] {
        events.filter { event in
            if event.type.isReminder {
                if case .reminder(let completed) = event.type {
                    return !completed || !Defaults[.hideCompletedReminders]
                }
            }
            // Filter out all-day events if setting is enabled
            if event.isAllDay && Defaults[.hideAllDayEvents] {
                return false
            }
            return true
        }
    }

    private var filteredEvents: [EventModel] {
        Self.filteredEvents(events: events)
    }

    private func scrollToRelevantEvent(proxy: ScrollViewProxy) {
        guard autoScrollToNextEvent else { return }
        let now = Date()
        // Determine a single target using preferred search order:
        // 1) first non-all-day upcoming/in-progress event
        // 2) first all-day event
        // 3) last event (fallback)
        let nonAllDayUpcoming = filteredEvents.first(where: { !$0.isAllDay && $0.end > now })
        let firstAllDay = filteredEvents.first(where: { $0.isAllDay })
        let lastEvent = filteredEvents.last
        guard let target = nonAllDayUpcoming ?? firstAllDay ?? lastEvent else { return }

        Task { @MainActor in
            withTransaction(Transaction(animation: nil)) {
                proxy.scrollTo(rowID(target, day: days.count > 1 ? max(Calendar.current.startOfDay(for: target.start), days[0]) : nil), anchor: .top)
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            HStack(alignment: .top, spacing: 16) {
                if days.isEmpty {
                    agendaList(filteredEvents, day: nil)
                }
                ForEach(days, id: \.self) { day in
                    VStack(alignment: .leading, spacing: compact ? 2 : 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(Calendar.current.isDateInToday(day) ? "今天" : Calendar.current.isDateInTomorrow(day) ? "明天" : day.formatted(.dateTime.weekday(.wide)))
                                .font(.system(size: 12, weight: .semibold))
                            Spacer(minLength: 4)
                            Text(day.formatted(.dateTime.month(.twoDigits).day(.twoDigits)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)

                        let dayEvents = filteredEvents.filter {
                            AgendaDateRange.overlaps(start: $0.start, end: $0.end, day: day)
                        }
                        if dayEvents.isEmpty {
                            Text(events.isEmpty ? "暂无日程" : "当前没有可显示的日程")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .padding(.horizontal, 8).padding(.top, compact ? 2 : 8)
                        } else {
                            agendaList(dayEvents, day: days.count > 1 ? day : nil)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .onAppear {
                scrollToRelevantEvent(proxy: proxy)
            }
            .onChange(of: filteredEvents) { _, _ in
                scrollToRelevantEvent(proxy: proxy)
            }
        }
    }

    private func agendaList(_ events: [EventModel], day: Date?) -> some View {
        List {
            ForEach(events, id: \.agendaOccurrenceID) { event in selectableRow(event, day: day) }
        }
        .listStyle(.plain)
        .scrollIndicators(.never)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    private func rowID(_ event: EventModel, day: Date?) -> String {
        day.map { "\($0.timeIntervalSince1970)-\(event.agendaOccurrenceID)" } ?? event.agendaOccurrenceID
    }

    private func selectableRow(_ event: EventModel, day: Date?) -> some View {
        Button {
            if let url = event.calendarAppURL() { openURL(url) }
        } label: {
            if compact {
                HStack(spacing: 4) {
                    Circle().fill(Color(event.calendar.color)).frame(width: 4, height: 4)
                    Text(event.title).notchReadableText().font(.caption).lineLimit(1)
                    Spacer(minLength: 3)
                    if event.isAllDay { Text("全天").font(.caption2) }
                    else { Text(event.start, style: .time).notchReadableText().font(.caption2) }
                }
                .frame(minHeight: 19)
                .contentShape(Rectangle())
            } else {
                eventRow(event)
            }
        }
        .id(rowID(event, day: day))
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: compact ? 0 : 3, leading: 7, bottom: compact ? 0 : 3, trailing: 7))
        .listRowSeparator(.automatic)
        .listRowSeparatorTint(.gray.opacity(0.2))
        .listRowBackground(Color.clear)
    }

    private func eventRow(_ event: EventModel) -> some View {
        if event.type.isReminder {
            let isCompleted: Bool
            if case .reminder(let completed) = event.type {
                isCompleted = completed
            } else {
                isCompleted = false
            }
            return AnyView(
                HStack(spacing: 8) {
                    ReminderToggle(
                        isOn: Binding(
                            get: { isCompleted },
                            set: { newValue in
                                Task {
                                    await calendarManager.setReminderCompleted(
                                        reminderID: event.id, completed: newValue
                                    )
                                }
                            }
                        ),
                        color: Color(event.calendar.color)
                    )
                    .opacity(1.0)  // Ensure the toggle is always fully opaque
                    HStack {
                        Text(event.title).notchReadableText()
                            .font(.callout)
                            .foregroundColor(.primary)
                            .lineLimit(showFullEventTitles ? nil : 1)
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 4) {
                            if event.isAllDay {
                                Text("全天")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                            } else {
                                Text(event.start, style: .time).notchReadableText()
                                    .foregroundColor(.primary)
                                    .font(.caption)
                            }
                        }
                    }
                    .opacity(
                        isCompleted
                            ? 0.4
                            : event.start < Date.now && Calendar.current.isDateInToday(event.start)
                                ? 0.6 : 1.0
                    )
                }
                .padding(.vertical, 4)
            )
        } else {
            return AnyView(
                HStack(alignment: .top, spacing: 4) {
                    Rectangle()
                        .fill(Color(event.calendar.color))
                        .frame(width: 3)
                        .cornerRadius(1.5)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title).notchReadableText()
                            .font(.callout)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                            .lineLimit(showFullEventTitles ? nil : 2)

                        if let location = event.location, !location.isEmpty {
                            Text(location)
                                .font(.caption)
                                .foregroundColor(Color.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 4) {
                        if event.isAllDay {
                            Text("全天")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        } else {
                            Text(event.start, style: .time).notchReadableText()
                                .foregroundColor(.primary)
                            Text(event.end, style: .time)
                                .foregroundColor(Color.secondary)
                        }
                    }
                    .font(.caption)
                    .frame(minWidth: 44, alignment: .trailing)
                }
                .opacity(
                    event.eventStatus == .ended && Calendar.current.isDateInToday(event.start)
                        ? 0.6 : 1.0)
            )
        }
    }
}

struct ReminderToggle: View {
    @Binding var isOn: Bool
    var color: Color

    var body: some View {
        Button(action: {
            isOn.toggle()
        }) {
            ZStack {
                // Outer ring
                Circle()
                    .strokeBorder(color, lineWidth: 2)
                    .frame(width: 14, height: 14)
                // Inner fill
                if isOn {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                }
                Circle()
                    .fill(Color.black.opacity(0.001))
                    .frame(width: 14, height: 14)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .padding(0)
        .accessibilityLabel(isOn ? "Mark as incomplete" : "Mark as complete")
    }
}

#Preview {
    CalendarView()
        .frame(width: 215, height: 130)
        .background(.black)
        .environmentObject(BoringViewModel())
}
