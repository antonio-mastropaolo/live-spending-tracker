import AppKit
import SwiftUI

// MARK: - Reusable modifiers (file-level)

private struct FadeInOnAppear: ViewModifier {
    @State private var visible = false
    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeIn(duration: 0.18)) { visible = true }
            }
    }
}

private struct PulsingHalo: ViewModifier {
    let color: Color
    @State private var animating = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(animating ? 2.2 : 1.0)
            .opacity(animating ? 0.0 : 0.5)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false), value: animating)
            .onAppear { animating = true }
    }
}

// MARK: - Color palette

private enum Palette {
    static let neon       = Color(red: 0.22, green: 1.0, blue: 0.08)
    static let amber      = Color(red: 1.0,  green: 0.62, blue: 0.0)
    static let danger     = Color(red: 1.0,  green: 0.27, blue: 0.23)
    static let cyan       = Color(red: 0.0,  green: 0.87, blue: 1.0)
    static let cardFill   = Color(white: 0.12)
    static let rowFill    = Color(white: 0.10)
    static let stroke     = Color.white.opacity(0.07)
    static let panelBG    = Color(white: 0.06)
}

// MARK: - Provider colors

// Module-internal (no `private`) so Toasts.swift can use the same color +
// monogram chip the popover rows render.
func providerColor(_ name: String) -> Color {
    switch name.lowercased() {
    case "anthropic": return Color(red: 1.0,  green: 0.45, blue: 0.2)
    case "openai":    return Color(red: 0.45, green: 0.85, blue: 0.75)
    case "gemini":    return Color(red: 0.35, green: 0.55, blue: 1.0)
    case "mistral":   return Color(red: 1.0,  green: 0.62, blue: 0.0)
    case "cohere":    return Color(red: 0.6,  green: 0.35, blue: 1.0)
    default:          return Color(white: 0.55)
    }
}

/// Single uppercase letter we use as the provider's monogram. Drawn
/// programmatically inside a rounded chip — no asset catalog, no
/// trademarked artwork, scales crisp at any size.
private func providerMonogram(_ name: String) -> String {
    switch name.lowercased() {
    case "anthropic":   return "A"
    case "openai":      return "O"
    case "gemini":      return "G"
    case "mistral":     return "M"
    case "cohere":      return "C"
    case "huggingface": return "H"
    default:            return name.first.map { String($0).uppercased() } ?? "?"
    }
}

/// A small provider mark — rounded-square chip with an accent stroke and
/// the provider's bold monogram. Sized for 16–22pt rendering: legible
/// inside row layouts, distinct color per provider via ``providerColor``.
struct ProviderMark: View {
    let provider: String
    var size: CGFloat = 18

    var body: some View {
        let accent = providerColor(provider)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Color(white: 0.10))
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(accent.opacity(0.15))
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(accent.opacity(0.55), lineWidth: max(0.6, size * 0.06))
            Text(providerMonogram(provider))
                .font(.system(size: size * 0.62, weight: .black, design: .rounded))
                .foregroundStyle(accent)
                .shadow(color: accent.opacity(0.55), radius: max(1, size * 0.10))
                // Optical centering nudge — the rounded font sits a hair
                // high otherwise, especially for "A".
                .offset(y: -size * 0.02)
        }
        .frame(width: size, height: size)
        .help(provider.capitalized)
    }
}

// MARK: - Footer buttons

private struct ResetButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.amber)
                Text("RESET")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hovered ? Color(white: 0.20) : Color(white: 0.15))
                    .animation(.easeInOut(duration: 0.15), value: hovered)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        hovered ? Palette.amber.opacity(0.35) : Palette.stroke,
                        lineWidth: 0.5
                    )
                    .animation(.easeInOut(duration: 0.15), value: hovered)
            )
        }
        .buttonStyle(.plain)
        .help("Zero out the proxy's today counters. v2 vendor data is preserved.")
        .onHover { hovered = $0 }
    }
}

private struct QuitButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.danger)
                Text("QUIT")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.primary)
            }
            .frame(minWidth: 80)
            .frame(height: 36)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hovered ? Color(white: 0.20) : Color(white: 0.15))
                    .animation(.easeInOut(duration: 0.15), value: hovered)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        hovered ? Palette.danger.opacity(0.35) : Palette.stroke,
                        lineWidth: 0.5
                    )
                    .animation(.easeInOut(duration: 0.15), value: hovered)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - MenuBarView root

struct MenuBarView: View {
    @EnvironmentObject private var store: SpendingStore

    var body: some View {
        ZStack {
            switch store.nav {
            case .overview:
                OverviewView()
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)))
            case .account(let id):
                AccountDetailView(accountID: id)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)))
            case .key(let aid, let kid):
                KeyDetailView(accountID: aid, keyID: kid)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)))
            case .history:
                HistoryView()
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)))
            }
        }
        .frame(width: 380)
        .background(Palette.panelBG)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.22), value: store.nav)
    }
}

// MARK: - Header (shared across tiers)

private struct HeaderView: View {
    let trailing: AnyView?
    @State private var appeared = false

    init(trailing: AnyView? = nil) {
        self.trailing = trailing
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Image("AppMark")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44)
                    .shadow(color: Palette.neon.opacity(0.35), radius: 6)

                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("Spend")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Tracker")
                        .font(.system(size: 16, weight: .light, design: .rounded))
                        .foregroundStyle(Palette.neon)
                }

                Spacer()
                trailing
            }
            .padding(.bottom, 14)

            Rectangle()
                .fill(Palette.stroke)
                .frame(height: 0.5)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : -6)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25)) { appeared = true }
        }
    }
}

// MARK: - OverviewView

private struct OverviewView: View {
    @EnvironmentObject private var store: SpendingStore
    @State private var heroExpanded: Bool = false

