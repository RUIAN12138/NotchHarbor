import AppKit
import Charts
import SwiftUI

enum AgentQuotaRings {
    static let outerMinutes = 300
    static let innerMinutes = 10_080
    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 16
        return cache
    }()

    struct Levels: Hashable {
        let outer: Double?
        let inner: Double?

        init(usage: AgentProviderUsage, at now: Double) {
            outer = usage.window(minutes: AgentQuotaRings.outerMinutes, at: now)?.remaining
            inner = usage.window(minutes: AgentQuotaRings.innerMinutes, at: now)?.remaining
        }
    }

    static func image(for usage: AgentProviderUsage, at now: Double = Date().timeIntervalSince1970) -> NSImage {
        image(for: Levels(usage: usage, at: now))
    }

    static func image(for levels: Levels) -> NSImage {
        let key = "\(levels.outer?.bitPattern ?? 0):\(levels.inner?.bitPattern ?? 0):\(levels.outer == nil):\(levels.inner == nil)" as NSString
        if let cached = images.object(forKey: key) { return cached }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            drawRing(center: center, radius: 7, remaining: levels.outer)
            drawRing(center: center, radius: 3.75, remaining: levels.inner)
            return true
        }
        image.isTemplate = true
        images.setObject(image, forKey: key)
        return image
    }

    private static func drawRing(center: NSPoint, radius: CGFloat, remaining: Double?) {
        let bounds = NSRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
        let track = NSBezierPath(ovalIn: bounds)
        track.lineWidth = 1.4
        NSColor.black.withAlphaComponent(remaining == nil ? 0.17 : 0.32).setStroke()
        track.stroke()

        guard let remaining, remaining > 0 else { return }
        let arc = NSBezierPath()
        arc.lineWidth = track.lineWidth
        arc.lineCapStyle = .round
        if remaining >= 100 {
            arc.appendOval(in: bounds)
        } else {
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                          endAngle: 90 - 3.6 * remaining, clockwise: true)
        }
        NSColor.black.setStroke()
        arc.stroke()
    }
}

@MainActor
final class AgentAPIUsageLedger: ObservableObject {
    static let shared = AgentAPIUsageLedger()

    struct DailyUsage: Codable {
        let date: Date
        var requests = 0
        var requestsWithTokens = 0
        var tokens = 0
    }

    private let key = "agentSuggestionAPIUsageToday"
    @Published private var latest: DailyUsage?

    var today: DailyUsage? { latest.flatMap { Calendar.current.isDateInToday($0.date) ? $0 : nil } }

    private init() {
        if let data = UserDefaults.standard.data(forKey: key) {
            latest = try? JSONDecoder().decode(DailyUsage.self, from: data)
        }
    }

    nonisolated static func responseTokens(_ data: Data) -> Int? {
        struct Response: Decodable {
            struct Usage: Decodable {
                var total_tokens: Int?
                var prompt_tokens: Int?
                var completion_tokens: Int?
            }
            var usage: Usage?
        }
        guard data.count <= 500_000,
              let usage = (try? JSONDecoder().decode(Response.self, from: data))?.usage else { return nil }
        func valid(_ value: Int?) -> Int? { value.flatMap { (0...10_000_000_000).contains($0) ? $0 : nil } }
        if let total = valid(usage.total_tokens) { return total }
        guard let input = valid(usage.prompt_tokens), let output = valid(usage.completion_tokens) else { return nil }
        return input + output
    }

    func recordResponse(_ data: Data) {
        var usage = today ?? DailyUsage(date: Date())
        usage.requests += 1
        if let tokens = Self.responseTokens(data) {
            usage.requestsWithTokens += 1
            usage.tokens += tokens
        }
        latest = usage
        if let data = try? JSONEncoder().encode(usage) { UserDefaults.standard.set(data, forKey: key) }
    }
}

enum AgentUsageSelection {
    static let key = "agentUsageMenuProvider"
    static let replyAPIID = "tideislet-reply-api"
    static let replyAPIName = "快捷回复 API"

    case provider(AgentProviderUsage)
    case replyAPI(AgentAPIUsageLedger.DailyUsage?)
    case unavailable

