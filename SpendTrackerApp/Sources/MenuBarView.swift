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

// MARK: - Button components (file-level so they own @State)

private struct ResetButton: View {
    let amber: Color
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(amber)
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
                        hovered ? amber.opacity(0.35) : Color.white.opacity(0.07),
                        lineWidth: 0.5
                    )
                    .animation(.easeInOut(duration: 0.15), value: hovered)
            )
        }
        .buttonStyle(.plain)
        .help("Zero out today's spending counters")
        .onHover { hovered = $0 }
    }
}

private struct QuitButton: View {
    let alertRed: Color
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(alertRed)
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
                        hovered ? alertRed.opacity(0.35) : Color.white.opacity(0.07),
                        lineWidth: 0.5
                    )
                    .animation(.easeInOut(duration: 0.15), value: hovered)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - MenuBarView

struct MenuBarView: View {
    @EnvironmentObject private var store: SpendingStore
    @State private var headerAppeared = false
    @State private var selectedProvider: String? = nil

    private var state: SpendingState { store.state }

    var body: some View {
        ZStack {
            if let provider = selectedProvider {
                providerDetail(for: provider)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)))
            } else {
                overview
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        .frame(width: 380)
        .background(Color(white: 0.06))
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.22), value: selectedProvider)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            totalCard
            if state.byProvider.contains(where: { $0.usd > 0.0001 }) {
                providerBreakdown
            }
            if state.byKey.contains(where: { $0.usd > 0.0001 }) {
                keyBreakdown
            }
            proxyStatus
            footerButtons
        }
        .padding(16)
    }

    // MARK: – Header

    private var header: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(white: 0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5)
                        )
                        .frame(width: 44, height: 44)
                    Text("$")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.22, green: 1.0, blue: 0.08))
                        .shadow(color: Color(red: 0.22, green: 1.0, blue: 0.08).opacity(0.55), radius: 8, x: 0, y: 0)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("Spend")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Tracker")
                            .font(.system(size: 16, weight: .light, design: .rounded))
                            .foregroundStyle(Color(red: 0.22, green: 1.0, blue: 0.08))
                    }
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color(red: 0.22, green: 1.0, blue: 0.08))
                            .frame(width: 5, height: 5)
                            .shadow(color: Color(red: 0.22, green: 1.0, blue: 0.08).opacity(0.8), radius: 3)
                        Text(state.date.isEmpty ? "Today" : state.date)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
                resetCountdown
            }
            .padding(.bottom, 14)

            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 0.5)
        }
        .opacity(headerAppeared ? 1 : 0)
        .offset(y: headerAppeared ? 0 : -6)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25)) { headerAppeared = true }
        }
    }

    private var resetCountdown: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("RESETS IN")
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
                .kerning(0.8)
            Text(timeUntilMidnight())
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(red: 0.0, green: 0.87, blue: 1.0))
                .shadow(color: Color(red: 0.0, green: 0.87, blue: 1.0).opacity(0.35), radius: 6, x: 0, y: 0)
                .monospacedDigit()
        }
    }

    // MARK: – Total card

    private var totalCard: some View {
        let neonGreen = Color(red: 0.22, green: 1.0, blue: 0.08)
        let amber     = Color(red: 1.0,  green: 0.62, blue: 0.0)
        let danger    = Color(red: 1.0,  green: 0.27, blue: 0.23)
        let heroColor: Color = state.totalUSD > 5 ? danger : state.totalUSD > 1 ? amber : neonGreen

        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0.12))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))

            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 1)
                    .fill(neonGreen.opacity(0.75))
                    .frame(width: 2, height: geo.size.height * 0.56)
                    .frame(maxHeight: .infinity, alignment: .center)
            }

            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TODAY'S SPEND")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(.tertiary)
                    Text(state.totalUSD, format: .currency(code: "USD"))
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
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 5) {
                    if state.cacheReadTokens > 0 {
                        chipView(label: "CACHE HIT",   value: formatTokens(state.cacheReadTokens),
                                 color: Color(red: 0.0, green: 0.87, blue: 1.0))
                    }
                    if state.cacheCreationTokens > 0 {
                        chipView(label: "CACHE WRITE", value: formatTokens(state.cacheCreationTokens),
                                 color: Color(red: 0.72, green: 0.45, blue: 1.0))
                    }
                }
                .padding(.top, 2)
            }
            .padding(.vertical, 14)
            .padding(.leading, 18)
            .padding(.trailing, 14)
        }
        .fixedSize(horizontal: false, vertical: true)
        .modifier(FadeInOnAppear())
    }

    private func chipView(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 4, height: 4)
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(color.opacity(0.85))
            Text(value)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(color.opacity(0.22), lineWidth: 0.5))
        )
    }

    // MARK: – Provider breakdown

    private var providerBreakdown: some View {
        let active = state.byProvider.filter { $0.usd > 0.0001 }
        return VStack(alignment: .leading, spacing: 0) {
            Divider()
                .overlay(Color.white.opacity(0.07))
                .padding(.bottom, 10)

            Text("BY PROVIDER")
                .font(.system(size: 9, weight: .ultraLight, design: .monospaced))
                .tracking(2.5)
                .foregroundStyle(Color.white.opacity(0.3))
                .padding(.horizontal, 2)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 1) {
                ForEach(active, id: \.provider) { row in
                    providerRow(name: row.provider, usd: row.usd, total: state.totalUSD)
                }
            }
        }
    }

    private func providerRow(name: String, usd: Double, total: Double) -> some View {
        let color = providerColor(name)
        let fraction: Double = total > 0 ? min(usd / total, 1.0) : 0
        let pct = total > 0 ? Int((usd / total * 100).rounded()) : 0
        let driftEntry = state.drift.first { $0.provider == name }
        let isDrift = driftEntry?.state == "DRIFT"

        return Button(action: { selectedProvider = name }) {
            HStack(alignment: .center, spacing: 0) {
                color.frame(width: 2).clipShape(Rectangle())

                HStack(alignment: .center, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 5, height: 5)
                        Text(name.capitalized)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.82))
                            .lineLimit(1)
                        if isDrift {
                            Text("DRIFT")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .tracking(0.6)
                                .foregroundStyle(Color(red: 1.0, green: 0.27, blue: 0.23))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color(red: 1.0, green: 0.27, blue: 0.23).opacity(0.15)))
                        }
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
                        .foregroundStyle(Color.white.opacity(0.75))
                        .monospacedDigit()
                        .frame(width: 62, alignment: .trailing)

                    Text("\(pct)%")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.28))
                        .frame(width: 26, alignment: .trailing)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(white: 0.10))
                .overlay(Rectangle().strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
            }
        }
        .buttonStyle(.plain)
        .help("Tap to drill into \(name.capitalized)")
    }

    private func providerIcon(_ name: String) -> some View {
        ZStack {
            Circle().fill(providerColor(name).opacity(0.15)).frame(width: 24, height: 24)
            Image(systemName: providerSFSymbol(name))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(providerColor(name))
        }
    }

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

    private func providerSFSymbol(_ name: String) -> String {
        switch name.lowercased() {
        case "anthropic": return "a.circle"
        case "openai":    return "sparkles"
        case "gemini":    return "g.circle"
        case "mistral":   return "wind"
        case "cohere":    return "c.circle"
        default:          return "globe"
        }
    }

    // MARK: – Key breakdown

    private var keyBreakdown: some View {
        let active = state.byKey.filter { $0.usd > 0.0001 }
        return VStack(alignment: .leading, spacing: 0) {
            Divider()
                .overlay(Color.white.opacity(0.07))
                .padding(.bottom, 10)

            Text("BY KEY")
                .font(.system(size: 9, weight: .ultraLight, design: .monospaced))
                .tracking(2.5)
                .foregroundStyle(Color.white.opacity(0.3))
                .padding(.horizontal, 2)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 1) {
                ForEach(active) { row in
                    keyRow(entry: row, total: state.totalUSD)
                }
            }
        }
    }

    private func keyRow(entry: KeyEntry, total: Double) -> some View {
        let color = providerColor(entry.provider)
        let fraction: Double = total > 0 ? min(entry.usd / total, 1.0) : 0
        let pct = total > 0 ? Int((entry.usd / total * 100).rounded()) : 0
        let label = entry.tail.isEmpty ? "…\(entry.id.prefix(6))" : "…\(entry.tail)"

        return HStack(alignment: .center, spacing: 0) {
            color.frame(width: 2).clipShape(Rectangle())

            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 5, height: 5)
                    Text(label)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(1)
                    Text(entry.provider)
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.35))
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
                    .foregroundStyle(Color.white.opacity(0.75))
                    .monospacedDigit()
                    .frame(width: 62, alignment: .trailing)

                Text("\(pct)%")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.28))
                    .frame(width: 30, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(white: 0.10))
            .overlay(Rectangle().strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
        }
    }

    // MARK: – Proxy status

    private var proxyStatus: some View {
        let neonGreen = Color(red: 0.22, green: 1.0, blue: 0.08)
        let alertRed  = Color(red: 1.0, green: 0.25, blue: 0.22)

        return VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 0.5)
                .padding(.bottom, 10)

            HStack(alignment: .center, spacing: 0) {
                statusBadge(neonGreen: neonGreen, alertRed: alertRed)
                Spacer()
                if let ts = state.lastUpdated {
                    lastUpdateField(ts: ts)
                }
            }
        }
    }

    private func statusBadge(neonGreen: Color, alertRed: Color) -> some View {
        let running = store.proxyRunning
        let stale   = store.isStale
        let drift   = store.state.anyDrift
        let amber   = Color(red: 1.0, green: 0.62, blue: 0.0)
        // Severity order: OFFLINE > DRIFT > STALE > LIVE
        let accent: Color
        let label:  String
        if !running {
            accent = alertRed; label = "OFFLINE"
        } else if drift {
            accent = alertRed; label = "DRIFT"
        } else if stale {
            accent = amber; label = "STALE"
        } else {
            accent = neonGreen; label = "LIVE"
        }
        let urgent = !running || drift || stale

        return HStack(spacing: 6) {
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
                .fill(Color(white: 0.12))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
        )
    }

    private func lastUpdateField(ts: Date) -> some View {
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

    // MARK: – Provider detail

    private func providerDetail(for provider: String) -> some View {
        let providerUSD = state.byProvider.first { $0.provider == provider }?.usd ?? 0
        let tone = providerColor(provider)
        let modelsForProvider = state.byModel.filter { row in
            // Heuristic: model id is grouped under provider via prefix in pricing.json.
            // For tagging here we just show all models with non-zero spend; accuracy
            // improves once the proxy starts attaching provider tags to model rows.
            modelMatchesProvider(model: row.model, provider: provider)
        }
        let keysForProvider = state.byKey.filter { $0.provider == provider }
        let truth = state.vendorTruth(for: provider)
        let driftEntry = state.drift.first { $0.provider == provider }

        return VStack(alignment: .leading, spacing: 12) {
            providerDetailHeader(provider: provider, color: tone)

            providerDetailTotalCard(provider: provider, usd: providerUSD, color: tone)

            if let truth = truth {
                vendorTruthCard(provider: provider, truth: truth, drift: driftEntry, color: tone)
            }

            if !modelsForProvider.isEmpty {
                modelBreakdown(rows: modelsForProvider, providerTotal: providerUSD, color: tone)
            }
            if !keysForProvider.isEmpty {
                keyBreakdownScoped(rows: keysForProvider, providerTotal: providerUSD, color: tone)
            }

            proxyStatus
            footerButtons
        }
        .padding(16)
    }

    private func providerDetailHeader(provider: String, color: Color) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: { selectedProvider = nil }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                    Text("BACK")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                }
                .foregroundStyle(Color.white.opacity(0.7))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(white: 0.12))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5)))
            }
            .buttonStyle(.plain)

            Spacer()

            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(provider.capitalized)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
        }
    }

    private func providerDetailTotalCard(provider: String, usd: Double, color: Color) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0.12))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color.opacity(0.85))
                    .frame(width: 2, height: geo.size.height * 0.56)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TODAY · \(provider.uppercased())")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(.tertiary)
                    Text(usd, format: .currency(code: "USD"))
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(color)
                        .shadow(color: color.opacity(0.4), radius: 6, x: 0, y: 2)
                }
                Spacer()
            }
            .padding(.vertical, 12)
            .padding(.leading, 18)
            .padding(.trailing, 14)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func vendorTruthCard(provider: String, truth: VendorTruth, drift: DriftEntry?, color: Color) -> some View {
        let isDrift = drift?.state == "DRIFT"
        let accent: Color = isDrift ? Color(red: 1.0, green: 0.27, blue: 0.23) : Color.white.opacity(0.5)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: isDrift ? "exclamationmark.triangle.fill" : "checkmark.seal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
                Text(isDrift ? "VENDOR DRIFT" : "VENDOR TRUTH")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(accent)
                Spacer()
                if let d = drift, d.deltaPct > 0 {
                    Text(String(format: "%.1f%%", d.deltaPct))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("YESTERDAY · VENDOR")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .tracking(0.7)
                        .foregroundStyle(.quaternary)
                    Text(truth.usd, format: .currency(code: "USD"))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.85))
                }
                if let d = drift {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("YESTERDAY · PROXY")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .tracking(0.7)
                            .foregroundStyle(.quaternary)
                        Text(d.proxyUSD, format: .currency(code: "USD"))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(Color.white.opacity(0.65))
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isDrift ? Color(red: 1.0, green: 0.27, blue: 0.23).opacity(0.06) : Color(white: 0.10))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isDrift ? Color(red: 1.0, green: 0.27, blue: 0.23).opacity(0.35)
                                          : Color.white.opacity(0.06), lineWidth: 0.5))
        )
    }

    private func modelBreakdown(rows: [(model: String, usd: Double)], providerTotal: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("BY MODEL")
                .font(.system(size: 9, weight: .ultraLight, design: .monospaced))
                .tracking(2.5)
                .foregroundStyle(Color.white.opacity(0.3))
                .padding(.horizontal, 2)
                .padding(.bottom, 6)
            VStack(spacing: 1) {
                ForEach(rows, id: \.model) { row in
                    miniRow(label: row.model, usd: row.usd, total: providerTotal, color: color, mono: true)
                }
            }
        }
    }

    private func keyBreakdownScoped(rows: [KeyEntry], providerTotal: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("BY KEY")
                .font(.system(size: 9, weight: .ultraLight, design: .monospaced))
                .tracking(2.5)
                .foregroundStyle(Color.white.opacity(0.3))
                .padding(.horizontal, 2)
                .padding(.bottom, 6)
            VStack(spacing: 1) {
                ForEach(rows) { entry in
                    let label = entry.tail.isEmpty ? "…\(entry.id.prefix(6))" : "…\(entry.tail)"
                    miniRow(label: label, usd: entry.usd, total: providerTotal, color: color, mono: true)
                }
            }
        }
    }

    private func miniRow(label: String, usd: Double, total: Double, color: Color, mono: Bool) -> some View {
        let fraction: Double = total > 0 ? min(usd / total, 1.0) : 0
        return HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: mono ? .monospaced : .rounded))
                .foregroundStyle(Color.white.opacity(0.78))
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
            Text(usd, format: .currency(code: "USD"))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.72))
                .monospacedDigit()
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(white: 0.10))
        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
    }

    private func modelMatchesProvider(model: String, provider: String) -> Bool {
        let m = model.lowercased()
        switch provider.lowercased() {
        case "anthropic":   return m.contains("claude")
        case "openai":      return m.hasPrefix("gpt") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4")
        case "gemini":      return m.contains("gemini")
        case "mistral":     return m.contains("mistral") || m.contains("mixtral") || m.contains("codestral")
        case "cohere":      return m.contains("command") || m.contains("cohere")
        case "huggingface": return m.contains("/") || m.contains("deepseek")
        default:            return false
        }
    }

    // MARK: – Footer

    private var footerButtons: some View {
        let amber    = Color(red: 1.0, green: 0.62, blue: 0.0)
        let alertRed = Color(red: 1.0, green: 0.25, blue: 0.22)
        return HStack(spacing: 8) {
            ResetButton(amber: amber, action: { store.resetState() })
            QuitButton(alertRed: alertRed, action: { NSApplication.shared.terminate(nil) })
        }
    }

    // MARK: – Helpers

    private func timeUntilMidnight() -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        guard let tomorrow = cal.nextDate(after: Date(), matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime) else {
            return "--:--:--"
        }
        let diff = Int(tomorrow.timeIntervalSince(Date()))
        return String(format: "%02d:%02d:%02d", diff / 3600, (diff % 3600) / 60, diff % 60)
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