    /// v2 layout is the default whenever a registry is installed — even
    /// before the first successful poll. The user explicitly wants the
    /// "overall across all accounts" to be the landing view, with
    /// per-account drill-down on demand.
    private var inV2Mode: Bool {
        store.state.hasV2Accounts || store.registryInstalled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderView(
                trailing: AnyView(ReconcileFreshness(date: store.state.lastReconciled))
            )

            if inV2Mode {
                v2Body
            } else {
                v1Body
            }

            statusFooter
            footerButtons
        }
        .padding(16)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: heroExpanded)
    }

    private func toggleHero() { heroExpanded.toggle() }

    // ---- v2 (multi-account) ----

    @ViewBuilder
    private var v2Body: some View {
        Button(action: toggleHero) {
            TotalCard(
                usd: store.displayedTotalsYesterdayUSD,
                headline: "YESTERDAY · ALL ACCOUNTS",
                forecast: store.forecastTotalEndOfMonth,
                expanded: heroExpanded
            )
        }
        .buttonStyle(.plain)

        if heroExpanded {
            HeroDetailV2(usd: store.displayedTotalsYesterdayUSD)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.92, anchor: .top)
                        .combined(with: .opacity)
                        .combined(with: .move(edge: .top)),
                    removal: .opacity.combined(with: .move(edge: .top))))
        }

        if let est = store.state.todayEstimate, est.burnRateCentsPerMin > 0.5 {
            BurnRateCard(centsPerMin: est.burnRateCentsPerMin)
        }

        BreakdownHeader(text: "BY ACCOUNT")
        if !store.state.accounts.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(store.state.accounts) { acct in
                    AccountRow(account: acct, total: store.displayedTotalsYesterdayUSD)
                }
            }
        } else {
            NoAccountsYetCard()
        }

        HistoryLinkButton()

        if let est = store.state.todayEstimate {
            TodayEstimateGhost(estimate: est)
        }
    }

    // ---- v1 fallback (registry not installed) ----

    @ViewBuilder
    private var v1Body: some View {
        Button(action: toggleHero) {
            TotalCard(usd: store.state.totalUSD, headline: "TODAY'S SPEND", expanded: heroExpanded)
        }
        .buttonStyle(.plain)

        if heroExpanded {
            HeroDetailV1()
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.92, anchor: .top)
                        .combined(with: .opacity)
                        .combined(with: .move(edge: .top)),
                    removal: .opacity.combined(with: .move(edge: .top))))
        }

        if store.state.byProvider.contains(where: { $0.usd > 0.0001 }) {
            BreakdownHeader(text: "BY PROVIDER")
            VStack(alignment: .leading, spacing: 1) {
                ForEach(
                    store.state.byProvider.filter { $0.usd > 0.0001 },
                    id: \.provider
                ) { row in
                    LegacyProviderRow(name: row.provider, usd: row.usd, total: store.state.totalUSD)
                }
            }
        }

        if store.state.byKey.contains(where: { $0.usd > 0.0001 }) {
            BreakdownHeader(text: "BY KEY")
            VStack(alignment: .leading, spacing: 1) {
                ForEach(store.state.byKey.filter { $0.usd > 0.0001 }) { entry in
                    LegacyKeyRow(entry: entry, total: store.state.totalUSD)
                }
            }
        }
    }

    private var statusFooter: some View { StatusBadgeRow() }
    private var footerButtons: some View { FooterButtons() }
}

// MARK: - AccountDetailView

private struct AccountDetailView: View {
    let accountID: String
    @EnvironmentObject private var store: SpendingStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            backHeader

            if let acct = store.account(id: accountID) {
                AccountTotalCard(account: acct)
                if acct.budgets.isSet {
                    BudgetProgressView(account: acct)
                }
                AnalyticsRow(account: acct)
                DisableAccountButton(accountID: acct.id, label: acct.label)
                if let err = acct.error {
                    ErrorCard(error: err)
                }
                if !acct.yesterday.workspaces.isEmpty {
                    BreakdownHeader(text: workspacesHeader(provider: acct.provider))
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(acct.yesterday.workspaces) { ws in
                            WorkspaceRow(entry: ws, total: acct.displayedYesterdayUSD, color: providerColor(acct.provider))
                        }
                    }
                }
                let visibleKeys = acct.visibleKeys
                if !visibleKeys.isEmpty {
                    BreakdownHeader(text: "BY KEY")
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(visibleKeys) { k in
                            AccountKeyRow(account: acct, key: k, color: providerColor(acct.provider))
                        }
                    }
                }
                if !acct.mutedKeyIDs.isEmpty {
                    MutedKeysSection(account: acct)
                }
            } else {
                Text("Account not found.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            FooterButtons()
        }
        .padding(16)
    }

    private var backHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            BackChip(label: "OVERVIEW") { store.popToOverview() }
            Spacer()
            if let acct = store.account(id: accountID) {
                HStack(spacing: 6) {
                    ProviderMark(provider: acct.provider, size: 18)
                    Text(acct.label)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.stroke).frame(height: 0.5)
        }
    }

    private func workspacesHeader(provider: String) -> String {
        switch provider.lowercased() {
        case "anthropic": return "BY WORKSPACE"
        case "openai":    return "BY PROJECT"
        default:          return "BY GROUP"
        }
    }
}

// MARK: - KeyDetailView

private struct KeyDetailView: View {
    let accountID: String
    let keyID: String
    @EnvironmentObject private var store: SpendingStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            backHeader

            if let acct = store.account(id: accountID),
               let key = acct.yesterday.keys.first(where: { $0.id == keyID })
            {
                KeyTotalCard(key: key, color: providerColor(acct.provider))

                BreakdownHeader(text: "7-DAY TREND")
                Sparkline(values: acct.trend7d, color: providerColor(acct.provider))
                    .frame(height: 56)
                    .padding(.horizontal, 4)

                BreakdownHeader(text: "DETAILS")
                VStack(alignment: .leading, spacing: 6) {
                    DetailRow(label: "Account", value: acct.label)
                    DetailRow(label: "Provider", value: acct.provider.capitalized)
                    DetailRow(label: "Key ID", value: key.id, monospaced: true)
                    if !key.label.isEmpty {
                        DetailRow(label: "Label", value: key.label)
                    }
                    if !key.tail.isEmpty {
                        DetailRow(label: "Tail", value: "…\(key.tail)", monospaced: true)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Palette.rowFill)
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Palette.stroke, lineWidth: 0.5))
                )
            } else {
                Text("Key not found.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            FooterButtons()
        }
        .padding(16)
    }

    private var backHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            BackChip(label: "ACCOUNT") { store.popToAccount() }
            Spacer()
            if let acct = store.account(id: accountID),
               let key = acct.yesterday.keys.first(where: { $0.id == keyID }) {
                let display = key.tail.isEmpty ? "…\(key.id.suffix(6))" : "…\(key.tail)"
                HStack(spacing: 6) {
                    Circle().fill(providerColor(acct.provider)).frame(width: 6, height: 6)
                    Text(display)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.stroke).frame(height: 0.5)
        }
    }
}

// MARK: - Cards & rows

private struct TotalCard: View {
    let usd: Double
    let headline: String
    var forecast: Double? = nil
    var expanded: Bool = false

    var heroColor: Color {
        // Amber by default — the warm "money on the move" tone. Escalates
        // only at clearly worrying levels so the visual stays grounded
        // for normal-day spend.
        if usd > 50 { return Palette.danger }
        return Palette.amber
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Palette.cardFill)
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        expanded ? heroColor.opacity(0.45) : Palette.stroke,
                        lineWidth: expanded ? 1.0 : 0.5))

            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Palette.neon.opacity(0.75))
                    .frame(width: 2, height: geo.size.height * 0.56)
                    .frame(maxHeight: .infinity, alignment: .center)
            }

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(headline)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .tracking(1.4)
                            .foregroundStyle(.tertiary)
                        Image(systemName: expanded ? "chevron.up.circle.fill" : "chevron.down.circle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(expanded ? 0.75 : 0.35))
                    }
                    Text(usd, format: .currency(code: "USD"))
                        .font(.system(size: 42, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(
                            LinearGradient(
                                colors: [heroColor, heroColor.opacity(0.72)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: heroColor.opacity(0.45), radius: 8, x: 0, y: 2)
                }
                Spacer(minLength: 0)
                if let f = forecast, f > 0 {
                    ForecastChip(amount: f)
                        .padding(.top, 2)
                }
            }
            .padding(.vertical, 14)
            .padding(.leading, 18)
            .padding(.trailing, 14)
        }
        .fixedSize(horizontal: false, vertical: true)
        .modifier(FadeInOnAppear())
        .help(expanded ? "Collapse" : "Click to expand the day")
    }
}