    static func resolve(_ providers: [AgentProviderUsage], preferred: String, active: String?,
                        apiEnabled: Bool, today: AgentAPIUsageLedger.DailyUsage?) -> Self {
        let hasAPI = apiEnabled || today != nil
        if hasAPI && preferred == replyAPIID { return .replyAPI(today) }
        if let provider = AgentProviderUsage.selected(from: providers, preferred: preferred, active: active) {
            return .provider(provider)
        }
        return hasAPI ? .replyAPI(today) : .unavailable
    }

    static func compactBilling(_ usage: AgentProviderUsage) -> String? {
        if let bill = usage.billing {
            if let used = bill.used { return amount(used, bill.currencyCode) }
            if let balance = bill.balance { return amount(balance, bill.currencyCode) }
            if let limit = bill.limit { return amount(limit, bill.currencyCode) }
        }
        return usage.localTokens30Days.map { $0.formatted(.number.notation(.compactName)) + " Tokens" }
    }

    static func apiLabel(_ usage: AgentAPIUsageLedger.DailyUsage?) -> String {
        guard let usage else { return "API" }
        if usage.requestsWithTokens > 0 { return "API " + usage.tokens.formatted(.number.notation(.compactName)) }
        return "API \(usage.requests) 次"
    }

    static func amount(_ value: Double, _ code: String) -> String {
        if Locale.Currency.isoCurrencies.contains(where: { $0.identifier == code.uppercased() }) {
            return value.formatted(.currency(code: code.uppercased()))
        }
        return value.formatted(.number.precision(.fractionLength(0...2))) + " " + code
    }
}

enum HarborMenuMetric: String, CaseIterable {
    static let key = "harborMenuMetric"
    case quota, memory

    var title: String { self == .quota ? "额度" : "内存压力" }

    static func applyMemory(to button: NSStatusBarButton, snapshot: MenuMemorySnapshot?) {
        let pressure = snapshot?.pressure ?? .unknown
        let image = memoryImages[pressure]
        if button.image !== image { button.image = image }
        if !button.title.isEmpty { button.title = "" }
        let title = "Notch Harbor · 内存" + (snapshot.map { " · " + $0.pressure.label } ?? "")
        button.setAccessibilityLabel(title)
        button.toolTip = title
    }

    private static let memoryImages: [MenuMemorySnapshot.Pressure: NSImage] = {
        Dictionary(uniqueKeysWithValues: [MenuMemorySnapshot.Pressure.unknown, .normal, .warning, .critical].map { pressure in
            let filled = switch pressure {
            case .unknown: 0
            case .normal: 1
            case .warning: 2
            case .critical: 3
            }
            let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
                for index in 0..<3 {
                    NSColor.black.withAlphaComponent(index < filled ? 1 : 0.29).setFill()
                    let rectangle = NSRect(x: 2 + CGFloat(index) * 5, y: 3,
                                           width: 3.5, height: 5 + CGFloat(index) * 3)
                    NSBezierPath(roundedRect: rectangle, xRadius: 1.3, yRadius: 1.3).fill()
                }
                return true
            }
            image.isTemplate = true
            return (pressure, image)
        })
    }()
}

enum AgentUsageStatusLabel {
    static func apply(to button: NSStatusBarButton, selection: AgentUsageSelection) {
        let title: String
        let image: NSImage?
        let label: String
        switch selection {
        case .replyAPI(let today):
            title = AgentUsageSelection.apiLabel(today)
            image = nil
            label = "Notch Harbor 快捷回复 API 今日用量"
        case .provider(let provider) where provider.showsQuotaRings:
            title = ""
            image = AgentQuotaRings.image(for: provider)
            label = "\(provider.name) 额度，外圈 5 小时，内圈每周"
        case .provider(let provider):
            title = AgentUsageSelection.compactBilling(provider) ?? "—"
            image = nil
            label = "\(provider.name) 用量"
        case .unavailable:
            title = ""
            image = NSImage(named: "NotchHarborMenu")
            label = "Notch Harbor"
        }
        if button.image !== image { button.image = image }
        if button.title != title { button.title = title }
        if button.accessibilityLabel() != label { button.setAccessibilityLabel(label) }
        button.toolTip = label
    }
}

