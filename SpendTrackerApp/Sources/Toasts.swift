import AppKit
import Combine
import SwiftUI

// MARK: - Public model

enum ToastKind: Hashable {
    case budgetDaily        // daily cap exceeded
    case budgetMonthly      // monthly cap exceeded
    case authError          // admin key rejected
    case networkError       // upstream timeout / TCP error
    case drift              // proxy vs vendor disagreement
    case burnRateSpike      // sustained high ¢/min
    case info               // generic status
}

struct Toast: Identifiable, Equatable {
    let id: UUID = UUID()
    let kind: ToastKind
    let title: String
    let message: String
    /// Provider id ("anthropic", "openai", …) used to tint the toast and
    /// stamp the monogram chip. ``nil`` for global / cross-provider events.
    let provider: String?
    /// Optional figures consumed by the per-kind layout (budget bars,
    /// percentage pills, ¢/min readouts).
    let spentUSD: Double?
    let capUSD: Double?
    let extraNumber: Double?    // burn-rate ¢/min, drift %, etc.
    let createdAt: Date = Date()

    init(
        kind: ToastKind,
        title: String,
        message: String,
        provider: String? = nil,
        spentUSD: Double? = nil,
        capUSD: Double? = nil,
        extraNumber: Double? = nil
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.provider = provider
        self.spentUSD = spentUSD
        self.capUSD = capUSD
        self.extraNumber = extraNumber
    }
}

// MARK: - ToastCenter
//
// Owns the queue + the floating NSPanel that hosts the SwiftUI stack. The
// panel sits below the menu bar at the right edge of the screen, ignores
// mouse focus by default, and resizes to fit whatever toasts are queued.

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published private(set) var toasts: [Toast] = []
    private var window: NSPanel?
    /// How long each toast stays before auto-dismissing.
    private let lifetimeSec: TimeInterval = 7.0

    private init() {}

    func enqueue(_ toast: Toast) {
        toasts.append(toast)
        ensureWindow()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(lifetimeSec * 1_000_000_000))
            self.dismiss(toast.id)
        }
    }

    func dismiss(_ id: UUID) {
        toasts.removeAll { $0.id == id }
        if toasts.isEmpty {
            window?.orderOut(nil)
        }
    }

    private func ensureWindow() {
        if let w = window {
            w.orderFrontRegardless()
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 1),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        let host = NSHostingView(rootView: ToastStackView(center: self))
        host.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = host
        panel.setContentSize(NSSize(width: 380, height: 1))
        panel.orderFrontRegardless()
        positionAtTopRight(panel)
        self.window = panel
    }

    private func positionAtTopRight(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.maxX - size.width - 12
        let y = visible.maxY - 6
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: y))
    }
}

// MARK: - Palette helpers (toast-internal)

private enum ToastPalette {
    static let danger = Color(red: 1.0,  green: 0.27, blue: 0.23)
    static let amber  = Color(red: 1.0,  green: 0.62, blue: 0.0)
    static let cyan   = Color(red: 0.0,  green: 0.87, blue: 1.0)
    static let neon   = Color(red: 0.22, green: 1.0,  blue: 0.08)
    static let purple = Color(red: 0.72, green: 0.45, blue: 1.0)
    static let slate  = Color(white: 0.55)
}

private struct ToastChrome {
    let stripe: Color
    let icon: String           // SF Symbol when no provider chip
    let kindLabel: String      // small uppercase tag
    let labelColor: Color
}

private func chrome(for kind: ToastKind) -> ToastChrome {
    switch kind {
    case .budgetDaily:
        return ToastChrome(stripe: ToastPalette.danger,
                           icon: "exclamationmark.triangle.fill",
                           kindLabel: "BUDGET · DAILY",
                           labelColor: ToastPalette.danger)
    case .budgetMonthly:
        return ToastChrome(stripe: ToastPalette.amber,
                           icon: "calendar.badge.exclamationmark",
                           kindLabel: "BUDGET · MONTHLY",
                           labelColor: ToastPalette.amber)
    case .authError:
        return ToastChrome(stripe: ToastPalette.danger,
                           icon: "key.slash.fill",
                           kindLabel: "ADMIN KEY REJECTED",
                           labelColor: ToastPalette.danger)
    case .networkError:
        return ToastChrome(stripe: ToastPalette.slate,
                           icon: "wifi.exclamationmark",
                           kindLabel: "NETWORK ISSUE",
                           labelColor: ToastPalette.slate)
    case .drift:
        return ToastChrome(stripe: ToastPalette.amber,
                           icon: "scale.3d",
                           kindLabel: "VENDOR DRIFT",
                           labelColor: ToastPalette.amber)
    case .burnRateSpike:
        return ToastChrome(stripe: ToastPalette.cyan,
                           icon: "flame.fill",
                           kindLabel: "BURN RATE SPIKE",
                           labelColor: ToastPalette.cyan)
    case .info:
        return ToastChrome(stripe: ToastPalette.neon,
                           icon: "checkmark.seal.fill",
                           kindLabel: "STATUS",
                           labelColor: ToastPalette.neon)
    }
}

/// Effective stripe color: provider tint takes precedence so an
/// Anthropic budget breach always reads as amber-orange and an OpenAI
/// breach always reads as green-cyan, regardless of kind.
private func stripeColor(_ toast: Toast) -> Color {
    if let p = toast.provider { return providerColor(p) }
    return chrome(for: toast.kind).stripe
}

// MARK: - Stack view