private struct ForecastChip: View {
    let amount: Double

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("EOM FORECAST")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(Palette.cyan.opacity(0.85))
            Text("~\(Self.compact(amount))")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.cyan)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Palette.cyan.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Palette.cyan.opacity(0.30), lineWidth: 0.5))
        )
    }

    static func compact(_ v: Double) -> String {
        if v >= 1000 { return String(format: "$%.1fK", v / 1000) }
        return String(format: "$%.2f", v)
    }
}

private struct AccountTotalCard: View {
    let account: AccountState

    var body: some View {
        let tone = providerColor(account.provider)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Palette.cardFill)
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Palette.stroke, lineWidth: 0.5))
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 1)
                    .fill(tone.opacity(0.85))
                    .frame(width: 2, height: geo.size.height * 0.56)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("YESTERDAY · \(account.provider.uppercased())")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(.tertiary)
                Text(account.displayedYesterdayUSD, format: .currency(code: "USD"))
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(tone)
                    .shadow(color: tone.opacity(0.4), radius: 6, x: 0, y: 2)
                if !account.yesterday.date.isEmpty {
                    Text("date: \(account.yesterday.date)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(.vertical, 12)
            .padding(.leading, 18)
            .padding(.trailing, 14)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct KeyTotalCard: View {
    let key: AccountKeyEntry
    let color: Color

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Palette.cardFill)
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Palette.stroke, lineWidth: 0.5))
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color.opacity(0.85))
                    .frame(width: 2, height: geo.size.height * 0.56)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("YESTERDAY · KEY")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(.tertiary)
                Text(key.usd, format: .currency(code: "USD"))
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .shadow(color: color.opacity(0.4), radius: 6, x: 0, y: 2)
            }
            .padding(.vertical, 12)
            .padding(.leading, 18)
            .padding(.trailing, 14)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AccountRow: View {
    let account: AccountState
    let total: Double
    @EnvironmentObject private var store: SpendingStore

    private var isOverBudget: Bool {
        let mtd = store.monthToDateSpend(for: account.id)
        let today = store.todaySpend(for: account.id)
        if let cap = account.budgets.dailyUSD, today > cap { return true }
        if let cap = account.budgets.monthlyUSD, mtd > cap { return true }
        return false
    }

    var body: some View {
        let color = providerColor(account.provider)
        let usd = account.displayedYesterdayUSD
        let fraction: Double = total > 0 ? min(usd / total, 1.0) : 0
        let pct = total > 0 ? Int((usd / total * 100).rounded()) : 0
        let wow = store.weekOverWeek(for: account.id)

        return Button(action: { store.showAccount(account.id) }) {
            HStack(alignment: .center, spacing: 0) {
                color.frame(width: 2).clipShape(Rectangle())

                HStack(alignment: .center, spacing: 8) {
                    HStack(spacing: 6) {
                        ProviderMark(provider: account.provider, size: 18)
                        Text(account.label)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if isOverBudget {
                            BudgetOverPill()
                        }
                        if account.error != nil {
                            ErrorPill(kind: account.error!.kind)
                        }
                    }
                    .frame(width: 150, alignment: .leading)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 4)
                            Rectangle().fill(color.opacity(0.85))
                                .frame(width: geo.size.width * fraction, height: 4)
                        }
                        .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 4)

                    Text(usd, format: .currency(code: "USD"))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.78))
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)

                    WoWArrow(deltaFraction: wow)
                        .frame(width: 38, alignment: .trailing)

                    Text("\(pct)%")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.28))
                        .frame(width: 22, alignment: .trailing)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Palette.rowFill)
                .overlay(Rectangle().strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
            }
        }
        .buttonStyle(.plain)
        .help("Drill into \(account.label)")
    }
}

private struct WoWArrow: View {
    let deltaFraction: Double?

    var body: some View {
        guard let d = deltaFraction else {
            return AnyView(
                Text("–")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.25))
            )
        }
        let pct = Int((abs(d) * 100).rounded())
        let isUp = d > 0
        let isFlat = pct == 0
        let symbol = isFlat ? "minus" : (isUp ? "arrow.up" : "arrow.down")
        // Up = more spend = warm; down = less = cool. Color signals direction.
        let color: Color = isFlat ? .white.opacity(0.30)
            : (isUp ? Palette.danger : Palette.neon)
        return AnyView(
            HStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .bold))
                Text("\(pct)%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
            }
            .foregroundStyle(color)
        )
    }
}

private struct BudgetOverPill: View {
    var body: some View {
        Text("OVER")
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .tracking(0.6)
            .foregroundStyle(Palette.danger)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Palette.danger.opacity(0.15)))
    }
}

private struct WorkspaceRow: View {
    let entry: WorkspaceEntry
    let total: Double
    let color: Color

    var body: some View {
        let fraction: Double = total > 0 ? min(entry.usd / total, 1.0) : 0
        return HStack(spacing: 8) {
            Text(entry.label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 4)
                    Rectangle().fill(color.opacity(0.85))
                        .frame(width: geo.size.width * fraction, height: 4)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 4)
            Text(entry.usd, format: .currency(code: "USD"))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.72))
                .monospacedDigit()
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Palette.rowFill)
        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
    }
}

private struct AccountKeyRow: View {
    let account: AccountState
    let key: AccountKeyEntry
    let color: Color
    @EnvironmentObject private var store: SpendingStore
    @State private var hovered = false

    var body: some View {
        let total = account.displayedYesterdayUSD
        let fraction: Double = total > 0 ? min(key.usd / total, 1.0) : 0
        let display: String = {
            if !key.tail.isEmpty { return "…\(key.tail)" }
            return "…\(key.id.suffix(6))"
        }()

        return ZStack {
            // Whole-row drill button.
            Button(action: { store.showKey(account.id, key.id) }) {
                HStack(spacing: 8) {
                    Text(display)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    if !key.label.isEmpty {
                        Text(key.label)
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 4)
                            Rectangle().fill(color.opacity(0.85))
                                .frame(width: geo.size.width * fraction, height: 4)
                        }
                        .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(maxWidth: 90, maxHeight: .infinity)
                    .frame(height: 4)
                    Text(key.usd, format: .currency(code: "USD"))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.72))
                        .monospacedDigit()
                        .frame(width: 62, alignment: .trailing)
                    // Reserve room for the mute button so the chevron
                    // doesn't shift on hover.
                    Color.clear.frame(width: 18, height: 1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Palette.rowFill)
                .overlay(Rectangle().strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help("Drill into key \(display)")

            // Hover-revealed mute button, sitting on top of the reserved
            // gap to the left of the chevron. ZStack layering keeps the
            // surrounding row click target intact.
            HStack {
                Spacer()
                Button(action: { store.setKeyMuted(account.id, key.id, muted: true) }) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hovered ? Palette.amber : .white.opacity(0.35))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Discard \(display) from tracking — admin key kept; reversible via CLI.")
                .padding(.trailing, 26) // reserve space for the chevron
                .opacity(hovered ? 1 : 0.55)
            }
        }
        .onHover { hovered = $0 }
    }
}

