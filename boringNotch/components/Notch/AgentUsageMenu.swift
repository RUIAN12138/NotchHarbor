import AppKit
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

struct AgentUsageStatusLabel: View {
    @ObservedObject private var hub = UnifiedActivities.shared
    @ObservedObject private var apiUsage = AgentAPIUsageLedger.shared
    @AppStorage(AgentUsageSelection.key) private var preferred = ""
    @AppStorage(AgentSuggestionAPI.enabledKey) private var apiEnabled = false

    var body: some View {
        switch AgentUsageSelection.resolve(hub.agentUsage, preferred: preferred, active: hub.runningAgent?.source,
                                           apiEnabled: apiEnabled, today: apiUsage.today) {
        case .replyAPI(let today):
            Text(AgentUsageSelection.apiLabel(today)).accessibilityLabel("Notch Harbor 快捷回复 API 今日用量")
        case .provider(let provider) where provider.showsQuotaRings:
            Image(nsImage: AgentQuotaRings.image(for: provider))
                .accessibilityLabel("\(provider.name) 额度，外圈 5 小时，内圈每周")
        case .provider(let provider):
            Text(AgentUsageSelection.compactBilling(provider) ?? "—")
                .accessibilityLabel("\(provider.name) 用量")
        case .unavailable:
            Image("NotchHarborMenu").accessibilityLabel("Notch Harbor")
        }
    }
}

struct AgentUsagePopover<Actions: View>: View {
    @ObservedObject private var hub = UnifiedActivities.shared
    @ObservedObject private var apiUsage = AgentAPIUsageLedger.shared
    @AppStorage(AgentUsageSelection.key) private var preferred = ""
    @AppStorage(AgentSuggestionAPI.enabledKey) private var apiEnabled = false
    let actions: Actions

    init(@ViewBuilder actions: () -> Actions) { self.actions = actions() }

    private var selection: AgentUsageSelection {
        AgentUsageSelection.resolve(hub.agentUsage, preferred: preferred, active: hub.runningAgent?.source,
                                    apiEnabled: apiEnabled, today: apiUsage.today)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if !hub.agentUsage.isEmpty || apiEnabled || apiUsage.today != nil {
                    Menu {
                        Picker("显示来源", selection: $preferred) {
                            Text("自动跟随 Agent").tag("")
                            ForEach(hub.agentUsage) { usage in Text(usage.name).tag(usage.id) }
                            if apiEnabled || apiUsage.today != nil {
                                Text(AgentUsageSelection.replyAPIName).tag(AgentUsageSelection.replyAPIID)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(sourceName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .help("切换额度来源")
                } else {
                    Text(sourceName).font(.system(size: 13, weight: .semibold))
                }
                Spacer(minLength: 8)
                actions
            }
            .controlSize(.small)

            switch selection {
            case .provider(let provider):
                providerContent(provider, now: Date().timeIntervalSince1970)
            case .replyAPI(let today):
                apiContent(today)
            case .unavailable:
                Text("暂无 Agent 用量记录").foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 286)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("agent-usage-details")
    }

    private var sourceName: String {
        switch selection {
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

    private func providerContent(_ provider: AgentProviderUsage, now: Double) -> some View {
        let periods = [AgentQuotaRings.outerMinutes, AgentQuotaRings.innerMinutes]
        let windows = provider.windows.sorted {
            (periods.firstIndex(of: $0.windowMinutes ?? 0) ?? periods.count)
                < (periods.firstIndex(of: $1.windowMinutes ?? 0) ?? periods.count)
        }
        return VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
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
            Divider()
            row("用量更新", Date(timeIntervalSince1970: provider.updatedAt).formatted(date: .abbreviated, time: .shortened))
                .foregroundStyle(.secondary)
        }
    }

    private func quotaRow(_ window: AgentUsageWindow, provider: AgentProviderUsage, now: Double) -> some View {
        let current = provider.isCurrent(window, at: now)
        let reset = window.resetsAt.map { Date(timeIntervalSince1970: $0) }
        let recovery = reset.map { date in
            if date.timeIntervalSince1970 <= now { return "等待新额度" }
            return "恢复 " + shortTime(date)
        } ?? "恢复时间未知"
        let forecast: String = switch provider.exhaustion(for: window, at: now) {
        case .depleted: "已用完"
        case .beforeReset(let date): "预计 " + shortTime(date) + " 用完"
        case .lastsUntilReset: "预计可用到恢复"
        case .unavailable: "暂无用完预测"
        }
        return VStack(alignment: .leading, spacing: 4) {
            row(window.cycle, current ? "剩余 \(Int(window.remaining))%" : "等待更新")
            ProgressView(value: current ? window.remaining : 0, total: 100)
                .controlSize(.small)
                .tint(.accentColor)
                .accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Text(recovery)
                    Spacer(minLength: 4)
                    Text(forecast)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(recovery)
                    Text(forecast)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
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