struct AgentUsagePopover: View {
    @ObservedObject private var hub = UnifiedActivities.shared
    @ObservedObject private var apiUsage = AgentAPIUsageLedger.shared
    @AppStorage(AgentUsageSelection.key) private var preferred = ""
    @AppStorage(AgentQuickReplySource.preferenceKey) private var quickReplySource = AgentQuickReplySource.current
    private var apiEnabled: Bool { quickReplySource == .api }
    @State private var page: Page = .overview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var measured = false
    @State private var sample: MenuPowerSample?

    private enum Page: String, CaseIterable {
        case overview, quota, power

        var title: LocalizedStringKey {
            switch self {
            case .overview: "概览"
            case .quota: "额度"
            case .power: "功率"
            }
        }

        var icon: String {
            switch self {
            case .overview: "square.grid.2x2"
            case .quota: "gauge.with.dots.needle.50percent"
            case .power: "bolt"
            }
        }
    }

    var readMemoryApps: () async -> Data = { Data() }
    let openSettings: () -> Void

    private var selection: AgentUsageSelection {
        AgentUsageSelection.resolve(hub.agentUsage, preferred: preferred, active: hub.runningAgent?.source,
                                    apiEnabled: apiEnabled, today: apiUsage.today)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    ForEach(Page.allCases, id: \.self) { destination in
                        Button { page = destination } label: {
                            Label(destination.title, systemImage: destination.icon)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(.primary.opacity(page == destination ? 0.10 : 0),
                                            in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(page == destination ? .isSelected : [])
                        .accessibilityIdentifier("menu-harbor-tab-\(destination.rawValue)")
                    }
                }
                .padding(2)
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))

                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 25, height: 27)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("设置")
                .accessibilityLabel("设置")
                .accessibilityIdentifier("menu-harbor-settings")
                .keyboardShortcut(",", modifiers: .command)
            }

            switch page {
            case .overview:
                VStack(alignment: .leading, spacing: 7) {
                    Text(sourceName).font(.system(size: 12, weight: .semibold))
                    quotaSummary
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                MenuPowerSection(sample: sample, measured: measured)
                    .padding(7)
                    .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
            case .quota:
                sourceTabs
                quotaDetail
            case .power:
                MenuPowerFlowDetail(sample: sample, measured: measured, animates: !reduceMotion)
                MenuMemoryTrend(readApps: readMemoryApps)
            }
        }
        .padding(10)
        .frame(width: 276)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("agent-usage-details")
        .task {
            let telemetry = MenuPowerTelemetry.shared
            while !Task.isCancelled {
                let reading = await telemetry.read()
                guard !Task.isCancelled else { return }
                if sample != reading { sample = reading }
                if !measured { measured = true }
                do { try await Task.sleep(for: .seconds(1)) }
                catch { break }
            }
        }
    }

    @ViewBuilder
    private var sourceTabs: some View {
        if !hub.agentUsage.isEmpty || apiEnabled || apiUsage.today != nil {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    sourceTab("自动", id: "")
                    ForEach(hub.agentUsage) { usage in
                        sourceTab(usage.name, id: usage.id)
                    }
                    if !hub.agentUsage.contains(where: { $0.id == "gemini" }) {
                        sourceTab("Gemini", id: "gemini")
                    }
                    if !hub.agentUsage.contains(where: { $0.id == "doubao" }) {
                        sourceTab("豆包", id: "doubao")
                    }
                    if apiEnabled || apiUsage.today != nil {
                        sourceTab(AgentUsageSelection.replyAPIName, id: AgentUsageSelection.replyAPIID)
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(height: 25)
        }
        Text(sourceName)
            .font(.system(size: 12, weight: .semibold))
    }

    private func sourceTab(_ title: String, id: String) -> some View {
        Button { preferred = id } label: {
            Text(title)
                .font(.system(size: 11, weight: preferred == id ? .semibold : .medium))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(.primary.opacity(preferred == id ? 0.11 : 0.045), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(preferred == id ? .isSelected : [])
    }

    @ViewBuilder
    private var quotaSummary: some View {
        if unavailableQuotaProvider != nil {
            Text("暂无用量").font(.caption).foregroundStyle(.secondary)
        } else {
            availableQuotaSummary
        }
    }

    @ViewBuilder
    private var availableQuotaSummary: some View {
        switch selection {
        case .provider(let provider):
            let windows = sortedWindows(provider)
            if windows.isEmpty {
                Label(AgentUsageSelection.compactBilling(provider) ?? "—", systemImage: "chart.bar")
                    .font(.callout.monospacedDigit())
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(windows.prefix(2).enumerated()), id: \.offset) { _, window in
                        let current = provider.isCurrent(window, at: Date().timeIntervalSince1970)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 4) {
                                Image(systemName: cycleIcon(window)).foregroundStyle(.secondary)
                                Text(window.cycle).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(current ? "\(Int(window.remaining))%" : "—").fontWeight(.semibold)
                            }
                            quotaTrack(remaining: current ? window.remaining : 0, height: 3)
                        }
                        .font(.caption.monospacedDigit())
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .replyAPI(let today):
            Label(AgentUsageSelection.apiLabel(today), systemImage: "chart.bar")
                .font(.callout.monospacedDigit())
        case .unavailable:
            Text("暂无用量").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var unavailableQuotaProvider: String? {
        guard ["gemini", "doubao"].contains(preferred), !hub.agentUsage.contains(where: { $0.id == preferred }) else { return nil }
        return preferred
    }

    private var quotaDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let provider = unavailableQuotaProvider {
                Label(provider == "gemini" ? "暂无 Gemini 余量" : "暂无豆包余量",
                      systemImage: "gauge.with.dots.needle.0percent")
                    .font(.system(size: 12, weight: .semibold))
                if provider == "gemini",
                   let url = URL(string: "https://gemini.google.com/usage") {
                    Link("打开 Gemini 用量页", destination: url)
                        .font(.caption)
                } else {
                    Button {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.bot.pc.doubao") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("打开豆包查看额度", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }
            } else {
                switch selection {
                case .provider(let provider):
                    providerContent(provider, now: Date().timeIntervalSince1970)
                case .replyAPI(let today):
                    apiContent(today)
                case .unavailable:
                    Text("暂无用量").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityIdentifier("menu-quota-detail")
    }

    private func cycleIcon(_ window: AgentUsageWindow) -> String {
        (window.windowMinutes ?? 0) >= 1440 ? "calendar" : "clock"
    }

    private var sourceName: String {
        switch unavailableQuotaProvider {
        case "gemini": return "Gemini"
        case "doubao": return "豆包"
        default: break
        }
        return switch selection {
        case .provider(let provider): provider.name
        case .replyAPI: AgentUsageSelection.replyAPIName
        case .unavailable: "Agent 用量"
        }
    }

    private func shortTime(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if Calendar.current.isDateInTomorrow(date) {
            return "明天 " + date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
    }

    private func sortedWindows(_ provider: AgentProviderUsage) -> [AgentUsageWindow] {
        let periods = [AgentQuotaRings.outerMinutes, AgentQuotaRings.innerMinutes]
        return provider.windows.sorted {
            (periods.firstIndex(of: $0.windowMinutes ?? 0) ?? periods.count)
                < (periods.firstIndex(of: $1.windowMinutes ?? 0) ?? periods.count)
        }
    }

    private func providerContent(_ provider: AgentProviderUsage, now: Double) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(sortedWindows(provider).enumerated()), id: \.offset) { index, window in
                if index > 0 { Divider() }
                quotaRow(window, provider: provider, now: now)
            }
            if let bill = provider.billing {
                if let used = bill.used { row("计费用量", AgentUsageSelection.amount(used, bill.currencyCode)) }
                if let limit = bill.limit, limit > 0 { row("预算", AgentUsageSelection.amount(limit, bill.currencyCode)) }
                if let balance = bill.balance { row("余额", AgentUsageSelection.amount(balance, bill.currencyCode)) }
            }
            if let tokens = provider.localTokens30Days {
                row("本机近 30 天", "\(tokens.formatted()) Tokens")
            }
        }
        .help("用量更新 · " + Date(timeIntervalSince1970: provider.updatedAt).formatted(date: .abbreviated, time: .shortened))
    }

    private func quotaRow(_ window: AgentUsageWindow, provider: AgentProviderUsage, now: Double) -> some View {
        let current = provider.isCurrent(window, at: now)
        let reset = window.resetsAt.map { Date(timeIntervalSince1970: $0) }
        let recovery = reset.map { date in
            if date.timeIntervalSince1970 <= now { return "等待新额度" }
            return shortTime(date)
        } ?? "未知"
        let forecast: String = switch provider.exhaustion(for: window, at: now) {
        case .depleted: "已用完"
        case .beforeReset(let date): shortTime(date)
        case .lastsUntilReset: "可用至恢复"
        case .unavailable: "—"
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(window.cycle, systemImage: cycleIcon(window)).font(.callout.weight(.medium))
                Spacer(minLength: 6)
                if current {
                    Text("\(Int(window.remaining))%").font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .accessibilityLabel("剩余 \(Int(window.remaining))%")
                } else {
                    Text("等待更新").font(.caption).foregroundStyle(.secondary)
                }
            }
            quotaTrack(remaining: current ? window.remaining : 0, height: 4)
            HStack(spacing: 8) {
                Label(recovery, systemImage: "arrow.clockwise")
                    .help("额度恢复时间")
                    .accessibilityLabel("恢复时间 " + recovery)
                Spacer(minLength: 0)
                Label(forecast, systemImage: "hourglass")
                    .help("预计用完时间")
                    .accessibilityLabel("预计用完 " + forecast)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
    }

    private func quotaTrack(remaining: Double, height: CGFloat) -> some View {
        GeometryReader { geometry in
            Capsule().fill(.primary.opacity(0.10))
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.accentColor)
                        .frame(width: geometry.size.width * min(1, max(0, remaining / 100)))
                }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func apiContent(_ today: AgentAPIUsageLedger.DailyUsage?) -> some View {
        if let today {
            row("今日成功请求", "\(today.requests) 次")
            if today.requestsWithTokens > 0 {
                row("已报告的 Token", today.tokens.formatted())
            }
            row("返回 Token 数的请求", "\(today.requestsWithTokens) 次")
        } else {
            Text("暂无请求记录").foregroundStyle(.secondary)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

private struct MenuPowerSection: View {
    let sample: MenuPowerSample?
    let measured: Bool

    var body: some View {
        if sample == nil && measured {
            Label("暂无功率", systemImage: "bolt.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 0) {
                metric(icon: "MenuPowerInput", title: "输入", detail: "充电器输入", watts: sample?.adapter)
                Divider().frame(height: 23)
                metric(icon: "MenuPowerBattery", title: batteryTitle, detail: batteryTitle, watts: sample?.battery.map(abs))
                Divider().frame(height: 23)
                metric(icon: "MenuPowerLoad", title: "本机", detail: "本机耗电", watts: sample?.system)
            }
        }
    }

    private var batteryTitle: LocalizedStringKey {
        guard let watts = sample?.battery else { return "电池" }
        if abs(watts) < 0.05 { return "待机" }
        return watts > 0 ? "充电" : "供电"
    }

    private func metric(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey, watts: Double?) -> some View {
        VStack(spacing: 3) {
            Image(icon).resizable().frame(width: 19, height: 19)
                .foregroundStyle(.primary).accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(watts?.formatted(.number.precision(.fractionLength(1))) ?? "—")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if watts != nil {
                    Text("W").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .help(Text(detail) + (sample?.isLive == false ? Text(" · 系统采样") : Text("")))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(detail))
        .accessibilityValue(watts.map { $0.formatted(.number.precision(.fractionLength(1))) + " W" } ?? "—")
    }
}

@MainActor
final class MenuMemoryMonitor: ObservableObject {
    static let shared = MenuMemoryMonitor()
    static let history: TimeInterval = 60

    @Published private(set) var points: [MenuMemorySnapshot] = []
    private var sampler: Task<Void, Never>?

    private init() {
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                let sample = await MenuMemoryTelemetry.shared.read()
                guard !Task.isCancelled, let self else { return }
                let now = Date()
                var history = self.points.filter { now.timeIntervalSince($0.date) <= Self.history }
                if let sample { history.append(sample) }
                self.points = history
                do { try await Task.sleep(for: .seconds(1)) }
                catch { break }
            }
        }
    }

    deinit { sampler?.cancel() }
}

private struct MenuMemoryTrend: View {
    private struct AppUsage: Decodable, Identifiable, Equatable {
        var id: String { path }
        let path: String
        let bytes: UInt64
    }

    let readApps: () async -> Data
    @ObservedObject private var monitor = MenuMemoryMonitor.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var apps: [AppUsage] = []
    @State private var measuredApps = false
    private var points: [MenuMemorySnapshot] { monitor.points }
    private var motion: Animation? { reduceMotion ? nil : .smooth(duration: 0.26) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("内存", systemImage: "memorychip").font(.callout.weight(.semibold))
                Spacer()
                if let current = points.last {
                    HStack(spacing: 5) {
                        Circle().fill(current.pressure.color).frame(width: 5, height: 5)
                        Text(current.pressure.label).font(.caption2.weight(.medium))
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(current.pressure.color.opacity(0.12), in: Capsule())
                }
            }
            if let current = points.last {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(format(current.used)) GB")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(motion, value: current.used)
                    Text("/ \(format(current.total)) GB").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("近 60 秒").font(.caption2).foregroundStyle(.secondary)
                }
                chart(current)
                    .frame(height: 39)
                    .accessibilityLabel("最近 60 秒内存趋势")
            } else {
                Text("暂无内存读数").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text("内存占用最多的应用").font(.caption.weight(.semibold))
                Spacer()
                Text("物理内存").font(.caption2).foregroundStyle(.secondary)
            }
            if apps.isEmpty {
                Text(measuredApps ? "暂无应用读数" : "正在读取…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(apps) { app in
                appRow(app)
            }
            .animation(motion, value: apps)
        }
        .padding(9)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("menu-memory-trend")
        .task {
            while !Task.isCancelled {
                let data = await readApps()
                guard !Task.isCancelled else { return }
                if let rows = try? JSONDecoder().decode([AppUsage].self, from: data), rows != apps {
                    apps = rows
                }
                measuredApps = true
                do { try await Task.sleep(for: .seconds(2)) }
                catch { break }
            }
        }
    }

    private func appRow(_ app: AppUsage) -> some View {
        let bundle = Bundle(path: app.path)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent
        let capacity = max(1, apps.first?.bytes ?? 1)
        let ratio = min(1, Double(app.bytes) / Double(capacity))
        return HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable().frame(width: 16, height: 16).accessibilityHidden(true)
            Text(verbatim: name).font(.system(size: 11, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
            Capsule().fill(.primary.opacity(0.08))
                .overlay(alignment: .leading) {
                    Capsule().fill(.blue.opacity(0.65)).frame(width: 38 * ratio)
                }
                .frame(width: 38, height: 3)
                .accessibilityHidden(true)
            Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: app.bytes), countStyle: .memory))
                .font(.caption2.weight(.semibold)).monospacedDigit()
                .contentTransition(.numericText())
                .frame(minWidth: 43, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func chart(_ current: MenuMemorySnapshot) -> some View {
        let tint = Color.blue
        return Chart {
            ForEach(points) { point in
                AreaMark(x: .value("时间", point.date), y: .value("已用", point.used))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.linearGradient(colors: [tint.opacity(0.32), tint.opacity(0.02)],
                                                     startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("时间", point.date), y: .value("已用", point.used))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
            PointMark(x: .value("时间", current.date), y: .value("已用", current.used))
                .foregroundStyle(tint)
                .symbolSize(21)
        }
        .chartXScale(domain: current.date.addingTimeInterval(-MenuMemoryMonitor.history)...current.date.addingTimeInterval(1))
        .chartYScale(domain: 0...current.total)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }

    private func format(_ bytes: Double) -> String {
        (bytes / 1_073_741_824).formatted(.number.precision(.fractionLength(0...1)))
    }
}

private extension MenuMemorySnapshot.Pressure {
    var color: Color {
        switch self {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        case .unknown: .secondary
        }
    }
}