// MARK: - Legacy v1 rows (used when no v2 registry)

private struct LegacyProviderRow: View {
    let name: String
    let usd: Double
    let total: Double

    var body: some View {
        let color = providerColor(name)
        let fraction: Double = total > 0 ? min(usd / total, 1.0) : 0
        let pct = total > 0 ? Int((usd / total * 100).rounded()) : 0

        return HStack(alignment: .center, spacing: 0) {
            color.frame(width: 2).clipShape(Rectangle())
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 5, height: 5)
                    Text(name.capitalized)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                }
                .frame(width: 110, alignment: .leading)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 4)
                        Rectangle().fill(color.opacity(0.85))
                            .frame(width: geo.size.width * fraction, height: 4)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 4)

                Text(usd, format: .currency(code: "USD"))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .monospacedDigit()
                    .frame(width: 62, alignment: .trailing)

                Text("\(pct)%")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.28))
                    .frame(width: 26, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Palette.rowFill)
            .overlay(Rectangle().strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
        }
    }
}

private struct LegacyKeyRow: View {
    let entry: KeyEntry
    let total: Double

    var body: some View {
        let color = providerColor(entry.provider)
        let fraction: Double = total > 0 ? min(entry.usd / total, 1.0) : 0
        let label = entry.tail.isEmpty ? "…\(entry.id.prefix(6))" : "…\(entry.tail)"

        return HStack(alignment: .center, spacing: 0) {
            color.frame(width: 2).clipShape(Rectangle())
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 5, height: 5)
                    Text(label)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Text(entry.provider)
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                }
                .frame(width: 130, alignment: .leading)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 4)
                        Rectangle().fill(color.opacity(0.85))
                            .frame(width: geo.size.width * fraction, height: 4)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 4)

                Text(entry.usd, format: .currency(code: "USD"))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .monospacedDigit()
                    .frame(width: 62, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Palette.rowFill)
            .overlay(Rectangle().strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
        }
    }
}

// MARK: - Status / freshness / footer

private struct ReconcileFreshness: View {
    let date: Date?

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("RECONCILED")
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
                .kerning(0.8)
            if let d = date {
                Text(d, style: .relative)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.cyan)
                    .monospacedDigit()
            } else {
                Text("never")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct StatusBadgeRow: View {
    @EnvironmentObject private var store: SpendingStore

    var body: some View {
        let running = store.proxyRunning
        let stale = store.isStale
        let drift = store.state.anyDrift
        let anyAuthErr = store.state.errorsByAccount.values.contains { $0.kind == "auth" }

        // Severity ladder (DESIGN.md §5c, additive: AUTH_ERROR new in v2):
        // OFFLINE > AUTH_ERROR > DRIFT > STALE > LIVE
        let label: String
        let accent: Color
        let urgent: Bool
        if !running {
            label = "OFFLINE"; accent = Palette.danger; urgent = true
        } else if anyAuthErr {
            label = "AUTH_ERROR"; accent = Palette.danger; urgent = true
        } else if drift {
            label = "DRIFT"; accent = Palette.danger; urgent = true
        } else if stale {
            label = "STALE"; accent = Palette.amber; urgent = true
        } else {
            label = "LIVE"; accent = Palette.neon; urgent = false
        }

        return VStack(spacing: 0) {
            Rectangle().fill(Palette.stroke).frame(height: 0.5).padding(.bottom, 10)
            HStack(alignment: .center, spacing: 0) {
                HStack(spacing: 6) {
                    ZStack {
                        if urgent {
                            Circle()
                                .fill(accent.opacity(0.25))
                                .frame(width: 13, height: 13)
                                .modifier(PulsingHalo(color: accent))
                        }
                        Circle().fill(accent).frame(width: 7, height: 7)
                    }
                    .frame(width: 13, height: 13)
                    Text(label)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(accent)
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 0.5, height: 11)
                        .padding(.horizontal, 2)
                    Text(":7778")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Palette.cardFill)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Palette.stroke, lineWidth: 0.5))
                )
                Spacer()
                if let ts = store.state.lastUpdated {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("LAST UPDATE")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .tracking(0.9)
                            .foregroundStyle(.quaternary)
                        Text(ts, style: .relative)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

private struct FooterButtons: View {
    @EnvironmentObject private var store: SpendingStore
    var body: some View {
        HStack(spacing: 8) {
            ResetButton(action: { store.resetState() })
            QuitButton(action: { NSApplication.shared.terminate(nil) })
        }
    }
}

// MARK: - Misc primitives

private struct BreakdownHeader: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(Palette.stroke).padding(.bottom, 8)
            Text(text)
                .font(.system(size: 9, weight: .ultraLight, design: .monospaced))
                .tracking(2.5)
                .foregroundStyle(.white.opacity(0.3))
                .padding(.horizontal, 2)
                .padding(.bottom, 4)
        }
    }
}

private struct BackChip: View {
    let label: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                Text(label)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(0.8)
            }
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovered ? Color(white: 0.18) : Palette.cardFill)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Palette.stroke, lineWidth: 0.5)))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct ErrorPill: View {
    let kind: String

    var body: some View {
        Text(kind.uppercased())
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .tracking(0.6)
            .foregroundStyle(Palette.danger)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Palette.danger.opacity(0.15)))
    }
}

private struct ErrorCard: View {
    let error: AccountError
    @State private var showDetails = false

    /// Pull the meaningful sentence out of a vendor error blob. Vendors
    /// return JSON like `{"error":{"message":"invalid x-api-key", ...}}`
    /// nested under varied keys. We prefer that string when we can parse
    /// it; otherwise we fall back to the raw message.
    private var summary: String {
        ErrorCard.summarize(kind: error.kind, raw: error.message)
    }

    private var heading: String {
        switch error.kind.lowercased() {
        case "auth":     return "Admin key rejected"
        case "network":  return "Network issue"
        case "http":     return "Vendor error"
        case "parse":    return "Unrecognized response"
        case "internal": return "Reconciler error"
        default:         return error.kind.capitalized
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(Palette.danger.opacity(0.85))
                .frame(width: 2.5)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(error.kind.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.9)
                        .foregroundStyle(Palette.danger.opacity(0.95))
                    Text("·")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.30))
                    Text(heading)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(summary)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(showDetails ? nil : 2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: { showDetails.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                        Text(showDetails ? "Hide raw response" : "Show raw response")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(.white.opacity(0.40))
                }
                .buttonStyle(.plain)
                .padding(.top, 1)

                if showDetails {
                    // Pretty-printed when possible (JSON wraps cleanly at
                    // braces/commas), raw otherwise. Confined to the
                    // available width with explicit wrapping rules so it
                    // doesn't overflow the card.
                    Text(ErrorCard.prettifyForDisplay(error.message))
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.white.opacity(0.04))
                        )
                        .padding(.top, 2)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Parser. Best-effort: tries JSON first, then a couple of regex
    /// shapes vendors actually return. Falls back to a kind-specific
    /// generic line so the user always sees a coherent sentence.
    static func summarize(kind: String, raw: String) -> String {
        // Most vendor blobs come prefixed like "HTTP 401: {…json…}".
        // Lift the JSON portion if present.
        let body: String
        if let braceIdx = raw.firstIndex(of: "{") {
            body = String(raw[braceIdx...])
        } else {
            body = raw
        }

        if let data = body.data(using: .utf8),
           let any = try? JSONSerialization.jsonObject(with: data) {
            if let msg = ErrorCard.findMessage(in: any), !msg.isEmpty {
                return msg
            }
        }

        // Fallback: drop the trailing JSON dump if parsing failed but the
        // prefix is still informative (e.g., "HTTP 401: …" → "HTTP 401").
        if let colon = raw.range(of: ": {") {
            return String(raw[..<colon.lowerBound])
        }

        switch kind.lowercased() {
        case "auth":    return "Admin key was rejected by the vendor."
        case "network": return "Couldn't reach the vendor endpoint."
        case "parse":   return "Vendor returned an unrecognized response."
        default:        return raw.isEmpty ? "No additional detail." : raw
        }
    }

