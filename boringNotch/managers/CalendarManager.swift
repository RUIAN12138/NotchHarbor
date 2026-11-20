//
//  CalendarManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 08/09/24.
//

import Defaults
import EventKit
import OSLog
import SwiftUI

// MARK: - CalendarManager

@MainActor
class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    @Published private(set) var currentDay = Calendar.current.startOfDay(for: Date())
    @Published var currentWeekStartDate: Date
    @Published var events: [EventModel] = []
    @Published var allCalendars: [CalendarModel] = []
    @Published var eventCalendars: [CalendarModel] = []
    @Published var reminderLists: [CalendarModel] = []
    @Published var calendarAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var reminderAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published private(set) var calendarConnectionError: String?
    private var selectedCalendars: [CalendarModel] = []
    private let calendarService = CalendarService()
    private let logger = Logger(subsystem: "theboringteam.boringnotch", category: "CalendarSync")

    @Published private(set) var isLoading = false
    private var queryGeneration = 0
    private var agendaAlertTask: Task<Void, Never>?
    private var shownAgendaAlerts: [String: Date] = [:]
    private var refreshObservers: [NSObjectProtocol] = []
    var hasCalendarAccess: Bool { calendarAuthorizationStatus == .fullAccess }
    var selectedEventCalendarCount: Int { eventCalendars.filter(getCalendarSelected).count }
    var hasSelectedEventCalendar: Bool { selectedEventCalendarCount > 0 }
    var agendaDays: [Date] { AgendaDateRange.days(anchor: currentWeekStartDate) }
    private var eventStoreChangedObserver: NSObjectProtocol?

    private init() {
        self.currentWeekStartDate = CalendarManager.startOfDay(Date())
        setupEventStoreChangedObserver()
        for name in [NSApplication.didBecomeActiveNotification, Notification.Name.NSCalendarDayChanged,
                     NSNotification.Name.NSSystemTimeZoneDidChange] {
            refreshObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.reloadCalendarAndReminderLists() }
            })
        }
        Task {
            await reloadCalendarAndReminderLists()
        }
    }

    deinit {
        refreshObservers.forEach(NotificationCenter.default.removeObserver)
        if let observer = eventStoreChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupEventStoreChangedObserver() {
        eventStoreChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task {
                await self?.reloadCalendarAndReminderLists()
            }
        }
    }

    @MainActor
    func reloadCalendarAndReminderLists() async {
        let today = Calendar.current.startOfDay(for: Date())
        if today != currentDay {
            if currentWeekStartDate == currentDay { currentWeekStartDate = today }
            currentDay = today
        }
        queryGeneration += 1
        let generation = queryGeneration
        calendarAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
        reminderAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
        let all = await calendarService.calendars()
        guard generation == queryGeneration else { return }
        eventCalendars = all.filter { !$0.isReminder }
        reminderLists = all.filter { $0.isReminder }
        allCalendars = all
        updateSelectedCalendars()
        logger.notice("Calendar access \(self.calendarAuthorizationStatus.rawValue, privacy: .public), sources \(self.eventCalendars.count, privacy: .public), selected \(self.selectedCalendars.filter { !$0.isReminder }.count, privacy: .public)")
        await updateEvents()
    }

    func checkCalendarAuthorization() async {
        calendarConnectionError = nil
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined || status == .writeOnly {
            do {
                _ = try await calendarService.requestAccess(to: .event)
            } catch {
                calendarConnectionError = "系统未能完成日历授权，请在系统设置中检查 Notch Harbor 的日历权限。"
            }
        }
        await reloadCalendarAndReminderLists()
    }

    func checkReminderAuthorization() async {
        if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
            _ = try? await calendarService.requestAccess(to: .reminder)
        }
        await reloadCalendarAndReminderLists()
    }

    func updateSelectedCalendars() {
        selectedCalendars = allCalendars.filter { getCalendarSelected($0) }
    }

    func selectAllCalendars() async {
        Defaults[.calendarSelectionState] = .all
        await reloadCalendarAndReminderLists()
    }

    func getCalendarSelected(_ calendar: CalendarModel) -> Bool {
        switch Defaults[.calendarSelectionState] {
        case .all:
            return true
        case .selected(let identifiers):
            return identifiers.contains(calendar.id)
        }
    }

    func setCalendarSelected(_ calendar: CalendarModel, isSelected: Bool) async {
        var selectionState = Defaults[.calendarSelectionState]

        switch selectionState {
        case .all:
            if !isSelected {
                let identifiers = Set(allCalendars.map { $0.id }).subtracting([calendar.id])
                selectionState = .selected(identifiers)
            }

        case .selected(var identifiers):
            if isSelected {
                identifiers.insert(calendar.id)
            } else {
                identifiers.remove(calendar.id)
            }

            selectionState =
                identifiers.count == allCalendars.count ? .all : .selected(identifiers)
        }

        Defaults[.calendarSelectionState] = selectionState
        updateSelectedCalendars()
        await updateEvents()
    }

    static func startOfDay(_ date: Date) -> Date {
        return Calendar.current.startOfDay(for: date)
    }

    func refreshCalendarSources() async {
        calendarService.refreshSources(force: true)
        await reloadCalendarAndReminderLists()
    }

    func updateCurrentDate(_ date: Date) async {
        currentWeekStartDate = Calendar.current.startOfDay(for: date)
        calendarService.refreshSources()
        await reloadCalendarAndReminderLists()
    }

    private func updateEvents() async {
        queryGeneration += 1
        let generation = queryGeneration
        isLoading = true
        let anchor = currentWeekStartDate
        let selected = selectedCalendars
        let end = AgendaDateRange.end(anchor: anchor)
        let calendarEvents = await calendarService.events(
            from: anchor, to: end, calendars: selected.filter { !$0.isReminder }.map(\.id))
        guard generation == queryGeneration else { return }
        logger.notice("Read \(calendarEvents.count, privacy: .public) calendar events for displayed dates")
        let reminders = await calendarService.events(
            from: anchor, to: AgendaDateRange.end(anchor: anchor),
            calendars: selected.filter(\.isReminder).map(\.id))
        guard generation == queryGeneration else { return }
        var seen = Set<String>()
        let result = (calendarEvents + reminders).filter { seen.insert($0.agendaOccurrenceID).inserted }
            .sorted { $0.start == $1.start ? $0.agendaOccurrenceID < $1.agendaOccurrenceID : $0.start < $1.start }
        events = result
        isLoading = false
        let today = currentDay
        let alertEvents = anchor == today ? result : await calendarService.events(
            from: today, to: AgendaDateRange.end(anchor: today),
            calendars: selectedCalendars.map(\.id))
        guard generation == queryGeneration else { return }
        scheduleAgendaAlerts(alertEvents)
    }

    private func scheduleAgendaAlerts(_ events: [EventModel]) {
        agendaAlertTask?.cancel()
        let eligible = events.filter { event in
            guard !event.isAllDay else { return false }
            switch event.type {
            case .event(let status): return status != .declined && hasCalendarAccess
            case .reminder(let completed): return !completed && reminderAuthorizationStatus == .fullAccess
            case .birthday: return false
            }
        }.sorted { $0.start < $1.start }
        agendaAlertTask = Task { @MainActor [weak self] in
            for event in eligible {
                let lead: TimeInterval = event.type.isReminder ? 0 : 600
                let delay = event.start.timeIntervalSinceNow - lead
                if delay > 0 { try? await Task.sleep(until: .now + .seconds(delay), clock: .continuous) }
                guard !Task.isCancelled, let self else { return }
                let now = Date()
                guard Defaults[.notchCalendarAlerts], now < event.start.addingTimeInterval(60) else { continue }
                let identity = event.id + ":" + String(event.start.timeIntervalSince1970)
                self.shownAgendaAlerts = self.shownAgendaAlerts.filter { $0.value > now }
                guard self.shownAgendaAlerts[identity] == nil else { continue }
                self.shownAgendaAlerts[identity] = event.start.addingTimeInterval(60)
                UnifiedActivities.shared.showCalendarAlert(id: identity, title: event.title, date: event.start)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
    

    func setReminderCompleted(reminderID: String, completed: Bool) async {
        await calendarService.setReminderCompleted(reminderID: reminderID, completed: completed)
        await updateEvents()
    }
}

// === AGENDA_DATE_RANGE_BEGIN ===
/// Calendar arithmetic keeps today/tomorrow correct across DST and local zones.
enum AgendaDateRange {
    static func days(anchor: Date, now: Date = Date(), calendar: Calendar = .current) -> [Date] {
        let start = calendar.startOfDay(for: anchor)
        let count = calendar.isDate(start, inSameDayAs: now) ? 2 : 1
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
    static func end(anchor: Date, now: Date = Date(), calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: anchor)
        return calendar.date(byAdding: .day, value: days(anchor: anchor, now: now, calendar: calendar).count, to: start) ?? start
    }
    static func occurrenceKey(calendarID: String, eventID: String, start: Date, end: Date) -> String {
        "\(calendarID.utf8.count):\(calendarID)\(eventID.utf8.count):\(eventID):\(start.timeIntervalSinceReferenceDate):\(end.timeIntervalSinceReferenceDate)"
    }
    static func overlaps(start: Date, end: Date, day: Date, calendar: Calendar = .current) -> Bool {
        let lower = calendar.startOfDay(for: day)
        guard let upper = calendar.date(byAdding: .day, value: 1, to: lower) else { return false }
        return start < upper && (end > lower || (start == end && start >= lower))
    }
}
// === AGENDA_DATE_RANGE_END ===