private struct ToastStackView: View {
    @ObservedObject var center: ToastCenter

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(center.toasts) { toast in
                ToastCard(toast: toast, dismiss: { center.dismiss(toast.id) })
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 0.92, anchor: .topTrailing)),
                        removal: .opacity
                            .combined(with: .move(edge: .trailing))))
            }
        }
        .padding(.trailing, 4)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(.spring(response: 0.40, dampingFraction: 0.78), value: center.toasts)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Toast card (shared shell + per-kind body)
//
// Design intent: looks like a quiet system notification, not a game popup.
// Flat dark card · neutral drop shadow · hairline white border · the
// accent color appears only in (1) a thin 2.5pt left rule and (2) the
// kind-tag text. No outer color halo, no pulsing, no saturated pills.

private struct ToastCard: View {
    let toast: Toast
    let dismiss: () -> Void
    @State private var hovered = false

    var body: some View {
        let stripe = stripeColor(toast)
        let kindChrome = chrome(for: toast.kind)

        return ZStack(alignment: .leading) {
            // Flat dark card with a hairline white border. No color wash.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(white: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )

            // Thin left accent rule — solid, no gradient.
            HStack(spacing: 0) {
                Rectangle()
                    .fill(stripe.opacity(0.85))
                    .frame(width: 2.5)
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: 10, bottomLeadingRadius: 10,
                        bottomTrailingRadius: 0, topTrailingRadius: 0))
                Spacer()
            }

            HStack(alignment: .top, spacing: 11) {
                ToastIcon(toast: toast)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(kindChrome.kindLabel)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(0.9)
                            .foregroundStyle(stripe.opacity(0.95))
                            .lineLimit(1)
                        Text("·")
                            .font(.system(size: 9, weight: .regular, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.30))
                        Text(toast.title)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(toast.message)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    // Per-kind data row: thin divider + restrained content.
                    let body = ToastBody(toast: toast, stripe: stripe)
                    if !(toast.kind == .info || toast.kind == .networkError) {
                        Rectangle()
                            .fill(Color.white.opacity(0.06))
                            .frame(height: 0.5)
                            .padding(.vertical, 2)
                    }
                    body
                }
                Spacer(minLength: 4)

                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(hovered ? 0.65 : 0.30))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .help("Dismiss")
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 11)
        }
        .frame(width: 360)
        // Neutral drop shadow only — no colored halo.
        .shadow(color: .black.opacity(0.50), radius: 12, x: 0, y: 4)
    }
}

// MARK: - Icon: provider monogram or kind glyph
//
// Quiet treatment: just the provider chip OR a flat glyph in a
// rounded-square chip. No glow, no pulse, no corner badge — the
// kind-tag text already names the event so the icon doesn't have
// to over-encode it.

private struct ToastIcon: View {
    let toast: Toast

    var body: some View {
        let kindChrome = chrome(for: toast.kind)
        let stripe = stripeColor(toast)

        if let provider = toast.provider {
            ProviderMark(provider: provider, size: 32)
        } else {
            // Provider-less toast: small flat chip with the kind glyph.
            // Sized to match ProviderMark exactly so the layout doesn't
            // jump between toast types.
            ZStack {
                RoundedRectangle(cornerRadius: 32 * 0.28, style: .continuous)
                    .fill(Color(white: 0.13))
                RoundedRectangle(cornerRadius: 32 * 0.28, style: .continuous)
                    .strokeBorder(stripe.opacity(0.45), lineWidth: 0.6)
                Image(systemName: kindChrome.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(stripe.opacity(0.85))
            }
            .frame(width: 32, height: 32)
        }
    }
}

// MARK: - Per-kind data row

private struct ToastBody: View {
    let toast: Toast
    let stripe: Color

    @ViewBuilder
    var body: some View {
        switch toast.kind {
        case .budgetDaily, .budgetMonthly:
            BudgetBar(spent: toast.spentUSD, cap: toast.capUSD, accent: stripe)
        case .burnRateSpike:
            HStack(spacing: 4) {
                Text(String(format: "%.1f", toast.extraNumber ?? 0))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                Text("¢/min sustained")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.50))
            }
        case .drift:
            HStack(spacing: 4) {
                Text(String(format: "Δ %.1f%%", toast.extraNumber ?? 0))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.80))
                    .monospacedDigit()
                Text("vendor vs proxy")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
        case .authError:
            Text("Reconciler paused for this account.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.50))
        case .networkError, .info:
            EmptyView()
        }
    }
}

private struct BudgetBar: View {
    let spent: Double?
    let cap: Double?
    let accent: Color

    var body: some View {
        guard let spent = spent, let cap = cap, cap > 0 else {
            return AnyView(EmptyView())
        }
        let frac = min(spent / cap, 1.0)
        let pct = Int((spent / cap * 100).rounded())

        return AnyView(
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\(pct)%")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent.opacity(0.95))
                        .monospacedDigit()
                    Spacer(minLength: 4)
                    Text(String(format: "$%.2f / $%.2f", spent, cap))
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .monospacedDigit()
                }
                // Flat bar — no gradient, no blendmode tricks. The accent
                // alone communicates "this is the metric"; if the spend
                // is over the cap (frac=1.0) the bar is fully filled and
                // the percent text says it.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.07)).frame(height: 3)
                        Capsule().fill(accent.opacity(0.85))
                            .frame(width: geo.size.width * frac, height: 3)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 3)
            }
        )
    }
}