    /// Reformat the raw error blob so it wraps cleanly inside the card.
    /// If a JSON object is detected we pretty-print it with newlines at
    /// each comma; that lets SwiftUI line-break at natural boundaries
    /// instead of mid-token, which was causing the overflow.
    static func prettifyForDisplay(_ raw: String) -> String {
        // Capture the leading prefix (e.g., "HTTP 401: ") if any.
        var prefix = ""
        var jsonPart = raw
        if let braceIdx = raw.firstIndex(of: "{") {
            prefix = String(raw[..<braceIdx])
            jsonPart = String(raw[braceIdx...])
        }
        guard let data = jsonPart.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: parsed,
                options: [.prettyPrinted, .sortedKeys]),
              let prettyStr = String(data: pretty, encoding: .utf8)
        else {
            return raw
        }
        // JSONSerialization indents with 2 spaces by default; that's
        // fine inside the mono inset block.
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespaces)
        return trimmedPrefix.isEmpty ? prettyStr : "\(trimmedPrefix)\n\(prettyStr)"
    }

    /// Walk a parsed JSON value looking for a likely "message" or
    /// "detail" string. Vendors nest these inconsistently.
    static func findMessage(in any: Any) -> String? {
        if let dict = any as? [String: Any] {
            for key in ["message", "detail", "description"] {
                if let s = dict[key] as? String, !s.isEmpty { return s }
            }
            for v in dict.values {
                if let s = findMessage(in: v) { return s }
            }
        } else if let arr = any as? [Any] {
            for v in arr {
                if let s = findMessage(in: v) { return s }
            }
        }
        return nil
    }
}

private struct TodayEstimateGhost: View {
    let estimate: TodayEstimate

    var body: some View {
        // Cyan accent so this never gets confused with the green vendor-truth
        // hero number, but bright enough to read at a glance.
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Palette.cyan.opacity(0.18))
                    .frame(width: 18, height: 18)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.cyan)
                    .shadow(color: Palette.cyan.opacity(0.6), radius: 3)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("TODAY · LIVE · THIS LAPTOP")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(Palette.cyan.opacity(0.85))
                Text("proxy intra-day estimate")
                    .font(.system(size: 9, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Text(String(format: "$%.2f", estimate.usd))
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.cyan)
                .shadow(color: Palette.cyan.opacity(0.45), radius: 4)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Palette.cyan.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Palette.cyan.opacity(0.30), lineWidth: 0.5))
        )
    }
}

private struct DetailRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .regular,
                              design: monospaced ? .monospaced : .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }
}

// MARK: - Hero detail expansion (click the total card → "explode")
//
// Two flavors: v1 (proxy-only today) and v2 (multi-account yesterday).
// Both share the cyan-tinted card chrome so the user reads them as
// "this is a deeper look at the headline number above."

private struct HeroDetailV1: View {
    @EnvironmentObject private var store: SpendingStore

