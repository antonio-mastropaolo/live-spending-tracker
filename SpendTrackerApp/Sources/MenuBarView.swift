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

private func providerColor(_ name: String) -> Color {
    switch name.lowercased() {
    case "anthropic": return Color(red: 1.0,  green: 0.45, blue: 0.2)
    case "openai":    return Color(red: 0.45, green: 0.85, blue: 0.75)
    case "gemini":    return Color(red: 0.35, green: 0.55, blue: 1.0)
    case "mistral":   return Color(red: 1.0,  green: 0.62, blue: 0.0)
    case "cohere":    return Color(red: 0.6,  green: 0.35, blue: 1.0)
    default:          return Color(white: 0.55)
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
    let subtitle: String
    let trailing: AnyView?
    @State private var appeared = false

    init(subtitle: String, trailing: AnyView? = nil) {
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Palette.cardFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Palette.stroke, lineWidth: 0.5)
                        )
                        .frame(width: 44, height: 44)
                    Text("$")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(Palette.neon)
                        .shadow(color: Palette.neon.opacity(0.55), radius: 8)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("Spend")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Tracker")
                            .font(.system(size: 16, weight: .light, design: .rounded))
                            .foregroundStyle(Palette.neon)
                    }
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Palette.neon)
                            .frame(width: 5, height: 5)
                            .shadow(color: Palette.neon.opacity(0.8), radius: 3)
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderView(
                subtitle: store.state.hasV2Accounts ? "Yesterday · vendor truth" : "Today (proxy only)",
                trailing: AnyView(ReconcileFreshness(date: store.state.lastReconciled))
            )

            if store.state.hasV2Accounts {
                v2Body
            } else {
                v1Body
            }

            statusFooter
            footerButtons
        }
        .padding(16)
    }

    // ---- v2 (multi-account) ----

    @ViewBuilder
    private var v2Body: some View {
        TotalCard(usd: store.state.totalsYesterdayUSD, headline: "YESTERDAY · ALL ACCOUNTS")

        if !store.state.accounts.isEmpty {
            BreakdownHeader(text: "BY ACCOUNT")
            VStack(alignment: .leading, spacing: 1) {
                ForEach(store.state.accounts) { acct in
                    AccountRow(account: acct, total: store.state.totalsYesterdayUSD)
                }
            }
        }

        if let est = store.state.todayEstimate {
            TodayEstimateGhost(estimate: est)
        }
    }

    // ---- v1 fallback (registry not installed) ----

    @ViewBuilder
    private var v1Body: some View {
        TotalCard(usd: store.state.totalUSD, headline: "TODAY'S SPEND")

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
                DisableAccountButton(accountID: acct.id, label: acct.label)
                if let err = acct.error {
                    ErrorCard(error: err)
                }
                if !acct.yesterday.workspaces.isEmpty {
                    BreakdownHeader(text: workspacesHeader(provider: acct.provider))
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(acct.yesterday.workspaces) { ws in
                            WorkspaceRow(entry: ws, total: acct.yesterday.usd, color: providerColor(acct.provider))
                        }
                    }
                }
                if !acct.yesterday.keys.isEmpty {
                    BreakdownHeader(text: "BY KEY")
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(acct.yesterday.keys) { k in
                            AccountKeyRow(account: acct, key: k, color: providerColor(acct.provider))
                        }
                    }
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
                    Circle().fill(providerColor(acct.provider)).frame(width: 6, height: 6)
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

    var heroColor: Color {
        if usd > 25 { return Palette.danger }
        if usd > 5  { return Palette.amber }
        return Palette.neon
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Palette.cardFill)
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Palette.stroke, lineWidth: 0.5))

            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Palette.neon.opacity(0.75))
                    .frame(width: 2, height: geo.size.height * 0.56)
                    .frame(maxHeight: .infinity, alignment: .center)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(headline)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(.tertiary)
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
            .padding(.vertical, 14)
            .padding(.leading, 18)
            .padding(.trailing, 14)
        }
        .fixedSize(horizontal: false, vertical: true)
        .modifier(FadeInOnAppear())
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
                Text(account.yesterday.usd, format: .currency(code: "USD"))
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

    var body: some View {
        let color = providerColor(account.provider)
        let usd = account.yesterday.usd
        let fraction: Double = total > 0 ? min(usd / total, 1.0) : 0
        let pct = total > 0 ? Int((usd / total * 100).rounded()) : 0

        return Button(action: { store.showAccount(account.id) }) {
            HStack(alignment: .center, spacing: 0) {
                color.frame(width: 2).clipShape(Rectangle())

                HStack(alignment: .center, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 5, height: 5)
                        Text(account.label)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.tail)
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
                        .frame(width: 62, alignment: .trailing)

                    Text("\(pct)%")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.28))
                        .frame(width: 26, alignment: .trailing)

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

    var body: some View {
        let total = account.yesterday.usd
        let fraction: Double = total > 0 ? min(key.usd / total, 1.0) : 0
        let display: String = {
            if !key.tail.isEmpty { return "…\(key.tail)" }
            return "…\(key.id.suffix(6))"
        }()

        return Button(action: { store.showKey(account.id, key.id) }) {
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

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.danger)
            VStack(alignment: .leading, spacing: 3) {
                Text(error.kind.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(Palette.danger)
                Text(error.message)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(3)
                    .truncationMode(.tail)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Palette.danger.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Palette.danger.opacity(0.35), lineWidth: 0.5))
        )
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
            Text(String(format: "$%.4f", estimate.usd))
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

// MARK: - Disable account button

private struct DisableAccountButton: View {
    let accountID: String
    let label: String
    @EnvironmentObject private var store: SpendingStore
    @State private var hovered = false
    @State private var confirming = false

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: 6) {
                Image(systemName: confirming ? "exclamationmark.triangle.fill" : "minus.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(confirming ? Palette.danger : Palette.amber)
                Text(confirming ? "TAP AGAIN TO CONFIRM" : "DISCARD FROM TRACKING")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.primary.opacity(0.85))
                Spacer()
                Text(confirming ? "\(label) will be hidden" : "admin key kept; reversible via CLI")
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
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

