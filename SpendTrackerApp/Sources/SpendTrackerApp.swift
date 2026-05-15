import AppKit
import Combine
import SwiftUI

@main
struct SpendTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let store = SpendingStore()

    private var flashIntensity: CGFloat = 0
    private var lastTotal: Double = -1
    private var cancellables = Set<AnyCancellable>()

    private static let neon  = NSColor(calibratedRed: 0.18, green: 1.0,  blue: 0.34, alpha: 1.0)
    /// Used for the menu-bar icon when state is older than 30 min. Amber
    /// keeps the icon clearly visible (vs. secondaryLabelColor which
    /// disappears on dark menu bars) while still reading as "not live."
    /// Matches the STALE badge color in the popover.
    private static let amber = NSColor(calibratedRed: 1.0,  green: 0.62, blue: 0.0,  alpha: 1.0)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.target = self
            btn.action = #selector(togglePopover(_:))
            btn.imagePosition = .imageOnly
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentSize = NSSize(width: 380, height: 440)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView().environmentObject(store)
        )

        store.$state
            .combineLatest(store.$isStale)
            .receive(on: RunLoop.main)
            .sink { [weak self] state, isStale in
                guard let self else { return }
                // Headline = v2 yesterday total + today_estimate when available;
                // falls back to v1 proxy total when registry isn't installed.
                let total = state.headlineUSD
                if self.lastTotal >= 0, abs(total - self.lastTotal) > 1e-9 {
                    self.flashIntensity = 1.0
                }
                self.flashIntensity = max(0, self.flashIntensity - 0.25)
                self.lastTotal = total
                self.statusItem.button?.image = self.renderIcon(total: total, stale: isStale)
            }
            .store(in: &cancellables)
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let btn = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
        }
    }

    private func renderIcon(total: Double, stale: Bool) -> NSImage {
        // Menu-bar icon is drawn programmatically at native resolution
        // rather than rasterized from the dock-icon SVG — the detailed
        // shield-and-pulse mark loses all legibility at 20pt. The
        // dock/Finder icon is still the rich AppMark; this is a
        // separate, deliberately simple high-contrast mark optimized
        // for the menu bar.
        let neon = AppDelegate.neon
        let amber = AppDelegate.amber
        let main: NSColor = stale ? amber : neon

        // Even in the stale state we keep a soft halo so the icon stands
        // out on dark menu bars. The amber+halo combo reads as "warning,
        // not live" without disappearing into the background.
        let glow: CGFloat = stale ? 0.5 : (0.65 + 0.35 * flashIntensity)

        let totalStr = String(format: "$%.2f", total)
        let costFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)

        let costShadow = NSShadow()
        costShadow.shadowColor = main.withAlphaComponent(min(1.0, glow * 0.9))
        costShadow.shadowBlurRadius = 3 + 4 * glow
        costShadow.shadowOffset = .zero
        // Shadow lives in the graphics context (see the disc draw below), not in
        // the attributes dict. macOS 26.x crashed inside -[NSDictionary
        // initWithDictionary:copyItems:] when NSShadow was an attribute value.
        let costAttrs: [NSAttributedString.Key: Any] = [
            .font: costFont,
            .foregroundColor: main,
        ]
        let costSize = (totalStr as NSString).size(withAttributes: costAttrs)

        let circleD: CGFloat = 18
        let gap: CGFloat = 5
        let leftPad: CGFloat = 6
        let rightPad: CGFloat = 7
        let totalW = leftPad + circleD + gap + ceil(costSize.width) + rightPad
        let totalH: CGFloat = 22

        let img = NSImage(size: NSSize(width: totalW, height: totalH))
        img.lockFocus()
        defer { img.unlockFocus() }

        let circleRect = NSRect(x: leftPad, y: (totalH - circleD) / 2, width: circleD, height: circleD)

        // Filled neon disc with a soft halo. High contrast against any
        // menu-bar background (light or dark wallpaper, accessibility
        // tints, etc.) — that's what was missing with the rasterized
        // dark-fill shield.
        let circleShadow = NSShadow()
        circleShadow.shadowColor = main.withAlphaComponent(min(1.0, glow))
        circleShadow.shadowBlurRadius = 5 + 5 * glow
        circleShadow.shadowOffset = .zero
        circleShadow.set()
        main.setFill()
        NSBezierPath(ovalIn: circleRect).fill()

        // Reset shadow state before drawing the inner glyph so the
        // black "$" doesn't itself emit a halo.
        let clearShadow = NSShadow()
        clearShadow.shadowColor = .clear
        clearShadow.set()

        // Bold black "$" stamped into the disc. Black on neon green is
        // the highest-contrast pairing on a 20pt target.
        let dollar = "$" as NSString
        let dollarFont = NSFont.systemFont(ofSize: 13, weight: .black)
        let dollarAttrs: [NSAttributedString.Key: Any] = [
            .font: dollarFont,
            .foregroundColor: NSColor.black.withAlphaComponent(0.92),
        ]
        let dSize = dollar.size(withAttributes: dollarAttrs)
        let dPoint = NSPoint(
            x: circleRect.midX - dSize.width / 2,
            y: circleRect.midY - dSize.height / 2 + 0.5
        )
        dollar.draw(at: dPoint, withAttributes: dollarAttrs)

        let costPoint = NSPoint(
            x: leftPad + circleD + gap,
            y: (totalH - costSize.height) / 2
        )
        NSGraphicsContext.saveGraphicsState()
        costShadow.set()
        (totalStr as NSString).draw(at: costPoint, withAttributes: costAttrs)
        NSGraphicsContext.restoreGraphicsState()

        img.isTemplate = false
        return img
    }
}