    var body: some View {
        let s = store.state
        return VStack(alignment: .leading, spacing: 10) {
            HeroDetailHeader(label: "TODAY · \(s.date.isEmpty ? "—" : s.date)",
                              total: s.totalUSD)

            // Token rollup — surfaced even when zero so the user sees they
            // exist. Values are running totals for the proxy's current day.
            HStack(spacing: 8) {
                MiniStat(label: "CACHE HIT",
                         value: formatTokens(s.cacheReadTokens),
                         accent: Palette.cyan)
                MiniStat(label: "CACHE WRITE",
                         value: formatTokens(s.cacheCreationTokens),
                         accent: Color(red: 0.72, green: 0.45, blue: 1.0))
                MiniStat(label: "MODELS",
                         value: "\(s.byModel.filter { $0.usd > 0.0001 }.count)",
                         accent: .white.opacity(0.85))
            }

            let topModels = s.byModel.filter { $0.usd > 0.0001 }.prefix(5)
            if !topModels.isEmpty {
                BreakdownHeader(text: "TOP MODELS")
                VStack(spacing: 1) {
                    ForEach(Array(topModels), id: \.model) { row in
                        HeroDetailRow(label: row.model, usd: row.usd, total: s.totalUSD,
                                      accent: Palette.cyan, mono: true)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Palette.cyan.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Palette.cyan.opacity(0.25), lineWidth: 0.5))
        )
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

private struct HeroDetailV2: View {
    @EnvironmentObject private var store: SpendingStore
    let usd: Double

    var body: some View {
        let yest = store.state.accounts.first?.yesterday.date ?? "—"

        // Aggregate workspaces / keys across accounts for "yesterday."
        var wsAgg: [(label: String, usd: Double, provider: String)] = []
        var keyAgg: [(label: String, tail: String, usd: Double, provider: String)] = []
        for acct in store.state.accounts {
            for ws in acct.yesterday.workspaces {
                wsAgg.append((ws.label, ws.usd, acct.provider))
            }
            // Hide muted keys from the cross-account TOP KEYS list so the
            // hero detail respects the operator's discards.
            for k in acct.visibleKeys {
                keyAgg.append((k.label, k.tail, k.usd, acct.provider))
            }
        }
        let topWorkspaces = wsAgg.sorted { $0.usd > $1.usd }.prefix(5)
        let topKeys = keyAgg.sorted { $0.usd > $1.usd }.prefix(5)

        let totalsForecast = store.forecastTotalEndOfMonth ?? 0
        let mtdAcrossAccounts: Double = {
            var sum = 0.0
            for acct in store.state.accounts {
                sum += store.monthToDateSpend(for: acct.id)
            }
            return sum
        }()
        let wowAcrossAccounts: Double? = {
            // Use aggregate history: this 7d / prior 7d − 1.
            let cal = Calendar(identifier: .gregorian)
            let isoFmt = DateFormatter()
            isoFmt.dateFormat = "yyyy-MM-dd"
            isoFmt.calendar = Calendar(identifier: .iso8601)
            isoFmt.timeZone = TimeZone(identifier: "UTC")
            let totals = store.dailyTotalsAcrossAccounts()
            var thisWeek = 0.0
            var lastWeek = 0.0
            let today = Date()
            for offset in 1...14 {
                guard let d = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
                let key = isoFmt.string(from: d)
                if let v = totals[key] {
                    if offset <= 7 { thisWeek += v } else { lastWeek += v }
                }
            }
            guard lastWeek > 0 else { return nil }
            return thisWeek / lastWeek - 1.0
        }()

        return VStack(alignment: .leading, spacing: 10) {
            HeroDetailHeader(label: "YESTERDAY · \(yest)", total: usd)

            HStack(spacing: 8) {
                MiniStat(label: "MTD",
                         value: String(format: "$%.2f", mtdAcrossAccounts),
                         accent: .white.opacity(0.85))
                MiniStat(label: "EOM",
                         value: totalsForecast > 0 ? ForecastChip.compact(totalsForecast) : "—",
                         accent: Palette.cyan)
                MiniStat(label: "WoW",
                         value: wowAcrossAccounts.map { String(format: "%@%.0f%%", $0 >= 0 ? "+" : "", $0 * 100) } ?? "—",
                         accent: wowAcrossAccounts.map { $0 > 0.05 ? Palette.danger : ($0 < -0.05 ? Palette.neon : .white.opacity(0.7)) } ?? .white.opacity(0.4))
            }

            if !topWorkspaces.isEmpty {
                BreakdownHeader(text: "TOP WORKSPACES · YESTERDAY")
                VStack(spacing: 1) {
                    ForEach(Array(topWorkspaces.enumerated()), id: \.offset) { _, row in
                        HeroDetailRow(label: row.label, usd: row.usd, total: usd,
                                      accent: providerColor(row.provider), mono: false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if !topKeys.isEmpty {
                BreakdownHeader(text: "TOP KEYS · YESTERDAY")
                VStack(spacing: 1) {
                    ForEach(Array(topKeys.enumerated()), id: \.offset) { _, row in
                        let display = row.tail.isEmpty ? row.label : "…\(row.tail)\(row.label.isEmpty ? "" : " · \(row.label)")"
                        HeroDetailRow(label: display, usd: row.usd, total: usd,
                                      accent: providerColor(row.provider), mono: true)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Palette.cyan.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Palette.cyan.opacity(0.25), lineWidth: 0.5))
        )
    }
}

private struct HeroDetailHeader: View {
    let label: String
    let total: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.expand.vertical")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.cyan)
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Text(total, format: .currency(code: "USD"))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Palette.cyan)
                .monospacedDigit()
        }
    }
}

private struct HeroDetailRow: View {
    let label: String
    let usd: Double
    let total: Double
    let accent: Color
    let mono: Bool

    var body: some View {
        let frac: Double = total > 0 ? min(usd / total, 1.0) : 0
        let pct = total > 0 ? Int((usd / total * 100).rounded()) : 0
        return HStack(spacing: 8) {
            Circle().fill(accent).frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 11, weight: .medium,
                              design: mono ? .monospaced : .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 4)
                    Rectangle().fill(accent.opacity(0.85))
                        .frame(width: geo.size.width * frac, height: 4)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(maxWidth: 70, maxHeight: .infinity)
            .frame(height: 4)
            Text(usd, format: .currency(code: "USD"))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.78))
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
            Text("\(pct)%")
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.30))
                .frame(width: 26, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Palette.rowFill)
    }
}

// MARK: - Burn rate card (live ¢/min while proxy is hot)

private struct BurnRateCard: View {
    let centsPerMin: Double
    @State private var pulse = false

    private var heat: Color {
        // ramp neon → amber → danger as the rate climbs
        if centsPerMin > 200 { return Palette.danger }
        if centsPerMin > 50  { return Palette.amber }
        return Palette.cyan
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(heat.opacity(0.20))
                    .frame(width: 22, height: 22)
                    .scaleEffect(pulse ? 1.25 : 1.0)
                    .opacity(pulse ? 0.0 : 0.7)
                    .animation(.easeOut(duration: 1.0).repeatForever(autoreverses: false), value: pulse)
                Image(systemName: "flame.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(heat)
                    .shadow(color: heat.opacity(0.6), radius: 4)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("BURN RATE · LIVE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(heat.opacity(0.9))
                Text("trailing 60s window")
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(Self.formatRate(centsPerMin))
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(heat)
                    .shadow(color: heat.opacity(0.45), radius: 4)
                    .monospacedDigit()
                Text("¢/min")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(heat.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(heat.opacity(0.30), lineWidth: 0.5))
        )
        .onAppear { pulse = true }
    }

    static func formatRate(_ c: Double) -> String {
        if c >= 100 { return String(format: "%.0f", c) }
        return String(format: "%.1f", c)
    }
}

// MARK: - Empty state for the BY ACCOUNT slot

private struct NoAccountsYetCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hourglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.cyan.opacity(0.85))
            VStack(alignment: .leading, spacing: 3) {
                Text("Waiting for first reconcile…")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                Text("Vendor data lands within 5 minutes of the first successful poll.")
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.10))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
        )
    }
}

// MARK: - History link

private struct HistoryLinkButton: View {
    @EnvironmentObject private var store: SpendingStore
    @State private var hovered = false

    var body: some View {
        Button(action: { store.showHistory() }) {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.cyan)
                Text("OPEN 90-DAY HISTORY")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hovered ? Color(white: 0.16) : Palette.cardFill)
                    .animation(.easeInOut(duration: 0.15), value: hovered)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        hovered ? Palette.cyan.opacity(0.30) : Palette.stroke,
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Muted keys section (Account Detail)
//
// Shown only when the account has at least one muted api_key_id. Lists
// each muted key with an "unmute" button so the operator can restore
// any discarded key without dropping to the CLI.

private struct MutedKeysSection: View {
    let account: AccountState
    @State private var expanded = false
    @EnvironmentObject private var store: SpendingStore

    var body: some View {
        let muted = account.yesterday.keys.filter { account.mutedKeyIDs.contains($0.id) }
        // We may have muted keys whose api_key_id isn't in the latest
        // yesterday.by_key (e.g., the key didn't get any spend yesterday
        // so the vendor didn't return a row for it). Surface those too,
        // with synthetic minimal info so the operator can still restore.
        let known: Set<String> = Set(muted.map(\.id))
        let extras: [AccountKeyEntry] = account.mutedKeyIDs
            .subtracting(known)
            .map { AccountKeyEntry(id: $0, label: "", tail: String($0.suffix(4)), usd: 0) }
        let allMuted = muted + extras

        VStack(alignment: .leading, spacing: 6) {
            Button(action: { expanded.toggle() }) {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("MUTED KEYS · \(allMuted.count)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1.0)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white.opacity(0.45))
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 1) {
                    ForEach(allMuted) { k in
                        MutedKeyRow(account: account, key: k)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

private struct MutedKeyRow: View {
    let account: AccountState
    let key: AccountKeyEntry
    @EnvironmentObject private var store: SpendingStore
    @State private var hovered = false

    var body: some View {
        let display = key.tail.isEmpty ? "…\(key.id.suffix(6))" : "…\(key.tail)"
        return HStack(spacing: 8) {
            Image(systemName: "eye.slash.fill")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.35))
            Text(display)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
            if !key.label.isEmpty {
                Text(key.label)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.30))
            }
            Spacer()
            Button(action: { store.setKeyMuted(account.id, key.id, muted: false) }) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.uturn.left")
                        .font(.system(size: 9, weight: .semibold))
                    Text("RESTORE")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                }
                .foregroundStyle(hovered ? Palette.neon : .white.opacity(0.55))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(hovered ? Palette.neon.opacity(0.10) : Color.white.opacity(0.04))
                )
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help("Restore \(display) — its spend will start counting again.")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Palette.rowFill)
    }
}

// MARK: - Disable account button

private struct DisableAccountButton: View {
    let accountID: String
    let label: String
    @EnvironmentObject private var store: SpendingStore
    @State private var hovered = false
    @State private var confirming = false

    var body: some View {
        Button(action: handleTap) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: confirming ? "exclamationmark.triangle.fill" : "minus.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(confirming ? Palette.danger : Palette.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text(confirming ? "TAP AGAIN TO CONFIRM" : "DISCARD FROM TRACKING")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(.primary.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(confirming
                         ? "\(label) will be hidden from totals"
                         : "Admin key kept on disk · reversible via CLI")
                        .font(.system(size: 9, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(confirming ? Palette.danger.opacity(0.10)
                                     : (hovered ? Color(white: 0.16) : Palette.cardFill))
                    .animation(.easeInOut(duration: 0.15), value: hovered)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        confirming ? Palette.danger.opacity(0.45)
                                   : (hovered ? Palette.amber.opacity(0.30) : Palette.stroke),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Stop tracking \(label). Excluded from totals; admin key stays on disk.")
    }

    private func handleTap() {
        if confirming {
            store.setAccountEnabled(accountID, enabled: false)
            confirming = false
        } else {
            confirming = true
            // Auto-cancel after 4s if the user doesn't confirm.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                confirming = false
            }
        }
    }
}

// MARK: - Budget progress + analytics

private struct BudgetProgressView: View {
    let account: AccountState
    @EnvironmentObject private var store: SpendingStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let cap = account.budgets.dailyUSD {
                bar(label: "TODAY",
                    spent: store.todaySpend(for: account.id),
                    cap:   cap)
            }
            if let cap = account.budgets.monthlyUSD {
                bar(label: "MONTH",
                    spent: store.monthToDateSpend(for: account.id),
                    cap:   cap)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Palette.cardFill)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Palette.stroke, lineWidth: 0.5))
        )
    }

    @ViewBuilder
    private func bar(label: String, spent: Double, cap: Double) -> some View {
        let frac = cap > 0 ? min(spent / cap, 1.5) : 0
        let color: Color = {
            if frac >= 1.0 { return Palette.danger }
            if frac >= 0.8 { return Palette.amber }
            return Palette.neon
        }()
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Text("\(formatUSD(spent)) of \(formatUSD(cap))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 6)
                    Rectangle().fill(color.opacity(0.85))
                        .frame(width: geo.size.width * min(frac, 1.0), height: 6)
                    if frac > 1.0 {
                        // Tip indicator showing how much over.
                        Rectangle().fill(Palette.danger)
                            .frame(width: 2, height: 8)
                            .offset(x: geo.size.width - 1)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 6)
        }
    }

    private func formatUSD(_ v: Double) -> String { String(format: "$%.2f", v) }
}

private struct AnalyticsRow: View {
    let account: AccountState
    @EnvironmentObject private var store: SpendingStore

    var body: some View {
        let mtd = store.monthToDateSpend(for: account.id)
        let forecast = store.forecastEndOfMonth(for: account.id)
        let wow = store.weekOverWeek(for: account.id)
        return HStack(spacing: 8) {
            MiniStat(label: "MTD",
                     value: String(format: "$%.2f", mtd),
                     accent: .white.opacity(0.85))
            MiniStat(label: "EOM",
                     value: forecast.map { ForecastChip.compact($0) } ?? "—",
                     accent: Palette.cyan)
            MiniStat(label: "WoW",
                     value: wow.map { String(format: "%@%.0f%%", $0 >= 0 ? "+" : "", $0 * 100) } ?? "—",
                     accent: wowColor(wow))
        }
    }

    private func wowColor(_ d: Double?) -> Color {
        guard let d = d else { return .white.opacity(0.4) }
        if d > 0.05  { return Palette.danger }
        if d < -0.05 { return Palette.neon }
        return .white.opacity(0.7)
    }
}

private struct MiniStat: View {
    let label: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(.white.opacity(0.4))
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Palette.cardFill)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Palette.stroke, lineWidth: 0.5))
        )
    }
}

// MARK: - History tier (90-day heatmap)

private struct HistoryView: View {
    @EnvironmentObject private var store: SpendingStore
    @State private var selectedDate: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            backHeader
            HeatmapGrid(selectedDate: $selectedDate)
            HeatmapLegend()
            if let d = selectedDate {
                DayDetailCard(dateISO: d, onClose: { selectedDate = nil })
            } else {
                HeatmapHint()
            }
            FooterButtons()
        }
        .padding(16)
    }

    private var backHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            BackChip(label: "OVERVIEW") { store.popToOverview() }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "calendar").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.cyan)
                Text("90-day history")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.stroke).frame(height: 0.5)
        }
    }
}

private struct HeatmapHint: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.point.up.left")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text("Click any cell to inspect that day")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

private struct DayDetailCard: View {
    let dateISO: String
    let onClose: () -> Void
    @EnvironmentObject private var store: SpendingStore

    var body: some View {
        let perAccount = store.history.compactMap { (aid, days) -> (provider: String, label: String, usd: Double)? in
            guard let entry = days[dateISO], entry.usd > 0 else { return nil }
            let label = store.account(id: aid)?.label ?? aid
            let provider = store.account(id: aid)?.provider ?? ""
            return (provider, label, entry.usd)
        }
        .sorted { $0.usd > $1.usd }

        let total = perAccount.reduce(0.0) { $0 + $1.usd }
        let displayDate = Self.prettyDate(dateISO)
        let breakdown = store.dayBreakdown(dateISO)
        let topWorkspaces = Array(breakdown.workspaces.prefix(5))
        let topKeys = Array(breakdown.keys.prefix(5))

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.cyan)
                Text(displayDate)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text(total, format: .currency(code: "USD"))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(total > 0 ? Palette.cyan : .secondary)
                    .monospacedDigit()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("Close inspection")
            }

            if perAccount.isEmpty {
                Text("No spend recorded on this day.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                Section(title: "BY ACCOUNT") {
                    VStack(spacing: 1) {
                        ForEach(Array(perAccount.enumerated()), id: \.offset) { _, row in
                            DayDetailRow(
                                provider: row.provider,
                                label:    row.label,
                                tail:     "",
                                usd:      row.usd,
                                total:    total,
                                mono:     false
                            )
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if !topWorkspaces.isEmpty {
                    Section(title: "WORKSPACES") {
                        VStack(spacing: 1) {
                            ForEach(topWorkspaces) { row in
                                DayDetailRow(
                                    provider: row.provider,
                                    label:    row.label,
                                    tail:     "",
                                    usd:      row.usd,
                                    total:    total,
                                    mono:     false
                                )
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

                if !topKeys.isEmpty {
                    Section(title: "KEYS") {
                        VStack(spacing: 1) {
                            ForEach(topKeys) { row in
                                let display = row.tail.isEmpty
                                    ? (row.label.isEmpty ? row.id : row.label)
                                    : "…\(row.tail)\(row.label.isEmpty ? "" : " · \(row.label)")"
                                DayDetailRow(
                                    provider: row.provider,
                                    label:    display,
                                    tail:     row.tail,
                                    usd:      row.usd,
                                    total:    total,
                                    mono:     true
                                )
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Palette.cyan.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Palette.cyan.opacity(0.30), lineWidth: 0.5))
        )
        .modifier(FadeInOnAppear())
    }

    static func prettyDate(_ iso: String) -> String {
        let inFmt = DateFormatter()
        inFmt.dateFormat = "yyyy-MM-dd"
        inFmt.calendar = Calendar(identifier: .iso8601)
        inFmt.timeZone = TimeZone(identifier: "UTC")
        guard let d = inFmt.date(from: iso) else { return iso }
        let outFmt = DateFormatter()
        outFmt.dateFormat = "EEE · MMM d, yyyy"
        return outFmt.string(from: d)
    }

    private struct Section<Content: View>: View {
        let title: String
        @ViewBuilder var content: () -> Content
        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 2)
                content()
            }
        }
    }
}

private struct DayDetailRow: View {
    let provider: String
    let label: String
    let tail: String
    let usd: Double
    let total: Double
    let mono: Bool

    var body: some View {
        HStack(spacing: 8) {
            ProviderMark(provider: provider, size: 18)
            Text(label)
                .font(.system(size: 11, weight: .medium,
                              design: mono ? .monospaced : .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("\(Int((usd / max(total, 0.0001) * 100).rounded()))%")
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.30))
            Text(usd, format: .currency(code: "USD"))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .monospacedDigit()
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Palette.rowFill)
    }
}

private struct HeatmapGrid: View {
    @EnvironmentObject private var store: SpendingStore
    @Binding var selectedDate: String?

    private static let isoFmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        let totals = store.dailyTotalsAcrossAccounts()
        let maxV = max(totals.values.max() ?? 0.0001, 0.0001)
        // Build a 7×13 grid (rows = day-of-week starting Mon, cols = week index).
        // Anchor: today is at the bottom-right region; we walk back 90 days.
        let cal = Calendar(identifier: .iso8601)
        let today = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today)
        // NSCalendar weekday: Sun=1..Sat=7. Convert to Mon=0..Sun=6.
        let isoWeekdayIdx = ((weekday + 5) % 7)
        let columns = 13
        let cellSize: CGFloat = 16
        let spacing: CGFloat = 3

        return VStack(spacing: spacing) {
            ForEach(0..<7, id: \.self) { dow in
                HStack(spacing: spacing) {
                    ForEach(0..<columns, id: \.self) { week in
                        let offsetFromToday =
                            (columns - 1 - week) * 7 + (isoWeekdayIdx - dow)
                        let cellDate = cal.date(byAdding: .day, value: -offsetFromToday, to: today) ?? today
                        let isFuture = cellDate > today
                        let key = Self.isoFmt.string(from: cellDate)
                        let v = totals[key] ?? 0
                        Cell(
                            dateKey: key,
                            amount: v,
                            max: maxV,
                            future: isFuture,
                            selected: selectedDate == key && !isFuture,
                            onTap: { tappedKey in
                                if isFuture { return }
                                // Toggle: clicking the selected cell clears it.
                                selectedDate = (selectedDate == tappedKey) ? nil : tappedKey
                            }
                        )
                        .frame(width: cellSize, height: cellSize)
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Palette.cardFill)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Palette.stroke, lineWidth: 0.5))
        )
    }

    private struct Cell: View {
        let dateKey: String
        let amount: Double
        let max: Double
        let future: Bool
        let selected: Bool
        let onTap: (String) -> Void
        @State private var hovered = false

        var body: some View {
            let frac = future ? -1 : (max > 0 ? amount / max : 0)
            let tint = fill(frac: frac)
            return Button(action: { onTap(dateKey) }) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(tint)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(
                                selected ? Color.white.opacity(0.95)
                                : (hovered ? Color.white.opacity(0.55) : Color.clear),
                                lineWidth: selected ? 1.5 : 1.0
                            )
                    )
                    .scaleEffect(selected ? 1.10 : 1.0)
                    .animation(.easeOut(duration: 0.12), value: selected)
                    .animation(.easeOut(duration: 0.12), value: hovered)
            }
            .buttonStyle(.plain)
            .disabled(future)
            .onHover { hovered = $0 }
            .help(future ? "—" : "\(dateKey) · $\(String(format: "%.2f", amount))")
        }

        private func fill(frac: Double) -> Color {
            if frac < 0 { return Color.white.opacity(0.04) }   // future cells
            if amount <= 0 { return Color.white.opacity(0.06) } // zero-spend day
            let bucket: Color
            switch frac {
            case ..<0.10: bucket = Palette.cyan.opacity(0.30)
            case ..<0.30: bucket = Palette.cyan.opacity(0.55)
            case ..<0.55: bucket = Palette.cyan.opacity(0.80)
            case ..<0.80: bucket = Palette.amber.opacity(0.85)
            default:      bucket = Palette.danger.opacity(0.95)
            }
            return bucket
        }
    }
}

private struct HeatmapLegend: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("less")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
            ForEach(0..<5, id: \.self) { i in
                let c: Color = {
                    switch i {
                    case 0: return Palette.cyan.opacity(0.30)
                    case 1: return Palette.cyan.opacity(0.55)
                    case 2: return Palette.cyan.opacity(0.80)
                    case 3: return Palette.amber.opacity(0.85)
                    default: return Palette.danger.opacity(0.95)
                    }
                }()
                RoundedRectangle(cornerRadius: 2)
                    .fill(c)
                    .frame(width: 12, height: 12)
            }
            Text("more")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.top, 4)
    }
}

// MARK: - Sparkline

private struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let maxV = max(values.max() ?? 0, 0.0001)
            let n = max(values.count, 2)
            let stepX = geo.size.width / CGFloat(n - 1)
            ZStack {
                Path { p in
                    for (i, v) in values.enumerated() {
                        let x = CGFloat(i) * stepX
                        let y = geo.size.height - CGFloat(v / maxV) * (geo.size.height - 4) - 2
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                        else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(color, lineWidth: 1.5)

                Path { p in
                    for (i, v) in values.enumerated() {
                        let x = CGFloat(i) * stepX
                        let y = geo.size.height - CGFloat(v / maxV) * (geo.size.height - 4) - 2
                        if i == 0 { p.move(to: CGPoint(x: x, y: geo.size.height)); p.addLine(to: CGPoint(x: x, y: y)) }
                        else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [color.opacity(0.35), color.opacity(0.0)],
                    startPoint: .top, endPoint: .bottom))
            }
        }
    }
}

